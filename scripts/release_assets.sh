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
  scripts/release_assets.sh remote-status --repository <owner/repo> --tag <vX.Y.Z>
  scripts/release_assets.sh local-status --asset-dir <目录>
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

# 目录内文件与 SHA256SUMS、来源、catalog、go 配置一致则返回，否则 die。不访问远端。
validate_constructed_dir() {
  local dl="$1" work="$2"
  local catalog gocfg cat_id pkg epoch rev prov prov_n prov_base
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
  rev="$(jq -r '.revision' "${gocfg}")"
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
    | ([$pkg, "golang-go"] | unique | sort) as $names
    | ([$names[] as $n | $archs[] as $a | "\($n)|\($a)"] | sort) as $want
    | ([.packages[] | "\(.package)|\(.architecture)"] | sort) as $got
    | ($names | length) == 2
    and ($root.schema_version=="1")
    and ($root.upstream.epoch==$epoch)
    and ($root.upstream.revision==$rev)
    and ($root.upstream.version_debian | type=="string" and length>0)
    and (([.packages[].filename] | unique | length) == (.packages | length))
    and ($got == $want)
    and all(.packages[];
        .version == ($root.upstream.epoch + ":" + $root.upstream.version_debian + "-" + $root.upstream.revision))
  ' "${prov}" >/dev/null || die "来源与规定组合不一致"
  local row filename row_pkg row_ver row_arch row_sha row_size got_size got_sha
  while IFS= read -r row; do
    filename="$(jq -r '.filename' <<<"${row}")"
    row_pkg="$(jq -r '.package' <<<"${row}")"
    row_ver="$(jq -r '.version' <<<"${row}")"
    row_arch="$(jq -r '.architecture' <<<"${row}")"
    row_sha="$(jq -r '.sha256' <<<"${row}")"
    row_size="$(jq -r '.size | tostring' <<<"${row}")"
    [[ -n "${row_pkg}" && -n "${row_ver}" && -n "${row_arch}" && "${row_sha}" =~ ^[0-9a-f]{64}$ ]] \
      || die "来源行字段不完整"
    [[ "${filename}" != */* && "${filename}" != '.' && "${filename}" != '..' && "${filename}" == *"_${row_arch}.deb" ]] \
      || die "来源文件名非法: ${filename}"
    [[ -f "${dl}/${filename}" && ! -L "${dl}/${filename}" ]] || die "来源列出的 deb 不在资产中: ${filename}"
    got_size="$(stat -c '%s' -- "${dl}/${filename}")"
    got_sha="$(sha256sum -- "${dl}/${filename}" | awk '{print $1}')"
    [[ "${got_size}" == "${row_size}" && "${got_sha}" == "${row_sha}" ]] || die "来源与 deb 字节不一致: ${filename}"
    [[ "$(dpkg-deb -f -- "${dl}/${filename}" Package)" == "${row_pkg}" ]] || die "Package 不一致: ${filename}"
    [[ "$(dpkg-deb -f -- "${dl}/${filename}" Version)" == "${row_ver}" ]] || die "Version 不一致: ${filename}"
    [[ "$(dpkg-deb -f -- "${dl}/${filename}" Architecture)" == "${row_arch}" ]] || die "Architecture 不一致: ${filename}"
    [[ "${row_ver}" =~ ^${epoch}:.+-${rev}$ ]] || die "版本与 config epoch/revision 不符: ${row_ver}"
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

remote_status() {
  local repository="" tag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repository) [[ $# -ge 2 ]] || usage; repository="$2"; shift 2 ;;
      --tag) [[ $# -ge 2 ]] || usage; tag="$2"; shift 2 ;;
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
  validate_constructed_dir "${dl}" "${WORK_DIR}"
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

[[ $# -ge 1 ]] || usage
mode="$1"
shift
case "${mode}" in
  remote-status) remote_status "$@" ;;
  local-status) local_status "$@" ;;
  *) usage ;;
esac
