#!/usr/bin/env bash
# 维护侧单入口：发现发行版 → sync → 复制加源脚本 → verify → render → success.json。
# 输入显式传参；不读 env 兜底连接参数；不改 previous / 主 README / published.json；无 --push/--publish。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT_TMP="${PROJECT_ROOT}/tmp"

catalog=""
previous=""
work_arg=""
gnupghome=""
fingerprint=""
site_url=""
releases_arg=""
package_repository=""
go_release_tag=""
go_downloads_json=""
rotate_from=""
work=""
lock_fd=""

die() {
  printf 'update_sources.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法: scripts/update_sources.sh --catalog <file> --previous <dir> --work-dir <全新/空目录> --gnupghome <dir> --fingerprint <完整指纹> --site-url <https> [--releases <已生成的官方发行版JSON>] [--package-repository <owner/repo>] [--go-release-tag <apt-hub-go-X.Y.Z-R>] [--go-downloads-json <file>] [--rotate-from <旧完整指纹>]
EOF
  exit 2
}

# shellcheck disable=SC2317 # EXIT trap 间接调用
release_lock() {
  if [[ -n "${lock_fd}" ]]; then
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
    lock_fd=""
  fi
}

# shellcheck disable=SC2317 # EXIT trap 调用
cleanup() {
  release_lock
}
trap cleanup EXIT

require_cmd() {
  local c
  for c in "$@"; do
    command -v -- "${c}" >/dev/null 2>&1 || die "缺少命令: ${c}"
  done
}

strip_fp() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
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

assert_no_overlap() {
  local a="$1" b="$2" msg="$3"
  if under_dir "${a}" "${b}" || under_dir "${b}" "${a}"; then
    die "${msg}"
  fi
}

dir_is_empty() {
  local d="$1" listing="" rc=0
  [[ -d "${d}" ]] || return 0
  # 显式捕获 find 成功与输出；读取失败不得当空。
  listing="$(find -- "${d}" -mindepth 1 -maxdepth 1 -print -quit)" || rc=$?
  [[ "${rc}" -eq 0 ]] || return "${rc}"
  [[ -z "${listing}" ]]
}

