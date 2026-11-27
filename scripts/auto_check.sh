#!/usr/bin/env bash
# 在有推送权限的机器上巡检已支持软件，本地预验通过后触发 git_tag.sh。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C
export LANGUAGE=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${ROOT}"

die() {
  printf 'auto_check.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/auto_check.sh [--dry-run] [--renew-days <天数>] [--skip-fetch]
                        [--state <state.json>] [--go-downloads-json <文件>]
                        [--upstream-dir <目录>] [--golang-provenance <文件>]
                        [--release-date <Release Date>] [--host-arch <amd64|arm64>]
无更新时打印状态并 exit 0。--dry-run 仍做探测与本地预验，但不调用 git_tag.sh、不提交、不推送。
--renew-days 默认 7（签名 Valid-Until 为 14 天）；0 表示不做签名续签检查。
EOF
  exit 2
}

dry_run=0
renew_days=7
skip_fetch=0
state_file=""
go_downloads_json=""
upstream_dir=""
golang_provenance=""
release_date_override=""
host_arch=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --renew-days)
      [[ $# -ge 2 ]] || usage
      renew_days="$2"; shift 2
      ;;
    --skip-fetch) skip_fetch=1; shift ;;
    --state)
      [[ $# -ge 2 ]] || usage
      state_file="$2"; shift 2
      ;;
    --go-downloads-json)
      [[ $# -ge 2 ]] || usage
      go_downloads_json="$2"; shift 2
      ;;
    --upstream-dir)
      [[ $# -ge 2 ]] || usage
      upstream_dir="$2"; shift 2
      ;;
    --golang-provenance)
      [[ $# -ge 2 ]] || usage
      golang_provenance="$2"; shift 2
      ;;
    --release-date)
      [[ $# -ge 2 ]] || usage
      release_date_override="$2"; shift 2
      ;;
    --host-arch)
      [[ $# -ge 2 ]] || usage
      host_arch="$2"; shift 2
      ;;
    -h|--help) usage ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ "${renew_days}" =~ ^[0-9]+$ ]] || die "--renew-days 必须是非负整数"
if [[ -n "${host_arch}" ]]; then
  [[ "${host_arch}" =~ ^(amd64|arm64)$ ]] || die "非法 --host-arch: ${host_arch}"
fi

require_cmd() {
  local c
  for c in "$@"; do
    command -v -- "${c}" >/dev/null 2>&1 || die "缺少命令: ${c}"
  done
}

curl_https() {
  local extra_auth=()
  if [[ -n "${GH_TOKEN:-}" ]]; then
    extra_auth=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 120 --retry 2 \
    -H "Accept: application/vnd.github+json" \
    "${extra_auth[@]}" "$@"
}

head_http_code() {
  local url="$1"
  curl -sS --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 60 --retry 2 \
    -o /dev/null -w '%{http_code}' -I -- "${url}"
}

assert_clean_worktree() {
  [[ -z "$(git status --porcelain)" ]] || die "工作区不干净，拒绝继续"
}

sync_remotes() {
  local head remote
  git fetch origin refs/heads/main:refs/remotes/origin/main \
    || die "同步 origin/main 失败"
  git fetch origin refs/heads/apt-hub-pages:refs/remotes/origin/apt-hub-pages \
    || die "同步 origin/apt-hub-pages 失败"
  head=$(git rev-parse HEAD)
  remote=$(git rev-parse origin/main)
  if [[ "${head}" == "${remote}" ]]; then
    return 0
  fi
  if git merge-base --is-ancestor "${head}" "${remote}"; then
    git merge --ff-only origin/main || die "快进 origin/main 失败"
    [[ -z "$(git status --porcelain)" ]] || die "快进后工作区不干净，拒绝继续"
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
      || die "快进后本地 main 仍与 origin/main 不一致"
    return 0
  fi
  die "本地 main 与 origin/main 不一致，拒绝自动同步"
}

load_state() {
  local dest="$1"
  if [[ -n "${state_file}" ]]; then
    [[ -f "${state_file}" && ! -L "${state_file}" ]] || die "--state 不是普通文件"
    cp -- "${state_file}" "${dest}"
  else
    git cat-file -e origin/apt-hub-pages:state.json 2>/dev/null \
      || die "origin/apt-hub-pages 缺少 state.json"
    git show origin/apt-hub-pages:state.json >"${dest}"
  fi
  jq -e '.schema_version=="2" and (.packages|type)=="array"' "${dest}" >/dev/null \
    || die "state.json 结构非法"
}

latest_go_version() {
  local index="$1" latest="" v
  jq -er 'if type=="array" and length>0 then .[]|select(.stable==true)|.version else error("bad index") end' \
    "${index}" >"${WORK}/stable-go.txt" || die "Go stable 索引非法"
  while IFS= read -r v; do
    if [[ "${v}" =~ ^go[0-9]+(\.[0-9]+)?$ ]]; then
      continue
    fi
    [[ "${v}" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Go stable 版本非法: ${v}"
    if [[ -z "${latest}" ]] || dpkg --compare-versions "${v#go}" gt "${latest#go}"; then
      latest="${v}"
    fi
  done <"${WORK}/stable-go.txt"
  [[ -n "${latest}" ]] || die "Go stable 索引为空"
  printf '%s\n' "${latest}"
}

build_inputs_sha256() {
  (cd "${ROOT}" && sha256sum scripts/gen_deb_golang.sh config/go.json | sha256sum | cut -d' ' -f1)
}

state_row() {
  local id="$1"
  jq -c --arg id "${id}" '.packages[]? | select(.id==$id)' "${STATE}" || true
}

published_go_inputs() {
  local row="$1" tag repo url
  if [[ -n "${golang_provenance}" ]]; then
    [[ -f "${golang_provenance}" && ! -L "${golang_provenance}" ]] || die "--golang-provenance 不是普通文件"
    cp -- "${golang_provenance}" "${WORK}/golang.provenance.json"
  else
    repo=$(jq -r '.package_repository // empty' <<<"${row}")
    tag=$(jq -r '.release_tag // empty' <<<"${row}")
    [[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "state 中 golang 缺少 package_repository"
    [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "state 中 golang 缺少 release_tag"
    url="https://github.com/${repo}/releases/download/${tag}/golang.provenance.json"
    curl_https -o "${WORK}/golang.provenance.json" -- "${url}" \
      || die "下载 golang.provenance.json 失败: ${url}"
  fi
  jq -r '.build_inputs_sha256 // empty' "${WORK}/golang.provenance.json"
}

github_latest() {
  local id="$1" repo="$2"
  local body
  if [[ -n "${upstream_dir}" ]]; then
    body="${upstream_dir}/${id}.json"
    [[ -f "${body}" && ! -L "${body}" ]] || die "upstream-dir 缺少 ${id}.json"
    cat -- "${body}"
    return 0
  fi
  curl_https -- "https://api.github.com/repos/${repo}/releases/latest"
}

detect_host_arch() {
  local arch
  if [[ -n "${host_arch}" ]]; then
    printf '%s\n' "${host_arch}"
    return 0
  fi
  if command -v dpkg >/dev/null 2>&1; then
    arch="$(dpkg --print-architecture)"
  else
    case "$(uname -m)" in
      x86_64) arch=amd64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) die "无法识别本机架构: $(uname -m)" ;;
    esac
  fi
  [[ "${arch}" =~ ^(amd64|arm64)$ ]] || die "本机架构不受支持: ${arch}"
  printf '%s\n' "${arch}"
}

load_release_date() {
  local path date_line
  if [[ -n "${release_date_override}" ]]; then
    printf '%s\n' "${release_date_override}"
    return 0
  fi
  path="$(git ls-tree -r --name-only origin/apt-hub-pages | awk '/\/dists\/[^/]+\/Release$/{print; exit}')"
  [[ -n "${path}" ]] || die "apt-hub-pages 中没有 Release 文件"
  date_line="$(git show "origin/apt-hub-pages:${path}" | awk -F': ' '$1=="Date"{print $2; exit}')"
  [[ -n "${date_line}" ]] || die "Release 缺少 Date: ${path}"
  printf '%s\n' "${date_line}"
}

age_days() {
  local raw="$1" ts now
  ts="$(date -u -d "${raw}" +%s 2>/dev/null)" || die "无法解析签名日期: ${raw}"
  now="$(date -u +%s)"
  printf '%s\n' $(( (now - ts) / 86400 ))
}

catalog_source_type() {
  local row="$1" st
  st="$(jq -r 'if (.source_type|type)=="string" and (.source_type|length)>0 then .source_type else "githubdeb" end' <<<"${row}")"
  case "${st}" in
    githubdeb|go_official_archive) printf '%s\n' "${st}" ;;
    *) die "非法 source_type: ${st}" ;;
  esac
}

format_prev() {
  local v="$1"
  if [[ -z "${v}" ]]; then
    printf 'none'
  else
    printf '%s' "${v}"
  fi
}

require_cmd bash git jq curl date sha256sum
[[ -f config/packages.json && ! -L config/packages.json ]] || die "缺少 config/packages.json"
assert_clean_worktree
if [[ "${skip_fetch}" -eq 0 ]]; then
  sync_remotes
fi
assert_clean_worktree

mkdir -p -- "${ROOT}/tmp"
WORK="$(mktemp -d "${ROOT}/tmp/auto-check.XXXXXX")"
STATE="${WORK}/state.json"
cleanup() {
  rm -rf -- "${WORK}"
}
trap cleanup EXIT

load_state "${STATE}"

reasons=()
golang_latest=""
preverify_golang=0
preverify_debs=()

while IFS= read -r pkgjson; do
  [[ -n "${pkgjson}" ]] || continue
  id="$(jq -r '.id // empty' <<<"${pkgjson}")"
  [[ -n "${id}" ]] || die "catalog 条目缺少 id"
  st="$(catalog_source_type "${pkgjson}")"
  prev="$(state_row "${id}")"
  prev_ver=""
  if [[ -n "${prev}" ]]; then
    prev_ver="$(jq -r '.version // empty' <<<"${prev}")"
  fi
  if [[ "${st}" == "go_official_archive" ]]; then
    require_cmd dpkg
    if [[ -n "${go_downloads_json}" ]]; then
      [[ -f "${go_downloads_json}" && ! -L "${go_downloads_json}" ]] || die "--go-downloads-json 不是普通文件"
      cp -- "${go_downloads_json}" "${WORK}/go-downloads.json"
    else
      curl_https -o "${WORK}/go-downloads.json" -- 'https://go.dev/dl/?mode=json&include=all' \
        || die "获取 Go 官方索引失败"
    fi
    golang_latest="$(latest_go_version "${WORK}/go-downloads.json")"
    current_inputs="$(build_inputs_sha256)"
    published_ver=""
    published_inputs=""
    if [[ -n "${prev}" ]]; then
      published_ver="$(jq -r '.upstream.version // empty' <<<"${prev}")"
      published_inputs="$(published_go_inputs "${prev}")"
    fi
    changed=0
    note=""
    if [[ -z "${published_ver}" ]]; then
      changed=1
    elif [[ "${published_ver}" != "${golang_latest}" ]]; then
      changed=1
    fi
    if [[ -n "${published_inputs}" && "${published_inputs}" != "${current_inputs}" ]]; then
      changed=1
      note=" (build inputs)"
    fi
    if [[ "${changed}" -eq 1 ]]; then
      reasons+=("auto-update: ${id} $(format_prev "${published_ver#go}") -> ${golang_latest#go}${note}")
      preverify_golang=1
    fi
  else
    repo="$(jq -r '.repository // empty' <<<"${pkgjson}")"
    [[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "非法 repository: ${id}"
    latest_json="$(github_latest "${id}" "${repo}")"
    echo "${latest_json}" | jq -e 'type=="object" and (.tag_name|type)=="string" and (.assets|type)=="array"' >/dev/null \
      || die "GitHub latest 响应非法: ${id}"
    jq -e '.draft!=true and .prerelease!=true' <<<"${latest_json}" >/dev/null \
      || die "latest 不是稳定版: ${id}"
    tag="$(jq -r '.tag_name' <<<"${latest_json}")"
    echo "${latest_json}" >"${WORK}/latest-${id}.json"
    # 已发布 version 通常等于上游 tag；二者都记下来以便比较。
    if [[ "${prev_ver}" != "${tag}" ]]; then
      reasons+=("auto-update: ${id} $(format_prev "${prev_ver}") -> ${tag}")
      preverify_debs+=("${id}")
    fi
  fi
done < <(jq -c '.packages[]?' config/packages.json)

if [[ "${renew_days}" -gt 0 ]]; then
  signed="$(load_release_date)"
  age="$(age_days "${signed}")"
  if [[ "${age}" -ge "${renew_days}" ]]; then
    reasons+=("auto-renew: apt signing refresh")
  fi
fi

if [[ "${#reasons[@]}" -eq 0 ]]; then
  printf 'auto_check.sh: 无更新\n'
  if [[ -n "${golang_latest}" ]]; then
    printf '  golang 上游稳定版=%s 构包输入未变或与已发布一致\n' "${golang_latest}"
  fi
  if [[ "${renew_days}" -gt 0 ]]; then
    printf '  签名日期未超过 %s 天续签阈值\n' "${renew_days}"
  fi
  exit 0
fi

printf 'auto_check.sh: 发现更新\n'
for reason in "${reasons[@]}"; do
  printf '  %s\n' "${reason}"
done

if [[ "${preverify_golang}" -eq 1 ]]; then
  [[ -n "${golang_latest}" ]] || die "缺少待预验的 Go 版本"
  [[ -x "${ROOT}/build.sh" ]] || die "缺少 build.sh"
  arch="$(detect_host_arch)"
  build_out="$(mktemp -d "${ROOT}/tmp/auto-check-build.XXXXXX")"
  build_args=(--output "${build_out}" --go-version "${golang_latest}" --arch "${arch}")
  if [[ -n "${go_downloads_json}" ]]; then
    build_args+=(--downloads-json "${go_downloads_json}")
  elif [[ -f "${WORK}/go-downloads.json" ]]; then
    build_args+=(--downloads-json "${WORK}/go-downloads.json")
  fi
  printf 'auto_check.sh: 本地预验构包 %s %s\n' "${golang_latest}" "${arch}"
  bash "${ROOT}/build.sh" "${build_args[@]}" || {
    rm -rf -- "${build_out}"
    die "本地构包预验失败"
  }
  bash "${ROOT}/build.sh" test || {
    rm -rf -- "${build_out}"
    die "build.sh test 失败"
  }
  rm -rf -- "${build_out}"
  printf 'auto_check.sh: 构包预验通过，已清理临时目录\n'
fi

for id in "${preverify_debs[@]+"${preverify_debs[@]}"}"; do
  pkgjson="$(jq -c --arg id "${id}" '.packages[] | select(.id==$id)' config/packages.json)"
  latest_json="$(cat -- "${WORK}/latest-${id}.json")"
  while IFS= read -r arch; do
    [[ -n "${arch}" ]] || continue
    regex="$(jq -r --arg a "${arch}" '.architectures[$a]' <<<"${pkgjson}")"
    n="$(jq --arg re "${regex}" '[.assets[]? | select((.name|type=="string") and (.name|test($re)))] | length' <<<"${latest_json}")"
    [[ "${n}" == "1" ]] || die "${id} 架构 ${arch} 资产正则未唯一匹配（${n}）"
    asset="$(jq -c --arg re "${regex}" '.assets[] | select(.name|test($re))' <<<"${latest_json}")"
    url="$(jq -r '.browser_download_url // empty' <<<"${asset}")"
    [[ "${url}" == https://* ]] || die "${id} ${arch} 缺少 https 下载 URL"
    size="$(jq -r '.size|tostring' <<<"${asset}")"
    [[ "${size}" =~ ^[1-9][0-9]*$ ]] || die "${id} ${arch} size 非法"
    digest="$(jq -r '.digest // empty' <<<"${asset}")"
    [[ -z "${digest}" || "${digest}" == sha256:* ]] || die "${id} ${arch} digest 非法"
    code="$(head_http_code "${url}")" || die "${id} ${arch} 探测下载 URL 失败"
    [[ "${code}" == "200" || "${code}" == "302" ]] \
      || die "${id} ${arch} 下载 URL 不可达（HTTP ${code}）"
    printf 'auto_check.sh: 外链预验通过 %s %s HTTP %s\n' "${id}" "${arch}" "${code}"
  done < <(jq -r '.architectures | keys[]' <<<"${pkgjson}")
done

printf '%s\n' "${reasons[@]}" >"${ROOT}/tmp/auto_check_reasons.txt"
if [[ "${dry_run}" -eq 1 ]]; then
  printf 'auto_check.sh: --dry-run，跳过 git_tag.sh\n'
  exit 0
fi
[[ -x "${ROOT}/git_tag.sh" ]] || die "缺少 git_tag.sh"
bash "${ROOT}/git_tag.sh"
printf 'auto_check.sh: 已触发 git_tag.sh\n'
