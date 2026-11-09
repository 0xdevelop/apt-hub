#!/usr/bin/env bash
# 真实抽取 ubuntu-publish.yml 的关键 run 段：无口令签名预检与发布者身份。
# 证据只写 tmp/final-fix；密钥仅本目录测试身份；不读用户凭证、不走长网络矩阵。
# 抽取用 awk 按 job/step/run 缩进定位，不引入额外 YAML 运行时。
set -euo pipefail
export LC_ALL=C
export LANG=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PUB="${ROOT}/.github/workflows/ubuntu-publish.yml"
EVIDENCE="${ROOT}/tmp/final-fix/workflow-test"
PASS=0
FAIL=0
OWNED_HOMES=()
OWNED_SANDBOX_GNUPG=()

mkdir -p -- "${ROOT}/tmp"
rm -rf -- "${EVIDENCE}"
mkdir -p -- "${EVIDENCE}/bin" "${EVIDENCE}/keys" "${EVIDENCE}/runs"

log() { printf '%s\n' "$*" | tee -a "${EVIDENCE}/test.log"; }
pass() { PASS=$((PASS + 1)); log "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL: $*"; }

path_is_under_evidence() {
  case "$1" in
    "${EVIDENCE}"|"${EVIDENCE}"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# 仅清理本测试登记的真实目录；拒 symlink，绝不碰项目 tmp/gnupg。
assert_owned_real_dir() {
  local p="$1"
  if ! path_is_under_evidence "${p}"; then
    log "refuse scrub outside evidence: ${p}"
    return 1
  fi
  if [[ -L "${p}" ]]; then
    log "refuse scrub symlink: ${p}"
    return 1
  fi
  if [[ ! -d "${p}" ]]; then
    return 1
  fi
  return 0
}

cleanup_gpg_home() {
  local home="$1"
  if [[ -d "${home}" && ! -L "${home}" ]]; then
    gpgconf --homedir "${home}" --kill gpg-agent >/dev/null 2>&1 || true
  fi
}

register_owned_home() {
  local home="$1"
  if ! path_is_under_evidence "${home}"; then
    echo "home 必须落在证据目录: ${home}" >&2
    exit 99
  fi
  if [[ -L "${home}" ]]; then
    echo "拒绝 symlink home: ${home}" >&2
    exit 99
  fi
  OWNED_HOMES+=("${home}")
}

register_owned_sandbox_gnupg() {
  local home="$1"
  if ! path_is_under_evidence "${home}"; then
    echo "sandbox gnupg 必须落在证据目录: ${home}" >&2
    exit 99
  fi
  if [[ -e "${home}" && -L "${home}" ]]; then
    echo "拒绝 symlink sandbox gnupg: ${home}" >&2
    exit 99
  fi
  OWNED_SANDBOX_GNUPG+=("${home}")
}

scrub_owned_home() {
  local home="$1"
  assert_owned_real_dir "${home}" || return 0
  cleanup_gpg_home "${home}"
  rm -rf -- \
    "${home}/private-keys-v1.d" \
    "${home}/openpgp-revocs.d" 2>/dev/null || true
  rm -f -- "${home}/batch" "${home}/fixture_protect.txt" 2>/dev/null || true
  # 目录内偶然残留的 armor / 密钥材料
  find "${home}" -maxdepth 1 -type f \( -name '*.asc' -o -name '*.key' \) -delete 2>/dev/null || true
}

scrub_test_secrets() {
  local home f
  for home in "${OWNED_HOMES[@]+"${OWNED_HOMES[@]}"}"; do
    scrub_owned_home "${home}"
  done
  for home in "${OWNED_SANDBOX_GNUPG[@]+"${OWNED_SANDBOX_GNUPG[@]}"}"; do
    scrub_owned_home "${home}"
  done
  if assert_owned_real_dir "${EVIDENCE}/keys"; then
    for f in "${EVIDENCE}/keys/"*.asc; do
      [[ -e "${f}" ]] || continue
      if [[ -L "${f}" ]]; then
        log "refuse remove symlink asc: ${f}"
        continue
      fi
      rm -f -- "${f}"
    done
    if [[ -f "${EVIDENCE}/keys/fixture_protect.txt" && ! -L "${EVIDENCE}/keys/fixture_protect.txt" ]]; then
      rm -f -- "${EVIDENCE}/keys/fixture_protect.txt"
    fi
  fi
}

trap 'scrub_test_secrets' EXIT

# --- 从真实 workflow 按 job/step name 与 run 缩进抽取；缺失/重复明确拒绝 ---
# 第4参可选：workflow 路径；默认 ubuntu-publish.yml，旧调用不变。
extract_step_run() {
  local job="$1" step_name="$2" out="$3"
  local wf="${4:-${PUB}}"
  local awk_rc=0
  local had_errexit=0
  [[ $- == *e* ]] && had_errexit=1
  set +e
  awk -v job="${job}" -v step="${step_name}" '
    BEGIN { in_jobs=0; in_job=0; in_step=0; job_seen=0; hits=0; grabbing=0; body=0 }
    /^jobs:[[:space:]]*$/ { in_jobs=1; next }
    in_jobs && /^  [A-Za-z0-9_]+:[[:space:]]*$/ {
      name=$1
      sub(/:$/, "", name)
      if (name == job) {
        in_job=1
        job_seen=1
        in_step=0
        grabbing=0
      } else if (in_job) {
        in_job=0
        in_step=0
        grabbing=0
      }
      next
    }
    in_job && /^      - name:[[:space:]]+/ {
      line=$0
      sub(/^      - name:[[:space:]]+/, "", line)
      if (line == step) {
        hits++
        if (hits > 1) {
          print "duplicate step: " step > "/dev/stderr"
          exit 4
        }
        in_step=1
        grabbing=0
      } else {
        in_step=0
        grabbing=0
      }
      next
    }
    in_step && /^        run:[[:space:]]*\|[[:space:]]*$/ {
      grabbing=1
      next
    }
    grabbing {
      if ($0 == "" || $0 ~ /^          /) {
        sub(/^          /, "", $0)
        print
        body=1
        next
      }
      grabbing=0
      in_step=0
    }
    END {
      if (!job_seen) {
        print "missing job: " job > "/dev/stderr"
        exit 2
      }
      if (hits == 0) {
        print "missing step: " step > "/dev/stderr"
        exit 3
      }
      if (hits != 1) {
        print "duplicate step: " step > "/dev/stderr"
        exit 4
      }
      if (!body) {
        print "missing step.run body: " step > "/dev/stderr"
        exit 5
      }
    }
  ' "${wf}" >"${out}"
  awk_rc=$?
  if [[ "${had_errexit}" -eq 1 ]]; then
    set -e
  else
    set +e
  fi
  if [[ "${awk_rc}" -ne 0 ]]; then
    return "${awk_rc}"
  fi
  if [[ ! -s "${out}" ]]; then
    echo "empty step.run: ${step_name}" >&2
    return 5
  fi
  printf 'extracted_bytes=%s\n' "$(wc -c <"${out}" | tr -d '[:space:]')"
}

# --- 生成仅用于本测试的密钥（口令不进 argv；第4参为指纹变量名，避免 $() 子壳丢 OWNED_HOMES） ---
gen_key() {
  local home="$1" email="$2" pass_file="$3" fpr_var="$4"
  local fpr=""
  cleanup_gpg_home "${home}"
  rm -rf -- "${home}"
  mkdir -p -- "${home}"
  chmod 700 -- "${home}"
  register_owned_home "${home}"
  printf '%s\n' 'pinentry-mode loopback' >"${home}/gpg.conf"
  printf '%s\n' 'allow-loopback-pinentry' >"${home}/gpg-agent.conf"
  chmod 600 -- "${home}/gpg.conf" "${home}/gpg-agent.conf"
  local batch="${home}/batch"
  if [[ -n "${pass_file}" ]]; then
    cat >"${batch}" <<EOF
%echo generating-enc
Key-Type: RSA
Key-Length: 2048
Name-Real: apt-hub-workflow-test
Name-Email: ${email}
Expire-Date: 0
Passphrase: $(cat -- "${pass_file}")
%commit
%echo done
EOF
  else
    cat >"${batch}" <<EOF
%echo generating-empty
Key-Type: RSA
Key-Length: 2048
Name-Real: apt-hub-workflow-test
Name-Email: ${email}
Expire-Date: 0
%no-protection
%commit
%echo done
EOF
  fi
  chmod 600 -- "${batch}"
  GNUPGHOME="${home}" gpg --batch --pinentry-mode loopback --generate-key "${batch}" \
    >"${home}/gen.log" 2>&1
  chmod 600 -- "${home}/gen.log" 2>/dev/null || true
  # batch 含口令时尽快删，指纹仍可从 log / list 得到
  rm -f -- "${batch}"
  fpr="$(
    GNUPGHOME="${home}" gpg --batch --with-colons --list-secret-keys 2>/dev/null \
      | awk -F: '/^fpr:/{print toupper($10); exit}'
  )"
  printf -v "${fpr_var}" '%s' "${fpr}"
}

