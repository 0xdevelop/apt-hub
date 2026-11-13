#!/usr/bin/env bash
# 一次加源：默认同站全部适用源；--software 仍加单个。验签后写入目标根，之后走普通 apt。
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
created_source_paths=()
sources_path=""
replaced_key=0
key_backup_mode=""
retain_scratch_for_backup=0
# SIGKILL 不可拦截，不保证该信号下原子回滚；INT/TERM/EXIT 可处理。

die() {
  printf 'add_source.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法: add_source.sh --site-url <https站点URL> [--software <软件id>] [--root <已存在隔离根>] [--architecture <架构>] [--cacert <仅隔离根>] [--replace-key <新公钥完整40hex指纹>]
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
  # 仍持锁时处理未提交写入；成功路径不回滚。
  if [[ "${success}" -ne 1 ]]; then
    if [[ "${#created_source_paths[@]}" -gt 0 ]]; then
      local created_path
      for created_path in "${created_source_paths[@]}"; do
        if [[ -n "${created_path}" && -f "${created_path}" && ! -L "${created_path}" ]]; then
          rm -f -- "${created_path}"
        fi
      done
      created_source_paths=()
    fi
    if [[ "${replaced_key}" -eq 1 ]]; then
      if restore_replaced_key; then
        printf 'add_source.sh: 已恢复旧公钥: %s\n' "${key_path}" >&2
      else
        printf 'add_source.sh: 恢复旧公钥失败，备份保留于 %s\n' \
          "${scratch}/apt-hub.gpg.backup" >&2
        retain_scratch_for_backup=1
        if [[ "${rc}" -eq 0 ]]; then
          rc=1
        fi
      fi
    elif [[ "${created_key}" -eq 1 && -n "${key_path}" && -f "${key_path}" && ! -L "${key_path}" ]]; then
      rm -f -- "${key_path}"
      created_key=0
    fi
  fi
  if [[ -n "${lock_fd}" ]]; then
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
    lock_fd=""
  fi
  if [[ "${retain_scratch_for_backup}" -eq 0 \
     && "${scratch_owned}" -eq 1 && -n "${scratch}" && -d "${scratch}" && ! -L "${scratch}" ]]; then
    rm -rf -- "${scratch}"
    scratch_owned=0
  elif [[ "${retain_scratch_for_backup}" -eq 1 && -n "${scratch}" && -d "${scratch}" && ! -L "${scratch}" ]]; then
    chmod 0700 -- "${scratch}" 2>/dev/null || true
    scratch_owned=0
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
trap 'exit 130' INT
trap 'exit 143' TERM

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

# 单 URI 必须精确为 mirror+<site>/repos/<software_id>/mirror.list。
assert_apt_hub_mirror_uri_same_site() {
  local uri="$1" site="$2"
  local prefix="mirror+${site}/repos/"
  local suffix="/mirror.list"
  local mid
  case "${uri}" in
    "${prefix}"*"${suffix}")
      mid="${uri#"${prefix}"}"
      mid="${mid%"${suffix}"}"
      [[ "${mid}" =~ ${SOFTWARE_ID_RE} ]] || return 1
      [[ "${uri}" == "${prefix}${mid}${suffix}" ]] || return 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Signed-By 是否引用本脚本专用 keyring（精确路径，防后缀误判）。
is_apt_hub_signed_by_path() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  if [[ "${p}" == "/etc/apt/keyrings/apt-hub.gpg" ]]; then
    return 0
  fi
  [[ -n "${key_path}" && "${p}" == "${key_path}" ]]
}

