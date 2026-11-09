#!/usr/bin/env bash
# Go 发版切片隔离验收：build/helper/workflow 真 run 段/git_tag bare；不触真实 Release；主仓不跑 git_tag。
set -euo pipefail
export LC_ALL=C
export LANG=C
export LANGUAGE=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE="${ROOT}/tmp/delivery-v16/release"
BUILD_SH="${ROOT}/build.sh"
GEN="${ROOT}/gen_deb_golang.sh"
REL="${ROOT}/scripts/release_golang.sh"
GIT_TAG="${ROOT}/git_tag.sh"
WF_REL="${ROOT}/.github/workflows/release.yml"
WF_PUB="${ROOT}/.github/workflows/ubuntu-publish.yml"
WF_TEST="${ROOT}/.github/workflows/ubuntu-test.yml"
CONFIG="${ROOT}/config/go.json"
SHELLCHECK_BIN=""
if [[ -x "${ROOT}/tmp/metadata-C/bin/shellcheck" ]]; then
  SHELLCHECK_BIN="${ROOT}/tmp/metadata-C/bin/shellcheck"
elif command -v shellcheck >/dev/null 2>&1; then
  SHELLCHECK_BIN="$(command -v shellcheck)"
fi

PASS=0
FAIL=0

mkdir -p -- "${EVIDENCE}/runs" "${EVIDENCE}/bin" "${EVIDENCE}/fixtures"
: >"${EVIDENCE}/test.log"

log() { printf '%s\n' "$*" | tee -a "${EVIDENCE}/test.log"; }
pass() { PASS=$((PASS + 1)); log "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL: $*"; }

record() {
  local name="$1" rc="$2" expect="$3"
  log "CASE ${name}: exit=${rc} expect=${expect}"
  if [[ "${rc}" -eq "${expect}" ]]; then
    pass "${name}"
  else
    fail "${name} exit=${rc} want=${expect}"
  fi
}

extract_step_run() {
  local job="$1" step_name="$2" out="$3" wf="$4"
  awk -v job="${job}" -v step="${step_name}" '
    BEGIN { in_jobs=0; in_job=0; in_step=0; job_seen=0; hits=0; grabbing=0; body=0 }
    /^jobs:[[:space:]]*$/ { in_jobs=1; next }
    in_jobs && /^  [A-Za-z0-9_]+:[[:space:]]*$/ {
      name=$1; sub(/:$/, "", name)
      if (name == job) { in_job=1; job_seen=1; in_step=0; grabbing=0 }
      else if (in_job) { in_job=0; in_step=0; grabbing=0 }
      next
    }
    in_job && /^      - name:[[:space:]]+/ {
      line=$0; sub(/^      - name:[[:space:]]+/, "", line)
      if (line == step) { hits++; in_step=1; grabbing=0 }
      else { in_step=0; grabbing=0 }
      next
    }
    in_step && /^        run:[[:space:]]*\|[[:space:]]*$/ { grabbing=1; next }
    grabbing {
      if ($0 == "" || $0 ~ /^          /) {
        sub(/^          /, "", $0); print; body=1; next
      }
      grabbing=0; in_step=0
    }
    END {
      if (!job_seen) { print "missing job: " job > "/dev/stderr"; exit 2 }
      if (hits != 1) { print "step hits=" hits > "/dev/stderr"; exit 3 }
      if (!body) { print "missing body" > "/dev/stderr"; exit 5 }
    }
  ' "${wf}" >"${out}"
}

# ---------- 静态 ----------
bash -n -- "${GEN}" "${BUILD_SH}" "${REL}" "${GIT_TAG}" "$0"
record "bash_n_all" $? 0
if [[ -n "${SHELLCHECK_BIN}" && -x "${SHELLCHECK_BIN}" ]]; then
  set +e
  "${SHELLCHECK_BIN}" -s bash -x -- "${GEN}" "${BUILD_SH}" "${REL}" "${GIT_TAG}" "$0" \
    >"${EVIDENCE}/runs/shellcheck.out" 2>&1
  RC=$?
  set -e
  record "shellcheck_release_slice" "${RC}" 0
else
  log "shellcheck missing"
  record "shellcheck_release_slice" 1 0
fi

if [[ -e "${ROOT}/scripts/build_go_deb.sh" ]]; then
  fail "仍存在 scripts/build_go_deb.sh 副本"
else
  pass "无 scripts/build_go_deb.sh 副本"
fi
if grep -R -n --exclude-dir=.git --exclude-dir=tmp -E 'scripts/build_go_deb\.sh' \
  "${ROOT}/gen_deb_golang.sh" "${ROOT}/build.sh" "${ROOT}/tests/go_deb_test.sh" \
  "${ROOT}/tests/workflow_test.sh" "${ROOT}/.github/workflows" 2>/dev/null \
  | grep -v 'release_test' >/dev/null; then
  fail "权限范围内仍引用 build_go_deb.sh"
else
  pass "权限范围已改齐 gen_deb_golang"
fi

if grep -Fq 'workflow_call' "${WF_REL}" \
  && grep -Eq '^  prepare:' "${WF_REL}" \
  && grep -Eq '^  Build:' "${WF_REL}" \
  && grep -Eq '^  RemoveOld:' "${WF_REL}" \
  && grep -Fq 'go_release_tag' "${WF_REL}"; then
  pass "release.yml prepare→Build→RemoveOld + go_release_tag"