armor_secret() {
  local home="$1" out="$2" pass_file="${3:-}"
  if [[ -n "${pass_file}" ]]; then
    # 口令仅经 fd 传入，不放 argv。
    GNUPGHOME="${home}" gpg --batch --pinentry-mode loopback --passphrase-fd 3 \
      --export-secret-keys --armor 3<"${pass_file}" >"${out}"
  else
    GNUPGHOME="${home}" gpg --batch --export-secret-keys --armor >"${out}"
  fi
  chmod 600 -- "${out}"
}

run_gpg_import_step() {
  local key_file="$1" out_dir="$2"
  local script="${EVIDENCE}/runs/gpg-import.sh"
  local logf="${out_dir}/run.log"
  local rcfile="${out_dir}/rc"
  local ghub_out="${out_dir}/github_output"
  local sandbox="${out_dir}/sandbox"
  local sand_gnupg="${sandbox}/tmp/gnupg"
  local key_body
  mkdir -p -- "${out_dir}" "${sandbox}"
  chmod 700 -- "${sandbox}"
  if [[ -L "${out_dir}" || -L "${sandbox}" ]]; then
    echo "拒绝 symlink out_dir/sandbox" >&2
    exit 99
  fi
  register_owned_sandbox_gnupg "${sand_gnupg}"
  : >"${ghub_out}"
  extract_step_run build_verify '导入生产签名密钥到临时 gnupg' "${script}" \
    >"${out_dir}/extract.log" 2>&1
  chmod 600 -- "${script}" 2>/dev/null || true
  key_body="$(cat -- "${key_file}")"
  (
    # 真实 workflow 用 $PWD/tmp/gnupg；独占 sandbox 后自然落证据目录内。
    # 生产只注入 APT_HUB_GPG_PRIVATE_KEY；不提供第二口令输入。
    cd -- "${sandbox}"
    mkdir -p -- tmp
    set +e
    env \
      GITHUB_OUTPUT="${ghub_out}" \
      APT_HUB_GPG_PRIVATE_KEY="${key_body}" \
      bash "${script}" >"${logf}" 2>&1
    echo "$?" >"${rcfile}"
    set -e
    scrub_owned_home "${sand_gnupg}"
  )
}

