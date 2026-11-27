#!/usr/bin/env bash
# 执行原工作流依赖步骤，现成工具不得触发全源更新。
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "${ROOT}/tmp"
BASE=$(mktemp -d "${ROOT}/tmp/ci-dependencies-test.XXXXXX")
mkdir -p "${BASE}/bin" "${BASE}/scripts"
if [[ -f "${ROOT}/scripts/ci_dependencies.sh" ]]; then cp "${ROOT}/scripts/ci_dependencies.sh" "${BASE}/scripts/"; fi
cat >"${BASE}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '禁止无条件安装: %s\n' "$*" >&2
exit 90
EOF
chmod 755 "${BASE}/bin/sudo"
for tool in curl jq gh gpg gpgconf dpkg-deb dpkg-scanpackages apt-ftparchive readelf shellcheck xxd node; do
  ln -s /bin/true "${BASE}/bin/${tool}"
done
awk '
  /^      - name: / { cap=0; dep=($0 ~ /安装临时依赖|安装构包与签源依赖/); if(dep)n++ }
  dep && $0=="        run: |" { cap=1; next }
  dep && $0~/^        run: / && $0!="        run: |" {print substr($0,14) > (base "/step-" n ".sh"); next}
  cap && substr($0,1,10)=="          " {print substr($0,11) > (base "/step-" n ".sh"); next}
  cap && $0!~/^$/ {cap=0}
  END {if(n!=4)exit 1}
' base="${BASE}" "${ROOT}/.github/workflows/release.yml"
for step in 1 2 3 4; do
  rc=0
  (cd "${BASE}" && PATH="${BASE}/bin:${PATH}" bash "${BASE}/step-${step}.sh") >"${BASE}/step-${step}.log" 2>&1 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then printf 'FAIL 依赖已齐仍执行APT step=%s rc=%s evidence=%s\n' "${step}" "${rc}" "${BASE}"; exit 1; fi
done
printf 'PASS 四个原依赖步骤复用预装工具，不执行APT\n'

# 缺少 apt-ftparchive 时只补 apt-utils；sudo 和 apt-get 均为明确夹具。
mkdir -p "${BASE}/missing-bin"
for tool in bash dirname mkdir mktemp chmod cat rm env; do ln -s "$(command -v "$tool")" "${BASE}/missing-bin/${tool}"; done
for tool in curl jq gh gpg gpgconf dpkg-deb dpkg-scanpackages readelf shellcheck xxd node; do
  ln -s /bin/true "${BASE}/missing-bin/${tool}"
done
cat >"${BASE}/missing-bin/dpkg" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == --print-architecture ]] || exit 91
printf '%s\n' "${FIXTURE_ARCH}"
EOF
cat >"${BASE}/missing-bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -n ]] || exit 91
shift
exec "$@"
EOF
cat >"${BASE}/missing-bin/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FIXTURE}/timeout.calls"
[[ "$1" == --kill-after=10s ]] || exit 91
shift 2
exec "$@"
EOF
cat >"${BASE}/missing-bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FIXTURE}/apt.calls"
for arg in "$@"; do
  case "$arg" in
    Dir::Etc::sourcelist=*) cp_path="${arg#*=}"; cat "$cp_path" >"${FIXTURE}/used.sources" ;;
  esac
done
case " $* " in
  *' update '*) exit "${FIXTURE_UPDATE_RC:-0}" ;;
  *' install '*)
    [[ "$*" == *'install -y --no-install-recommends --no-upgrade apt-utils' ]] || exit 91
    ln -s /bin/true "${FIXTURE}/missing-bin/apt-ftparchive" ;;
  *) exit 91 ;;
esac
EOF
ln -s "$(command -v ln)" "${BASE}/missing-bin/ln"
chmod 755 "${BASE}/missing-bin/dpkg" "${BASE}/missing-bin/sudo" "${BASE}/missing-bin/timeout" "${BASE}/missing-bin/apt-get"
for arch in amd64 arm64; do
  : >"${BASE}/apt.calls"
  : >"${BASE}/timeout.calls"
  rm -f "${BASE}/missing-bin/apt-ftparchive"
  FIXTURE="${BASE}" FIXTURE_ARCH="$arch" PATH="${BASE}/missing-bin" GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted ImageOS=ubuntu24 \
    /bin/bash "${BASE}/scripts/ci_dependencies.sh" build >"${BASE}/missing-${arch}.log" 2>&1
  [[ "$(wc -l <"${BASE}/apt.calls")" -eq 2 ]]
  grep -Fq 'Dir::Etc::sourceparts=-' "${BASE}/apt.calls"
  grep -Fq 'Acquire::https::Timeout=20' "${BASE}/apt.calls"
  grep -Fq 'DPkg::Lock::Timeout=30' "${BASE}/apt.calls"
  grep -Fxq "Architectures: ${arch}" "${BASE}/used.sources"
  [[ "$(grep -cFx 'Components: main' "${BASE}/used.sources")" -eq 2 ]]
  if [[ "$arch" == amd64 ]]; then
    grep -Fxq 'URIs: https://archive.ubuntu.com/ubuntu' "${BASE}/used.sources"
    grep -Fxq 'URIs: https://security.ubuntu.com/ubuntu' "${BASE}/used.sources"
  else
    [[ "$(grep -cFx 'URIs: https://ports.ubuntu.com/ubuntu-ports' "${BASE}/used.sources")" -eq 2 ]]
  fi
  if grep -Eq 'azure|microsoft|trusted=yes|AllowUnauthenticated' "${BASE}/used.sources" "${BASE}/apt.calls"; then exit 1; fi
  grep -Fq -- '--kill-after=10s 180s apt-get' "${BASE}/timeout.calls"
  grep -Fq -- '--kill-after=10s 300s env' "${BASE}/timeout.calls"
done
printf 'PASS 缺项仅安装apt-utils，amd64/arm64均限定宿主架构及官方HTTPS源\n'
rm -f "${BASE}/missing-bin/apt-ftparchive"
: >"${BASE}/apt.calls"
rc=0
FIXTURE="${BASE}" FIXTURE_ARCH=amd64 FIXTURE_UPDATE_RC=42 PATH="${BASE}/missing-bin" GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted ImageOS=ubuntu24 \
  /bin/bash "${BASE}/scripts/ci_dependencies.sh" build >"${BASE}/update-failed.log" 2>&1 || rc=$?
[[ "$rc" -eq 42 && "$(wc -l <"${BASE}/apt.calls")" -eq 1 && ! -e "${BASE}/missing-bin/apt-ftparchive" ]]
printf 'PASS 更新失败保留原退出码且不继续安装\n'
printf 'RESULT pass=3 fail=0 evidence=%s\n' "${BASE}"