else
  fail "release.yml 三段结构不完整"
fi
if grep -Fq 'uses: ./.github/workflows/release.yml' "${WF_PUB}" \
  && grep -Fq 'rotate_from' "${WF_PUB}" \
  && grep -Fq -- '--package-repository' "${WF_PUB}" \
  && grep -Fq -- '--go-release-tag' "${WF_PUB}" \
  && grep -Fq 'binutils' "${WF_PUB}" \
  && grep -Eq '^  preflight:' "${WF_PUB}"; then
  pass "ubuntu-publish 预检+Go发版+共享参数"
else
  fail "ubuntu-publish 未正确接入"
fi
if grep -Fq 'gen_deb_golang.sh' "${WF_TEST}" && grep -Fq 'release_test.sh' "${WF_TEST}"; then
  pass "ubuntu-test 引用新入口与 release_test"
else
  fail "ubuntu-test 未更新"
fi

# ---------- build.sh 真小双 arch ----------
FIX_ARCH="${EVIDENCE}/fixtures/archives"
FIX_JSON="${EVIDENCE}/fixtures/downloads.json"
mkdir -p -- "${FIX_ARCH}"
write_min_elf() {
  local out="$1" arch="$2" machine
  case "${arch}" in
    amd64) machine="3e00" ;;
    arm64) machine="b700" ;;
    *) return 1 ;;
  esac
  xxd -r -p >"${out}" <<EOF
7f454c460201010000000000000000000200${machine}010000000000000000000000400000000000000000000000000000000000000000000000400038000100400000000000000000000000
EOF
  printf 'APT_HUB_GO_TEST_FIXTURE_ELF\n' >>"${out}"
  chmod 755 -- "${out}"
}
make_tree() {
  local root="$1" ver="$2" arch="$3" triple
  case "${arch}" in
    amd64) triple=linux_amd64 ;;
    arm64) triple=linux_arm64 ;;
  esac
  rm -rf -- "${root}"
  mkdir -p -- "${root}/go/bin" "${root}/go/pkg/tool/${triple}"
  printf '%s\ntime 2023-11-14T00:00:00Z\n' "${ver}" >"${root}/go/VERSION"
  printf 'TEST FIXTURE LICENSE\n' >"${root}/go/LICENSE"
  write_min_elf "${root}/go/bin/go" "${arch}"
  write_min_elf "${root}/go/bin/gofmt" "${arch}"
  write_min_elf "${root}/go/pkg/tool/${triple}/compile" "${arch}"
}
pack_tar() {
  local tree="$1" dest="$2"
  (
    cd -- "${tree}"
    tar --sort=name --mtime="@1700000000" --owner=0 --group=0 --numeric-owner -czf "${dest}.tmp" go
  )
  mv -f -- "${dest}.tmp" "${dest}"
}
make_tree "${EVIDENCE}/fixtures/tree-amd" go7.7.7 amd64
make_tree "${EVIDENCE}/fixtures/tree-arm" go7.7.7 arm64
pack_tar "${EVIDENCE}/fixtures/tree-amd" "${FIX_ARCH}/go7.7.7.linux-amd64.tar.gz"
pack_tar "${EVIDENCE}/fixtures/tree-arm" "${FIX_ARCH}/go7.7.7.linux-arm64.tar.gz"
amd_sha="$(sha256sum -- "${FIX_ARCH}/go7.7.7.linux-amd64.tar.gz" | awk '{print $1}')"
amd_sz="$(stat -c '%s' -- "${FIX_ARCH}/go7.7.7.linux-amd64.tar.gz")"
arm_sha="$(sha256sum -- "${FIX_ARCH}/go7.7.7.linux-arm64.tar.gz" | awk '{print $1}')"
arm_sz="$(stat -c '%s' -- "${FIX_ARCH}/go7.7.7.linux-arm64.tar.gz")"
jq -n \
  --arg as "${amd_sha}" --arg az "${amd_sz}" \
  --arg rs "${arm_sha}" --arg rz "${arm_sz}" \
  '[{version:"go7.7.7",stable:true,files:[
    {filename:"go7.7.7.linux-amd64.tar.gz",os:"linux",arch:"amd64",version:"go7.7.7",sha256:$as,size:($az|tonumber),kind:"archive"},
    {filename:"go7.7.7.linux-arm64.tar.gz",os:"linux",arch:"arm64",version:"go7.7.7",sha256:$rs,size:($rz|tonumber),kind:"archive"}
  ]}]' >"${FIX_JSON}"

OUT_BUILD="${ROOT}/tmp/delivery-v16/release/out-build"
rm -rf -- "${OUT_BUILD}" "${OUT_BUILD}".*
chmod a+x -- "${BUILD_SH}" "${GEN}" "${REL}" "${GIT_TAG}"
set +e
"${BUILD_SH}" --output "${OUT_BUILD}" --go-version go7.7.7 \
  --downloads-json "${FIX_JSON}" --archive-dir "${FIX_ARCH}" \
  >"${EVIDENCE}/runs/build.out" 2>"${EVIDENCE}/runs/build.err"
