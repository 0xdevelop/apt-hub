#!/usr/bin/env bash
# 读写根 VERSION；auto/custom 生成 changelog 后精确 stage 提交并 tag/push。
# 不改 git config；不强制 latest；旧同族清理交给 Actions prune。
set -euo pipefail
umask 022
export LC_ALL=C

VERSION_FILE=""
CURRENT_VERSION=""
NEXT_VERSION=""
STAGED_VERSION=0
STAGED_CHANGELOG=""
REPO_ROOT=""

die() {
  printf 'git_tag.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法: git_tag.sh [auto|custom] | git_tag.sh --version <X.Y.Z>
  auto（默认）: 自动 patch+1，写 changelog，commit VERSION+changelog，打 v 标签并 push
  custom: 交互输入版本
  --version: VERSION 须已等于该号；仅打标签并 push（不改 VERSION）
不修改 git config；缺少 user.name/user.email 时拒绝。不移动 latest。
EOF
  exit 2
}

rollback_owned() {
  if [[ "${STAGED_VERSION}" -eq 1 && -n "${CURRENT_VERSION}" ]]; then
    printf '%s\n' "${CURRENT_VERSION}" >"${VERSION_FILE}" || true
  fi
  if [[ -n "${STAGED_CHANGELOG}" && -f "${STAGED_CHANGELOG}" ]]; then
    rm -f -- "${STAGED_CHANGELOG}" || true
  fi
}

on_exit() {
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    rollback_owned
  fi
  exit "${rc}"
}
trap on_exit EXIT

require_git_identity() {
  local name email
  name="$(git config --get user.name || true)"
  email="$(git config --get user.email || true)"
  [[ -n "${name}" ]] || die "缺少 git user.name（不代写 config）"
  [[ -n "${email}" ]] || die "缺少 git user.email（不代写 config）"
}