expect_rc() {
  local name="$1" got_file="$2" want="$3"
  local got
  got="$(tr -d '[:space:]' <"${got_file}" 2>/dev/null || echo missing)"
  if [[ "${got}" == "${want}" ]]; then
    pass "${name} rc=${got}"
  else
    fail "${name} rc=${got} want=${want} log=$(tail -n 20 "${got_file%/*}/run.log" 2>/dev/null | tr '\n' '|' || true)"
  fi
}

log "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "root=${ROOT}"

# 项目根 tmp/gnupg 哨兵：本测试不得改动（若预存）。
SENTINEL="${ROOT}/tmp/gnupg/sentinel.txt"
SENTINEL_HASH=""
if [[ -f "${SENTINEL}" && ! -L "${ROOT}/tmp/gnupg" && ! -L "${SENTINEL}" ]]; then
  SENTINEL_HASH="$(sha256sum -- "${SENTINEL}" | awk '{print $1}')"
  log "sentinel_pre=${SENTINEL_HASH}"
fi

# ---------- 1) 无口令签名预检：先对真实抽取脚本取证 ----------
# 夹具保护口令仅文件持有（测试命名），不写进日志与命令行参数，不扩生产接口。
FIXTURE_PROTECT="${EVIDENCE}/keys/fixture_protect.txt"
printf '%s' 'wf-test-protect-ok' >"${FIXTURE_PROTECT}"
chmod 600 -- "${FIXTURE_PROTECT}"

EMPTY_HOME="${EVIDENCE}/keys/empty-home"
ENC_HOME="${EVIDENCE}/keys/enc-home"
OTHER_HOME="${EVIDENCE}/keys/other-home"
EMPTY_KEY="${EVIDENCE}/keys/empty.asc"
ENC_KEY="${EVIDENCE}/keys/enc.asc"
MULTI_KEY="${EVIDENCE}/keys/multi.asc"
OTHER_KEY="${EVIDENCE}/keys/other.asc"

log "== 生成测试密钥 =="
EMPTY_FPR=""
ENC_FPR=""
OTHER_FPR=""
gen_key "${EMPTY_HOME}" 'empty@apt-hub-workflow-test.invalid' '' EMPTY_FPR
armor_secret "${EMPTY_HOME}" "${EMPTY_KEY}"
gen_key "${ENC_HOME}" 'enc@apt-hub-workflow-test.invalid' "${FIXTURE_PROTECT}" ENC_FPR
armor_secret "${ENC_HOME}" "${ENC_KEY}" "${FIXTURE_PROTECT}"
gen_key "${OTHER_HOME}" 'other@apt-hub-workflow-test.invalid' '' OTHER_FPR
armor_secret "${OTHER_HOME}" "${OTHER_KEY}"
cleanup_gpg_home "${OTHER_HOME}"
{
  cat -- "${EMPTY_KEY}"
  echo
  cat -- "${OTHER_KEY}"
} >"${MULTI_KEY}"
chmod 600 -- "${MULTI_KEY}"
log "empty_fpr=${EMPTY_FPR}"
log "enc_fpr=${ENC_FPR}"
log "other_fpr=${OTHER_FPR}"

log "== GPG 导入/预检真实 run 段 =="
run_gpg_import_step "${EMPTY_KEY}" "${EVIDENCE}/runs/empty_ok"
expect_rc unprotected_key_sign_success "${EVIDENCE}/runs/empty_ok/rc" 0
if [[ -s "${EVIDENCE}/runs/empty_ok/github_output" ]] \
  && grep -Eq '^fingerprint=[A-F0-9]{40}$' "${EVIDENCE}/runs/empty_ok/github_output"; then
  pass "无口令私钥派生唯一 fingerprint"
else
  fail "无口令私钥未写出合法 fingerprint"
fi

run_gpg_import_step "${ENC_KEY}" "${EVIDENCE}/runs/enc_reject"
expect_rc protected_key_without_second_input_rejected "${EVIDENCE}/runs/enc_reject/rc" 1

run_gpg_import_step "${MULTI_KEY}" "${EVIDENCE}/runs/multi_reject"
expect_rc multiple_primary_rejected "${EVIDENCE}/runs/multi_reject/rc" 1

if grep -E 'APT_HUB_GPG_PASSPHRASE|GPG_PASSPHRASE' "${PUB}" >/dev/null \
  || grep -E 'APT_HUB_GPG_PASSPHRASE|GPG_PASSPHRASE' "${ROOT}/scripts/sync.sh" >/dev/null; then
  fail "生产 workflow/sync 仍含口令 Secret 接口"
else
  pass "生产 workflow/sync 无口令 Secret 接口"
fi

if grep -E 'wf-test-protect|Passphrase:' "${EVIDENCE}/test.log" >/dev/null; then
  fail "证据日志泄漏夹具保护口令"
else
  pass "证据日志无夹具保护口令"
fi

# ---------- 2) 发布者身份：必须存在可抽取步骤，且消费 github.actor ----------
log "== 发布者身份真实 run 段 =="
ID_SCRIPT="${EVIDENCE}/runs/publisher.sh"
set +e
extract_step_run preflight '解析发布者命令级身份' "${ID_SCRIPT}" \
  >"${EVIDENCE}/runs/publisher-extract.log" 2>&1
id_extract_rc=$?
set -e
if [[ "${id_extract_rc}" -eq 0 && -s "${ID_SCRIPT}" ]]; then
  pass "抽取到解析发布者命令级身份步骤"
else
  fail "缺少解析发布者命令级身份步骤（extract_rc=${id_extract_rc}）"
fi

if grep -Fq "APT_HUB_GIT_NAME='yerikokay'" "${PUB}" \
  || grep -Fq '129245892+yerikokay@users.noreply.github.com' "${PUB}"; then
  fail "publish 仍硬编码原维护者身份"
else
  pass "publish 无硬编码原维护者身份"
fi

if grep -Fq 'github.actor' "${PUB}" && grep -Fq 'github.actor_id' "${PUB}"; then
  pass "publish 引用 github.actor / github.actor_id"
else
  fail "publish 未引用 github.actor / github.actor_id"
fi

# curl shim：仅服务本测试标注的 mock 用户，不冒充真实网络。
cat >"${EVIDENCE}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# mock-api: apt-hub workflow_test 本地夹具，非真实 GitHub 网络。
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -w)
      shift 2
      ;;
    -sS|-s|--silent)
      shift
      ;;
    -H)
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "${out}" && -n "${url}" ]] || exit 90
login="${url##*/}"
case "${login}" in
  yerikokay)
    printf '%s\n' '{"login":"yerikokay","id":129245892,"type":"User"}' >"${out}"
    printf '200'
    ;;
  fork-human)
    printf '%s\n' '{"login":"fork-human","id":424242,"type":"User"}' >"${out}"
    printf '200'
    ;;
  some-bot)
    printf '%s\n' '{"login":"some-bot","id":7,"type":"Bot"}' >"${out}"
    printf '200'
    ;;
  *)
    printf '%s\n' '{"message":"mock Not Found"}' >"${out}"
    printf '404'
    ;;
