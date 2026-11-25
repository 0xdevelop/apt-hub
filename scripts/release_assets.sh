#!/usr/bin/env bash
# 构造资产：远端完整或 catalog 无需构造则跳过；空远端允许上传。上传前用同一套目录校验。
set -euo pipefail
umask 022
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTRUCT_N=""
WORK_DIR=""

die() {
  printf 'release_assets.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/release_assets.sh plan --repository <owner/repo> --tag <vX.Y.Z> [--previous-state <state.json>]
  scripts/release_assets.sh stage-upload --repository <owner/repo> --tag <vX.Y.Z> --asset-dir <目录> --output-dir <全新tmp子目录>
  scripts/release_assets.sh remote-status --repository <owner/repo> --tag <vX.Y.Z> [--source-tag]
  scripts/release_assets.sh local-status --asset-dir <目录>
  scripts/release_assets.sh prepare-archives --go-version <goX.Y.Z> --downloads-json <文件> --archive-dir <目录>
退出: 0 已完整，或 catalog 无需构造；10 远端没有构造包；1 不完整、不一致或查询失败。
EOF
  exit 2
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "缺少 $1"
}

# 统计 go_official_archive。缺省 source_type 视为 githubdeb。未知类型拒绝。
read_catalog() {
  local catalog="${ROOT}/config/packages.json" out st n=0
  [[ -f "${catalog}" && ! -L "${catalog}" ]] || die "缺少 catalog"
  require_tool jq
  out="$(jq -r '
    if (.schema_version != "2") or (.packages | type != "array") then
      "BADSCHEMA"
    else
      .packages[] | (.source_type // "githubdeb")
    end
  ' "${catalog}")" || die "catalog 解析失败"
  if [[ "${out}" == "BADSCHEMA" ]]; then
    die "catalog 解析失败"
  fi
  while IFS= read -r st || [[ -n "${st}" ]]; do
    [[ -n "${st}" ]] || continue
    case "${st}" in
      githubdeb) ;;
      go_official_archive) n=$((n + 1)) ;;
      *) die "未知 source_type: ${st}" ;;
    esac
  done <<< "${out}"
  [[ "${n}" -le 1 ]] || die "go_official_archive 多于一条"
  CONSTRUCT_N="${n}"
}

expected_go_revision() {
  local rev
  rev="$(jq -er '.revision' "${ROOT}/config/go.json")" || die "读取 config/go.json revision 失败"
  [[ "${rev}" =~ ^[1-9][0-9]*$ ]] || die "config revision 语法非法"
  printf '%s\n' "${rev}"
}

