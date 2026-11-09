#!/usr/bin/env bash
# tests/update_sources_test.sh — 维护侧单入口 update_sources.sh：先调度/失败传播，再真 sync→verify→render。
set -euo pipefail
export LC_ALL=C
export LANG=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UPD="${ROOT}/scripts/update_sources.sh"
BASE="${ROOT}/tmp/update-sources-fix/test"
EVIDENCE="${BASE}/evidence.log"
SITE_URL='https://apt-hub.example.test'
PASS=0
FAIL=0
RESTRICTED_WORK=""

mkdir -p -- "${ROOT}/tmp"
rm -rf -- "${BASE}"
mkdir -p -- "${BASE}"

{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "root=${ROOT}"
} >"${EVIDENCE}"

log() {
  printf '%s\n' "$*" | tee -a "${EVIDENCE}"
}

pass() {
  PASS=$((PASS + 1))
  log "PASS $*"
}

fail() {
  FAIL=$((FAIL + 1))
  log "FAIL $*"
}

capture_rc() {
  local logf="$1" rc=0
  shift
  "$@" >"${logf}" 2>&1 || rc=$?
  printf '%s\n' "${rc}"
}

record_rc() {
  local name="$1" rc="$2" expect="$3"
  log "CASE ${name}: exit=${rc} expect=${expect}"
  if [[ "${rc}" -eq "${expect}" ]]; then
    pass "${name}"
  else
    fail "${name} rc=${rc}"
    return 1
  fi
}

sha_of() {
  sha256sum -- "$1" | awk '{print $1}'
}

find_shellcheck() {
  if command -v shellcheck >/dev/null 2>&1; then
    command -v shellcheck
    return 0
  fi
  if [[ -x "${ROOT}/tmp/metadata-C/bin/shellcheck" ]]; then
    printf '%s\n' "${ROOT}/tmp/metadata-C/bin/shellcheck"
    return 0
  fi
  # 独占副本可能无 tmp/metadata-C；回退宿主仓只读 shellcheck
  if [[ -x "/home/ubuntu/workspace/projects/apt-hub/tmp/metadata-C/bin/shellcheck" ]]; then
    printf '%s\n' "/home/ubuntu/workspace/projects/apt-hub/tmp/metadata-C/bin/shellcheck"
    return 0
  fi
  return 1
}

# shellcheck disable=SC2317 # EXIT trap / 失败路径间接调用
kill_own_gpg() {
  local home="$1"
  [[ -d "${home}" ]] || return 0
  gpgconf --homedir "${home}" --kill all >/dev/null 2>&1 || true
}