assert_allowed_dir() {
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
    if [[ -L "${abs}" ]]; then
      die "${role} 不能是符号链接: ${abs}"
    fi
    if [[ -e "${abs}" ]]; then
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

  if under_dir "${PROJECT_ROOT}" "${abs}"; then
    under_dir "${PROJECT_TMP}" "${abs}" || die "${role} 在项目内时必须位于 tmp/ 下: ${abs}"
    [[ "${abs}" != "${PROJECT_ROOT}" && "${abs}" != "${PROJECT_TMP}" ]] || die "${role} 不能是项目根或 tmp 根: ${abs}"
  else
    is_system_path "${abs}" && die "${role} 拒绝系统路径: ${abs}"
    [[ "${abs}" != "${PROJECT_ROOT}" ]] || die "${role} 不能是项目根"
  fi
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

SITE_URL_RE='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$'

assert_site_url() {
  local u="$1"
  [[ "${u}" =~ ${SITE_URL_RE} ]] || die "site-url 非法: ${u}"
  case "${u}" in
    *localhost*|*127.0.0.1*|*\[::1\]*)
      die "site-url 拒绝 localhost"
      ;;
  esac
  printf '%s\n' "${u}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog)
      [[ $# -ge 2 ]] || usage
      catalog="$2"; shift 2 ;;
    --previous)
      [[ $# -ge 2 ]] || usage
      previous="$2"; shift 2 ;;
    --work-dir)
      [[ $# -ge 2 ]] || usage
      work_arg="$2"; shift 2 ;;
    --gnupghome)
      [[ $# -ge 2 ]] || usage
      gnupghome="$2"; shift 2 ;;
    --fingerprint)
      [[ $# -ge 2 ]] || usage
      fingerprint="$2"; shift 2 ;;
    --site-url)
      [[ $# -ge 2 ]] || usage
      site_url="$2"; shift 2 ;;
    --releases)
      [[ $# -ge 2 ]] || usage
      releases_arg="$2"; shift 2 ;;
    --package-repository)
      [[ $# -ge 2 ]] || usage
      package_repository="$2"; shift 2 ;;
    --go-release-tag)
      [[ $# -ge 2 ]] || usage
      go_release_tag="$2"; shift 2 ;;
    --go-downloads-json)
      [[ $# -ge 2 ]] || usage
      go_downloads_json="$2"; shift 2 ;;
    --rotate-from)
      [[ $# -ge 2 ]] || usage
      rotate_from="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      die "未知参数: $1" ;;
  esac
done

[[ -n "${catalog}" && -n "${previous}" && -n "${work_arg}" && -n "${gnupghome}" && -n "${fingerprint}" && -n "${site_url}" ]] || usage

require_cmd bash jq flock cp chmod mkdir mv rm find realpath stat date cmp sha256sum curl

[[ -d "${PROJECT_TMP}" ]] || die "缺少项目 tmp/ 目录"

catalog="$(assert_allowed_file catalog "${catalog}")"
previous="$(assert_allowed_dir previous "${previous}" yes)"
gnupghome="$(assert_allowed_dir gnupghome "${gnupghome}" yes)"
work="$(assert_allowed_dir work-dir "${work_arg}" no)"
fingerprint="$(strip_fp "${fingerprint}")"
[[ "${fingerprint}" =~ ^[A-F0-9]{40}$ ]] || die "fingerprint 必须是 40 位十六进制完整指纹"
site_url="$(assert_site_url "${site_url}")"
if [[ -n "${rotate_from}" ]]; then
  rotate_from="$(strip_fp "${rotate_from}")"
  [[ "${rotate_from}" =~ ^[A-F0-9]{40}$ ]] || die "rotate-from 必须是 40 位十六进制完整指纹"
fi
if [[ -n "${go_downloads_json}" ]]; then
  go_downloads_json="$(assert_allowed_file go-downloads-json "${go_downloads_json}")"
fi

releases=""
if [[ -n "${releases_arg}" ]]; then
  releases="$(assert_allowed_file releases "${releases_arg}")"
fi

# catalog 含 Go 且未显式给 tag：可从官方索引 + config/go.json revision 派生，但不假造已上传。
if jq -e '.packages|any((.source_type // "") == "go_official_archive")' "${catalog}" >/dev/null; then
  [[ -n "${package_repository}" ]] || die "catalog 含 go_official_archive 时必须传 --package-repository"
  if [[ -z "${go_release_tag}" ]]; then
    go_cfg="${PROJECT_ROOT}/config/go.json"
    [[ -f "${go_cfg}" && ! -L "${go_cfg}" ]] || die "缺少 config/go.json 无法派生 go-release-tag"
    rev="$(jq -r '.revision|tostring' "${go_cfg}")"
    [[ "${rev}" =~ ^[1-9][0-9]*$ ]] || die "config/go.json revision 非法"
    dl_tmp="${PROJECT_TMP}/update-go-dl-$$.json"
    if [[ -n "${go_downloads_json}" ]]; then
      cp -- "${go_downloads_json}" "${dl_tmp}"
    else
      curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 20 --max-time 60 \
        -o "${dl_tmp}" -- 'https://go.dev/dl/?mode=json&include=all' \
        || die "派生 go-release-tag 时拉取 go.dev 失败"
    fi
    ver_deb="$(jq -r '
      ([.[] | select(.stable==true)][0].version // empty) as $v
      | if ($v|startswith("go")) then $v[2:] else empty end
    ' "${dl_tmp}")"
    rm -f -- "${dl_tmp}"
    [[ "${ver_deb}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "无法从官方索引派生 Go 版本"
    go_release_tag="apt-hub-go-${ver_deb}-${rev}"
    printf 'update_sources.sh: 派生 go-release-tag=%s（仍须上游已上传该 tag）\n' "${go_release_tag}"
  fi
fi

assert_no_overlap "${work}" "${previous}" "work-dir 与 previous 重叠"
assert_no_overlap "${work}" "${gnupghome}" "work-dir 与 gnupghome 重叠"
assert_no_overlap "${previous}" "${gnupghome}" "previous 与 gnupghome 重叠"
assert_no_overlap "${work}" "${catalog}" "work-dir 与 catalog 重叠"
if [[ -n "${releases}" ]]; then
  assert_no_overlap "${work}" "${releases}" "work-dir 与 releases 重叠"
  assert_no_overlap "${previous}" "${releases}" "previous 与 releases 重叠"
  assert_no_overlap "${gnupghome}" "${releases}" "gnupghome 与 releases 重叠"
fi

readme_src="${PROJECT_ROOT}/README.md"
[[ -f "${readme_src}" && ! -L "${readme_src}" ]] || die "缺少普通 README.md"
assert_no_symlink_components "${readme_src}"

add_src="${SCRIPT_DIR}/add_source.sh"
[[ -f "${add_src}" && ! -L "${add_src}" ]] || die "源码缺少普通加源脚本"
assert_no_symlink_components "${add_src}"

for helper in ubuntu_releases.sh sync.sh verify_ubuntu.sh render.sh; do
  [[ -f "${SCRIPT_DIR}/${helper}" && ! -L "${SCRIPT_DIR}/${helper}" ]] || die "缺少 ${helper}"
done

# 锁与空目录预检：拒绝前无子流程副作用。
lockfile="${work}.lock"
lockdir="$(dirname -- "${lockfile}")"
[[ -d "${lockdir}" ]] || die "work-dir 父目录不存在"
assert_no_symlink_components "${lockdir}"
if [[ -L "${lockfile}" ]]; then
  die "lock 不能是符号链接: ${lockfile}"
fi
if [[ -e "${lockfile}" ]]; then
  [[ -f "${lockfile}" ]] || die "lock 不是普通文件: ${lockfile}"
  assert_no_symlink_components "${lockfile}"
fi
exec 9>>"${lockfile}" || die "无法打开 lock: ${lockfile}"
lock_fd=9
if [[ -L "${lockfile}" ]]; then
  die "lock 不能是符号链接: ${lockfile}"
fi
[[ -f "${lockfile}" ]] || die "lock 不是普通文件: ${lockfile}"
[[ "$(stat -L -c '%d:%i' /proc/self/fd/9)" == "$(stat -c '%d:%i' "${lockfile}")" ]] \
  || die "lock 句柄与路径不一致"
flock -n 9 || die "更新已在进行: ${lockfile}"

if [[ -e "${work}" ]]; then
  [[ -d "${work}" ]] || die "work-dir 存在但不是目录"
  [[ ! -L "${work}" ]] || die "拒绝符号链接: --work-dir"
  dir_is_empty "${work}" || die "拒绝已有非空或不可访问 work-dir: ${work}"
else
  mkdir -- "${work}"
fi
dir_is_empty "${work}" || die "拒绝已有非空或不可访问 work-dir: ${work}"
printf 'pid=%s\nstarted=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${work}/.apt-hub-update.owned"

site_dir="${work}/site"
verify_dir="${work}/verify"
readme_copy="${work}/README.md"
releases_work="${work}/releases.json"
success_json="${work}/success.json"

# 发行版：无 --releases 时在 work 内发现；有则复制合法输入。
if [[ -n "${releases}" ]]; then
  cp -- "${releases}" "${releases_work}"
else
  "${SCRIPT_DIR}/ubuntu_releases.sh" --output "${releases_work}"
fi
[[ -f "${releases_work}" && ! -L "${releases_work}" ]] || die "work 内缺少 releases.json"

# sync → 同 checkout 复制 add_source(0644) → verify(含真实下载) → render
sync_args=(
  --catalog "${catalog}"
  --releases "${releases_work}"
  --previous "${previous}"
  --output "${site_dir}"
  --gnupghome "${gnupghome}"
  --fingerprint "${fingerprint}"
  --site-url "${site_url}"
)
[[ -n "${package_repository}" ]] && sync_args+=(--package-repository "${package_repository}")
[[ -n "${go_release_tag}" ]] && sync_args+=(--go-release-tag "${go_release_tag}")
[[ -n "${go_downloads_json}" ]] && sync_args+=(--go-downloads-json "${go_downloads_json}")
[[ -n "${rotate_from}" ]] && sync_args+=(--rotate-from "${rotate_from}")
"${SCRIPT_DIR}/sync.sh" "${sync_args[@]}"

cp -- "${add_src}" "${site_dir}/add_source.sh"
chmod 0644 -- "${site_dir}/add_source.sh"
[[ -f "${site_dir}/add_source.sh" && ! -L "${site_dir}/add_source.sh" ]] || die "站点 add_source.sh 非法"
cmp -s -- "${add_src}" "${site_dir}/add_source.sh" || die "add_source.sh 与本次 checkout 不一致"
[[ "$(stat -c '%a' "${site_dir}/add_source.sh")" == 644 ]] || die "add_source.sh 必须为 0644"

"${SCRIPT_DIR}/verify_ubuntu.sh" \
  --site "${site_dir}" \
  --releases "${releases_work}" \
  --work-dir "${verify_dir}" \
  --verify-downloads

[[ -f "${verify_dir}/summary.json" && ! -L "${verify_dir}/summary.json" ]] || die "缺少 verify summary.json"
jq -e '.ok==true' "${verify_dir}/summary.json" >/dev/null || die "verify summary ok!=true"

cp -- "${readme_src}" "${readme_copy}"
"${SCRIPT_DIR}/render.sh" \
  --state "${site_dir}/state.json" \
  --readme "${readme_copy}" \
  --site "${site_dir}"

[[ -f "${site_dir}/index.html" && ! -L "${site_dir}/index.html" ]] || die "缺少 site/index.html"
[[ -f "${readme_copy}" && ! -L "${readme_copy}" ]] || die "缺少 work/README.md"

# 仅全部成功后写 success.json；半成品不得带 success 标记。
tmp_success="${work}/success.json.pending"
jq -n \
  --argjson ok true \
  --arg site "${site_dir}" \
  --arg summary "${verify_dir}/summary.json" \
  --arg readme "${readme_copy}" \
  --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ok:$ok,site:$site,summary:$summary,readme:$readme,checked_at:$checked_at}' >"${tmp_success}"
mv -- "${tmp_success}" "${success_json}"
jq -e '.ok==true' "${success_json}" >/dev/null || die "success.json 写入异常"

printf 'update_sources.sh: 候选已就绪 site=%s summary=%s\n' "${site_dir}" "${verify_dir}/summary.json"
exit 0
