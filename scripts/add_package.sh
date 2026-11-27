#!/usr/bin/env bash
# 按 templates/package_github_deb.json 向 config/packages.json 追加官方 GitHub .deb 软件。
set -euo pipefail
umask 022
export LC_ALL=C
export LANG=C
export LANGUAGE=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${ROOT}"

PKG_NAME='^[a-z0-9][a-z0-9.+-]+$'
SAFE_ID='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
REPO_NAME='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
ALLOWED_ARCH='^(amd64|arm64)$'
CATALOG="${ROOT}/config/packages.json"
TEMPLATE="${ROOT}/templates/package_github_deb.json"

die() {
  printf 'add_package.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
用法:
  scripts/add_package.sh --id <id> --repository <owner/repo> --package <包名> \
    --description <说明> --source-url <https> --license <许可> \
    [--ubuntu-series supported|<代号,代号>] \
    --arch <amd64|arm64>=<资产名正则> [--arch ...]
    [--skip-remote-check] [--yes]
缺字段且在终端交互时会逐项询问。校验通过后写入 config/packages.json，并调用
scripts/sync.sh --check-catalog-only 确认清单合法。
EOF
  exit 2
}

id=""
repository=""
package=""
description=""
source_url=""
license=""
ubuntu_series="supported"
skip_remote=0
assume_yes=0
declare -A ARCH_REGEX=()