RC=$?
set -e
record "build_flat_dual_arch" "${RC}" 0
if [[ -f "${OUT_BUILD}/apt-hub-go_7.7.7-1_amd64.deb" \
  && -f "${OUT_BUILD}/apt-hub-go_7.7.7-1_arm64.deb" \
  && -f "${OUT_BUILD}/provenance.json" \
  && -f "${OUT_BUILD}/SHA256SUMS" ]]; then
  pass "build 单平面 assets 齐全"
else
  fail "build 输出布局不完整"
fi

OUT_FAIL="${ROOT}/tmp/delivery-v16/release/out-fail"
rm -rf -- "${OUT_FAIL}" "${OUT_FAIL}".*
mkdir -p -- "${OUT_FAIL}"
set +e
"${BUILD_SH}" --output "${OUT_FAIL}" --go-version go0.0.0 \
  --downloads-json "${FIX_JSON}" --archive-dir "${FIX_ARCH}" \
  >"${EVIDENCE}/runs/build-fail.out" 2>"${EVIDENCE}/runs/build-fail.err"
RC=$?
set -e
record "build_bad_version_fails" "${RC}" 1
if find -- "${OUT_FAIL}" -type f \( -name '*.deb' -o -name 'provenance.json' \) 2>/dev/null | grep -q .; then
  fail "失败路径留下半套"
else
  pass "失败无半套"
fi

# ---------- fixture 桩（明确标注，非真实 gh） ----------
STUB_BIN="${EVIDENCE}/bin"
install -d -- "${STUB_BIN}"

cat >"${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="${APT_HUB_GH_LOG:?}"
printf 'gh %s\n' "$*" >>"${LOG}"
cmd="${1:-}"
case "${cmd}" in
  release)
    sub="${2:-}"
    case "${sub}" in
      list)
        cat <<'JSON'
[{"tagName":"apt-hub-go-7.7.7-1","isDraft":false,"isLatest":false,"createdAt":"2026-01-03T00:00:00Z"},
 {"tagName":"apt-hub-go-7.7.6-1","isDraft":false,"isLatest":false,"createdAt":"2026-01-02T00:00:00Z"},
 {"tagName":"apt-hub-go-7.7.5-1","isDraft":false,"isLatest":false,"createdAt":"2026-01-01T00:00:00Z"},
 {"tagName":"apt-hub-go-9.9.9-1","isDraft":true,"isLatest":false,"createdAt":"2026-01-04T00:00:00Z"}]
JSON
        ;;
      view)
        tag="${3:-}"
        case "${tag}" in
          apt-hub-go-7.7.5-1|apt-hub-go-9.9.9-1) exit 0 ;;
          *) echo "not found" >&2; exit 1 ;;
        esac
        ;;
      create) echo created-draft ;;
      upload) echo uploaded ;;
      download)
        dest=""; pat=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -D|--dir) dest="$2"; shift 2 ;;
            -p|--pattern) pat="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        cp -a -- "${APT_HUB_DL_SRC:?}/${pat}" "${dest}/${pat}"
        ;;
      edit) echo edited ;;
      delete) echo "deleted $*" ;;
      *) echo "gh release unknown ${sub}" >&2; exit 2 ;;
    esac
    ;;
  *) echo "gh unknown: $*" >&2; exit 2 ;;
esac
EOF
chmod a+x -- "${STUB_BIN}/gh"

pub_assets_json() {
  local draft="$1"
  local amd arm prov sums
  amd="${APT_HUB_ASSET_DIR}/apt-hub-go_7.7.7-1_amd64.deb"
  arm="${APT_HUB_ASSET_DIR}/apt-hub-go_7.7.7-1_arm64.deb"
  prov="${APT_HUB_ASSET_DIR}/provenance.json"
  sums="${APT_HUB_ASSET_DIR}/SHA256SUMS"
  jq -n \
    --argjson draft "${draft}" \
    --argjson as "$(stat -c '%s' -- "$amd")" \
    --arg ad "sha256:$(sha256sum -- "$amd" | awk '{print $1}')" \
    --argjson rs "$(stat -c '%s' -- "$arm")" \
    --arg rd "sha256:$(sha256sum -- "$arm" | awk '{print $1}')" \
    --argjson ps "$(stat -c '%s' -- "$prov")" \
    --arg pd "sha256:$(sha256sum -- "$prov" | awk '{print $1}')" \
    --argjson ss "$(stat -c '%s' -- "$sums")" \
    --arg sd "sha256:$(sha256sum -- "$sums" | awk '{print $1}')" \
    '{id:1,draft:$draft,prerelease:false,assets:[
      {name:"apt-hub-go_7.7.7-1_amd64.deb",size:$as,digest:$ad,id:11},
      {name:"apt-hub-go_7.7.7-1_arm64.deb",size:$rs,digest:$rd,id:12},
      {name:"provenance.json",size:$ps,digest:$pd,id:13},
      {name:"SHA256SUMS",size:$ss,digest:$sd,id:14}
    ]}'
}

cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="${APT_HUB_CURL_LOG:?}"
printf 'curl %s\n' "$*" >>"${LOG}"
out=""; url=""; write_code=0
args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  a="${args[$i]}"
  case "$a" in
    -o) i=$((i+1)); out="${args[$i]}" ;;
    -w) i=$((i+1)); write_code=1 ;;
    --) i=$((i+1)); url="${args[$i]}" ;;
    https://*|http://*) url="$a" ;;
  esac
  i=$((i+1))