# 共享专用 keyring 的 apt-hub-*.sources：逐 stanza 解析全部 Signed-By/URIs（含续行）。
assert_shared_key_sources_same_site() {
  local sources_dir="$1" site="$2"
  local f parsed kind val uri
  local stanza_ours=0
  local -a stanza_uris=()
  shopt -s nullglob
  for f in "${sources_dir}"/apt-hub-*.sources; do
    if [[ -L "${f}" ]]; then
      die "共享源路径是符号链接，拒绝静默跳过: ${f}"
    fi
    [[ -f "${f}" ]] || continue
    parsed="$(awk '
      function trim(s) {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
      }
      function emit_tokens(kind, s, n, a, i) {
        n = split(s, a, /[ \t]+/)
        for (i = 1; i <= n; i++) {
          if (a[i] != "") print kind "\t" a[i]
        }
      }
      function end_field() {
        # Deb822 字段名大小写不敏感；Signed-By 可含多绝对路径/指纹 token。
        if (cur == "signed-by") emit_tokens("SB", trim(val))
        else if (cur == "uris") emit_tokens("URI", trim(val))
        cur = ""
        val = ""
      }
      function end_stanza() {
        end_field()
        print "END"
      }
      {
        sub(/\r$/, "")
      }
      /^#/ {
        # 合法整行注释：跳过且保持当前字段续行状态
        next
      }
      /^[ \t]/ {
        if (cur != "") {
          line = $0
          sub(/^[ \t]+/, "", line)
          if (val != "") val = val " " line
          else val = line
        }
        next
      }
      /^$/ {
        end_stanza()
        next
      }
      {
        end_field()
        idx = index($0, ":")
        if (idx > 0) {
          cur = tolower(substr($0, 1, idx - 1))
          val = substr($0, idx + 1)
          sub(/^[ \t]+/, "", val)
        } else {
          cur = ""
          val = ""
        }
        next
      }
      END { end_stanza() }
    ' "${f}")" || die "解析 sources 失败: ${f}"

    stanza_ours=0
    stanza_uris=()
    while IFS=$'\t' read -r kind val || [[ -n "${kind}" ]]; do
      [[ -n "${kind}" ]] || continue
      case "${kind}" in
        SB)
          if is_apt_hub_signed_by_path "${val}"; then
            stanza_ours=1
          fi
          ;;
        URI)
          stanza_uris+=("${val}")
          ;;
        END)
          if [[ "${stanza_ours}" -eq 1 ]]; then
            if [[ "${#stanza_uris[@]}" -eq 0 ]]; then
              die "共享钥源缺少 URIs: ${f}"
            fi
            for uri in "${stanza_uris[@]}"; do
              assert_apt_hub_mirror_uri_same_site "${uri}" "${site}" \
                || die "共享钥的其他源不属于同一站点: ${f}"
            done
          fi
          stanza_ours=0
          stanza_uris=()
          ;;
      esac
    done <<<"${parsed}"
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

# 调用前须已完成指纹比对与冲突拒绝。key_backup_mode 保持全局，供 cleanup 恢复。
install_final_key() {
  if [[ ! -f "${key_path}" ]]; then
    created_key=1
    if ! atomic_install_file "${scratch}/final.gpg" "${key_path}" 0644; then
      created_key=0
      die "写入公钥失败"
    fi
  elif cmp -s -- "${key_path}" "${scratch}/final.gpg"; then
    :
  elif [[ "${replacing_key}" -eq 1 ]]; then
    key_backup_mode="$(stat -c '%a' "${key_path}")"
    [[ "${key_backup_mode}" =~ ^[0-7]{3,4}$ ]] || die "无法读取已有公钥权限"
    cp -f -- "${key_path}" "${scratch}/apt-hub.gpg.backup" || die "备份已有公钥失败"
    chmod -- "${key_backup_mode}" "${scratch}/apt-hub.gpg.backup" || die "备份公钥权限失败"
    replaced_key=1
    if ! atomic_install_file "${scratch}/final.gpg" "${key_path}" "${key_backup_mode}"; then
      die "替换公钥失败"
    fi
  else
    die "已有公钥指纹相同但内容不同，拒绝覆盖"
  fi
}

# shellcheck disable=SC2317 # EXIT/INT/TERM cleanup 与失败路径调用
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

