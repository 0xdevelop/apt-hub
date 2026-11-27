#!/usr/bin/env bash
# 验证 auto_check.sh 的探测、dry-run、本地预验与固定范式原因；不访问生产服务。
set -euo pipefail
export LC_ALL=C
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$(mktemp -d "${ROOT}/tmp/auto-check-test.XXXXXX")"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }

git_identity() { git -c user.name='fixture' -c user.email='fixture@invalid' "$@"; }

setup_repo() {
  local dest="$1"
  rm -rf -- "${dest}"
  mkdir -p "${dest}/scripts" "${dest}/config" "${dest}/tmp" "${dest}/bin"
  cp -- "${ROOT}/scripts/auto_check.sh" "${dest}/scripts/"
  cp -- "${ROOT}/config/packages.json" "${ROOT}/config/go.json" "${dest}/config/"
  cp -- "${ROOT}/scripts/gen_deb_golang.sh" "${dest}/scripts/"
  printf '0.0.16\n' >"${dest}/VERSION"
  cat >"${dest}/.gitignore" <<'GI'
tmp/
bin/
/build.sh
/git_tag.sh
go-downloads.json
state.json
prov.json
upstream/
run.log
GI
  git init -q -b main "${dest}"
  git -C "${dest}" add -- scripts config VERSION .gitignore
  git_identity -C "${dest}" commit -qm init
  git init -q --bare "${dest}.git"
  git -C "${dest}" remote add origin "${dest}.git"
  git -C "${dest}" push -q origin main
  git -C "${dest}" fetch -q origin main:refs/remotes/origin/main
  # 空的 apt-hub-pages 由测试用 --state / --release-date 绕过。
}

current_inputs() {
  (cd "$1" && sha256sum scripts/gen_deb_golang.sh config/go.json | sha256sum | cut -d' ' -f1)
}

write_state() {
  local dest="$1" go_ver="${2:-go9.9.9}" rust_ver="${3:-1.5.3}" deb="${2:-go9.9.9}"
  deb="${deb#go}"
  jq -n --arg go "$go_ver" --arg deb "$deb" --arg rust "$rust_ver" '{
    schema_version:"2",
    packages:[
      {
        id:"golang", package:"golang", source_type:"go_official_archive",
        package_repository:"example/apt-hub", release_tag:"v0.0.16",
        version:("2:"+$deb+"-2"),
        upstream:{version:$go, version_debian:$deb, revision:"2", epoch:"2"}
      },
      {id:"rustdesk", package:"rustdesk", version:$rust, repository:"rustdesk/rustdesk"}
    ]
  }' >"${dest}"
}

write_go_downloads() {
  local dest="$1" ver="${2:-go9.9.9}"
  jq -n --arg ver "$ver" '[{
    version:$ver, stable:true,
    files:[
      {os:"linux",arch:"amd64",kind:"archive",filename:($ver+".linux-amd64.tar.gz"),sha256:("a"*64),size:111},
      {os:"linux",arch:"arm64",kind:"archive",filename:($ver+".linux-arm64.tar.gz"),sha256:("b"*64),size:222}
    ]
  }]' >"${dest}"
}

write_provenance() {
  local dest="$1" inputs="$2"
  jq -n --arg h "$inputs" '{schema_version:"1",build_inputs_sha256:$h,upstream:{version:"go9.9.9"}}' >"${dest}"
}

write_rust_latest() {
  local dest="$1" ver="$2"
  mkdir -p "$(dirname -- "${dest}")"
  jq -n --arg ver "$ver" '{
    tag_name:$ver, draft:false, prerelease:false,
    html_url:("https://github.com/rustdesk/rustdesk/releases/tag/"+$ver),
    assets:[
      {name:("rustdesk-"+$ver+"-x86_64.deb"), size:25345980,
       digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
       browser_download_url:("https://github.com/rustdesk/rustdesk/releases/download/"+$ver+"/rustdesk-"+$ver+"-x86_64.deb")},
      {name:("rustdesk-"+$ver+"-aarch64.deb"), size:23625528,
       digest:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
       browser_download_url:("https://github.com/rustdesk/rustdesk/releases/download/"+$ver+"/rustdesk-"+$ver+"-aarch64.deb")}
    ]
  }' >"${dest}"
}

install_mocks() {
  local dest="$1"
  mkdir -p "${dest}/bin"
  cat >"${dest}/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out="" url="" head=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    -I) head=1; shift ;;
    -w) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [[ "${head}" -eq 1 ]]; then
  printf '302'
  exit 0
fi
case "${url}" in
  *go.dev/dl*) src="${FIXTURE}/go-downloads.json" ;;
  *) exit 22 ;;
esac
[[ -f "${src}" ]] || exit 22
if [[ -n "${out}" ]]; then cp "${src}" "${out}"; else cat "${src}"; fi
SH
  cat >"${dest}/build.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "test" ]]; then
  printf 'build.sh test\n' >>"${ROOT}/tmp/build-calls.log"
  exit 0