done
[[ -n "${url}" ]] || { echo "curl stub: no url" >&2; exit 1; }
respond() {
  local body="$1" code="$2"
  if [[ -n "${out}" ]]; then printf '%s' "${body}" >"${out}"; else printf '%s' "${body}"; fi
  if [[ "${write_code}" -eq 1 ]]; then printf '%s' "${code}"; fi
}
case "${url}" in
  https://api.github.com/repos/*/releases/tags/*)
    tag="${url##*/}"
    st="${APT_HUB_REL_STATE:-missing}"
    if [[ "${tag}" == "apt-hub-go-7.7.7-1" && "${st}" == "published" ]]; then
      respond "$(APT_HUB_ASSET_DIR="${APT_HUB_ASSET_DIR}" bash -c 'source /dev/null; '"$(declare -f pub_assets_json)"'; pub_assets_json false')" 200
    elif [[ "${tag}" == "apt-hub-go-7.7.7-1" && "${st}" == "published_bad" ]]; then
      respond '{"id":1,"draft":false,"prerelease":false,"assets":[{"name":"apt-hub-go_7.7.7-1_amd64.deb","size":1,"digest":"sha256:dead","id":11}]}' 200
    elif [[ "${tag}" == "apt-hub-go-7.7.7-1" && "${st}" == "draft" ]]; then
      respond "$(APT_HUB_ASSET_DIR="${APT_HUB_ASSET_DIR}" bash -c 'true')" 200
      # draft incomplete: only one asset / or full-but-draft
      respond '{"id":42,"draft":true,"prerelease":false,"assets":[{"name":"SHA256SUMS","size":10,"id":1}]}' 200
    elif [[ "${tag}" == "apt-hub-go-7.7.7-1" && "${st}" == "draft_full" ]]; then
      body="$(
        amd="${APT_HUB_ASSET_DIR}/apt-hub-go_7.7.7-1_amd64.deb"
        arm="${APT_HUB_ASSET_DIR}/apt-hub-go_7.7.7-1_arm64.deb"
        prov="${APT_HUB_ASSET_DIR}/provenance.json"
        sums="${APT_HUB_ASSET_DIR}/SHA256SUMS"
        jq -n \
          --argjson as "$(stat -c '%s' -- "$amd")" --arg ad "sha256:$(sha256sum -- "$amd" | awk '{print $1}')" \
          --argjson rs "$(stat -c '%s' -- "$arm")" --arg rd "sha256:$(sha256sum -- "$arm" | awk '{print $1}')" \
          --argjson ps "$(stat -c '%s' -- "$prov")" --arg pd "sha256:$(sha256sum -- "$prov" | awk '{print $1}')" \
          --argjson ss "$(stat -c '%s' -- "$sums")" --arg sd "sha256:$(sha256sum -- "$sums" | awk '{print $1}')" \
          '{id:42,draft:true,prerelease:false,assets:[
            {name:"apt-hub-go_7.7.7-1_amd64.deb",size:$as,digest:$ad,id:11},
            {name:"apt-hub-go_7.7.7-1_arm64.deb",size:$rs,digest:$rd,id:12},
            {name:"provenance.json",size:$ps,digest:$pd,id:13},
            {name:"SHA256SUMS",size:$ss,digest:$sd,id:14}
          ]}'
      )"
      respond "${body}" 200
    else
      respond '{"message":"Not Found"}' 404
    fi
    ;;
  https://api.github.com/repos/*/tarball/*)
    tmpdir=$(mktemp -d)
    mkdir -p "${tmpdir}/repo/dists/stable/main/binary-amd64" "${tmpdir}/repo/by-hash/SHA256"
    printf 'Package: apt-hub-go\nFilename: pool/main/apt-hub-go_7.7.6-1_amd64.deb\n' \
      >"${tmpdir}/repo/dists/stable/main/binary-amd64/Packages"
    printf 'Filename: pool/main/apt-hub-go_7.7.6-1_amd64.deb\n' \
      >"${tmpdir}/repo/by-hash/SHA256/deadbeef"
    tar -C "${tmpdir}" -czf "${out}" repo
    rm -rf -- "${tmpdir}"
    if [[ "${write_code}" -eq 1 ]]; then printf '200'; fi
    ;;
  *)
    respond '{"ok":true}' 200
    ;;
esac
EOF
chmod a+x -- "${STUB_BIN}/curl"

# 简化：重写 curl 桩，避免嵌套函数问题
cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="${APT_HUB_CURL_LOG:?}"
printf 'curl %s\n' "$*" >>"${LOG}"
out=""; url=""; write_code=0
args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  a="${args[$i]}"
  case "$a" in
    -o) i=$((i+1)); out="${args[$i]}" ;;
    -w) i=$((i+1)); write_code=1 ;;
    --) i=$((i+1)); url="${args[$i]}" ;;
    https://*|http://*) url="$a" ;;
  esac
  i=$((i+1))
