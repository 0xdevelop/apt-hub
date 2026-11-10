#!/usr/bin/env bash
# Go deb Release：prepare / upload / prune。本地 build 不隐式联网写 release。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C
export LANGUAGE=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT_TMP="${PROJECT_ROOT}/tmp"

GO_TAG_RE='^go[0-9]+\.[0-9]+\.[0-9]+$'
REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
HEX40='^[a-f0-9]{40}$'
REL_TAG_RE='^golang-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*$'
DEC_POS='^[1-9][0-9]*$'

die() {
  printf 'release_golang.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/release_golang.sh prepare --repository <owner/repo> --config <config/go.json>
      [--work-dir <tmp内目录>] [--downloads-json <已有索引>] [--version <goX.Y.Z>]
  scripts/release_golang.sh status --repository <owner/repo> --tag <golang-X.Y.Z-R>
      [--fetch-dir <tmp内目录>]
  scripts/release_golang.sh upload --repository <owner/repo> --tag <golang-X.Y.Z-R>
      --asset-dir <构包输出> --source-sha <40hex> [--draft-body <文件>]
  scripts/release_golang.sh prune --repository <owner/repo> --current-tag <golang-X.Y.Z-R>
      [--apt-data-ref <ref>] [--keep-recent <N>]
EOF
  exit 2
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v -- "${c}" >/dev/null 2>&1 || die "缺少命令: ${c}"
  done
}

under_dir() {
  local parent="$1" child="$2"
  [[ "${child}" == "${parent}" || "${child}" == "${parent}/"* ]]
}