# shellcheck disable=SC2317 # EXIT trap：失败也恢复自有 0300 fixture
restore_restricted_work() {
  if [[ -n "${RESTRICTED_WORK}" && -d "${RESTRICTED_WORK}" ]]; then
    chmod 0700 -- "${RESTRICTED_WORK}" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2317 # EXIT trap 调用
cleanup_test() {
  restore_restricted_work || true
  kill_own_gpg "${BASE}/gnupg-real" || true
  kill_own_gpg "${BASE}/iso/tmp/gnupg" || true
  kill_own_gpg "${BASE}/real/gnupg-real" || true
  if [[ -n "${LOCK_HOLDER_PID:-}" ]] && kill -0 "${LOCK_HOLDER_PID}" 2>/dev/null; then
    kill "${LOCK_HOLDER_PID}" 2>/dev/null || true
    wait "${LOCK_HOLDER_PID}" 2>/dev/null || true
  fi
}
trap cleanup_test EXIT

# ---------- lint ----------
log "== bash -n / shellcheck =="
if [[ -f "${UPD}" ]]; then
  rc="$(capture_rc "${BASE}/bash-n-upd.log" bash -n -- "${UPD}")"
  record_rc "bash_n_update_sources" "${rc}" 0 || true
else
  fail "missing_update_sources_script"
fi
rc="$(capture_rc "${BASE}/bash-n-test.log" bash -n -- "${ROOT}/tests/update_sources_test.sh")"
record_rc "bash_n_update_sources_test" "${rc}" 0 || true

SC_BIN=""
if SC_BIN="$(find_shellcheck)"; then
  log "shellcheck_bin=${SC_BIN}"
  if [[ -f "${UPD}" ]]; then
    rc="$(capture_rc "${BASE}/shellcheck.gcc" "${SC_BIN}" -f gcc -s bash "${UPD}" "${ROOT}/tests/update_sources_test.sh")"
  else
    rc="$(capture_rc "${BASE}/shellcheck.gcc" "${SC_BIN}" -f gcc -s bash "${ROOT}/tests/update_sources_test.sh")"
  fi
  record_rc "shellcheck" "${rc}" 0 || true
  if [[ "${rc}" -ne 0 ]]; then
    head -n 40 "${BASE}/shellcheck.gcc" | tee -a "${EVIDENCE}" || true
  fi
else
  fail "shellcheck_unavailable"
fi

# ---------- 隔离副本 + 失败桩：调度与退出传播 ----------
log "== 隔离失败桩：调度与退出传播 =="
ISO="${BASE}/iso"
mkdir -p -- "${ISO}/scripts" "${ISO}/tmp" "${ISO}/config"
printf '%s\n' '# fixture README' '<!-- APT-HUB:PACKAGES:BEGIN -->' '尚未完成首次发布' '<!-- APT-HUB:PACKAGES:END -->' >"${ISO}/README.md"
printf '%s\n' '#!/usr/bin/env bash' 'echo fixture add_source' >"${ISO}/scripts/add_source.sh"
chmod 0755 -- "${ISO}/scripts/add_source.sh"
if [[ -f "${UPD}" ]]; then
  cp -- "${UPD}" "${ISO}/scripts/update_sources.sh"
  chmod 0755 -- "${ISO}/scripts/update_sources.sh"
fi

ORDER_LOG="${ISO}/tmp/call-order.log"
: >"${ORDER_LOG}"

write_stub() {
  local name="$1" rc="$2"
  cat >"${ISO}/scripts/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s' '${name}' >>'${ORDER_LOG}'
printf '\\n' >>'${ORDER_LOG}'
printf '%s\\n' "\$*" >>'${ISO}/tmp/${name}.args'
if [[ '${name}' == 'ubuntu_releases.sh' ]]; then
  out=''
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --output) out="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "\$out" ]] || exit 2
  mkdir -p -- "\$(dirname -- "\$out")"
  printf '%s\\n' '{"schema_version":1,"source_url":"fixture","checked_at":"2026-11-06T00:00:00Z","releases":[{"series":"jammy","version":"22.04","release_date":"2022-04-21","eol_date":"2027-06-01"}]}' >"\$out"
fi
if [[ '${name}' == 'sync.sh' && '${rc}' == '0' ]]; then
  out=''
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --output) out="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "\$out" ]] || exit 2
  mkdir -p -- "\$out/repos/alpha"
  printf '%s\\n' '{"schema_version":"2","packages":[],"checked_at":"2026-11-06T00:00:00Z"}' >"\$out/state.json"
  printf '%s\\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'fixture' '-----END PGP PUBLIC KEY BLOCK-----' >"\$out/apt-hub.gpg"
  printf '%s\\n' '<html>stub</html>' >"\$out/index.html"
fi
if [[ '${name}' == 'verify_ubuntu.sh' && '${rc}' == '0' ]]; then
  w=''
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --work-dir) w="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "\$w" ]] || exit 2
  mkdir -p -- "\$w"
  printf '%s\\n' '{"schema_version":1,"ok":true,"results":[]}' >"\$w/summary.json"
fi
if [[ '${name}' == 'render.sh' && '${rc}' == '0' ]]; then
  site=''
  readme=''
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --site) site="\$2"; shift 2 ;;
      --readme) readme="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "\$site" && -n "\$readme" ]] || exit 2
  printf '%s\\n' '<html>rendered</html>' >"\$site/index.html"
  printf '%s\\n' '<!-- APT-HUB:PACKAGES:BEGIN -->' 'stub-pkg' '<!-- APT-HUB:PACKAGES:END -->' >"\$readme"
fi
exit ${rc}
EOF
  chmod 0755 -- "${ISO}/scripts/${name}"
}

PREV_SENT="${ISO}/tmp/previous-sentinel"
README_SENT_SHA=""
mkdir -p -- "${ISO}/tmp/previous" "${ISO}/tmp/gnupg"
chmod 700 -- "${ISO}/tmp/gnupg"
printf 'previous-keep\n' >"${PREV_SENT}"
cp -- "${PREV_SENT}" "${ISO}/tmp/previous/KEEP"
printf 'readme-keep\n' >"${ISO}/README.md.keep"
README_MAIN="${ISO}/README.md"
README_SENT_SHA="$(sha_of "${README_MAIN}")"
PREV_SHA="$(sha_of "${ISO}/tmp/previous/KEEP")"
printf '%s\n' '{"schema_version":"2","packages":[]}' >"${ISO}/config/packages.json"

# shellcheck disable=SC2317 # 经 capture_rc "$@" 间接调用
run_iso() {
  local work="$1"
  shift
  (
    cd -- "${ISO}"
    ./scripts/update_sources.sh \
      --catalog config/packages.json \
      --previous tmp/previous \
      --work-dir "${work}" \
      --gnupghome tmp/gnupg \
      --fingerprint AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
      --site-url "${SITE_URL}" \
      "$@"
  )
}

if [[ ! -f "${UPD}" ]]; then
  fail "red_missing_script_blocks_stub_suite"