fi
printf '%s\n' "$@" >>"${ROOT}/tmp/build-calls.log"
# 消耗 --output 目录要求：创建占位，simulate success。
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "${out:-/tmp}"
printf 'ok\n' >"${out:-/tmp}/stub"
SH
  cat >"${dest}/git_tag.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf 'git_tag.sh called\n' >"${ROOT}/tmp/git-tag-called.log"
if [[ -f "${ROOT}/tmp/auto_check_reasons.txt" ]]; then
  cp -- "${ROOT}/tmp/auto_check_reasons.txt" "${ROOT}/tmp/git-tag-reasons.log"
fi
exit 0
SH
  chmod 755 "${dest}/bin/curl" "${dest}/build.sh" "${dest}/git_tag.sh"
}

run_check() {
  local dest="$1"
  shift
  (cd "${dest}" && PATH="${dest}/bin:${PATH}" FIXTURE="${dest}" \
    bash scripts/auto_check.sh --skip-fetch "$@") >"${dest}/run.log" 2>&1
}

# 1) 无更新 + dry-run
setup_repo "${BASE}/none"
install_mocks "${BASE}/none"
write_go_downloads "${BASE}/none/go-downloads.json" go9.9.9
write_state "${BASE}/none/state.json" go9.9.9 1.5.3
write_provenance "${BASE}/none/prov.json" "$(current_inputs "${BASE}/none")"
write_rust_latest "${BASE}/none/upstream/rustdesk.json" 1.5.3
fresh_date="$(date -u -d '2 hours ago' '+%a, %d %b %Y %H:%M:%S +0000')"
rc=0
run_check "${BASE}/none" --dry-run --state "${BASE}/none/state.json" \
  --go-downloads-json "${BASE}/none/go-downloads.json" \
  --golang-provenance "${BASE}/none/prov.json" \
  --upstream-dir "${BASE}/none/upstream" \
  --release-date "${fresh_date}" --renew-days 7 --host-arch arm64 || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q '无更新' "${BASE}/none/run.log" \
  && [[ ! -e "${BASE}/none/tmp/git-tag-called.log" ]]; then
  pass '无更新时 dry-run 退出 0 且不调用 git_tag.sh'
else
  fail "无更新路径失败 rc=${rc} log=$(cat "${BASE}/none/run.log")"
fi

# 2) rustdesk 更新：dry-run 预验 URL，记录固定范式原因，不发版
setup_repo "${BASE}/rust"
install_mocks "${BASE}/rust"
write_go_downloads "${BASE}/rust/go-downloads.json" go9.9.9
write_state "${BASE}/rust/state.json" go9.9.9 1.5.3
write_provenance "${BASE}/rust/prov.json" "$(current_inputs "${BASE}/rust")"
write_rust_latest "${BASE}/rust/upstream/rustdesk.json" 1.5.4
rc=0
run_check "${BASE}/rust" --dry-run --state "${BASE}/rust/state.json" \
  --go-downloads-json "${BASE}/rust/go-downloads.json" \
  --golang-provenance "${BASE}/rust/prov.json" \
  --upstream-dir "${BASE}/rust/upstream" \
  --release-date "${fresh_date}" --renew-days 7 --host-arch arm64 || rc=$?
if [[ "${rc}" -eq 0 ]] \
  && grep -Fxq '  auto-update: rustdesk 1.5.3 -> 1.5.4' "${BASE}/rust/run.log" \
  && grep -q '外链预验通过 rustdesk' "${BASE}/rust/run.log" \
  && grep -q '跳过 git_tag.sh' "${BASE}/rust/run.log" \
  && [[ ! -e "${BASE}/rust/tmp/git-tag-called.log" ]] \
  && grep -Fxq 'auto-update: rustdesk 1.5.3 -> 1.5.4' "${BASE}/rust/tmp/auto_check_reasons.txt"; then
  pass 'rustdesk 更新 dry-run 记录固定范式原因并预验，不调用 git_tag.sh'
else
  fail "rustdesk 更新路径失败 rc=${rc} log=$(cat "${BASE}/rust/run.log")"
fi

# 3) golang 更新：调用本地 build.sh 预验与 test
setup_repo "${BASE}/go"
install_mocks "${BASE}/go"
write_go_downloads "${BASE}/go/go-downloads.json" go9.9.10
write_state "${BASE}/go/state.json" go9.9.9 1.5.3
write_provenance "${BASE}/go/prov.json" "$(current_inputs "${BASE}/go")"
write_rust_latest "${BASE}/go/upstream/rustdesk.json" 1.5.3
rc=0
run_check "${BASE}/go" --dry-run --state "${BASE}/go/state.json" \
  --go-downloads-json "${BASE}/go/go-downloads.json" \
  --golang-provenance "${BASE}/go/prov.json" \
  --upstream-dir "${BASE}/go/upstream" \
  --release-date "${fresh_date}" --renew-days 7 --host-arch amd64 || rc=$?