assert_no_symlink_components() {
  local path="$1"
  local prefix="" part
  [[ "${path}" == /* ]] || die "路径必须是绝对路径: ${path}"
  prefix="/"
  local -a parts=()
  IFS=/ read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [[ -n "${part}" ]] || continue
    prefix="${prefix%/}/${part}"
    if [[ -L "${prefix}" ]]; then
      die "路径含符号链接: ${prefix}"
    fi
  done
}

abs_path() {
  local p="$1"
  [[ -n "${p}" ]] || die "空路径"
  case "${p}" in
    *..*) die "路径含 ..: ${p}" ;;
  esac
  if [[ "${p}" != /* ]]; then
    p="${PWD%/}/${p}"
  fi
  if [[ "${p}" != / ]]; then
    p="${p%/}"
  fi
  printf '%s\n' "${p}"
}

# 用户/显式 tmp 目录：拒 symlink、拒根；已存在则必须可枚举且为空——绝不凭 marker 整目录删除。
ensure_empty_tmp_dir() {
  local role="$1" raw="$2"
  local abs parent base listing=""
  abs="$(abs_path "${raw}")"
  parent="$(dirname -- "${abs}")"
  base="$(basename -- "${abs}")"
  [[ "${base}" != "." && "${base}" != ".." && "${base}" != "/" && "${base}" != "tmp" ]] \
    || die "${role} 非法目录名"
  [[ -e "${parent}" ]] || die "${role} 父目录不存在"
  [[ -d "${parent}" && ! -L "${parent}" ]] || die "${role} 父目录非法"
  assert_no_symlink_components "${parent}"
  under_dir "${PROJECT_TMP}" "${abs}" || die "${role} 必须位于项目 tmp/ 下"
  [[ "${abs}" != "${PROJECT_ROOT}" && "${abs}" != "${PROJECT_TMP}" ]] \
    || die "${role} 不能是项目根或 tmp 根"
  if [[ -e "${abs}" || -L "${abs}" ]]; then
    [[ ! -L "${abs}" ]] || die "${role} 不能是符号链接"
    [[ -d "${abs}" ]] || die "${role} 已存在且不是目录"
    assert_no_symlink_components "${abs}"
    listing="$(find -- "${abs}" -mindepth 1 -maxdepth 1 -print -quit)" || die "${role} 无法枚举"
    [[ -z "${listing}" ]] || die "${role} 已有内容，拒绝覆盖（不删调用方输入）"
  else
    mkdir -m 755 -- "${abs}" || die "${role} 无法创建"
    assert_no_symlink_components "${abs}"
  fi
  printf '%s\n' "${abs}"
}

# 本次独占 scratch：mktemp，退出时由调用方 cleanup_owned_dir 精确删除。
make_scratch_tmp_dir() {
  local prefix="$1"
  local d
  mkdir -p -- "${PROJECT_TMP}" || die "无法确保 tmp 根"
  d="$(mktemp -d --tmpdir="${PROJECT_TMP}" "${prefix}.XXXXXX")" || die "mktemp 失败"
  assert_no_symlink_components "${d}"
  printf '%s\n' "${d}"
}

cleanup_owned_dir() {
  local d="$1"
  [[ -n "${d}" ]] || return 0
  under_dir "${PROJECT_TMP}" "${d}" || return 0
  [[ "${d}" != "${PROJECT_TMP}" && "${d}" != "${PROJECT_ROOT}" ]] || return 0
  if [[ -d "${d}" && ! -L "${d}" ]]; then
    rm -rf -- "${d}"
  fi
}

assert_no_path_overlap() {
  local a="$1" b="$2" msg="$3"
  if under_dir "${a}" "${b}" || under_dir "${b}" "${a}"; then
    die "${msg}"
  fi
}

is_gzip_file() {
  local f="$1"
  local magic
  [[ -f "${f}" && ! -L "${f}" ]] || return 1
  magic="$(od -An -N2 -tx1 -- "${f}" | tr -d ' \n')"
  [[ "${magic}" == "1f8b" ]]
}

select_stable_version() {
  # 先完整落盘并核 jq 退出码，再消费；禁止 process substitution 吞部分成功后的非 0。
  local index="$1"
  local best_tag="" best_ver="" tag ver tags_file jq_rc=0 bad=0 bad_msg=""
  mkdir -p -- "${PROJECT_TMP}" || die "无法确保 tmp 根"
  tags_file="$(mktemp --tmpdir="${PROJECT_TMP}" go-stable-tags.XXXXXX)" || die "mktemp stable 失败"
  jq -r '.[] | select(.stable==true) | .version' "${index}" >"${tags_file}" || jq_rc=$?
  if [[ "${jq_rc}" -ne 0 ]]; then
    rm -f -- "${tags_file}"
    die "枚举官方 stable 版本失败 rc=${jq_rc}"
  fi
  while IFS= read -r tag || [[ -n "${tag}" ]]; do
    [[ -n "${tag}" ]] || continue
    if ! [[ "${tag}" =~ ${GO_TAG_RE} ]]; then
      bad=1
      bad_msg="拒绝非稳定 go 版本: ${tag}"
      break
    fi
    ver="${tag#go}"
    if [[ -z "${best_ver}" ]] || dpkg --compare-versions "${ver}" gt "${best_ver}"; then
      best_ver="${ver}"
      best_tag="${tag}"
    fi
  done <"${tags_file}"
  rm -f -- "${tags_file}"
  [[ "${bad}" -eq 0 ]] || die "${bad_msg}"
  [[ -n "${best_tag}" ]] || die "官方索引无 stable 版本"
  printf '%s\n' "${best_tag}"
}

cmd_prepare() {
  local repository="" config="" work_dir="" downloads_json="" version_lock="" revision=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repository) [[ $# -ge 2 ]] || usage; repository="$2"; shift 2 ;;
      --config) [[ $# -ge 2 ]] || usage; config="$2"; shift 2 ;;
      --work-dir) [[ $# -ge 2 ]] || usage; work_dir="$2"; shift 2 ;;
      --downloads-json) [[ $# -ge 2 ]] || usage; downloads_json="$2"; shift 2 ;;
      --version) [[ $# -ge 2 ]] || usage; version_lock="$2"; shift 2 ;;
      *) die "prepare 未知参数: $1" ;;
    esac
  done
  [[ -n "${repository}" && -n "${config}" ]] || usage
  [[ "${repository}" =~ ${REPO_RE} ]] || die "repository 非法: ${repository}"
  require_cmd jq curl dpkg

  config="$(abs_path "${config}")"
  [[ -f "${config}" && ! -L "${config}" ]] || die "config 不是普通文件"
  assert_no_symlink_components "$(dirname -- "${config}")"
  revision="$(jq -r '.revision' "${config}")" || die "读取 revision 失败"
  [[ "${revision}" =~ ${DEC_POS} ]] || die "revision 非法"
  index_url="$(jq -r '.release_index_url' "${config}")" || die "读取 release_index_url 失败"
  [[ "${index_url}" == "https://go.dev/dl/?mode=json" ]] || die "release_index_url 必须为官方 JSON"

  if [[ -z "${work_dir}" ]]; then
    work_dir="${PROJECT_TMP}/go-release-prepare"
  fi
  # 先规范化全部路径并查重叠，再碰磁盘——禁止 claim 先删输入。
  work_dir="$(abs_path "${work_dir}")"
  if [[ -n "${downloads_json}" ]]; then
    downloads_json="$(abs_path "${downloads_json}")"
    [[ -f "${downloads_json}" && ! -L "${downloads_json}" ]] || die "downloads-json 非法"
    assert_no_symlink_components "$(dirname -- "${downloads_json}")"
    assert_no_path_overlap "${downloads_json}" "${work_dir}" "downloads-json 与 work-dir 重叠"
  fi
  assert_no_path_overlap "${config}" "${work_dir}" "config 与 work-dir 重叠"
  work_dir="$(ensure_empty_tmp_dir "work-dir" "${work_dir}")"

  local index_file="${work_dir}/downloads.json"
  if [[ -n "${downloads_json}" ]]; then
    cp -a -- "${downloads_json}" "${index_file}" || die "复制 downloads-json 失败"
  else
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --connect-timeout 20 --max-time 120 \
      -o "${index_file}" -- "${index_url}" \
      || die "拉取官方索引失败"
  fi
  jq -e 'type=="array" and length>0' "${index_file}" >/dev/null || die "官方索引非法"

  local tag
  if [[ -n "${version_lock}" ]]; then
    [[ "${version_lock}" =~ ${GO_TAG_RE} ]] || die "非法 --version: ${version_lock}"
    local count
    count="$(jq -r --arg v "${version_lock}" '[.[]|select(.version==$v)]|length' "${index_file}")"
    [[ "${count}" == "1" ]] || die "索引无锁定版本: ${version_lock}"
    tag="${version_lock}"
  else
    tag="$(select_stable_version "${index_file}")" || die "选择稳定版本失败"
  fi
  local ver="${tag#go}"
  local go_release_tag="golang-${ver}-${revision}"
  [[ "${go_release_tag}" =~ ${REL_TAG_RE} ]] || die "派生 tag 非法: ${go_release_tag}"

  printf '%s\n' "${go_release_tag}" >"${work_dir}/go_release_tag"
  printf '%s\n' "${tag}" >"${work_dir}/go_version"
  printf '%s\n' "${revision}" >"${work_dir}/revision"
  printf '%s\n' "${repository}" >"${work_dir}/repository"

  # 机器可读：后续 build --go-version / workflow outputs
  printf 'go_release_tag=%s\n' "${go_release_tag}"
  printf 'go_version=%s\n' "${tag}"
  printf 'revision=%s\n' "${revision}"
  printf 'downloads_json=%s\n' "${index_file}"
  printf 'repository=%s\n' "${repository}"
}

gh_api() {
  local method="$1" path="$2"
  shift 2
  local url="https://api.github.com${path}"
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 120 \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -X "${method}" \
    "$@" \
    -- "${url}"
}

gh_api_code() {
  local method="$1" path="$2" out="$3"
  shift 3
  local url="https://api.github.com${path}"
  curl -sS --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 120 \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -X "${method}" \
    -o "${out}" -w '%{http_code}' \
    "$@" \
    -- "${url}" || true
}

asset_digest_ok() {
  local local_file="$1" remote_sha="$2" remote_size="$3"
  local got_sha got_size
  got_size="$(stat -c '%s' -- "${local_file}")"
  got_sha="$(sha256sum -- "${local_file}" | awk '{print $1}')"
  [[ "${got_size}" == "${remote_size}" ]] || return 1
  # GitHub 可能给 sha256: 前缀 digest，或仅 size；有 digest 必须匹配。
  if [[ -n "${remote_sha}" && "${remote_sha}" != "null" ]]; then
    remote_sha="${remote_sha#sha256:}"
    [[ "${got_sha}" == "${remote_sha}" ]] || return 1
  fi
  return 0
}

required_asset_names() {
  local asset_dir="$1"
  local deb
  printf '%s\n' "SHA256SUMS" "provenance.json"
  while IFS= read -r deb; do
    basename -- "${deb}"
  done < <(find -- "${asset_dir}" -maxdepth 1 -type f -name 'golang*.deb' | LC_ALL=C sort)
}

# 双层：远端 size/digest + 本地 SHA256SUMS/control；忽略 provenance.generated_at_utc。
provenance_packages_equal() {
  local a="$1" b="$2"
  jq -e --slurpfile other "${b}" '
    (.packages | sort_by(.package,.architecture)) as $p1
    | ($other[0].packages | sort_by(.package,.architecture)) as $p2
    | ($p1|length) > 0
    and ($p1|length) == ($p2|length)
    and ([range(0; $p1|length) | $p1[.] == $p2[.]] | all)
  ' "${a}" >/dev/null
}

verify_local_asset_set() {
  # 可选第二参 expected_tag=golang-X.Y.Z-R：绑定版本/上游 URL，拒绝借别 tag 资产。
  # 正式双 arch：四组合 (package,architecture) 唯一齐全；filename 唯一；
  # manifest/SHA256SUMS/磁盘 deb 成员精确一致；拒重复/缺组合/孤儿坏包。
  local asset_dir="$1"
  local expected_tag="${2-}"
  local sums prov expected_fn_ver line fn hash ver_fn
  local names_file rows_file disk_file jq_rc=0
  local -a sum_files=() expected_files=() expected_debs=() disk_debs=()
  sums="${asset_dir}/SHA256SUMS"
  prov="${asset_dir}/provenance.json"
  [[ -f "${sums}" && ! -L "${sums}" && -f "${prov}" && ! -L "${prov}" ]] || return 1
  jq -e '
    .schema_version=="1"
    and (.packages|type=="array" and length==4)
    and (([.packages[] | [.package,.architecture]] | unique | length) == 4)
    and (([.packages[].filename] | unique | length) == 4)
    and (([.packages[] | .package + "/" + .architecture] | sort)
         == ["golang-go/amd64","golang-go/arm64","golang/amd64","golang/arm64"])
    and (.upstream.version|type=="string" and test("^go[0-9]+\\.[0-9]+\\.[0-9]+$"))
    and (.upstream.epoch=="2")
    and (.upstream.version_debian|type=="string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
    and all(.packages[];
      (.filename|type=="string")
      and (.filename|test("^[^/\\\\]+$"))
      and (.filename|contains("..")|not)
      and (.sha256|test("^[a-f0-9]{64}$"))
      and (.size|type=="string" and test("^[1-9][0-9]*$"))
      and (.architecture|test("^(amd64|arm64)$"))
      and (.package|test("^(golang|golang-go)$"))
      and (.version|test("^2:[0-9]+\\.[0-9]+\\.[0-9]+-[1-9][0-9]*$"))
      and (.upstream.url|type=="string")
      and (.upstream.sha256|test("^[a-f0-9]{64}$"))
      and (.upstream.size|type=="string" and test("^[1-9][0-9]*$"))
    )
  ' "${prov}" >/dev/null || return 1

  if [[ -n "${expected_tag}" ]]; then
    [[ "${expected_tag}" =~ ${REL_TAG_RE} ]] || return 1
    expected_fn_ver="${expected_tag#golang-}"
    jq -e --arg v "2:${expected_fn_ver}" --arg gv "go${expected_fn_ver%-*}" --arg vd "${expected_fn_ver%-*}" '
      (.upstream.version==$gv)
      and (.upstream.version_debian==$vd)
      and (.upstream.epoch=="2")
      and all(.packages[]; .version==$v)
    ' "${prov}" >/dev/null || return 1
  fi

  mkdir -p -- "${PROJECT_TMP}" || return 1
  names_file="$(mktemp --tmpdir="${PROJECT_TMP}" go-asset-names.XXXXXX)" || return 1
  jq_rc=0
  jq -r '.packages[].filename' "${prov}" >"${names_file}" || jq_rc=$?
  if [[ "${jq_rc}" -ne 0 ]]; then
    rm -f -- "${names_file}"
    return 1
  fi
  # 不用 sort -u 折叠重复名：四行必须四名。
  mapfile -t expected_files <"${names_file}"
  rm -f -- "${names_file}"
  [[ "${#expected_files[@]}" -eq 4 ]] || return 1
  expected_files+=("provenance.json")
  mapfile -t expected_files < <(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort)

  sum_files=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^[0-9a-f]{64}[[:space:]]{2}[^[:space:]]+$ ]] || return 1
    hash="${line%%  *}"
    fn="${line#*  }"
    [[ "${#hash}" -eq 64 ]] || return 1
    [[ "${fn}" != */* && "${fn}" != *\\* && "${fn}" != *..* ]] || return 1
    sum_files+=("${fn}")
  done <"${sums}"
  mapfile -t sum_files < <(printf '%s\n' "${sum_files[@]}" | LC_ALL=C sort)
  [[ "${#sum_files[@]}" -eq "${#expected_files[@]}" ]] || return 1
  [[ "$(printf '%s\n' "${sum_files[@]}")" == "$(printf '%s\n' "${expected_files[@]}")" ]] || return 1

  # 磁盘 golang*.deb 必须与清单 filename 精确一致（拒孤儿坏包）。
  disk_file="$(mktemp --tmpdir="${PROJECT_TMP}" go-disk-debs.XXXXXX)" || return 1
  if ! find -- "${asset_dir}" -maxdepth 1 -type f -name 'golang*.deb' -printf '%f\n' \
    >"${disk_file}.raw"; then
    rm -f -- "${disk_file}" "${disk_file}.raw"
    return 1
  fi
  if ! LC_ALL=C sort -o "${disk_file}" "${disk_file}.raw"; then
    rm -f -- "${disk_file}" "${disk_file}.raw"
    return 1
  fi
  rm -f -- "${disk_file}.raw"
  mapfile -t disk_debs <"${disk_file}"
  rm -f -- "${disk_file}"
  mapfile -t expected_debs < <(printf '%s\n' "${expected_files[@]}" | grep -E '^golang' | LC_ALL=C sort || true)
  [[ "${#expected_debs[@]}" -eq 4 ]] || return 1
  [[ "${#disk_debs[@]}" -eq 4 ]] || return 1
  [[ "$(printf '%s\n' "${disk_debs[@]}")" == "$(printf '%s\n' "${expected_debs[@]}")" ]] || return 1

  (cd -- "${asset_dir}" && sha256sum -c --strict SHA256SUMS) >/dev/null || return 1

  local row arch ver pkg up_url got_pkg got_ver got_arch got_sha got_sz
  local upstream_go
  upstream_go="$(jq -r '.upstream.version' "${prov}")" || return 1
  rows_file="$(mktemp --tmpdir="${PROJECT_TMP}" go-prov-rows.XXXXXX)" || return 1
  jq_rc=0
  jq -c '.packages[]' "${prov}" >"${rows_file}" || jq_rc=$?
  if [[ "${jq_rc}" -ne 0 ]]; then
    rm -f -- "${rows_file}"
    return 1
  fi
  # 行数必须仍为 4；producer 半截不得当成功。
  if [[ "$(wc -l <"${rows_file}" | tr -d ' ')" != "4" ]]; then
    rm -f -- "${rows_file}"
    return 1
  fi
  local row_ok=1
  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -n "${row}" ]] || continue
    fn="$(jq -r '.filename' <<<"${row}")" || { row_ok=0; break; }
    arch="$(jq -r '.architecture' <<<"${row}")" || { row_ok=0; break; }
    ver="$(jq -r '.version' <<<"${row}")" || { row_ok=0; break; }
    pkg="$(jq -r '.package' <<<"${row}")" || { row_ok=0; break; }
    up_url="$(jq -r '.upstream.url' <<<"${row}")" || { row_ok=0; break; }
    ver_fn="${ver#2:}"
    [[ "${ver}" == "2:${ver_fn}" ]] || { row_ok=0; break; }
    [[ "${fn}" == "${pkg}_${ver_fn}_${arch}.deb" ]] || { row_ok=0; break; }
    [[ "${up_url}" == "https://go.dev/dl/${upstream_go}.linux-${arch}.tar.gz" ]] || { row_ok=0; break; }
    [[ -f "${asset_dir}/${fn}" && ! -L "${asset_dir}/${fn}" ]] || { row_ok=0; break; }
    got_pkg="$(dpkg-deb -f -- "${asset_dir}/${fn}" Package)" || { row_ok=0; break; }
    got_ver="$(dpkg-deb -f -- "${asset_dir}/${fn}" Version)" || { row_ok=0; break; }
    got_arch="$(dpkg-deb -f -- "${asset_dir}/${fn}" Architecture)" || { row_ok=0; break; }
    [[ "${got_pkg}" == "${pkg}" && "${got_ver}" == "${ver}" && "${got_arch}" == "${arch}" ]] || { row_ok=0; break; }
    got_sha="$(sha256sum -- "${asset_dir}/${fn}" | awk '{print $1}')" || { row_ok=0; break; }
    got_sz="$(stat -c '%s' -- "${asset_dir}/${fn}")" || { row_ok=0; break; }
    [[ "${got_sha}" == "$(jq -r '.sha256' <<<"${row}")" ]] || { row_ok=0; break; }
    [[ "${got_sz}" == "$(jq -r '.size' <<<"${row}")" ]] || { row_ok=0; break; }
  done <"${rows_file}"
  rm -f -- "${rows_file}"
  [[ "${row_ok}" -eq 1 ]] || return 1
  return 0
}

