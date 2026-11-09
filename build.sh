#!/usr/bin/env bash
# 编排 Go 官方归档 → deb；扩展入口仅 gen_deb_golang.sh。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C
export LANGUAGE=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "${SCRIPT_DIR}"

# 明确 golang 扩展脚本数组（无需注册平台）。
golang_extend_scripts=(./gen_deb_golang.sh)

output=""
go_version=""
downloads_json=""
archive_dir=""

die() {
  printf 'build.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法: ./build.sh --output <全新/空的本项目tmp内目录> [--go-version <goX.Y.Z>] [--downloads-json <官方JSON>] [--archive-dir <已下载归档目录>]
产物（单平面）: output/{双deb,provenance.json,SHA256SUMS}
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || usage
      output="$2"
      shift 2
      ;;
    --go-version)
      [[ $# -ge 2 ]] || usage
      go_version="$2"
      shift 2
      ;;
    --downloads-json)
      [[ $# -ge 2 ]] || usage
      downloads_json="$2"
      shift 2
      ;;
    --archive-dir)
      [[ $# -ge 2 ]] || usage
      archive_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

[[ -n "${output}" ]] || usage

[[ ${#golang_extend_scripts[@]} -eq 1 ]] || die "golang 扩展脚本数组必须恰好 1 项"
ext="${golang_extend_scripts[0]}"
[[ -f "${ext}" && -x "${ext}" ]] || die "缺少可执行扩展: ${ext}"

args=(--config ./config/go.json --output "${output}")
if [[ -n "${go_version}" ]]; then
  args+=(--version "${go_version}")
fi
if [[ -n "${downloads_json}" ]]; then
  args+=(--downloads-json "${downloads_json}")
fi
if [[ -n "${archive_dir}" ]]; then
  args+=(--archive-dir "${archive_dir}")
fi

# 扩展失败由子进程非 0 传播；gen 自身保证无半套。
"${ext}" "${args[@]}"
printf 'build.sh: layout=flat assets under %s\n' "${output}"
