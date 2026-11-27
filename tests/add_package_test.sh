#!/usr/bin/env bash
# 验证 add_package.sh 的包名校验、冲突拦截、正则校验与写入。
set -euo pipefail
export LC_ALL=C
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$(mktemp -d "${ROOT}/tmp/add-package-test.XXXXXX")"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }

setup_tree() {
  local dest="$1"
  rm -rf -- "${dest}"
  mkdir -p "${dest}/scripts" "${dest}/config" "${dest}/templates" "${dest}/tmp" "${dest}/bin"
  cp -- "${ROOT}/scripts/add_package.sh" "${ROOT}/scripts/sync.sh" "${dest}/scripts/"
  cp -- "${ROOT}/config/packages.json" "${ROOT}/config/go.json" "${dest}/config/"
  cp -- "${ROOT}/templates/package_github_deb.json" "${dest}/templates/"
}

run_add() {
  local dest="$1"
  shift
  (cd "${dest}" && PATH="${dest}/bin:${PATH}" bash scripts/add_package.sh --yes --skip-remote-check "$@") \
    >"${dest}/run.log" 2>&1
}

# 非法 Debian 包名
setup_tree "${BASE}/badname"
rc=0
run_add "${BASE}/badname" --id bad --repository owner/app --package 'Foo_Bar' \
  --description d --source-url https://example.test --license MIT \
  --arch 'amd64=^foo_amd64\.deb$' || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q '不是合法 Debian/APT 包名' "${BASE}/badname/run.log"; then
  pass '拒绝非法 Debian 包名'
else
  fail "非法包名未拦截 rc=${rc} log=$(cat "${BASE}/badname/run.log")"
fi

# catalog 去重
setup_tree "${BASE}/dup"
rc=0
run_add "${BASE}/dup" --id rustdesk --repository rustdesk/rustdesk --package rustdesk-unique \
  --description d --source-url https://github.com/rustdesk/rustdesk --license MIT \
  --arch 'amd64=^rustdesk-.*x86_64\.deb$' || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q '已存在 id=rustdesk' "${BASE}/dup/run.log"; then
  pass '拒绝重复 id'
else
  fail "重复 id 未拦截 rc=${rc} log=$(cat "${BASE}/dup/run.log")"
fi

setup_tree "${BASE}/dup-pkg"
rc=0
run_add "${BASE}/dup-pkg" --id newdesk --repository rustdesk/rustdesk --package rustdesk \
  --description d --source-url https://github.com/rustdesk/rustdesk --license MIT \
  --arch 'amd64=^rustdesk-.*x86_64\.deb$' || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q '已存在 package=rustdesk' "${BASE}/dup-pkg/run.log"; then
  pass '拒绝重复 package'
else
  fail "重复 package 未拦截 rc=${rc} log=$(cat "${BASE}/dup-pkg/run.log")"
fi

# apt 同名冲突
setup_tree "${BASE}/apt"
cat >"${BASE}/apt/bin/apt-cache" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == --no-generate && "$2" == policy && "$3" == vim ]]; then
  cat <<'OUT'
vim:
  Installed: (none)
  Candidate: 2:9.1.0016-1
OUT
  exit 0
fi
echo 'unknown:'; echo '  Candidate: (none)'
exit 0
SH
chmod 755 "${BASE}/apt/bin/apt-cache"
rc=0
run_add "${BASE}/apt" --id vim-extra --repository official/vim --package vim \
  --description d --source-url https://example.test --license MIT \
  --arch 'amd64=^vim_.*_amd64\.deb$' || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q '与 Ubuntu 自带 apt 包同名' "${BASE}/apt/run.log"; then
  pass '拦截 Ubuntu apt 同名冲突'
else
  fail "apt 冲突未拦截 rc=${rc} log=$(cat "${BASE}/apt/run.log")"
fi

# snap 同名冲突（apt 无候选）
setup_tree "${BASE}/snap"
cat >"${BASE}/snap/bin/apt-cache" <<'SH'
#!/usr/bin/env bash
echo 'pkg:'; echo '  Candidate: (none)'
exit 0
SH
cat >"${BASE}/snap/bin/snap" <<'SH'
#!/usr/bin/env bash
[[ "$1" == info && "$2" == hello-snap ]] && exit 0
exit 1
SH
chmod 755 "${BASE}/snap/bin/apt-cache" "${BASE}/snap/bin/snap"
rc=0
run_add "${BASE}/snap" --id hello-snap --repository official/hello --package hello-snap \
  --description d --source-url https://example.test --license MIT \
  --arch 'amd64=^hello-snap_.*_amd64\.deb$' || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q '与 Ubuntu snap 包同名' "${BASE}/snap/run.log"; then
  pass '拦截 Ubuntu snap 同名冲突'
else
  fail "snap 冲突未拦截 rc=${rc} log=$(cat "${BASE}/snap/run.log")"
fi

# 写入 catalog 并跑 sync.sh --check-catalog-only
setup_tree "${BASE}/ok"
# 确保 PATH 里没有会误报的真实 apt-cache/snap：放到 dest/bin 的空壳返回 none/失败
cat >"${BASE}/ok/bin/apt-cache" <<'SH'
#!/usr/bin/env bash
echo 'pkg:'; echo '  Candidate: (none)'
exit 0
SH
cat >"${BASE}/ok/bin/snap" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod 755 "${BASE}/ok/bin/apt-cache" "${BASE}/ok/bin/snap"
rc=0
run_add "${BASE}/ok" --id example-app --repository official-owner/example-app \
  --package example-app --description '软件用途的简短说明' \
  --source-url https://github.com/official-owner/example-app --license MIT \
  --ubuntu-series supported \
  --arch 'amd64=^example-app_[0-9.]+_amd64\.deb$' \
  --arch 'arm64=^example-app_[0-9.]+_arm64\.deb$' || rc=$?
