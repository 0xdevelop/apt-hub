#!/usr/bin/env bash
# 维护签名站点产物；清理时保护有效索引引用的资产。
set -euo pipefail
umask 022
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${ROOT}"

die() {
  local msg="$*"
  msg="${msg#::error::}"
  printf '::error::%s\n' "${msg}" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法: scripts/publish_apt_site.sh preflight|publish|remove-old
EOF
  exit 2
}

ensure_apt_hub_pages_branch() {
  local name="$1" email="$2" ls_rc=0 work blob tree commit
  set +e
  git ls-remote --exit-code --heads origin refs/heads/apt-hub-pages >/dev/null
  ls_rc=$?
  set -e
  if [[ "${ls_rc}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${ls_rc}" -ne 2 ]]; then
    die "查询 apt-hub-pages 失败，不能当作分支不存在"
  fi
  work=$(mktemp -d "${ROOT}/tmp/apt-hub-pages-init.XXXXXX")
  rmdir "${work}"
  git worktree add --detach "${work}" HEAD
  : >"${work}/.nojekyll"
  blob=$(git -C "${work}" hash-object -w -- "${work}/.nojekyll")
  tree=$(printf '100644 blob %s\t.nojekyll\n' "${blob}" | git -C "${work}" mktree)
  commit=$(
    GIT_AUTHOR_NAME="${name}" \
      GIT_AUTHOR_EMAIL="${email}" \
      GIT_COMMITTER_NAME="${name}" \
      GIT_COMMITTER_EMAIL="${email}" \
      git -C "${work}" commit-tree "${tree}" -m "准备 Pages 产物分支"
  )
  if ! git -C "${work}" push origin "${commit}:refs/heads/apt-hub-pages"; then
    git worktree remove --force "${work}" >/dev/null 2>&1 || true
    die "创建 apt-hub-pages 失败，未改已有历史"
  fi
  git worktree remove --force "${work}" >/dev/null 2>&1 || true
}

