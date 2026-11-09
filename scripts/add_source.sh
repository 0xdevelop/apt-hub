#!/usr/bin/env bash
# 一次加源：下载站点公钥与当前系列 .sources，验签后写入目标根；之后走普通 apt。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C

SCRIPT_PATH="$(realpath -e -- "${BASH_SOURCE[0]}")"
SCRIPT_BASE="$(basename -- "${SCRIPT_PATH}")"
PROJECT_ROOT=""
PROJECT_TMP=""

SITE_URL_RE='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$'
SOFTWARE_ID_RE='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
SERIES_RE='^[a-z][a-z0-9]*$'
ARCH_RE='^(amd64|arm64)$'
# Ubuntu 标准：/etc/os-release -> ../usr/lib/os-release
OS_RELEASE_LINK_TARGET='../usr/lib/os-release'

site_url=""
software_id=""
root_arg=""
architecture=""
cacert=""
replace_key_fpr=""
target_root="/"
isolated=0
series=""
arch=""
scratch=""
scratch_owned=0
lock_fd=""
success=0
created_key=0
created_sources=0
replaced_key=0
key_backup_mode=""

die() {
  printf 'add_source.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法: add_source.sh --site-url <https站点URL> --software <软件id> [--root <已存在隔离根>] [--architecture <架构>] [--cacert <仅隔离根>] [--replace-key <新公钥完整40hex指纹>]
EOF
  exit 2
}

# shellcheck disable=SC2317 # 仅由 cleanup 间接调用
is_repo_source_script() {
  local dir
  dir="$(dirname -- "${SCRIPT_PATH}")"
  [[ "$(basename -- "${dir}")" == "scripts" ]] || return 1
  [[ -f "${dir}/sync.sh" ]] || return 1
  return 0
}

# shellcheck disable=SC2317 # EXIT trap 调用
cleanup() {
  local rc=$?
  if [[ -n "${lock_fd}" ]]; then
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
  fi
  if [[ "${scratch_owned}" -eq 1 && -n "${scratch}" && -d "${scratch}" && ! -L "${scratch}" ]]; then
    rm -rf -- "${scratch}"
  fi
  if [[ "${success}" -eq 1 ]]; then
    # 仓库 scripts/ 源码不自删；仅 cwd 下下载副本 basename 自删。
    if ! is_repo_source_script; then
      if [[ -f "./${SCRIPT_BASE}" && ! -L "./${SCRIPT_BASE}" ]]; then
        if [[ "$(realpath -e -- "./${SCRIPT_BASE}" 2>/dev/null || true)" == "${SCRIPT_PATH}" ]]; then
          rm -f -- "./${SCRIPT_BASE}"
        fi
      fi
    fi
  fi
  exit "${rc}"
}
trap cleanup EXIT

require_cmd() {
  local c
  for c in "$@"; do
    command -v -- "${c}" >/dev/null 2>&1 || die "缺少命令: ${c}"
  done
}