else
  printf '%s\n' '{"schema_version":1,"source_url":"fixture","checked_at":"2026-11-06T00:00:00Z","releases":[{"series":"jammy","version":"22.04","release_date":"2022-04-21","eol_date":"2027-06-01"}]}' >"${ISO}/tmp/releases-in.json"

  # sync 失败：previous/README 不变，无 success
  write_stub ubuntu_releases.sh 0
  write_stub sync.sh 1
  write_stub verify_ubuntu.sh 0
  write_stub render.sh 0
  rm -rf -- "${ISO}/tmp/work-sync-fail"
  mkdir -p -- "${ISO}/tmp/work-sync-fail"
  : >"${ORDER_LOG}"
  rc="$(capture_rc "${BASE}/stub-sync-fail.log" run_iso tmp/work-sync-fail --releases tmp/releases-in.json)"
  record_rc "stub_sync_fail_rc" "${rc}" 1 || true
  if [[ "$(sha_of "${ISO}/tmp/previous/KEEP")" == "${PREV_SHA}" && "$(sha_of "${README_MAIN}")" == "${README_SENT_SHA}" ]]; then
    pass "stub_sync_fail_sentinels_unchanged"
  else
    fail "stub_sync_fail_sentinels_changed"
  fi
  if [[ ! -e "${ISO}/tmp/work-sync-fail/success.json" ]]; then
    pass "stub_sync_fail_no_success"
  else
    fail "stub_sync_fail_has_success"
  fi
  if grep -qx 'sync.sh' "${ORDER_LOG}" && ! grep -qx 'verify_ubuntu.sh' "${ORDER_LOG}"; then
    pass "stub_sync_fail_stops_before_verify"
  else
    fail "stub_sync_fail_order=$(tr '\n' ',' <"${ORDER_LOG}")"
  fi

  # verify 失败
  write_stub sync.sh 0
  write_stub verify_ubuntu.sh 1
  write_stub render.sh 0
  rm -rf -- "${ISO}/tmp/work-verify-fail"
  mkdir -p -- "${ISO}/tmp/work-verify-fail"
  : >"${ORDER_LOG}"
  rc="$(capture_rc "${BASE}/stub-verify-fail.log" run_iso tmp/work-verify-fail --releases tmp/releases-in.json)"
  record_rc "stub_verify_fail_rc" "${rc}" 1 || true
  if [[ "$(sha_of "${ISO}/tmp/previous/KEEP")" == "${PREV_SHA}" && "$(sha_of "${README_MAIN}")" == "${README_SENT_SHA}" && ! -e "${ISO}/tmp/work-verify-fail/success.json" ]]; then
    pass "stub_verify_fail_sentinels_no_success"
  else
    fail "stub_verify_fail_sentinel_or_success"
  fi
  if grep -qx 'sync.sh' "${ORDER_LOG}" && grep -qx 'verify_ubuntu.sh' "${ORDER_LOG}" && ! grep -qx 'render.sh' "${ORDER_LOG}"; then
    pass "stub_verify_fail_stops_before_render"
  else
    fail "stub_verify_fail_order=$(tr '\n' ',' <"${ORDER_LOG}")"
  fi

  # render 失败
  write_stub verify_ubuntu.sh 0
  write_stub render.sh 1
  rm -rf -- "${ISO}/tmp/work-render-fail"
  mkdir -p -- "${ISO}/tmp/work-render-fail"
  : >"${ORDER_LOG}"
  rc="$(capture_rc "${BASE}/stub-render-fail.log" run_iso tmp/work-render-fail --releases tmp/releases-in.json)"
  record_rc "stub_render_fail_rc" "${rc}" 1 || true
  if [[ "$(sha_of "${ISO}/tmp/previous/KEEP")" == "${PREV_SHA}" && "$(sha_of "${README_MAIN}")" == "${README_SENT_SHA}" && ! -e "${ISO}/tmp/work-render-fail/success.json" ]]; then
    pass "stub_render_fail_sentinels_no_success"
  else
    fail "stub_render_fail_sentinel_or_success"
  fi

  # 无 --releases 时调用 ubuntu_releases，再 sync→verify→render
  write_stub render.sh 0
  rm -rf -- "${ISO}/tmp/work-ok-stub"
  mkdir -p -- "${ISO}/tmp/work-ok-stub"
  : >"${ORDER_LOG}"
  rc="$(capture_rc "${BASE}/stub-ok.log" run_iso tmp/work-ok-stub)"
  record_rc "stub_full_ok_rc" "${rc}" 0 || true
  if [[ -f "${ISO}/tmp/work-ok-stub/success.json" ]] \
    && jq -e '.ok==true and (.site|type=="string") and (.summary|type=="string")' "${ISO}/tmp/work-ok-stub/success.json" >/dev/null; then
    pass "stub_full_ok_success_json"
  else
    fail "stub_full_ok_success_json"
  fi
  order="$(tr '\n' ' ' <"${ORDER_LOG}" | sed 's/ *$//')"
  if [[ "${order}" == "ubuntu_releases.sh sync.sh verify_ubuntu.sh render.sh" ]]; then
    pass "stub_full_ok_call_order"
  else
    fail "stub_full_ok_call_order got=${order}"
  fi
  if [[ -f "${ISO}/tmp/work-ok-stub/site/add_source.sh" ]] \
    && [[ "$(stat -c '%a' "${ISO}/tmp/work-ok-stub/site/add_source.sh")" == 644 ]] \
    && cmp -s "${ISO}/scripts/add_source.sh" "${ISO}/tmp/work-ok-stub/site/add_source.sh"; then
    pass "stub_full_ok_add_source_0644"
  else
    fail "stub_full_ok_add_source"
  fi
  if [[ "$(sha_of "${ISO}/tmp/previous/KEEP")" == "${PREV_SHA}" && "$(sha_of "${README_MAIN}")" == "${README_SENT_SHA}" ]]; then
    pass "stub_full_ok_main_readme_previous_untouched"
  else
    fail "stub_full_ok_touched_main_assets"
  fi

  # 拒非空 work（用户文件），拒绝前无副作用
  write_stub sync.sh 0
  write_stub verify_ubuntu.sh 0
  write_stub render.sh 0
  rm -rf -- "${ISO}/tmp/work-nonempty"
  mkdir -p -- "${ISO}/tmp/work-nonempty"
  printf 'user-file\n' >"${ISO}/tmp/work-nonempty/USER"
  : >"${ORDER_LOG}"
  rc="$(capture_rc "${BASE}/stub-nonempty.log" run_iso tmp/work-nonempty --releases tmp/releases-in.json)"
  record_rc "reject_nonempty_work_rc" "${rc}" 1 || true
  if [[ -f "${ISO}/tmp/work-nonempty/USER" ]] && [[ ! -s "${ORDER_LOG}" ]] && [[ ! -e "${ISO}/tmp/work-nonempty/success.json" ]]; then
    pass "reject_nonempty_work_no_side_effect"
  else
    fail "reject_nonempty_work_side_effect"
  fi

  # 完整入口：已有用户文件 + work 0300（不可列），失败且文件内容/权限/链接不变
  write_stub sync.sh 0
  write_stub verify_ubuntu.sh 0
  write_stub render.sh 0
  RESTRICTED_WORK="${ISO}/tmp/work-restricted"
  rm -rf -- "${RESTRICTED_WORK}" "${RESTRICTED_WORK}.lock"
  mkdir -p -- "${RESTRICTED_WORK}"
  printf 'user-releases-keep\n' >"${RESTRICTED_WORK}/releases.json"
  printf 'user-owned-keep\n' >"${RESTRICTED_WORK}/.apt-hub-update.owned"
  ln -s -- releases.json "${RESTRICTED_WORK}/user-link"
  chmod 0644 -- "${RESTRICTED_WORK}/releases.json" "${RESTRICTED_WORK}/.apt-hub-update.owned"
  USER_REL_SHA="$(sha_of "${RESTRICTED_WORK}/releases.json")"
  USER_OWN_SHA="$(sha_of "${RESTRICTED_WORK}/.apt-hub-update.owned")"
  USER_REL_MODE="$(stat -c '%a' "${RESTRICTED_WORK}/releases.json")"
  USER_OWN_MODE="$(stat -c '%a' "${RESTRICTED_WORK}/.apt-hub-update.owned")"
  USER_LINK_TARGET="$(readlink -- "${RESTRICTED_WORK}/user-link")"
  chmod 0300 -- "${RESTRICTED_WORK}"
  FIND_PROBE_RC=0
  find -- "${RESTRICTED_WORK}" -mindepth 1 -maxdepth 1 -print -quit >/dev/null 2>&1 || FIND_PROBE_RC=$?
  : >"${ORDER_LOG}"
  if [[ "${FIND_PROBE_RC}" -ne 0 ]]; then
    rc="$(capture_rc "${BASE}/stub-restricted-work.log" run_iso tmp/work-restricted --releases tmp/releases-in.json)"
    record_rc "reject_unlistable_work_rc" "${rc}" 1 || true
  else
    # root 等无法触发权限失败：显式 find 失败桩补足，不得静默跳过算 PASS
    log "unlistable_work_perm_ineffective find_probe_rc=${FIND_PROBE_RC}; using find-fail stub"
    restore_restricted_work
    mkdir -p -- "${ISO}/tmp/bin-find-perm"
    cat >"${ISO}/tmp/bin-find-perm/find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# 模拟不可列目录：stdout 空、exit 1