# 聚合 Deb822：只接受锚定本站的 stanza，验完全部适用项后再提交。
add_all_applicable_sources() {
  local agg="${scratch}/aggregate.sources"
  local stanza_dir="${scratch}/stanzas"
  local stanza_count=0 stanza_i=0 stanza_file
  local types uris suites components signed_by archs id path pkg
  local prefix suffix id_base pkg_hash got_hash new_fpr old_fpr
  local all_same=1 install_line="" seen_file="${scratch}/seen-ids"
  local -a applicable_ids=() applicable_pkgs=() applicable_paths=() applicable_stanzas=()
  mkdir -p -- "${stanza_dir}"
  : >"${seen_file}"
  curl_get "${site_url}/apt-hub.gpg" "${scratch}/apt-hub.gpg" || die "下载公钥失败"
  curl_get "${site_url}/repos/${series}.sources" "${agg}" || die "下载聚合 sources 失败"
  dearmor_key_to "${scratch}/apt-hub.gpg" "${scratch}/trusted.gpg"
  stanza_count="$(awk -v dir="${stanza_dir}" '
    function flush() {
      if (nlines == 0) return
      n++
      path = dir "/stanza-" n
      for (i = 1; i <= nlines; i++) print lines[i] > path
      close(path)
      nlines = 0
    }
    /^[[:space:]]*$/ { flush(); next }
    { nlines++; lines[nlines] = $0 }
    END { flush(); printf "%d\n", n + 0 }
  ' "${agg}")"
  [[ "${stanza_count}" =~ ^[0-9]+$ ]] || die "聚合 sources 格式未知"
  stanza_i=1
  while [[ "${stanza_i}" -le "${stanza_count}" ]]; do
    stanza_file="${stanza_dir}/stanza-${stanza_i}"
    awk -F': ' '
      NF < 2 || $1 ~ /[[:space:]]/ { exit 2 }
      {
        if ($1!="Types" && $1!="URIs" && $1!="Suites" && $1!="Components" && $1!="Signed-By" && $1!="Architectures") exit 3
        seen[$1]++
        if (seen[$1] != 1) exit 5
      }
      END {
        if (NR == 0) exit 4
        n = 0
        for (k in seen) n++
        if (n != 6) exit 5
      }
    ' "${stanza_file}" || die "聚合 sources 格式未知"
    types="$(awk -F': ' '$1=="Types"{print $2; exit}' "${stanza_file}")"
    uris="$(awk -F': ' '$1=="URIs"{print $2; exit}' "${stanza_file}")"
    suites="$(awk -F': ' '$1=="Suites"{print $2; exit}' "${stanza_file}")"
    components="$(awk -F': ' '$1=="Components"{print $2; exit}' "${stanza_file}")"
    signed_by="$(awk -F': ' '$1=="Signed-By"{print $2; exit}' "${stanza_file}")"
    archs="$(awk -F': ' '$1=="Architectures"{print $2; exit}' "${stanza_file}")"
    [[ "${types}" == "deb" ]] || die "sources Types 非法"
    [[ "${components}" == "main" ]] || die "sources Components 非法"
    [[ "${signed_by}" == "/etc/apt/keyrings/apt-hub.gpg" ]] || die "sources Signed-By 必须是专用 keyring 路径"
    if grep -qiE 'trusted\s*=\s*yes|Signed-By:\s*/etc/apt/trusted' "${stanza_file}"; then
      die "sources 试图使用全局 trusted"
    fi
    prefix="mirror+${site_url}/repos/"
    suffix="/mirror.list"
    case "${uris}" in
      "${prefix}"*"${suffix}")
        id="${uris#"${prefix}"}"
        id="${id%"${suffix}"}"
        ;;
      *)
        die "sources URIs 未锚定当前站点/软件"
        ;;
    esac
    [[ "${id}" =~ ${SOFTWARE_ID_RE} && "${id}" != *..* && "${uris}" == "${prefix}${id}${suffix}" ]] \
      || die "software id 非法: ${id}"
    if grep -Fxq -- "${id}" "${seen_file}"; then
      die "聚合 sources id 重复: ${id}"
    fi
    printf '%s\n' "${id}" >>"${seen_file}"
    [[ "${suites}" == "${series}" ]] || die "sources Suites 不匹配"
    if ! printf '%s\n' "${archs}" | tr ' ' '\n' | grep -qx -- "${arch}"; then
      printf '跳过不适用架构: %s\n' "${id}" >&2
      stanza_i=$((stanza_i + 1))
      continue
    fi
    path="${sources_dir}/apt-hub-${id}.sources"
    preflight_dest_file "${path}" "sources 路径是符号链接"
    applicable_ids+=("${id}")
    applicable_paths+=("${path}")
    applicable_stanzas+=("${stanza_file}")
    stanza_i=$((stanza_i + 1))
  done
  [[ "${#applicable_ids[@]}" -gt 0 ]] || die "没有适用于当前系列/架构的源"

  stanza_i=0
  while [[ "${stanza_i}" -lt "${#applicable_ids[@]}" ]]; do
    id="${applicable_ids[${stanza_i}]}"
    stanza_file="${applicable_stanzas[${stanza_i}]}"
    id_base="${site_url}/repos/${id}"
    mkdir -p -- "${scratch}/ids/${id}"
    curl_get "${id_base}/dists/${series}/InRelease" "${scratch}/ids/${id}/InRelease" \
      || die "下载 InRelease 失败"
    verify_inrelease "${scratch}/trusted.gpg" "${scratch}/ids/${id}/InRelease" \
      "${scratch}/ids/${id}/Release.body" "${scratch}/ids/${id}/gpg.status"
    check_release_body "${scratch}/ids/${id}/Release.body"
    validate_sources_file "${stanza_file}" "mirror+${site_url}/repos/${id}/mirror.list"
    pkg_hash="$(packages_hash_from_release "${scratch}/ids/${id}/Release.body" "${arch}")"
    [[ -n "${pkg_hash}" && "${pkg_hash}" =~ ^[a-f0-9]{64}$ ]] \
      || die "Release 缺少当前架构 Packages SHA256"
    curl_get "${id_base}/dists/${series}/main/binary-${arch}/Packages" "${scratch}/ids/${id}/Packages" \
      || die "下载 Packages 失败"
    got_hash="$(sha256sum -- "${scratch}/ids/${id}/Packages" | awk '{print $1}')"
    [[ "${got_hash}" == "${pkg_hash}" ]] || die "Packages 摘要与已签名 Release 不符"
    pkg="$(awk -F': ' '$1=="Package"{print $2; exit}' "${scratch}/ids/${id}/Packages")"
    [[ -n "${pkg}" ]] || die "已签名 Packages 中无 Package 字段"
    write_final_sources "${stanza_file}" "${scratch}/ids/${id}/final.sources" "${signed_by_final}"
    applicable_pkgs+=("${pkg}")
    stanza_i=$((stanza_i + 1))
  done

  cp -f -- "${scratch}/trusted.gpg" "${scratch}/final.gpg"
  chmod 0644 -- "${scratch}/final.gpg"
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

  stanza_i=0
  while [[ "${stanza_i}" -lt "${#applicable_ids[@]}" ]]; do
    path="${applicable_paths[${stanza_i}]}"
    id="${applicable_ids[${stanza_i}]}"
    if [[ -f "${path}" && ! -L "${path}" ]]; then
      if ! cmp -s -- "${path}" "${scratch}/ids/${id}/final.sources"; then
        die "已有冲突源，拒绝覆盖: ${path}"
      fi
    else
      all_same=0
    fi
    stanza_i=$((stanza_i + 1))
  done
  if [[ "${all_same}" -eq 1 && -f "${key_path}" ]] && cmp -s -- "${key_path}" "${scratch}/final.gpg"; then
    stanza_i=0
    while [[ "${stanza_i}" -lt "${#applicable_paths[@]}" ]]; do
      printf '已添加（幂等）: %s\n' "${applicable_paths[${stanza_i}]}"
      stanza_i=$((stanza_i + 1))
    done
    for pkg in "${applicable_pkgs[@]}"; do
      install_line="${install_line}${install_line:+ }${pkg}"
    done
    printf '下一步: apt update && apt install %s\n' "${install_line}"
    success=1
    exit 0
  fi

  install_final_key
  stanza_i=0
  while [[ "${stanza_i}" -lt "${#applicable_ids[@]}" ]]; do
    path="${applicable_paths[${stanza_i}]}"
    id="${applicable_ids[${stanza_i}]}"
    if [[ ! -f "${path}" ]] || ! cmp -s -- "${path}" "${scratch}/ids/${id}/final.sources"; then
      created_source_paths+=("${path}")
      if ! atomic_install_file "${scratch}/ids/${id}/final.sources" "${path}" 0644; then
        die "写入 sources 失败"
      fi
    fi
    stanza_i=$((stanza_i + 1))
  done
  stanza_i=0
  while [[ "${stanza_i}" -lt "${#applicable_paths[@]}" ]]; do
    printf '已添加: %s\n' "${applicable_paths[${stanza_i}]}"
    stanza_i=$((stanza_i + 1))
  done
  for pkg in "${applicable_pkgs[@]}"; do
    install_line="${install_line}${install_line:+ }${pkg}"
  done
  printf '下一步: apt update && apt install %s\n' "${install_line}"
  success=1
  exit 0
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