make_abs_unresolved() {
  local p="$1"
  if [[ "${p}" == /* ]]; then
    printf '%s\n' "${p}"
  else
    printf '%s/%s\n' "$(pwd -P)" "${p}"
  fi
}

assert_no_symlink_components() {
  local path="$1" prefix="/" part
  [[ "${path}" == /* ]] || die "路径必须是绝对路径: ${path}"
  IFS=/ read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [[ -n "${part}" ]] || continue
    prefix="${prefix%/}/${part}"
    [[ ! -L "${prefix}" ]] || die "路径含符号链接: ${prefix}"
  done
}

under_dir() {
  local parent="$1" child="$2"
  [[ "${child}" == "${parent}" || "${child}" == "${parent}/"* ]]
}

discover_project_root() {
  local start="$1" cur
  cur="$(realpath -e -- "${start}")"
  [[ -d "${cur}" ]] || cur="$(dirname -- "${cur}")"
  while [[ "${cur}" != "/" ]]; do
    if [[ -f "${cur}/VERSION" && -f "${cur}/scripts/sync.sh" && -d "${cur}/tmp" && ! -L "${cur}/tmp" ]]; then
      printf '%s\n' "${cur}"
      return 0
    fi
    cur="$(dirname -- "${cur}")"
  done
  return 1
}

bind_project_paths() {
  local hint="$1" found
  if found="$(discover_project_root "${hint}")"; then
    PROJECT_ROOT="${found}"
    PROJECT_TMP="${PROJECT_ROOT}/tmp"
    return 0
  fi
  return 1
}

strip_fp() {
  local s="$1"
  s="$(printf '%s' "${s}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  printf '%s\n' "${s}"
}

public_key_fingerprint() {
  local keyfile="$1"
  gpg --batch --show-keys --with-colons -- "${keyfile}" 2>/dev/null \
    | awk -F: '$1=="fpr"{print $10; exit}'
}

# 主指纹：仅统计 pub 后的首个 fpr，忽略 subkey。
primary_public_key_fingerprints() {
  local keyfile="$1"
  gpg --batch --show-keys --with-colons -- "${keyfile}" 2>/dev/null \
    | awk -F: '
      $1=="pub" { want=1; next }
      $1=="sub" { want=0; next }
      $1=="fpr" && want { print $10; want=0 }
    '
}

assert_unique_primary_fingerprint() {
  local keyfile="$1"
  local expected="$2"
  local fprs n got
  fprs="$(primary_public_key_fingerprints "${keyfile}")"
  n="$(printf '%s\n' "${fprs}" | grep -c . || true)"
  [[ "${n}" -eq 1 ]] || die "下载公钥必须恰好一个主指纹，实际 ${n} 个"
  got="$(strip_fp "$(printf '%s\n' "${fprs}" | head -n1)")"
  [[ "${got}" =~ ^[A-F0-9]{40}$ ]] || die "无法读取下载公钥主指纹"
  [[ "${got}" == "${expected}" ]] || die "下载公钥主指纹不符: 实际=${got} 期望=${expected}"
}

# 共享专用 keyring 的 apt-hub-*.sources 必须同站点。
assert_shared_key_sources_same_site() {
  local sources_dir="$1" site="$2"
  local f signed_by uris
  shopt -s nullglob
  for f in "${sources_dir}"/apt-hub-*.sources; do
    [[ -f "${f}" && ! -L "${f}" ]] || continue
    signed_by="$(awk -F': ' '$1=="Signed-By"{print $2; exit}' "${f}")"
    case "${signed_by}" in
      /etc/apt/keyrings/apt-hub.gpg|*/etc/apt/keyrings/apt-hub.gpg) ;;
      *) continue ;;
    esac
    uris="$(awk -F': ' '$1=="URIs"{print $2; exit}' "${f}")"
    case "${uris}" in
      "mirror+${site}/repos/"*/mirror.list) ;;
      *)
        die "共享钥的其他源不属于同一站点: ${f}"
        ;;
    esac
  done
  shopt -u nullglob
}