if [[ "${rc}" -eq 0 ]] \
  && jq -e '.packages[] | select(.id=="example-app" and .package=="example-app" and .repository=="official-owner/example-app")' \
    "${BASE}/ok/config/packages.json" >/dev/null \
  && grep -q 'catalog 校验通过' "${BASE}/ok/run.log" \
  && jq -e '.packages[] | select(.id=="golang")' "${BASE}/ok/config/packages.json" >/dev/null; then
  pass '校验通过后写入 packages.json 并保留已有条目'
else
  fail "写入失败 rc=${rc} log=$(cat "${BASE}/ok/run.log")"
fi

# 远程正则唯一匹配
setup_tree "${BASE}/remote"
cat >"${BASE}/remote/bin/apt-cache" <<'SH'
#!/usr/bin/env bash
echo 'pkg:'; echo '  Candidate: (none)'
exit 0
SH
chmod 755 "${BASE}/remote/bin/apt-cache"
cat >"${BASE}/remote/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out="" 
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|--connect-timeout|--max-time|--retry|--proto|--proto-redir) shift 2 ;;
    --tlsv1.2|-sS|--|--yes) shift ;;
    https://api.github.com/repos/official-owner/example-app/releases/latest)
      jq -n '{
        tag_name:"1.2.3", draft:false, prerelease:false,
        assets:[
          {name:"example-app_1.2.3_amd64.deb", size:10, digest:("sha256:"+("a"*64)),
           browser_download_url:"https://github.com/official-owner/example-app/releases/download/1.2.3/example-app_1.2.3_amd64.deb"},
          {name:"example-app_1.2.3_arm64.deb", size:11, digest:("sha256:"+("b"*64)),
           browser_download_url:"https://github.com/official-owner/example-app/releases/download/1.2.3/example-app_1.2.3_arm64.deb"}
        ]
      }' >"${out}"
      printf '200'
      exit 0
      ;;
    *) exit 22 ;;
  esac
done
SH
chmod 755 "${BASE}/remote/bin/curl"
rc=0
(cd "${BASE}/remote" && PATH="${BASE}/remote/bin:${PATH}" bash scripts/add_package.sh --yes \
  --id example-app --repository official-owner/example-app --package example-app \
  --description '软件用途的简短说明' --source-url https://github.com/official-owner/example-app \
  --license MIT \
  --arch 'amd64=^example-app_[0-9.]+_amd64\.deb$' \
  --arch 'arm64=^example-app_[0-9.]+_arm64\.deb$') >"${BASE}/remote/run.log" 2>&1 || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q 'amd64 匹配 example-app_1.2.3_amd64.deb' "${BASE}/remote/run.log"; then
  pass '远程校验唯一匹配官方 .deb 资产'
else
  fail "远程唯一匹配失败 rc=${rc} log=$(cat "${BASE}/remote/run.log")"
fi

# 正则匹配不唯一
setup_tree "${BASE}/multi"
cat >"${BASE}/multi/bin/apt-cache" <<'SH'
#!/usr/bin/env bash
echo 'pkg:'; echo '  Candidate: (none)'
exit 0
SH
chmod 755 "${BASE}/multi/bin/apt-cache"
cat >"${BASE}/multi/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|--connect-timeout|--max-time|--retry|--proto|--proto-redir) shift 2 ;;
    --tlsv1.2|-sS|--|--yes) shift ;;
    https://api.github.com/repos/official-owner/example-app/releases/latest)
      jq -n '{
        tag_name:"1.2.3", draft:false, prerelease:false,
        assets:[
          {name:"example-app_1.2.3_amd64.deb", size:10},
          {name:"example-app_1.2.4_amd64.deb", size:11}
        ]
      }' >"${out}"
      printf '200'
      exit 0
      ;;
    *) exit 22 ;;
  esac
done
SH
chmod 755 "${BASE}/multi/bin/curl"
rc=0
(cd "${BASE}/multi" && PATH="${BASE}/multi/bin:${PATH}" bash scripts/add_package.sh --yes \
  --id example-app --repository official-owner/example-app --package example-app \
  --description d --source-url https://github.com/official-owner/example-app --license MIT \
  --arch 'amd64=^example-app_.*_amd64\.deb$') >"${BASE}/multi/run.log" 2>&1 || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q '必须唯一匹配 1 个资产，实际 2 个' "${BASE}/multi/run.log"; then
  pass '远程正则不唯一时拒绝写入'
else
  fail "不唯一正则未拦截 rc=${rc} log=$(cat "${BASE}/multi/run.log")"
fi

# 确认失败的写入没有改 catalog
if jq -e '.packages|any(.id=="example-app")|not' "${BASE}/multi/config/packages.json" >/dev/null; then
  pass '远程校验失败不写入 packages.json'
else
  fail '远程校验失败仍写入了 packages.json'
fi

printf 'RESULT pass=%s fail=%s evidence=%s\n' "${PASS}" "${FAIL}" "${BASE}"
[[ "${FAIL}" -eq 0 ]]