assert_release_identity() {
  local rel_json="$1" repository="$2" tag="$3"
  local got_tag html expect
  got_tag="$(jq -r '.tag_name // empty' "${rel_json}")"
  html="$(jq -r '.html_url // empty' "${rel_json}")"
  [[ "${got_tag}" == "${tag}" ]] || die "release.tag_name 与请求 tag 不一致"
  [[ -n "${html}" ]] || die "release.html_url 缺失"
  expect="https://github.com/${repository}/releases/tag/${tag}"
  [[ "${html}" == "${expect}" ]] || die "release.html_url 与仓库/tag 不匹配"
}

remote_release_asset_complete() {
  # 仅 published 可 complete；draft 永远不完整；单架构不算 complete。
  local rel_json="$1"
  local state name sz amd_n arm_n
  state="$(jq -r 'if .draft then "draft" elif .prerelease then "prerelease" else "published" end' "${rel_json}")"
  [[ "${state}" == "published" ]] || return 1
  for name in SHA256SUMS provenance.json; do
    sz="$(jq -r --arg n "${name}" '[.assets[]|select(.name==$n)|.size]|first|tostring' "${rel_json}")"
    [[ "${sz}" =~ ^[1-9][0-9]*$ ]] || return 1
  done
  # 每 arch 须同时有 golang_ 与 golang-go_ 两 deb。
  amd_n="$(jq -r '[.assets[]|select(.name|test("^(golang|golang-go)_.*_amd64\\.deb$"))]|length' "${rel_json}")"
  arm_n="$(jq -r '[.assets[]|select(.name|test("^(golang|golang-go)_.*_arm64\\.deb$"))]|length' "${rel_json}")"
  [[ "${amd_n}" == "2" && "${arm_n}" == "2" ]] || return 1
  return 0
}