esac
EOF
chmod a+x -- "${EVIDENCE}/bin/curl"

run_publisher() {
  local actor="$1" actor_id="$2" out_dir="$3"
  local ghub_out="${out_dir}/github_output"
  local sandbox="${out_dir}/sandbox"
  mkdir -p -- "${out_dir}" "${sandbox}"
  if [[ -L "${out_dir}" || -L "${sandbox}" ]]; then
    echo "拒绝 symlink publisher sandbox" >&2
    exit 99
  fi
  : >"${ghub_out}"
  if [[ ! -s "${ID_SCRIPT}" ]]; then
    echo 97 >"${out_dir}/rc"
    printf 'no publisher script\n' >"${out_dir}/run.log"
    return 0
  fi
  (
    cd -- "${sandbox}"
    mkdir -p -- tmp
    set +e
    env \
      PATH="${EVIDENCE}/bin:${PATH}" \
      GITHUB_OUTPUT="${ghub_out}" \
      ACTOR_LOGIN="${actor}" \
      ACTOR_ID="${actor_id}" \
      GH_TOKEN='mock-token-not-real' \
      GITHUB_API_URL='https://api.github.com' \
      GITHUB_ACTOR="${actor}" \
      GITHUB_ACTOR_ID="${actor_id}" \
      bash "${ID_SCRIPT}" >"${out_dir}/run.log" 2>&1
    echo "$?" >"${out_dir}/rc"
    set -e
  )
}