exit 1
EOF
    chmod 0755 -- "${ISO}/tmp/bin-find-perm/find"
    rc="$(PATH="${ISO}/tmp/bin-find-perm:${PATH}" capture_rc "${BASE}/stub-restricted-work.log" run_iso tmp/work-restricted --releases tmp/releases-in.json)"
    record_rc "reject_unlistable_work_rc" "${rc}" 1 || true
  fi
  restore_restricted_work
  if [[ "${rc}" -ne 0 ]] \
    && [[ ! -s "${ORDER_LOG}" ]] \
    && [[ ! -e "${RESTRICTED_WORK}/success.json" ]] \
    && [[ -f "${RESTRICTED_WORK}/releases.json" ]] \
    && [[ -f "${RESTRICTED_WORK}/.apt-hub-update.owned" ]] \
    && [[ -L "${RESTRICTED_WORK}/user-link" ]] \
    && [[ "$(sha_of "${RESTRICTED_WORK}/releases.json")" == "${USER_REL_SHA}" ]] \
    && [[ "$(sha_of "${RESTRICTED_WORK}/.apt-hub-update.owned")" == "${USER_OWN_SHA}" ]] \
    && [[ "$(stat -c '%a' "${RESTRICTED_WORK}/releases.json")" == "${USER_REL_MODE}" ]] \
    && [[ "$(stat -c '%a' "${RESTRICTED_WORK}/.apt-hub-update.owned")" == "${USER_OWN_MODE}" ]] \
    && [[ "$(readlink -- "${RESTRICTED_WORK}/user-link")" == "${USER_LINK_TARGET}" ]]; then
    pass "reject_unlistable_work_files_unchanged"
  else
    fail "reject_unlistable_work_files_changed order=$(tr '\n' ',' <"${ORDER_LOG}")"
    log "restricted_after_listing=$(ls -la "${RESTRICTED_WORK}" 2>&1 || true)"
  fi
  RESTRICTED_WORK=""

  # find exit 2 且 stdout 空：必须拒绝（不可当空）
  write_stub sync.sh 0
  write_stub verify_ubuntu.sh 0
  write_stub render.sh 0
  rm -rf -- "${ISO}/tmp/work-find-exit2" "${ISO}/tmp/work-find-exit2.lock"
  mkdir -p -- "${ISO}/tmp/work-find-exit2" "${ISO}/tmp/bin-find-exit2"
  cat >"${ISO}/tmp/bin-find-exit2/find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# stdout 保持空，exit 2