# 目录内文件与 SHA256SUMS、来源、catalog、go 配置一致则返回，否则 die。不访问远端。
validate_constructed_dir() {
  local dl="$1" work="$2" expected_revision="${3:-}"
  local catalog gocfg cat_id pkg epoch rev prov prov_n prov_base base_rev
  [[ -d "${dl}" && ! -L "${dl}" ]] || die "asset-dir 不是目录"
  if find "${dl}" -mindepth 1 -maxdepth 1 ! -type f -print -quit | grep -q .; then
    die "目录含非构造文件"
  fi
  [[ -f "${dl}/SHA256SUMS" && ! -L "${dl}/SHA256SUMS" ]] || die "构造包不完整，缺少唯一 SHA256SUMS"
  (
    cd -- "${dl}"
    sha256sum -c -- SHA256SUMS >/dev/null
  ) || die "SHA256SUMS 与目录字节不一致"
  awk '{print $2}' "${dl}/SHA256SUMS" | LC_ALL=C sort >"${work}/sums.names"
  find "${dl}" -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort >"${work}/disk.names"
  local name
  while IFS= read -r name || [[ -n "${name}" ]]; do
    [[ -n "${name}" ]] || continue
    [[ "${name}" != */* && "${name}" != *\\* && "${name}" != *$'\n'* && "${name}" != *$'\r'* \
      && "${name}" != '.' && "${name}" != '..' ]] || die "资产文件名非法"
  done <"${work}/sums.names"
  cmp -s "${work}/sums.names" "${work}/disk.names" || die "SHA256SUMS 成员与资产不一致"

  catalog="${ROOT}/config/packages.json"
  gocfg="${ROOT}/config/go.json"
  [[ -f "${catalog}" && ! -L "${catalog}" && -f "${gocfg}" && ! -L "${gocfg}" ]] || die "缺少 catalog 或 go 配置"
  jq -e --slurpfile go "${gocfg}" '
    ([.packages[] | select(.source_type=="go_official_archive")] | length) == 1
    and (([.packages[] | select(.source_type=="go_official_archive")][0].package) == $go[0].package)
    and (([.packages[] | select(.source_type=="go_official_archive")][0].architectures | keys | sort)
         == ($go[0].architectures | sort))
    and ($go[0].epoch | type=="string" and test("^[0-9]+$"))
    and ($go[0].revision | type=="string" and test("^[0-9]+$"))
    and ($go[0].architectures | type=="array" and length>0)
  ' "${catalog}" >/dev/null || die "catalog 与 go 配置组合不一致"
  pkg="$(jq -r '.package' "${gocfg}")"
  epoch="$(jq -r '.epoch' "${gocfg}")"
  base_rev="$(expected_go_revision)"
  rev="${expected_revision:-${base_rev}}"
  cat_id="$(jq -r '[.packages[] | select(.source_type=="go_official_archive")][0].id' "${catalog}")"
  [[ "${cat_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "catalog id 非法"
  prov="${dl}/${cat_id}.provenance.json"
  [[ -f "${prov}" && ! -L "${prov}" ]] || die "来源文件名与 catalog 不一致"
  prov_n="$(find "${dl}" -maxdepth 1 -type f -name '*.provenance.json' | wc -l | tr -d ' ')"
  [[ "${prov_n}" -eq 1 ]] || die "来源文件必须恰好一个"
  prov_base="$(basename -- "${prov}")"
  jq -e --arg pkg "${pkg}" --arg epoch "${epoch}" --arg rev "${rev}" --slurpfile go "${gocfg}" '
    . as $root
    | ($go[0].architectures | sort) as $archs
    | ([$pkg] | unique | sort) as $names
    | ([$names[] as $n | $archs[] as $a | "\($n)|\($a)"] | sort) as $want
    | ([.packages[] | "\(.package)|\(.architecture)"] | sort) as $got
    | ($names | length) == 1
    and ($root.schema_version=="1")
    and ($root.upstream.epoch==$epoch)
    and ($root.upstream.revision==$rev)
    and ($root.upstream.version_debian | type=="string" and length>0)
    and (([.packages[].filename] | unique | length) == (.packages | length))
    and ($got == $want)
    and all(.packages[];
        .version == ($root.upstream.epoch + ":" + $root.upstream.version_debian + "-" + $root.upstream.revision))
  ' "${prov}" >/dev/null || die "来源与规定组合不一致"
  local up_deb_ver row filename row_pkg row_ver row_arch row_sha row_size got_size got_sha rev_re
  up_deb_ver="$(jq -er '.upstream.version_debian' "${prov}")" || die "来源 version_debian 缺失"
  while IFS= read -r row; do
    filename="$(jq -r '.filename' <<<"${row}")"
    row_pkg="$(jq -r '.package' <<<"${row}")"
    row_ver="$(jq -r '.version' <<<"${row}")"
    row_arch="$(jq -r '.architecture' <<<"${row}")"
    row_sha="$(jq -r '.sha256' <<<"${row}")"
    row_size="$(jq -r '.size | tostring' <<<"${row}")"
    [[ -n "${row_pkg}" && -n "${row_ver}" && -n "${row_arch}" && "${row_sha}" =~ ^[0-9a-f]{64}$ ]] \
      || die "来源行字段不完整"
    [[ "${filename}" != */* && "${filename}" != '.' && "${filename}" != '..' && "${filename}" == "${row_pkg}_${up_deb_ver}-${rev}_${row_arch}.deb" ]] \
      || die "来源文件名非法或与版本修订不符: ${filename}"
    [[ -f "${dl}/${filename}" && ! -L "${dl}/${filename}" ]] || die "来源列出的 deb 不在资产中: ${filename}"
    got_size="$(stat -c '%s' -- "${dl}/${filename}")"
    got_sha="$(sha256sum -- "${dl}/${filename}" | awk '{print $1}')"
    [[ "${got_size}" == "${row_size}" && "${got_sha}" == "${row_sha}" ]] || die "来源与 deb 字节不一致: ${filename}"
    [[ "$(dpkg-deb -f -- "${dl}/${filename}" Package)" == "${row_pkg}" ]] || die "Package 不一致: ${filename}"
    [[ "$(dpkg-deb -f -- "${dl}/${filename}" Version)" == "${row_ver}" ]] || die "Version 不一致: ${filename}"
    [[ "$(dpkg-deb -f -- "${dl}/${filename}" Architecture)" == "${row_arch}" ]] || die "Architecture 不一致: ${filename}"
    rev_re="${rev//./\\.}"
    rev_re="${rev_re//+/\\+}"
    [[ "${row_ver}" =~ ^${epoch}:.+-${rev_re}$ ]] || die "版本与 config epoch/revision 不符: ${row_ver}"
  done < <(jq -c '.packages[]' "${prov}")
  find "${dl}" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | LC_ALL=C sort >"${work}/deb.names"
  jq -r '.packages[].filename' "${prov}" | LC_ALL=C sort >"${work}/prov.names"
  cmp -s "${work}/deb.names" "${work}/prov.names" || die "deb 与来源清单不一致"
  find "${dl}" -maxdepth 1 -type f -printf '%f\n' \
    | awk -v p="${prov_base}" '$0 != "SHA256SUMS" && $0 != p' \
    | LC_ALL=C sort >"${work}/disk.rest"
  cmp -s "${work}/disk.rest" "${work}/prov.names" || die "目录文件与来源清单不一致"
}

