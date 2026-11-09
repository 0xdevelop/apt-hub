#!/usr/bin/env bash
# 从 Go 官方 Linux 归档构造独立 apt-hub-go .deb（不抢 Ubuntu golang 入口）。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C
export LANGUAGE=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"
PROJECT_TMP="${PROJECT_ROOT}/tmp"

HEX64='^[a-f0-9]{64}$'
DEC_POS='^[1-9][0-9]*$'
GO_TAG='^go[0-9]+\.[0-9]+\.[0-9]+$'
DEB_REV='^[1-9][0-9]*$'
ALLOWED_ARCH='^(amd64|arm64)$'
PKG_NAME='^[a-z0-9][a-z0-9.+-]+$'

config=""
output=""
downloads_json=""
archive_dir=""
version_lock=""
work=""
scratch=""
staging=""
work_owned=0
scratch_owned=0
staging_owned=0
success=0

die() {
  printf 'gen_deb_golang.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法: ./gen_deb_golang.sh --config <config/go.json> --output <全新/空的本项目tmp内目录> [--version <goX.Y.Z>] [--downloads-json <官方JSON普通文件>] [--archive-dir <已下载归档目录>]
EOF
  exit 2
}

cleanup() {
  if [[ "${success}" -eq 1 ]]; then
    return
  fi
  # 只清自己的 work/scratch/staging；不碰用户原有空 output。
  if [[ "${staging_owned}" -eq 1 && -n "${staging}" && -d "${staging}" && ! -L "${staging}" ]]; then
    rm -rf -- "${staging}"
  fi
  if [[ "${work_owned}" -eq 1 && -n "${work}" && -d "${work}" && ! -L "${work}" ]]; then
    rm -rf -- "${work}"
  fi
  if [[ "${scratch_owned}" -eq 1 && -n "${scratch}" && -d "${scratch}" && ! -L "${scratch}" ]]; then
    rm -rf -- "${scratch}"
  fi
}
trap cleanup EXIT

require_cmd() {
  local c
  for c in "$@"; do
    command -v -- "${c}" >/dev/null 2>&1 || die "缺少命令: ${c}"
  done
}