exit 2
EOF
  chmod 0755 -- "${ISO}/tmp/bin-find-exit2/find"
  : >"${ORDER_LOG}"
  rc="$(PATH="${ISO}/tmp/bin-find-exit2:${PATH}" capture_rc "${BASE}/stub-find-exit2.log" run_iso tmp/work-find-exit2 --releases tmp/releases-in.json)"
  record_rc "reject_find_exit2_empty_stdout_rc" "${rc}" 1 || true
  if [[ "${rc}" -ne 0 ]] && [[ ! -s "${ORDER_LOG}" ]] && [[ ! -e "${ISO}/tmp/work-find-exit2/success.json" ]] \
    && [[ ! -e "${ISO}/tmp/work-find-exit2/.apt-hub-update.owned" ]]; then
    pass "reject_find_exit2_no_side_effect"
  else
    fail "reject_find_exit2_side_effect order=$(tr '\n' ',' <"${ORDER_LOG}")"
  fi

  # 拒 work 与 previous 重叠
  rc="$(capture_rc "${BASE}/stub-overlap.log" run_iso tmp/previous --releases tmp/releases-in.json)"
  record_rc "reject_work_previous_overlap_rc" "${rc}" 1 || true
  if [[ "$(sha_of "${ISO}/tmp/previous/KEEP")" == "${PREV_SHA}" ]]; then
    pass "reject_overlap_previous_intact"
  else
    fail "reject_overlap_previous_changed"
  fi

  # 拒 work 符号链接
  rm -rf -- "${ISO}/tmp/work-link-target"
  mkdir -p -- "${ISO}/tmp/work-link-target"
  ln -s work-link-target "${ISO}/tmp/work-symlink"
  rc="$(capture_rc "${BASE}/stub-symlink-work.log" run_iso tmp/work-symlink --releases tmp/releases-in.json)"
  record_rc "reject_work_symlink_rc" "${rc}" 1 || true

  # 同 work 并发锁：先占锁，第二进程拒绝，不杀持锁进程
  LOCK_WORK="${ISO}/tmp/work-lock"
  rm -rf -- "${LOCK_WORK}" "${LOCK_WORK}.lock"
  mkdir -p -- "${LOCK_WORK}"
  : >"${LOCK_WORK}.lock"
  (
    flock 9
    printf 'holder-alive\n' >"${ISO}/tmp/lock-holder.flag"
    sleep 30
  ) 9>>"${LOCK_WORK}.lock" &
  LOCK_HOLDER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "${ISO}/tmp/lock-holder.flag" ]] && break
    sleep 0.1
  done
  : >"${ORDER_LOG}"
  rc="$(capture_rc "${BASE}/stub-lock.log" run_iso tmp/work-lock --releases tmp/releases-in.json)"
  record_rc "reject_concurrent_lock_rc" "${rc}" 1 || true
  if kill -0 "${LOCK_HOLDER_PID}" 2>/dev/null; then
    pass "concurrent_lock_holder_still_alive"
  else
    fail "concurrent_lock_holder_killed"
  fi
  kill "${LOCK_HOLDER_PID}" 2>/dev/null || true
  wait "${LOCK_HOLDER_PID}" 2>/dev/null || true
  LOCK_HOLDER_PID=""
  if [[ ! -s "${ORDER_LOG}" ]]; then
    pass "concurrent_lock_no_child_scripts"
  else
    fail "concurrent_lock_ran_scripts"
  fi
