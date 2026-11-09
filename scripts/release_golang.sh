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
REL_TAG_RE='^apt-hub-go-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*$'
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
  scripts/release_golang.sh status --repository <owner/repo> --tag <apt-hub-go-X.Y.Z-R>
      [--fetch-dir <tmp内目录>]
  scripts/release_golang.sh upload --repository <owner/repo> --tag <apt-hub-go-X.Y.Z-R>
      --asset-dir <构包输出> --source-sha <40hex> [--draft-body <文件>]
  scripts/release_golang.sh prune --repository <owner/repo> --current-tag <apt-hub-go-X.Y.Z-R>
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

under_tmp() {
  local abs="$1"
  [[ "${abs}" == "${PROJECT_TMP}" || "${abs}" == "${PROJECT_TMP}/"* ]]
}

abs_path() {
  local p="$1"
  [[ -n "${p}" ]] || die "空路径"
  if [[ "${p}" != /* ]]; then
    p="${PWD%/}/${p}"
  fi
  printf '%s\n' "${p%/}"
}

select_stable_version() {
  local index="$1"
  local best_tag="" best_ver="" tag ver
  while IFS= read -r tag; do
    [[ "${tag}" =~ ${GO_TAG_RE} ]] || die "拒绝非稳定 go 版本: ${tag}"
    ver="${tag#go}"
    if [[ -z "${best_ver}" ]] || dpkg --compare-versions "${ver}" gt "${best_ver}"; then
      best_ver="${ver}"
      best_tag="${tag}"
    fi
  done < <(jq -r '.[] | select(.stable==true) | .version' "${index}")
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
  revision="$(jq -r '.revision' "${config}")" || die "读取 revision 失败"
  [[ "${revision}" =~ ${DEC_POS} ]] || die "revision 非法"
  index_url="$(jq -r '.release_index_url' "${config}")" || die "读取 release_index_url 失败"
  [[ "${index_url}" == "https://go.dev/dl/?mode=json" ]] || die "release_index_url 必须为官方 JSON"

  if [[ -z "${work_dir}" ]]; then
    work_dir="${PROJECT_TMP}/go-release-prepare"
  fi
  work_dir="$(abs_path "${work_dir}")"
  under_tmp "${work_dir}" || die "work-dir 必须在项目 tmp/ 下"
  mkdir -p -- "${work_dir}"
  [[ ! -L "${work_dir}" ]] || die "work-dir 不能是符号链接"

  local index_file="${work_dir}/downloads.json"
  if [[ -n "${downloads_json}" ]]; then
    downloads_json="$(abs_path "${downloads_json}")"
    [[ -f "${downloads_json}" && ! -L "${downloads_json}" ]] || die "downloads-json 非法"
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
  local go_release_tag="apt-hub-go-${ver}-${revision}"
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
  done < <(find -- "${asset_dir}" -maxdepth 1 -type f -name 'apt-hub-go_*.deb' | LC_ALL=C sort)
}

# 双层：远端 size/digest + 本地 SHA256SUMS/control；忽略 provenance.generated_at_utc。
provenance_packages_equal() {
  local a="$1" b="$2"
  jq -e --slurpfile other "${b}" '
    (.packages | sort_by(.architecture)) as $p1
    | ($other[0].packages | sort_by(.architecture)) as $p2
    | ($p1|length) > 0
    and ($p1|length) == ($p2|length)
    and ([range(0; $p1|length) | $p1[.] == $p2[.]] | all)
  ' "${a}" >/dev/null
}

verify_local_asset_set() {
  local asset_dir="$1"
  local sums prov
  sums="${asset_dir}/SHA256SUMS"
  prov="${asset_dir}/provenance.json"
  [[ -f "${sums}" && -f "${prov}" ]] || return 1
  (cd -- "${asset_dir}" && sha256sum -c --strict SHA256SUMS) >/dev/null || return 1
  jq -e '
    .schema_version=="1"
    and (.packages|type=="array" and length>=1)
    and all(.packages[];
      (.filename|type=="string")
      and (.sha256|test("^[a-f0-9]{64}$"))
      and (.size|type=="string" and test("^[1-9][0-9]*$"))
      and (.architecture|test("^(amd64|arm64)$"))
      and (.package=="apt-hub-go")
    )
  ' "${prov}" >/dev/null || return 1
  local row fn arch ver pkg got_pkg got_ver got_arch got_sha got_sz
  while IFS= read -r row; do
    fn="$(jq -r '.filename' <<<"${row}")"
    arch="$(jq -r '.architecture' <<<"${row}")"
    ver="$(jq -r '.version' <<<"${row}")"
    pkg="$(jq -r '.package' <<<"${row}")"
    [[ -f "${asset_dir}/${fn}" ]] || return 1
    got_pkg="$(dpkg-deb -f -- "${asset_dir}/${fn}" Package)"
    got_ver="$(dpkg-deb -f -- "${asset_dir}/${fn}" Version)"
    got_arch="$(dpkg-deb -f -- "${asset_dir}/${fn}" Architecture)"
    [[ "${got_pkg}" == "${pkg}" && "${got_ver}" == "${ver}" && "${got_arch}" == "${arch}" ]] || return 1
    got_sha="$(sha256sum -- "${asset_dir}/${fn}" | awk '{print $1}')"
    got_sz="$(stat -c '%s' -- "${asset_dir}/${fn}")"
    [[ "${got_sha}" == "$(jq -r '.sha256' <<<"${row}")" ]] || return 1
    [[ "${got_sz}" == "$(jq -r '.size' <<<"${row}")" ]] || return 1
  done < <(jq -c '.packages[]' "${prov}")
  return 0
}

remote_release_asset_complete() {
  # 仅 published 可 complete；draft 永远不完整。
  local rel_json="$1"
  local state name sz
  state="$(jq -r 'if .draft then "draft" elif .prerelease then "prerelease" else "published" end' "${rel_json}")"
  [[ "${state}" == "published" ]] || return 1
  for name in SHA256SUMS provenance.json; do
    sz="$(jq -r --arg n "${name}" '[.assets[]|select(.name==$n)|.size]|first|tostring' "${rel_json}")"
    [[ "${sz}" =~ ^[1-9][0-9]*$ ]] || return 1
  done
  local deb_count
  deb_count="$(jq -r '[.assets[]|select(.name|test("^apt-hub-go_.*\\.deb$"))]|length' "${rel_json}")"
  [[ "${deb_count}" =~ ^[1-9][0-9]*$ ]] || return 1
  return 0
}

cmd_status() {
  local repository="" tag="" fetch_dir=""
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

  local work="${PROJECT_TMP}/go-release-status"
  mkdir -p -- "${work}"
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

  fetch_dir="$(abs_path "${fetch_dir}")"
  under_tmp "${fetch_dir}" || die "fetch-dir 必须在项目 tmp/ 下"
  rm -rf -- "${fetch_dir}"
  mkdir -p -- "${fetch_dir}"
  local name
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    GH_REPO="${repository}" gh release download "${tag}" -p "${name}" -D "${fetch_dir}" \
      || die "下载资产失败: ${name}"
  done < <(jq -r '.assets[].name' "${rel_json}")
  verify_local_asset_set "${fetch_dir}" || die "远端 published 资产核验失败（hash/size/control）"
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
  [[ -f "${asset_dir}/provenance.json" && -f "${asset_dir}/SHA256SUMS" ]] \
    || die "asset-dir 缺少 provenance.json 或 SHA256SUMS"
  mapfile -t debs < <(find -- "${asset_dir}" -maxdepth 1 -type f -name 'apt-hub-go_*.deb' | LC_ALL=C sort)
  [[ "${#debs[@]}" -ge 1 ]] || die "asset-dir 无 deb"

  local work="${PROJECT_TMP}/go-release-upload"
  mkdir -p -- "${work}"
  local rel_json="${work}/release.json"
  local code
  code="$(gh_api_code GET "/repos/${repository}/releases/tags/${tag}" "${rel_json}")"
  local state="" release_id=""
  if [[ "${code}" == "200" ]]; then
    state="$(jq -r 'if .draft then "draft" elif .prerelease then "prerelease" else "published" end' "${rel_json}")"
    release_id="$(jq -r '.id|tostring' "${rel_json}")"
  elif [[ "${code}" == "404" ]]; then
    state="missing"
  else
    die "查询 release 失败 HTTP ${code}"
  fi

  if [[ "${state}" == "published" ]]; then
    verify_local_asset_set "${asset_dir}" || die "本地 asset-dir 未通过 hash/size/control 核验"
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

extract_referenced_go_tags() {
  # 从 apt-data 树提取 Filename 里引用的 apt-hub-go-* release 资产线索 → tag 集合。
  local root="$1"
  local out="$2"
  : >"${out}"
  local f
  while IFS= read -r -d '' f; do
    case "${f}" in
      *.gz)
        gzip -dc -- "${f}" 2>/dev/null | grep -oE 'apt-hub-go-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*' \
          >>"${out}" || true
        ;;
      *)
        grep -oE 'apt-hub-go-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*' "${f}" >>"${out}" || true
        ;;
    esac
  done < <(find -- "${root}" \( -name 'Packages' -o -name 'Packages.gz' -o -path '*/by-hash/*' \) \
    -type f -print0 2>/dev/null)
  if [[ -s "${out}" ]]; then
    LC_ALL=C sort -u -o "${out}" "${out}"
  fi
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
  require_cmd jq curl gh gzip git

  local work="${PROJECT_TMP}/go-release-prune"
  rm -rf -- "${work}"
  mkdir -p -- "${work}/apt-data" "${work}/lists"

  # 真实列 release；失败拒绝清理。
  local list_json="${work}/lists/releases.json"
  if ! GH_REPO="${repository}" gh release list --limit 200 --json tagName,isDraft,isLatest,createdAt \
    >"${list_json}"; then
    die "列出 releases 失败，拒绝清理"
  fi
  jq -e 'type=="array"' "${list_json}" >/dev/null || die "releases 列表非法"

  # apt-data：首轮不存在可识别；网络/鉴权失败拒绝。
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
    # tarball 必须 octet-stream（json Accept 会得到非归档）；跟随 redirect。
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

  # 最近 keep_recent 个已发布（非 draft）同族 tag（按 X.Y.Z-R 版本序）。
  jq -r '.[] | select(.isDraft==false) | .tagName' "${list_json}" \
    | grep -E '^apt-hub-go-[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*$' \
    | sed -E 's/^(apt-hub-go-)(.*)$/\1\2\t\2/' \
    | sort -t$'\t' -k2,2V -r \
    | awk -F'\t' -v n="${keep_recent}" 'NR<=n {print $1}' \
    >>"${protected}" || true
  LC_ALL=C sort -u -o "${protected}" "${protected}"

  local cand del_list="${work}/lists/delete.txt"
  : >"${del_list}"
  while IFS= read -r cand; do
    [[ "${cand}" =~ ${REL_TAG_RE} ]] || continue
    if grep -Fxq -- "${cand}" "${protected}"; then
      continue
    fi
    # 真实查 ref 存在才删
    if GH_REPO="${repository}" gh release view "${cand}" >/dev/null 2>&1; then
      printf '%s\n' "${cand}" >>"${del_list}"
    fi
  done < <(jq -r '.[].tagName' "${list_json}" | grep -E '^apt-hub-go-' || true)

  if [[ ! -s "${del_list}" ]]; then
    printf 'prune_deleted=0\n'
    printf 'go_release_tag=%s\n' "${current_tag}"
    return 0
  fi

  local t
  while IFS= read -r t; do
    [[ -n "${t}" ]] || continue
    # 只删同族 Release 与同名 tag；不动 latest / 仓 v*。
    GH_REPO="${repository}" gh release delete "${t}" -y \
      || die "删除 release 失败: ${t}"
    # 删同名 git tag（若仍在）
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