read_output() {
  local file="$1" key="$2"
  awk -F= -v k="${key}" '$1==k {print substr($0, index($0,"=")+1); exit}' "${file}" 2>/dev/null || true
}

if [[ -s "${ID_SCRIPT}" ]]; then
  run_publisher yerikokay 129245892 "${EVIDENCE}/runs/id_confirmed"
  expect_rc identity_confirmed_user_rc "${EVIDENCE}/runs/id_confirmed/rc" 0
  got_name="$(read_output "${EVIDENCE}/runs/id_confirmed/github_output" git_name)"
  got_email="$(read_output "${EVIDENCE}/runs/id_confirmed/github_output" git_email)"
  if [[ "${got_name}" == "yerikokay" \
    && "${got_email}" == "129245892+yerikokay@users.noreply.github.com" ]]; then
    pass "确认用户身份输出保持 yerikokay / 129245892+yerikokay@users.noreply.github.com"
  else
    fail "确认用户身份输出偏离: name=${got_name} email=${got_email}"
  fi

  run_publisher fork-human 424242 "${EVIDENCE}/runs/id_fork"
  expect_rc identity_fork_human_rc "${EVIDENCE}/runs/id_fork/rc" 0
  fork_name="$(read_output "${EVIDENCE}/runs/id_fork/github_output" git_name)"
  fork_email="$(read_output "${EVIDENCE}/runs/id_fork/github_output" git_email)"
  if [[ "${fork_name}" == "fork-human" \
    && "${fork_email}" == "424242+fork-human@users.noreply.github.com" ]]; then
    pass "fork 人类身份生成为自身而非 yerikokay"
  else
    fail "fork 身份错误: name=${fork_name} email=${fork_email}"
  fi

  run_publisher some-bot 7 "${EVIDENCE}/runs/id_bot"
  expect_rc identity_bot_rejected "${EVIDENCE}/runs/id_bot/rc" 1

  run_publisher yerikokay 1 "${EVIDENCE}/runs/id_mismatch"
  expect_rc identity_id_mismatch_rejected "${EVIDENCE}/runs/id_mismatch/rc" 1
