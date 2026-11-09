#!/usr/bin/env bash
# 从官方 GitHub Releases 核验资产，生成每软件 repos/<id> 签名元数据（不含 deb）。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT_TMP="${PROJECT_ROOT}/tmp"
VALID_UNTIL_SECONDS=1209600
API_TIMEOUT=60
DOWNLOAD_TIMEOUT=600
CONNECT_TIMEOUT=20
ALLOWED_ARCHS='^(amd64|arm64)$'
HEX64='^[a-f0-9]{64}$'
SERIES_NAME='^[a-z][a-z0-9]*$'
REPO_NAME='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
PKG_NAME='^[a-z0-9][a-z0-9.+-]+$'
DATE_ISO='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
GITHUB_TAG='^[A-Za-z0-9._+-]+$'
SITE_URL_RE='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$'

catalog=""
releases=""
previous=""
output=""
gnupghome=""
fingerprint=""
site_url=""
work=""
scratch=""
work_owned=0
scratch_owned=0
success=0

die() {
  printf 'sync.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法: scripts/sync.sh --catalog <file> --releases <file> --previous <dir> --output <dir> --gnupghome <dir> --fingerprint <完整指纹> --site-url <https站点URL>
EOF
  exit 2
}

cleanup() {
  if [[ "${success}" -eq 1 ]]; then
    return
  fi
  if [[ "${work_owned}" -eq 1 && -n "${work}" && -d "${work}" && ! -L "${work}" ]]; then
    rm -rf -- "${work}"
  fi
  if [[ "${scratch_owned}" -eq 1 && -n "${scratch}" && -d "${scratch}" && ! -L "${scratch}" ]]; then
    rm -rf -- "${scratch}"
  fi
}
trap cleanup EXIT

require_cmd() {
  local c
  for c in "$@"; do
    command -v -- "${c}" >/dev/null 2>&1 || die "缺少命令: ${c}"
  done
}

strip_fp() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