done
[[ -n "${url}" ]] || { echo "curl stub: no url" >&2; exit 1; }
respond() {
  local body="$1" code="$2"
  if [[ -n "${out}" ]]; then printf '%s' "${body}" >"${out}"; else printf '%s' "${body}"; fi
  if [[ "${write_code}" -eq 1 ]]; then printf '%s' "${code}"; fi
}
make_full() {
  local draft="$1"
  local amd arm prov sums
  amd="${APT_HUB_ASSET_DIR}/apt-hub-go_7.7.7-1_amd64.deb"
  arm="${APT_HUB_ASSET_DIR}/apt-hub-go_7.7.7-1_arm64.deb"
  prov="${APT_HUB_ASSET_DIR}/provenance.json"
  sums="${APT_HUB_ASSET_DIR}/SHA256SUMS"
  jq -n \
    --argjson draft "${draft}" \
    --argjson as "$(stat -c '%s' -- "$amd")" --arg ad "sha256:$(sha256sum -- "$amd" | awk '{print $1}')" \
    --argjson rs "$(stat -c '%s' -- "$arm")" --arg rd "sha256:$(sha256sum -- "$arm" | awk '{print $1}')" \
    --argjson ps "$(stat -c '%s' -- "$prov")" --arg pd "sha256:$(sha256sum -- "$prov" | awk '{print $1}')" \
    --argjson ss "$(stat -c '%s' -- "$sums")" --arg sd "sha256:$(sha256sum -- "$sums" | awk '{print $1}')" \
    '{id:(if $draft then 42 else 1 end),draft:$draft,prerelease:false,assets:[
      {name:"apt-hub-go_7.7.7-1_amd64.deb",size:$as,digest:$ad,id:11},
      {name:"apt-hub-go_7.7.7-1_arm64.deb",size:$rs,digest:$rd,id:12},
      {name:"provenance.json",size:$ps,digest:$pd,id:13},
      {name:"SHA256SUMS",size:$ss,digest:$sd,id:14}
    ]}'
}
case "${url}" in
  https://api.github.com/repos/*/releases/tags/*)
    tag="${url##*/}"
    st="${APT_HUB_REL_STATE:-missing}"
    if [[ "${tag}" != "apt-hub-go-7.7.7-1" ]]; then
      respond '{"message":"Not Found"}' 404
    elif [[ "${st}" == "published" ]]; then
      respond "$(make_full false)" 200
    elif [[ "${st}" == "published_bad" ]]; then
      respond '{"id":1,"draft":false,"prerelease":false,"assets":[{"name":"apt-hub-go_7.7.7-1_amd64.deb","size":1,"digest":"sha256:dead","id":11}]}' 200
    elif [[ "${st}" == "draft" ]]; then
      respond '{"id":42,"draft":true,"prerelease":false,"assets":[{"name":"SHA256SUMS","size":10,"id":1}]}' 200
    elif [[ "${st}" == "draft_full" ]]; then
      respond "$(make_full true)" 200
    else
      respond '{"message":"Not Found"}' 404
    fi
    ;;
  https://api.github.com/repos/*/tarball/*)
    tmpdir=$(mktemp -d)
    mkdir -p "${tmpdir}/repo/dists/stable/main/binary-amd64" "${tmpdir}/repo/by-hash/SHA256"
    printf 'Package: apt-hub-go\nFilename: pool/main/apt-hub-go_7.7.6-1_amd64.deb\n' \
      >"${tmpdir}/repo/dists/stable/main/binary-amd64/Packages"
    printf 'Filename: pool/main/apt-hub-go_7.7.6-1_amd64.deb\n' \
      >"${tmpdir}/repo/by-hash/SHA256/deadbeef"
    tar -C "${tmpdir}" -czf "${out}" repo
    rm -rf -- "${tmpdir}"
    if [[ "${write_code}" -eq 1 ]]; then printf '200'; fi
    ;;
  *)
    respond '{"ok":true}' 200
    ;;
esac
EOF
chmod a+x -- "${STUB_BIN}/curl"

cat >"${STUB_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="${APT_HUB_GIT_LOG:-/dev/null}"
printf 'git %s\n' "$*" >>"${LOG}"
if [[ "${1:-}" == "ls-remote" ]]; then
  if [[ "${APT_HUB_APT_DATA:-present}" == "absent" ]]; then exit 0; fi
  if [[ "${APT_HUB_APT_DATA:-present}" == "error" ]]; then echo "network fail" >&2; exit 1; fi
  echo "0123456789abcdef0123456789abcdef01234567	refs/heads/apt-data"
  exit 0
fi
if [[ "${1:-}" == "push" ]]; then exit 0; fi
exec /usr/bin/git "$@"
EOF
chmod a+x -- "${STUB_BIN}/git"

PREP_DIR="${ROOT}/tmp/delivery-v16/release/prepare"
rm -rf -- "${PREP_DIR}"
mkdir -p -- "${PREP_DIR}"
set +e
env PATH="${STUB_BIN}:/usr/bin:/bin" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-prepare.log" \
  bash "${REL}" prepare \
    --repository "example/apt-hub" \
    --config "${CONFIG}" \
    --work-dir "${PREP_DIR}" \
    --downloads-json "${FIX_JSON}" \
    --version go7.7.7 \
  >"${EVIDENCE}/runs/prepare.out" 2>"${EVIDENCE}/runs/prepare.err"
RC=$?
set -e
record "prepare_ok" "${RC}" 0
grep -Fq 'go_release_tag=apt-hub-go-7.7.7-1' "${EVIDENCE}/runs/prepare.out" \
  && pass "prepare 输出精确 tag" || fail "prepare 未输出 apt-hub-go-7.7.7-1"

