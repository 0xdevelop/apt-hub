#!/usr/bin/env bash
# 从官方 distro-info-data ubuntu.csv 筛出当前标准支持发行版。
# 标准支持结束日用 eol-server（无则 eol），不用 eol-esm/eol-legacy，不读 meta-release Supported。
set -euo pipefail

usage() {
  echo "用法: scripts/ubuntu_releases.sh --output <releases.json> [--csv <已下载的官方CSV>]" >&2
  exit 2
}

die() {
  echo "ubuntu_releases: $*" >&2
  exit 1
}

SOURCE_URL='https://salsa.debian.org/debian/distro-info-data/-/raw/main/ubuntu.csv'
CROSS_CHECK_URL='https://ubuntu.com/about/release-cycle'
REQUIRED_HEADER='version,codename,series,created,release,eol,eol-server,eol-esm,eol-legacy'

output_arg=""
csv_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || usage
      output_arg="$2"
      shift 2
      ;;
    --csv)
      [[ $# -ge 2 ]] || usage
      csv_arg="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      ;;
  esac
done

[[ -n "$output_arg" ]] || usage
command -v jq >/dev/null 2>&1 || die "需要 jq"
command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v awk >/dev/null 2>&1 || die "需要 awk"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "$script_dir/.." && pwd)
tmp_root=$(realpath -m -- "$root_dir/tmp")
[[ -d "$tmp_root" ]] || die "缺少项目 tmp/ 目录"

if [[ "$output_arg" != /* ]]; then
  output_arg="$root_dir/$output_arg"
fi
output_real=$(realpath -m -- "$output_arg")
case "$output_real" in
  "$tmp_root"/*) ;;
  *) die "输出必须位于项目 tmp/ 内" ;;
esac
[[ "$output_real" != "$tmp_root" ]] || die "输出不能是 tmp/ 本身"
[[ ! -L "$output_arg" ]] || die "拒绝符号链接: --output"
out_dir=$(dirname -- "$output_real")
[[ -d "$out_dir" ]] || die "输出目录不存在: $out_dir"

csv_tmp=""
page_tmp=""
out_tmp=""
rows_tmp=""
cleanup() {
  rm -f -- ${csv_tmp:+"$csv_tmp"} ${page_tmp:+"$page_tmp"} ${out_tmp:+"$out_tmp"} ${rows_tmp:+"$rows_tmp"}
}
trap cleanup EXIT

validate_csv() {
  local path="$1"
  [[ -f "$path" && -s "$path" ]] || die "CSV 为空或不存在"
  [[ ! -L "$path" ]] || die "拒绝符号链接 CSV"
  if grep -qiE 'Invalid OpenID|I Challenge Thee|<html|<HTML|<!DOCTYPE' "$path"; then
    die "CSV 不是 distro-info-data 表格（疑似网页或 OpenID 错误页）"
  fi
  local header
  header=$(head -n 1 "$path" | tr -d '\r')
  [[ "$header" == "$REQUIRED_HEADER" ]] || die "CSV 表头不是官方字段: $header"
  local rows
  rows=$(awk 'NR>1 && $0 !~ /^[[:space:]]*$/ {n++} END {print n+0}' "$path")
  [[ "$rows" -ge 1 ]] || die "CSV 没有数据行"
}

filter_supported() {
  local path="$1"
  local today="$2"
  awk -v today="$today" -F, '
    function isdate(s) { return s ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ }
    function bad(msg) {
      printf "ubuntu_releases: CSV 第%d行格式错误: %s\n", NR, msg > "/dev/stderr"
      exit 1
    }
    NR == 1 { next }
    {
      gsub(/\r/, "")
      if ($0 ~ /^[[:space:]]*$/) next
      version = $1
      series = $3
      rel = $5
      eol = $6
      eol_server = $7
      if (series == "" || version == "") bad("缺 version/series")
      if (!isdate(rel)) {
        if (rel == "") next
        bad("release 日期非法: " rel)
      }
      std = (eol_server != "" ? eol_server : eol)
      if (!isdate(std)) bad("标准支持结束日非法: " std)
      if (rel > today) next
      if (std <= today) next
      printf "%s\t%s\t%s\t%s\n", series, version, rel, std
    }
  ' "$path"
}

today=$(date -u +%Y-%m-%d)
checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
csv_path=""

if [[ -n "$csv_arg" ]]; then
  [[ -e "$csv_arg" ]] || die "CSV 不存在: $csv_arg"
  [[ ! -L "$csv_arg" ]] || die "拒绝符号链接: --csv"
  csv_path=$(realpath -- "$csv_arg")
  validate_csv "$csv_path"
else
  command -v curl >/dev/null 2>&1 || die "需要 curl"
  csv_tmp=$(mktemp -- "$tmp_root/ubuntu-csv.XXXXXX")
  page_tmp=$(mktemp -- "$tmp_root/ubuntu-cycle.XXXXXX")
  http_csv=$(curl -sS --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 20 --max-time 60 \
    -o "$csv_tmp" -w '%{http_code}' --fail-with-body "$SOURCE_URL" || true)
  [[ "$http_csv" == "200" ]] || die "下载官方 CSV 失败 HTTP $http_csv"
  validate_csv "$csv_tmp"
  live_rows=$(awk 'NR>1 && $0 !~ /^[[:space:]]*$/ {n++} END {print n+0}' "$csv_tmp")
  [[ "$live_rows" -ge 20 ]] || die "官方 CSV 行数过少，可能不是完整 distro-info-data"
  csv_path="$csv_tmp"

  http_page=$(curl -sS --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 20 --max-time 60 \
    -o "$page_tmp" -w '%{http_code}' --fail-with-body "$CROSS_CHECK_URL" || true)
  [[ "$http_page" == "200" ]] || die "交叉对照页下载失败 HTTP $http_page"
  [[ -s "$page_tmp" ]] || die "交叉对照页为空"
  if ! grep -q 'Ubuntu release cycle' "$page_tmp" && ! grep -qi 'release-cycle' "$page_tmp" && ! grep -q 'Standard security maintenance' "$page_tmp"; then
    die "交叉对照页不是 ubuntu.com 发行周期页"
  fi
fi

rows_tmp=$(mktemp -- "$tmp_root/ubuntu-rows.XXXXXX")
if ! filter_supported "$csv_path" "$today" >"$rows_tmp"; then
  die "CSV 含无法解析的已发布版本行"
fi
mapfile -t rows <"$rows_tmp"
[[ ${#rows[@]} -gt 0 ]] || die "标准支持集合为空，拒绝输出"

releases_json='[]'
seen_series=""
for row in "${rows[@]}"; do
  IFS=$'\t' read -r series version release_date eol_date <<<"$row"
  [[ "$series" =~ ^[a-z][a-z0-9]*$ ]] || die "非法 series: $series"
  case " $seen_series " in
    *" $series "*) die "CSV 中 series 重复: $series" ;;
  esac
  seen_series+=" $series"
  if [[ -n "$csv_arg" ]]; then
    :
  else
    ver_num=$(printf '%s' "$version" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    [[ -n "$ver_num" ]] || die "无法从 version 解析数字: $version"
    grep -Fq "$ver_num" "$page_tmp" || die "交叉对照页未出现已选版本 $ver_num（$series）"
  fi
  releases_json=$(jq -c --arg series "$series" --arg version "$version" \
    --arg release_date "$release_date" --arg eol_date "$eol_date" \
    '. + [{series:$series,version:$version,release_date:$release_date,eol_date:$eol_date}]' \
    <<<"$releases_json")
done

releases_json=$(jq -c 'sort_by(.release_date)' <<<"$releases_json")

out_tmp=$(mktemp -- "$tmp_root/ubuntu-releases.XXXXXX")
jq -n --argjson schema_version 1 --arg source_url "$SOURCE_URL" --arg checked_at "$checked_at" \
  --argjson releases "$releases_json" \
  '{schema_version:$schema_version,source_url:$source_url,checked_at:$checked_at,releases:$releases}' \
  >"$out_tmp"

jq -e '.schema_version==1 and (.source_url|type=="string") and (.checked_at|type=="string") and (.releases|type=="array" and length>0)
  and all(.releases[]; (.series|type=="string") and (.version|type=="string") and (.release_date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and (.eol_date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))
  and all(.releases[]; .release_date <= ($today) and .eol_date > ($today))' \
  --arg today "$today" "$out_tmp" >/dev/null \
  || die "输出 JSON 结构校验失败"

mv -f -- "$out_tmp" "$output_real"
out_tmp=""
echo "ubuntu_releases: 写入 $output_real （$today UTC，${#rows[@]} 个标准支持版本）"
