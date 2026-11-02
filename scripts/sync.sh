#!/usr/bin/env bash
# 从官方 GitHub Releases 同步 .deb，校验后生成签名 APT 候选站点。
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
POOL_FILENAME='^pool/main/[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]+_[A-Za-z0-9.~%+-]+_(amd64|arm64)\.deb$'
GITHUB_TAG='^[A-Za-z0-9._+-]+$'

catalog=""
releases=""
previous=""
output=""
gnupghome=""
fingerprint=""
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
用法: scripts/sync.sh --catalog <file> --releases <file> --previous <dir> --output <dir> --gnupghome <dir> --fingerprint <完整指纹>
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

assert_pool_filename() {
  local f="$1" role="${2:-filename}"
  [[ -n "${f}" ]] || die "${role} 为空"
  case "${f}" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "${role} 含非法空白" ;;
  esac
  [[ "${f}" != /* ]] || die "${role} 不能是绝对路径: ${f}"
  [[ "${f}" != *..* ]] || die "${role} 含 ..: ${f}"
  [[ "${f}" != *//* ]] || die "${role} 含空路径段: ${f}"
  [[ "${f}" =~ ${POOL_FILENAME} ]] || die "${role} 不是规范 pool 相对路径: ${f}"
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

pool_relpath() {
  local pkg="$1" ver="$2" arch="$3"
  local prefix ver_fn rel
  dpkg --validate-version -- "${ver}" || die "包内 Version 非法: ${ver}"
  if [[ "${pkg}" == lib?* && ${#pkg} -ge 4 ]]; then
    prefix="${pkg:0:4}"
  else
    prefix="${pkg:0:1}"
  fi
  ver_fn="${ver//:/%3a}"
  rel="$(printf 'pool/main/%s/%s/%s_%s_%s.deb' "${prefix}" "${pkg}" "${pkg}" "${ver_fn}" "${arch}")"
  assert_pool_filename "${rel}" "pool 路径"
  printf '%s\n' "${rel}"
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
  )
  if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
    args+=(--passphrase-fd 0)
    printf '%s' "${GPG_PASSPHRASE}" | gpg "${args[@]}" --detach-sign --armor --output "${detach_out}" -- "${in}"
    printf '%s' "${GPG_PASSPHRASE}" | gpg "${args[@]}" --clearsign --output "${clear_out}" -- "${in}"
  else
    gpg "${args[@]}" --passphrase '' --detach-sign --armor --output "${detach_out}" -- "${in}"
    gpg "${args[@]}" --passphrase '' --clearsign --output "${clear_out}" -- "${in}"
  fi
}

validate_catalog() {
  local file="$1"
  jq -e 'type=="object" and .schema_version==1 and (.packages|type=="array")' "${file}" >/dev/null \
    || die "catalog 必须是 schema_version=1 且含 packages 数组"
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
    [[ -n "${id}" && "${id}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "非法 id: ${id}"
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

validate_previous_tree() {
  local root="$1"
  local rel path
  if find -- "${root}" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit | grep -q .; then
    die "previous 含符号链接或特殊文件，拒绝复制"
  fi
  while IFS= read -r -d '' path; do
    rel="${path#"${root}"/}"
    [[ "${rel}" != *..* ]] || die "previous 路径含 .. : ${rel}"
  done < <(find -- "${root}" -print0)
}

copy_previous_immutable() {
  local src="$1" dest="$2"
  local path rel hash name
  while IFS= read -r -d '' path; do
    rel="${path#"${src}"/}"
    case "${rel}" in
      pool/*.deb)
        [[ -f "${path}" ]] || die "pool 项不是普通文件: ${rel}"
        dpkg-deb -I -- "${path}" >/dev/null 2>&1 || die "previous 中不是合法 .deb: ${rel}"
        install -D -m 644 -- "${path}" "${dest}/${rel}"
        ;;
      dists/*/main/binary-*/by-hash/SHA256/*)
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
    if [[ -d "${src}/pool" ]] && [[ -n "$(find -- "${src}/pool" -type f -name '*.deb' -print -quit 2>/dev/null || true)" ]]; then
      die "previous 含 pool 但缺少 state.json"
    fi
    printf '%s\n' '{"schema_version":1,"packages":[]}' >"${dest}/prev-state.json"
    return
  fi
  [[ -f "${src}/state.json" && ! -L "${src}/state.json" ]] || die "previous/state.json 非法"
  jq -e 'type=="object" and .schema_version==1 and (.packages|type=="array")' "${src}/state.json" >/dev/null \
    || die "previous/state.json schema 无效"
  local row id filename sha size path resolved
  while IFS= read -r row; do
    id="$(jq -r '.id // empty' <<<"${row}")"
    while IFS= read -r asset; do
      filename="$(jq -r '.filename // empty' <<<"${asset}")"
      sha="$(jq -r '.sha256 // empty' <<<"${asset}")"
      size="$(jq -r '.size // empty' <<<"${asset}")"
      [[ "${sha}" =~ ${HEX64} ]] || die "previous state 摘要非法: ${id} ${filename}"
      assert_pool_filename "${filename}" "previous filename"
      path="${src}/${filename}"
      [[ -f "${path}" && ! -L "${path}" ]] || die "previous state 引用缺失: ${filename}"
      resolved="$(realpath -e -- "${path}")"
      under_dir "${src}" "${resolved}" || die "previous state 引用越界: ${filename}"
      [[ "$(hex_sha256 "${path}")" == "${sha}" ]] || die "previous 摘要不匹配: ${filename}"
      [[ "$(file_size "${path}")" == "${size}" ]] || die "previous 大小不匹配: ${filename}"
    done < <(jq -c '.assets[]?' <<<"${row}")
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

write_indexes() {
  local dest="$1" current_assets="$2"
  local all_pkg="${scratch}/all.packages"
  mkdir -p -- "${dest}/pool"
  if ! (
    cd -- "${dest}"
    apt-ftparchive --md5=off --sha1=off --sha512=off --sha256 packages pool
  ) >"${all_pkg}"; then
    die "apt-ftparchive packages 失败"
  fi
  local series arch allow pkgfile gzfile dist conf hash
  while IFS= read -r series; do
    dist="${dest}/dists/${series}"
    for arch in amd64 arm64; do
      mkdir -p -- "${dist}/main/binary-${arch}/by-hash/SHA256"
      allow="${scratch}/allow-${series}-${arch}.txt"
      : >"${allow}"
      jq -r --arg s "${series}" --arg a "${arch}" '
        .[] | select(.architecture==$a) | select(.series[]==$s) | .sha256
      ' "${current_assets}" >>"${allow}"
      pkgfile="${dist}/main/binary-${arch}/Packages"
      awk -v allowfile="${allow}" '
        BEGIN {
          while ((getline s < allowfile) > 0) if (s != "") ok[tolower(s)] = 1
          RS = ""
          FS = "\n"
        }
        {
          sha = ""
          archf = ""
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^SHA256: /) { split($i, a, " "); sha = tolower(a[2]) }
            if ($i ~ /^Architecture: /) { split($i, b, " "); archf = b[2] }
          }
          if (sha != "" && (sha in ok)) printf "%s\n\n", $0
        }
      ' "${all_pkg}" >"${pkgfile}"
      gzip -n -9 -c -- "${pkgfile}" >"${pkgfile}.gz"
    done
    conf="${scratch}/release-${series}.conf"
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
APT::FTPArchive::Release::Architectures "amd64 arm64";
APT::FTPArchive::Release::Acquire-By-Hash "yes";
APT::FTPArchive::Release::ValidTime "${VALID_UNTIL_SECONDS}";
EOF
    rm -f -- "${dist}/Release" "${dist}/Release.gpg" "${dist}/InRelease"
    apt-ftparchive -c "${conf}" release "${dist}" >"${scratch}/Release-${series}"
    if grep -E '[[:space:]]Release$' "${scratch}/Release-${series}" >/dev/null; then
      die "Release 不应包含对自身的摘要"
    fi
    mv -- "${scratch}/Release-${series}" "${dist}/Release"
    grep -q '^SHA256:' "${dist}/Release" || die "Release 缺少 SHA256"
    if grep -E '^(MD5Sum|SHA1|SHA512):' "${dist}/Release" >/dev/null; then
      die "Release 含非 SHA256 摘要，禁止降级"
    fi
    grep -q '^Acquire-By-Hash: yes$' "${dist}/Release" || die "Release 缺少 Acquire-By-Hash"
    grep -q '^Valid-Until:' "${dist}/Release" || die "Release 缺少 Valid-Until"
    for arch in amd64 arm64; do
      for pkgfile in "${dist}/main/binary-${arch}/Packages" "${dist}/main/binary-${arch}/Packages.gz"; do
        hash="$(hex_sha256 "${pkgfile}")"
        install -m 644 -- "${pkgfile}" "${dist}/main/binary-${arch}/by-hash/SHA256/${hash}"
      done
    done
    without_xtrace gpg_sign "${dist}/Release" "${dist}/Release.gpg" "${dist}/InRelease"
    [[ -s "${dist}/Release.gpg" && -s "${dist}/InRelease" ]] || die "签名文件为空: ${series}"
  done < <(supported_series)
}

write_state() {
  local dest="$1" rows="$2"
  jq -e --slurp '
    {schema_version:1, packages:(. | sort_by(.id))}
  ' "${rows}" >"${dest}/state.json"
  jq -e '.schema_version==1 and (.packages|type=="array")' "${dest}/state.json" >/dev/null \
    || die "生成 state.json 失败"
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
    -h|--help)
      usage ;;
    *)
      die "未知参数: $1" ;;
  esac
done

[[ -n "${catalog}" && -n "${releases}" && -n "${previous}" && -n "${output}" && -n "${gnupghome}" && -n "${fingerprint}" ]] || usage

require_cmd bash jq curl gpg gpg-agent dpkg-deb dpkg apt-ftparchive gzip flock sha256sum realpath date find install awk sed grep tr sort

catalog="$(assert_allowed_file catalog "${catalog}")"
releases="$(assert_allowed_file releases "${releases}")"
previous="$(assert_allowed_dir previous "${previous}" yes)"
output="$(assert_allowed_dir output "${output}" no)"
gnupghome="$(assert_allowed_dir gnupghome "${gnupghome}" yes)"
fingerprint="$(strip_fp "${fingerprint}")"
[[ "${fingerprint}" =~ ^[A-F0-9]{40}$ ]] || die "fingerprint 必须是 40 位十六进制完整指纹"

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
mkdir -p -- "${work}/pool"

validate_previous_tree "${previous}"
copy_previous_immutable "${previous}" "${work}"
load_previous_state "${previous}" "${scratch}"

now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
current_assets="${scratch}/current-assets.jsonl"
state_rows="${scratch}/state-rows.jsonl"
: >"${current_assets}"
: >"${state_rows}"

if [[ -n "$(jq -c '.packages[]?' "${catalog}")" ]]; then
while IFS= read -r pkgjson; do
  id="$(jq -r '.id' <<<"${pkgjson}")"
  repo="$(jq -r '.repository' <<<"${pkgjson}")"
  pkg="$(jq -r '.package' <<<"${pkgjson}")"
  desc="$(jq -r '.description' <<<"${pkgjson}")"
  src="$(jq -r '.source_url' <<<"${pkgjson}" | sed 's#/$##')"
  lic="$(jq -r '.license' <<<"${pkgjson}")"
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
  while IFS= read -r arch; do
    regex="$(jq -r --arg a "${arch}" '.architectures[$a]' <<<"${pkgjson}")"
    asset="$(match_unique_asset "${release_json}" "${regex}")"
    name="$(jq -r '.name' <<<"${asset}")"
    size="$(jq -r '.size' <<<"${asset}")"
    url="$(jq -r '.browser_download_url // empty' <<<"${asset}")"
    official="$(official_sha256 "${asset}")"
    [[ "${size}" =~ ^[1-9][0-9]*$ ]] || die "官方 size 非法: ${id} ${name}"
    assert_github_asset_url "${repo}" "${tag}" "${name}" "${url}"

    incoming="${scratch}/incoming-${id}-${arch}.deb"
    without_xtrace curl_https "${DOWNLOAD_TIMEOUT}" -o "${incoming}" -- "${url}" || die "下载失败: ${url}"
    got_size="$(file_size "${incoming}")"
    got_sha="$(hex_sha256 "${incoming}")"
    [[ "${got_size}" == "${size}" ]] || die "实际大小与官方 size 不符: ${name}"
    [[ "${got_sha}" == "${official}" ]] || die "实际 SHA256 与官方 digest 不符: ${name}"

    deb_pkg="$(dpkg-deb -f -- "${incoming}" Package)"
    deb_ver="$(dpkg-deb -f -- "${incoming}" Version)"
    deb_arch="$(dpkg-deb -f -- "${incoming}" Architecture)"
    [[ "${deb_pkg}" == "${pkg}" ]] || die "包内 Package=${deb_pkg} 与清单 ${pkg} 不符"
    [[ "${deb_arch}" == "${arch}" ]] || die "包内 Architecture=${deb_arch} 与 ${arch} 不符"
    [[ -n "${deb_ver}" ]] || die "包内 Version 为空: ${name}"
    dpkg --validate-version -- "${deb_ver}" || die "包内 Version 非法: ${name} ${deb_ver}"
    if [[ -z "${deb_version}" ]]; then
      deb_version="${deb_ver}"
    else
      compare_dpkg_versions "${deb_ver}" eq "${deb_version}" || die "同一软件不同架构 Version 不一致: ${id}"
    fi

    rel="$(pool_relpath "${pkg}" "${deb_ver}" "${arch}")"
    dest_deb="${work}/${rel}"
    dest_resolved="$(realpath -m -- "${dest_deb}")"
    under_dir "${work}" "${dest_resolved}" || die "pool 路径越界: ${rel}"
    if [[ -e "${dest_deb}" ]]; then
      [[ "$(hex_sha256 "${dest_deb}")" == "${got_sha}" ]] || die "禁止同名版本内容替换: ${rel}"
    else
      install -D -m 644 -- "${incoming}" "${dest_deb}"
    fi
    rm -f -- "${incoming}"

    asset_rows+=("$(jq -n \
      --arg architecture "${arch}" \
      --arg filename "${rel}" \
      --arg sha256 "${got_sha}" \
      --argjson size "${got_size}" \
      --arg url "${url}" \
      '{architecture:$architecture,filename:$filename,sha256:$sha256,size:$size,url:$url}')")
    archs="${archs} ${arch}"

    series_json="$(printf '%s\n' "${pkg_series[@]}" | jq -R . | jq -s .)"
    jq -n \
      --arg architecture "${arch}" \
      --arg sha256 "${got_sha}" \
      --argjson series "${series_json}" \
      '{architecture:$architecture,sha256:$sha256,series:$series}' >>"${current_assets}"
  done < <(jq -r '.architectures|keys[]' <<<"${pkgjson}")

  [[ -n "${deb_version}" ]] || die "软件 ${id} 没有有效资产"

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

  assets_json="$(printf '%s\n' "${asset_rows[@]}" | jq -s 'sort_by(.architecture)')"
  series_json="$(printf '%s\n' "${pkg_series[@]}" | jq -R . | jq -s .)"
  arch_json="$(printf '%s\n' ${archs} | awk 'NF' | jq -R . | jq -s .)"
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
    --argjson ubuntu_series "${series_json}" \
    --argjson architectures "${arch_json}" \
    --argjson assets "${assets_json}" \
    '{
      id:$id, package:$package, repository:$repository, description:$description,
      version:$version, release_url:$release_url, source_url:$source_url, license:$license,
      updated_at:$updated_at, ubuntu_series:$ubuntu_series, architectures:$architectures, assets:$assets
    }' >>"${state_rows}"
done < <(jq -c '.packages[]' "${catalog}")
fi

if [[ ! -s "${current_assets}" ]]; then
  printf '%s\n' '[]' >"${scratch}/current-assets.json"
else
  jq -s '.' "${current_assets}" >"${scratch}/current-assets.json"
fi
write_indexes "${work}" "${scratch}/current-assets.json"

if [[ ! -s "${state_rows}" ]]; then
  printf '%s\n' '{"schema_version":1,"packages":[]}' >"${work}/state.json"
else
  write_state "${work}" "${state_rows}"
fi

without_xtrace gpg --homedir "${gnupghome}" --batch --export -- "${fingerprint}" >"${work}/apt-hub.gpg"
[[ -s "${work}/apt-hub.gpg" ]] || die "导出公钥失败"
if grep -q 'BEGIN PGP PRIVATE KEY' "${work}/apt-hub.gpg"; then
  die "站点中出现私钥"
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
printf 'sync.sh: 候选站点已写入 %s\n' "${output}"