assert_site_url() {
  local u="$1" host rest path
  [[ -n "${u}" ]] || die "缺少 --site-url"
  case "${u}" in
    *[\?#]*|*"@"*|*" "*) die "site-url 含非法字符/query/frag/userinfo: ${u}" ;;
  esac
  [[ "${u}" =~ ${SITE_URL_RE} ]] || die "site-url 非法: ${u}"
  [[ "${u}" == https://* ]] || die "site-url 必须是 https: ${u}"
  rest="${u#https://}"
  host="${rest%%/*}"
  [[ -n "${host}" ]] || die "site-url 空 host"
  path="${rest#"${host}"}"
  [[ "${path}" != *..* ]] || die "site-url 含路径遍历"
  host="${host%%:*}"
  host="$(printf '%s' "${host}" | tr '[:upper:]' '[:lower:]')"
  case "${host}" in
    localhost|localhost.*|127.0.0.1|::1)
      die "site-url 拒绝 localhost: ${u}"
      ;;
  esac
  printf '%s\n' "${u%/}"
}

assert_software_id() {
  local id="$1"
  [[ -n "${id}" ]] || die "缺少 --software"
  [[ "${id}" =~ ${SOFTWARE_ID_RE} ]] || die "software id 非法: ${id}"
  [[ "${id}" != *..* ]] || die "software id 含 .."
  printf '%s\n' "${id}"
}

# 解析可读的 os-release 普通文件路径。允许 Ubuntu 标准只读 symlink；不 source。
resolve_os_release_file() {
  local root="$1"
  local link target resolved root_real
  if [[ "${root}" == "/" ]]; then
    link="/etc/os-release"
  else
    link="${root}/etc/os-release"
  fi
  [[ -e "${link}" ]] || die "缺少 os-release: ${link}"
  if [[ -L "${link}" ]]; then
    target="$(readlink -- "${link}")"
    [[ "${target}" == "${OS_RELEASE_LINK_TARGET}" ]] \
      || die "os-release 符号链接非标准布局: ${target}"
    if [[ "${root}" == "/" ]]; then
      resolved="/usr/lib/os-release"
    else
      root_real="$(realpath -e -- "${root}")"
      resolved="${root_real}/usr/lib/os-release"
      [[ -e "${resolved}" ]] || die "隔离根缺少 usr/lib/os-release"
      resolved="$(realpath -e -- "${resolved}")"
      under_dir "${root_real}" "${resolved}" || die "os-release 链接越出隔离根"
    fi
    [[ -f "${resolved}" && ! -L "${resolved}" ]] || die "os-release 目标不是普通文件: ${resolved}"
    printf '%s\n' "${resolved}"
    return 0
  fi
  [[ -f "${link}" && ! -L "${link}" ]] || die "os-release 非法: ${link}"
  printf '%s\n' "${link}"
}

parse_os_release_field() {
  # 安全读取：不 source；file 必须是已解析的普通文件。
  local file="$1" key="$2" line val
  [[ -f "${file}" && ! -L "${file}" ]] || die "缺少合法 os-release 文件: ${file}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    val="${line#"${key}="}"
    val="${val#\"}"
    val="${val%\"}"
    val="${val#\'}"
    val="${val%\'}"
    printf '%s\n' "${val}"
    return 0
  done <"${file}"
  return 1
}

resolve_target_root() {
  local abs
  if [[ -z "${root_arg}" ]]; then
    target_root="/"
    isolated=0
    [[ "$(id -u)" -eq 0 ]] || die "系统根写入需要 root 权限"
    PROJECT_ROOT=""
    PROJECT_TMP=""
    return 0
  fi
  abs="$(make_abs_unresolved "${root_arg}")"
  [[ -e "${abs}" ]] || die "--root 不存在: ${abs}"
  [[ -d "${abs}" && ! -L "${abs}" ]] || die "--root 必须是已存在的普通目录"
  assert_no_symlink_components "${abs}"
  abs="$(realpath -e -- "${abs}")"
  bind_project_paths "${abs}" || bind_project_paths "${SCRIPT_PATH}" \
    || die "--root 必须位于 apt-hub 项目 tmp/ 下"
  under_dir "${PROJECT_TMP}" "${abs}" || die "--root 仅允许本项目 tmp/ 下隔离根"
  [[ "${abs}" != "${PROJECT_TMP}" && "${abs}" != "${PROJECT_ROOT}" ]] || die "--root 不能是项目/tmp 根"
  [[ -e "${abs}/etc/os-release" ]] || die "隔离根缺少 etc/os-release"
  target_root="${abs}"
  isolated=1
}

resolve_identity() {
  local osrel id_val codename
  osrel="$(resolve_os_release_file "${target_root}")"
  id_val="$(parse_os_release_field "${osrel}" ID)" || die "os-release 缺少 ID"
  [[ "${id_val}" == "ubuntu" ]] || die "仅支持 Ubuntu，当前 ID=${id_val}"
  codename="$(parse_os_release_field "${osrel}" VERSION_CODENAME)" || die "os-release 缺少 VERSION_CODENAME"
  [[ "${codename}" =~ ${SERIES_RE} ]] || die "VERSION_CODENAME 非法: ${codename}"
  series="${codename}"

  if [[ -n "${architecture}" ]]; then
    [[ "${isolated}" -eq 1 ]] || die "--architecture 仅允许隔离根"
    [[ "${architecture}" =~ ${ARCH_RE} ]] || die "architecture 非法: ${architecture}"
    arch="${architecture}"
  elif [[ "${isolated}" -eq 1 && -f "${target_root}/var/lib/dpkg/status" && ! -L "${target_root}/var/lib/dpkg/status" ]]; then
    arch="$(dpkg --print-architecture)"
    [[ "${arch}" =~ ${ARCH_RE} ]] || die "本机 dpkg 架构不受支持: ${arch}"
  elif [[ "${isolated}" -eq 1 ]]; then
    die "隔离根需提供 --architecture，或具备 var/lib/dpkg/status"
  else
    arch="$(dpkg --print-architecture)"
    [[ "${arch}" =~ ${ARCH_RE} ]] || die "本机架构不受支持: ${arch}"
  fi
}

curl_get() {
  local url="$1" dest="$2"
  # 不强制关闭代理：尊重调用方网络配置；隔离回环由测试侧 DIRECT。
  local args=(
    -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2
    --connect-timeout 20 --max-time 120
    -o "${dest}"
  )
  if [[ -n "${cacert}" ]]; then
    args+=(--cacert "${cacert}")
  fi
  curl "${args[@]}" -- "${url}" || return 1
  [[ -f "${dest}" && -s "${dest}" && ! -L "${dest}" ]] || return 1
}

dearmor_key_to() {
  local src="$1" dest="$2" gpghome
  gpghome="${scratch}/gpg-dearmor"
  mkdir -p -- "${gpghome}"
  chmod 700 -- "${gpghome}"
  if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "${src}"; then
    GNUPGHOME="${gpghome}" gpg --batch --yes --dearmor <"${src}" >"${dest}"
  else
    cp -f -- "${src}" "${dest}"
  fi
  rm -rf -- "${gpghome}"
  [[ -s "${dest}" ]] || die "公钥为空"
  chmod 0644 -- "${dest}"
}

verify_inrelease() {
  local keyring="$1" inrelease="$2" body_out="$3" status_out="$4"
  local rc=0
  rm -f -- "${body_out}" "${status_out}"
  gpgv --keyring "${keyring}" --status-fd 3 --output "${body_out}" -- "${inrelease}" \
    3>"${status_out}" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 0 && -s "${body_out}" ]] || die "InRelease gpgv 验签失败"
  grep -q '^\[GNUPG:\] GOODSIG ' "${status_out}" || die "InRelease 无 GOODSIG"
  if grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|NO_PUBKEY|EXPSIG|EXPKEYSIG|REVKEYSIG) ' "${status_out}"; then
    die "InRelease 签名状态拒绝"
  fi
}