[[ -n "${site_url}" ]] || usage
require_cmd bash curl gpg gpgv flock dpkg date awk sed grep tr chmod mkdir mv cp rm realpath sha256sum id readlink head stat

site_url="$(assert_site_url "${site_url}")"
if [[ -n "${software_id}" ]]; then
  software_id="$(assert_software_id "${software_id}")"
fi
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
# 同根一把锁：覆盖共享 apt-hub.gpg，不同 software 串行
lock_file="${key_dir}/.apt-hub-add-source.lock"
if [[ "${isolated}" -eq 1 ]]; then
  signed_by_final="${key_path}"
else
  signed_by_final="/etc/apt/keyrings/apt-hub.gpg"
fi
if [[ -n "${software_id}" ]]; then
  sources_path="${sources_dir}/apt-hub-${software_id}.sources"
fi

# 全部目的路径无写入预检通过后，再 mkdir / 开锁
if [[ -n "${software_id}" ]]; then
  preflight_all_dest_paths "${key_dir}" "${sources_dir}" "${key_path}" "${sources_path}" "${lock_file}"
else
  preflight_dest_dir "${key_dir}"
  preflight_dest_dir "${sources_dir}"
  preflight_dest_file "${key_path}" "公钥路径是符号链接"
  preflight_dest_file "${lock_file}" "lock 不能是符号链接"