set +e
bash "${REL}" prepare --config "${CONFIG}" --work-dir "${PREP_DIR}/x" \
  >"${EVIDENCE}/runs/prepare-norepo.out" 2>"${EVIDENCE}/runs/prepare-norepo.err"
RC=$?
set -e
record "prepare_requires_repository" "${RC}" 2

# status: draft 半套 incomplete
: >"${EVIDENCE}/runs/gh-status.log"
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-status.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-status.log" \
  APT_HUB_REL_STATE=draft \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  bash "${REL}" status --repository example/apt-hub --tag apt-hub-go-7.7.7-1 \
  >"${EVIDENCE}/runs/status-draft.out" 2>"${EVIDENCE}/runs/status-draft.err"
RC=$?
set -e
record "status_draft_ok" "${RC}" 0
grep -Fq 'assets_complete=0' "${EVIDENCE}/runs/status-draft.out" \
  && grep -Fq 'release_state=draft' "${EVIDENCE}/runs/status-draft.out" \
  && pass "draft 不视 complete" || fail "draft 被误标 complete"

# status: published complete + fetch 复用
FETCH_DIR="${ROOT}/tmp/delivery-v16/release/fetch-reuse"
rm -rf -- "${FETCH_DIR}"
export APT_HUB_DL_SRC="${OUT_BUILD}"
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-status-pub.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-status-pub.log" \
  APT_HUB_REL_STATE=published \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  APT_HUB_DL_SRC="${OUT_BUILD}" \
  bash "${REL}" status --repository example/apt-hub --tag apt-hub-go-7.7.7-1 \
    --fetch-dir "${FETCH_DIR}" \
  >"${EVIDENCE}/runs/status-pub.out" 2>"${EVIDENCE}/runs/status-pub.err"
RC=$?
set -e
record "status_published_reuse" "${RC}" 0
grep -Fq 'assets_reused=1' "${EVIDENCE}/runs/status-pub.out" \
  && [[ -f "${FETCH_DIR}/provenance.json" ]] \
  && pass "published 完整资产可复用" || fail "published 复用失败"

# upload 幂等 published（忽略 generated_at：同 packages）
: >"${EVIDENCE}/runs/gh-upload.log"
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-upload.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-upload.log" \
  APT_HUB_REL_STATE=published \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  APT_HUB_DL_SRC="${OUT_BUILD}" \
  bash "${REL}" upload \
    --repository example/apt-hub \
    --tag apt-hub-go-7.7.7-1 \
    --asset-dir "${OUT_BUILD}" \
    --source-sha "$(git -C "${ROOT}" rev-parse HEAD)" \
  >"${EVIDENCE}/runs/upload-idem.out" 2>"${EVIDENCE}/runs/upload-idem.err"
RC=$?
set -e
record "upload_idempotent_published" "${RC}" 0
grep -Fq 'upload_status=idempotent_published' "${EVIDENCE}/runs/upload-idem.out" \
  && pass "upload 幂等 published" || fail "upload 未走幂等"

# 同 tag 不同 bytes 拒绝
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-upload-bad.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-upload-bad.log" \
  APT_HUB_REL_STATE=published_bad \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  APT_HUB_DL_SRC="${OUT_BUILD}" \
  bash "${REL}" upload \
    --repository example/apt-hub \
    --tag apt-hub-go-7.7.7-1 \
    --asset-dir "${OUT_BUILD}" \
    --source-sha "$(git -C "${ROOT}" rev-parse HEAD)" \
  >"${EVIDENCE}/runs/upload-bad.out" 2>"${EVIDENCE}/runs/upload-bad.err"
RC=$?
set -e
record "upload_reject_byte_mismatch" "${RC}" 1

# draft_full → publish
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-upload-draft.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-upload-draft.log" \
  APT_HUB_REL_STATE=draft_full \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  APT_HUB_DL_SRC="${OUT_BUILD}" \
  bash "${REL}" upload \
    --repository example/apt-hub \
    --tag apt-hub-go-7.7.7-1 \
    --asset-dir "${OUT_BUILD}" \
    --source-sha "$(git -C "${ROOT}" rev-parse HEAD)" \
  >"${EVIDENCE}/runs/upload-draft.out" 2>"${EVIDENCE}/runs/upload-draft.err"
RC=$?
set -e
record "upload_draft_publish" "${RC}" 0

set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-sha.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-sha.log" \
  bash "${REL}" upload \
    --repository example/apt-hub --tag apt-hub-go-7.7.7-1 \
    --asset-dir "${OUT_BUILD}" --source-sha latest \
  >"${EVIDENCE}/runs/upload-latest.out" 2>"${EVIDENCE}/runs/upload-latest.err"
RC=$?
set -e
record "upload_reject_latest_sha" "${RC}" 1

# prune
: >"${EVIDENCE}/runs/gh-prune.log"
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-prune.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-prune.log" \
  APT_HUB_GIT_LOG="${EVIDENCE}/runs/git-prune.log" \
  APT_HUB_APT_DATA=present \
  bash "${REL}" prune \
    --repository example/apt-hub \
    --current-tag apt-hub-go-7.7.7-1 \
    --keep-recent 2 \
  >"${EVIDENCE}/runs/prune.out" 2>"${EVIDENCE}/runs/prune.err"