check_release_body() {
  local body="$1"
  local suite codename archs valid_until now_epoch until_epoch
  suite="$(awk -F': ' '$1=="Suite"{print $2; exit}' "${body}")"
  codename="$(awk -F': ' '$1=="Codename"{print $2; exit}' "${body}")"
  archs="$(awk -F': ' '$1=="Architectures"{print $2; exit}' "${body}")"
  valid_until="$(awk -F': ' '$1=="Valid-Until"{print $2; exit}' "${body}")"
  [[ "${suite}" == "${series}" ]] || die "Suite 不匹配: ${suite} != ${series}"
  [[ "${codename}" == "${series}" ]] || die "Codename 不匹配: ${codename} != ${series}"
  [[ -n "${archs}" ]] || die "Release 缺少 Architectures"
  printf '%s\n' "${archs}" | tr ' ' '\n' | grep -qx -- "${arch}" \
    || die "当前架构 ${arch} 不在声明 Architectures: ${archs}"
  [[ -n "${valid_until}" ]] || die "Release 缺少 Valid-Until"
  now_epoch="$(date -u +%s)"
  until_epoch="$(date -u -d "${valid_until}" +%s 2>/dev/null)" \
    || die "Valid-Until 无法解析: ${valid_until}"
  [[ "${now_epoch}" -le "${until_epoch}" ]] || die "InRelease 已过期: ${valid_until}"
}