prepare_work() {
  mkdir -p -- "${ROOT}/tmp"
  [[ -d "${ROOT}/tmp" && ! -L "${ROOT}/tmp" ]] || die "项目 tmp 不可用"
  WORK_DIR="$(mktemp -d "${ROOT}/tmp/release-assets.XXXXXX")"
  trap 'rm -rf -- "${WORK_DIR}"' EXIT
}

build_inputs_sha256() {
  (cd "${ROOT}" && sha256sum scripts/gen_deb_golang.sh config/go.json | sha256sum | cut -d' ' -f1)
}

fetch_release() {
  local repository="$1" tag="$2" dest="$3" err="${WORK_DIR}/api.err"
  if gh api "repos/${repository}/releases/tags/${tag}" >"${dest}" 2>"${err}"; then
    jq -e --arg tag "${tag}" 'type=="object" and .tag_name==$tag and .draft==false and .prerelease!=true and (.assets|type)=="array"' "${dest}" >/dev/null \
      || die "Release 响应非法: ${tag}"
    return 0
  fi
  if grep -Eq 'HTTP 404|\(404\)' "${err}"; then
    rm -f -- "${dest}"
    return 10
  fi
  die "读取 Release 失败: ${tag}（非不存在）"
}

validate_remote_assets() {
  local body="$1" repository="$2" tag="$3"
  jq -e --arg prefix "https://github.com/${repository}/releases/download/${tag}/" '
    ([.assets[].name]|length)==([.assets[].name]|unique|length)
    and all(.assets[];
      (.name|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$"))
      and (.size|type=="number" and .>0)
      and (.digest|type=="string" and test("^sha256:[0-9a-f]{64}$"))
      and .state=="uploaded"
      and (.browser_download_url==($prefix+.name)
        or .browser_download_url==($prefix+(.name|@uri))))
  ' "${body}" >/dev/null || die "Release 资产身份、摘要或名称非法: ${tag}"
}

download_remote_file() {
  local body="$1" name="$2" dest="$3" url size digest
  url=$(jq -er --arg n "${name}" '.assets[]|select(.name==$n)|.browser_download_url' "${body}") || die "缺少资产: ${name}"
  size=$(jq -er --arg n "${name}" '.assets[]|select(.name==$n)|.size' "${body}") || die "缺少 size: ${name}"
  digest=$(jq -er --arg n "${name}" '.assets[]|select(.name==$n)|.digest' "${body}") || die "缺少 digest: ${name}"
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 600 --retry 2 -o "${dest}" "${url}" \
    || die "下载资产失败: ${name}"
  [[ "$(stat -c '%s' "${dest}")" == "${size}" && "sha256:$(sha256sum "${dest}" | cut -d' ' -f1)" == "${digest}" ]] \
    || die "资产字节与 Release 不符: ${name}"
}

# 完整来源按其自己的标签修订校验，不把当前页面版本混入包版本。
verified_release_dir() {
  local body="$1" tag="$2" dir="$3" name revision
  mkdir -p "${dir}"
  while IFS= read -r name; do
    download_remote_file "${body}" "${name}" "${dir}/${name}"
  done < <(jq -r '.assets[].name' "${body}")
  revision=$(jq -er '.upstream.revision' "${dir}/golang.provenance.json") || die "来源修订缺失"
  [[ "${revision}" == "$(expected_go_revision)" ]] || die "来源修订与包配置不符: ${tag}"
  validate_constructed_dir "${dir}" "${WORK_DIR}" "${revision}"
}

plan_release() {
  local repository="" tag="" previous_state="" arg
  while [[ $# -gt 0 ]]; do
    arg="$1"; [[ $# -ge 2 ]] || usage
    case "${arg}" in
      --repository) repository="$2" ;;
      --tag) tag="$2" ;;
      --previous-state) previous_state="$2" ;;
      *) usage ;;
    esac
    shift 2
  done
  [[ "${repository}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "计划仓库或标签非法"
  read_catalog
  prepare_work
  if [[ "${CONSTRUCT_N}" -eq 0 ]]; then
    printf 'build_packages=0\nbump_release=0\npackage_release_tag=%s\ngo_version=\n' "${tag}"
    return 0
  fi
  require_tool gh
  require_tool curl
  local index="${WORK_DIR}/downloads.json" latest="" v fingerprint current="${WORK_DIR}/current.json" source_tag="${tag}" source
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 120 --retry 2 -o "${index}" 'https://go.dev/dl/?mode=json&include=all' || die "获取 Go 官方索引失败"
  jq -er 'if type=="array" and length>0 then .[]|select(.stable==true)|.version else error("bad index") end' "${index}" >"${WORK_DIR}/stable.txt" || die "Go stable 索引非法"
  while IFS= read -r v; do
    if [[ "${v}" =~ ^go[0-9]+(\.[0-9]+)?$ ]]; then continue; fi
    [[ "${v}" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Go stable 版本非法"
    if [[ -z "${latest}" ]] || dpkg --compare-versions "${v#go}" gt "${latest#go}"; then latest="${v}"; fi
  done <"${WORK_DIR}/stable.txt"
  [[ -n "${latest}" ]] || die "Go stable 索引为空"
  fingerprint=$(build_inputs_sha256) || die "计算构包输入失败"
  local previous_version=""
  if [[ -n "${previous_state}" ]]; then
    [[ -f "${previous_state}" && ! -L "${previous_state}" ]] || die "previous-state 不是普通文件"
    jq -e '.schema_version=="2" and (.packages|type)=="array" and ([.packages[]|select(.id=="golang")]|length)<=1' "${previous_state}" >/dev/null || die "previous-state 结构非法"
    previous_version=$(jq -r '.packages[]|select(.id=="golang")|.version' "${previous_state}")
    [[ -z "${previous_version}" ]] || dpkg --validate-version "${previous_version}" || die "previous Go 版本非法"
  fi
  if [[ -n "${previous_state}" ]]; then
    local old_tag old_repo
    old_tag=$(jq -r '.packages[]|select(.id=="golang")|.release_tag // empty' "${previous_state}") || die "previous-state 非法"
    old_repo=$(jq -r '.packages[]|select(.id=="golang")|.package_repository // empty' "${previous_state}") || die "previous-state 非法"
    if [[ -n "${old_tag}" ]]; then
      [[ "${old_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "${old_repo}" == "${repository}" ]] || die "previous Go 来源仓库或标签非法"
      dpkg --compare-versions "${old_tag#v}" le "${tag#v}" || die "previous 来源标签晚于当前版本"
    fi
  fi
  local current_count=0
  if fetch_release "${repository}" "${tag}" "${current}"; then
    current_count=$(jq '.assets|length' "${current}")
    validate_remote_assets "${current}" "${repository}" "${tag}"
  fi
  source="${current}"
  source_tag="${tag}"
  local count="${current_count}" prov="${WORK_DIR}/provenance.json" upstream="" inputs="" prov_rev="" base_rev="" complete=0 pinned="${latest}" bump=0
  base_rev=$(expected_go_revision)
  if [[ "${count}" -gt 0 ]]; then
    if jq -e '.assets|any(.name=="golang.provenance.json")' "${source}" >/dev/null; then
      download_remote_file "${source}" golang.provenance.json "${prov}"
      upstream=$(jq -er '.upstream.version|select(test("^go[0-9]+\\.[0-9]+\\.[0-9]+$"))' "${prov}") || die "来源 Go 版本非法"
      inputs=$(jq -r '.build_inputs_sha256 // empty' "${prov}") || die "来源构包输入非法"
      prov_rev=$(jq -er '.upstream.revision // empty' "${prov}") || die "来源修订缺失"
      [[ "${prov_rev}" == "${base_rev}" ]] || die "来源修订与包配置不符: ${tag}"
      dpkg --compare-versions "${upstream#go}" le "${latest#go}" || die "官方索引版本回退，拒绝替换现有包"
      local expected_count
      expected_count=$(jq '.architectures|length+2' "${ROOT}/config/go.json")
      if [[ "${count}" -eq "${expected_count}" ]] && jq -e '.assets|any(.name=="SHA256SUMS")' "${source}" >/dev/null; then complete=1; fi
      if [[ "${inputs}" == "${fingerprint}" && "${complete}" -eq 1 && "${upstream}" == "${latest}" ]]; then
        jq -e --slurpfile p "${prov}" '
          . as $index | all($p[0].packages[]; . as $pkg |
            any($index[]; .version==$p[0].upstream.version and
              any(.files[]; .arch==$pkg.architecture and .os=="linux" and .kind=="archive"
                and ("https://go.dev/dl/"+.filename)==$pkg.upstream.url
                and .sha256==$pkg.upstream.sha256 and (.size|tostring)==($pkg.upstream.size|tostring))))
        ' "${index}" >/dev/null || die "已发布 Go 来源与当前官方归档不符"
        verified_release_dir "${source}" "${tag}" "${WORK_DIR}/verified"
        local selected_version
        selected_version=$(jq -er '.packages[0].version' "${prov}") || die "来源包版本缺失"
        if [[ -n "${previous_version}" ]] && dpkg --compare-versions "${selected_version}" lt "${previous_version}"; then die "拒绝退回已发布的较低 Go 包版本"; fi
        printf 'build_packages=0\nbump_release=0\npackage_release_tag=%s\ngo_version=%s\n' "${tag}" "${upstream}"
        return 0
      fi
      if [[ "${complete}" -eq 1 || "${inputs}" != "${fingerprint}" ]]; then bump=1; else pinned="${upstream}"; fi
    else
      jq -r '.assets[].name|select(endswith(".deb"))' "${source}" >"${WORK_DIR}/partial-names.txt"
      if jq -e '.assets|any(.name=="SHA256SUMS")' "${source}" >/dev/null; then
        download_remote_file "${source}" SHA256SUMS "${WORK_DIR}/partial-SHA256SUMS"
        awk '$1 ~ /^[0-9a-f]+$/ && length($1)==64 {print $2}' "${WORK_DIR}/partial-SHA256SUMS" >>"${WORK_DIR}/partial-names.txt"
      fi
      if grep -Ev "^golang_[0-9][0-9.]*-${base_rev}_(amd64|arm64)\.deb$|^golang\.provenance\.json$" "${WORK_DIR}/partial-names.txt" | grep -q .; then
        die "部分资产版本或文件名与包配置不符: ${tag}"
      fi
      sed -n "s/^golang_\([0-9][0-9.]*\)-${base_rev}_\(amd64\|arm64\)\.deb$/go\1/p" "${WORK_DIR}/partial-names.txt" | sort -u >"${WORK_DIR}/partial-versions.txt"
      [[ "$(wc -l <"${WORK_DIR}/partial-versions.txt")" -eq 1 ]] || die "部分资产无法唯一确定 Go 版本"
      pinned=$(<"${WORK_DIR}/partial-versions.txt")
    fi
  fi
  if [[ -n "${previous_version}" ]]; then
    local candidate_version
    candidate_version="$(jq -er '.epoch' "${ROOT}/config/go.json"):${pinned#go}-${base_rev}"
    if dpkg --compare-versions "${candidate_version}" lt "${previous_version}"; then die "拒绝构造低于已发布的 Go 包版本"; fi
  fi
  printf 'build_packages=1\nbump_release=%s\npackage_release_tag=%s\ngo_version=%s\n' "${bump}" "${tag}" "${pinned}"
}

stage_upload() {
  local repository="" tag="" asset_dir="" output=""
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || usage
    case "$1" in
      --repository) repository="$2" ;;
      --tag) tag="$2" ;;
      --asset-dir) asset_dir="$2" ;;
      --output-dir) output="$2" ;;
      *) usage ;;
    esac
    shift 2
  done
  [[ "${repository}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "上传仓库或标签非法"
  read_catalog
  prepare_work
  local expected_rev
  expected_rev="$(expected_go_revision)"
  validate_constructed_dir "${asset_dir}" "${WORK_DIR}" "${expected_rev}"
  local resolved name remote sha size body="${WORK_DIR}/release.json" part prefix=""
  [[ -n "${output}" && "${output}" != *$'\n'* ]] || die "上传目录为空或非法"
  case "/${output}/" in */../*|*/./*) die "上传目录不能含 . 或 .." ;; esac
  resolved=$(realpath -m "${output}") || die "上传目录非法"
  [[ "${resolved}" == "${ROOT}/tmp/"* && "${resolved}" != "${ROOT}/tmp/" && ! -e "${resolved}" && ! -L "${resolved}" ]] || die "上传目录必须是未存在的项目 tmp 子目录"
  local -a components
  IFS=/ read -r -a components <<<"${resolved#/}"
  for part in "${components[@]}"; do
    prefix="${prefix}/${part}"
    [[ ! -L "${prefix}" ]] || die "上传目录含符号链接"
  done
  [[ "${resolved}" != "$(realpath -e "${asset_dir}")" && "${resolved}" != "$(realpath -e "${asset_dir}")/"* && "$(realpath -e "${asset_dir}")" != "${resolved}/"* ]] || die "上传目录与构包目录重叠"
  fetch_release "${repository}" "${tag}" "${body}" || die "上传目标 Release 尚未创建"
  validate_remote_assets "${body}" "${repository}" "${tag}"
  while IFS= read -r name; do
    [[ -f "${asset_dir}/${name}" && ! -L "${asset_dir}/${name}" ]] || die "远端含候选外资产，拒绝覆盖: ${name}"
    remote=$(jq -c --arg n "${name}" '.assets[]|select(.name==$n)' "${body}")
    sha=$(sha256sum "${asset_dir}/${name}" | cut -d' ' -f1)
    size=$(stat -c '%s' "${asset_dir}/${name}")
    jq -e --arg d "sha256:${sha}" --argjson s "${size}" '.digest==$d and .size==$s' <<<"${remote}" >/dev/null || die "远端同名资产冲突，拒绝覆盖: ${name}"
    download_remote_file "${body}" "${name}" "${WORK_DIR}/${name}"
  done < <(jq -r '.assets[].name' "${body}")
  mkdir -- "${resolved}"
  while IFS= read -r -d '' name; do
    name="${name##*/}"
    if ! jq -e --arg n "${name}" '.assets|any(.name==$n)' "${body}" >/dev/null; then
      cp -- "${asset_dir}/${name}" "${resolved}/${name}"
    fi
  done < <(find "${asset_dir}" -mindepth 1 -maxdepth 1 -type f -print0)
  if [[ -n "$(find "${resolved}" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]]; then
    printf 'upload=1\nupload_path=%s/*\n' "${resolved}"
  else
    printf 'upload=0\n'
  fi
}

remote_status() {
  local repository="" tag="" source_tag=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repository) [[ $# -ge 2 ]] || usage; repository="$2"; shift 2 ;;
      --tag) [[ $# -ge 2 ]] || usage; tag="$2"; shift 2 ;;
      --source-tag) source_tag=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ "${repository}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repository 非法"
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag 必须是严格 vX.Y.Z"
  read_catalog
  if [[ "${CONSTRUCT_N}" -eq 0 ]]; then
    printf 'release_assets.sh: 无可构造条目\n'
    exit 0
  fi
  [[ -n "${GH_TOKEN:-}" ]] || die "缺少 GH_TOKEN"
  require_tool gh
  require_tool sha256sum
  require_tool dpkg-deb
  local body dl asset_n name row want_size want_digest got_size got_digest
  prepare_work
  body="${WORK_DIR}/release.json"
  dl="${WORK_DIR}/dl"
  mkdir -p -- "${dl}"
  if ! GH_TOKEN="${GH_TOKEN}" gh api "repos/${repository}/releases/tags/${tag}" >"${body}"; then
    die "读取 release 失败: ${tag}"
  fi
  if ! jq -e --arg tag "${tag}" '
    type=="object"
    and .tag_name==$tag
    and .draft==false
    and (.assets|type=="array")
  ' "${body}" >/dev/null; then
    die "release 不是已发布且 tag 一致的对象: ${tag}"
  fi
  asset_n="$(jq -r '.assets|length' "${body}")"
  if [[ "${asset_n}" == "0" ]]; then
    printf 'release_assets.sh: absent %s\n' "${tag}"
    exit 10
  fi
  if ! jq -e '
    all(.assets[];
      (.name|type=="string" and length>0)
      and (.size|type=="number" and .>=0)
      and (.digest|type=="string" and test("^sha256:[0-9a-f]{64}$"))
      and .state=="uploaded")
  ' "${body}" >/dev/null; then
    die "资产缺少 name/size/digest/state: ${tag}"
  fi
  if ! jq -e '
    all(.assets[];
      (.name|type=="string")
      and (.name|contains("/")|not)
      and (.name|contains("\\")|not)
      and (.name|test("[\n\r]")|not)
      and .name!="."
      and .name!="..")
  ' "${body}" >/dev/null; then
    die "资产文件名非法"
  fi
  if ! jq -e '[.assets[].name|select(.=="SHA256SUMS")]|length==1' "${body}" >/dev/null; then
    die "构造包不完整，缺少唯一 SHA256SUMS: ${tag}"
  fi
  while IFS= read -r name; do
    [[ -n "${name}" ]] || die "资产名为空"
    [[ "${name}" != */* && "${name}" != *\\* && "${name}" != *$'\n'* && "${name}" != *$'\r'* \
      && "${name}" != '.' && "${name}" != '..' ]] || die "资产文件名非法"
    GH_TOKEN="${GH_TOKEN}" gh release download "${tag}" \
      --repo "${repository}" --dir "${dl}" --pattern "${name}" --clobber \
      || die "下载资产失败: ${name}"
    [[ -f "${dl}/${name}" && ! -L "${dl}/${name}" ]] || die "下载结果不是普通文件: ${name}"
  done < <(jq -r '.assets[].name' "${body}")
  while IFS= read -r row; do
    name="$(jq -r '.name' <<<"${row}")"
    want_size="$(jq -r '.size' <<<"${row}")"
    want_digest="$(jq -r '.digest' <<<"${row}")"
    got_size="$(stat -c '%s' -- "${dl}/${name}")"
    got_digest="sha256:$(sha256sum -- "${dl}/${name}" | awk '{print $1}')"
    [[ "${got_size}" == "${want_size}" ]] || die "size 不一致: ${name}"
    [[ "${got_digest}" == "${want_digest}" ]] || die "digest 不一致: ${name}"
  done < <(jq -c '.assets[]' "${body}")
  if [[ "${source_tag}" -eq 1 ]]; then
    local revision
    revision=$(jq -er '.upstream.revision' "${dl}/golang.provenance.json") || die "来源修订缺失"
    [[ "${revision}" == "$(expected_go_revision)" ]] || die "来源修订与包配置不符"
    validate_constructed_dir "${dl}" "${WORK_DIR}" "${revision}"
  else
    validate_constructed_dir "${dl}" "${WORK_DIR}"
  fi
  printf 'release_assets.sh: complete %s\n' "${tag}"
  exit 0
}

local_status() {
  local asset_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --asset-dir) [[ $# -ge 2 ]] || usage; asset_dir="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ -n "${asset_dir}" ]] || usage
  read_catalog
  if [[ "${CONSTRUCT_N}" -eq 0 ]]; then
    die "无可构造条目"
  fi
  require_tool sha256sum
  require_tool dpkg-deb
  prepare_work
  validate_constructed_dir "${asset_dir}" "${WORK_DIR}"
  printf 'release_assets.sh: 本地构造集完整\n'
  exit 0
}


prepare_archives() {
  local go_version="" downloads_json="" archive_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --go-version) [[ $# -ge 2 ]] || usage; go_version="$2"; shift 2 ;;
      --downloads-json) [[ $# -ge 2 ]] || usage; downloads_json="$2"; shift 2 ;;
      --archive-dir) [[ $# -ge 2 ]] || usage; archive_dir="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ "${go_version}" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "go-version 非法"
  [[ -n "${downloads_json}" && -f "${downloads_json}" && ! -L "${downloads_json}" ]] || die "downloads-json 不是普通文件"
  [[ -n "${archive_dir}" ]] || usage
  require_tool jq
  require_tool curl
  require_tool sha256sum
  require_tool realpath
  mkdir -p -- "${ROOT}/tmp"
  [[ -d "${ROOT}/tmp" && ! -L "${ROOT}/tmp" ]] || die "项目 tmp 不可用"
  local tmp_root resolved part prefix=""
  tmp_root="$(realpath -e -- "${ROOT}/tmp")"
  case "/${archive_dir}/" in */../*|*/./*) die "archive-dir 不能含 . 或 .." ;; esac
  resolved="$(realpath -m -- "${archive_dir}")" || die "archive-dir 非法"
  [[ "${resolved}" == "${tmp_root}/"* && "${resolved}" != "${tmp_root}" && ! -L "${resolved}" ]] || die "archive-dir 必须是项目 tmp 子目录"
  local -a parts
  IFS=/ read -r -a parts <<<"${resolved#/}"
  for part in "${parts[@]}"; do
    prefix="${prefix}/${part}"
    [[ ! -L "${prefix}" ]] || die "archive-dir 路径含符号链接"
  done
  if [[ -e "${resolved}" && ! -d "${resolved}" ]]; then
    die "archive-dir 已存在且不是目录"
  fi
  mkdir -p -- "${resolved}"
  local gocfg="${ROOT}/config/go.json" arch row fn sha size dest got_sha got_size dl_tmp
  [[ -f "${gocfg}" && ! -L "${gocfg}" ]] || die "缺少 config/go.json"
  prepare_work
  while IFS= read -r arch; do
    [[ "${arch}" =~ ^(amd64|arm64)$ ]] || die "非法架构: ${arch}"
    row="$(jq -er --arg v "${go_version}" --arg a "${arch}" '
      [ .[] | select(.version==$v) | .files[]?
        | select(.os=="linux" and .arch==$a and .kind=="archive")
        | select((.filename|type)=="string" and (.sha256|test("^[0-9a-f]{64}$")) and (.size|type=="number" and .>0))
      ] | if length==1 then .[0] else error("missing archive") end
      | [.filename, .sha256, (.size|tostring)] | @tsv
    ' "${downloads_json}")" || die "downloads-json 缺少 ${go_version}/${arch} 归档记录"
    IFS=$'\t' read -r fn sha size <<<"${row}"
    [[ "${fn}" == "${go_version}.linux-${arch}.tar.gz" ]] || die "归档文件名异常: ${fn}"
    dest="${resolved}/${fn}"
    if [[ -f "${dest}" && ! -L "${dest}" ]]; then
      got_size="$(stat -c '%s' -- "${dest}")"
      got_sha="$(sha256sum -- "${dest}" | awk '{print $1}')"
      if [[ "${got_size}" == "${size}" && "${got_sha}" == "${sha}" ]]; then
        printf 'release_assets.sh: cache hit %s\n' "${fn}"
        continue
      fi
    fi
    dl_tmp="${WORK_DIR}/${fn}"
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 600 \
      --max-filesize "$((size + 1048576))" -o "${dl_tmp}" -- "https://go.dev/dl/${fn}" \
      || die "下载 Go 官方归档失败: ${fn}"
    got_size="$(stat -c '%s' -- "${dl_tmp}")"
    got_sha="$(sha256sum -- "${dl_tmp}" | awk '{print $1}')"
    [[ "${got_size}" == "${size}" && "${got_sha}" == "${sha}" ]] || die "下载归档摘要或大小不符: ${fn}"
    install -m 644 -- "${dl_tmp}" "${dest}.tmp.$$" || die "写入缓存失败: ${fn}"
    mv -f -- "${dest}.tmp.$$" "${dest}" || die "提交缓存失败: ${fn}"
    printf 'release_assets.sh: cached %s\n' "${fn}"
  done < <(jq -r '.architectures[]' "${gocfg}")
}

[[ $# -ge 1 ]] || usage
mode="$1"
shift
case "${mode}" in
  plan) plan_release "$@" ;;
  stage-upload) stage_upload "$@" ;;
  remote-status) remote_status "$@" ;;
  local-status) local_status "$@" ;;
  prepare-archives) prepare_archives "$@" ;;
  *) usage ;;
esac
