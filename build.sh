#!/usr/bin/env bash
# 默认 release：最终文件只进 build/upload_tmp_dir。test 先校验已有上传目录，再跑现有测试，不写入该目录。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C
export LANGUAGE=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "${ROOT}"

die() {
  printf 'build.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  ./build.sh [release] [--catalog <file>] [--go-version <goX.Y.Z>] [--downloads-json <文件>] [--archive-dir <目录>]
  ./build.sh --output <tmp子目录或build/upload_tmp_dir> [--catalog <file>] [--go-version <goX.Y.Z>] [--downloads-json <文件>] [--archive-dir <目录>]
  ./build.sh test
release 按 catalog 构造，默认写入 build/upload_tmp_dir。已有非空目录拒绝清理。test 校验已有上传目录后跑现有测试，不删除该目录。
EOF
  exit 2
}

mode="release"
output=""
catalog=""
go_version=""
downloads_json=""
archive_dir=""

if [[ $# -gt 0 && "$1" != -* ]]; then
  mode="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) [[ $# -ge 2 ]] || usage; output="$2"; shift 2 ;;
    --catalog) [[ $# -ge 2 ]] || usage; catalog="$2"; shift 2 ;;
    --go-version) [[ $# -ge 2 ]] || usage; go_version="$2"; shift 2 ;;
    --downloads-json) [[ $# -ge 2 ]] || usage; downloads_json="$2"; shift 2 ;;
    --archive-dir) [[ $# -ge 2 ]] || usage; archive_dir="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ "${mode}" == "release" || "${mode}" == "test" ]] || usage
[[ -x "${ROOT}/gen_debs.sh" ]] || die "缺少 gen_debs.sh"

if [[ "${mode}" == "test" ]]; then
  [[ -z "${output}" && -z "${catalog}" && -z "${go_version}" && -z "${downloads_json}" && -z "${archive_dir}" ]] \
    || die "test 不接受输出或构包参数"
  dir="build/upload_tmp_dir"
  if [[ -e "${dir}" ]]; then
    [[ ! -L "${dir}" && -f "${dir}/SHA256SUMS" ]] || die "上传目录不可校验"
    [[ ! -e "${dir}/provenance.json" ]] || die "上传目录仍含未按条目命名的 provenance.json"
    ( cd -- "${dir}" && sha256sum -c -- SHA256SUMS >/dev/null ) || die "SHA256SUMS 校验失败"
    printf 'build.sh: 已校验 %s\n' "${dir}"
  fi
  if ! command -v shellcheck >/dev/null 2>&1 \
    && [[ -x "${ROOT}/tmp/go-final-parent/bin/shellcheck" ]]; then
    PATH="${ROOT}/tmp/go-final-parent/bin:${PATH}"
    export PATH
  fi
  if bash tests/ubuntu_test.sh \
    && bash tests/sync_test.sh \
    && bash tests/render_test.sh \
    && bash tests/workflow_test.sh \
    && bash tests/add_source_test.sh \
    && bash tests/update_sources_test.sh \
    && bash tests/go_source_test.sh \
    && bash tests/release_test.sh \
    && bash tests/go_deb_test.sh; then
    exit 0
  fi
  exit 1
fi

args=(release)
if [[ -n "${catalog}" ]]; then
  args+=(--catalog "${catalog}")
fi
if [[ -n "${output}" ]]; then
  args+=(--output "${output}")
else
  mkdir -p -- build
  [[ ! -L build && ! -L build/upload_tmp_dir ]] || die "build 路径不能是符号链接"
  args+=(--output build/upload_tmp_dir)
fi
if [[ -n "${go_version}" ]]; then
  args+=(--go-version "${go_version}")
fi
if [[ -n "${downloads_json}" ]]; then
  args+=(--downloads-json "${downloads_json}")
fi
if [[ -n "${archive_dir}" ]]; then
  args+=(--archive-dir "${archive_dir}")
fi
"${ROOT}/gen_debs.sh" "${args[@]}"
printf 'build.sh: release output=%s\n' "${output:-build/upload_tmp_dir}"