preflight() {
  local pages actor site cname login id api_rc pages_err email
  [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || die "缺少工作流仓库上下文"
  actor=$(gh api "users/${GITHUB_ACTOR:?}") || die "无法读取发布者"
  login=$(jq -er '.login' <<<"${actor}")
  id=$(jq -er '.id | tostring' <<<"${actor}")
  jq -e '.type=="User"' <<<"${actor}" >/dev/null || die "拒绝非人类发布者"
  [[ "${login,,}" == "${GITHUB_ACTOR,,}" && "${id}" == "${GITHUB_ACTOR_ID:?}" ]] || die "发布者身份与上下文不一致"
  [[ "${login}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ && "${id}" =~ ^[1-9][0-9]*$ ]] || die "发布者身份格式非法"
  email="${id}+${login}@users.noreply.github.com"
  ensure_apt_hub_pages_branch "${login}" "${email}"
  pages_err=$(mktemp "${ROOT}/tmp/pages-api.XXXXXX")
  set +e
  pages=$(gh api "repos/${GITHUB_REPOSITORY}/pages" 2>"${pages_err}")
  api_rc=$?
  set -e
  if [[ "${api_rc}" -ne 0 ]]; then
    if grep -F -q 'HTTP 404' "${pages_err}"; then
      rm -f -- "${pages_err}"
      die "产物分支 apt-hub-pages 已就绪，请在仓库 Pages 设置选择 apt-hub-pages 分支根目录后重跑；不自动更改设置"
    fi
    rm -f -- "${pages_err}"
    die "读取 Pages 失败（权限或网络），不能当作未启用"
  fi
  rm -f -- "${pages_err}"
  jq -e '.build_type=="legacy" and .source.branch=="apt-hub-pages" and .source.path=="/"' <<<"${pages}" >/dev/null \
    || die "产物分支 apt-hub-pages 已就绪，请在仓库 Pages 设置选择 apt-hub-pages 分支根目录后重跑；不自动更改设置"
  site=$(jq -er '.html_url | select(type=="string" and length>0)' <<<"${pages}") || die "Pages html_url 不是非空字符串"
  [[ "${site}" != *$'\n'* && "${site}" != *$'\r'* ]] || die "Pages html_url 含换行"
  site="${site%/}"
  case "${site}" in
    http://*) site="https://${site#http://}" ;;
    https://*) ;;
    *) die "Pages URL 协议非法" ;;
  esac
  local url_re='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$'
  [[ "${site}" =~ ${url_re} ]] || die "Pages URL 非法"
  cname=$(jq -r '.cname // ""' <<<"${pages}")
  [[ -z "${cname}" || "${cname}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Pages cname 非法"
  printf 'site_url=%s\ncname=%s\ngit_name=%s\ngit_email=%s\n' \
    "${site}" "${cname}" "${login}" "${email}" >>"${GITHUB_OUTPUT:?}"
}

import_key() {
  set +x
  [[ -n "${APT_HUB_GPG_PRIVATE_KEY:-}" ]] || die "缺少 APT_HUB_GPG_PRIVATE_KEY"
  export GNUPGHOME="${ROOT}/tmp/gnupg"
  [[ ! -e "${GNUPGHOME}" && ! -L "${GNUPGHOME}" ]] || die "临时密钥目录已存在，拒绝覆盖"
  mkdir -p "${GNUPGHOME}" && chmod 700 "${GNUPGHOME}"
  printf '%s\n' "${APT_HUB_GPG_PRIVATE_KEY}" | gpg --batch --import || die "私钥导入失败"
  local listing fpr
  local -a fingerprints
  listing=$(gpg --batch --with-colons --list-secret-keys) || die "无法读取导入的私钥"
  mapfile -t fingerprints < <(awk -F: '/^sec:/{want=1;next} /^fpr:/ && want {print toupper($10);want=0}' <<<"${listing}")
  [[ "${#fingerprints[@]}" -eq 1 ]] || die "需要恰好一个主私钥身份"
  fpr="${fingerprints[0]}"
  [[ "${fpr}" =~ ^[A-F0-9]{40}$ ]] || die "派生指纹非法"
  printf 'apt-hub-sign-check\n' >"${GNUPGHOME}/check"
  gpg --batch --yes --pinentry-mode loopback --passphrase '' --local-user "${fpr}" \
    --clearsign --output /dev/null "${GNUPGHOME}/check" || die "无口令签名检查失败"
  rm -f -- "${GNUPGHOME}/check"
  printf '%s\n' "${fpr}" >tmp/signing-fingerprint
  [[ -z "${GITHUB_OUTPUT:-}" ]] || printf 'fingerprint=%s\n' "${fpr}" >>"${GITHUB_OUTPUT}"
}

get_pre_del_tag() {
  local v_str="$1" base major minor base_str
  base_str="${v_str%%.*}"
  base="${base_str#v}"
  major="$(printf '%s\n' "${v_str}" | cut -d. -f2)"
  minor="$(printf '%s\n' "${v_str}" | cut -d. -f3)"
  if ((minor > 0)); then
    minor=$((minor - 1))
  else
    minor=999
    if ((major > 0)); then
      major=$((major - 1))
    else
      major=999
      if ((base > 0)); then
        base=$((base - 1))
      else
        echo "版本不能再递减: ${v_str}" >&2
        return 1
      fi
    fi
  fi
  printf 'v%s.%s.%s\n' "${base}" "${major}" "${minor}"
}

remove_old() {
  local event="${EVENT_NAME:-}" ref="${REF:-}" tag="" old="" errf view_rc sha grep_rc
  if [[ "${event}" != "push" ]]; then
    echo "非 tag push，跳过两代清理"
    exit 0
  fi
  if [[ ! "${ref}" =~ ^refs/tags/(v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "非严格 vX.Y.Z，跳过两代清理"
    exit 0
  fi
  tag="${BASH_REMATCH[1]}"
  if ! old="$(get_pre_del_tag "$(get_pre_del_tag "${tag}")")"; then
    echo "没有两代前版本，跳过清理"
    exit 0
  fi
  echo "Old version to remove: ${old}"
  case "${old}" in
    golang-*|latest)
      echo "拒绝删除 golang 或 latest: ${old}" >&2
      exit 1
      ;;
  esac
  [[ "${old}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "旧版本非法: ${old}"
  [[ -n "${GH_TOKEN:-}" ]] || die "缺少 GH_TOKEN"
  if ! git fetch origin refs/heads/apt-hub-pages:refs/remotes/origin/apt-hub-pages; then
    die "读取 apt-hub-pages 失败，拒绝删除"
  fi
  sha="$(git rev-parse --verify refs/remotes/origin/apt-hub-pages)"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "apt-hub-pages SHA 非法"
  mkdir -p -- tmp
  [[ -d tmp && ! -L tmp ]] || die "项目 tmp 不可用"
  local scan needle magic text path scan_rc gz_rc grep_rc
  scan="$(mktemp -d tmp/script-old-scan.XXXXXX)"
  if ! git archive "${sha}" | tar -x -C "${scan}"; then
    rm -rf -- "${scan}"
    die "解包 apt-hub-pages 失败，拒绝删除"
  fi
  needle="releases/download/${old}/"
  scan_rc=0
  find -- "${scan}" \( -name 'Packages' -o -name 'Packages.gz' \) -type f -print0 >"${scan}/files.bin" || die "枚举索引失败，拒绝清理"
  while IFS= read -r -d '' path; do
    [[ -n "${path}" ]] || continue
    magic="$(od -An -t x1 -N 2 -- "${path}" | tr -d '[:space:]')"
    if [[ "${magic}" == "1f8b" ]]; then
      text="$(mktemp "${scan}/plain.XXXXXX")"
      set +e
      gzip -dc -- "${path}" >"${text}"
      gz_rc=$?
      set -e
      if [[ "${gz_rc}" -ne 0 ]]; then
        rm -rf -- "${scan}"
        die "解压索引失败，拒绝删除"
      fi
    else
      text="${path}"
    fi
    set +e
    grep -F -q -- "${needle}" "${text}"
    grep_rc=$?
    set -e
    if [[ "${grep_rc}" -eq 0 ]]; then
      rm -rf -- "${scan}"
      echo "有效索引仍引用 ${old}，不删除"
      exit 0
    fi
    if [[ "${grep_rc}" -gt 1 ]]; then
      rm -rf -- "${scan}"
      die "检索索引引用失败"
    fi
  done <"${scan}/files.bin" || scan_rc=$?
  rm -rf -- "${scan}"
  if [[ "${scan_rc}" -ne 0 ]]; then
    die "检索索引引用失败"
  fi
  errf="$(mktemp tmp/script-old-view.XXXXXX)"
  set +e
  gh release view "${old}" >/dev/null 2>"${errf}"
  view_rc=$?
  set -e
  delete_leftover_tag() {
    local ls_rc=0
    set +e
    git ls-remote --exit-code origin "refs/tags/${old}" >/dev/null
    ls_rc=$?
    set -e
    if [[ "${ls_rc}" -eq 2 ]]; then
      return 0
    fi
    if [[ "${ls_rc}" -ne 0 ]]; then
      die "查询 tag 失败 rc=${ls_rc}"
    fi
    git push origin --delete "${old}" || die "删除残留 tag 失败"
  }
  if [[ "${view_rc}" -ne 0 ]]; then
    if grep -Eiq 'release not found|HTTP 404|Not Found' "${errf}"; then
      rm -f -- "${errf}"
      delete_leftover_tag
      echo "Release ${old} 不存在"
      exit 0
    fi
    echo "查询旧 Release 失败 rc=${view_rc}" >&2
    cat -- "${errf}" >&2 || true
    rm -f -- "${errf}"
    exit "${view_rc}"
  fi
  rm -f -- "${errf}"
  gh release delete "${old}" -y --cleanup-tag
  delete_leftover_tag
}

restore_previous() {
  [[ ! -e tmp/previous && ! -L tmp/previous ]] || die "previous 已存在，拒绝覆盖"
  [[ ! -e tmp/previous-prev && ! -L tmp/previous-prev ]] || die "previous-prev 已存在，拒绝覆盖"
  mkdir -p tmp/previous
  if ! git ls-remote --heads origin apt-hub-pages >tmp/apt-hub-pages-refs.txt; then
    echo "列出 apt-hub-pages 失败（网络或鉴权），不能当首轮空目录" >&2
    exit 1
  fi
  if [[ ! -s tmp/apt-hub-pages-refs.txt ]]; then
    echo "apt-hub-pages 分支不存在，使用空 previous"
    : >tmp/apt-hub-pages-base.sha
    return 0
  fi
  git fetch origin refs/heads/apt-hub-pages:refs/remotes/origin/apt-hub-pages
  local sha prev_sha=""
  sha="$(git rev-parse --verify origin/apt-hub-pages)"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "无法解析 apt-hub-pages SHA"
  printf '%s\n' "${sha}" >tmp/apt-hub-pages-base.sha
  git archive "${sha}" | tar -x -C tmp/previous
  [[ -d tmp/previous ]] || die "恢复 apt-hub-pages 失败"
  if prev_sha="$(git rev-parse --verify "${sha}^" 2>/dev/null)" && [[ "${prev_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    mkdir -p tmp/previous-prev
    git archive "${prev_sha}" | tar -x -C tmp/previous-prev
    [[ -d tmp/previous-prev ]] || die "恢复前两代 apt-hub-pages 失败"
  fi
}

build_site() {
  local fpr="${APT_HUB_FINGERPRINT:-}" site="${SITE_URL:-}" tag="${RELEASE_TAG:-}" repo="${PACKAGE_REPOSITORY:-}"
  local pkg_tag="${PACKAGE_RELEASE_TAG:-${tag}}"
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "release-tag 非法"
  [[ "${pkg_tag}" == "${tag}" ]] || die "PACKAGE_RELEASE_TAG(${pkg_tag}) 必须与 RELEASE_TAG(${tag}) 一致"
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "缺少 GITHUB_TOKEN"
  export GNUPGHOME="${PWD}/tmp/gnupg"
  chmod a+x scripts/update_sources.sh scripts/ubuntu_releases.sh scripts/sync.sh scripts/render.sh scripts/verify_ubuntu.sh scripts/add_source.sh
  fpr="$(printf '%s' "${fpr}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  [[ "${fpr}" =~ ^[A-F0-9]{40}$ ]] || die "fingerprint 非法"
  [[ -n "${site}" ]] || die "缺少 Pages site_url"
  [[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "package-repository 非法"
  [[ ! -e tmp/update-candidate && ! -e tmp/site ]] || die "候选输出已存在，拒绝覆盖"
  local -a update_args
  update_args=(
    --catalog config/packages.json
    --previous tmp/previous
    --work-dir tmp/update-candidate
    --gnupghome "${GNUPGHOME}"
    --fingerprint "${fpr}"
    --site-url "${site}"
    --package-repository "${repo}"
    --release-tag "${tag}"
    --package-release-tag "${pkg_tag}"
  )
  if [[ -d tmp/previous-prev ]]; then
    update_args+=(--previous-prev tmp/previous-prev)
  fi
  if [[ -d tmp/debs/upstream ]]; then
    update_args+=(--upstream-dir tmp/debs/upstream)
  fi
  if [[ -n "${ROTATE_FROM:-}" ]]; then
    [[ "${ROTATE_FROM}" =~ ^[0-9a-fA-F]{40}$ ]] || die "rotate_from 须为 40hex"
    update_args+=(--rotate-from "${ROTATE_FROM}")
  fi
  scripts/update_sources.sh "${update_args[@]}"
  [[ -f tmp/update-candidate/success.json ]] || die "单入口未写出 success.json"
  jq -e '.ok==true' tmp/update-candidate/success.json >/dev/null || die "success.json ok!=true"
  mv tmp/update-candidate/site tmp/site
  : >tmp/site/.nojekyll
  [[ -z "${PAGES_CNAME:-}" ]] || printf '%s\n' "${PAGES_CNAME}" >tmp/site/CNAME
}

gate_site() {
  local hit bytes name
  hit="$(find tmp/site -type l -print -quit)" || die "候选站点符号链接检查失败"
  [[ -z "${hit}" ]] || die "候选站点含符号链接"
  hit="$(find tmp/site ! -type f ! -type d -print -quit)" || die "候选站点特殊文件检查失败"
  [[ -z "${hit}" ]] || die "候选站点含特殊文件"
  [[ -f tmp/site/add_source.sh ]] || die "候选站点缺少普通 add_source.sh"
  [[ "$(stat -c '%a' tmp/site/add_source.sh)" == "644" ]] || die "add_source.sh 必须为 0644"
  cmp -s scripts/add_source.sh tmp/site/add_source.sh || die "add_source.sh 与本次 checkout 不一致"
  hit="$(find tmp/site -name '*.deb' -print -quit)" || die "候选站点 .deb 检查失败"
  [[ -z "${hit}" ]] || die "候选站点含 .deb"
  local rc=0
  grep -r -a -n -E '^-----BEGIN ([A-Z0-9 ]*PRIVATE KEY( BLOCK)?|PGP SECRET KEY BLOCK)-----[[:space:]]*$' tmp/site >tmp/site-key-check.log || rc=$?
  [[ "${rc}" == 1 ]] || die "候选站点含私钥材料或检查失败"
  bytes="$(du -sb tmp/site | awk '{print $1}')"
  echo "site_bytes=${bytes}"
  if [[ "${bytes}" -gt 1073741824 ]]; then
    die "候选站点超过 GitHub Pages 1GB 上限: ${bytes}"
  fi
  for name in apt-hub.gpg state.json index.html add_source.sh repos; do
    [[ -e "tmp/site/${name}" ]] || die "候选站点缺少 ${name}"
  done
  find tmp/site -mindepth 1 -maxdepth 1 -printf '%f\n' >tmp/site-paths.txt || die "读取站点文件失败"
  while IFS= read -r name; do
    case "${name}" in .nojekyll|CNAME|apt-hub.gpg|state.json|index.html|add_source.sh|repos) ;;
      *) die "候选站点含非发布文件: ${name}" ;;
    esac
  done <tmp/site-paths.txt
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "site_ok=true" >>"${GITHUB_OUTPUT}"
}

save_apt_hub_pages() (
  local work base rel saved="" remote name="${APT_HUB_GIT_NAME:?}" email="${APT_HUB_GIT_EMAIL:?}"
  local tree="" base_tree=""
  local -a parents=()
  work=$(mktemp -d "${ROOT}/tmp/apt-hub-pages.XXXXXX")
  rmdir "${work}"
  trap 'git worktree remove --force "${work}" >/dev/null 2>&1 || true' EXIT
  base=$(<tmp/apt-hub-pages-base.sha)
  if [[ -n "${base}" ]]; then
    [[ "${base}" =~ ^[0-9a-f]{40}$ ]] || die "apt-hub-pages 基线非法"
    git worktree add --detach "${work}" "${base}"
    git -C "${work}" ls-files >tmp/previous-paths.txt
    while IFS= read -r rel; do
      case "${rel}" in .nojekyll|CNAME|apt-hub.gpg|state.json|index.html|add_source.sh|repos/*) ;;
        *) die "apt-hub-pages 含非站点文件: ${rel}" ;;
      esac
    done <tmp/previous-paths.txt
    parents=(-p "${base}")
  else
    git worktree add --detach "${work}" HEAD
  fi
  git -C "${work}" read-tree --empty
  while IFS= read -r -d '' rel; do
    rm -rf -- "${rel}"
  done < <(find "${work}" -mindepth 1 -maxdepth 1 ! -name '.git' -print0)
  local names=(.nojekyll CNAME apt-hub.gpg state.json index.html add_source.sh repos)
  for rel in "${names[@]}"; do
    [[ ! -e "tmp/site/${rel}" ]] || cp -a -- "tmp/site/${rel}" "${work}/${rel}"
  done
  git -C "${work}" add -- apt-hub.gpg state.json index.html add_source.sh repos
  for rel in .nojekyll CNAME; do
    [[ ! -f "${work}/${rel}" ]] || git -C "${work}" add -- "${rel}"
  done
  tree=$(git -C "${work}" write-tree)
  if [[ -n "${base}" ]]; then
    base_tree=$(git rev-parse "${base}^{tree}")
    if [[ "${tree}" == "${base_tree}" ]]; then
      saved="${base}"
    fi
  fi
  if [[ -z "${saved}" ]]; then
    saved=$(
      GIT_AUTHOR_NAME="${name}" GIT_AUTHOR_EMAIL="${email}" \
        GIT_COMMITTER_NAME="${name}" GIT_COMMITTER_EMAIL="${email}" \
        git -C "${work}" commit-tree "${tree}" "${parents[@]}" -m "更新 APT 站点产物"
    )
  fi
  git -C "${work}" push origin "${saved}:refs/heads/apt-hub-pages" || die "apt-hub-pages 非快进推送失败，未发布"
  remote=$(git ls-remote --exit-code origin refs/heads/apt-hub-pages) || die "无法回读 apt-hub-pages"
  [[ "${remote%%$'\t'*}" == "${saved}" ]] || die "apt-hub-pages 回读与保存提交不同"
  printf '%s\n' "${saved}" >tmp/apt-hub-pages-saved.sha
  [[ -z "${GITHUB_OUTPUT:-}" ]] || printf 'apt_hub_pages_sha=%s\n' "${saved}" >>"${GITHUB_OUTPUT}"
)

pages_http_note() {
  local file="$1" line=""
  line=$(grep -m 1 -oE 'HTTP [0-9]{3}' -- "${file}" || true)
  if [[ -n "${line}" ]]; then
    printf '%s\n' "${line}"
  else
    printf '%s\n' 'HTTP 状态缺失'
  fi
}

deploy_pages() {
  local sha="${APT_HUB_PAGES_SHA:?}" repo="${GITHUB_REPOSITORY:-}" remote endpoint body status commit attempt
  local matched=0 err note post_cmd
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "::error::站点提交非法"
  [[ "${repo}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*/[A-Za-z0-9_][A-Za-z0-9._-]*$ && "${repo}" != *..* ]] \
    || die "::error::GITHUB_REPOSITORY 非法"
  remote=$(git ls-remote --exit-code origin refs/heads/apt-hub-pages) || die "::error::无法回读 apt-hub-pages"
  [[ "${remote%%$'\t'*}" == "${sha}" ]] || die "::error::Pages 分支提交已变化，拒绝回读: ${sha}"
  post_cmd="gh api --method POST repos/${repo}/pages/builds"
  err=$(mktemp "${ROOT}/tmp/pages-http.XXXXXX")
  if ! gh api --method POST "repos/${repo}/pages/builds" >/dev/null 2>"${err}"; then
    note=$(pages_http_note "${err}")
    rm -f -- "${err}"
    die "阶段=deploy-pages 命令=${post_cmd} ${note}"
  fi
  rm -f -- "${err}"
  endpoint="repos/${repo}/pages/builds/latest"
  status=""
  for ((attempt=0; attempt<60; attempt++)); do
    err=$(mktemp "${ROOT}/tmp/pages-http.XXXXXX")
    if ! body=$(gh api "${endpoint}" 2>"${err}"); then
      note=$(pages_http_note "${err}")
      rm -f -- "${err}"
      die "阶段=deploy-pages 命令=轮询构建状态 ${note}"
    fi
    rm -f -- "${err}"
    status=$(jq -er '.status' <<<"${body}") || die "::error::Pages 构建状态缺失"
    case "${status}" in
      built)
        commit=$(jq -er '.commit' <<<"${body}") || die "::error::Pages 未返回部署提交"
        if [[ "${commit}" == "${sha}" ]]; then
          matched=1
          break
        fi
        sleep 10 ;;
      queued|building) sleep 10 ;;
      *) die "::error::Pages 构建未成功: ${status}" ;;
    esac
  done
  [[ "${matched}" -eq 1 ]] || die "阶段=deploy-pages 命令=轮询构建状态 Pages 构建超时: ${status}"
  for ((attempt=0; attempt<60; attempt++)); do
    if curl -fsS --proto '=https' --connect-timeout 15 --max-time 30 \
      "${SITE_URL:?}/state.json" -o tmp/public-state.json && cmp -s tmp/site/state.json tmp/public-state.json \
      && curl -fsS --proto '=https' --connect-timeout 15 --max-time 30 \
      "${SITE_URL:?}/index.html" -o tmp/public-index.html && cmp -s tmp/site/index.html tmp/public-index.html \
      && curl -fsS --proto '=https' --connect-timeout 15 --max-time 30 \
      "${SITE_URL:?}/add_source.sh" -o tmp/public-add_source.sh && cmp -s tmp/site/add_source.sh tmp/public-add_source.sh; then
      printf 'Pages 已部署并回读提交 %s\n' "${sha}"
      return 0
    fi
    sleep 10
  done
  die "::error::公网站点尚未同时返回本次 state、index 与 add_source，未回写列表: ${SITE_URL:?}"
}

publish() {
  [[ ! -e tmp/gnupg && ! -L tmp/gnupg ]] || die "临时密钥目录已存在，拒绝覆盖"
  trap 'gpgconf --homedir "${ROOT}/tmp/gnupg" --kill all >/dev/null 2>&1 || true; rm -rf -- "${ROOT}/tmp/gnupg"' EXIT
  import_key
  unset APT_HUB_GPG_PRIVATE_KEY
  export APT_HUB_FINGERPRINT
  APT_HUB_FINGERPRINT=$(<tmp/signing-fingerprint)
  restore_previous
  mkdir -p tmp/debs
  bash gen_debs.sh metadata --upstream-dir tmp/debs/upstream
  PACKAGE_REPOSITORY="${GITHUB_REPOSITORY:?}" GITHUB_TOKEN="${GH_TOKEN:?}" build_site
  gate_site
  save_apt_hub_pages
  export APT_HUB_PAGES_SHA
  APT_HUB_PAGES_SHA=$(<tmp/apt-hub-pages-saved.sha)
  deploy_pages
  update_readme
}

update_readme() (
  local name="${APT_HUB_GIT_NAME:-}" email="${APT_HUB_GIT_EMAIL:-}" sha="${APT_HUB_PAGES_SHA:-}" work saved remote repo tag source_sha expected_tree main_sha
  [[ -n "${name}" && -n "${email}" ]] || die "缺少已核验发布者身份"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "缺少已保存 apt-hub-pages SHA"
  repo="${GITHUB_REPOSITORY:-}"
  tag="${RELEASE_TAG:-}"
  [[ "${repo}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*\/[A-Za-z0-9_][A-Za-z0-9._-]*$ && "${repo}" != *..* ]] \
    || die "GITHUB_REPOSITORY 非法"
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "RELEASE_TAG 非法"
  source_sha=$(git rev-parse HEAD) || die "读取本次源码 SHA 失败"
  git fetch origin refs/heads/main:refs/remotes/origin/main || die "读取 main 失败"
  main_sha=$(git rev-parse refs/remotes/origin/main) || die "读取 main SHA 失败"
  work=$(mktemp -d "${ROOT}/tmp/readme.XXXXXX")
  rmdir "${work}"
  trap 'git worktree remove --force "${work}" >/dev/null 2>&1 || true' EXIT
  git worktree add --detach "${work}" "${source_sha}"
  mkdir -p tmp/readme-site "${work}/data"
  git fetch origin refs/heads/apt-hub-pages:refs/remotes/origin/apt-hub-pages
  git cat-file -e "${sha}^{commit}" || die "已部署 SHA 不在 apt-hub-pages 历史中"
  git show "${sha}:state.json" >"${work}/data/published.json"
  bash scripts/render.sh --state "${work}/data/published.json" --readme "${work}/README.md" --site tmp/readme-site \
    --repository "${repo}" --release-tag "${tag}"
  export GIT_AUTHOR_NAME="${name}"
  export GIT_AUTHOR_EMAIL="${email}"
  export GIT_COMMITTER_NAME="${name}"
  export GIT_COMMITTER_EMAIL="${email}"
  git -C "${work}" add -- README.md data/published.json
  if grep -Fqx '列表取自已发布状态。**全源加源是本轮新版功能，尚未部署到 Pages；下列统一命令须待本版部署后使用。**' "${work}/README.md"; then
    grep -v -F -x -- '列表取自已发布状态。**全源加源是本轮新版功能，尚未部署到 Pages；下列统一命令须待本版部署后使用。**' "${work}/README.md" >"${work}/README.md.next"
    mv -- "${work}/README.md.next" "${work}/README.md"
    git -C "${work}" add -- README.md
  fi
  expected_tree=$(git -C "${work}" write-tree) || die "读取预期回写树失败"
  if [[ "${main_sha}" != "${source_sha}" ]]; then
    # 唯一可接受的后继是本次源码的精确生成结果；不放行新业务、VERSION 或 README 正文变化。
    if ! git merge-base --is-ancestor "${source_sha}" "${main_sha}" \
      || [[ "$(git rev-parse "${main_sha}^{tree}")" != "${expected_tree}" ]]; then
      die "main 已推进且不等于本次精确回写结果，拒绝旧源码回写；后续新发版继续，当前运行不清理"
    fi
    remote=$(git ls-remote --exit-code origin refs/heads/main) || die "无法回读 main"
    [[ "${remote%%$'\t'*}" == "${main_sha}" ]] || die "main 在幂等核验期间变化，拒绝旧源码回写"
    echo "README 与已发布状态已一致（本次源码的精确生成后继）"
    exit 0
  fi
  if git -C "${work}" diff --cached --quiet; then
    remote=$(git ls-remote --exit-code origin refs/heads/main) || die "无法回读 main"
    [[ "${remote%%$'\t'*}" == "${main_sha}" ]] || die "main 在幂等核验期间变化，拒绝旧源码回写"
    echo "README 与已发布状态已一致"
    exit 0
  fi
  git -C "${work}" commit -m "回写已部署的软件列表"
  if ! git -C "${work}" push origin HEAD:refs/heads/main; then
    die "主分支有并发更新，禁止 force，请重跑工作流"
  fi
  saved=$(git -C "${work}" rev-parse HEAD)
  remote=$(git ls-remote --exit-code origin refs/heads/main) || die "无法回读 main"
  [[ "${remote%%$'\t'*}" == "${saved}" ]] || die "main 回读与保存提交不同"
)

main() {
  [[ $# -ge 1 ]] || usage
  mkdir -p tmp
  case "$1" in
    preflight) preflight ;;
    import-key) import_key ;;
    deploy-pages) deploy_pages ;;
    publish) publish ;;
    restore-previous) restore_previous ;;
    build-site) build_site ;;
    gate-site) gate_site ;;
    save-apt-hub-pages) save_apt_hub_pages ;;
    update-readme) update_readme ;;
    remove-old) remove_old ;;
    -h|--help) usage ;;
    *) die "未知子命令: $1" ;;
  esac
}

main "$@"