prompt() {
  local var="$1" label="$2" current="$3"
  local value=""
  if [[ -n "${current}" ]]; then
    printf -v "${var}" '%s' "${current}"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "缺少 ${label}，且非交互输入"
  fi
  printf '%s: ' "${label}" >/dev/tty
  IFS= read -r value </dev/tty || die "读取 ${label} 失败"
  [[ -n "${value}" ]] || die "${label} 不能为空"
  printf -v "${var}" '%s' "${value}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) [[ $# -ge 2 ]] || usage; id="$2"; shift 2 ;;
    --repository) [[ $# -ge 2 ]] || usage; repository="$2"; shift 2 ;;
    --package) [[ $# -ge 2 ]] || usage; package="$2"; shift 2 ;;
    --description) [[ $# -ge 2 ]] || usage; description="$2"; shift 2 ;;
    --source-url) [[ $# -ge 2 ]] || usage; source_url="$2"; shift 2 ;;
    --license) [[ $# -ge 2 ]] || usage; license="$2"; shift 2 ;;
    --ubuntu-series) [[ $# -ge 2 ]] || usage; ubuntu_series="$2"; shift 2 ;;
    --arch)
      [[ $# -ge 2 ]] || usage
      case "$2" in
        amd64=*|arm64=*)
          ARCH_REGEX["${2%%=*}"]="${2#*=}"
          ;;
        *) die "--arch 必须是 amd64=<正则> 或 arm64=<正则>" ;;
      esac
      shift 2
      ;;
    --skip-remote-check) skip_remote=1; shift ;;
    --yes|-y) assume_yes=1; shift ;;
    -h|--help) usage ;;
    *) die "未知参数: $1" ;;
  esac
done

prompt id "id" "${id}"
prompt repository "repository (owner/repo)" "${repository}"
prompt package "package（Debian 包名）" "${package}"
prompt description "description" "${description}"
prompt source_url "source_url (https)" "${source_url}"
prompt license "license" "${license}"
if [[ "${#ARCH_REGEX[@]}" -eq 0 ]]; then
  if [[ -t 0 ]]; then
    local_amd="" local_arm=""
    printf 'amd64 资产正则: ' >/dev/tty
    IFS= read -r local_amd </dev/tty || true
    printf 'arm64 资产正则: ' >/dev/tty
    IFS= read -r local_arm </dev/tty || true
    [[ -n "${local_amd}" ]] && ARCH_REGEX[amd64]="${local_amd}"
    [[ -n "${local_arm}" ]] && ARCH_REGEX[arm64]="${local_arm}"
  fi
fi
[[ "${#ARCH_REGEX[@]}" -gt 0 ]] || die "至少需要一个 --arch <架构>=<正则>"

[[ -f "${CATALOG}" && ! -L "${CATALOG}" ]] || die "缺少 ${CATALOG}"
[[ -f "${TEMPLATE}" && ! -L "${TEMPLATE}" ]] || die "缺少 ${TEMPLATE}"
command -v jq >/dev/null 2>&1 || die "缺少 jq"

# 1) Debian 包名与清单去重
assert_debian_package_name() {
  local pkg="$1"
  [[ "${pkg}" =~ ${PKG_NAME} ]] || die "package 不是合法 Debian/APT 包名: ${pkg}"
}

assert_unique_catalog() {
  local field="$1" value="$2"
  if jq -e --arg v "${value}" --arg f "${field}" '.packages|any(.[$f]==$v)' "${CATALOG}" >/dev/null; then
    die "config/packages.json 已存在 ${field}=${value}"
  fi
}

[[ "${id}" =~ ${SAFE_ID} && "${id}" != *..* ]] || die "id 非法: ${id}"
[[ "${repository}" =~ ${REPO_NAME} ]] || die "repository 非法: ${repository}"
assert_debian_package_name "${package}"
[[ -n "${description}" && -n "${license}" ]] || die "description 与 license 不能为空"
[[ "${source_url}" == https://* ]] || die "source_url 必须是 https"
assert_unique_catalog id "${id}"
assert_unique_catalog package "${package}"

series_json=""
if [[ "${ubuntu_series}" == "supported" ]]; then
  series_json='"supported"'
else
  series_json="$(jq -nc --arg s "${ubuntu_series}" '($s|split(","))|map(gsub("^\\s+|\\s+$";""))|map(select(length>0))')" \
    || die "ubuntu_series 无法解析"
  jq -e 'type=="array" and length>0' <<<"${series_json}" >/dev/null || die "ubuntu_series 数组为空"
fi

for arch in "${!ARCH_REGEX[@]}"; do
  [[ "${arch}" =~ ${ALLOWED_ARCH} ]] || die "非法架构: ${arch}"
  [[ -n "${ARCH_REGEX[$arch]}" ]] || die "架构 ${arch} 的正则不能为空"
done

# 2) Ubuntu apt / snap 同名冲突。命令不存在时跳过实时探测，仍保留本函数供测试覆盖。
package_conflicts_ubuntu_apt() {
  local pkg="$1" out=""
  command -v apt-cache >/dev/null 2>&1 || return 1
  out="$(apt-cache --no-generate policy "${pkg}" 2>/dev/null || true)"
  [[ -n "${out}" ]] || return 1
  echo "${out}" | awk '
    $1=="Candidate:" && $2!="(none)" { found=1 }
    END { exit found?0:1 }
  '
}

package_conflicts_ubuntu_snap() {
  local pkg="$1"
  command -v snap >/dev/null 2>&1 || return 1
  snap info "${pkg}" >/dev/null 2>&1
}

if package_conflicts_ubuntu_apt "${package}"; then
  die "package 与 Ubuntu 自带 apt 包同名，已拦截: ${package}"
fi
if package_conflicts_ubuntu_snap "${package}"; then
  die "package 与 Ubuntu snap 包同名，已拦截: ${package}"
fi
printf 'add_package.sh: 未发现 apt/snap 同名冲突: %s\n' "${package}"

# 3) 可选远程校验：各架构正则唯一匹配 official latest 的一个 .deb
if [[ "${skip_remote}" -eq 0 ]]; then
  command -v curl >/dev/null 2>&1 || die "缺少 curl"
  tmp="$(mktemp)"
  extra_auth=()
  if [[ -n "${GH_TOKEN:-}" ]]; then
    extra_auth=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi
  code="$(curl -sS --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 120 --retry 2 \
    -H "Accept: application/vnd.github+json" \
    "${extra_auth[@]}" \
    -o "${tmp}" -w '%{http_code}' -- "https://api.github.com/repos/${repository}/releases/latest")" \
    || { rm -f -- "${tmp}"; die "请求 GitHub /releases/latest 失败"; }
  if [[ "${code}" != "200" ]]; then
    rm -f -- "${tmp}"
    die "GitHub /releases/latest 失败: HTTP ${code}"
  fi
  jq -e 'type=="object" and .draft!=true and .prerelease!=true and (.assets|type)=="array"' "${tmp}" >/dev/null \
    || { rm -f -- "${tmp}"; die "latest 不是合法稳定版 Release"; }
  for arch in "${!ARCH_REGEX[@]}"; do
    regex="${ARCH_REGEX[$arch]}"
    n="$(jq --arg re "${regex}" '[.assets[]? | select((.name|type=="string") and (.name|test($re)))] | length' "${tmp}")"
    if [[ "${n}" != "1" ]]; then
      rm -f -- "${tmp}"
      die "架构 ${arch} 的正则必须唯一匹配 1 个资产，实际 ${n} 个: ${regex}"
    fi
    name="$(jq -r --arg re "${regex}" '.assets[] | select(.name|test($re)) | .name' "${tmp}")"
    [[ "${name}" == *.deb ]] || { rm -f -- "${tmp}"; die "匹配到的资产不是 .deb: ${name}"; }
    printf 'add_package.sh: %s 匹配 %s\n' "${arch}" "${name}"
  done
  rm -f -- "${tmp}"
else
  printf 'add_package.sh: 跳过远程资产校验\n'
fi

arch_json="$(jq -n --argjson empty '{}' '$empty')"
for arch in $(printf '%s\n' "${!ARCH_REGEX[@]}" | LC_ALL=C sort); do
  arch_json="$(jq --arg a "${arch}" --arg r "${ARCH_REGEX[$arch]}" '.[$a]=$r' <<<"${arch_json}")"
done

entry="$(jq -n \
  --arg id "${id}" \
  --arg repository "${repository}" \
  --arg package "${package}" \
  --arg description "${description}" \
  --arg source_url "${source_url}" \
  --arg license "${license}" \
  --argjson ubuntu_series "${series_json}" \
  --argjson architectures "${arch_json}" \
  '{
    id:$id,
    repository:$repository,
    package:$package,
    description:$description,
    source_url:$source_url,
    license:$license,
    ubuntu_series:$ubuntu_series,
    architectures:$architectures
  }')"

if [[ "${assume_yes}" -ne 1 && -t 0 ]]; then
  printf '即将写入以下条目:\n%s\n确认写入? [y/N] ' "$(jq . <<<"${entry}")" >/dev/tty
  IFS= read -r ans </dev/tty || true
  [[ "${ans}" == "y" || "${ans}" == "Y" ]] || die "已取消"
fi

mkdir -p -- "${ROOT}/tmp"
tmp_catalog="$(mktemp "${ROOT}/tmp/packages.json.XXXXXX")"
jq --argjson entry "${entry}" '.packages += [$entry]' "${CATALOG}" >"${tmp_catalog}" \
  || { rm -f -- "${tmp_catalog}"; die "写入 catalog 失败"; }
mv -f -- "${tmp_catalog}" "${CATALOG}"
printf 'add_package.sh: 已写入 %s\n' "${CATALOG}"

bash "${ROOT}/scripts/sync.sh" --check-catalog-only --catalog "${CATALOG}" \
  || die "写入后 catalog 校验失败"
printf 'add_package.sh: catalog 校验通过\n'