if [[ "${rc}" -eq 0 ]] \
  && grep -Fxq '  auto-update: golang 9.9.9 -> 9.9.10' "${BASE}/go/run.log" \
  && grep -q -- '--go-version' "${BASE}/go/tmp/build-calls.log" \
  && grep -q -- 'go9.9.10' "${BASE}/go/tmp/build-calls.log" \
  && grep -q -- '--arch' "${BASE}/go/tmp/build-calls.log" \
  && grep -q -- 'amd64' "${BASE}/go/tmp/build-calls.log" \
  && grep -Fxq 'build.sh test' "${BASE}/go/tmp/build-calls.log" \
  && grep -q '构包预验通过，已清理临时目录' "${BASE}/go/run.log"; then
  pass 'golang 更新触发本机架构预验和 build.sh test'
else
  fail "golang 预验路径失败 rc=${rc} log=$(cat "${BASE}/go/run.log") calls=$(cat "${BASE}/go/tmp/build-calls.log" 2>/dev/null || true)"
fi

# 4) 签名超过阈值：auto-renew
setup_repo "${BASE}/renew"
install_mocks "${BASE}/renew"
write_go_downloads "${BASE}/renew/go-downloads.json" go9.9.9
write_state "${BASE}/renew/state.json" go9.9.9 1.5.3
write_provenance "${BASE}/renew/prov.json" "$(current_inputs "${BASE}/renew")"
write_rust_latest "${BASE}/renew/upstream/rustdesk.json" 1.5.3
old_date="$(date -u -d '10 days ago' '+%a, %d %b %Y %H:%M:%S +0000')"
rc=0
run_check "${BASE}/renew" --dry-run --state "${BASE}/renew/state.json" \
  --go-downloads-json "${BASE}/renew/go-downloads.json" \
  --golang-provenance "${BASE}/renew/prov.json" \
  --upstream-dir "${BASE}/renew/upstream" \
  --release-date "${old_date}" --renew-days 7 --host-arch arm64 || rc=$?
if [[ "${rc}" -eq 0 ]] \
  && grep -Fxq '  auto-renew: apt signing refresh' "${BASE}/renew/run.log"; then
  pass '签名超过 --renew-days 时给出 auto-renew 原因'
else
  fail "续签探测失败 rc=${rc} log=$(cat "${BASE}/renew/run.log")"
fi

# 5) 非 dry-run：预验后触发 git_tag.sh
setup_repo "${BASE}/tag"
install_mocks "${BASE}/tag"
write_go_downloads "${BASE}/tag/go-downloads.json" go9.9.9
write_state "${BASE}/tag/state.json" go9.9.9 1.5.3
write_provenance "${BASE}/tag/prov.json" "$(current_inputs "${BASE}/tag")"
write_rust_latest "${BASE}/tag/upstream/rustdesk.json" 1.5.4
rc=0
run_check "${BASE}/tag" --state "${BASE}/tag/state.json" \
  --go-downloads-json "${BASE}/tag/go-downloads.json" \
  --golang-provenance "${BASE}/tag/prov.json" \
  --upstream-dir "${BASE}/tag/upstream" \
  --release-date "${fresh_date}" --renew-days 7 --host-arch arm64 || rc=$?
if [[ "${rc}" -eq 0 ]] \
  && grep -Fq 'git_tag.sh called' "${BASE}/tag/tmp/git-tag-called.log" \
  && grep -Fxq 'auto-update: rustdesk 1.5.3 -> 1.5.4' "${BASE}/tag/tmp/git-tag-reasons.log"; then
  pass '非 dry-run 将固定范式原因交给 git_tag.sh'
else
  fail "触发 git_tag.sh 失败 rc=${rc} log=$(cat "${BASE}/tag/run.log")"
fi

# 6) 工作区不干净时拒绝
setup_repo "${BASE}/dirty"
install_mocks "${BASE}/dirty"
printf 'dirty\n' >"${BASE}/dirty/VERSION"
rc=0
(cd "${BASE}/dirty" && bash scripts/auto_check.sh --dry-run --skip-fetch --renew-days 0) \
  >"${BASE}/dirty/run.log" 2>&1 || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q '工作区不干净' "${BASE}/dirty/run.log"; then
  pass '工作区不干净时安全拒绝'
else
  fail "脏工作区未拒绝 rc=${rc} log=$(cat "${BASE}/dirty/run.log")"
fi

printf 'RESULT pass=%s fail=%s evidence=%s\n' "${PASS}" "${FAIL}" "${BASE}"
[[ "${FAIL}" -eq 0 ]]