cmd_status() {
  local repository="" tag="" fetch_dir=""
  local work=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repository) [[ $# -ge 2 ]] || usage; repository="$2"; shift 2 ;;
      --tag) [[ $# -ge 2 ]] || usage; tag="$2"; shift 2 ;;
      --fetch-dir) [[ $# -ge 2 ]] || usage; fetch_dir="$2"; shift 2 ;;
      *) die "status 未知参数: $1" ;;
    esac
  done
  [[ -n "${repository}" && -n "${tag}" ]] || usage
  [[ "${repository}" =~ ${REPO_RE} ]] || die "repository 非法"
  [[ "${tag}" =~ ${REL_TAG_RE} ]] || die "tag 非法"
  [[ -n "${GH_TOKEN:-}" ]] || die "缺少 GH_TOKEN"
  require_cmd jq curl sha256sum gh dpkg-deb

  work="$(make_scratch_tmp_dir "go-release-status")"
  # shellcheck disable=SC2064
  trap 'cleanup_owned_dir "'"${work}"'"' RETURN
  local rel_json="${work}/release.json"
  local code
  code="$(gh_api_code GET "/repos/${repository}/releases/tags/${tag}" "${rel_json}")"
  if [[ "${code}" == "404" ]]; then
    printf 'release_state=missing\n'
    printf 'assets_complete=0\n'
    printf 'go_release_tag=%s\n' "${tag}"
    return 0
  fi
  [[ "${code}" == "200" ]] || die "查询 release 失败 HTTP ${code}"
  assert_release_identity "${rel_json}" "${repository}" "${tag}"
  local state
  state="$(jq -r 'if .draft then "draft" elif .prerelease then "prerelease" else "published" end' "${rel_json}")"
  printf 'release_state=%s\n' "${state}"
  if [[ "${state}" != "published" ]]; then
    # draft/prerelease 半套不得视 complete
    printf 'assets_complete=0\n'
    printf 'go_release_tag=%s\n' "${tag}"
    return 0
  fi
  if ! remote_release_asset_complete "${rel_json}"; then
    printf 'assets_complete=0\n'
    printf 'go_release_tag=%s\n' "${tag}"
    return 0
  fi

  if [[ -z "${fetch_dir}" ]]; then
    printf 'assets_complete=1\n'
    printf 'go_release_tag=%s\n' "${tag}"
    return 0
  fi

  # 先 abs + 拒已有用户内容，再下载；绝不凭 marker 整目录删除。
  fetch_dir="$(abs_path "${fetch_dir}")"
  fetch_dir="$(ensure_empty_tmp_dir "fetch-dir" "${fetch_dir}")"
  local name
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    case "${name}" in
      *..*|*/|*\\*) die "非法资产名: ${name}" ;;
    esac
    GH_REPO="${repository}" gh release download "${tag}" -p "${name}" -D "${fetch_dir}" \
      || die "下载资产失败: ${name}"
  done < <(jq -r '.assets[].name' "${rel_json}")
  verify_local_asset_set "${fetch_dir}" "${tag}" || die "远端 published 资产核验失败（hash/size/control/tag）"
  printf 'assets_complete=1\n'
  printf 'assets_reused=1\n'
  printf 'fetch_dir=%s\n' "${fetch_dir}"
  printf 'go_release_tag=%s\n' "${tag}"
}

cmd_upload() {
  local repository="" tag="" asset_dir="" source_sha="" draft_body=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repository) [[ $# -ge 2 ]] || usage; repository="$2"; shift 2 ;;
      --tag) [[ $# -ge 2 ]] || usage; tag="$2"; shift 2 ;;
      --asset-dir) [[ $# -ge 2 ]] || usage; asset_dir="$2"; shift 2 ;;
      --source-sha) [[ $# -ge 2 ]] || usage; source_sha="$2"; shift 2 ;;
      --draft-body) [[ $# -ge 2 ]] || usage; draft_body="$2"; shift 2 ;;
      *) die "upload 未知参数: $1" ;;
    esac
  done
  [[ -n "${repository}" && -n "${tag}" && -n "${asset_dir}" && -n "${source_sha}" ]] || usage
  [[ "${repository}" =~ ${REPO_RE} ]] || die "repository 非法"
  [[ "${tag}" =~ ${REL_TAG_RE} ]] || die "tag 非法: ${tag}"
  [[ "${source_sha}" =~ ${HEX40} ]] || die "source-sha 必须为 40hex（禁止 latest）"
  [[ -n "${GH_TOKEN:-}" ]] || die "缺少 GH_TOKEN"
  require_cmd jq curl sha256sum gh stat

  asset_dir="$(abs_path "${asset_dir}")"
  [[ -d "${asset_dir}" && ! -L "${asset_dir}" ]] || die "asset-dir 非法"
  assert_no_symlink_components "${asset_dir}"
  # 任何 create/upload/edit 之前完整本地核验：半套/错 hash/traversal/未知成员一律拒绝。
  verify_local_asset_set "${asset_dir}" "${tag}" || die "本地 asset-dir 未通过 hash/size/control/成员核验"
  mapfile -t debs < <(find -- "${asset_dir}" -maxdepth 1 -type f -name 'golang*.deb' | LC_ALL=C sort)
  [[ "${#debs[@]}" -eq 4 ]] || die "asset-dir 必须恰好四个 deb（golang+golang-go × 双 arch）"

  local work
  work="$(make_scratch_tmp_dir "go-release-upload")"
  # shellcheck disable=SC2064
  trap 'cleanup_owned_dir "'"${work}"'"' RETURN
  local rel_json="${work}/release.json"
  local code
  code="$(gh_api_code GET "/repos/${repository}/releases/tags/${tag}" "${rel_json}")"
  local state="" release_id=""
  if [[ "${code}" == "200" ]]; then
    assert_release_identity "${rel_json}" "${repository}" "${tag}"
    state="$(jq -r 'if .draft then "draft" elif .prerelease then "prerelease" else "published" end' "${rel_json}")"
    release_id="$(jq -r '.id|tostring' "${rel_json}")"
  elif [[ "${code}" == "404" ]]; then
    state="missing"
  else
    die "查询 release 失败 HTTP ${code}"
  fi

  if [[ "${state}" == "published" ]]; then
    if ! remote_release_asset_complete "${rel_json}"; then
      die "已 published 但远端资产不完整，拒绝覆盖/续传"
    fi
    # 幂等：按双层 hash/size + provenance.packages（忽略 generated_at）比对；不 --clobber。
    local name local_path remote_size remote_digest tmp_dl="${work}/pub-dl"
    mkdir -p -- "${tmp_dl}"
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      local_path="${asset_dir}/${name}"
      [[ -f "${local_path}" ]] || die "本地缺少 ${name}"
      remote_size="$(jq -r --arg n "${name}" \
        '[.assets[]|select(.name==$n)|.size]|first|tostring' "${rel_json}")"
      remote_digest="$(jq -r --arg n "${name}" \
        '[.assets[]|select(.name==$n)|(.digest // empty)]|first // empty' "${rel_json}")"
      [[ "${remote_size}" =~ ^[1-9][0-9]*$ ]] || die "远端缺少资产: ${name}"
      if [[ "${name}" == "provenance.json" ]]; then
        rm -f -- "${tmp_dl}/${name}"
        GH_REPO="${repository}" gh release download "${tag}" -p "${name}" -D "${tmp_dl}" \
          || die "下载远端 provenance 失败"
        if provenance_packages_equal "${local_path}" "${tmp_dl}/${name}"; then
          continue
        fi
        die "已 published 的 provenance.packages 与本地不一致（非 generated_at），拒绝覆盖"
      fi
      if ! asset_digest_ok "${local_path}" "${remote_digest}" "${remote_size}"; then
        # digest 缺失时回下比对，避免仅因 timestamp 误判
        rm -f -- "${tmp_dl}/${name}"
        GH_REPO="${repository}" gh release download "${tag}" -p "${name}" -D "${tmp_dl}" \
          || die "下载远端 ${name} 失败"
        if cmp -s -- "${local_path}" "${tmp_dl}/${name}"; then
          continue
        fi
        die "已 published 的 ${name} 与本地 bytes 不一致，拒绝覆盖"
      fi
    done < <(required_asset_names "${asset_dir}")
    printf 'upload_status=idempotent_published\n'
    printf 'go_release_tag=%s\n' "${tag}"
    return 0
  fi

  if [[ "${state}" == "missing" ]]; then
    local body_file="${work}/body.md"
    if [[ -n "${draft_body}" ]]; then
      cp -a -- "$(abs_path "${draft_body}")" "${body_file}"
    else
      printf '%s\n' "apt-hub Go toolchain ${tag} (source ${source_sha})" >"${body_file}"
    fi
    # draft 先建；make_latest=false 避免抢仓脚本 latest。
    GH_REPO="${repository}" gh release create "${tag}" \
      --draft \
      --latest=false \
      --target "${source_sha}" \
      --title "${tag}" \
      --notes-file "${body_file}" \
      || die "创建 draft release 失败"
    code="$(gh_api_code GET "/repos/${repository}/releases/tags/${tag}" "${rel_json}")"
    [[ "${code}" == "200" ]] || die "创建后无法读取 draft HTTP ${code}"
    assert_release_identity "${rel_json}" "${repository}" "${tag}"
    release_id="$(jq -r '.id|tostring' "${rel_json}")"
    state="draft"
  fi

  [[ "${state}" == "draft" || "${state}" == "published" ]] || die "拒绝操作 prerelease/未知状态: ${state}"
  [[ "${release_id}" =~ ^[1-9][0-9]*$ ]] || die "release id 非法"

  if [[ "${state}" == "draft" ]]; then
    # 上传全部资产；已有同名则先比对，不同 bytes 拒绝。
    local f bn existing
    for f in "${debs[@]}" "${asset_dir}/provenance.json" "${asset_dir}/SHA256SUMS"; do
      bn="$(basename -- "${f}")"
      existing="$(jq -r --arg n "${bn}" \
        '.assets[]|select(.name==$n)|.id|tostring' "${rel_json}" 2>/dev/null || true)"
      if [[ -n "${existing}" && "${existing}" != "null" ]]; then
        remote_size="$(jq -r --arg n "${bn}" \
          '.assets[]|select(.name==$n)|.size|tostring' "${rel_json}")"
        remote_digest="$(jq -r --arg n "${bn}" \
          '.assets[]|select(.name==$n)|(.digest // empty)' "${rel_json}")"
        if asset_digest_ok "${f}" "${remote_digest}" "${remote_size}"; then
          continue
        fi
        die "draft 已有不同内容的资产 ${bn}，拒绝"
      fi
      GH_REPO="${repository}" gh release upload "${tag}" "${f}" --clobber=false \
        || die "上传失败: ${bn}"
    done
    # 重新读取并逐文件核 size（及 digest 若有）
    code="$(gh_api_code GET "/repos/${repository}/releases/tags/${tag}" "${rel_json}")"
    [[ "${code}" == "200" ]] || die "上传后读取 release 失败 HTTP ${code}"
    assert_release_identity "${rel_json}" "${repository}" "${tag}"
    for f in "${debs[@]}" "${asset_dir}/provenance.json" "${asset_dir}/SHA256SUMS"; do
      bn="$(basename -- "${f}")"
      remote_size="$(jq -r --arg n "${bn}" \
        '.assets[]|select(.name==$n)|.size|tostring' "${rel_json}")"
      remote_digest="$(jq -r --arg n "${bn}" \
        '.assets[]|select(.name==$n)|(.digest // empty)' "${rel_json}")"
      [[ "${remote_size}" =~ ^[0-9]+$ ]] || die "远端缺少资产: ${bn}"
      asset_digest_ok "${f}" "${remote_digest}" "${remote_size}" \
        || die "上传后校验失败: ${bn}"
      # 再下载一次核对（不只命令 exit 0）
      rm -f -- "${work}/${bn}"
      GH_REPO="${repository}" gh release download "${tag}" -p "${bn}" -D "${work}" \
        || die "回下资产失败: ${bn}"
      [[ -f "${work}/${bn}" ]] || die "回下后缺少文件: ${bn}"
      cmp -s -- "${f}" "${work}/${bn}" || die "回下字节不一致: ${bn}"
      rm -f -- "${work}/${bn}"
    done
    GH_REPO="${repository}" gh release edit "${tag}" --draft=false --latest=false \
      || die "publish draft 失败"
    printf 'upload_status=published\n'
  fi

  printf 'go_release_tag=%s\n' "${tag}"
}

extract_tags_from_bytes() {
  local src="$1" out="$2"
  # grep 无匹配是正常；管道失败才拒。在 || 上下文须显式返回，不靠 set -e。
  local grc=0
  grep -oE 'golang-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*' "${src}" >>"${out}" || grc=$?
  if [[ "${grc}" -eq 0 || "${grc}" -eq 1 ]]; then
    return 0
  fi
  printf 'release_golang.sh: 解析引用 grep 失败 rc=%s\n' "${grc}" >&2
  return 1
}

extract_referenced_go_tags() {
  # Packages / Packages.gz / by-hash：按内容魔数识别 gzip，不按后缀。
  # 调用方若写 `extract_referenced_go_tags ... || die`，本函数内每步须显式传播失败。
  local root="$1"
  local out="$2"
  local list="${out}.files"
  : >"${out}" || return 1
  : >"${list}" || return 1
  if ! find -- "${root}" \( -name 'Packages' -o -name 'Packages.gz' -o -path '*/by-hash/*' \) \
    -type f -print0 >"${list}.0"; then
    printf 'release_golang.sh: 枚举 apt-data 索引失败\n' >&2
    return 1
  fi
  local f tmp
  while IFS= read -r -d '' f; do
    if [[ ! -f "${f}" || -L "${f}" ]]; then
      printf 'release_golang.sh: 索引路径非法: %s\n' "${f}" >&2
      return 1
    fi
    tmp="${out}.chunk"
    if is_gzip_file "${f}"; then
      if ! gzip -dc -- "${f}" >"${tmp}"; then
        printf 'release_golang.sh: gzip 解压失败: %s\n' "${f}" >&2
        rm -f -- "${tmp}"
        return 1
      fi
      if ! extract_tags_from_bytes "${tmp}" "${out}"; then
        rm -f -- "${tmp}"
        return 1
      fi
      rm -f -- "${tmp}"
    else
      extract_tags_from_bytes "${f}" "${out}" || return 1
    fi
  done <"${list}.0"
  rm -f -- "${list}.0"
  if [[ -s "${out}" ]]; then
    LC_ALL=C sort -u -o "${out}" "${out}" || return 1
  fi
  return 0
}

list_all_releases_json() {
  # 完整分页；任页失败不删除。
  local repository="$1" out="$2"
  local page=1 chunk="${out}.page" acc="${out}.acc"
  printf '[]\n' >"${acc}"
  while [[ "${page}" -le 50 ]]; do
    if ! GH_REPO="${repository}" gh api \
      "repos/${repository}/releases?per_page=100&page=${page}" \
      >"${chunk}"; then
      die "列出 releases 第 ${page} 页失败，拒绝清理"
    fi
    jq -e 'type=="array"' "${chunk}" >/dev/null || die "releases 第 ${page} 页不是数组"
    local n
    n="$(jq -r 'length' "${chunk}")" || die "解析 releases 页长度失败"
    [[ "${n}" =~ ^[0-9]+$ ]] || die "releases 页长度非法"
    jq -s 'add' "${acc}" "${chunk}" >"${acc}.next" || die "合并 releases 页失败"
    mv -f -- "${acc}.next" "${acc}"
    [[ "${n}" -eq 0 || "${n}" -lt 100 ]] && break
    page=$((page + 1))
  done
  [[ "${page}" -le 50 ]] || die "releases 分页超过上限，拒绝清理"
  # 归一为 prune 使用的字段
  jq '[.[] | {
    tagName: .tag_name,
    isDraft: .draft,
    isLatest: (.make_latest=="true" or .make_latest==true),
    createdAt: .created_at
  }]' "${acc}" >"${out}" || die "归一 releases 列表失败"
  rm -f -- "${chunk}" "${acc}"
}

cmd_prune() {
  local repository="" current_tag="" apt_data_ref="apt-data" keep_recent=2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repository) [[ $# -ge 2 ]] || usage; repository="$2"; shift 2 ;;
      --current-tag) [[ $# -ge 2 ]] || usage; current_tag="$2"; shift 2 ;;
      --apt-data-ref) [[ $# -ge 2 ]] || usage; apt_data_ref="$2"; shift 2 ;;
      --keep-recent) [[ $# -ge 2 ]] || usage; keep_recent="$2"; shift 2 ;;
      *) die "prune 未知参数: $1" ;;
    esac
  done
  [[ -n "${repository}" && -n "${current_tag}" ]] || usage
  [[ "${repository}" =~ ${REPO_RE} ]] || die "repository 非法"
  [[ "${current_tag}" =~ ${REL_TAG_RE} ]] || die "current-tag 非法"
  [[ "${keep_recent}" =~ ^[1-9][0-9]*$ ]] || die "keep-recent 非法"
  [[ -n "${GH_TOKEN:-}" ]] || die "缺少 GH_TOKEN"
  require_cmd jq curl gh gzip git od

  local work
  work="$(make_scratch_tmp_dir "go-release-prune")"
  # shellcheck disable=SC2064
  trap 'cleanup_owned_dir "'"${work}"'"' RETURN
  mkdir -p -- "${work}/apt-data" "${work}/lists" || die "无法创建 prune 工作目录"

  local list_json="${work}/lists/releases.json"
  list_all_releases_json "${repository}" "${list_json}"
  jq -e 'type=="array"' "${list_json}" >/dev/null || die "releases 列表非法"

  local protected="${work}/lists/protected.txt"
  printf '%s\n' "${current_tag}" >"${protected}"
  local refs_out="${work}/lists/apt-data-refs.txt"
  if ! git ls-remote --heads "https://github.com/${repository}.git" "${apt_data_ref}" \
    >"${refs_out}" 2>"${work}/lists/apt-data-ls.err"; then
    die "列出 apt-data 失败（网络或鉴权），拒绝清理"
  fi
  if [[ -s "${refs_out}" ]]; then
    local sha
    sha="$(awk '{print $1}' "${refs_out}" | head -n1)"
    [[ "${sha}" =~ ${HEX40} ]] || die "apt-data SHA 非法"
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Accept: application/vnd.github.raw" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      --connect-timeout 20 --max-time 300 \
      -L \
      -o "${work}/apt-data.tgz" \
      -- "https://api.github.com/repos/${repository}/tarball/${sha}"; then
      die "下载 apt-data 失败，拒绝清理"
    fi
    tar -tzf "${work}/apt-data.tgz" >/dev/null 2>&1 \
      || die "apt-data 下载内容不是 tar.gz，拒绝清理"
    # 枚举成功后才解压；拒越界/绝对路径/链接/特殊成员。
    local members="${work}/lists/tar-members.txt"
    tar -tzf "${work}/apt-data.tgz" >"${members}" || die "列举 apt-data tar 失败，拒绝清理"
    if grep -E '(^|/)\.\.(/|$)|^/' "${members}" >/dev/null; then
      die "apt-data tar 含越界路径，拒绝清理"
    fi
    if tar -tvzf "${work}/apt-data.tgz" | awk '
      {
        mode=$1
        # 链接 / 设备 / fifo / 其它非 - 或 d
        if (mode ~ /^[lcbp]/ || mode ~ /^[Hh]/) { bad=1; exit }
      }
      END { exit bad ? 1 : 0 }
    '; then
      :
    else
      die "apt-data tar 含链接或特殊文件，拒绝清理"
    fi
    tar -xzf "${work}/apt-data.tgz" -C "${work}/apt-data" --strip-components=1 \
      || die "解压 apt-data 失败，拒绝清理"
    extract_referenced_go_tags "${work}/apt-data" "${work}/lists/referenced.txt" \
      || die "解析 apt-data 引用失败，拒绝清理"
    if [[ -s "${work}/lists/referenced.txt" ]]; then
      cat "${work}/lists/referenced.txt" >>"${protected}"
    fi
  else
    printf 'prune_note=apt-data_absent_first_run\n'
  fi

  # 最近 keep_recent 个已发布（非 draft）同族 tag。
  local recent_rc=0
  jq -r '.[] | select(.isDraft==false) | .tagName' "${list_json}" \
    >"${work}/lists/published-tags.txt" || die "提取已发布 tag 失败"
  if grep -E '^golang-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*$' \
    "${work}/lists/published-tags.txt" >"${work}/lists/family-published.txt"; then
    :
  else
    recent_rc=$?
    [[ "${recent_rc}" -eq 1 ]] || die "筛选同族已发布 tag 失败"
    : >"${work}/lists/family-published.txt"
  fi
  sed -E 's/^(golang-)(.*)$/\1\2\t\2/' "${work}/lists/family-published.txt" \
    | sort -t$'\t' -k2,2V -r \
    | awk -F'\t' -v n="${keep_recent}" 'NR<=n {print $1}' \
    >>"${protected}" || die "计算最近成功版本保护集失败"
  LC_ALL=C sort -u -o "${protected}" "${protected}" || die "保护集排序失败"
  [[ -s "${protected}" ]] || die "保护集为空，拒绝清理"

  local cand del_list="${work}/lists/delete.txt"
  : >"${del_list}"
  jq -r '.[].tagName' "${list_json}" >"${work}/lists/all-tags.txt" || die "提取全部 tag 失败"
  while IFS= read -r cand; do
    [[ "${cand}" =~ ${REL_TAG_RE} ]] || continue
    if grep -Fxq -- "${cand}" "${protected}"; then
      continue
    fi
    if GH_REPO="${repository}" gh release view "${cand}" >/dev/null 2>&1; then
      printf '%s\n' "${cand}" >>"${del_list}"
    fi
  done <"${work}/lists/all-tags.txt"

  if [[ ! -s "${del_list}" ]]; then
    printf 'prune_deleted=0\n'
    printf 'go_release_tag=%s\n' "${current_tag}"
    return 0
  fi

  local t
  while IFS= read -r t; do
    [[ -n "${t}" ]] || continue
    GH_REPO="${repository}" gh release delete "${t}" -y \
      || die "删除 release 失败: ${t}"
    git push "https://x-access-token:${GH_TOKEN}@github.com/${repository}.git" ":refs/tags/${t}" \
      >/dev/null 2>&1 || true
    printf 'prune_deleted_tag=%s\n' "${t}"
  done <"${del_list}"

  printf 'prune_deleted=%s\n' "$(wc -l <"${del_list}" | tr -d ' ')"
  printf 'go_release_tag=%s\n' "${current_tag}"
}

main() {
  [[ $# -ge 1 ]] || usage
  local cmd="$1"
  shift
  case "${cmd}" in
    prepare) cmd_prepare "$@" ;;
    status) cmd_status "$@" ;;
    upload) cmd_upload "$@" ;;
    prune) cmd_prune "$@" ;;
    -h|--help) usage ;;
    *) die "未知子命令: ${cmd}" ;;
  esac
}

main "$@"