fi

# ---------- 真实单入口：sync→verify→render ----------
log "== 真实 sync → verify → render =="
REAL="${BASE}/real"
mkdir -p -- "${REAL}/bin" "${REAL}/debs" "${REAL}/api" "${REAL}/empty-prev" "${REAL}/gnupg-real"
chmod 700 -- "${REAL}/gnupg-real"

# fixture curl（非真实网络证据）
cat >"${REAL}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
proto=""
proto_redir=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  a="${args[$i]}"
  case "$a" in
    -o|--output) i=$((i + 1)); out="${args[$i]}" ;;
    --output=*) out="${a#--output=}" ;;
    --proto) i=$((i + 1)); proto="${args[$i]}" ;;
    --proto=*) proto="${a#--proto=}" ;;
    --proto-redir) i=$((i + 1)); proto_redir="${args[$i]}" ;;
    --proto-redir=*) proto_redir="${a#--proto-redir=}" ;;
    https://*) url="$a" ;;
    http://*)
      printf 'fixture-curl: 拒绝非 HTTPS URL %s\n' "$a" >&2
      exit 1
      ;;
    --url) i=$((i + 1)); url="${args[$i]}" ;;
    --url=*) url="${a#--url=}" ;;
  esac
  i=$((i + 1))
done
if [[ "${proto}" != "=https" || "${proto_redir}" != "=https" ]]; then
  printf 'fixture-curl: 需要 --proto =https 与 --proto-redir =https\n' >&2
  exit 1
fi
[[ -n "${url}" ]] || { printf 'fixture-curl: missing url\n' >&2; exit 1; }
map="${CURL_FIXTURE_MAP:?}"
file="$(awk -F '\t' -v u="${url}" '$1==u {print $2; exit}' "${map}")"
if [[ -z "${file}" || ! -f "${file}" ]]; then
  printf 'fixture-curl: 无夹具映射 %s\n' "${url}" >&2
  exit 1
fi
if [[ -n "${out}" ]]; then
  cp -- "${file}" "${out}"
else
  cat -- "${file}"
fi
EOF
chmod 755 -- "${REAL}/bin/curl"

build_deb() {
  local pkg="$1" ver="$2" arch="$3" dest="$4"
  local root="${REAL}/debroot/${pkg}-${ver}-${arch}"
  rm -rf -- "${root}"
  mkdir -p -- "${root}/DEBIAN" "${root}/usr/share/doc/${pkg}"
  cat >"${root}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${ver}
Architecture: ${arch}
Maintainer: apt-hub-test <apt-hub-test@invalid>
Depends: libc6
Description: update_sources fixture ${pkg}
EOF
  printf 'payload %s %s %s\n' "${pkg}" "${ver}" "${arch}" >"${root}/usr/share/doc/${pkg}/README"
  dpkg-deb --build --root-owner-group -- "${root}" "${dest}" >/dev/null
}

build_deb alpha 1.0.0 amd64 "${REAL}/debs/alpha-1.0.0-x86_64.deb"
build_deb alpha 1.0.0 arm64 "${REAL}/debs/alpha-1.0.0-aarch64.deb"
amd_size="$(stat -c '%s' -- "${REAL}/debs/alpha-1.0.0-x86_64.deb")"
arm_size="$(stat -c '%s' -- "${REAL}/debs/alpha-1.0.0-aarch64.deb")"
amd_sha="$(sha_of "${REAL}/debs/alpha-1.0.0-x86_64.deb")"
arm_sha="$(sha_of "${REAL}/debs/alpha-1.0.0-aarch64.deb")"
jq -n \
  --arg tag '1.0.0' \
  --arg html 'https://github.com/fixture/alpha/releases/tag/1.0.0' \
  --arg n1 'alpha-1.0.0-x86_64.deb' --arg n2 'alpha-1.0.0-aarch64.deb' \
  --argjson s1 "${amd_size}" --argjson s2 "${arm_size}" \
  --arg u1 'https://github.com/fixture/alpha/releases/download/1.0.0/alpha-1.0.0-x86_64.deb' \
  --arg u2 'https://github.com/fixture/alpha/releases/download/1.0.0/alpha-1.0.0-aarch64.deb' \
  --arg d1 "sha256:${amd_sha}" --arg d2 "sha256:${arm_sha}" \
  '{
    tag_name:$tag, html_url:$html, draft:false, prerelease:false,
    assets:[
      {name:$n1,size:$s1,browser_download_url:$u1,digest:$d1},
      {name:$n2,size:$s2,browser_download_url:$u2,digest:$d2}
    ]
  }' >"${REAL}/api/alpha.json"

