#!/usr/bin/env bash
# 复用 runner 工具，仅从隔离的官方源补齐缺项。
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
die() { printf 'ci_dependencies.sh: %s\n' "$*" >&2; exit 1; }
mode="${1:-}"
[[ $# -eq 1 ]] || die '需要 release、build 或 cleanup'
tools=(curl jq gh)
packages=(curl jq gh)
case "${mode}" in
  release) tools+=(dpkg-deb); packages+=(dpkg-dev) ;;
  build)
    tools+=(gpg gpgconf dpkg-deb dpkg-scanpackages apt-ftparchive readelf shellcheck xxd node)
    packages+=(gnupg gnupg dpkg-dev dpkg-dev apt-utils binutils shellcheck xxd nodejs) ;;
  cleanup) ;;
  *) die '未知依赖组' ;;
esac
missing=()
for i in "${!tools[@]}"; do
  if ! command -v "${tools[$i]}" >/dev/null 2>&1; then
    found=0
    for pkg in "${missing[@]}"; do [[ "${pkg}" != "${packages[$i]}" ]] || found=1; done
    [[ "${found}" -eq 1 ]] || missing+=("${packages[$i]}")
  fi
done
if [[ "${#missing[@]}" -eq 0 ]]; then
  printf 'ci_dependencies.sh: %s 工具已齐，跳过APT\n' "${mode}"
  exit 0
fi
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${ImageOS:-}" == ubuntu24 ]] \
  || die '只在 Ubuntu 24.04 GitHub 托管 runner 补装依赖'
[[ -r /usr/share/keyrings/ubuntu-archive-keyring.gpg && -s /etc/ssl/certs/ca-certificates.crt ]] || die '缺少官方签名公钥或CA证书'
for tool in dpkg sudo timeout; do command -v "${tool}" >/dev/null 2>&1 || die "缺少 ${tool}"; done
arch=$(dpkg --print-architecture)
case "${arch}" in
  amd64) archive=https://archive.ubuntu.com/ubuntu; security=https://security.ubuntu.com/ubuntu ;;
  arm64) archive=https://ports.ubuntu.com/ubuntu-ports; security="${archive}" ;;
  *) die "不支持的runner架构: ${arch}" ;;
esac
components=main
for pkg in "${missing[@]}"; do
  case "${pkg}" in gh|shellcheck|nodejs) components='main universe' ;; esac
done
mkdir -p "${ROOT}/tmp"
[[ -d "${ROOT}/tmp" && ! -L "${ROOT}/tmp" ]] || die '项目tmp不是普通目录'
work=$(mktemp -d "${ROOT}/tmp/ci-dependencies.XXXXXX")
trap 'sudo -n rm -rf -- "${work}"' EXIT
chmod 755 "${work}"
mkdir -p "${work}/lists/partial" "${work}/archives/partial"
cat >"${work}/ubuntu.sources" <<EOF
Types: deb
URIs: ${archive}
Suites: noble noble-updates
Components: ${components}
Architectures: ${arch}
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${security}
Suites: noble-security
Components: ${components}
Architectures: ${arch}
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
apt_options=(
  -o "Dir::Etc::sourcelist=${work}/ubuntu.sources" -o Dir::Etc::sourceparts=-
  -o "Dir::State::lists=${work}/lists" -o "Dir::Cache::archives=${work}/archives"
  -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20
  -o DPkg::Lock::Timeout=30 -o APT::Update::Error-Mode=any
)
printf 'ci_dependencies.sh: runner=%s，仅补装 %s\n' "${arch}" "${missing[*]}"
sudo -n timeout --kill-after=10s 180s apt-get "${apt_options[@]}" update
sudo -n timeout --kill-after=10s 300s env DEBIAN_FRONTEND=noninteractive \
  apt-get "${apt_options[@]}" install -y --no-install-recommends --no-upgrade "${missing[@]}"
for tool in "${tools[@]}"; do command -v "${tool}" >/dev/null 2>&1 || die "补装后仍缺少 ${tool}"; done
printf 'ci_dependencies.sh: %s 依赖已齐\n' "${mode}"