fi
ensure_leaf_dir "${key_dir}"
ensure_leaf_dir "${sources_dir}"
exec 9>>"${lock_file}"
lock_fd=9
flock 9 || die "无法取得加源锁"
# 拿锁后复查，避免协作竞争下路径被替换
if [[ -n "${software_id}" ]]; then
  preflight_all_dest_paths "${key_dir}" "${sources_dir}" "${key_path}" "${sources_path}" "${lock_file}"
else
  preflight_dest_dir "${key_dir}"
  preflight_dest_dir "${sources_dir}"
  preflight_dest_file "${key_path}" "公钥路径是符号链接"
  preflight_dest_file "${lock_file}" "lock 不能是符号链接"
fi

# scratch 祖先不得含 symlink；规范化后必须仍在 PROJECT_TMP 或 key_dir 内。
prepare_owned_scratch() {
  local parent parent_real root_real scratch_real
  if [[ -n "${PROJECT_TMP}" ]]; then
    root_real="$(realpath -e -- "${PROJECT_TMP}")"
    [[ -d "${root_real}" && ! -L "${PROJECT_TMP}" ]] || die "项目 tmp 非法"
    assert_no_symlink_components "${root_real}"
    parent="${PROJECT_TMP}/add-source-run"
    if [[ -L "${parent}" ]]; then
      die "scratch 父目录是符号链接: ${parent}"
    fi
    if [[ -e "${parent}" ]]; then
      [[ -d "${parent}" && ! -L "${parent}" ]] || die "scratch 父路径类型非法: ${parent}"
      assert_no_symlink_components "${parent}"
    else
      mkdir -- "${parent}" || die "创建 scratch 父目录失败: ${parent}"
      chmod 0755 -- "${parent}"
    fi
    parent_real="$(realpath -e -- "${parent}")"
    under_dir "${root_real}" "${parent_real}" || die "scratch 父目录越出项目 tmp"
    assert_no_symlink_components "${parent_real}"
    scratch="$(mktemp -d -- "${parent_real}/scratch.XXXXXX")"
    scratch_real="$(realpath -e -- "${scratch}")"
    under_dir "${root_real}" "${scratch_real}" || die "scratch 越出项目 tmp"
    under_dir "${parent_real}" "${scratch_real}" || die "scratch 越出父目录"
  else
    root_real="$(realpath -e -- "${key_dir}")"
    [[ -d "${root_real}" && ! -L "${key_dir}" ]] || die "keyrings 目录非法"
    assert_no_symlink_components "${root_real}"
    scratch="$(mktemp -d -- "${root_real}/.apt-hub-scratch.XXXXXX")"
    scratch_real="$(realpath -e -- "${scratch}")"
    under_dir "${root_real}" "${scratch_real}" || die "scratch 越出 keyrings"
  fi
  scratch="${scratch_real}"
}
prepare_owned_scratch
scratch_owned=1
chmod 0700 -- "${scratch}"
if [[ -z "${software_id}" ]]; then
  add_all_applicable_sources
fi

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

install_final_key

if [[ "${sources_missing}" -eq 1 ]] || ! cmp -s -- "${sources_path}" "${scratch}/final.sources"; then
  # 标志先于 rename：TERM 落在 mv 成功后仍回滚本批新建文件
  created_source_paths+=("${sources_path}")
  if ! atomic_install_file "${scratch}/final.sources" "${sources_path}" 0644; then
    die "写入 sources 失败"
  fi
fi

printf '已添加: %s\n' "${sources_path}"
printf '下一步: apt update && apt install %s\n' "${package_name}"
success=1
exit 0