else
  fail "跳过身份执行：无抽取脚本"
fi

# preflight 先核 publisher；build_verify/README 经 job outputs 透传同一身份。
if grep -Fq 'needs.preflight.outputs.git_name' "${PUB}" \
  && grep -Fq 'needs.preflight.outputs.git_email' "${PUB}" \
  && grep -Fq 'needs.build_verify.outputs.git_name' "${PUB}" \
  && grep -Fq 'needs.build_verify.outputs.git_email' "${PUB}"; then
  pass "保存/回写消费同一 publisher 核验输出"
else
  fail "保存/回写未消费 publisher 核验输出"
fi
if grep -Eq 'go_release:[[:space:]]*$' "${PUB}" \
  && awk '
    $0 ~ /^  go_release:/ {hit=1}
    hit && $0 ~ /^    needs:[[:space:]]*preflight[[:space:]]*$/ {found=1}
    hit && /^  [a-zA-Z0-9_]+:/ && $0 !~ /go_release:/ {exit}
    END {exit found?0:1}
  ' "${PUB}"; then
  pass "go_release 依赖 preflight（缺私钥不发版）"
else
  fail "go_release 未 needs preflight"
fi

# ---------- Go 离线构包 CI 步骤消费者回归（shim，非 Go 构包验收） ----------
# 证据仅 tmp/go-ci-integration；不跑完整 go_deb_test 矩阵。
UBUNTU_TEST_WF="${ROOT}/.github/workflows/ubuntu-test.yml"
GO_CI_EVIDENCE="${ROOT}/tmp/go-ci-integration/workflow-consumer"
GO_STEP_NAME='Go 离线构包与 APT 升级夹具'
rm -rf -- "${GO_CI_EVIDENCE}"
mkdir -p -- "${GO_CI_EVIDENCE}/runs"

log "== Go 离线 CI 步骤真实 run 段 =="
GO_SCRIPT="${GO_CI_EVIDENCE}/runs/go-offline.sh"
set +e
extract_step_run fixture_test "${GO_STEP_NAME}" "${GO_SCRIPT}" "${UBUNTU_TEST_WF}" \
  >"${GO_CI_EVIDENCE}/runs/go-offline-extract.log" 2>&1
go_extract_rc=$?
set -e
if [[ "${go_extract_rc}" -eq 0 && -s "${GO_SCRIPT}" ]]; then
  pass "抽取到唯一非空 Go 离线构包步骤"
else
  fail "缺少 Go 离线构包步骤（extract_rc=${go_extract_rc}）"
fi

