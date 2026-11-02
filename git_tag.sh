#!/usr/bin/env bash
# 校验 VERSION 与 --version 后，在当前仓库 HEAD 创建本地标签 v<version>。
# 不 push、不 force、不删除标签、不 git add、不改 git config。
set -euo pipefail

usage() {
  echo "用法: git_tag.sh --version <脚本版本号>" >&2
  echo "脚本版本号须与仓库根目录 VERSION 完全一致（数字.数字.数字，无 v 前缀）。" >&2
  exit 2
}

version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || usage
      version="$2"
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

[[ -n "$version" ]] || usage
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本必须为数字.数字.数字，且不要 v 前缀" >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "当前目录不是 git 仓库" >&2
  exit 1
fi

root=$(git rev-parse --show-toplevel)
cd "$root"

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "仓库没有 HEAD，拒绝打标签" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "工作区不干净，拒绝打标签" >&2
  exit 1
fi

version_file="$root/VERSION"
if [[ ! -f "$version_file" ]]; then
  echo "缺少 VERSION" >&2
  exit 1
fi
if ! printf '%s\n' "$version" | cmp -s - "$version_file"; then
  echo "VERSION 与 --version 不一致" >&2
  exit 1
fi

tag="v${version}"
if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "标签已存在: ${tag}" >&2
  exit 1
fi

git tag "$tag"
echo "已创建本地标签 ${tag}"