is_abs() {
  [[ "$1" == /* ]]
}

make_abs_unresolved() {
  local p="$1"
  [[ -n "${p}" ]] || die "空路径"
  if [[ "${p}" != /* ]]; then
    p="${PWD%/}/${p}"
  fi
  if [[ "${p}" != / ]]; then
    p="${p%/}"
  fi
  printf '%s\n' "${p}"
}

assert_no_symlink_components() {
  local path="$1"
  local prefix="" part
  [[ "${path}" == /* ]] || die "路径必须是绝对路径: ${path}"
  prefix="/"
  IFS=/ read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [[ -n "${part}" ]] || continue
    prefix="${prefix%/}/${part}"
    if [[ -L "${prefix}" ]]; then
      die "路径含符号链接: ${prefix}"
    fi
  done
}

is_system_path() {
  case "$1" in
    /|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/boot|/boot/*|/sys|/sys/*|/proc|/proc/*|/dev|/dev/*|/root|/root/*|/var|/var/*|/run|/run/*|/tmp|/tmp/*)
      return 0
      ;;
  esac
  return 1
}

under_dir() {
  local parent="$1" child="$2"
  [[ "${child}" == "${parent}" || "${child}" == "${parent}/"* ]]
}

dir_is_empty() {
  local d="$1" listing="" rc=0
  [[ -d "${d}" ]] || return 0
  # 显式捕获 find 成功与输出；读取失败不得当空。
  listing="$(find -- "${d}" -mindepth 1 -maxdepth 1 -print -quit)" || rc=$?
  [[ "${rc}" -eq 0 ]] || return "${rc}"
  [[ -z "${listing}" ]]
}

hex_sha256() {
  sha256sum -- "$1" | awk '{print $1}'
}

file_size() {
  stat -c '%s' -- "$1"
}

assert_allowed_tmp_dir() {
  local role="$1" abs="$2" must_exist="$3"
  local parent base parent_abs

  [[ -n "${abs}" ]] || die "缺少 ${role} 路径"
  abs="$(make_abs_unresolved "${abs}")"
  if [[ "${must_exist}" == "yes" ]]; then
    [[ -e "${abs}" ]] || die "${role} 不存在: ${abs}"
    [[ -d "${abs}" ]] || die "${role} 不是目录: ${abs}"
    [[ ! -L "${abs}" ]] || die "${role} 不能是符号链接: ${abs}"
    assert_no_symlink_components "${abs}"
    abs="$(realpath -e -- "${abs}")"
  else
    parent="$(dirname -- "${abs}")"
    base="$(basename -- "${abs}")"
    [[ "${base}" != "." && "${base}" != ".." && "${base}" != "/" ]] || die "${role} 非法目录名"
    [[ -e "${parent}" ]] || die "${role} 父目录不存在: ${parent}"
    [[ -d "${parent}" ]] || die "${role} 父目录不是目录: ${parent}"
    [[ ! -L "${parent}" ]] || die "${role} 父目录不能是符号链接: ${parent}"
    assert_no_symlink_components "${parent}"
    if [[ -e "${abs}" || -L "${abs}" ]]; then
      [[ ! -L "${abs}" ]] || die "${role} 不能是符号链接: ${abs}"
      [[ -d "${abs}" ]] || die "${role} 已存在且不是目录: ${abs}"
      assert_no_symlink_components "${abs}"
    fi
    parent_abs="$(realpath -e -- "${parent}")"
    abs="${parent_abs}/${base}"
    if [[ -e "${abs}" || -L "${abs}" ]]; then
      [[ ! -L "${abs}" ]] || die "${role} 不能是符号链接: ${abs}"
      [[ -d "${abs}" ]] || die "${role} 已存在且不是目录: ${abs}"
    fi
  fi

  under_dir "${PROJECT_TMP}" "${abs}" || die "${role} 必须位于项目 tmp/ 下: ${abs}"
  [[ "${abs}" != "${PROJECT_ROOT}" && "${abs}" != "${PROJECT_TMP}" ]] || die "${role} 不能是项目根或 tmp 根"
  is_system_path "${abs}" && die "${role} 拒绝系统路径: ${abs}"
  printf '%s\n' "${abs}"
}

assert_allowed_file() {
  local role="$1" path="$2"
  local abs
  abs="$(make_abs_unresolved "${path}")"
  [[ -e "${abs}" ]] || die "${role} 不存在: ${abs}"
  [[ -f "${abs}" ]] || die "${role} 不是普通文件: ${abs}"
  [[ ! -L "${abs}" ]] || die "${role} 不能是符号链接: ${abs}"
  assert_no_symlink_components "${abs}"
  abs="$(realpath -e -- "${abs}")"
  printf '%s\n' "${abs}"
}

assert_no_overlap() {
  local a="$1" b="$2" msg="$3"
  if under_dir "${a}" "${b}" || under_dir "${b}" "${a}"; then
    die "${msg}"
  fi
}

official_download_url() {
  local filename="$1"
  printf 'https://go.dev/dl/%s\n' "${filename}"
}

arch_from_filename() {
  local filename="$1"
  case "${filename}" in
    *.linux-amd64.tar.gz) printf 'amd64\n' ;;
    *.linux-arm64.tar.gz) printf 'arm64\n' ;;
    *) die "无法从文件名映射架构: ${filename}" ;;
  esac
}

elf_machine_expected() {
  case "$1" in
    amd64) printf 'Advanced Micro Devices X86-64\n' ;;
    arm64) printf 'AArch64\n' ;;
    *) die "未知架构: $1" ;;
  esac
}

tool_triple() {
  case "$1" in
    amd64) printf 'linux_amd64\n' ;;
    arm64) printf 'linux_arm64\n' ;;
    *) die "未知架构: $1" ;;
  esac
}

assert_safe_member_name() {
  local name="$1" part
  [[ -n "${name}" ]] || die "归档含空成员名"
  case "${name}" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "归档成员名含控制空白: ${name}" ;;
  esac
  [[ "${name}" != /* ]] || die "归档含绝对路径: ${name}"
  [[ "${name}" != *\\* ]] || die "归档成员名含反斜线: ${name}"
  [[ "${name}" != *//* ]] || die "归档成员名含空路径段: ${name}"
  [[ "${name}" == go || "${name}" == go/* ]] || die "归档成员不在顶层 go/ 下: ${name}"
  IFS=/ read -r -a parts <<< "${name}"
  for part in "${parts[@]}"; do
    [[ -n "${part}" ]] || die "归档成员名含空路径段: ${name}"
    [[ "${part}" != "." && "${part}" != ".." ]] || die "归档成员名含 . 或 .. 段: ${name}"
  done
}

inspect_official_archive() {
  local archive="$1"
  local list="${scratch}/tar-list.txt"
  local seen="${scratch}/tar-seen.txt"
  local line mode name
  : >"${seen}"
  # 完整成员列表：先校验名字，再校验类型；不解包。
  # literal：避免把 UTF-8 显示成 \ooo 而误判反斜线
  tar --quoting-style=literal -tzf "${archive}" >"${list}" || die "无法列出归档: ${archive}"
  [[ -s "${list}" ]] || die "归档为空: ${archive}"
  while IFS= read -r name; do
    assert_safe_member_name "${name}"
    if grep -Fxq -- "${name}" "${seen}"; then
      die "归档含重复路径: ${name}"
    fi
    printf '%s\n' "${name}" >>"${seen}"
  done <"${list}"
  grep -Fxq -- 'go' "${seen}" || grep -Fxq -- 'go/' "${seen}" || die "归档缺少顶层 go"
  grep -Fxq -- 'go/VERSION' "${seen}" || die "归档缺少 go/VERSION"
  grep -Fxq -- 'go/bin/go' "${seen}" || die "归档缺少 go/bin/go"
  grep -Fxq -- 'go/bin/gofmt' "${seen}" || die "归档缺少 go/bin/gofmt"

  while IFS= read -r line; do
    # GNU tar -tv：首字符为类型；symlink 含 " -> "；hardlink 含 " link to "
    mode="${line%% *}"
    [[ -n "${mode}" ]] || continue
    case "${mode:0:1}" in
      -|d) ;;
      l) die "归档含符号链接（本批拒绝）: ${line}" ;;
      h) die "归档含硬链接（本批拒绝）: ${line}" ;;
      p) die "归档含 FIFO: ${line}" ;;
      c|b) die "归档含设备节点: ${line}" ;;
      *) die "归档含未知成员类型: ${line}" ;;
    esac
    case "${mode}" in
      *s*|*S*|*t*|*T*) die "归档含危险权限位: ${line}" ;;
    esac
    if [[ "${line}" == *" -> "* ]]; then
      die "归档含链接目标字段: ${line}"
    fi
    if [[ "${line}" == *" link to "* ]]; then
      die "归档含硬链接字段: ${line}"
    fi
  done < <(tar --quoting-style=literal -tvzf "${archive}")
}

download_official_archive() {
  local url="$1" dest="$2" expect_size="$3"
  local max_bytes
  max_bytes=$((expect_size + 1048576))
  [[ "${max_bytes}" -gt "${expect_size}" ]] || die "下载上限计算溢出"
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 600 \
    --max-filesize "${max_bytes}" \
    -o "${dest}" -- "${url}" \
    || die "下载失败: ${url}"
}

verify_archive_bytes() {
  local path="$1" expect_sha="$2" expect_size="$3"
  local got_sha got_size
  got_size="$(file_size "${path}")"
  [[ "${got_size}" == "${expect_size}" ]] || die "归档大小不匹配: got=${got_size} expect=${expect_size}"
  got_sha="$(hex_sha256 "${path}")"
  [[ "${got_sha}" == "${expect_sha}" ]] || die "归档 sha256 不匹配"
}

assert_elf_arch() {
  local bin="$1" arch="$2"
  local expect got re_out re_rc=0
  [[ -f "${bin}" && ! -L "${bin}" ]] || die "缺少 ELF 文件: ${bin}"
  expect="$(elf_machine_expected "${arch}")" || die "无法映射 ELF 期望机型: ${arch}"
  # 以 Machine 字段为准；截断测试 ELF 可能令 readelf 非 0 但仍可读出机型。
  re_out="$(readelf -h -- "${bin}" 2>&1)" || re_rc=$?
  got="$(printf '%s\n' "${re_out}" | awk -F: '/^[[:space:]]*Machine:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')" \
    || die "解析 readelf Machine 失败: ${bin}"
  [[ -n "${got}" ]] || die "readelf 未读到 Machine: ${bin} (rc=${re_rc})"
  [[ "${got}" == "${expect}" ]] || die "ELF 架构不匹配 ${bin}: got=${got} expect=${expect}"
}

clamp_tree_mtime() {
  local root="$1" epoch="$2" p
  local list="${scratch}/clamp-mtime.list"
  find -- "${root}" -print0 >"${list}" || die "无法枚举树以固定时间戳: ${root}"
  while IFS= read -r -d '' p; do
    touch -h -d "@${epoch}" -- "${p}" || die "无法固定时间戳: ${p}"
  done <"${list}"
}

select_stable_version() {
  local index="$1"
  local best_tag="" best_ver="" tag ver
  while IFS= read -r tag; do
    [[ "${tag}" =~ ${GO_TAG} ]] || die "拒绝非稳定 go 版本标签: ${tag}"
    ver="${tag#go}"
    if [[ -z "${best_ver}" ]] || dpkg --compare-versions "${ver}" gt "${best_ver}"; then
      best_ver="${ver}"
      best_tag="${tag}"
    fi
  done < <(jq -r '.[] | select(.stable==true) | .version' "${index}")
  [[ -n "${best_tag}" ]] || die "官方索引无 stable 版本"
  printf '%s\n' "${best_tag}"
}

resolve_version_tag() {
  local index="$1" want="$2"
  local count
  [[ "${want}" =~ ${GO_TAG} ]] || die "非法 --version: ${want}"
  count="$(jq -r --arg v "${want}" '[.[] | select(.version==$v)] | length' "${index}")" \
    || die "查询索引版本失败"
  [[ "${count}" == "1" ]] || die "索引中版本不唯一或不存在: ${want} count=${count}"
  printf '%s\n' "${want}"
}

artifact_for_arch() {
  local index="$1" tag="$2" arch="$3"
  local count filename sha size kind os a
  count="$(jq -r --arg v "${tag}" --arg a "${arch}" '
    [.[] | select(.version==$v) | .files[]?
      | select(.os=="linux" and .arch==$a and .kind=="archive")]
    | length' "${index}")"
  [[ "${count}" == "1" ]] || die "版本 ${tag} 架构 ${arch} 归档不唯一: count=${count}"
  filename="$(jq -r --arg v "${tag}" --arg a "${arch}" '
    .[] | select(.version==$v) | .files[]?
      | select(.os=="linux" and .arch==$a and .kind=="archive")
      | .filename' "${index}")"
  sha="$(jq -r --arg v "${tag}" --arg a "${arch}" '
    .[] | select(.version==$v) | .files[]?
      | select(.os=="linux" and .arch==$a and .kind=="archive")
      | .sha256' "${index}")"
  size="$(jq -r --arg v "${tag}" --arg a "${arch}" '
    .[] | select(.version==$v) | .files[]?
      | select(.os=="linux" and .arch==$a and .kind=="archive")
      | (.size|tostring)' "${index}")"
  kind="$(jq -r --arg v "${tag}" --arg a "${arch}" '
    .[] | select(.version==$v) | .files[]?
      | select(.os=="linux" and .arch==$a and .kind=="archive")
      | .kind' "${index}")"
  os="$(jq -r --arg v "${tag}" --arg a "${arch}" '
    .[] | select(.version==$v) | .files[]?
      | select(.os=="linux" and .arch==$a and .kind=="archive")
      | .os' "${index}")"
  a="$(jq -r --arg v "${tag}" --arg a "${arch}" '
    .[] | select(.version==$v) | .files[]?
      | select(.os=="linux" and .arch==$a and .kind=="archive")
      | .arch' "${index}")"
  [[ "${kind}" == "archive" && "${os}" == "linux" && "${a}" == "${arch}" ]] || die "归档元数据非法"
  [[ "${filename}" == "${tag}.linux-${arch}.tar.gz" ]] || die "归档文件名与版本/架构不一致: ${filename}"
  [[ "${sha}" =~ ${HEX64} ]] || die "归档 sha256 非法"
  [[ "${size}" =~ ${DEC_POS} ]] || die "归档 size 非法"
  [[ "$(arch_from_filename "${filename}")" == "${arch}" ]] || die "文件名架构映射失败"
  printf '%s\t%s\t%s\n' "${filename}" "${sha}" "${size}"
}

build_one_deb() {
  local arch="$1" tag="$2" revision="$3" archive="$4" url="$5" sha="$6" size="$7"
  local upstream_ver pkg_ver extract debroot go_tree triple
  local epoch deb_name deb_path installed_size deb_sha deb_sz ver_line special
  local pkg_desc pkg_maintainer pkg_homepage pkg_section pkg_priority pkg_name

  upstream_ver="${tag#go}"
  pkg_ver="${upstream_ver}-${revision}"
  pkg_name="$(jq -r '.package' "${config}")" || die "读取 package 失败"
  pkg_desc="$(jq -r '.description' "${config}")" || die "读取 description 失败"
  pkg_maintainer="$(jq -r '.maintainer' "${config}")" || die "读取 maintainer 失败"
  pkg_homepage="$(jq -r '.homepage' "${config}")" || die "读取 homepage 失败"
  pkg_section="$(jq -r '.section' "${config}")" || die "读取 section 失败"
  pkg_priority="$(jq -r '.priority' "${config}")" || die "读取 priority 失败"
  triple="$(tool_triple "${arch}")" || die "无法映射 tool triple: ${arch}"

  extract="${work}/extract-${arch}"
  debroot="${work}/debroot-${arch}"
  rm -rf -- "${extract}" "${debroot}" || die "无法清理构包临时目录: ${arch}"
  mkdir -m 755 -- "${extract}" "${debroot}" || die "无法创建构包临时目录: ${arch}"

  inspect_official_archive "${archive}"
  tar -xzf "${archive}" -C "${extract}" \
    --no-same-owner --no-same-permissions \
    || die "解包失败: ${archive}"

  go_tree="${extract}/go"
  [[ -d "${go_tree}" && ! -L "${go_tree}" ]] || die "解包后缺少 go 目录"
  special="$(find -- "${go_tree}" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit)" \
    || die "无法枚举解包树: ${arch}"
  [[ -z "${special}" ]] || die "解包树含链接或特殊文件"
  [[ -f "${go_tree}/VERSION" ]] || die "缺少 VERSION"
  # 官方 VERSION 首行为 goX.Y.Z，其后可有 time 行
  ver_line="$(head -n1 -- "${go_tree}/VERSION" | tr -d '\r')" || die "无法读取 VERSION"
  [[ "${ver_line}" == "${tag}" ]] || die "VERSION 与所选版本不一致"
  [[ -f "${go_tree}/bin/go" && -f "${go_tree}/bin/gofmt" ]] || die "缺少 bin/go 或 bin/gofmt"
  [[ -d "${go_tree}/pkg/tool/${triple}" ]] || die "缺少 pkg/tool/${triple}"
  assert_elf_arch "${go_tree}/bin/go" "${arch}"
  assert_elf_arch "${go_tree}/bin/gofmt" "${arch}"

  mkdir -p -- "${debroot}/usr/lib/apt-hub" "${debroot}/usr/bin" \
    "${debroot}/usr/share/doc/${pkg_name}" "${debroot}/DEBIAN" \
    || die "无法创建 deb 目录树: ${arch}"
  cp -a -- "${go_tree}" "${debroot}/usr/lib/apt-hub/go" || die "复制 go 树失败: ${arch}"
  ln -s -- "../lib/apt-hub/go/bin/go" "${debroot}/usr/bin/apt-hub-go" || die "创建 apt-hub-go 链接失败"
  ln -s -- "../lib/apt-hub/go/bin/gofmt" "${debroot}/usr/bin/apt-hub-gofmt" || die "创建 apt-hub-gofmt 链接失败"
  [[ -f "${go_tree}/LICENSE" && ! -L "${go_tree}/LICENSE" ]] \
    || die "归档缺少真实 LICENSE，拒绝伪造 copyright"
  cp -a -- "${go_tree}/LICENSE" "${debroot}/usr/share/doc/${pkg_name}/copyright" \
    || die "复制 LICENSE 失败"
  printf '%s\n' "apt-hub packaging of ${tag}" >"${debroot}/usr/share/doc/${pkg_name}/README.Debian" \
    || die "写入 README.Debian 失败"

  installed_size="$(du -sk -- "${debroot}" | awk '{print $1}')" || die "计算 Installed-Size 失败"
  cat >"${debroot}/DEBIAN/control" <<EOF || die "写入 control 失败"
Package: ${pkg_name}
Version: ${pkg_ver}
Architecture: ${arch}
Maintainer: ${pkg_maintainer}
Section: ${pkg_section}
Priority: ${pkg_priority}
Homepage: ${pkg_homepage}
Installed-Size: ${installed_size}
Description: ${pkg_desc}
EOF

  # SOURCE_DATE_EPOCH 只来自已认证归档内容：VERSION time，或解包后受校验成员 mtime。
  epoch=""
  if awk 'NR==2 && $1=="time" {print $2; exit}' "${go_tree}/VERSION" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
    epoch="$(date -u -d "$(awk 'NR==2 && $1=="time" {print $2; exit}' "${go_tree}/VERSION")" +%s)" \
      || die "无法解析 VERSION time"
  else
    epoch="$(stat -c '%Y' -- "${go_tree}/VERSION")" \
      || die "无法读取归档内 VERSION 成员时间"
  fi
  [[ "${epoch}" =~ ^[0-9]+$ ]] || die "无法确定 SOURCE_DATE_EPOCH"
  clamp_tree_mtime "${debroot}" "${epoch}"

  deb_name="${pkg_name}_${pkg_ver}_${arch}.deb"
  deb_path="${work}/${deb_name}"
  env SOURCE_DATE_EPOCH="${epoch}" \
    dpkg-deb --build --root-owner-group -Zgzip -z9 -- "${debroot}" "${deb_path}" \
    >/dev/null || die "dpkg-deb 构建失败: ${arch}"
  [[ -f "${deb_path}" && ! -L "${deb_path}" ]] || die "deb 产物缺失: ${deb_path}"
  deb_sha="$(hex_sha256 "${deb_path}")" || die "计算 deb sha256 失败: ${arch}"
  deb_sz="$(file_size "${deb_path}")" || die "读取 deb 大小失败: ${arch}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${arch}" "${deb_name}" "${deb_sha}" "${deb_sz}" \
    "${pkg_ver}" "${url}" "${sha}" "${size}"
}

# ---- args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || usage
      config="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || usage
      output="$2"
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
    --version)
      [[ $# -ge 2 ]] || usage
      version_lock="$2"
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

[[ -n "${config}" && -n "${output}" ]] || usage
require_cmd bash jq curl tar dpkg-deb dpkg readelf sha256sum realpath find flock stat touch install awk sed grep tr sort du env

config="$(assert_allowed_file "config" "${config}")"
output="$(assert_allowed_tmp_dir "output" "${output}" "no")"

if [[ -n "${downloads_json}" ]]; then
  downloads_json="$(assert_allowed_file "downloads-json" "${downloads_json}")"
fi
if [[ -n "${archive_dir}" ]]; then
  archive_dir="$(assert_allowed_tmp_dir "archive-dir" "${archive_dir}" "yes")"
fi

assert_no_overlap "${config}" "${output}" "config 与 output 路径重叠"
if [[ -n "${downloads_json}" ]]; then
  assert_no_overlap "${downloads_json}" "${output}" "downloads-json 与 output 路径重叠"
fi
if [[ -n "${archive_dir}" ]]; then
  assert_no_overlap "${archive_dir}" "${output}" "archive-dir 与 output 路径重叠"
fi

jq -e '
  .schema_version=="1"
  and .source_type=="go_official_archive"
  and (.release_index_url|type=="string" and .=="https://go.dev/dl/?mode=json")
  and (.package|type=="string")
  and (.description|type=="string" and length>0)
  and (.maintainer|type=="string" and length>0)
  and (.homepage|type=="string" and startswith("https://"))
  and (.section|type=="string" and length>0)
  and (.priority|type=="string" and length>0)
  and (.revision|type=="string" and test("^[1-9][0-9]*$"))
  and (.architectures|type=="array" and length>0)
  and ([.architectures[]|select(test("^(amd64|arm64)$"))]|length)==(.architectures|length)
  and (.architectures|unique|length)==(.architectures|length)
' "${config}" >/dev/null || die "config/go.json 字段不合法"

pkg_name="$(jq -r '.package' "${config}")"
revision="$(jq -r '.revision' "${config}")"
index_url="$(jq -r '.release_index_url' "${config}")"
[[ "${pkg_name}" =~ ${PKG_NAME} ]] || die "package 名非法"
[[ "${revision}" =~ ${DEB_REV} ]] || die "revision 非法"

lockfile="${output}.lock"
lockdir="$(dirname -- "${lockfile}")"
[[ -d "${lockdir}" ]] || die "output 父目录不存在"
assert_no_symlink_components "${lockdir}"
if [[ -L "${lockfile}" ]]; then
  die "lock 不能是符号链接: ${lockfile}"
fi
if [[ -e "${lockfile}" ]]; then
  [[ -f "${lockfile}" ]] || die "lock 不是普通文件: ${lockfile}"
fi
# 固定 FD9 原生重定向；路径文本不得进入 eval。
exec 9>>"${lockfile}" || die "无法打开 lock: ${lockfile}"
[[ -f "${lockfile}" && ! -L "${lockfile}" ]] || die "lock 非法"
lock_id="$(stat -c '%d:%i' -- "${lockfile}")"
fd_id="$(stat -L -c '%d:%i' -- /proc/self/fd/9)"
[[ "${lock_id}" == "${fd_id}" ]] || die "lock 路径与 fd9 inode 不一致"
flock -n 9 || die "构包已在进行: ${lockfile}"

# 不预先创建/chmod/清空用户 output；已存在则必须可枚举且为空。
if [[ -e "${output}" || -L "${output}" ]]; then
  [[ -d "${output}" && ! -L "${output}" ]] || die "output 不是普通目录"
  dir_is_empty "${output}" || die "拒绝写入已有非空或不可枚举 output: ${output}"
fi

pending_work="${output}.work"
pending_scratch="${output}.scratch"
pending_staging="${output}.staging"
pending_hold="${output}.hold-empty"
if [[ -e "${pending_work}" || -L "${pending_work}" ]]; then
  die "存在未完成候选目录，拒绝覆盖: ${pending_work}"
fi
if [[ -e "${pending_scratch}" || -L "${pending_scratch}" ]]; then
  die "存在未清理临时目录，拒绝覆盖: ${pending_scratch}"
fi
if [[ -e "${pending_staging}" || -L "${pending_staging}" ]]; then
  die "存在未完成 staging，拒绝覆盖: ${pending_staging}"
fi
if [[ -e "${pending_hold}" || -L "${pending_hold}" ]]; then
  die "存在未清理 hold-empty，拒绝覆盖: ${pending_hold}"
fi
mkdir -m 755 -- "${pending_work}" || die "无法创建候选目录"
work="${pending_work}"
work_owned=1
mkdir -m 755 -- "${pending_scratch}" || die "无法创建临时目录"
scratch="${pending_scratch}"
scratch_owned=1
mkdir -m 755 -- "${pending_staging}" || die "无法创建 staging"
staging="${pending_staging}"
staging_owned=1

index_file="${scratch}/downloads.json"
if [[ -n "${downloads_json}" ]]; then
  cp -a -- "${downloads_json}" "${index_file}" || die "复制 downloads-json 失败"
else
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 120 \
    -o "${index_file}" -- "${index_url}" \
    || die "拉取官方索引失败"
fi
jq -e 'type=="array" and length>0' "${index_file}" >/dev/null || die "官方索引不是非空数组"

if [[ -n "${version_lock}" ]]; then
  tag="$(resolve_version_tag "${index_file}" "${version_lock}")" || die "锁定版本失败"
else
  tag="$(select_stable_version "${index_file}")" || die "选择稳定版本失败"
fi
upstream_ver="${tag#go}"
# 同步写 scratch 并核 jq 退出码；禁止进程替换吞掉部分输出后的非 0。
archs_file="${scratch}/architectures.txt"
jq -r '.architectures[]' "${config}" >"${archs_file}" \
  || die "读取 architectures 失败"
mapfile -t archs <"${archs_file}" \
  || die "解析 architectures 失败"
[[ "${#archs[@]}" -gt 0 ]] || die "architectures 为空"

prov_rows="${scratch}/prov-rows.jsonl"
: >"${prov_rows}" || die "无法初始化 provenance 行文件"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || die "无法生成 UTC 时间"

for arch in "${archs[@]}"; do
  [[ "${arch}" =~ ${ALLOWED_ARCH} ]] || die "非法架构: ${arch}"
  art_row="$(artifact_for_arch "${index_file}" "${tag}" "${arch}")" \
    || die "官方元数据架构 ${arch} 解析失败"
  IFS=$'\t' read -r filename sha size <<<"${art_row}" \
    || die "解析官方元数据行失败: ${arch}"
  [[ -n "${filename}" && -n "${sha}" && -n "${size}" ]] || die "官方元数据字段不完整: ${arch}"
  url="$(official_download_url "${filename}")" || die "构造下载 URL 失败"
  archive_path=""
  if [[ -n "${archive_dir}" ]]; then
    archive_path="${archive_dir}/${filename}"
    [[ -f "${archive_path}" && ! -L "${archive_path}" ]] || die "archive-dir 缺少普通文件: ${filename}"
  else
    archive_path="${scratch}/${filename}"
    download_official_archive "${url}" "${archive_path}" "${size}"
  fi
  verify_archive_bytes "${archive_path}" "${sha}" "${size}"
  # 不执行未认证内容：仅在哈希通过后做只读成员检查与受限解包。
  # 行结果写文件，避免命令替换 + || 抑制函数内 errexit。
  row_file="${scratch}/row-${arch}.txt"
  build_one_deb "${arch}" "${tag}" "${revision}" "${archive_path}" "${url}" "${sha}" "${size}" \
    >"${row_file}" || die "构包失败: ${arch}"
  row="$(cat -- "${row_file}")" || die "读取构包结果失败: ${arch}"
  IFS=$'\t' read -r out_arch deb_name deb_sha deb_size pkg_ver up_url up_sha up_size <<<"${row}" \
    || die "解析构包结果失败: ${arch}"
  [[ -n "${deb_name}" && -f "${work}/${deb_name}" && ! -L "${work}/${deb_name}" ]] \
    || die "构包产物缺失: ${arch}"
  # 提交前验 package/version/arch 与 go 树。
  [[ "$(dpkg-deb -f -- "${work}/${deb_name}" Package)" == "${pkg_name}" ]] \
    || die "deb Package 与 manifest 不一致: ${arch}"
  [[ "$(dpkg-deb -f -- "${work}/${deb_name}" Version)" == "${pkg_ver}" ]] \
    || die "deb Version 与 manifest 不一致: ${arch}"
  [[ "$(dpkg-deb -f -- "${work}/${deb_name}" Architecture)" == "${arch}" ]] \
    || die "deb Architecture 与 manifest 不一致: ${arch}"
  # 先完整列出再 grep，避免 grep -q 提前关闭管道令 dpkg-deb SIGPIPE。
  deb_list="${scratch}/deb-list-${arch}.txt"
  dpkg-deb -c -- "${work}/${deb_name}" >"${deb_list}" || die "无法列出 deb 内容: ${arch}"
  grep -q 'usr/lib/apt-hub/go/bin/go' "${deb_list}" || die "deb 缺少 go 树: ${arch}"
  install -m 644 -- "${work}/${deb_name}" "${staging}/${deb_name}" \
    || die "写入 staging deb 失败: ${arch}"
  jq -nc \
    --arg arch "${out_arch}" \
    --arg filename "${deb_name}" \
    --arg sha256 "${deb_sha}" \
    --arg size "${deb_size}" \
    --arg version "${pkg_ver}" \
    --arg package "${pkg_name}" \
    --arg upstream_url "${up_url}" \
    --arg upstream_sha256 "${up_sha}" \
    --arg upstream_size "${up_size}" \
    '{
      package:$package,
      version:$version,
      architecture:$arch,
      filename:$filename,
      sha256:$sha256,
      size:$size,
      upstream:{url:$upstream_url, sha256:$upstream_sha256, size:$upstream_size}
    }' >>"${prov_rows}" || die "写入 provenance 行失败: ${arch}"
done

jq -nc \
  --arg schema_version "1" \
  --arg generated_at_utc "${generated_at}" \
  --arg upstream_version "${tag}" \
  --arg upstream_version_debian "${upstream_ver}" \
  --arg revision "${revision}" \
  --argjson packages "$(jq -s '.' "${prov_rows}")" \
  '{
    schema_version:$schema_version,
    generated_at_utc:$generated_at_utc,
    upstream:{
      version:$upstream_version,
      version_debian:$upstream_version_debian,
      revision:$revision
    },
    packages:$packages
  }' >"${staging}/provenance.json" || die "写入 staging provenance 失败"

[[ -f "${staging}/provenance.json" && ! -L "${staging}/provenance.json" ]] \
  || die "staging 缺少 provenance.json"
archs_json="$(printf '%s\n' "${archs[@]}" | jq -R . | jq -s -c .)" \
  || die "无法序列化 arch 清单"
jq -e --argjson archs "${archs_json}" '
  .schema_version=="1"
  and (.packages|type=="array" and length==($archs|length))
  and (([.packages[].architecture]|sort) == ($archs|sort))
' "${staging}/provenance.json" >/dev/null || die "staging provenance 与 arch 清单不一致"
for arch in "${archs[@]}"; do
  deb_name="$(jq -r --arg a "${arch}" \
    '.packages[]|select(.architecture==$a)|.filename' "${staging}/provenance.json")" \
    || die "provenance 缺 arch 文件名: ${arch}"
  [[ -f "${staging}/${deb_name}" && ! -L "${staging}/${deb_name}" ]] \
    || die "staging 缺 deb: ${deb_name}"
done

sums_tmp="${scratch}/SHA256SUMS.tmp"
: >"${sums_tmp}" || die "无法初始化 SHA256SUMS"
(
  cd -- "${staging}" || exit 1
  sha256sum -- provenance.json || exit 1
  for arch in "${archs[@]}"; do
    deb_name="$(jq -r --arg a "${arch}" \
      '.packages[]|select(.architecture==$a)|.filename' provenance.json)" \
      || exit 1
    sha256sum -- "${deb_name}" || exit 1
  done
) | LC_ALL=C sort -k2 >"${sums_tmp}" || die "计算 SHA256SUMS 失败"
install -m 644 -- "${sums_tmp}" "${staging}/SHA256SUMS" || die "写入 SHA256SUMS 失败"
[[ -s "${staging}/SHA256SUMS" ]] || die "staging 缺少 SHA256SUMS"

# 提交前再核空目录与锁（fd9 仍持有）。
if [[ -e "${output}" || -L "${output}" ]]; then
  [[ -d "${output}" && ! -L "${output}" ]] || die "提交前 output 不是普通目录"
  dir_is_empty "${output}" || die "提交前 output 变为非空或不可枚举"
fi
[[ -f "${lockfile}" && ! -L "${lockfile}" ]] || die "提交前 lock 非法"
lock_id_now="$(stat -c '%d:%i' -- "${lockfile}")" || die "提交前无法读取 lock"
fd_id_now="$(stat -L -c '%d:%i' -- /proc/self/fd/9)" || die "提交前无法读取 fd9"
[[ "${lock_id_now}" == "${fd_id_now}" ]] || die "提交前 lock 与 fd9 inode 不一致"

# 同 filesystem：staging 一次 rename 提交；失败恢复用户空目录，不删其目录。
if [[ ! -e "${output}" && ! -L "${output}" ]]; then
  mv -- "${staging}" "${output}" || die "原子提交失败"
  staging_owned=0
  staging=""
else
  mv -- "${output}" "${pending_hold}" || die "无法暂存空 output"
  if ! mv -- "${staging}" "${output}"; then
    mv -- "${pending_hold}" "${output}" || die "原子提交失败且无法恢复空 output"
    die "原子提交失败，已恢复空 output"
  fi
  staging_owned=0
  staging=""
  rmdir -- "${pending_hold}" || die "无法移除空 hold 目录"
fi

[[ -f "${output}/provenance.json" && ! -L "${output}/provenance.json" ]] \
  || die "output 缺少 provenance.json"
[[ -f "${output}/SHA256SUMS" && ! -L "${output}/SHA256SUMS" ]] \
  || die "output 缺少 SHA256SUMS"
dir_is_empty "${output}" && die "output 提交后为空"

rm -rf -- "${work}" "${scratch}"
work_owned=0
scratch_owned=0
success=1
printf 'gen_deb_golang.sh: ok packages=%s version=%s-%s\n' "${#archs[@]}" "${upstream_ver}" "${revision}"