: >"${REAL}/curl-map.tsv"
printf '%s\t%s\n' \
  'https://api.github.com/repos/fixture/alpha/releases/latest' "${REAL}/api/alpha.json" \
  'https://github.com/fixture/alpha/releases/download/1.0.0/alpha-1.0.0-x86_64.deb' "${REAL}/debs/alpha-1.0.0-x86_64.deb" \
  'https://github.com/fixture/alpha/releases/download/1.0.0/alpha-1.0.0-aarch64.deb' "${REAL}/debs/alpha-1.0.0-aarch64.deb" \
  >>"${REAL}/curl-map.tsv"
export CURL_FIXTURE_MAP="${REAL}/curl-map.tsv"

jq -n '{
  schema_version:1,
  source_url:"https://salsa.debian.org/debian/distro-info-data/-/raw/main/ubuntu.csv",
  checked_at:"2026-11-06T00:00:00Z",
  releases:[
    {series:"jammy",version:"22.04",release_date:"2022-04-21",eol_date:"2027-06-01"}
  ]
}' >"${REAL}/releases.json"

jq -n '{
  schema_version:"2",
  packages:[
    {
      id:"alpha", repository:"fixture/alpha", package:"alpha",
      description:"update_sources 真链路夹具", source_url:"https://github.com/fixture/alpha",
      license:"MIT", ubuntu_series:["jammy"],
      architectures:{
        amd64:"^alpha-[0-9][^-]*-x86_64\\.deb$",
        arm64:"^alpha-[0-9][^-]*-aarch64\\.deb$"
      }
    }
  ]
}' >"${REAL}/catalog.json"

# 主 README / previous 哨兵（真实入口不得改它们；previous 目录保持空）
MAIN_README_SHA="$(sha_of "${ROOT}/README.md")"
PUBLISHED_SHA="$(sha_of "${ROOT}/data/published.json")"
printf 'prev-real\n' >"${REAL}/previous.sentinel"
PREV_REAL_SHA="$(sha_of "${REAL}/previous.sentinel")"

kill_own_gpg "${REAL}/gnupg-real"
rm -rf -- "${REAL}/gnupg-real"
mkdir -m 700 -- "${REAL}/gnupg-real"
printf 'allow-loopback-pinentry\n' >"${REAL}/gnupg-real/gpg-agent.conf"
gpg --homedir "${REAL}/gnupg-real" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "apt-hub update-sources fixture <apt-hub-update-sources@invalid>" ed25519 sign never
FP="$(gpg --homedir "${REAL}/gnupg-real" --batch --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')"
log "real_fingerprint=${FP}"
[[ "${#FP}" -eq 40 ]]

WORK_REAL="${BASE}/work-real"
rm -rf -- "${WORK_REAL}" "${WORK_REAL}.lock"
mkdir -p -- "${WORK_REAL}"

if [[ ! -f "${UPD}" ]]; then
  fail "red_real_chain_missing_script"