is_abs() {
  [[ "$1" == /* ]]
}

make_abs_unresolved() {
  local p="$1"
  [[ -n "${p}" ]] || die "空路径"
  if [[ "${p}" != /* ]]; then
    p="${PWD%/}/${p}"
  fi
  if [[ "${p}" != / ]]; then
    p="${p%/}"
  fi
  printf '%s\n' "${p}"
}

assert_no_symlink_components() {
  local path="$1"
  local prefix="" part
  [[ "${path}" == /* ]] || die "路径必须是绝对路径: ${path}"
  prefix="/"
  IFS=/ read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [[ -n "${part}" ]] || continue
    prefix="${prefix%/}/${part}"
    if [[ -L "${prefix}" ]]; then
      die "路径含符号链接: ${prefix}"
    fi
  done
}

is_system_path() {
  case "$1" in
    /|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/boot|/boot/*|/sys|/sys/*|/proc|/proc/*|/dev|/dev/*|/root|/root/*|/var|/var/*|/run|/run/*|/tmp|/tmp/*)
      return 0
      ;;
  esac
  return 1
}

under_dir() {
  local parent="$1" child="$2"
  [[ "${child}" == "${parent}" || "${child}" == "${parent}/"* ]]
}

assert_allowed_dir() {
  local role="$1" abs="$2" must_exist="$3"
  local parent base parent_abs

  [[ -n "${abs}" ]] || die "缺少 ${role} 路径"
  abs="$(make_abs_unresolved "${abs}")"
  if [[ "${must_exist}" == "yes" ]]; then
    [[ -e "${abs}" ]] || die "${role} 不存在: ${abs}"
    [[ -d "${abs}" ]] || die "${role} 不是目录: ${abs}"
    [[ ! -L "${abs}" ]] || die "${role} 不能是符号链接: ${abs}"
    assert_no_symlink_components "${abs}"
    abs="$(realpath -e -- "${abs}")"
  else
    parent="$(dirname -- "${abs}")"
    base="$(basename -- "${abs}")"
    [[ "${base}" != "." && "${base}" != ".." && "${base}" != "/" ]] || die "${role} 非法目录名"
    [[ -e "${parent}" ]] || die "${role} 父目录不存在: ${parent}"
    [[ -d "${parent}" ]] || die "${role} 父目录不是目录: ${parent}"
    [[ ! -L "${parent}" ]] || die "${role} 父目录不能是符号链接: ${parent}"
    assert_no_symlink_components "${parent}"
    if [[ -e "${abs}" || -L "${abs}" ]]; then
      [[ ! -L "${abs}" ]] || die "${role} 不能是符号链接: ${abs}"
      [[ -d "${abs}" ]] || die "${role} 已存在且不是目录: ${abs}"
      assert_no_symlink_components "${abs}"
    fi
    parent_abs="$(realpath -e -- "${parent}")"
    abs="${parent_abs}/${base}"
    if [[ -e "${abs}" || -L "${abs}" ]]; then
      [[ ! -L "${abs}" ]] || die "${role} 不能是符号链接: ${abs}"
      [[ -d "${abs}" ]] || die "${role} 已存在且不是目录: ${abs}"
    fi
  fi

  if under_dir "${PROJECT_ROOT}" "${abs}"; then
    under_dir "${PROJECT_TMP}" "${abs}" || die "${role} 在项目内时必须位于 tmp/ 下: ${abs}"
    [[ "${abs}" != "${PROJECT_ROOT}" && "${abs}" != "${PROJECT_TMP}" ]] || die "${role} 不能是项目根或 tmp 根: ${abs}"
  else
    is_system_path "${abs}" && die "${role} 拒绝系统路径: ${abs}"
    [[ "${abs}" != "${PROJECT_ROOT}" ]] || die "${role} 不能是项目根"
  fi
  printf '%s\n' "${abs}"
}

assert_allowed_file() {
  local role="$1" path="$2"
  local abs
  abs="$(make_abs_unresolved "${path}")"
  [[ -e "${abs}" ]] || die "${role} 不存在: ${abs}"
  [[ -f "${abs}" ]] || die "${role} 不是普通文件: ${abs}"
  [[ ! -L "${abs}" ]] || die "${role} 不能是符号链接: ${abs}"
  assert_no_symlink_components "${abs}"
  abs="$(realpath -e -- "${abs}")"
  printf '%s\n' "${abs}"
}

assert_no_overlap() {
  local a="$1" b="$2" msg="$3"
  if under_dir "${a}" "${b}" || under_dir "${b}" "${a}"; then
    die "${msg}"
  fi
}

dir_is_empty() {
  local d="$1"
  [[ -d "${d}" ]] || return 0
  [[ -z "$(find -- "${d}" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

hex_sha256() {
  sha256sum -- "$1" | awk '{print $1}'
}

file_size() {
  stat -c '%s' -- "$1"
}

assert_iso_date() {
  local d="$1" what="$2" canon
  [[ "${d}" =~ ${DATE_ISO} ]] || die "${what} 不是 YYYY-MM-DD: ${d}"
  canon="$(date -u -d "${d}" +%Y-%m-%d 2>/dev/null)" || die "${what} 非法日期: ${d}"
  [[ "${canon}" == "${d}" ]] || die "${what} 不是有效日历日: ${d}"
}

assert_origin_relative_filename() {
  local f="$1" role="${2:-filename}"
  [[ -n "${f}" ]] || die "${role} 为空"
  case "${f}" in
    *$'\n'*|*$'\r'*|*$'\t'*|*' '*) die "${role} 含非法空白" ;;
  esac
  [[ "${f}" != /* ]] || die "${role} 不能是绝对路径: ${f}"
  [[ "${f}" != *..* ]] || die "${role} 含 ..: ${f}"
  [[ "${f}" != *//* ]] || die "${role} 含空路径段: ${f}"
  [[ "${f}" != pool/* ]] || die "${role} 不能是旧 pool 路径: ${f}"
  [[ "${f}" == *.deb ]] || die "${role} 必须以 .deb 结尾: ${f}"
  [[ "${f}" =~ ^[A-Za-z0-9._~/-]+\.deb$ ]] || die "${role} 不是规范官方相对路径: ${f}"
}

# catalog / previous / consumer 同一 id 规则：ASCII 字母数字开头 + _.-，拒 .. 与路径分隔符
assert_safe_package_id() {
  local id="$1" role="${2:-id}"
  [[ -n "${id}" ]] || die "${role} 为空"
  case "${id}" in
    */*) die "非法 ${role}（含路径分隔符）: ${id}" ;;
  esac
  [[ "${id}" != *\\* ]] || die "非法 ${role}（含路径分隔符）: ${id}"
  [[ "${id}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "${id}" != *..* ]] \
    || die "非法 ${role}: ${id}"
}

assert_contained_repo_dir() {
  local repos_root="$1" id="$2" role="$3"
  local path resolved root_resolved
  assert_safe_package_id "${id}" "${role}"
  [[ -d "${repos_root}" && ! -L "${repos_root}" ]] || die "${role} repos 根非法"
  path="${repos_root}/${id}"
  [[ -e "${path}" || -L "${path}" ]] || die "${role} 缺少 repos/${id}"
  [[ ! -L "${path}" ]] || die "${role} repos/${id} 不能是符号链接"
  [[ -d "${path}" ]] || die "${role} repos/${id} 不是目录"
  if find -- "${path}" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit | grep -q .; then
    die "${role} repos/${id} 含符号链接或特殊文件"
  fi
  root_resolved="$(realpath -e -- "${repos_root}")"
  resolved="$(realpath -e -- "${path}")"
  under_dir "${root_resolved}" "${resolved}" || die "${role} repos/${id} 越出候选目录"
  [[ "${resolved}" != "${root_resolved}" ]] || die "${role} repos/${id} 不能是 repos 根"
}

assert_contained_repo_dest() {
  local repos_root="$1" id="$2" role="$3"
  local path root_resolved dest_resolved
  assert_safe_package_id "${id}" "${role}"
  mkdir -p -- "${repos_root}"
  [[ -d "${repos_root}" && ! -L "${repos_root}" ]] || die "${role} repos 根非法"
  path="${repos_root}/${id}"
  root_resolved="$(realpath -e -- "${repos_root}")"
  dest_resolved="$(realpath -m -- "${path}")"
  under_dir "${root_resolved}" "${dest_resolved}" || die "${role} 目标 repos/${id} 越出候选目录"
  [[ "${dest_resolved}" != "${root_resolved}" ]] || die "${role} 目标不能是 repos 根"
  if [[ -e "${path}" || -L "${path}" ]]; then
    [[ ! -L "${path}" ]] || die "${role} 目标不能是符号链接"
    [[ -d "${path}" ]] || die "${role} 目标已存在且不是目录"
    if find -- "${path}" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit | grep -q .; then
      die "${role} 目标含符号链接或特殊文件"
    fi
  fi
}

assert_retained_github_asset_url() {
  local repo="$1" url="$2"
  local prefix="https://github.com/${repo}/releases/download/"
  local rest tag name
  [[ "${url}" == "${prefix}"* ]] || die "存量 asset.url 未锚定仓库 ${repo}: ${url}"
  rest="${url#"${prefix}"}"
  [[ "${rest}" == */* ]] || die "存量 asset.url 缺少 tag/name: ${url}"
  tag="${rest%%/*}"
  name="${rest#*/}"
  [[ -n "${tag}" && -n "${name}" && "${name}" != */* ]] || die "存量 asset.url 非法: ${url}"
  assert_github_tag "${tag}"
  assert_github_asset_url "${repo}" "${tag}" "${name}" "${url}"
}

release_sha256_field() {
  local body="$1" relpath="$2" which="$3"
  awk -v f="${relpath}" -v want="${which}" '
    $1 == "SHA256:" { insha = 1; next }
    insha && NF >= 3 {
      path = $3
      sub(/^\.\//, "", path)
      if (path == f) {
        if (want == "hash") print $1
        else if (want == "size") print $2
        exit
      }
    }
    insha && NF == 0 { insha = 0 }
  ' "${body}"
}

retained_official_origin_from_state() {
  local prev_row="$1" repo_root="$2" id="$3"
  local repo asset_count origin="" asset arch filename sha size url
  local series_dir packages found this_origin pkg_fn pkg_sz pkg_arch stanza url_rel
  repo="$(jq -r '.repository // empty' <<<"${prev_row}")"
  [[ "${repo}" =~ ${REPO_NAME} ]] || die "存量 ${id} repository 非法"
  asset_count="$(jq '(.assets // []) | length' <<<"${prev_row}")"
  [[ "${asset_count}" =~ ^[1-9][0-9]*$ ]] || die "存量 ${id} assets 为空"
  [[ -n "${scratch}" && -d "${scratch}" ]] || die "存量 ${id} 缺少 scratch"
  while IFS= read -r asset; do
    arch="$(jq -r '.architecture // empty' <<<"${asset}")"
    filename="$(jq -r '.filename // empty' <<<"${asset}")"
    sha="$(jq -r '.sha256 // empty' <<<"${asset}")"
    size="$(jq -r '((.size|tostring) // empty)' <<<"${asset}")"
    url="$(jq -r '.url // empty' <<<"${asset}")"
    [[ "${arch}" =~ ${ALLOWED_ARCHS} ]] || die "存量 ${id} architecture 非法"
    [[ "${sha}" =~ ${HEX64} ]] || die "存量 ${id} sha256 非法"
    [[ "${size}" =~ ^[1-9][0-9]*$ ]] || die "存量 ${id} size 非法"
    assert_origin_relative_filename "${filename}" "存量 filename"
    assert_retained_github_asset_url "${repo}" "${url}"
    this_origin="$(https_origin_of "${url}")"
    [[ "${this_origin}" == "https://github.com" ]] || die "存量 ${id} 官方 origin 非 GitHub: ${this_origin}"
    if [[ -z "${origin}" ]]; then
      origin="${this_origin}"
    else
      [[ "${origin}" == "${this_origin}" ]] || die "存量 ${id} 多 host 官方 origin"
    fi
    found=0
    stanza="${scratch}/retained-stanza-${id}-${arch}.txt"
    while IFS= read -r -d '' series_dir; do
      packages="${series_dir}/main/binary-${arch}/Packages"
      [[ -f "${packages}" && ! -L "${packages}" ]] || continue
      if extract_packages_stanza_by_sha "${packages}" "${sha}" >"${stanza}"; then
        pkg_fn="$(control_field "${stanza}" Filename)"
        pkg_sz="$(control_field "${stanza}" Size)"
        pkg_arch="$(control_field "${stanza}" Architecture)"
        [[ "${pkg_fn}" == "${filename}" ]] || die "存量 ${id} Filename 与签名 Packages 不符"
        [[ "${pkg_sz}" == "${size}" ]] || die "存量 ${id} Size 与签名 Packages 不符"
        [[ "${pkg_arch}" == "${arch}" ]] || die "存量 ${id} Architecture 与签名 Packages 不符"
        url_rel="$(origin_relative_path "${url}")"
        [[ "${url_rel}" == "${pkg_fn}" ]] || die "存量 ${id} asset.url 路径与签名 Packages Filename 不符"
        found=1
        break
      fi
    done < <(find -- "${repo_root}/dists" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    [[ "${found}" -eq 1 ]] || die "存量 ${id} 资产未出现在已签名 Packages: ${arch}"
  done < <(jq -c '.assets[]' <<<"${prev_row}")
  [[ -n "${origin}" ]] || die "存量 ${id} 无法派生官方 origin"
  printf '%s\n' "${origin}"
}

assert_retained_mirror_deb_origin() {
  local mirror_file="$1" expected_origin="$2" id="$3"
  local line url typ deb_count=0 index_count=0 deb_origin
  [[ -f "${mirror_file}" && ! -L "${mirror_file}" ]] || die "存量 ${id} 缺少 mirror.list"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    if [[ "${line}" != *$'\t'* ]]; then
      die "存量 ${id} mirror.list 含未标 type 的行"
    fi
    url="${line%%$'\t'*}"
    typ="${line#*$'\t'}"
    case "${typ}" in
      type:index)
        index_count=$((index_count + 1))
        [[ "${index_count}" -eq 1 ]] || die "存量 ${id} mirror.list 含多个 type:index"
        [[ "${url}" == https://* ]] || die "存量 ${id} type:index 非 https"
        ;;
      type:deb)
        deb_count=$((deb_count + 1))
        [[ "${deb_count}" -eq 1 ]] || die "存量 ${id} mirror.list 含多个 type:deb"
        deb_origin="${url%/}"
        [[ "${deb_origin}" == "${expected_origin}" ]] \
          || die "存量 ${id} type:deb origin 与官方资产不一致"
        ;;
      *)
        die "存量 ${id} mirror.list 含未知 type: ${typ}"
        ;;
    esac
  done <"${mirror_file}"
  [[ "${deb_count}" -eq 1 ]] || die "存量 ${id} mirror.list 缺少唯一 type:deb"
  [[ "${index_count}" -eq 1 ]] || die "存量 ${id} mirror.list 缺少唯一 type:index"
}

assert_github_tag() {
  local tag="$1"
  [[ "${tag}" =~ ${GITHUB_TAG} ]] || die "非法 tag_name: ${tag}"
}

assert_github_html_url() {
  local repo="$1" tag="$2" url="$3"
  local expected="https://github.com/${repo}/releases/tag/${tag}"
  [[ "${url}" == "${expected}" ]] || die "html_url 未锚定到清单仓库 release: ${url}"
}

assert_github_asset_url() {
  local repo="$1" tag="$2" name="$3" url="$4"
  [[ -n "${name}" && "${name}" != */* && "${name}" != *..* ]] || die "非法资产名: ${name}"
  case "${name}" in
    *$'\n'*|*$'\r'*|*$'\t'*|*' '*) die "非法资产名: ${name}" ;;
  esac
  local expected="https://github.com/${repo}/releases/download/${tag}/${name}"
  [[ "${url}" == "${expected}" ]] || die "browser_download_url 未锚定到清单仓库 asset: ${url}"
}

https_origin_of() {
  local url="$1" rest hostpath
  [[ "${url}" == https://* ]] || die "资产 URL 必须是 https: ${url}"
  rest="${url#https://}"
  hostpath="${rest%%/*}"
  [[ -n "${hostpath}" ]] || die "无法解析官方 origin: ${url}"
  printf 'https://%s\n' "${hostpath}"
}

origin_relative_path() {
  local url="$1" origin path
  origin="$(https_origin_of "${url}")"
  path="${url#"${origin}/"}"
  [[ "${path}" != "${url}" ]] || die "资产 URL 缺少 origin 相对路径: ${url}"
  assert_origin_relative_filename "${path}" "官方相对路径"
  printf '%s\n' "${path}"
}

assert_site_url() {
  local u="$1" host
  [[ -n "${u}" ]] || die "缺少 --site-url"
  [[ "${u}" =~ ${SITE_URL_RE} ]] || die "site-url 非法: ${u}"
  [[ "${u}" == https://* ]] || die "site-url 必须是 https: ${u}"
  host="${u#https://}"
  host="${host%%/*}"
  host="${host%%:*}"
  host="$(printf '%s' "${host}" | tr '[:upper:]' '[:lower:]')"
  case "${host}" in
    localhost|localhost.*|127.0.0.1|::1)
      die "site-url 拒绝 localhost: ${u}"
      ;;
  esac
  printf '%s\n' "${u%/}"
}

without_xtrace() {
  local xtrace_was=0
  case "${-}" in *x*) xtrace_was=1; set +x ;; esac
  "$@"
  local rc=$?
  if [[ "${xtrace_was}" -eq 1 ]]; then set -x; fi
  return "${rc}"
}

curl_https() {
  local timeout="$1"
  shift
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${timeout}" \
    --retry 2 --retry-delay 1 --max-redirs 5 \
    "$@"
}

github_get() {
  local url="$1"
  local headers=(
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
    -H 'User-Agent: apt-hub-sync'
  )
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl_https "${API_TIMEOUT}" "${headers[@]}" -- "${url}"
}

gpg_sign() {
  local in="$1" detach_out="$2" clear_out="$3"
  local args=(
    --homedir "${gnupghome}"
    --batch --yes --pinentry-mode loopback
    --local-user "${fingerprint}"
    --passphrase ''
  )
  gpg "${args[@]}" --detach-sign --armor --output "${detach_out}" -- "${in}"
  gpg "${args[@]}" --clearsign --output "${clear_out}" -- "${in}"
}

validate_catalog() {
  local file="$1"
  jq -e 'type=="object" and .schema_version=="2" and (.packages|type=="array")' "${file}" >/dev/null \
    || die "catalog 必须是 schema_version=\"2\" 且含 packages 数组"
  jq -e '
    .packages
    | (map(.id) | length) == (map(.id) | unique | length)
    and (map(.package) | length) == (map(.package) | unique | length)
  ' "${file}" >/dev/null || die "catalog 中 id 或 package 重复"
  local pkgjson id repo pkg desc src lic series_type archs
  while IFS= read -r pkgjson; do
    id="$(jq -r '.id // empty' <<<"${pkgjson}")"
    repo="$(jq -r '.repository // empty' <<<"${pkgjson}")"
    pkg="$(jq -r '.package // empty' <<<"${pkgjson}")"
    desc="$(jq -r '.description // empty' <<<"${pkgjson}")"
    src="$(jq -r '.source_url // empty' <<<"${pkgjson}")"
    lic="$(jq -r '.license // empty' <<<"${pkgjson}")"
    assert_safe_package_id "${id}"
    [[ "${repo}" =~ ${REPO_NAME} ]] || die "非法 repository: ${repo}"
    [[ "${pkg}" =~ ${PKG_NAME} ]] || die "非法 package: ${pkg}"
    [[ -n "${desc}" && -n "${src}" && -n "${lic}" ]] || die "软件 ${id} 缺少 description/source_url/license"
    [[ "${src}" == https://* ]] || die "软件 ${id} 的 source_url 必须是 https"
    series_type="$(jq -r 'if .ubuntu_series=="supported" then "supported" elif (.ubuntu_series|type)=="array" then "list" else "bad" end' <<<"${pkgjson}")"
    [[ "${series_type}" != "bad" ]] || die "软件 ${id} 的 ubuntu_series 必须是 supported 或官方 series 数组"
    if [[ "${series_type}" == "list" ]]; then
      jq -e '.ubuntu_series|length>0 and all(.[]; type=="string" and length>0)' <<<"${pkgjson}" >/dev/null \
        || die "软件 ${id} 的 ubuntu_series 数组为空"
    fi
    archs="$(jq -r '.architectures | keys[]?' <<<"${pkgjson}")"
    [[ -n "${archs}" ]] || die "软件 ${id} 缺少 architectures"
    while IFS= read -r arch; do
      [[ "${arch}" =~ ${ALLOWED_ARCHS} ]] || die "软件 ${id} 含非法架构: ${arch}"
      jq -e --arg a "${arch}" '.architectures[$a]|type=="string" and length>0' <<<"${pkgjson}" >/dev/null \
        || die "软件 ${id} 架构 ${arch} 的资产规则必须是非空正则"
    done <<<"${archs}"
  done < <(jq -c '.packages[]?' "${file}")
}

validate_releases() {
  local file="$1"
  local today
  today="$(date -u +%Y-%m-%d)"
  jq -e 'type=="object" and .schema_version==1 and (.releases|type=="array") and (.releases|length>0)' "${file}" >/dev/null \
    || die "releases 必须是 schema_version=1 且含非空 releases"
  jq -e '(.releases|map(.series)|length) == (.releases|map(.series)|unique|length)' "${file}" >/dev/null \
    || die "releases 中 series 重复"
  local row series version release_date eol_date
  while IFS= read -r row; do
    series="$(jq -r '.series // empty' <<<"${row}")"
    version="$(jq -r '.version // empty' <<<"${row}")"
    release_date="$(jq -r '.release_date // empty' <<<"${row}")"
    eol_date="$(jq -r '.eol_date // empty' <<<"${row}")"
    [[ "${series}" =~ ${SERIES_NAME} ]] || die "非法 series: ${series}"
    [[ -n "${version}" ]] || die "series ${series} 缺少 version"
    assert_iso_date "${release_date}" "series ${series} release_date"
    assert_iso_date "${eol_date}" "series ${series} eol_date"
    [[ "${release_date}" < "${eol_date}" ]] || die "series ${series} release_date 必须早于 eol_date"
    [[ "${release_date}" > "${today}" ]] && die "series ${series} 尚未进入标准支持期"
    [[ "${eol_date}" > "${today}" ]] || die "series ${series} 已结束标准支持期"
  done < <(jq -c '.releases[]' "${file}")
}

supported_series() {
  jq -r '.releases[].series' "${releases}"
}

series_is_supported() {
  local s="$1"
  jq -e --arg s "${s}" '.releases|any(.series==$s)' "${releases}" >/dev/null
}

package_series_list() {
  local pkgjson="$1"
  if [[ "$(jq -r 'if .ubuntu_series=="supported" then "supported" else "list" end' <<<"${pkgjson}")" == "supported" ]]; then
    supported_series
    return
  fi
  local s
  while IFS= read -r s; do
    series_is_supported "${s}" || die "ubuntu_series ${s} 不是当前官方标准支持集合的子集"
    printf '%s\n' "${s}"
  done < <(jq -r '.ubuntu_series[]' <<<"${pkgjson}")
}

public_key_fingerprint() {
  local keyfile="$1"
  gpg --batch --show-keys --with-colons -- "${keyfile}" \
    | awk -F: '$1=="fpr"{print $10; exit}'
}

assert_previous_signing_identity() {
  local root="$1"
  local keyfile="${root}/apt-hub.gpg" prev_fpr
  if [[ ! -e "${keyfile}" ]]; then
    return 0
  fi
  [[ -f "${keyfile}" && ! -L "${keyfile}" ]] || die "previous/apt-hub.gpg 非法"
  prev_fpr="$(strip_fp "$(public_key_fingerprint "${keyfile}")")"
  [[ "${prev_fpr}" =~ ^[A-F0-9]{40}$ ]] || die "无法读取 previous 公钥指纹"
  [[ "${prev_fpr}" == "${fingerprint}" ]] || die "拒绝静默换钥: previous=${prev_fpr} current=${fingerprint}"
}

validate_previous_tree() {
  local root="$1"
  local rel path
  if find -- "${root}" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit | grep -q .; then
    die "previous 含符号链接或特殊文件，拒绝复制"
  fi
  if find -- "${root}" -type f -name '*.deb' -print -quit | grep -q .; then
    die "previous 含 .deb，拒绝旧镜像输入"
  fi
  if [[ -d "${root}/pool" ]]; then
    die "previous 含 pool/，拒绝旧镜像输入"
  fi
  if [[ -d "${root}/dists" ]]; then
    die "previous 含根级 dists/，拒绝旧布局"
  fi
  while IFS= read -r -d '' path; do
    rel="${path#"${root}"/}"
    [[ "${rel}" != *..* ]] || die "previous 路径含 .. : ${rel}"
  done < <(find -- "${root}" -print0)
}

copy_previous_byhash() {
  local src="$1" dest="$2"
  local path rel name hash
  while IFS= read -r -d '' path; do
    rel="${path#"${src}"/}"
    case "${rel}" in
      repos/*/dists/*/main/binary-*/by-hash/SHA256/*)
        name="$(basename -- "${rel}")"
        [[ "${name}" =~ ${HEX64} ]] || die "by-hash 文件名不是 SHA256: ${rel}"
        hash="$(hex_sha256 "${path}")"
        [[ "${hash}" == "${name}" ]] || die "by-hash 内容与文件名不一致: ${rel}"
        install -D -m 644 -- "${path}" "${dest}/${rel}"
        ;;
    esac
  done < <(find -- "${src}" -type f -print0)
}

load_previous_state() {
  local src="$1" dest="$2"
  if [[ ! -e "${src}/state.json" ]]; then
    if [[ -d "${src}/pool" ]] || [[ -d "${src}/dists" ]] || [[ -d "${src}/repos" ]]; then
      die "previous 缺少 state.json 但含旧/未声明布局"
    fi
    if find -- "${src}" -type f -name '*.deb' -print -quit | grep -q .; then
      die "previous 含 .deb 但缺少 state.json"
    fi
    printf '%s\n' '{"schema_version":"2","packages":[]}' >"${dest}/prev-state.json"
    return
  fi
  [[ -f "${src}/state.json" && ! -L "${src}/state.json" ]] || die "previous/state.json 非法"
  if ! jq -e 'type=="object" and .schema_version=="2" and (.packages|type=="array")' "${src}/state.json" >/dev/null; then
    die "previous/state.json 不是 schema_version=\"2\"，拒绝旧 schema"
  fi
  local row id filename sha size uri seen_ids
  seen_ids="${dest}/prev-ids-seen.txt"
  : >"${seen_ids}"
  while IFS= read -r row; do
    id="$(jq -r '.id // empty' <<<"${row}")"
    [[ -n "${id}" ]] || die "previous state 缺少 id"
    assert_safe_package_id "${id}" "previous id"
    if grep -Fxq -- "${id}" "${seen_ids}"; then
      die "previous state 重复 id: ${id}"
    fi
    printf '%s\n' "${id}" >>"${seen_ids}"
    uri="$(jq -r '.apt_source_uri // empty' <<<"${row}")"
    [[ -n "${uri}" ]] || die "previous state 缺少 apt_source_uri: ${id}"
    while IFS= read -r asset; do
      filename="$(jq -r '.filename // empty' <<<"${asset}")"
      sha="$(jq -r '.sha256 // empty' <<<"${asset}")"
      size="$(jq -r '.size // empty' <<<"${asset}")"
      [[ "${sha}" =~ ${HEX64} ]] || die "previous state 摘要非法: ${id} ${filename}"
      [[ "${size}" =~ ^[1-9][0-9]*$ ]] || die "previous size 必须是十进制字符串: ${id} ${filename}"
      assert_origin_relative_filename "${filename}" "previous filename"
      jq -e '(.url|type=="string") and (.url|startswith("https://"))' <<<"${asset}" >/dev/null \
        || die "previous asset url 非法: ${id}"
    done < <(jq -c '.assets[]?' <<<"${row}")
    assert_contained_repo_dir "${src}/repos" "${id}" "previous"
  done < <(jq -c '.packages[]?' "${src}/state.json")
  cp -- "${src}/state.json" "${dest}/prev-state.json"
}

match_unique_asset() {
  local release_json="$1" regex="$2"
  local n
  n="$(jq --arg re "${regex}" '[.assets[]? | select((.name|type=="string") and (.name|test($re)))] | length' <<<"${release_json}")"
  [[ "${n}" == "1" ]] || die "资产正则必须唯一匹配 1 个文件，实际 ${n} 个: ${regex}"
  jq -c --arg re "${regex}" '.assets[] | select(.name|test($re))' <<<"${release_json}"
}

official_sha256() {
  local asset="$1"
  local digest
  digest="$(jq -r '.digest // empty' <<<"${asset}")"
  [[ "${digest}" == sha256:* ]] || die "缺少非空官方 SHA256 digest"
  local hash="${digest#sha256:}"
  hash="$(printf '%s' "${hash}" | tr '[:upper:]' '[:lower:]')"
  [[ "${hash}" =~ ${HEX64} ]] || die "官方 SHA256 不是 64 位 hex"
  printf '%s\n' "${hash}"
}

compare_dpkg_versions() {
  local left="$1" op="$2" right="$3"
  local rc=0
  set +e
  dpkg --compare-versions -- "${left}" "${op}" "${right}"
  rc=$?
  set -e
  [[ "${rc}" -ne 2 ]] || die "Debian 版本无法比较: ${left} ${op} ${right}"
  return "${rc}"
}

extract_packages_stanza_by_sha() {
  local packages_file="$1" want_sha="$2"
  awk -v want="$(printf '%s' "${want_sha}" | tr '[:upper:]' '[:lower:]')" '
    BEGIN { RS=""; FS="\n" }
    {
      sha=""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^SHA256: /) {
          split($i, a, " ")
          sha = tolower(a[2])
        }
      }
      if (sha == want) {
        printf "%s\n\n", $0
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "${packages_file}"
}

ensure_verify_trusted_keyring() {
  local keyring="${scratch}/verify-trusted.gpg"
  [[ -n "${scratch}" && -d "${scratch}" ]] || return 1
  if [[ ! -s "${keyring}" ]]; then
    gpg --homedir "${gnupghome}" --batch --export -- "${fingerprint}" >"${keyring}" || return 1
    [[ -s "${keyring}" ]] || return 1
  fi
}

release_status_binds_fingerprint() {
  local status_file="$1" primary
  [[ -s "${status_file}" ]] || return 1
  grep -q '^\[GNUPG:\] GOODSIG ' "${status_file}" || return 1
  if grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|NO_PUBKEY|EXPSIG|EXPKEYSIG|REVKEYSIG) ' "${status_file}"; then
    return 1
  fi
  primary="$(awk '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      if (NF >= 12 && $12 != "") print $12
      else print $3
      exit
    }
  ' "${status_file}")"
  primary="$(strip_fp "${primary}")"
  [[ "${primary}" == "${fingerprint}" ]]
}

# 用 gpgv 取得已验签 Release 正文；失败不回退未认证旁路文件。
authenticated_release_body() {
  local dist="$1" body_out="$2" status_out="$3"
  local keyring="${scratch}/verify-trusted.gpg" rc=0
  ensure_verify_trusted_keyring || return 1
  rm -f -- "${body_out}" "${status_out}"
  if [[ -f "${dist}/InRelease" && ! -L "${dist}/InRelease" ]]; then
    gpgv --keyring "${keyring}" --status-fd 3 --output "${body_out}" -- "${dist}/InRelease" \
      3>"${status_out}" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -eq 0 && -s "${body_out}" ]] || return 1
    release_status_binds_fingerprint "${status_out}" || return 1
    if [[ -f "${dist}/Release" && ! -L "${dist}/Release" ]]; then
      cmp -s -- "${body_out}" "${dist}/Release" || return 1
    fi
    return 0
  fi
  if [[ -f "${dist}/Release.gpg" && ! -L "${dist}/Release.gpg" && -f "${dist}/Release" && ! -L "${dist}/Release" ]]; then
    gpgv --keyring "${keyring}" --status-fd 3 -- "${dist}/Release.gpg" "${dist}/Release" \
      3>"${status_out}" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    release_status_binds_fingerprint "${status_out}" || return 1
    cp -f -- "${dist}/Release" "${body_out}" || return 1
    return 0
  fi
  return 1
}

verify_repo_release_and_packages() {
  local repo_root="$1" series="$2" arch="$3"
  local dist packages packages_gz body status hash size expected_hash expected_size decoded
  local gz_hash gz_size expected_gz_hash expected_gz_size
  dist="${repo_root}/dists/${series}"
  packages="${dist}/main/binary-${arch}/Packages"
  packages_gz="${packages}.gz"
  [[ -f "${packages}" && ! -L "${packages}" ]] || return 1
  [[ -f "${packages_gz}" && ! -L "${packages_gz}" ]] || return 1
  [[ -n "${scratch}" && -d "${scratch}" ]] || return 1
  body="${scratch}/verified-release-${series}-${arch}.txt"
  status="${scratch}/verify-status-${series}-${arch}.txt"
  authenticated_release_body "${dist}" "${body}" "${status}" || return 1
  hash="$(hex_sha256 "${packages}")"
  size="$(file_size "${packages}")"
  expected_hash="$(release_sha256_field "${body}" "main/binary-${arch}/Packages" hash)"
  expected_size="$(release_sha256_field "${body}" "main/binary-${arch}/Packages" size)"
  [[ -n "${expected_hash}" && "${expected_hash}" == "${hash}" ]] || return 1
  [[ -n "${expected_size}" && "${expected_size}" == "${size}" ]] || return 1
  gz_hash="$(hex_sha256 "${packages_gz}")"
  gz_size="$(file_size "${packages_gz}")"
  expected_gz_hash="$(release_sha256_field "${body}" "main/binary-${arch}/Packages.gz" hash)"
  expected_gz_size="$(release_sha256_field "${body}" "main/binary-${arch}/Packages.gz" size)"
  [[ -n "${expected_gz_hash}" && "${expected_gz_hash}" == "${gz_hash}" ]] || return 1
  [[ -n "${expected_gz_size}" && "${expected_gz_size}" == "${gz_size}" ]] || return 1
  decoded="${scratch}/verified-packages-decoded-${series}-${arch}.txt"
  gzip -dc -- "${packages_gz}" >"${decoded}" || return 1
  cmp -s -- "${decoded}" "${packages}" || return 1
  return 0
}

verify_previous_repo_indexes() {
  local id="$1"
  local repo_root="${previous}/repos/${id}"
  local series_dir series arch_dir arch ok=0
  [[ -d "${repo_root}/dists" ]] || return 1
  while IFS= read -r -d '' series_dir; do
    series="$(basename -- "${series_dir}")"
    [[ "${series}" =~ ${SERIES_NAME} ]] || return 1
    while IFS= read -r -d '' arch_dir; do
      arch="$(basename -- "${arch_dir}")"
      arch="${arch#binary-}"
      [[ "${arch}" =~ ${ALLOWED_ARCHS} ]] || return 1
      verify_repo_release_and_packages "${repo_root}" "${series}" "${arch}" || return 1
      ok=1
    done < <(find -- "${series_dir}/main" -mindepth 1 -maxdepth 1 -type d -name 'binary-*' -print0 2>/dev/null)
  done < <(find -- "${repo_root}/dists" -mindepth 1 -maxdepth 1 -type d -print0)
  [[ "${ok}" -eq 1 ]]
}

try_reuse_control_stanza() {
  local id="$1" arch="$2" sha="$3" series_file="$4" out="$5"
  local repo_root series series_dir ok=0
  local tried="${scratch}/reuse-series-tried-${id}-${arch}.txt"
  repo_root="${previous}/repos/${id}"
  [[ -d "${repo_root}" ]] || return 1
  [[ -n "${scratch}" && -d "${scratch}" ]] || return 1
  : >"${tried}"
  while IFS= read -r series; do
    [[ -n "${series}" ]] || continue
    printf '%s\n' "${series}" >>"${tried}"
    if verify_repo_release_and_packages "${repo_root}" "${series}" "${arch}"; then
      if extract_packages_stanza_by_sha \
        "${repo_root}/dists/${series}/main/binary-${arch}/Packages" "${sha}" >"${out}"; then
        ok=1
        break
      fi
    fi
  done <"${series_file}"
  # 合法窗口迁移：当前 series 无交集时，仍可从 previous 其他已验签系列取同资产 control
  if [[ "${ok}" -ne 1 ]]; then
    while IFS= read -r -d '' series_dir; do
      series="$(basename -- "${series_dir}")"
      [[ "${series}" =~ ${SERIES_NAME} ]] || return 1
      if grep -Fxq -- "${series}" "${tried}"; then
        continue
      fi
      if verify_repo_release_and_packages "${repo_root}" "${series}" "${arch}"; then
        if extract_packages_stanza_by_sha \
          "${repo_root}/dists/${series}/main/binary-${arch}/Packages" "${sha}" >"${out}"; then
          ok=1
          break
        fi
      fi
    done < <(find -- "${repo_root}/dists" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
  [[ "${ok}" -eq 1 ]]
}

control_field() {
  local stanza_file="$1" field="$2"
  awk -v f="${field}" '
    BEGIN { FS=": " }
    $1==f { sub(/^[^:]+: /,""); print; exit }
  ' "${stanza_file}"
}

sign_repo_series_release() {
  local dist="$1" series="$2" arch_list="$3"
  local conf arch pkgfile hash archs_release
  archs_release="$(tr ' ' '\n' <<<"${arch_list}" | awk 'NF' | paste -sd' ' -)"
  [[ -n "${archs_release}" ]] || die "写索引时架构列表为空"
  conf="${scratch}/release-${series}-$$.conf"
  cat >"${conf}" <<EOF
APT::FTPArchive::MD5 "false";
APT::FTPArchive::SHA1 "false";
APT::FTPArchive::SHA512 "false";
APT::FTPArchive::SHA256 "true";
APT::FTPArchive::Release::Origin "apt-hub";
APT::FTPArchive::Release::Label "apt-hub";
APT::FTPArchive::Release::Suite "${series}";
APT::FTPArchive::Release::Codename "${series}";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Architectures "${archs_release}";
APT::FTPArchive::Release::Acquire-By-Hash "yes";
APT::FTPArchive::Release::ValidTime "${VALID_UNTIL_SECONDS}";
EOF
  rm -f -- "${dist}/Release" "${dist}/Release.gpg" "${dist}/InRelease"
  apt-ftparchive -c "${conf}" release "${dist}" >"${scratch}/Release-${series}-$$"
  if grep -E '[[:space:]]Release$' "${scratch}/Release-${series}-$$" >/dev/null; then
    die "Release 不应包含对自身的摘要"
  fi
  mv -- "${scratch}/Release-${series}-$$" "${dist}/Release"
  grep -q '^SHA256:' "${dist}/Release" || die "Release 缺少 SHA256"
  if grep -E '^(MD5Sum|SHA1|SHA512):' "${dist}/Release" >/dev/null; then
    die "Release 含非 SHA256 摘要，禁止降级"
  fi
  grep -q '^Acquire-By-Hash: yes$' "${dist}/Release" || die "Release 缺少 Acquire-By-Hash"
  grep -q '^Valid-Until:' "${dist}/Release" || die "Release 缺少 Valid-Until"
  for arch in ${arch_list}; do
    mkdir -p -- "${dist}/main/binary-${arch}/by-hash/SHA256"
    for pkgfile in "${dist}/main/binary-${arch}/Packages" "${dist}/main/binary-${arch}/Packages.gz"; do
      [[ -f "${pkgfile}" && ! -L "${pkgfile}" ]] || die "缺少 Packages 文件: ${pkgfile}"
      hash="$(hex_sha256 "${pkgfile}")"
      install -m 644 -- "${pkgfile}" "${dist}/main/binary-${arch}/by-hash/SHA256/${hash}"
    done
  done
  without_xtrace gpg_sign "${dist}/Release" "${dist}/Release.gpg" "${dist}/InRelease"
  [[ -s "${dist}/Release.gpg" && -s "${dist}/InRelease" ]] || die "签名文件为空: ${series}"
}

write_repo_indexes() {
  local dest_repo="$1" series_file="$2" arch_list="$3" stanza_dir="$4"
  local series arch dist pkgfile
  while IFS= read -r series; do
    dist="${dest_repo}/dists/${series}"
    for arch in ${arch_list}; do
      mkdir -p -- "${dist}/main/binary-${arch}/by-hash/SHA256"
      pkgfile="${dist}/main/binary-${arch}/Packages"
      : >"${pkgfile}"
      if [[ -f "${stanza_dir}/${arch}.stanza" ]]; then
        cat -- "${stanza_dir}/${arch}.stanza" >>"${pkgfile}"
        if [[ -s "${pkgfile}" ]] && [[ "$(tail -c 1 -- "${pkgfile}" | wc -c)" -ne 0 ]]; then
          printf '\n' >>"${pkgfile}"
        fi
      fi
      gzip -n -9 -c -- "${pkgfile}" >"${pkgfile}.gz"
    done
    sign_repo_series_release "${dist}" "${series}" "${arch_list}"
  done <"${series_file}"
}

resign_existing_repo_indexes() {
  local dest_repo="$1" series_file="$2" arch_list="$3"
  local series dist
  while IFS= read -r series; do
    [[ -n "${series}" ]] || continue
    dist="${dest_repo}/dists/${series}"
    [[ -d "${dist}" ]] || die "续签缺少 dists/${series}"
    sign_repo_series_release "${dist}" "${series}" "${arch_list}"
  done <"${series_file}"
}

write_repo_mirror_and_sources() {
  local dest_repo="$1" id="$2" series_file="$3" arch_list="$4" official_origin="$5"
  local base_url listf series archs_line
  base_url="${site_url}/repos/${id}/"
  listf="${dest_repo}/mirror.list"
  {
    printf '%s\ttype:index\n' "${base_url}"
    printf '%s/\ttype:deb\n' "${official_origin%/}"
  } >"${listf}"
  archs_line="$(tr ' ' '\n' <<<"${arch_list}" | awk 'NF' | paste -sd' ' -)"
  while IFS= read -r series; do
    cat >"${dest_repo}/${series}.sources" <<EOF
Types: deb
URIs: mirror+${site_url}/repos/${id}/mirror.list
Suites: ${series}
Components: main
Signed-By: /etc/apt/keyrings/apt-hub.gpg
Architectures: ${archs_line}
EOF
  done <"${series_file}"
}

write_state() {
  local dest="$1" rows="$2"
  jq -e --slurp '
    {schema_version:"2", packages:(. | sort_by(.id))}
  ' "${rows}" >"${dest}/state.json"
  jq -e '.schema_version=="2" and (.packages|type=="array")' "${dest}/state.json" >/dev/null \
    || die "生成 state.json 失败"
}

copy_retained_repo() {
  local id="$1" prev_row="$2"
  local src="${previous}/repos/${id}"
  local dest="${work}/repos/${id}"
  local path rel series_file arch_list official_origin series_dir arch_dir arch
  assert_safe_package_id "${id}" "存量 id"
  assert_contained_repo_dir "${previous}/repos" "${id}" "存量"
  assert_contained_repo_dest "${work}/repos" "${id}" "存量"
  if find -- "${src}" -type f -name '*.deb' -print -quit | grep -q .; then
    die "存量 repos/${id} 含 .deb"
  fi
  verify_previous_repo_indexes "${id}" \
    || die "存量 repos/${id} 未通过签名元数据校验，拒绝重新发布"
  # 官方 origin 由已签名 Packages 锚定的 asset.url 派生；旧 mirror 仅校验不得改 deb host
  official_origin="$(retained_official_origin_from_state "${prev_row}" "${src}" "${id}")"
  assert_retained_mirror_deb_origin "${src}/mirror.list" "${official_origin}" "${id}"
  mkdir -p -- "${dest}"
  while IFS= read -r -d '' path; do
    rel="${path#"${src}"/}"
    install -D -m 644 -- "${path}" "${dest}/${rel}"
  done < <(find -- "${src}" -type f -print0)

  series_file="${scratch}/series-retain-${id}.txt"
  : >"${series_file}"
  while IFS= read -r -d '' series_dir; do
    printf '%s\n' "$(basename -- "${series_dir}")" >>"${series_file}"
  done < <(find -- "${dest}/dists" -mindepth 1 -maxdepth 1 -type d -print0)
  sort -u -o "${series_file}" "${series_file}"
  [[ -s "${series_file}" ]] || die "存量 repos/${id} 无 dists 系列"

  arch_list=""
  while IFS= read -r -d '' arch_dir; do
    arch="$(basename -- "${arch_dir}")"
    arch="${arch#binary-}"
    [[ "${arch}" =~ ${ALLOWED_ARCHS} ]] || die "存量 repos/${id} 含非法架构: ${arch}"
    case " ${arch_list} " in
      *" ${arch} "*) ;;
      *) arch_list="${arch_list} ${arch}" ;;
    esac
  done < <(find -- "${dest}/dists" -type d -name 'binary-*' -print0)
  arch_list="$(tr ' ' '\n' <<<"${arch_list}" | awk 'NF' | sort -u | paste -sd' ' -)"
  [[ -n "${arch_list}" ]] || die "存量 repos/${id} 无 binary 架构"

  # 保留 Packages/by-hash 字节，仅重生成 Release 续期并按当前 site-url 重写 mirror/sources
  resign_existing_repo_indexes "${dest}" "${series_file}" "${arch_list}"
  write_repo_mirror_and_sources "${dest}" "${id}" "${series_file}" "${arch_list}" "${official_origin}"
}

# --- 参数 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog)
      [[ $# -ge 2 ]] || usage
      catalog="$2"; shift 2 ;;
    --releases)
      [[ $# -ge 2 ]] || usage
      releases="$2"; shift 2 ;;
    --previous)
      [[ $# -ge 2 ]] || usage
      previous="$2"; shift 2 ;;
    --output)
      [[ $# -ge 2 ]] || usage
      output="$2"; shift 2 ;;
    --gnupghome)
      [[ $# -ge 2 ]] || usage
      gnupghome="$2"; shift 2 ;;
    --fingerprint)
      [[ $# -ge 2 ]] || usage
      fingerprint="$2"; shift 2 ;;
    --site-url)
      [[ $# -ge 2 ]] || usage
      site_url="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      die "未知参数: $1" ;;
  esac
done

[[ -n "${catalog}" && -n "${releases}" && -n "${previous}" && -n "${output}" && -n "${gnupghome}" && -n "${fingerprint}" && -n "${site_url}" ]] || usage

require_cmd bash jq curl gpg gpgv gpg-agent dpkg-deb dpkg apt-ftparchive gzip flock sha256sum realpath date find install awk sed grep tr sort paste cmp

catalog="$(assert_allowed_file catalog "${catalog}")"
releases="$(assert_allowed_file releases "${releases}")"
previous="$(assert_allowed_dir previous "${previous}" yes)"
output="$(assert_allowed_dir output "${output}" no)"
gnupghome="$(assert_allowed_dir gnupghome "${gnupghome}" yes)"
fingerprint="$(strip_fp "${fingerprint}")"
[[ "${fingerprint}" =~ ^[A-F0-9]{40}$ ]] || die "fingerprint 必须是 40 位十六进制完整指纹"
site_url="$(assert_site_url "${site_url}")"

assert_no_overlap "${previous}" "${output}" "previous 与 output 重叠"
assert_no_overlap "${gnupghome}" "${output}" "gnupghome 与 output 重叠"
assert_no_overlap "${gnupghome}" "${previous}" "gnupghome 与 previous 重叠"
[[ "${output}" != "${catalog}" && "${output}" != "${releases}" ]] || die "output 与输入文件冲突"

validate_catalog "${catalog}"
validate_releases "${releases}"

gpg --homedir "${gnupghome}" --batch --list-secret-keys --with-colons -- "${fingerprint}" >/dev/null 2>&1 \
  || die "gnupghome 中没有该 fingerprint 的私钥"

lockfile="${output}.lock"
lockdir="$(dirname -- "${lockfile}")"
[[ -d "${lockdir}" ]] || die "output 父目录不存在"
assert_no_symlink_components "${lockdir}"
if [[ -L "${lockfile}" ]]; then
  die "lock 不能是符号链接: ${lockfile}"
fi
if [[ -e "${lockfile}" ]]; then
  [[ -f "${lockfile}" ]] || die "lock 不是普通文件: ${lockfile}"
  assert_no_symlink_components "${lockfile}"
fi
exec 9>>"${lockfile}" || die "无法打开 lock: ${lockfile}"
if [[ -L "${lockfile}" ]]; then
  die "lock 不能是符号链接: ${lockfile}"
fi
[[ -f "${lockfile}" ]] || die "lock 不是普通文件: ${lockfile}"
[[ "$(stat -L -c '%d:%i' /proc/self/fd/9)" == "$(stat -c '%d:%i' "${lockfile}")" ]] \
  || die "lock 句柄与路径不一致"
flock -n 9 || die "同步已在进行: ${lockfile}"

if [[ -e "${output}" ]] && ! dir_is_empty "${output}"; then
  die "拒绝写入已有非空 output: ${output}"
fi
pending_work="${output}.work"
pending_scratch="${output}.scratch"
if [[ -e "${pending_work}" || -L "${pending_work}" ]]; then
  die "存在未完成候选目录，拒绝覆盖: ${pending_work}"
fi
if [[ -e "${pending_scratch}" || -L "${pending_scratch}" ]]; then
  die "存在未清理临时目录，拒绝覆盖: ${pending_scratch}"
fi

mkdir -m 755 -- "${pending_work}" || die "无法创建候选目录: ${pending_work}"
work="${pending_work}"
work_owned=1
mkdir -m 755 -- "${pending_scratch}" || die "无法创建临时目录: ${pending_scratch}"
scratch="${pending_scratch}"
scratch_owned=1
mkdir -p -- "${work}/repos"

validate_previous_tree "${previous}"
assert_previous_signing_identity "${previous}"
copy_previous_byhash "${previous}" "${work}"
load_previous_state "${previous}" "${scratch}"

now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
state_rows="${scratch}/state-rows.jsonl"
: >"${state_rows}"
catalog_ids="${scratch}/catalog-ids.txt"
: >"${catalog_ids}"

if [[ -n "$(jq -c '.packages[]?' "${catalog}")" ]]; then
while IFS= read -r pkgjson; do
  id="$(jq -r '.id' <<<"${pkgjson}")"
  repo="$(jq -r '.repository' <<<"${pkgjson}")"
  pkg="$(jq -r '.package' <<<"${pkgjson}")"
  desc="$(jq -r '.description' <<<"${pkgjson}")"
  src="$(jq -r '.source_url' <<<"${pkgjson}" | sed 's#/$##')"
  lic="$(jq -r '.license' <<<"${pkgjson}")"
  printf '%s\n' "${id}" >>"${catalog_ids}"
  package_series_list "${pkgjson}" >"${scratch}/series-${id}.raw"
  sort -u "${scratch}/series-${id}.raw" >"${scratch}/series-${id}.txt"
  mapfile -t pkg_series <"${scratch}/series-${id}.txt"
  [[ ${#pkg_series[@]} -gt 0 ]] || die "软件 ${id} 未分配到任何发行版"

  api_url="https://api.github.com/repos/${repo}/releases/latest"
  release_json="$(without_xtrace github_get "${api_url}")" || die "GitHub API 失败: ${repo}"
  echo "${release_json}" | jq -e 'type=="object" and (.tag_name|type=="string") and (.html_url|type=="string") and (.assets|type=="array")' >/dev/null \
    || die "GitHub latest 响应不是合法 release 对象: ${repo}"
  jq -e '.draft!=true and .prerelease!=true' <<<"${release_json}" >/dev/null \
    || die "latest 不是稳定版: ${repo}"
  tag="$(jq -r '.tag_name' <<<"${release_json}")"
  html_url="$(jq -r '.html_url' <<<"${release_json}")"
  assert_github_tag "${tag}"
  assert_github_html_url "${repo}" "${tag}" "${html_url}"

  prev_row="$(jq -c --arg id "${id}" '.packages[]? | select(.id==$id)' "${scratch}/prev-state.json" || true)"
  prev_ver=""
  prev_updated=""
  if [[ -n "${prev_row}" ]]; then
    prev_ver="$(jq -r '.version' <<<"${prev_row}")"
    prev_updated="$(jq -r '.updated_at' <<<"${prev_row}")"
  fi

  asset_rows=()
  archs=""
  deb_version=""
  official_origin=""
  stanza_dir="${scratch}/stanza-${id}"
  mkdir -p -- "${stanza_dir}"
  verify_tree="${scratch}/verify-tree-${id}"
  rm -rf -- "${verify_tree}"
  mkdir -p -- "${verify_tree}"

  while IFS= read -r arch; do
    regex="$(jq -r --arg a "${arch}" '.architectures[$a]' <<<"${pkgjson}")"
    asset="$(match_unique_asset "${release_json}" "${regex}")"
    name="$(jq -r '.name' <<<"${asset}")"
    size="$(jq -r '.size' <<<"${asset}")"
    url="$(jq -r '.browser_download_url // empty' <<<"${asset}")"
    official="$(official_sha256 "${asset}")"
    [[ "${size}" =~ ^[1-9][0-9]*$ ]] || die "官方 size 非法: ${id} ${name}"
    assert_github_asset_url "${repo}" "${tag}" "${name}" "${url}"
    rel="$(origin_relative_path "${url}")"
    origin="$(https_origin_of "${url}")"
    if [[ -z "${official_origin}" ]]; then
      official_origin="${origin}"
    else
      [[ "${official_origin}" == "${origin}" ]] || die "同一软件官方 origin 不一致: ${id}"
    fi

    reused=0
    if [[ -n "${prev_row}" ]]; then
      prev_asset="$(jq -c --arg a "${arch}" --arg u "${url}" --arg h "${official}" --arg s "${size}" '
        .assets[]? | select(.architecture==$a and .url==$u and .sha256==$h and (.size|tostring)==$s)
      ' <<<"${prev_row}" || true)"
      if [[ -n "${prev_asset}" ]]; then
        prev_fn="$(jq -r '.filename' <<<"${prev_asset}")"
        [[ "${prev_fn}" == "${rel}" ]] || die "previous filename 与官方相对路径不一致: ${id} ${arch}"
        if try_reuse_control_stanza "${id}" "${arch}" "${official}" "${scratch}/series-${id}.txt" "${stanza_dir}/${arch}.stanza"; then
          reused=1
        else
          die "previous 元数据无法通过签名/Packages 校验，拒绝盲复用: ${id} ${arch}"
        fi
      fi
    fi

    if [[ "${reused}" -eq 1 ]]; then
      deb_pkg="$(control_field "${stanza_dir}/${arch}.stanza" Package)"
      deb_ver="$(control_field "${stanza_dir}/${arch}.stanza" Version)"
      deb_arch="$(control_field "${stanza_dir}/${arch}.stanza" Architecture)"
      deb_fn="$(control_field "${stanza_dir}/${arch}.stanza" Filename)"
      deb_sha="$(control_field "${stanza_dir}/${arch}.stanza" SHA256 | tr '[:upper:]' '[:lower:]')"
      deb_sz="$(control_field "${stanza_dir}/${arch}.stanza" Size)"
      [[ "${deb_pkg}" == "${pkg}" ]] || die "复用 control Package 不符: ${id}"
      [[ "${deb_arch}" == "${arch}" ]] || die "复用 control Architecture 不符: ${id}"
      [[ "${deb_fn}" == "${rel}" ]] || die "复用 control Filename 不符: ${id}"
      [[ "${deb_sha}" == "${official}" ]] || die "复用 control SHA256 不符: ${id}"
      [[ "${deb_sz}" == "${size}" ]] || die "复用 control Size 不符: ${id}"
      [[ -n "${deb_ver}" ]] || die "复用 control Version 为空: ${id}"
      dpkg --validate-version -- "${deb_ver}" || die "复用 Version 非法: ${id} ${deb_ver}"
    else
      dest_rel="${verify_tree}/${rel}"
      dest_resolved="$(realpath -m -- "${dest_rel}")"
      under_dir "${verify_tree}" "${dest_resolved}" || die "临时核验路径越界: ${rel}"
      mkdir -p -- "$(dirname -- "${dest_rel}")"
      without_xtrace curl_https "${DOWNLOAD_TIMEOUT}" -o "${dest_rel}" -- "${url}" || die "下载失败: ${url}"
      got_size="$(file_size "${dest_rel}")"
      got_sha="$(hex_sha256 "${dest_rel}")"
      [[ "${got_size}" == "${size}" ]] || die "实际大小与官方 size 不符: ${name}"
      [[ "${got_sha}" == "${official}" ]] || die "实际 SHA256 与官方 digest 不符: ${name}"
      deb_pkg="$(dpkg-deb -f -- "${dest_rel}" Package)"
      deb_ver="$(dpkg-deb -f -- "${dest_rel}" Version)"
      deb_arch="$(dpkg-deb -f -- "${dest_rel}" Architecture)"
      [[ "${deb_pkg}" == "${pkg}" ]] || die "包内 Package=${deb_pkg} 与清单 ${pkg} 不符"
      [[ "${deb_arch}" == "${arch}" ]] || die "包内 Architecture=${deb_arch} 与 ${arch} 不符"
      [[ -n "${deb_ver}" ]] || die "包内 Version 为空: ${name}"
      dpkg --validate-version -- "${deb_ver}" || die "包内 Version 非法: ${name} ${deb_ver}"
      if ! (
        cd -- "${verify_tree}"
        apt-ftparchive --md5=off --sha1=off --sha512=off --sha256 packages .
      ) >"${stanza_dir}/${arch}.raw"; then
        die "apt-ftparchive packages 失败"
      fi
      awk -v want="${official}" '
        BEGIN { RS=""; FS="\n" }
        {
          sha=""
          for (i=1;i<=NF;i++) if ($i ~ /^SHA256: /){split($i,a," "); sha=tolower(a[2])}
          if (sha==want) {
            for (i=1;i<=NF;i++) {
              if ($i ~ /^Filename: \.\//) sub(/^Filename: \.\//,"Filename: ", $i)
              print $i
            }
            printf "\n"
            found=1
            exit
          }
        }
        END { if (!found) exit 1 }
      ' "${stanza_dir}/${arch}.raw" >"${stanza_dir}/${arch}.stanza" \
        || die "apt-ftparchive 未生成对应 Packages 记录: ${id} ${arch}"
      rm -f -- "${dest_rel}"
    fi

    if [[ -z "${deb_version}" ]]; then
      deb_version="${deb_ver}"
    else
      compare_dpkg_versions "${deb_ver}" eq "${deb_version}" || die "同一软件不同架构 Version 不一致: ${id}"
    fi

    asset_rows+=("$(jq -n \
      --arg architecture "${arch}" \
      --arg filename "${rel}" \
      --arg sha256 "${official}" \
      --arg size "${size}" \
      --arg url "${url}" \
      '{architecture:$architecture,filename:$filename,sha256:$sha256,size:$size,url:$url}')")
    archs="${archs} ${arch}"
  done < <(jq -r '.architectures|keys[]' <<<"${pkgjson}")

  [[ -n "${deb_version}" ]] || die "软件 ${id} 没有有效资产"
  [[ -n "${official_origin}" ]] || die "软件 ${id} 缺少官方 origin"
  rm -rf -- "${verify_tree}"

  if [[ -n "${prev_ver}" ]]; then
    if compare_dpkg_versions "${deb_version}" lt "${prev_ver}"; then
      die "禁止上游降级: ${id} ${deb_version} < ${prev_ver}"
    fi
    if compare_dpkg_versions "${deb_version}" eq "${prev_ver}"; then
      for row in "${asset_rows[@]}"; do
        fn="$(jq -r '.filename' <<<"${row}")"
        sha="$(jq -r '.sha256' <<<"${row}")"
        oldsha="$(jq -r --arg f "${fn}" '.assets[]?|select(.filename==$f)|.sha256 // empty' <<<"${prev_row}")"
        if [[ -n "${oldsha}" && "${oldsha}" != "${sha}" ]]; then
          die "禁止同名版本内容替换: ${id} ${fn}"
        fi
      done
    fi
  fi

  updated_at="${now_utc}"
  if [[ -n "${prev_row}" ]] && compare_dpkg_versions "${deb_version}" eq "${prev_ver}"; then
    identical=1
    for row in "${asset_rows[@]}"; do
      fn="$(jq -r '.filename' <<<"${row}")"
      sha="$(jq -r '.sha256' <<<"${row}")"
      oldsha="$(jq -r --arg f "${fn}" '.assets[]?|select(.filename==$f)|.sha256 // empty' <<<"${prev_row}")"
      [[ "${oldsha}" == "${sha}" ]] || identical=0
    done
    old_count="$(jq '.assets|length' <<<"${prev_row}")"
    new_count="${#asset_rows[@]}"
    if [[ "${identical}" -eq 1 && "${old_count}" == "${new_count}" ]]; then
      updated_at="${prev_updated}"
    fi
  fi

  dest_repo="${work}/repos/${id}"
  mkdir -p -- "${dest_repo}"
  write_repo_indexes "${dest_repo}" "${scratch}/series-${id}.txt" "${archs}" "${stanza_dir}"
  write_repo_mirror_and_sources "${dest_repo}" "${id}" "${scratch}/series-${id}.txt" "${archs}" "${official_origin}"

  assets_json="$(printf '%s\n' "${asset_rows[@]}" | jq -s 'sort_by(.architecture)')"
  series_json="$(printf '%s\n' "${pkg_series[@]}" | jq -R . | jq -s .)"
  arch_json="$(tr ' ' '\n' <<<"${archs}" | awk 'NF' | jq -R . | jq -s .)"
  apt_uri="mirror+${site_url}/repos/${id}/mirror.list"
  jq -n \
    --arg id "${id}" \
    --arg package "${pkg}" \
    --arg repository "${repo}" \
    --arg description "${desc}" \
    --arg version "${deb_version}" \
    --arg release_url "${html_url}" \
    --arg source_url "${src}/tree/${tag}" \
    --arg license "${lic}" \
    --arg updated_at "${updated_at}" \
    --arg apt_source_uri "${apt_uri}" \
    --argjson ubuntu_series "${series_json}" \
    --argjson architectures "${arch_json}" \
    --argjson assets "${assets_json}" \
    '{
      id:$id, package:$package, repository:$repository, description:$description,
      version:$version, release_url:$release_url, source_url:$source_url, license:$license,
      updated_at:$updated_at, apt_source_uri:$apt_source_uri,
      ubuntu_series:$ubuntu_series, architectures:$architectures, assets:$assets
    }' >>"${state_rows}"
done < <(jq -c '.packages[]' "${catalog}")
fi

# 存量纳入：previous 中已声明但不在本轮 catalog 的软件，校验后续签续期并保留
while IFS= read -r prev_row; do
  [[ -n "${prev_row}" ]] || continue
  id="$(jq -r '.id' <<<"${prev_row}")"
  if grep -Fxq -- "${id}" "${catalog_ids}"; then
    continue
  fi
  copy_retained_repo "${id}" "${prev_row}"
  jq -c --arg uri "mirror+${site_url}/repos/${id}/mirror.list" \
    '.apt_source_uri=$uri' <<<"${prev_row}" >>"${state_rows}"
done < <(jq -c '.packages[]?' "${scratch}/prev-state.json")

if [[ ! -s "${state_rows}" ]]; then
  printf '%s\n' '{"schema_version":"2","packages":[]}' >"${work}/state.json"
else
  write_state "${work}" "${state_rows}"
fi

without_xtrace gpg --homedir "${gnupghome}" --batch --export -- "${fingerprint}" >"${work}/apt-hub.gpg"
[[ -s "${work}/apt-hub.gpg" ]] || die "导出公钥失败"
if grep -q 'BEGIN PGP PRIVATE KEY' "${work}/apt-hub.gpg"; then
  die "站点中出现私钥"
fi

if find -- "${work}" -type f -name '*.deb' -print -quit | grep -q .; then
  die "产物含 .deb，拒绝发布"
fi

chmod 644 -- "${work}/apt-hub.gpg" "${work}/state.json"
find -- "${work}" -type d -exec chmod 755 {} +
find -- "${work}" -type f -exec chmod 644 {} +

if [[ -e "${output}" ]]; then
  dir_is_empty "${output}" || die "output 在写入前变为非空"
  rmdir -- "${output}"
fi
mv -- "${work}" "${output}"
work_owned=0
work=""
rm -rf -- "${scratch}"
scratch_owned=0
scratch=""
success=1
printf 'sync.sh: 候选元数据站点已写入 %s\n' "${output}"