packages_hash_from_release() {
  local body="$1" arch_name="$2"
  awk -v f="main/binary-${arch_name}/Packages" '
    $1 == "SHA256:" { insha = 1; next }
    insha && NF >= 3 {
      path = $3
      sub(/^\.\//, "", path)
      if (path == f) { print $1; exit }
    }
    insha && NF == 0 { insha = 0 }
  ' "${body}"
}

validate_sources_file() {
  local file="$1" expected_uri="$2"
  local types uris suites components signed_by archs
  types="$(awk -F': ' '$1=="Types"{print $2; exit}' "${file}")"
  uris="$(awk -F': ' '$1=="URIs"{print $2; exit}' "${file}")"
  suites="$(awk -F': ' '$1=="Suites"{print $2; exit}' "${file}")"
  components="$(awk -F': ' '$1=="Components"{print $2; exit}' "${file}")"
  signed_by="$(awk -F': ' '$1=="Signed-By"{print $2; exit}' "${file}")"
  archs="$(awk -F': ' '$1=="Architectures"{print $2; exit}' "${file}")"
  [[ "${types}" == "deb" ]] || die "sources Types 非法"
  [[ "${uris}" == "${expected_uri}" ]] || die "sources URIs 未锚定当前站点/软件"
  [[ "${suites}" == "${series}" ]] || die "sources Suites 不匹配"
  [[ "${components}" == "main" ]] || die "sources Components 非法"
  [[ "${signed_by}" == "/etc/apt/keyrings/apt-hub.gpg" ]] || die "sources Signed-By 必须是专用 keyring 路径"
  [[ -n "${archs}" ]] || die "sources 缺少 Architectures"
  printf '%s\n' "${archs}" | tr ' ' '\n' | grep -qx -- "${arch}" \
    || die "sources 不支持架构 ${arch}"
  local n_types n_uris
  n_types="$(grep -c '^Types:' "${file}" || true)"
  n_uris="$(grep -c '^URIs:' "${file}" || true)"
  [[ "${n_types}" -eq 1 && "${n_uris}" -eq 1 ]] || die "sources 含重复/注入条目"
  if grep -qiE 'trusted\s*=\s*yes|Signed-By:\s*/etc/apt/trusted' "${file}"; then
    die "sources 试图使用全局 trusted"
  fi
}

write_final_sources() {
  local downloaded="$1" dest="$2" signed_by="$3"
  local types uris suites components archs
  types="$(awk -F': ' '$1=="Types"{print $2; exit}' "${downloaded}")"
  uris="$(awk -F': ' '$1=="URIs"{print $2; exit}' "${downloaded}")"
  suites="$(awk -F': ' '$1=="Suites"{print $2; exit}' "${downloaded}")"
  components="$(awk -F': ' '$1=="Components"{print $2; exit}' "${downloaded}")"
  archs="$(awk -F': ' '$1=="Architectures"{print $2; exit}' "${downloaded}")"
  cat >"${dest}" <<EOF
Types: ${types}
URIs: ${uris}
Suites: ${suites}
Components: ${components}
Signed-By: ${signed_by}
Architectures: ${archs}
EOF
  chmod 0644 -- "${dest}"
}

atomic_install_file() {
  local src="$1" dest="$2" mode="$3"
  local dir base tmp
  dir="$(dirname -- "${dest}")"
  base="$(basename -- "${dest}")"
  [[ -d "${dir}" && ! -L "${dir}" ]] || return 1
  local prefix="/" part
  IFS=/ read -r -a parts <<< "${dir#/}"
  for part in "${parts[@]}"; do
    [[ -n "${part}" ]] || continue
    prefix="${prefix%/}/${part}"
    [[ ! -L "${prefix}" ]] || return 1
  done
  if [[ -e "${dest}" || -L "${dest}" ]]; then
    [[ -f "${dest}" && ! -L "${dest}" ]] || return 1
  fi
  tmp="${dir}/.${base}.apthub-new.$$"
  [[ ! -e "${tmp}" && ! -L "${tmp}" ]] || return 1
  cp -f -- "${src}" "${tmp}" || { rm -f -- "${tmp}"; return 1; }
  chmod "${mode}" -- "${tmp}" || { rm -f -- "${tmp}"; return 1; }
  mv -f -- "${tmp}" "${dest}" || { rm -f -- "${tmp}"; return 1; }
  return 0
}

rollback_created() {
  local key_path="$1" sources_path="$2"
  if [[ "${created_sources}" -eq 1 && -f "${sources_path}" && ! -L "${sources_path}" ]]; then
    rm -f -- "${sources_path}"
    created_sources=0
  fi
  if [[ "${created_key}" -eq 1 && -f "${key_path}" && ! -L "${key_path}" ]]; then
    rm -f -- "${key_path}"
    created_key=0
  fi
}

# shellcheck disable=SC2317 # 提交失败路径调用
restore_replaced_key() {
  if [[ "${replaced_key}" -eq 1 && -n "${scratch}" && -f "${scratch}/apt-hub.gpg.backup" && ! -L "${scratch}/apt-hub.gpg.backup" ]]; then
    if atomic_install_file "${scratch}/apt-hub.gpg.backup" "${key_path}" "${key_backup_mode}"; then
      replaced_key=0
      return 0
    fi
    return 1
  fi
  return 0
}

# 无写入预检目录目的：已存在组件无 symlink 且为目录；缺失叶允许。
preflight_dest_dir() {
  local dir="$1"
  local prefix="/" part
  [[ "${dir}" == /* ]] || die "目录必须是绝对路径: ${dir}"
  IFS=/ read -r -a parts <<< "${dir#/}"
  for part in "${parts[@]}"; do
    [[ -n "${part}" ]] || continue
    prefix="${prefix%/}/${part}"
    if [[ -L "${prefix}" ]]; then
      die "路径含符号链接: ${prefix}"
    fi
    if [[ -e "${prefix}" ]]; then
      [[ -d "${prefix}" ]] || die "路径组件不是目录: ${prefix}"
    else
      return 0
    fi
  done
}

# 无写入预检文件目的：祖先目录合法；叶不得为 symlink；已存在则须为普通文件。
preflight_dest_file() {
  local file="$1" symlink_msg="$2"
  local prefix="/" part
  local -a parts
  local i n last j
  [[ "${file}" == /* ]] || die "路径必须是绝对路径: ${file}"
  IFS=/ read -r -a parts <<< "${file#/}"
  n="${#parts[@]}"
  for ((i = 0; i < n; i++)); do
    part="${parts[i]}"
    [[ -n "${part}" ]] || continue
    prefix="${prefix%/}/${part}"
    last=1
    for ((j = i + 1; j < n; j++)); do
      if [[ -n "${parts[j]}" ]]; then
        last=0
        break
      fi
    done
    if [[ "${last}" -eq 1 ]]; then
      [[ ! -L "${prefix}" ]] || die "${symlink_msg}"
      if [[ -e "${prefix}" ]]; then
        [[ -f "${prefix}" ]] || die "目的文件路径类型非法: ${prefix}"
      fi
      return 0
    fi
    if [[ -L "${prefix}" ]]; then
      die "路径含符号链接: ${prefix}"
    fi
    if [[ -e "${prefix}" ]]; then
      [[ -d "${prefix}" ]] || die "路径组件不是目录: ${prefix}"
    else
      return 0
    fi
  done
}

preflight_all_dest_paths() {
  local key_dir="$1" sources_dir="$2" key_path="$3" sources_path="$4" lock_file="$5"
  preflight_dest_dir "${key_dir}"
  preflight_dest_dir "${sources_dir}"
  preflight_dest_file "${key_path}" "公钥路径是符号链接"
  preflight_dest_file "${sources_path}" "sources 路径是符号链接"
  preflight_dest_file "${lock_file}" "lock 不能是符号链接"
}

# 先验全部已存在祖先无 symlink，再逐级创建缺失目录；不对已有目录 chmod。
ensure_leaf_dir() {
  local dir="$1"
  local prefix="/" part
  local missing=0
  [[ "${dir}" == /* ]] || die "目录必须是绝对路径: ${dir}"
  IFS=/ read -r -a parts <<< "${dir#/}"
  for part in "${parts[@]}"; do
    [[ -n "${part}" ]] || continue
    prefix="${prefix%/}/${part}"
    if [[ "${missing}" -eq 0 ]]; then
      if [[ -L "${prefix}" ]]; then
        die "路径含符号链接: ${prefix}"
      fi
      if [[ -e "${prefix}" ]]; then
        [[ -d "${prefix}" ]] || die "路径组件不是目录: ${prefix}"
        continue
      fi
      missing=1
    fi
    mkdir -- "${prefix}" || die "创建目录失败: ${prefix}"
    chmod 0755 -- "${prefix}"
  done
}

# ---- args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-url)
      [[ $# -ge 2 ]] || usage
      site_url="$2"; shift 2 ;;
    --software)
      [[ $# -ge 2 ]] || usage
      software_id="$2"; shift 2 ;;
    --root)
      [[ $# -ge 2 ]] || usage
      root_arg="$2"; shift 2 ;;
    --architecture)
      [[ $# -ge 2 ]] || usage
      architecture="$2"; shift 2 ;;
    --cacert)
      [[ $# -ge 2 ]] || usage
      cacert="$2"; shift 2 ;;
    --replace-key)
      [[ $# -ge 2 ]] || usage
      replace_key_fpr="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      die "未知参数: $1" ;;
  esac
done

[[ -n "${site_url}" && -n "${software_id}" ]] || usage
require_cmd bash curl gpg gpgv flock dpkg date awk sed grep tr chmod mkdir mv cp rm realpath sha256sum id readlink head stat

site_url="$(assert_site_url "${site_url}")"
software_id="$(assert_software_id "${software_id}")"
if [[ -n "${replace_key_fpr}" ]]; then
  replace_key_fpr="$(strip_fp "${replace_key_fpr}")"
  [[ "${replace_key_fpr}" =~ ^[A-F0-9]{40}$ ]] || die "--replace-key 必须是 40 位十六进制完整指纹"
fi
resolve_target_root
resolve_identity

if [[ -n "${cacert}" ]]; then
  [[ "${isolated}" -eq 1 ]] || die "--cacert 仅允许隔离根"
  cacert="$(make_abs_unresolved "${cacert}")"
  [[ -f "${cacert}" && ! -L "${cacert}" ]] || die "--cacert 必须是普通文件"
  assert_no_symlink_components "${cacert}"
  cacert="$(realpath -e -- "${cacert}")"
fi

key_dir="${target_root}/etc/apt/keyrings"
sources_dir="${target_root}/etc/apt/sources.list.d"
key_path="${key_dir}/apt-hub.gpg"
sources_path="${sources_dir}/apt-hub-${software_id}.sources"
# 同根一把锁：覆盖共享 apt-hub.gpg，不同 software 串行
lock_file="${key_dir}/.apt-hub-add-source.lock"
if [[ "${isolated}" -eq 1 ]]; then
  signed_by_final="${key_path}"
else
  signed_by_final="/etc/apt/keyrings/apt-hub.gpg"
fi

# 全部目的路径无写入预检通过后，再 mkdir / 开锁
preflight_all_dest_paths "${key_dir}" "${sources_dir}" "${key_path}" "${sources_path}" "${lock_file}"
ensure_leaf_dir "${key_dir}"
ensure_leaf_dir "${sources_dir}"
exec 9>>"${lock_file}"
lock_fd=9
flock 9 || die "无法取得加源锁"
# 拿锁后复查，避免协作竞争下路径被替换
preflight_all_dest_paths "${key_dir}" "${sources_dir}" "${key_path}" "${sources_path}" "${lock_file}"

if [[ -n "${PROJECT_TMP}" ]]; then
  mkdir -p -- "${PROJECT_TMP}/add-source-fix"
  scratch="$(mktemp -d -- "${PROJECT_TMP}/add-source-fix/scratch.XXXXXX")"
else
  scratch="$(mktemp -d -- "${key_dir}/.apt-hub-scratch.XXXXXX")"
fi
scratch_owned=1
chmod 0700 -- "${scratch}"

expected_uri="mirror+${site_url}/repos/${software_id}/mirror.list"
base="${site_url}/repos/${software_id}"

curl_get "${site_url}/apt-hub.gpg" "${scratch}/apt-hub.gpg" \
  || die "下载公钥失败"
curl_get "${base}/${series}.sources" "${scratch}/${series}.sources" \
  || die "下载 ${series}.sources 失败（可能不支持当前 Ubuntu 代号）"
curl_get "${base}/dists/${series}/InRelease" "${scratch}/InRelease" \
  || die "下载 InRelease 失败"

dearmor_key_to "${scratch}/apt-hub.gpg" "${scratch}/trusted.gpg"
verify_inrelease "${scratch}/trusted.gpg" "${scratch}/InRelease" \
  "${scratch}/Release.body" "${scratch}/gpg.status"
check_release_body "${scratch}/Release.body"
validate_sources_file "${scratch}/${series}.sources" "${expected_uri}"

pkg_hash="$(packages_hash_from_release "${scratch}/Release.body" "${arch}")"
[[ -n "${pkg_hash}" && "${pkg_hash}" =~ ^[a-f0-9]{64}$ ]] \
  || die "Release 缺少当前架构 Packages SHA256"
curl_get "${base}/dists/${series}/main/binary-${arch}/Packages" "${scratch}/Packages" \
  || die "下载 Packages 失败"
got_hash="$(sha256sum -- "${scratch}/Packages" | awk '{print $1}')"
[[ "${got_hash}" == "${pkg_hash}" ]] || die "Packages 摘要与已签名 Release 不符"

package_name="$(awk -F': ' '$1=="Package"{print $2; exit}' "${scratch}/Packages")"
[[ -n "${package_name}" ]] || die "已签名 Packages 中无 Package 字段"

write_final_sources "${scratch}/${series}.sources" "${scratch}/final.sources" "${signed_by_final}"
cp -f -- "${scratch}/trusted.gpg" "${scratch}/final.gpg"
chmod 0644 -- "${scratch}/final.gpg" "${scratch}/final.sources"

new_fpr="$(strip_fp "$(public_key_fingerprint "${scratch}/final.gpg")")"
[[ "${new_fpr}" =~ ^[A-F0-9]{40}$ ]] || die "无法读取下载公钥指纹"
assert_unique_primary_fingerprint "${scratch}/final.gpg" "${new_fpr}"
if [[ -n "${replace_key_fpr}" ]]; then
  [[ "${new_fpr}" == "${replace_key_fpr}" ]] \
    || die "下载公钥指纹与 --replace-key 不符: 下载=${new_fpr} 指定=${replace_key_fpr}"
fi

replacing_key=0
if [[ -f "${key_path}" && ! -L "${key_path}" ]]; then
  old_fpr="$(strip_fp "$(public_key_fingerprint "${key_path}")")"
  [[ "${old_fpr}" =~ ^[A-F0-9]{40}$ ]] || die "无法读取已有公钥指纹"
  if [[ "${old_fpr}" != "${new_fpr}" ]]; then
    if [[ -z "${replace_key_fpr}" ]]; then
      die "拒绝静默换钥/跨站点同名钥冲突: 已有=${old_fpr} 下载=${new_fpr}"
    fi
    replacing_key=1
  fi
fi

if [[ "${replacing_key}" -eq 1 ]]; then
  assert_shared_key_sources_same_site "${sources_dir}" "${site_url}"
fi

sources_missing=1
if [[ -f "${sources_path}" && ! -L "${sources_path}" ]]; then
  sources_missing=0
  if cmp -s -- "${sources_path}" "${scratch}/final.sources"; then
    if [[ -f "${key_path}" ]] && cmp -s -- "${key_path}" "${scratch}/final.gpg"; then
      printf '已添加（幂等）: %s\n' "${sources_path}"
      printf '下一步: apt update && apt install %s\n' "${package_name}"
      success=1
      exit 0
    fi
  else
    die "已有冲突源，拒绝覆盖: ${sources_path}"
  fi
fi

if [[ ! -f "${key_path}" ]]; then
  if ! atomic_install_file "${scratch}/final.gpg" "${key_path}" 0644; then
    rollback_created "${key_path}" "${sources_path}"
    die "写入公钥失败"
  fi
  created_key=1
elif cmp -s -- "${key_path}" "${scratch}/final.gpg"; then
  :
elif [[ "${replacing_key}" -eq 1 ]]; then
  key_backup_mode="$(stat -c '%a' "${key_path}")"
  [[ "${key_backup_mode}" =~ ^[0-7]{3,4}$ ]] || die "无法读取已有公钥权限"
  cp -f -- "${key_path}" "${scratch}/apt-hub.gpg.backup" || die "备份已有公钥失败"
  chmod -- "${key_backup_mode}" "${scratch}/apt-hub.gpg.backup" || die "备份公钥权限失败"
  if ! atomic_install_file "${scratch}/final.gpg" "${key_path}" "${key_backup_mode}"; then
    die "替换公钥失败"
  fi
  replaced_key=1
else
  die "已有公钥指纹相同但内容不同，拒绝覆盖"
fi

if [[ "${sources_missing}" -eq 1 ]] || ! cmp -s -- "${sources_path}" "${scratch}/final.sources"; then
  if ! atomic_install_file "${scratch}/final.sources" "${sources_path}" 0644; then
    if [[ "${replaced_key}" -eq 1 ]]; then
      restore_replaced_key || true
    fi
    rollback_created "${key_path}" "${sources_path}"
    die "写入 sources 失败（已回滚本次写入）"
  fi
  created_sources=1
fi

printf '已添加: %s\n' "${sources_path}"
printf '下一步: apt update && apt install %s\n' "${package_name}"
success=1
exit 0
