#!/usr/bin/env bash
# 按 catalog 的 source_type 调度：githubdeb 只发现，go_official_archive 才构造。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C
export LANGUAGE=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "${ROOT}"
PROJECT_TMP="${ROOT}/tmp"
CATALOG="${ROOT}/config/packages.json"

die() {
  printf 'gen_debs.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  gen_debs.sh metadata --upstream-dir <目录> [--catalog <file>]
  gen_debs.sh release --output <目录> [--catalog <file>] [--go-version <goX.Y.Z>] [--downloads-json <文件>] [--archive-dir <目录>]
metadata 只写入官方 Release API 原文。release 只构造 catalog 里需要转换的条目。
EOF
  exit 2
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v -- "${c}" >/dev/null 2>&1 || die "缺少命令: ${c}"
  done
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

reject_dotdot() {
  local p="$1" part
  local -a parts
  IFS=/ read -r -a parts <<< "${p}"
  for part in "${parts[@]}"; do
    [[ "${part}" != ".." ]] || die "路径含 ..: ${p}"
  done
}

assert_no_symlink_components() {
  local path="$1" prefix="" part
  local -a parts
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

dir_is_empty() {
  local d="$1" listing="" rc=0
  [[ -d "${d}" ]] || return 0
  listing="$(find -- "${d}" -mindepth 1 -maxdepth 1 -print -quit)" || rc=$?
  [[ "${rc}" -eq 0 ]] || return "${rc}"
  [[ -z "${listing}" ]]
}

assert_catalog_file() {
  local raw="$1" abs
  [[ -n "${raw}" ]] || die "缺少 catalog"
  reject_dotdot "${raw}"
  abs="$(make_abs_unresolved "${raw}")"
  reject_dotdot "${abs}"
  [[ -f "${abs}" && ! -L "${abs}" ]] || die "catalog 不是普通文件: ${abs}"
  assert_no_symlink_components "${abs}"
  abs="$(realpath -e -- "${abs}")"
  under_dir "${ROOT}" "${abs}" || die "catalog 必须在仓库内: ${abs}"
  is_system_path "${abs}" && die "catalog 拒绝系统路径: ${abs}"
  printf '%s\n' "${abs}"
}

assert_consumer_dir() {
  local role="$1" raw="$2" allow_upload="$3"
  local abs parent base parent_abs
  [[ -n "${raw}" ]] || die "缺少 ${role}"
  reject_dotdot "${raw}"
  abs="$(make_abs_unresolved "${raw}")"
  reject_dotdot "${abs}"
  parent="$(dirname -- "${abs}")"
  base="$(basename -- "${abs}")"
  [[ "${base}" != "." && "${base}" != ".." && "${base}" != "/" ]] || die "${role} 非法目录名"
  [[ -d "${parent}" && ! -L "${parent}" ]] || die "${role} 父目录不存在"
  assert_no_symlink_components "${parent}"
  if [[ -L "${abs}" ]]; then
    die "${role} 不能是符号链接: ${abs}"
  fi
  if [[ -e "${abs}" && ! -d "${abs}" ]]; then
    die "${role} 已存在且不是目录: ${abs}"
  fi
  if [[ -e "${abs}" ]]; then
    assert_no_symlink_components "${abs}"
  fi
  parent_abs="$(realpath -e -- "${parent}")"
  abs="${parent_abs}/${base}"
  if [[ -e "${abs}" || -L "${abs}" ]]; then
    [[ ! -L "${abs}" && -d "${abs}" ]] || die "${role} 不能是符号链接: ${abs}"
  fi
  if [[ "${allow_upload}" == "yes" && "${abs}" == "${ROOT}/build/upload_tmp_dir" ]]; then
    :
  else
    under_dir "${PROJECT_TMP}" "${abs}" || die "${role} 必须位于 tmp/ 下: ${abs}"
    [[ "${abs}" != "${ROOT}" && "${abs}" != "${PROJECT_TMP}" ]] || die "${role} 不能是项目根或 tmp 根"
  fi
  is_system_path "${abs}" && die "${role} 拒绝系统路径: ${abs}"
  if [[ -e "${abs}" ]]; then
    dir_is_empty "${abs}" || die "${role} 必须为空，拒绝清理已有内容"
  fi
  printf '%s\n' "${abs}"
}

owned_tmp() {
  mkdir -p -- "${PROJECT_TMP}"
  [[ -d "${PROJECT_TMP}" && ! -L "${PROJECT_TMP}" ]] || die "项目 tmp 不可用"
  mktemp -p "${PROJECT_TMP}" "$1"
}

parse_catalog_rows() {
  local dest="$1"
  if ! jq -r '
    .packages[]
    | [(.source_type // "githubdeb"), .id]
    | @tsv
  ' "${CATALOG}" >"${dest}"; then
    die "catalog 解析失败"
  fi
}

metadata() {
  local dest=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upstream-dir)
        [[ $# -ge 2 ]] || usage
        dest="$2"
        shift 2
        ;;
      --catalog)
        [[ $# -ge 2 ]] || usage
        CATALOG="$2"
        shift 2
        ;;
      *) die "metadata 未知参数: $1" ;;
    esac
  done
  [[ -n "${dest}" ]] || usage
  require_cmd jq curl realpath find
  CATALOG="$(assert_catalog_file "${CATALOG}")"
  dest="$(assert_consumer_dir "upstream-dir" "${dest}" no)"
  local ids stage id repo url code body n rc st catalog_text
  local -a curl_args
  ids="$(owned_tmp "gen-debs-ids.XXXXXX")"
  if ! parse_catalog_rows "${ids}"; then
    rm -f -- "${ids}"
    die "catalog 解析失败"
  fi
  catalog_text="$(cat -- "${ids}")"
  rm -f -- "${ids}"
  n=0
  while IFS=$'\t' read -r st id; do
    [[ "${st}" == "githubdeb" ]] || continue
    [[ -n "${id}" ]] || die "githubdeb 缺少 id"
    n=$((n + 1))
  done <<< "${catalog_text}"
  if [[ "${n}" -eq 0 ]]; then
    printf 'gen_debs.sh: metadata packages=0\n'
    return 0
  fi
  local parent
  parent="$(dirname -- "${dest}")"
  stage="$(mktemp -d "${parent}/.upstream-stage.XXXXXX")"
  n=0
  while IFS=$'\t' read -r st id; do
    [[ "${st}" == "githubdeb" ]] || continue
    [[ -n "${id}" ]] || { rm -rf -- "${stage}"; die "githubdeb 缺少 id"; }
    repo="$(jq -r --arg id "${id}" '.packages[] | select(.id==$id) | .repository // empty' "${CATALOG}")"
    [[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
      rm -rf -- "${stage}"
      die "repository 非法: ${id}"
    }
    url="https://api.github.com/repos/${repo}/releases/latest"
    body="${stage}/${id}.json"
    curl_args=(
      -sS --proto '=https' --proto-redir '=https' --tlsv1.2
      --connect-timeout 20 --max-time 120
      -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28"
    )
    if [[ -n "${GH_TOKEN:-}" ]]; then
      curl_args+=(-H "Authorization: Bearer ${GH_TOKEN}")
    fi
    curl_args+=(-o "${body}" -w '%{http_code}' -- "${url}")
    set +e
    code="$(curl "${curl_args[@]}")"
    rc=$?
    set -e
    if [[ "${rc}" -ne 0 || "${code}" != "200" ]]; then
      rm -rf -- "${stage}"
      die "官方 Release 获取失败: ${id} HTTP ${code:-curl${rc}}"
    fi
    if ! jq -e 'type=="object" and (.tag_name|type=="string") and (.assets|type=="array")' "${body}" >/dev/null; then
      rm -rf -- "${stage}"
      die "官方 Release JSON 不完整: ${id}"
    fi
    n=$((n + 1))
  done <<< "${catalog_text}"
  local created=0
  if [[ ! -e "${dest}" ]]; then
    mkdir -- "${dest}"
    created=1
  fi
  if ! dir_is_empty "${dest}"; then
    rm -rf -- "${stage}"
    [[ "${created}" -eq 0 ]] || rmdir -- "${dest}"
    die "upstream-dir 必须为空，拒绝清理已有内容"
  fi
  mv -n -- "${stage}/"*.json "${dest}/"
  if find -- "${stage}" -mindepth 1 -maxdepth 1 -name '*.json' -print -quit | grep -q .; then
    rm -rf -- "${stage}"
    die "upstream-dir 已有同名文件，拒绝覆盖"
  fi
  rm -rf -- "${stage}"
  printf 'gen_debs.sh: metadata packages=%s dir=%s\n' "${n}" "${dest}"
}

rewrite_sums() {
  local dir="$1" sums
  sums="$(mktemp "${dir}/.SHA256SUMS.XXXXXX")"
  (
    cd -- "${dir}"
    find . -maxdepth 1 -type f ! -name '.*' -printf '%f\n' | LC_ALL=C sort \
      | while IFS= read -r name; do
          [[ -n "${name}" ]] || continue
          sha256sum -- "${name}"
        done
  ) | LC_ALL=C sort -k2 >"${sums}" || { rm -f -- "${sums}"; die "重写 SHA256SUMS 失败"; }
  mv -f -- "${sums}" "${dir}/SHA256SUMS"
}

commit_stage() {
  local stage="$1" output="$2"
  if [[ ! -e "${output}" ]]; then
    mv -- "${stage}" "${output}"
    return 0
  fi
  if ! dir_is_empty "${output}"; then
    rm -rf -- "${stage}"
    die "output 必须为空，拒绝清理已有内容"
  fi
  mv -n -- "${stage}/"* "${output}/"
  if find -- "${stage}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    rm -rf -- "${stage}"
    die "output 已有同名文件，拒绝覆盖"
  fi
  rm -rf -- "${stage}"
}

release_build() {
  local output="" go_version="" downloads_json="" archive_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) [[ $# -ge 2 ]] || usage; output="$2"; shift 2 ;;
      --catalog) [[ $# -ge 2 ]] || usage; CATALOG="$2"; shift 2 ;;
      --go-version) [[ $# -ge 2 ]] || usage; go_version="$2"; shift 2 ;;
      --downloads-json) [[ $# -ge 2 ]] || usage; downloads_json="$2"; shift 2 ;;
      --archive-dir) [[ $# -ge 2 ]] || usage; archive_dir="$2"; shift 2 ;;
      *) die "release 未知参数: $1" ;;
    esac
  done
  [[ -n "${output}" ]] || usage
  require_cmd jq sha256sum find realpath
  CATALOG="$(assert_catalog_file "${CATALOG}")"
  output="$(assert_consumer_dir "output" "${output}" yes)"
  local rows st id go_id="" go_n=0 catalog_text
  rows="$(owned_tmp "gen-debs-rows.XXXXXX")"
  if ! parse_catalog_rows "${rows}"; then
    rm -f -- "${rows}"
    die "catalog 解析失败"
  fi
  catalog_text="$(cat -- "${rows}")"
  rm -f -- "${rows}"
  while IFS=$'\t' read -r st id; do
    [[ -n "${st}" ]] || continue
    case "${st}" in
      githubdeb) ;;
      go_official_archive)
        go_n=$((go_n + 1))
        go_id="${id}"
        ;;
      *)
        die "未知 source_type: ${st}"
        ;;
    esac
  done <<< "${catalog_text}"
  [[ "${go_n}" -le 1 ]] || die "go_official_archive 多于一条"
  if [[ "${go_n}" -eq 0 ]]; then
    printf 'gen_debs.sh: release 无可构造条目\n'
    return 0
  fi
  [[ "${go_id}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "构造条目 id 非法: ${go_id}"
  [[ -x "${ROOT}/scripts/gen_deb_golang.sh" ]] || die "缺少 scripts/gen_deb_golang.sh"
  mkdir -p -- "${ROOT}/tmp/debs"
  [[ -d "${ROOT}/tmp/debs" && ! -L "${ROOT}/tmp/debs" ]] || die "tmp/debs 不可用"
  local stage
  local -a args
  stage="$(mktemp -d "${ROOT}/tmp/debs/golang-stage.XXXXXX")"
  args=(--config "${ROOT}/config/go.json" --output "${stage}")
  if [[ -n "${go_version}" ]]; then
    args+=(--version "${go_version}")
  fi
  if [[ -n "${downloads_json}" ]]; then
    args+=(--downloads-json "${downloads_json}")
  fi
  if [[ -n "${archive_dir}" ]]; then
    args+=(--archive-dir "${archive_dir}")
  fi
  if ! "${ROOT}/scripts/gen_deb_golang.sh" "${args[@]}"; then
    rm -rf -- "${stage}"
    die "Go 构包失败，未提交上传目录"
  fi
  [[ -f "${stage}/provenance.json" && ! -L "${stage}/provenance.json" ]] || {
    rm -rf -- "${stage}"
    die "构包未产生 provenance.json"
  }
  rm -f -- "${stage}/SHA256SUMS"
  mv -f -- "${stage}/provenance.json" "${stage}/${go_id}.provenance.json"
  rewrite_sums "${stage}"
  ( cd -- "${stage}" && sha256sum -c -- SHA256SUMS >/dev/null ) || {
    rm -rf -- "${stage}"
    die "SHA256SUMS 与构造集不一致"
  }
  commit_stage "${stage}" "${output}"
  printf 'gen_debs.sh: release output=%s id=%s\n' "${output}" "${go_id}"
}

main() {
  [[ $# -ge 1 ]] || usage
  local cmd="$1"
  shift
  case "${cmd}" in
    metadata) metadata "$@" ;;
    release) release_build "$@" ;;
    -h|--help) usage ;;
    *) die "未知子命令: ${cmd}" ;;
  esac
}

main "$@"