else
  export PATH="${REAL}/bin:${PATH}"
  rc="$(capture_rc "${BASE}/real-chain.log" \
    "${UPD}" \
      --catalog "${REAL}/catalog.json" \
      --previous "${REAL}/empty-prev" \
      --work-dir "${WORK_REAL}" \
      --gnupghome "${REAL}/gnupg-real" \
      --fingerprint "${FP}" \
      --site-url "${SITE_URL}" \
      --releases "${REAL}/releases.json")"
  cat "${BASE}/real-chain.log" >>"${EVIDENCE}"
  echo "real_chain_rc=${rc}" | tee -a "${EVIDENCE}"
  record_rc "real_chain_rc" "${rc}" 0 || true

  if [[ "${rc}" -eq 0 ]]; then
    if [[ -f "${WORK_REAL}/success.json" ]] \
      && jq -e '.ok==true' "${WORK_REAL}/success.json" >/dev/null; then
      pass "real_chain_success_ok_true"
      jq -c '{ok,site,summary,readme}' "${WORK_REAL}/success.json" | tee -a "${EVIDENCE}"
    else
      fail "real_chain_success_missing"
    fi
    if [[ -f "${WORK_REAL}/site/state.json" && -f "${WORK_REAL}/verify/summary.json" && -f "${WORK_REAL}/README.md" ]]; then
      pass "real_chain_artifacts_present"
    else
      fail "real_chain_artifacts_missing"
    fi
    if jq -e '.ok==true and (.results|length)==2 and all(.results[]; .ok==true)' "${WORK_REAL}/verify/summary.json" >/dev/null; then
      pass "real_chain_verify_summary"
    else
      fail "real_chain_verify_summary $(cat "${WORK_REAL}/verify/summary.json" 2>/dev/null || true)"
    fi
    if [[ -f "${WORK_REAL}/site/add_source.sh" ]] \
      && [[ "$(stat -c '%a' "${WORK_REAL}/site/add_source.sh")" == 644 ]] \
      && cmp -s "${ROOT}/scripts/add_source.sh" "${WORK_REAL}/site/add_source.sh"; then
      pass "real_chain_add_source_from_checkout"
    else
      fail "real_chain_add_source"
    fi
    if [[ ! -e "$(find "${WORK_REAL}/site" -name '*.deb' -print -quit)" ]]; then
      pass "real_chain_site_no_deb"
    else
      fail "real_chain_site_has_deb"
    fi
    if grep -Fq 'alpha' "${WORK_REAL}/README.md" && grep -Fq 'alpha' "${WORK_REAL}/site/index.html"; then
      pass "real_chain_render_mentions_alpha"
    else
      fail "real_chain_render_content"
    fi
    SITE_SHA="$(sha_of "${WORK_REAL}/site/state.json")"
    SUM_SHA="$(sha_of "${WORK_REAL}/verify/summary.json")"
    README_COPY_SHA="$(sha_of "${WORK_REAL}/README.md")"
    log "actualdelta site/state.json sha256=${SITE_SHA}"
    log "actualdelta verify/summary.json sha256=${SUM_SHA}"
    log "actualdelta work/README.md sha256=${README_COPY_SHA}"
  fi

  if [[ "$(sha_of "${ROOT}/README.md")" == "${MAIN_README_SHA}" ]]; then
    pass "real_chain_root_readme_unchanged"
  else
    fail "real_chain_root_readme_changed"
  fi
  if [[ "$(sha_of "${ROOT}/data/published.json")" == "${PUBLISHED_SHA}" ]]; then
    pass "real_chain_published_unchanged"
  else
    fail "real_chain_published_changed"
  fi
  if [[ "$(sha_of "${REAL}/previous.sentinel")" == "${PREV_REAL_SHA}" ]] \
    && [[ -z "$(find -- "${REAL}/empty-prev" -mindepth 1 -print -quit)" ]]; then
    pass "real_chain_previous_sentinel_unchanged"
  else
    fail "real_chain_previous_changed"
  fi
fi

# ---------- workflow 接线静态断言 ----------
log "== workflow 接线 =="
PUB="${ROOT}/.github/workflows/ubuntu-publish.yml"
TST="${ROOT}/.github/workflows/ubuntu-test.yml"
if grep -Fq 'scripts/update_sources.sh' "${PUB}"; then
  pass "publish_calls_update_sources"
else
  fail "publish_missing_update_sources"
fi
if awk '
  /^      - name: 生成发行版数据并构建候选站点$/ {hit=1; next}
  hit && /^      - name:/ {exit}
  hit && /chmod / {next}
  hit && /(^|[[:space:]])scripts\/sync\.sh([[:space:]]|\\|$)/ {bad=1}
  hit && /(^|[[:space:]])scripts\/verify_ubuntu\.sh([[:space:]]|\\|$)/ {bad=1}
  hit && /(^|[[:space:]])scripts\/ubuntu_releases\.sh([[:space:]]|\\|$)/ {bad=1}
  hit && /(^|[[:space:]])scripts\/render\.sh([[:space:]]|\\|$)/ {bad=1}
  END { exit bad+0 }
' "${PUB}"; then
  pass "publish_build_step_single_entry_only"
else
  fail "publish_build_step_still_serial_scripts"
fi
if grep -Fq 'tests/update_sources_test.sh' "${TST}"; then
  pass "ci_runs_update_sources_test"
else
  fail "ci_missing_update_sources_test"
fi
if grep -Fq 'scripts/update_sources.sh' "${TST}"; then
  pass "ci_chmods_update_sources"
else
  fail "ci_missing_chmod_update_sources"
fi

# Go 尚未接入：报告侧在结果文件写明；此处断言生产 catalog 仍仅 rustdesk、入口未引入 go 打包
if jq -e '[.packages[].id] == ["rustdesk"]' "${ROOT}/config/packages.json" >/dev/null; then
  pass "catalog_still_rustdesk_only_go_pending"
else
  fail "catalog_unexpected_packages"
fi
if ! grep -Eiq 'golang|go-lang|go\.dev' "${UPD}" 2>/dev/null; then
  pass "update_sources_no_go_packaging"
else
  fail "update_sources_mentions_go_packaging"
fi

kill_own_gpg "${REAL}/gnupg-real"

log "RESULT pass=${PASS} fail=${FAIL}"
echo "pass=${PASS} fail=${FAIL}"
if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi
exit 0