if [[ -s "${GO_SCRIPT}" ]]; then
  set +e
  bash -n -- "${GO_SCRIPT}" >"${GO_CI_EVIDENCE}/runs/go-offline-bash-n.log" 2>&1
  go_bashn_rc=$?
  set -e
  if [[ "${go_bashn_rc}" -eq 0 ]]; then
    pass "Go 离线步骤 bash -n 通过"
  else
    fail "Go 离线步骤 bash -n 失败 rc=${go_bashn_rc}"
  fi

  if grep -Fq -- '--live' "${GO_SCRIPT}"; then
    fail "Go 离线步骤含 --live"
  else
    pass "Go 离线步骤无 --live"
  fi
  if grep -Eq 'chmod a\+x[[:space:]].*gen_deb_golang\.sh' "${GO_SCRIPT}" \
    && grep -Eq 'chmod a\+x[[:space:]].*tests/go_deb_test\.sh|chmod a\+x[[:space:]].*gen_deb_golang\.sh[[:space:]].*tests/go_deb_test\.sh' "${GO_SCRIPT}" \
    && grep -Eq '(^|[[:space:]])tests/go_deb_test\.sh([[:space:]]|$)' "${GO_SCRIPT}"; then
    pass "Go 离线步骤 chmod gen/build 与 go_deb_test.sh"
  else
    if grep -Fq 'gen_deb_golang.sh' "${GO_SCRIPT}" \
      && grep -Fq 'tests/go_deb_test.sh' "${GO_SCRIPT}"; then
      pass "Go 离线步骤引用 gen_deb_golang.sh 与 go_deb_test.sh"
    else
      fail "Go 离线步骤未正确 chmod/调用 Go 测试入口"
    fi
  fi

  # 标注 shim：编排失败探测，不得当作 Go 构包验收。
  install_go_ci_shim() {
    local sandbox="$1"
    mkdir -p -- "${sandbox}/scripts" "${sandbox}/tests"
    # 占位：仅满足 chmod；非真实构包脚本。
    printf '%s\n' '#!/usr/bin/env bash' '# SHIM placeholder gen_deb_golang — not real' 'exit 0' \
      >"${sandbox}/gen_deb_golang.sh"
    printf '%s\n' '#!/usr/bin/env bash' '# SHIM placeholder build — not real' 'exit 0' \
      >"${sandbox}/build.sh"
    cat >"${sandbox}/tests/go_deb_test.sh" <<'SHIM'
#!/usr/bin/env bash
# SHIM: workflow_test Go CI orchestration probe — NOT go_deb package acceptance.
set -euo pipefail
CALL_LOG="${APT_HUB_GO_SHIM_CALL_LOG:?missing APT_HUB_GO_SHIM_CALL_LOG}"
RC_FILE="${APT_HUB_GO_SHIM_RC_FILE:?missing APT_HUB_GO_SHIM_RC_FILE}"
{
  printf 'argc=%s\n' "$#"
  printf 'argv='
  printf '%q ' "$@"
  printf '\n'
} >>"${CALL_LOG}"
if [[ $# -gt 0 ]]; then
  for a in "$@"; do
    if [[ "${a}" == "--live" ]]; then
      echo "shim reject --live" >&2
      exit 2
    fi
  done
  echo "shim reject unknown args: $*" >&2
  exit 2
fi
exit "$(tr -d '[:space:]' <"${RC_FILE}")"
SHIM
    chmod a+x -- "${sandbox}/gen_deb_golang.sh" "${sandbox}/build.sh" "${sandbox}/tests/go_deb_test.sh"
  }

  run_go_ci_step() {
    local out_dir="$1" want_rc="$2"
    local sandbox="${out_dir}/sandbox"
    local call_log="${out_dir}/shim-calls.log"
    local rc_file="${out_dir}/shim-rc.txt"
    mkdir -p -- "${out_dir}"
    rm -rf -- "${sandbox}"
    mkdir -p -- "${sandbox}"
    install_go_ci_shim "${sandbox}"
    : >"${call_log}"
    printf '%s\n' "${want_rc}" >"${rc_file}"
    (
      cd -- "${sandbox}"
      set +e
      env \
        APT_HUB_GO_SHIM_CALL_LOG="${call_log}" \
        APT_HUB_GO_SHIM_RC_FILE="${rc_file}" \
        bash "${GO_SCRIPT}" >"${out_dir}/run.log" 2>&1
      echo "$?" >"${out_dir}/rc"
      set -e
    )
  }

  run_go_ci_step "${GO_CI_EVIDENCE}/runs/go_ok" 0
  expect_rc go_offline_step_success_propagates "${GO_CI_EVIDENCE}/runs/go_ok/rc" 0
  if [[ -s "${GO_CI_EVIDENCE}/runs/go_ok/shim-calls.log" ]] \
    && grep -Fq 'argc=0' "${GO_CI_EVIDENCE}/runs/go_ok/shim-calls.log"; then
    pass "Go 步骤成功路径确实调用 shim（无参）"
  else
    fail "Go 步骤成功路径未记录 shim 调用"
  fi

  run_go_ci_step "${GO_CI_EVIDENCE}/runs/go_fail23" 23
  expect_rc go_offline_step_fail23_propagates "${GO_CI_EVIDENCE}/runs/go_fail23/rc" 23
  if [[ -s "${GO_CI_EVIDENCE}/runs/go_fail23/shim-calls.log" ]] \
    && grep -Fq 'argc=0' "${GO_CI_EVIDENCE}/runs/go_fail23/shim-calls.log"; then
    pass "Go 步骤失败路径确实调用 shim（rc=23）"
  else
    fail "Go 步骤失败路径未记录 shim 调用"
  fi

  # 直接打 shim：拒 --live / 未知参数（编排探测，非构包验收）。
  shim_probe="${GO_CI_EVIDENCE}/runs/shim-probe"
  mkdir -p -- "${shim_probe}"
  install_go_ci_shim "${shim_probe}/sandbox"
  : >"${shim_probe}/calls.log"
  printf '0\n' >"${shim_probe}/rc.txt"
  set +e
  env APT_HUB_GO_SHIM_CALL_LOG="${shim_probe}/calls.log" \
    APT_HUB_GO_SHIM_RC_FILE="${shim_probe}/rc.txt" \
    bash "${shim_probe}/sandbox/tests/go_deb_test.sh" --live \
    >"${shim_probe}/live.log" 2>&1
  echo "$?" >"${shim_probe}/live.rc"
  env APT_HUB_GO_SHIM_CALL_LOG="${shim_probe}/calls.log" \
    APT_HUB_GO_SHIM_RC_FILE="${shim_probe}/rc.txt" \
    bash "${shim_probe}/sandbox/tests/go_deb_test.sh" --bogus \
    >"${shim_probe}/bogus.log" 2>&1
  echo "$?" >"${shim_probe}/bogus.rc"
  set -e
  expect_rc go_shim_rejects_live "${shim_probe}/live.rc" 2
  expect_rc go_shim_rejects_unknown "${shim_probe}/bogus.rc" 2
else
  fail "跳过 Go 步骤执行：无抽取脚本"
  fail "跳过 Go 步骤 bash -n：无抽取脚本"
fi

# ---------- 可移植性与隔离验收 ----------
# needle 拼接，避免源码自带探测字面量。
_dep_yaml='Bun.''YAML.parse'
_dep_bin='^[[:space:]]*b''un[[:space:]]'
if grep -nF "${_dep_yaml}" "${ROOT}/tests/workflow_test.sh" >/dev/null \
  || grep -nE "${_dep_bin}" "${ROOT}/tests/workflow_test.sh" >/dev/null; then
  fail "workflow_test.sh 仍调用外部 YAML 运行时"
elif grep -A20 '^extract_step_run()' "${ROOT}/tests/workflow_test.sh" | grep -q 'awk '; then
  pass "extract_step_run 使用 awk，无外部 YAML 运行时调用"
else
  fail "extract_step_run 未使用 awk"
fi
unset _dep_yaml _dep_bin

if [[ -n "${SENTINEL_HASH}" ]]; then
  if [[ -f "${SENTINEL}" && ! -L "${SENTINEL}" ]]; then
    got_hash="$(sha256sum -- "${SENTINEL}" | awk '{print $1}')"
    if [[ "${got_hash}" == "${SENTINEL_HASH}" ]]; then
      pass "项目 tmp/gnupg sentinel 未改动"
    else
      fail "项目 tmp/gnupg sentinel 被改动"
    fi
  else
    fail "项目 tmp/gnupg sentinel 丢失"
  fi
else
  if [[ -e "${ROOT}/tmp/gnupg" ]]; then
    # 本测试启动时无哨兵则不应新建/污染项目 gnupg；若他方创建则不强制。
    log "note: 无预存 sentinel，跳过 sentinel 哈希核验"
  fi
fi

# 主动清密后再断言残留（trap 还会再跑一次）
scrub_test_secrets
residue=0
if [[ -e "${EVIDENCE}/keys/fixture_protect.txt" ]]; then
  fail "残留 fixture_protect.txt"
  residue=1
fi
if compgen -G "${EVIDENCE}/keys/*.asc" >/dev/null; then
  fail "残留导出 *.asc"
  residue=1
fi
if find "${EVIDENCE}" -type d -name 'private-keys-v1.d' 2>/dev/null | grep -q .; then
  fail "残留 private-keys-v1.d"
  residue=1
fi
if [[ "${residue}" -eq 0 ]]; then
  pass "无测试私钥/夹具保护口令残留（asc/fixture_protect/private-keys）"
fi

log "RESULT pass=${PASS} fail=${FAIL}"
if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi
exit 0