read_current_version() {
  [[ -f "${VERSION_FILE}" && ! -L "${VERSION_FILE}" ]] || die "缺少 VERSION"
  CURRENT_VERSION="$(tr -d '[:space:]' <"${VERSION_FILE}")"
  [[ "${CURRENT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION 非法: ${CURRENT_VERSION}"
}

bump_patch() {
  local base major minor
  base="$(echo "${CURRENT_VERSION}" | cut -d. -f1)"
  major="$(echo "${CURRENT_VERSION}" | cut -d. -f2)"
  minor="$(echo "${CURRENT_VERSION}" | cut -d. -f3)"
  minor=$((minor + 1))
  if ((minor == 1000)); then
    minor=0
    major=$((major + 1))
  fi
  if ((major == 1000)); then
    major=0
    base=$((base + 1))
  fi
  NEXT_VERSION="${base}.${major}.${minor}"
}

prompt_custom() {
  local inputString
  echo "============================ apt-hub ============================"
  echo "  current VERSION [${CURRENT_VERSION}]"
  echo "================================================================"
  read -r -p "please input version string [example: 0.0.1 or v0.0.1]: " inputString
  [[ -n "${inputString}" ]] || die "空版本"
  if [[ "${inputString}" =~ ^v ]]; then
    NEXT_VERSION="${inputString#v}"
  else
    NEXT_VERSION="${inputString}"
  fi
  [[ "${NEXT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本非法: ${NEXT_VERSION}"
}

find_prev_release_commit() {
  git log --fixed-strings --grep='Release:--:' --format='%H' -n 1 HEAD || true
}

gen_changelog() {
  local out_dir="changelog" out_file prev_release_sha range range_end commit_count shortstat
  mkdir -p "${out_dir}"
  out_file="${out_dir}/v${NEXT_VERSION}.md"
  STAGED_CHANGELOG="${out_file}"
  range_end="HEAD"
  prev_release_sha="$(find_prev_release_commit)"
  if [[ -z "${prev_release_sha}" ]]; then
    prev_release_sha="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
  fi
  range="${prev_release_sha}..${range_end}"
  commit_count="$(git rev-list --count "${range}" 2>/dev/null || echo 0)"
  {
    echo "## v${NEXT_VERSION} ChangeLog"
    echo
    echo "- Release:--: v${NEXT_VERSION}_$(date -u +"%Y-%m-%d_%H:%M:%S")_UTC"
    echo "- Range: ${range}"
    echo "- Commits: ${commit_count}"
    echo
    echo "### commit infos"
    echo
    if [[ "${commit_count}" == "0" ]]; then
      echo "- (no commits between releases)"
    else
      shortstat="$(git diff --shortstat "${range}" 2>/dev/null || true)"
      if [[ -n "${shortstat}" ]]; then
        echo "- ${shortstat}"
      else
        echo "- (no file changes)"
      fi
      echo
      echo '```'
      git diff --stat "${range}" 2>/dev/null || true
      echo '```'
    fi
    echo
    echo "### commit messages"
    echo
    if [[ "${commit_count}" == "0" ]]; then
      echo "- (no commits between releases)"
    else
      git log --reverse --date=short --pretty=format:"- %ad %h %s" "${range}" || true
    fi
    echo
  } >"${out_file}"
}

enter_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "不是 git 仓库"
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  cd -- "${REPO_ROOT}"
  VERSION_FILE="${REPO_ROOT}/VERSION"
}

assert_clean_and_ready() {
  enter_repo
  git rev-parse --verify HEAD >/dev/null 2>&1 || die "仓库没有 HEAD"
  [[ -z "$(git status --porcelain)" ]] || die "工作区不干净，拒绝"
  require_git_identity
}

write_version_and_commit_tag_push() {
  local tag="v${NEXT_VERSION}"
  local msg
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    die "标签已存在: ${tag}"
  fi
  printf '%s\n' "${NEXT_VERSION}" >"${VERSION_FILE}"
  STAGED_VERSION=1
  gen_changelog
  msg="Release:--: v${NEXT_VERSION}_$(date -u +"%Y-%m-%d_%H:%M:%S")_UTC"
  # 精确 stage，禁止 git add -A
  git add -- "${VERSION_FILE}" "changelog/v${NEXT_VERSION}.md"
  # 提交前完整 message 校验：禁止 agent trailer
  if printf '%s\n' "${msg}" | grep -Ei 'co-authored-by:|signed-off-by:|cursoragent|cursor agent' >/dev/null; then
    die "commit message 含禁止 trailer/agent 标记"
  fi
  git commit -m "${msg}" || die "commit 失败"
  STAGED_VERSION=0
  STAGED_CHANGELOG=""
  git tag "${tag}" || die "打标签失败"
  local remote
  for remote in $(git remote); do
    echo "Pushing to ${remote}..."
    git push "${remote}" HEAD || die "push 分支失败: ${remote}"
    git push "${remote}" "${tag}" || die "push 标签失败: ${remote}"
  done
  echo "Completed v${NEXT_VERSION}"
}

tag_only_matching_version() {
  local want="$1"
  local tag="v${want}"
  enter_repo
  git rev-parse --verify HEAD >/dev/null 2>&1 || die "仓库没有 HEAD"
  [[ -z "$(git status --porcelain)" ]] || die "工作区不干净，拒绝"
  read_current_version
  [[ "${CURRENT_VERSION}" == "${want}" ]] || die "VERSION 与 --version 不一致"
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    die "标签已存在: ${tag}"
  fi
  git tag "${tag}" || die "打标签失败"
  local remote remotes
  remotes="$(git remote)"
  if [[ -n "${remotes}" ]]; then
    require_git_identity
    for remote in ${remotes}; do
      git push "${remote}" "${tag}" || die "push 标签失败: ${remote}"
    done
  fi
  echo "已创建标签 ${tag}"
}

main() {
  local mode="${1:-auto}"
  case "${mode}" in
    -h|--help) usage ;;
    --version)
      [[ $# -ge 2 ]] || usage
      [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本必须为数字.数字.数字"
      tag_only_matching_version "$2"
      ;;
    auto|"")
      assert_clean_and_ready
      read_current_version
      bump_patch
      write_version_and_commit_tag_push
      ;;
    custom)
      assert_clean_and_ready
      read_current_version
      prompt_custom
      write_version_and_commit_tag_push
      ;;
    *)
      die "未知参数: ${mode}"
      ;;
  esac
}

main "$@"