RC=$?
set -e
record "prune_ok" "${RC}" 0
if grep -E 'prune_deleted_tag=apt-hub-go-(7\.7\.5|9\.9\.9)-1' "${EVIDENCE}/runs/prune.out" >/dev/null; then
  pass "prune 删除未保护同族 tag"
else
  fail "prune 未删除未保护候选"
fi
if grep -Fq 'prune_deleted_tag=apt-hub-go-7.7.6-1' "${EVIDENCE}/runs/prune.out"; then
  fail "prune 误删 apt-data/by-hash 引用版"
else
  pass "prune 保护 apt-data/by-hash 引用"
fi

set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-prune-err.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-prune-err.log" \
  APT_HUB_GIT_LOG="${EVIDENCE}/runs/git-prune-err.log" \
  APT_HUB_APT_DATA=error \
  bash "${REL}" prune --repository example/apt-hub --current-tag apt-hub-go-7.7.7-1 \
  >"${EVIDENCE}/runs/prune-err.out" 2>"${EVIDENCE}/runs/prune-err.err"
RC=$?
set -e
record "prune_refuse_on_aptdata_error" "${RC}" 1

# ---------- 真实抽取 workflow run 段并执行 helper 消费 ----------
BUILD_STEP="${EVIDENCE}/runs/wf-build-step.sh"
set +e
extract_step_run Build '复用或构包并上传' "${BUILD_STEP}" "${WF_REL}" \
  >"${EVIDENCE}/runs/wf-build-extract.log" 2>&1
ex_rc=$?
set -e
if [[ "${ex_rc}" -eq 0 && -s "${BUILD_STEP}" ]]; then
  pass "抽取 release.yml Build run 段"
else
  fail "未能抽取 Build run 段 rc=${ex_rc}"
fi
if grep -Fq 'scripts/release_golang.sh status' "${BUILD_STEP}" \
  && grep -Fq 'scripts/release_golang.sh upload' "${BUILD_STEP}" \
  && grep -Fq './build.sh' "${BUILD_STEP}" \
  && ! grep -Fiq 'zip' "${BUILD_STEP}"; then
  pass "Build 段消费 status/upload/build.sh 且不 zip"
else
  fail "Build 段未正确消费 helper"
fi

# 在沙箱中真实跑抽取的 Build 段（桩环境；published 复用路径）
WF_SANDBOX="${EVIDENCE}/runs/wf-build-sandbox"
rm -rf -- "${WF_SANDBOX}"
mkdir -p -- "${WF_SANDBOX}/scripts" "${WF_SANDBOX}/tmp" "${WF_SANDBOX}/config"
cp -a -- "${REL}" "${WF_SANDBOX}/scripts/release_golang.sh"
cp -a -- "${BUILD_SH}" "${GEN}" "${WF_SANDBOX}/"
cp -a -- "${CONFIG}" "${WF_SANDBOX}/config/go.json"
cp -a -- "${FIX_JSON}" "${WF_SANDBOX}/tmp/go-downloads.json"
# build.sh 需要 gen；published 复用不会调 build，但脚本仍 chmod
chmod a+x -- "${WF_SANDBOX}/build.sh" "${WF_SANDBOX}/gen_deb_golang.sh" \
  "${WF_SANDBOX}/scripts/release_golang.sh"
: >"${EVIDENCE}/runs/gh-wf-build.log"
set +e
(
  cd -- "${WF_SANDBOX}"
  export GH_TOKEN=t REPOSITORY=example/apt-hub TAG=apt-hub-go-7.7.7-1
  export GO_VERSION=go7.7.7 SOURCE_SHA="$(git -C "${ROOT}" rev-parse HEAD)"
  export GITHUB_OUTPUT="${EVIDENCE}/runs/wf-build.github_output"
  : >"${GITHUB_OUTPUT}"
  export PATH="${STUB_BIN}:${PATH}"
  export APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-wf-build.log"
  export APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-wf-build.log"
  export APT_HUB_REL_STATE=published
  export APT_HUB_ASSET_DIR="${OUT_BUILD}"
  export APT_HUB_DL_SRC="${OUT_BUILD}"
  bash "${BUILD_STEP}"
) >"${EVIDENCE}/runs/wf-build-run.out" 2>"${EVIDENCE}/runs/wf-build-run.err"
RC=$?
set -e
record "workflow_build_run_reuses_published" "${RC}" 0
grep -Fq 'go_release_tag=apt-hub-go-7.7.7-1' "${EVIDENCE}/runs/wf-build.github_output" \
  && pass "Build run 段写出 go_release_tag" || fail "Build run 段未写 go_release_tag"

PRE_STEP="${EVIDENCE}/runs/wf-preflight-secret.sh"
set +e
extract_step_run preflight '检查签名 secret 与 Pages URL' "${PRE_STEP}" "${WF_PUB}" \
  >"${EVIDENCE}/runs/wf-preflight-extract.log" 2>&1
ex_rc=$?
set -e
if [[ "${ex_rc}" -eq 0 && -s "${PRE_STEP}" ]] \
  && grep -Fq 'APT_HUB_GPG_PRIVATE_KEY' "${PRE_STEP}"; then
  pass "抽取 preflight Secret/Pages 真 run 段"
else
  fail "未能抽取 preflight Secret 段"
fi
# 缺私钥应失败（真跑抽取段）
PRE_RUN_DIR="${EVIDENCE}/runs/preflight-empty-cwd"
rm -rf -- "${PRE_RUN_DIR}"
mkdir -p -- "${PRE_RUN_DIR}"
set +e
(
  cd -- "${PRE_RUN_DIR}"
  env -u APT_HUB_GPG_PRIVATE_KEY \
    APT_HUB_GPG_PRIVATE_KEY='' \
    GH_TOKEN=t \
    GITHUB_REPOSITORY=example/apt-hub \
    GITHUB_OUTPUT="${EVIDENCE}/runs/preflight-empty.github_output" \
    bash "${PRE_STEP}"
) >"${EVIDENCE}/runs/preflight-empty.out" 2>"${EVIDENCE}/runs/preflight-empty.err"
RC=$?
set -e
record "preflight_rejects_empty_secret" "${RC}" 1

# ---------- git_tag 仅隔离 bare；主仓不执行 ----------
BARE="${EVIDENCE}/git/bare.git"
WORK="${EVIDENCE}/git/work"
rm -rf -- "${EVIDENCE}/git"
mkdir -p -- "${EVIDENCE}/git"
git init --bare --quiet "${BARE}"
git init --quiet "${WORK}"
git -C "${WORK}" remote add origin "${BARE}"
git -C "${WORK}" config user.name 'apt-hub-release-test'
git -C "${WORK}" config user.email 'apt-hub-release-test@invalid'
printf '0.1.0\n' >"${WORK}/VERSION"
printf '# test\n' >"${WORK}/README.md"
git -C "${WORK}" add VERSION README.md
git -C "${WORK}" commit --quiet -m 'init'
git -C "${WORK}" push --quiet origin HEAD:master 2>/dev/null \
  || git -C "${WORK}" push --quiet origin HEAD:main

MAIN_VER_BEFORE="$(tr -d '[:space:]' <"${ROOT}/VERSION")"
printf 'x\n' >"${WORK}/dirty"
set +e
bash -c "cd \"${WORK}\" && \"${GIT_TAG}\" auto" \
  >"${EVIDENCE}/runs/git-dirty.out" 2>"${EVIDENCE}/runs/git-dirty.err"
RC=$?
set -e
record "git_tag_dirty_refuse" "${RC}" 1
rm -f -- "${WORK}/dirty"

git -C "${WORK}" config --unset user.name || true
git -C "${WORK}" config --unset user.email || true
set +e
bash -c "cd \"${WORK}\" && \"${GIT_TAG}\" auto" \
  >"${EVIDENCE}/runs/git-noid.out" 2>"${EVIDENCE}/runs/git-noid.err"
RC=$?
set -e
record "git_tag_refuse_no_identity" "${RC}" 1
git -C "${WORK}" config user.name 'apt-hub-release-test'
git -C "${WORK}" config user.email 'apt-hub-release-test@invalid'

set +e
bash -c "cd \"${WORK}\" && \"${GIT_TAG}\" auto" \
  >"${EVIDENCE}/runs/git-auto.out" 2>"${EVIDENCE}/runs/git-auto.err"
RC=$?
set -e
record "git_tag_auto_push" "${RC}" 0
if [[ "$(tr -d '[:space:]' <"${WORK}/VERSION")" == "0.1.1" ]] \
  && git -C "${BARE}" rev-parse -q --verify refs/tags/v0.1.1 >/dev/null; then
  pass "git_tag auto 推送到隔离 bare"
else
  fail "git_tag auto 未完成"
fi
[[ "$(tr -d '[:space:]' <"${ROOT}/VERSION")" == "${MAIN_VER_BEFORE}" ]] \
  && pass "主仓 VERSION 未改且未执行主仓 git_tag" || fail "主仓 VERSION 被改"

set +e
bash -c "cd \"${WORK}\" && \"${GIT_TAG}\" --version 0.1.1" \
  >"${EVIDENCE}/runs/git-dup.out" 2>"${EVIDENCE}/runs/git-dup.err"
RC=$?
set -e
record "git_tag_existing_refuse" "${RC}" 1

git -C "${WORK}" remote set-url origin "${EVIDENCE}/git/no-such-bare.git"
set +e
bash -c "cd \"${WORK}\" && \"${GIT_TAG}\" auto" \
  >"${EVIDENCE}/runs/git-pushfail.out" 2>"${EVIDENCE}/runs/git-pushfail.err"
RC=$?
set -e
record "git_tag_push_refuse" "${RC}" 1

{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "PASS=${PASS}"
  echo "FAIL=${FAIL}"
  echo "OUT_BUILD=${OUT_BUILD}"
  [[ -f "${OUT_BUILD}/SHA256SUMS" ]] && { echo "SHA256SUMS<<"; cat "${OUT_BUILD}/SHA256SUMS"; }
  sha256sum -- "${GEN}" "${BUILD_SH}" "${REL}" "${GIT_TAG}" "${WF_REL}" "${WF_PUB}" 2>/dev/null || true
} | tee "${EVIDENCE}/summary.txt"

log "TOTAL PASS=${PASS} FAIL=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
