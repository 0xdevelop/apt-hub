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
  && grep -Eq '^  RemoveOldRelease:' "${WF_REL}" \
  && grep -Fq 'go_release_tag' "${WF_REL}" \
  && grep -Fq 'ncipollo/release-action@339a81892b84b4eeb0f6e744e4574d79d0d9b8dd' "${WF_REL}" \
  && grep -Fq 'skipIfReleaseExists: true' "${WF_REL}" \
  && grep -Fq 'get_pre_del_tag' "${WF_REL}" \
  && grep -Fq '清理旧脚本 Release' "${WF_REL}" \
  && ! grep -Fq '创建脚本 Release draft' "${WF_REL}" \
  && ! grep -Fq '发布脚本 Release' "${WF_REL}"; then
  pass "release.yml 母版 ncipollo + 两代清理 + Go 三段"
else
  fail "release.yml 母版收口不完整"
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
if [[ -f "${OUT_BUILD}/golang-go_7.7.7-1_amd64.deb" \
  && -f "${OUT_BUILD}/golang-go_7.7.7-1_arm64.deb" \
  && -f "${OUT_BUILD}/golang_7.7.7-1_amd64.deb" \
  && -f "${OUT_BUILD}/golang_7.7.7-1_arm64.deb" \
  && -f "${OUT_BUILD}/provenance.json" \
  && -f "${OUT_BUILD}/SHA256SUMS" ]]; then
  pass "build 单平面 4deb+manifest 齐全"
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
  api)
    # repos/OWNER/REPO/releases?per_page=100&page=N
    path="${2:-}"
    if [[ "${path}" == repos/*/releases* ]]; then
      if [[ "${path}" == *page=2* ]]; then
        if [[ "${APT_HUB_GH_PAGE2:-ok}" == "fail" ]]; then
          echo "page2 fixture fail" >&2
          exit 1
        fi
        printf '[]\n'
        exit 0
      fi
      if [[ "${APT_HUB_GH_PAGE2:-ok}" == "fail" ]]; then
        # 满页强制翻页，才能打到 page2 失败零 delete
        jq -n '[range(100)|{tag_name:("pad-\(.)"),draft:true,make_latest:"false",created_at:"2026-01-01T00:00:00Z"}]'
        exit 0
      fi
      # ≥4 已发布同族 + draft；旧版 7.7.4 仅靠 by-hash 全文 tag 保护（非 keep-recent）
      # draft/draft_full：tag 端点 404 后靠本列表 id 再 GET /releases/:id
      st="${APT_HUB_REL_STATE:-}"
      if [[ "${st}" == "draft" || "${st}" == "draft_full" ]]; then
        cat <<'JSON'
[{"id":88,"tag_name":"golang-7.7.8-1","draft":false,"make_latest":"false","created_at":"2026-01-05T00:00:00Z"},
 {"id":42,"tag_name":"golang-7.7.7-1","draft":true,"make_latest":"false","created_at":"2026-01-04T00:00:00Z"},
 {"id":86,"tag_name":"golang-7.7.6-1","draft":false,"make_latest":"false","created_at":"2026-01-03T00:00:00Z"},
 {"id":85,"tag_name":"golang-7.7.5-1","draft":false,"make_latest":"false","created_at":"2026-01-02T00:00:00Z"},
 {"id":84,"tag_name":"golang-7.7.4-1","draft":false,"make_latest":"false","created_at":"2026-01-01T00:00:00Z"},
 {"id":99,"tag_name":"golang-9.9.9-1","draft":true,"make_latest":"false","created_at":"2026-01-06T00:00:00Z"}]
JSON
      else
        cat <<'JSON'
[{"id":88,"tag_name":"golang-7.7.8-1","draft":false,"make_latest":"false","created_at":"2026-01-05T00:00:00Z"},
 {"id":87,"tag_name":"golang-7.7.7-1","draft":false,"make_latest":"false","created_at":"2026-01-04T00:00:00Z"},
 {"id":86,"tag_name":"golang-7.7.6-1","draft":false,"make_latest":"false","created_at":"2026-01-03T00:00:00Z"},
 {"id":85,"tag_name":"golang-7.7.5-1","draft":false,"make_latest":"false","created_at":"2026-01-02T00:00:00Z"},
 {"id":84,"tag_name":"golang-7.7.4-1","draft":false,"make_latest":"false","created_at":"2026-01-01T00:00:00Z"},
 {"id":99,"tag_name":"golang-9.9.9-1","draft":true,"make_latest":"false","created_at":"2026-01-06T00:00:00Z"}]
JSON
      fi
      exit 0
    fi
    echo "gh api unknown path: ${path}" >&2
    exit 2
    ;;
  release)
    sub="${2:-}"
    case "${sub}" in
      list)
        cat <<'JSON'
[{"tagName":"golang-7.7.8-1","isDraft":false,"isLatest":false,"createdAt":"2026-01-05T00:00:00Z"},
 {"tagName":"golang-7.7.7-1","isDraft":false,"isLatest":false,"createdAt":"2026-01-04T00:00:00Z"},
 {"tagName":"golang-7.7.6-1","isDraft":false,"isLatest":false,"createdAt":"2026-01-03T00:00:00Z"},
 {"tagName":"golang-7.7.5-1","isDraft":false,"isLatest":false,"createdAt":"2026-01-02T00:00:00Z"},
 {"tagName":"golang-7.7.4-1","isDraft":false,"isLatest":false,"createdAt":"2026-01-01T00:00:00Z"},
 {"tagName":"golang-9.9.9-1","isDraft":true,"isLatest":false,"createdAt":"2026-01-06T00:00:00Z"}]
JSON
        ;;
      view)
        tag="${3:-}"
        if [[ -n "${APT_HUB_GH_DELETED_RELEASES:-}" ]] \
          && [[ -f "${APT_HUB_GH_DELETED_RELEASES}" ]] \
          && grep -Fxq -- "${tag}" "${APT_HUB_GH_DELETED_RELEASES}"; then
          echo "not found" >&2
          exit 1
        fi
        case "${tag}" in
          golang-7.7.5-1|golang-7.7.6-1|golang-9.9.9-1) exit 0 ;;
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
      delete)
        tag="${3:-}"
        if [[ -n "${APT_HUB_GH_DELETED_RELEASES:-}" ]]; then
          printf '%s\n' "${tag}" >>"${APT_HUB_GH_DELETED_RELEASES}"
        fi
        echo "deleted $*"
        ;;
      *) echo "gh release unknown ${sub}" >&2; exit 2 ;;
    esac
    ;;
  *) echo "gh unknown: $*" >&2; exit 2 ;;
esac
EOF
chmod a+x -- "${STUB_BIN}/gh"
: >"${EVIDENCE}/runs/gh-deleted-releases.txt"


pub_assets_json() {
  local draft="$1"
  local amd arm prov sums
  amd="${APT_HUB_ASSET_DIR}/golang-go_7.7.7-1_amd64.deb"
  arm="${APT_HUB_ASSET_DIR}/golang-go_7.7.7-1_arm64.deb"
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
      {name:"golang-go_7.7.7-1_amd64.deb",size:$as,digest:$ad,id:11},
      {name:"golang-go_7.7.7-1_arm64.deb",size:$rs,digest:$rd,id:12},
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
    if [[ "${tag}" == "golang-7.7.7-1" && "${st}" == "published" ]]; then
      respond "$(APT_HUB_ASSET_DIR="${APT_HUB_ASSET_DIR}" bash -c 'source /dev/null; '"$(declare -f pub_assets_json)"'; pub_assets_json false')" 200
    elif [[ "${tag}" == "golang-7.7.7-1" && "${st}" == "published_bad" ]]; then
      respond '{"id":1,"draft":false,"prerelease":false,"assets":[{"name":"golang-go_7.7.7-1_amd64.deb","size":1,"digest":"sha256:dead","id":11}]}' 200
    elif [[ "${tag}" == "golang-7.7.7-1" && "${st}" == "draft" ]]; then
      respond "$(APT_HUB_ASSET_DIR="${APT_HUB_ASSET_DIR}" bash -c 'true')" 200
      # draft incomplete: only one asset / or full-but-draft
      respond '{"id":42,"draft":true,"prerelease":false,"assets":[{"name":"SHA256SUMS","size":10,"id":1}]}' 200
    elif [[ "${tag}" == "golang-7.7.7-1" && "${st}" == "draft_full" ]]; then
      body="$(
        amd="${APT_HUB_ASSET_DIR}/golang-go_7.7.7-1_amd64.deb"
        arm="${APT_HUB_ASSET_DIR}/golang-go_7.7.7-1_arm64.deb"
        prov="${APT_HUB_ASSET_DIR}/provenance.json"
        sums="${APT_HUB_ASSET_DIR}/SHA256SUMS"
        jq -n \
          --argjson as "$(stat -c '%s' -- "$amd")" --arg ad "sha256:$(sha256sum -- "$amd" | awk '{print $1}')" \
          --argjson rs "$(stat -c '%s' -- "$arm")" --arg rd "sha256:$(sha256sum -- "$arm" | awk '{print $1}')" \
          --argjson ps "$(stat -c '%s' -- "$prov")" --arg pd "sha256:$(sha256sum -- "$prov" | awk '{print $1}')" \
          --argjson ss "$(stat -c '%s' -- "$sums")" --arg sd "sha256:$(sha256sum -- "$sums" | awk '{print $1}')" \
          '{id:42,draft:true,prerelease:false,assets:[
            {name:"golang-go_7.7.7-1_amd64.deb",size:$as,digest:$ad,id:11},
            {name:"golang-go_7.7.7-1_arm64.deb",size:$rs,digest:$rd,id:12},
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
  local gga ggb ga gb prov sums html
  gga="${APT_HUB_ASSET_DIR}/golang-go_7.7.7-1_amd64.deb"
  ggb="${APT_HUB_ASSET_DIR}/golang-go_7.7.7-1_arm64.deb"
  ga="${APT_HUB_ASSET_DIR}/golang_7.7.7-1_amd64.deb"
  gb="${APT_HUB_ASSET_DIR}/golang_7.7.7-1_arm64.deb"
  prov="${APT_HUB_ASSET_DIR}/provenance.json"
  sums="${APT_HUB_ASSET_DIR}/SHA256SUMS"
  # draft 官方可能给 untagged-*；published 必须精确 tag URL
  if [[ "${draft}" == "true" ]]; then
    html="https://github.com/example/apt-hub/releases/tag/untagged-abcdef0123456789"
  else
    html="https://github.com/example/apt-hub/releases/tag/golang-7.7.7-1"
  fi
  jq -n \
    --argjson draft "${draft}" \
    --arg tag "golang-7.7.7-1" \
    --arg html "${html}" \
    --argjson gas "$(stat -c '%s' -- "$gga")" --arg gad "sha256:$(sha256sum -- "$gga" | awk '{print $1}')" \
    --argjson gbs "$(stat -c '%s' -- "$ggb")" --arg gbd "sha256:$(sha256sum -- "$ggb" | awk '{print $1}')" \
    --argjson as "$(stat -c '%s' -- "$ga")" --arg ad "sha256:$(sha256sum -- "$ga" | awk '{print $1}')" \
    --argjson bs "$(stat -c '%s' -- "$gb")" --arg bd "sha256:$(sha256sum -- "$gb" | awk '{print $1}')" \
    --argjson ps "$(stat -c '%s' -- "$prov")" --arg pd "sha256:$(sha256sum -- "$prov" | awk '{print $1}')" \
    --argjson ss "$(stat -c '%s' -- "$sums")" --arg sd "sha256:$(sha256sum -- "$sums" | awk '{print $1}')" \
    '{id:(if $draft then 42 else 1 end),tag_name:$tag,html_url:$html,draft:$draft,prerelease:false,assets:[
      {name:"golang-go_7.7.7-1_amd64.deb",size:$gas,digest:$gad,id:11},
      {name:"golang-go_7.7.7-1_arm64.deb",size:$gbs,digest:$gbd,id:12},
      {name:"golang_7.7.7-1_amd64.deb",size:$as,digest:$ad,id:15},
      {name:"golang_7.7.7-1_arm64.deb",size:$bs,digest:$bd,id:16},
      {name:"provenance.json",size:$ps,digest:$pd,id:13},
      {name:"SHA256SUMS",size:$ss,digest:$sd,id:14}
    ]}'
}
case "${url}" in
  https://api.github.com/repos/*/releases/tags/*)
    tag="${url##*/}"
    st="${APT_HUB_REL_STATE:-missing}"
    # 官方：draft 不出现在 tags 端点 → 404，再走 list+id
    if [[ "${tag}" != "golang-7.7.7-1" ]]; then
      respond '{"message":"Not Found"}' 404
    elif [[ "${st}" == "draft" || "${st}" == "draft_full" ]]; then
      respond '{"message":"Not Found"}' 404
    elif [[ "${st}" == "published" ]]; then
      respond "$(make_full false)" 200
    elif [[ "${st}" == "published_no_identity" ]]; then
      body="$(make_full false | jq 'del(.tag_name,.html_url)')"
      respond "${body}" 200
    elif [[ "${st}" == "published_bad_tag" ]]; then
      body="$(make_full false | jq '.tag_name="golang-0.0.0-1"')"
      respond "${body}" 200
    elif [[ "${st}" == "published_bad" ]]; then
      respond '{"id":1,"tag_name":"golang-7.7.7-1","html_url":"https://github.com/example/apt-hub/releases/tag/golang-7.7.7-1","draft":false,"prerelease":false,"assets":[{"name":"golang-go_7.7.7-1_amd64.deb","size":1,"digest":"sha256:dead","id":11}]}' 200
    else
      respond '{"message":"Not Found"}' 404
    fi
    ;;
  https://api.github.com/repos/*/releases/[0-9]*)
    rid="${url##*/}"
    st="${APT_HUB_REL_STATE:-missing}"
    if [[ "${rid}" == "42" && "${st}" == "draft" ]]; then
      respond '{"id":42,"tag_name":"golang-7.7.7-1","html_url":"https://github.com/example/apt-hub/releases/tag/untagged-abcdef0123456789","draft":true,"prerelease":false,"assets":[{"name":"SHA256SUMS","size":10,"id":1}]}' 200
    elif [[ "${rid}" == "42" && "${st}" == "draft_full" ]]; then
      respond "$(make_full true)" 200
    elif [[ "${rid}" == "1" ]]; then
      respond "$(make_full false)" 200
    else
      respond '{"message":"Not Found"}' 404
    fi
    ;;
  https://api.github.com/repos/*/tarball/*)
    tmpdir=$(mktemp -d)
    mkdir -p "${tmpdir}/repo/dists/stable/main/binary-amd64" "${tmpdir}/repo/by-hash/SHA256"
    # Packages 仅 underscore 文件名，不含完整 release tag——避免假绿。
    printf 'Package: apt-hub-go\nFilename: pool/main/apt-hub-go_7.7.8-1_amd64.deb\n' \
      >"${tmpdir}/repo/dists/stable/main/binary-amd64/Packages"
    # 无后缀 by-hash：gzip 魔数 + 完整 tag golang-7.7.4-1
    printf 'Filename: pool/main/x\nDescription: keep golang-7.7.4-1 referenced\n' \
      | gzip -c >"${tmpdir}/repo/by-hash/SHA256/deadbeef"
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
DEL="${APT_HUB_GIT_DELETED_TAGS:-/dev/null}"
printf 'git %s\n' "$*" >>"${LOG}"
if [[ "${1:-}" == "ls-remote" ]]; then
  # heads apt-data
  if [[ "$*" == *"--heads"* ]]; then
    if [[ "${APT_HUB_APT_DATA:-present}" == "absent" ]]; then exit 0; fi
    if [[ "${APT_HUB_APT_DATA:-present}" == "error" ]]; then echo "network fail" >&2; exit 1; fi
    echo "0123456789abcdef0123456789abcdef01234567	refs/heads/apt-data"
    exit 0
  fi
  # tags：删除后须空；未删除返回精确 ref
  if [[ "$*" == *"--tags"* ]]; then
    ref=""
    for a in "$@"; do
      case "$a" in refs/tags/*) ref="$a" ;; esac
    done
    tag="${ref#refs/tags/}"
    [[ -n "${tag}" ]] || exit 0
    if [[ -f "${DEL}" ]] && grep -Fxq -- "${tag}" "${DEL}" 2>/dev/null; then
      exit 0
    fi
    echo "0123456789abcdef0123456789abcdef01234567	refs/tags/${tag}"
    exit 0
  fi
  exit 0
fi
if [[ "${1:-}" == "push" ]]; then
  # :refs/tags/<tag> 记入已删集合
  for a in "$@"; do
    case "$a" in
      :refs/tags/*)
        if [[ -n "${APT_HUB_GIT_DELETED_TAGS:-}" ]]; then
          printf '%s\n' "${a#:refs/tags/}" >>"${APT_HUB_GIT_DELETED_TAGS}"
        fi
        ;;
    esac
  done
  exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod a+x -- "${STUB_BIN}/git"
: >"${EVIDENCE}/runs/git-deleted-tags.txt"


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
if grep -Fq 'go_release_tag=golang-7.7.7-1' "${EVIDENCE}/runs/prepare.out"; then
  pass "prepare 输出精确 tag"
else
  fail "prepare 未输出 golang-7.7.7-1"
fi

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
  bash "${REL}" status --repository example/apt-hub --tag golang-7.7.7-1 \
  >"${EVIDENCE}/runs/status-draft.out" 2>"${EVIDENCE}/runs/status-draft.err"
RC=$?
set -e
record "status_draft_ok" "${RC}" 0
if grep -Fq 'assets_complete=0' "${EVIDENCE}/runs/status-draft.out" \
  && grep -Fq 'release_state=draft' "${EVIDENCE}/runs/status-draft.out"; then
  pass "draft 不视 complete"
else
  fail "draft 被误标 complete"
fi

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
  bash "${REL}" status --repository example/apt-hub --tag golang-7.7.7-1 \
    --fetch-dir "${FETCH_DIR}" \
  >"${EVIDENCE}/runs/status-pub.out" 2>"${EVIDENCE}/runs/status-pub.err"
RC=$?
set -e
record "status_published_reuse" "${RC}" 0
if grep -Fq 'assets_reused=1' "${EVIDENCE}/runs/status-pub.out" \
  && [[ -f "${FETCH_DIR}/provenance.json" ]]; then
  pass "published 完整资产可复用"
else
  fail "published 复用失败"
fi

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
    --tag golang-7.7.7-1 \
    --asset-dir "${OUT_BUILD}" \
    --source-sha "$(git -C "${ROOT}" rev-parse HEAD)" \
  >"${EVIDENCE}/runs/upload-idem.out" 2>"${EVIDENCE}/runs/upload-idem.err"
RC=$?
set -e
record "upload_idempotent_published" "${RC}" 0
if grep -Fq 'upload_status=idempotent_published' "${EVIDENCE}/runs/upload-idem.out"; then
  pass "upload 幂等 published"
else
  fail "upload 未走幂等"
fi

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
    --tag golang-7.7.7-1 \
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
    --tag golang-7.7.7-1 \
    --asset-dir "${OUT_BUILD}" \
    --source-sha "$(git -C "${ROOT}" rev-parse HEAD)" \
  >"${EVIDENCE}/runs/upload-draft.out" 2>"${EVIDENCE}/runs/upload-draft.err"
RC=$?
set -e
record "upload_draft_publish" "${RC}" 0
if grep -Fq 'release edit' "${EVIDENCE}/runs/gh-upload-draft.log"; then
  pass "draft_full 完整集才 edit publish"
else
  fail "draft_full 未调用 edit"
fi

# 半套 asset-dir（仅 amd64 + 原双 arch manifest/sums）在任何外部写前拒绝
HALF_DIR="${EVIDENCE}/runs/upload-half-assets"
rm -rf -- "${HALF_DIR}"
mkdir -p -- "${HALF_DIR}"
# 半套：原双 arch 双包 manifest/sums + 仅 amd64 golang-go（缺其余 3 deb）
cp -a -- "${OUT_BUILD}/provenance.json" "${OUT_BUILD}/SHA256SUMS" \
  "${OUT_BUILD}/golang-go_7.7.7-1_amd64.deb" "${HALF_DIR}/"
: >"${EVIDENCE}/runs/gh-upload-half.log"
: >"${EVIDENCE}/runs/curl-upload-half.log"
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-upload-half.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-upload-half.log" \
  APT_HUB_REL_STATE=draft_full \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  APT_HUB_DL_SRC="${OUT_BUILD}" \
  bash "${REL}" upload \
    --repository example/apt-hub \
    --tag golang-7.7.7-1 \
    --asset-dir "${HALF_DIR}" \
    --source-sha "$(git -C "${ROOT}" rev-parse HEAD)" \
  >"${EVIDENCE}/runs/upload-half.out" 2>"${EVIDENCE}/runs/upload-half.err"
RC=$?
set -e
record "upload_half_set_rejects" "${RC}" 1
if grep -E 'release (create|upload|edit)' "${EVIDENCE}/runs/gh-upload-half.log" >/dev/null; then
  fail "半套 upload 仍有外部写"
else
  pass "半套 upload 无 create/upload/edit"
fi

# 四行清单仅 3 唯一 (package,arch)：重复 amd64 缺 golang/arm64 + 孤儿坏包 → 拒发布写
DUP_DIR="${EVIDENCE}/runs/upload-dup-pair-assets"
rm -rf -- "${DUP_DIR}"
mkdir -p -- "${DUP_DIR}"
cp -a -- "${OUT_BUILD}/"*.deb "${DUP_DIR}/"
jq '.packages[3]=.packages[0]' "${OUT_BUILD}/provenance.json" >"${DUP_DIR}/provenance.json"
printf 'UNMANIFESTED AND NOT A DEB\n' >"${DUP_DIR}/golang_7.7.7-1_arm64.deb"
(
  cd -- "${DUP_DIR}"
  mapfile -t listed < <(jq -r '.packages[].filename' provenance.json | LC_ALL=C sort -u)
  sha256sum -- provenance.json "${listed[@]}" >SHA256SUMS
)
DUP_BEFORE_SHA="$(sha256sum -- "${DUP_DIR}/golang_7.7.7-1_arm64.deb" | awk '{print $1}')"
: >"${EVIDENCE}/runs/gh-upload-dup.log"
: >"${EVIDENCE}/runs/curl-upload-dup.log"
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-upload-dup.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-upload-dup.log" \
  APT_HUB_REL_STATE=draft_full \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  APT_HUB_DL_SRC="${OUT_BUILD}" \
  bash "${REL}" upload \
    --repository example/apt-hub \
    --tag golang-7.7.7-1 \
    --asset-dir "${DUP_DIR}" \
    --source-sha "$(git -C "${ROOT}" rev-parse HEAD)" \
  >"${EVIDENCE}/runs/upload-dup.out" 2>"${EVIDENCE}/runs/upload-dup.err"
RC=$?
set -e
record "upload_reject_duplicate_missing_pair" "${RC}" 1
if grep -E 'release (create|upload|edit)' "${EVIDENCE}/runs/gh-upload-dup.log" >/dev/null; then
  fail "缺组合/孤儿 upload 仍有外部写"
else
  pass "缺组合/孤儿 upload 无 create/upload/edit"
fi
DUP_AFTER_SHA="$(sha256sum -- "${DUP_DIR}/golang_7.7.7-1_arm64.deb" | awk '{print $1}')"
if [[ "${DUP_BEFORE_SHA}" == "${DUP_AFTER_SHA}" ]]; then
  pass "缺组合拒绝后输入未改"
else
  fail "缺组合拒绝后输入被改"
fi
if jq -e '((.packages|length)==4) and (([.packages[]|[.package,.architecture]]|unique|length)==3)' \
  "${DUP_DIR}/provenance.json" >/dev/null; then
  pass "反例仍为 4 行 3 唯一组合"
else
  fail "反例 fixture 形态漂移"
fi

# prepare：stable 枚举 jq 先合法后失败（畸形数组尾）必须非 0
MALFORMED_STABLE="${EVIDENCE}/fixtures/stable-partial.json"
printf '[{"version":"go7.7.7","stable":true},0]\n' >"${MALFORMED_STABLE}"
set +e
/usr/bin/jq -r '.[] | select(.stable==true) | .version' "${MALFORMED_STABLE}" \
  >"${EVIDENCE}/runs/stable-jq.out" 2>"${EVIDENCE}/runs/stable-jq.err"
STABLE_JQ_RC=$?
set -e
record "stable_jq_partial_nonzero" "${STABLE_JQ_RC}" 5
MAL_PREP="${ROOT}/tmp/delivery-v16/release/malformed-stable-prep"
rm -rf -- "${MAL_PREP}"
set +e
bash "${REL}" prepare \
  --repository example/apt-hub \
  --config "${CONFIG}" \
  --work-dir "${MAL_PREP}" \
  --downloads-json "${MALFORMED_STABLE}" \
  >"${EVIDENCE}/runs/prepare-stable-partial.out" 2>"${EVIDENCE}/runs/prepare-stable-partial.err"
RC=$?
set -e
record "prepare_rejects_stable_producer_partial" "${RC}" 1
if grep -Fq 'go_release_tag=' "${EVIDENCE}/runs/prepare-stable-partial.out"; then
  fail "stable 半截 producer 仍输出 tag"
else
  pass "stable 半截 producer 无成功输出"
fi
if [[ -f "${MALFORMED_STABLE}" ]]; then
  pass "畸形索引输入未改"
else
  fail "畸形索引输入丢失"
fi

# status 缺 tag_name/html_url 不得 reuse
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-status-noid.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-status-noid.log" \
  APT_HUB_REL_STATE=published_no_identity \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  APT_HUB_DL_SRC="${OUT_BUILD}" \
  bash "${REL}" status --repository example/apt-hub --tag golang-7.7.7-1 \
    --fetch-dir "${ROOT}/tmp/delivery-v16/release/fetch-noid" \
  >"${EVIDENCE}/runs/status-noid.out" 2>"${EVIDENCE}/runs/status-noid.err"
RC=$?
set -e
record "status_reject_missing_identity" "${RC}" 1
if grep -Fq 'assets_reused=1' "${EVIDENCE}/runs/status-noid.out"; then
  fail "缺身份仍 assets_reused"
else
  pass "缺身份拒绝 reuse"
fi

set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-status-badtag.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-status-badtag.log" \
  APT_HUB_REL_STATE=published_bad_tag \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  bash "${REL}" status --repository example/apt-hub --tag golang-7.7.7-1 \
  >"${EVIDENCE}/runs/status-badtag.out" 2>"${EVIDENCE}/runs/status-badtag.err"
RC=$?
set -e
record "status_reject_mismatched_tag_name" "${RC}" 1

set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-sha.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-sha.log" \
  bash "${REL}" upload \
    --repository example/apt-hub --tag golang-7.7.7-1 \
    --asset-dir "${OUT_BUILD}" --source-sha latest \
  >"${EVIDENCE}/runs/upload-latest.out" 2>"${EVIDENCE}/runs/upload-latest.err"
RC=$?
set -e
record "upload_reject_latest_sha" "${RC}" 1

# prune：≥4 成功版本；keep-recent=2 保护 7.7.8/7.7.7；by-hash gzip 全文保护 7.7.4
: >"${EVIDENCE}/runs/gh-prune.log"
: >"${EVIDENCE}/runs/git-deleted-tags.txt"
: >"${EVIDENCE}/runs/gh-deleted-releases.txt"
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-prune.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-prune.log" \
  APT_HUB_GIT_LOG="${EVIDENCE}/runs/git-prune.log" \
  APT_HUB_GIT_DELETED_TAGS="${EVIDENCE}/runs/git-deleted-tags.txt" \
  APT_HUB_GH_DELETED_RELEASES="${EVIDENCE}/runs/gh-deleted-releases.txt" \
  APT_HUB_APT_DATA=present \
  bash "${REL}" prune \
    --repository example/apt-hub \
    --current-tag golang-7.7.8-1 \
    --keep-recent 2 \
  >"${EVIDENCE}/runs/prune.out" 2>"${EVIDENCE}/runs/prune.err"
RC=$?
set -e
record "prune_ok" "${RC}" 0
if grep -E 'prune_deleted_tag=golang-(7\.7\.5|7\.7\.6|9\.9\.9)-1' "${EVIDENCE}/runs/prune.out" >/dev/null; then
  pass "prune 删除未保护同族 tag"
else
  fail "prune 未删除未保护候选"
fi
if grep -Fq 'prune_deleted_tag=golang-7.7.4-1' "${EVIDENCE}/runs/prune.out"; then
  fail "prune 误删 by-hash gzip 全文引用版 7.7.4"
else
  pass "prune 保护 by-hash gzip 全文 tag"
fi
if grep -Fq 'prune_deleted_tag=golang-7.7.7-1' "${EVIDENCE}/runs/prune.out" \
  || grep -Fq 'prune_deleted_tag=golang-7.7.8-1' "${EVIDENCE}/runs/prune.out"; then
  fail "prune 误删 keep-recent 保护集"
else
  pass "prune 保留 keep-recent=2"
fi

set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-prune-err.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-prune-err.log" \
  APT_HUB_GIT_LOG="${EVIDENCE}/runs/git-prune-err.log" \
  APT_HUB_GIT_DELETED_TAGS="${EVIDENCE}/runs/git-deleted-tags-err.txt" \
  APT_HUB_APT_DATA=error \
  bash "${REL}" prune --repository example/apt-hub --current-tag golang-7.7.8-1 \
  >"${EVIDENCE}/runs/prune-err.out" 2>"${EVIDENCE}/runs/prune-err.err"
RC=$?
set -e
record "prune_refuse_on_aptdata_error" "${RC}" 1

# 第二页失败 → 零 delete
: >"${EVIDENCE}/runs/gh-prune-page2.log"
: >"${EVIDENCE}/runs/git-deleted-tags-page2.txt"
set +e
env PATH="${STUB_BIN}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-prune-page2.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-prune-page2.log" \
  APT_HUB_GIT_LOG="${EVIDENCE}/runs/git-prune-page2.log" \
  APT_HUB_GIT_DELETED_TAGS="${EVIDENCE}/runs/git-deleted-tags-page2.txt" \
  APT_HUB_APT_DATA=present \
  APT_HUB_GH_PAGE2=fail \
  bash "${REL}" prune --repository example/apt-hub --current-tag golang-7.7.8-1 \
  >"${EVIDENCE}/runs/prune-page2.out" 2>"${EVIDENCE}/runs/prune-page2.err"
RC=$?
set -e
record "prune_page2_fail_nonzero" "${RC}" 1
if grep -Fq 'prune_deleted_tag=' "${EVIDENCE}/runs/prune-page2.out" \
  || grep -Fq 'release delete' "${EVIDENCE}/runs/gh-prune-page2.log"; then
  fail "page2 失败仍发生 delete"
else
  pass "page2 失败零 delete"
fi

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
  && grep -Eq 'st_rc=|up_rc=' "${BUILD_STEP}" \
  && ! grep -Eq '(^|[[:space:]])zip([[:space:]]|-)' "${BUILD_STEP}" \
  && ! grep -Fq '.zip' "${BUILD_STEP}"; then
  pass "Build 段消费 status/upload/build.sh 且捕获非0"
else
  fail "Build 段未正确消费 helper/退出码"
fi

# prepare 真 run 段：partial 合法键 + 非0 不得当成功
PREP_STEP="${EVIDENCE}/runs/wf-prepare-step.sh"
set +e
extract_step_run prepare prepare "${PREP_STEP}" "${WF_REL}" \
  >"${EVIDENCE}/runs/wf-prepare-extract.log" 2>&1
ex_rc=$?
set -e
if [[ "${ex_rc}" -eq 0 && -s "${PREP_STEP}" ]] && grep -Fq 'prep_rc' "${PREP_STEP}"; then
  pass "抽取 prepare run 段且捕获 prep_rc"
else
  fail "未能抽取 prepare 退出码捕获段"
fi
PARTIAL_SANDBOX="${EVIDENCE}/runs/prepare-partial-sandbox"
rm -rf -- "${PARTIAL_SANDBOX}"
mkdir -p -- "${PARTIAL_SANDBOX}/scripts" "${PARTIAL_SANDBOX}/tmp" "${PARTIAL_SANDBOX}/config"
cp -a -- "${CONFIG}" "${PARTIAL_SANDBOX}/config/go.json"
cat >"${PARTIAL_SANDBOX}/scripts/release_golang.sh" <<'PARTIAL'
#!/usr/bin/env bash
# fixture：先吐合法键再 exit 24，验证 workflow 不吞非0
set -euo pipefail
printf 'go_release_tag=golang-0.0.0-1\n'
printf 'go_version=go0.0.0\n'
printf 'downloads_json=/tmp/no-such-downloads.json\n'
exit 24
PARTIAL
chmod a+x -- "${PARTIAL_SANDBOX}/scripts/release_golang.sh"
: >"${EVIDENCE}/runs/prepare-partial.github_output"
set +e
env -C "${PARTIAL_SANDBOX}" \
  REPOSITORY=example/apt-hub \
  GITHUB_OUTPUT="${EVIDENCE}/runs/prepare-partial.github_output" \
  bash "${PREP_STEP}" \
  >"${EVIDENCE}/runs/prepare-partial.out" 2>"${EVIDENCE}/runs/prepare-partial.err"
RC=$?
set -e
record "prepare_partial_nonzero_not_success" "${RC}" 24
if [[ -s "${EVIDENCE}/runs/prepare-partial.github_output" ]] \
  && grep -Fq 'go_release_tag=' "${EVIDENCE}/runs/prepare-partial.github_output"; then
  fail "partial prepare 仍写出 GITHUB_OUTPUT"
else
  pass "partial prepare 未写出成功 outputs"
fi

# 路径：祖先 symlink / .. / 非空无哨兵 拒绝
SYMLINK_BASE="${ROOT}/tmp/delivery-v16/release/path-probe"
rm -rf -- "${SYMLINK_BASE}"
mkdir -p -- "${SYMLINK_BASE}/real" "${ROOT}/tmp/delivery-v16/release/path-victim"
ln -s -- "${SYMLINK_BASE}/real" "${SYMLINK_BASE}/link"
set +e
bash "${REL}" prepare --repository example/apt-hub --config "${CONFIG}" \
  --work-dir "${SYMLINK_BASE}/link/nested" --downloads-json "${FIX_JSON}" \
  >"${EVIDENCE}/runs/path-symlink.out" 2>"${EVIDENCE}/runs/path-symlink.err"
RC=$?
set -e
record "prepare_reject_symlink_component" "${RC}" 1
printf 'keep\n' >"${ROOT}/tmp/delivery-v16/release/path-victim/user.txt"
set +e
bash "${REL}" prepare --repository example/apt-hub --config "${CONFIG}" \
  --work-dir "${ROOT}/tmp/delivery-v16/release/path-victim" --downloads-json "${FIX_JSON}" \
  >"${EVIDENCE}/runs/path-nonempty.out" 2>"${EVIDENCE}/runs/path-nonempty.err"
RC=$?
set -e
record "prepare_reject_nonempty_unowned" "${RC}" 1
if [[ -f "${ROOT}/tmp/delivery-v16/release/path-victim/user.txt" ]]; then
  pass "未 rm 调用者已有目录内容"
else
  fail "误删调用者目录"
fi

# parent 实证反例：work-dir 内已有 marker+downloads-json，重叠拒绝且不得删输入
OVERLAP="${ROOT}/tmp/delivery-v16/release/overlap-owned"
rm -rf -- "${OVERLAP}"
mkdir -p -- "${OVERLAP}"
printf 'owned\n' >"${OVERLAP}/.apt-hub-release-owned"
cp -a -- "${FIX_JSON}" "${OVERLAP}/input.json"
set +e
bash "${REL}" prepare \
  --repository example/apt-hub \
  --config "${CONFIG}" \
  --work-dir "${OVERLAP}" \
  --downloads-json "${OVERLAP}/input.json" \
  --version go7.7.7 \
  >"${EVIDENCE}/runs/overlap-owned.out" 2>"${EVIDENCE}/runs/overlap-owned.err"
RC=$?
set -e
record "prepare_overlap_owned_rejects" "${RC}" 1
if [[ -f "${OVERLAP}/input.json" ]]; then
  pass "overlap 拒绝后输入仍在"
else
  fail "overlap 拒绝时输入被删"
fi

# status/upload 真 run 段：partial 合法键 + 非0 不得当成功、无后续动作
BUILD_PARTIAL_STATUS="${EVIDENCE}/runs/status-partial-sandbox"
rm -rf -- "${BUILD_PARTIAL_STATUS}"
mkdir -p -- "${BUILD_PARTIAL_STATUS}/scripts" "${BUILD_PARTIAL_STATUS}/tmp" "${BUILD_PARTIAL_STATUS}/config"
cp -a -- "${CONFIG}" "${BUILD_PARTIAL_STATUS}/config/go.json"
cat >"${BUILD_PARTIAL_STATUS}/scripts/release_golang.sh" <<'PARTIAL'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
shift || true
case "${cmd}" in
  status)
    printf 'release_state=published\n'
    printf 'assets_complete=1\n'
    printf 'assets_reused=1\n'
    printf 'go_release_tag=golang-0.0.0-1\n'
    exit 24
    ;;
  upload)
    printf 'upload_status=published\n'
    printf 'go_release_tag=golang-0.0.0-1\n'
    exit 24
    ;;
  *) echo "unexpected ${cmd}" >&2; exit 2 ;;
esac
PARTIAL
chmod a+x -- "${BUILD_PARTIAL_STATUS}/scripts/release_golang.sh"
: >"${BUILD_PARTIAL_STATUS}/gen_deb_golang.sh"
chmod a+x -- "${BUILD_PARTIAL_STATUS}/gen_deb_golang.sh"
# 最小 build.sh：若 status 失败后仍被调用则留下脚印
cat >"${BUILD_PARTIAL_STATUS}/build.sh" <<'B'
#!/usr/bin/env bash
printf 'build_ran\n' >tmp/build-ran.flag
exit 0
B
chmod a+x -- "${BUILD_PARTIAL_STATUS}/build.sh"
: >"${EVIDENCE}/runs/status-partial.github_output"
set +e
env -C "${BUILD_PARTIAL_STATUS}" \
  GH_TOKEN=t \
  REPOSITORY=example/apt-hub \
  TAG=golang-7.7.7-1 \
  GO_VERSION=go7.7.7 \
  SOURCE_SHA="$(git -C "${ROOT}" rev-parse HEAD)" \
  GITHUB_OUTPUT="${EVIDENCE}/runs/status-partial.github_output" \
  bash "${BUILD_STEP}" \
  >"${EVIDENCE}/runs/status-partial.out" 2>"${EVIDENCE}/runs/status-partial.err"
RC=$?
set -e
record "status_partial_nonzero_not_success" "${RC}" 24
if [[ -f "${BUILD_PARTIAL_STATUS}/tmp/build-ran.flag" ]] \
  || grep -Fq 'go_release_tag=' "${EVIDENCE}/runs/status-partial.github_output"; then
  fail "status partial 仍继续构包或写出 output"
else
  pass "status partial 无后续动作/无成功 output"
fi

BUILD_PARTIAL_UPLOAD="${EVIDENCE}/runs/upload-partial-sandbox"
rm -rf -- "${BUILD_PARTIAL_UPLOAD}"
mkdir -p -- "${BUILD_PARTIAL_UPLOAD}/scripts" "${BUILD_PARTIAL_UPLOAD}/tmp/go-release-assets" \
  "${BUILD_PARTIAL_UPLOAD}/config"
cp -a -- "${CONFIG}" "${BUILD_PARTIAL_UPLOAD}/config/go.json"
cp -a -- "${OUT_BUILD}/." "${BUILD_PARTIAL_UPLOAD}/tmp/go-release-assets/"
# Build 段在非 reuse 时会 rm -rf assets 再调 build；预存副本供 stub 回填。
mkdir -p -- "${BUILD_PARTIAL_UPLOAD}/tmp/asset-seed"
cp -a -- "${OUT_BUILD}/." "${BUILD_PARTIAL_UPLOAD}/tmp/asset-seed/"
cat >"${BUILD_PARTIAL_UPLOAD}/scripts/release_golang.sh" <<'PARTIAL'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
shift || true
case "${cmd}" in
  status)
    # 强制走构包后 upload：不 reuse
    printf 'release_state=missing\n'
    printf 'assets_complete=0\n'
    printf 'go_release_tag=golang-7.7.7-1\n'
    exit 0
    ;;
  upload)
    printf 'upload_status=published\n'
    printf 'go_release_tag=golang-0.0.0-1\n'
    exit 24
    ;;
  *) echo "unexpected ${cmd}" >&2; exit 2 ;;
esac
PARTIAL
chmod a+x -- "${BUILD_PARTIAL_UPLOAD}/scripts/release_golang.sh"
: >"${BUILD_PARTIAL_UPLOAD}/gen_deb_golang.sh"
chmod a+x -- "${BUILD_PARTIAL_UPLOAD}/gen_deb_golang.sh"
cat >"${BUILD_PARTIAL_UPLOAD}/build.sh" <<'B'
#!/usr/bin/env bash
set -euo pipefail
# workflow 可能先 rm assets；从 seed 回填使 upload 段可到达
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${out}" ]]
mkdir -p -- "${out}"
cp -a -- tmp/asset-seed/. "${out}/"
printf 'build_ran\n' >tmp/build-ran.flag
exit 0
B
chmod a+x -- "${BUILD_PARTIAL_UPLOAD}/build.sh"
: >"${EVIDENCE}/runs/upload-partial.github_output"
set +e
env -C "${BUILD_PARTIAL_UPLOAD}" \
  GH_TOKEN=t \
  REPOSITORY=example/apt-hub \
  TAG=golang-7.7.7-1 \
  GO_VERSION=go7.7.7 \
  SOURCE_SHA="$(git -C "${ROOT}" rev-parse HEAD)" \
  GITHUB_OUTPUT="${EVIDENCE}/runs/upload-partial.github_output" \
  bash "${BUILD_STEP}" \
  >"${EVIDENCE}/runs/upload-partial.out" 2>"${EVIDENCE}/runs/upload-partial.err"
RC=$?
set -e
record "upload_partial_nonzero_not_success" "${RC}" 24
if grep -Fq 'go_release_tag=' "${EVIDENCE}/runs/upload-partial.github_output"; then
  fail "upload partial 仍写出 GITHUB_OUTPUT"
else
  pass "upload partial 未写出成功 outputs"
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
: >"${EVIDENCE}/runs/wf-build.github_output"
SOURCE_SHA="$(git -C "${ROOT}" rev-parse HEAD)"
set +e
env -C "${WF_SANDBOX}" \
  PATH="${STUB_BIN}:${PATH}" \
  GH_TOKEN=t \
  REPOSITORY=example/apt-hub \
  TAG=golang-7.7.7-1 \
  GO_VERSION=go7.7.7 \
  SOURCE_SHA="${SOURCE_SHA}" \
  GITHUB_OUTPUT="${EVIDENCE}/runs/wf-build.github_output" \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-wf-build.log" \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-wf-build.log" \
  APT_HUB_REL_STATE=published \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  APT_HUB_DL_SRC="${OUT_BUILD}" \
  bash "${BUILD_STEP}" \
  >"${EVIDENCE}/runs/wf-build-run.out" 2>"${EVIDENCE}/runs/wf-build-run.err"
RC=$?
set -e
record "workflow_build_run_reuses_published" "${RC}" 0
if grep -Fq 'go_release_tag=golang-7.7.7-1' "${EVIDENCE}/runs/wf-build.github_output"; then
  pass "Build run 段写出 go_release_tag"
else
  fail "Build run 段未写 go_release_tag"
fi

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
: >"${EVIDENCE}/runs/preflight-empty.github_output"
set +e
env -C "${PRE_RUN_DIR}" -u APT_HUB_GPG_PRIVATE_KEY \
  APT_HUB_GPG_PRIVATE_KEY='' \
  GH_TOKEN=t \
  GITHUB_REPOSITORY=example/apt-hub \
  GITHUB_OUTPUT="${EVIDENCE}/runs/preflight-empty.github_output" \
  bash "${PRE_STEP}" \
  >"${EVIDENCE}/runs/preflight-empty.out" 2>"${EVIDENCE}/runs/preflight-empty.err"
RC=$?
set -e
record "preflight_rejects_empty_secret" "${RC}" 1

# ---------- 母版脚本 Release：ncipollo 静态 + 两代前 get_pre_del 真 run ----------
if grep -Fq 'bodyFile: changelog/' "${WF_REL}" \
  && grep -Fq 'steps.script_tag.outputs.tag' "${WF_REL}" \
  && grep -Fq "if: steps.script_tag.outputs.ok == '1'" "${WF_REL}" \
  && grep -Fq 'makeLatest: false' "${WF_REL}"; then
  pass "ncipollo 仅严格 vtag + 精确 tag/bodyFile"
else
  fail "ncipollo 参数未按母版收口"
fi

SCRIPT_TAG_STEP="${EVIDENCE}/runs/wf-script-tag-step.sh"
SCRIPT_PRUNE_STEP="${EVIDENCE}/runs/wf-script-prune-step.sh"
set +e
extract_step_run prepare '解析脚本 tag' "${SCRIPT_TAG_STEP}" "${WF_REL}" \
  >"${EVIDENCE}/runs/wf-script-tag-extract.log" 2>&1
ex_tag=$?
extract_step_run RemoveOldRelease '清理旧脚本 Release' "${SCRIPT_PRUNE_STEP}" "${WF_REL}" \
  >"${EVIDENCE}/runs/wf-script-prune-extract.log" 2>&1
ex_prune=$?
set -e
record "extract_script_tag_step" "${ex_tag}" 0
record "extract_script_prune_step" "${ex_prune}" 0

: >"${EVIDENCE}/runs/script-tag-nontag.github_output"
set +e
env EVENT_NAME=workflow_dispatch REF=refs/heads/main \
  GITHUB_OUTPUT="${EVIDENCE}/runs/script-tag-nontag.github_output" \
  bash "${SCRIPT_TAG_STEP}" \
  >"${EVIDENCE}/runs/script-tag-nontag.out" 2>"${EVIDENCE}/runs/script-tag-nontag.err"
RC=$?
set -e
record "script_tag_skip_nontag" "${RC}" 0
if grep -Fq 'ok=0' "${EVIDENCE}/runs/script-tag-nontag.github_output"; then
  pass "非 push 不启用 ncipollo"
else
  fail "非 push 仍 ok=1"
fi

: >"${EVIDENCE}/runs/script-tag-ok.github_output"
set +e
env EVENT_NAME=push REF=refs/tags/v0.0.5 \
  GITHUB_OUTPUT="${EVIDENCE}/runs/script-tag-ok.github_output" \
  bash "${SCRIPT_TAG_STEP}" \
  >"${EVIDENCE}/runs/script-tag-ok.out" 2>"${EVIDENCE}/runs/script-tag-ok.err"
RC=$?
set -e
record "script_tag_strict_ok" "${RC}" 0
if grep -Fq 'ok=1' "${EVIDENCE}/runs/script-tag-ok.github_output" \
  && grep -Fq 'tag=v0.0.5' "${EVIDENCE}/runs/script-tag-ok.github_output"; then
  pass "严格 vtag 解析"
else
  fail "严格 vtag 未解析"
fi

: >"${EVIDENCE}/runs/script-tag-beta.github_output"
set +e
env EVENT_NAME=push REF=refs/tags/v0.0.5-beta \
  GITHUB_OUTPUT="${EVIDENCE}/runs/script-tag-beta.github_output" \
  bash "${SCRIPT_TAG_STEP}" \
  >"${EVIDENCE}/runs/script-tag-beta.out" 2>"${EVIDENCE}/runs/script-tag-beta.err"
RC=$?
set -e
record "script_tag_reject_nonstrict" "${RC}" 0
if grep -Fq 'ok=0' "${EVIDENCE}/runs/script-tag-beta.github_output"; then
  pass "非严格 v* 不启用 ncipollo"
else
  fail "非严格仍 ok=1"
fi

SCRIPT_STUB="${EVIDENCE}/bin-script"
rm -rf -- "${SCRIPT_STUB}"
mkdir -p -- "${SCRIPT_STUB}" "${EVIDENCE}/runs/script-state"
cat >"${SCRIPT_STUB}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="${APT_HUB_GH_LOG:?}"
STATE="${APT_HUB_SCRIPT_STATE:?}"
printf 'gh %s\n' "$*" >>"${LOG}"
cmd="${1:-}"
case "${cmd}" in
  release)
    sub="${2:-}"
    case "${sub}" in
      view)
        tag="${3:-}"
        mode="${APT_HUB_SCRIPT_VIEW_MODE:-}"
        if [[ "${mode}" == "http503" ]]; then
          echo "HTTP 503: Service Unavailable" >&2
          exit 1
        fi
        if [[ "${mode}" == "http404" ]]; then
          echo "HTTP 404: Not Found" >&2
          exit 1
        fi
        if [[ ! -f "${STATE}/${tag}.present" ]]; then
          echo "release not found" >&2
          exit 1
        fi
        exit 0
        ;;
      delete)
        tag="${3:-}"
        [[ -f "${STATE}/${tag}.present" ]] || { echo "missing ${tag}" >&2; exit 1; }
        rm -f -- "${STATE}/${tag}.present"
        printf 'deleted %s\n' "${tag}" >>"${STATE}/deleted.log"
        echo "deleted ${tag}"
        ;;
      *) echo "release sub unknown: ${sub}" >&2; exit 2 ;;
    esac
    ;;
  *) echo "gh unknown: $*" >&2; exit 2 ;;
esac
EOF
chmod a+x -- "${SCRIPT_STUB}/gh"
cat >"${SCRIPT_STUB}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="${APT_HUB_GH_LOG:?}"
STATE="${APT_HUB_SCRIPT_STATE:?}"
printf 'git %s\n' "$*" >>"${LOG}"
if [[ "${1:-}" == "push" && "${2:-}" == "origin" && "${3:-}" == "--delete" ]]; then
  printf 'git-delete-tag %s\n' "${4:-}" >>"${STATE}/deleted.log"
  exit 0
fi
echo "git unexpected: $*" >&2
exit 2
EOF
chmod a+x -- "${SCRIPT_STUB}/git"

# v0.0.5 两代前 = v0.0.3；明确不存在 → 无删除
SCRIPT_CW="${EVIDENCE}/runs/script-prune-cwd"
rm -rf -- "${SCRIPT_CW}"
mkdir -p -- "${SCRIPT_CW}/tmp"
: >"${EVIDENCE}/runs/gh-script-prune-miss.log"
: >"${EVIDENCE}/runs/script-state/deleted.log"
rm -f -- "${EVIDENCE}/runs/script-state/"*.present
set +e
env -C "${SCRIPT_CW}" PATH="${SCRIPT_STUB}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-script-prune-miss.log" \
  APT_HUB_SCRIPT_STATE="${EVIDENCE}/runs/script-state" \
  EVENT_NAME=push REF=refs/tags/v0.0.5 \
  bash "${SCRIPT_PRUNE_STEP}" \
  >"${EVIDENCE}/runs/script-prune-miss.out" 2>"${EVIDENCE}/runs/script-prune-miss.err"
RC=$?
set -e
record "script_prune_missing_noop" "${RC}" 0
if [[ -s "${EVIDENCE}/runs/script-state/deleted.log" ]]; then
  fail "旧 Release 不存在仍删除"
else
  pass "两代前不存在无操作"
fi
if grep -Fq 'Old version to remove: v0.0.3' "${EVIDENCE}/runs/script-prune-miss.out"; then
  pass "get_pre_del_tag×2 → v0.0.3"
else
  fail "两代前公式不符"
fi

# 明确 HTTP 404 → 无操作
: >"${EVIDENCE}/runs/gh-script-prune-404.log"
: >"${EVIDENCE}/runs/script-state/deleted.log"
set +e
env -C "${SCRIPT_CW}" PATH="${SCRIPT_STUB}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-script-prune-404.log" \
  APT_HUB_SCRIPT_STATE="${EVIDENCE}/runs/script-state" \
  APT_HUB_SCRIPT_VIEW_MODE=http404 \
  EVENT_NAME=push REF=refs/tags/v0.0.5 \
  bash "${SCRIPT_PRUNE_STEP}" \
  >"${EVIDENCE}/runs/script-prune-404.out" 2>"${EVIDENCE}/runs/script-prune-404.err"
RC=$?
set -e
record "script_prune_http404_noop" "${RC}" 0
if [[ -s "${EVIDENCE}/runs/script-state/deleted.log" ]]; then
  fail "HTTP 404 仍删除"
else
  pass "HTTP 404 无操作"
fi

# HTTP 503 + exit1 → 非 0，零 delete/push（不得当 missing）
: >"${EVIDENCE}/runs/gh-script-prune-503.log"
: >"${EVIDENCE}/runs/script-state/deleted.log"
set +e
env -C "${SCRIPT_CW}" PATH="${SCRIPT_STUB}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-script-prune-503.log" \
  APT_HUB_SCRIPT_STATE="${EVIDENCE}/runs/script-state" \
  APT_HUB_SCRIPT_VIEW_MODE=http503 \
  EVENT_NAME=push REF=refs/tags/v0.0.5 \
  bash "${SCRIPT_PRUNE_STEP}" \
  >"${EVIDENCE}/runs/script-prune-503.out" 2>"${EVIDENCE}/runs/script-prune-503.err"
RC=$?
set -e
record "script_prune_http503_fail" "${RC}" 1
if [[ -s "${EVIDENCE}/runs/script-state/deleted.log" ]]; then
  fail "HTTP 503 仍有 delete/push"
else
  pass "HTTP 503 零删除"
fi
if grep -Eiq '不存在，无操作' "${EVIDENCE}/runs/script-prune-503.out"; then
  fail "HTTP 503 被误判为不存在"
else
  pass "HTTP 503 不吞为 missing"
fi

# 首版 v0.0.1：两代下溢到 v0.0.0 → view 不存在 → 无操作
: >"${EVIDENCE}/runs/gh-script-prune-v001.log"
: >"${EVIDENCE}/runs/script-state/deleted.log"
set +e
env -C "${SCRIPT_CW}" PATH="${SCRIPT_STUB}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-script-prune-v001.log" \
  APT_HUB_SCRIPT_STATE="${EVIDENCE}/runs/script-state" \
  EVENT_NAME=push REF=refs/tags/v0.0.1 \
  bash "${SCRIPT_PRUNE_STEP}" \
  >"${EVIDENCE}/runs/script-prune-v001.out" 2>"${EVIDENCE}/runs/script-prune-v001.err"
RC=$?
set -e
record "script_prune_v001_underflow_noop" "${RC}" 0
if grep -Fq 'Old version to remove: v0.0.0' "${EVIDENCE}/runs/script-prune-v001.out" \
  && [[ ! -s "${EVIDENCE}/runs/script-state/deleted.log" ]]; then
  pass "v0.0.1 无两代前无操作"
else
  fail "v0.0.1 下溢处理错误"
fi

# v0.0.2 → 两代前 v0.0.0 不存在 → 无操作
: >"${EVIDENCE}/runs/gh-script-prune-v002.log"
: >"${EVIDENCE}/runs/script-state/deleted.log"
set +e
env -C "${SCRIPT_CW}" PATH="${SCRIPT_STUB}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-script-prune-v002.log" \
  APT_HUB_SCRIPT_STATE="${EVIDENCE}/runs/script-state" \
  EVENT_NAME=push REF=refs/tags/v0.0.2 \
  bash "${SCRIPT_PRUNE_STEP}" \
  >"${EVIDENCE}/runs/script-prune-v002.out" 2>"${EVIDENCE}/runs/script-prune-v002.err"
RC=$?
set -e
record "script_prune_v002_floor_noop" "${RC}" 0
if grep -Fq 'Old version to remove: v0.0.0' "${EVIDENCE}/runs/script-prune-v002.out" \
  && [[ ! -s "${EVIDENCE}/runs/script-state/deleted.log" ]]; then
  pass "v0.0.2 查 v0.0.0 不存在无操作"
else
  fail "v0.0.2 地板查询错误"
fi

# 存在则删 Release + tag；不碰 golang/latest
: >"${EVIDENCE}/runs/gh-script-prune-hit.log"
: >"${EVIDENCE}/runs/script-state/deleted.log"
printf '1\n' >"${EVIDENCE}/runs/script-state/v0.0.3.present"
printf '1\n' >"${EVIDENCE}/runs/script-state/golang-7.7.7-1.present"
printf '1\n' >"${EVIDENCE}/runs/script-state/latest.present"
set +e
env -C "${SCRIPT_CW}" PATH="${SCRIPT_STUB}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-script-prune-hit.log" \
  APT_HUB_SCRIPT_STATE="${EVIDENCE}/runs/script-state" \
  EVENT_NAME=push REF=refs/tags/v0.0.5 \
  bash "${SCRIPT_PRUNE_STEP}" \
  >"${EVIDENCE}/runs/script-prune-hit.out" 2>"${EVIDENCE}/runs/script-prune-hit.err"
RC=$?
set -e
record "script_prune_two_gen_delete" "${RC}" 0
if grep -Fq 'deleted v0.0.3' "${EVIDENCE}/runs/script-state/deleted.log" \
  && grep -Fq 'git-delete-tag v0.0.3' "${EVIDENCE}/runs/script-state/deleted.log" \
  && [[ -f "${EVIDENCE}/runs/script-state/golang-7.7.7-1.present" ]] \
  && [[ -f "${EVIDENCE}/runs/script-state/latest.present" ]]; then
  pass "仅删两代前脚本 Release/tag"
else
  fail "两代清理目标错误"
fi

# 非 vtag push 跳过
: >"${EVIDENCE}/runs/gh-script-prune-skip.log"
: >"${EVIDENCE}/runs/script-state/deleted.log"
set +e
env -C "${SCRIPT_CW}" PATH="${SCRIPT_STUB}:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-script-prune-skip.log" \
  APT_HUB_SCRIPT_STATE="${EVIDENCE}/runs/script-state" \
  EVENT_NAME=workflow_dispatch REF=refs/heads/main \
  bash "${SCRIPT_PRUNE_STEP}" \
  >"${EVIDENCE}/runs/script-prune-skip.out" 2>"${EVIDENCE}/runs/script-prune-skip.err"
RC=$?
set -e
record "script_prune_skip_nontag" "${RC}" 0
if [[ -s "${EVIDENCE}/runs/script-state/deleted.log" ]]; then
  fail "非 tag 仍清理脚本"
else
  pass "非 tag 跳过脚本两代清理"
fi

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

VER_BEFORE_MANUAL="$(tr -d '[:space:]' <"${WORK}/VERSION")"
set +e
bash -c "cd \"${WORK}\" && \"${GIT_TAG}\" custom" \
  >"${EVIDENCE}/runs/git-custom.out" 2>"${EVIDENCE}/runs/git-custom.err"
RC=$?
set -e
record "git_tag_custom_refuse" "${RC}" 1
set +e
bash -c "cd \"${WORK}\" && \"${GIT_TAG}\" --version 0.9.9" \
  >"${EVIDENCE}/runs/git-version.out" 2>"${EVIDENCE}/runs/git-version.err"
RC=$?
set -e
record "git_tag_version_refuse" "${RC}" 1
manual_tag_exists=0
if git -C "${WORK}" rev-parse -q --verify refs/tags/v0.9.9 >/dev/null; then
  manual_tag_exists=1
fi
if [[ "$(tr -d '[:space:]' <"${WORK}/VERSION")" == "${VER_BEFORE_MANUAL}" \
  && -z "$(git -C "${WORK}" status --porcelain)" \
  && "${manual_tag_exists}" -eq 0 ]]; then
  pass "手动入口拒绝且无写入/无 tag"
else
  fail "手动入口仍改动仓库"
fi

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
if [[ "$(tr -d '[:space:]' <"${ROOT}/VERSION")" == "${MAIN_VER_BEFORE}" ]]; then
  pass "主仓 VERSION 未改且未执行主仓 git_tag"
else
  fail "主仓 VERSION 被改"
fi

# 重复 tag：VERSION 回退到 0.1.0 再 auto → 目标 v0.1.1 已存在
printf '0.1.0\n' >"${WORK}/VERSION"
git -C "${WORK}" add VERSION
git -C "${WORK}" commit --quiet -m 'reset version for dup tag'
git -C "${WORK}" push --quiet origin HEAD:master 2>/dev/null \
  || git -C "${WORK}" push --quiet origin HEAD:main
set +e
bash -c "cd \"${WORK}\" && \"${GIT_TAG}\" auto" \
  >"${EVIDENCE}/runs/git-dup.out" 2>"${EVIDENCE}/runs/git-dup.err"
RC=$?
set -e
record "git_tag_existing_refuse" "${RC}" 1

# 进位：0.0.999→0.1.0；0.999.999→1.0.0（各隔离 bare）
bump_auto_case() {
  local start="$1" expect="$2" name="$3"
  local bare work
  bare="${EVIDENCE}/git/bump-${name}.git"
  work="${EVIDENCE}/git/bump-${name}-work"
  rm -rf -- "${bare}" "${work}"
  mkdir -p -- "${EVIDENCE}/git"
  git init --bare --quiet "${bare}"
  git init --quiet "${work}"
  git -C "${work}" remote add origin "${bare}"
  git -C "${work}" config user.name 'apt-hub-release-test'
  git -C "${work}" config user.email 'apt-hub-release-test@invalid'
  printf '%s\n' "${start}" >"${work}/VERSION"
  git -C "${work}" add VERSION
  git -C "${work}" commit --quiet -m 'bump start'
  git -C "${work}" push --quiet origin HEAD:master 2>/dev/null \
    || git -C "${work}" push --quiet origin HEAD:main
  set +e
  bash -c "cd \"${work}\" && \"${GIT_TAG}\" auto" \
    >"${EVIDENCE}/runs/git-bump-${name}.out" 2>"${EVIDENCE}/runs/git-bump-${name}.err"
  RC=$?
  set -e
  record "git_tag_bump_${name}" "${RC}" 0
  if [[ "$(tr -d '[:space:]' <"${work}/VERSION")" == "${expect}" ]] \
    && git -C "${bare}" rev-parse -q --verify "refs/tags/v${expect}" >/dev/null; then
    pass "git_tag bump ${start}->${expect}"
  else
    fail "git_tag bump ${start}->${expect}"
  fi
}
bump_auto_case "0.0.1" "0.0.2" "patch"
bump_auto_case "0.0.999" "0.1.0" "minor_carry"
bump_auto_case "0.999.999" "1.0.0" "major_carry"

# push 失败：从 0.1.1 auto→0.1.2，坏 remote；不得回滚已提交 VERSION/changelog
git -C "${WORK}" remote set-url origin "${BARE}"
printf '0.1.1\n' >"${WORK}/VERSION"
git -C "${WORK}" add VERSION
git -C "${WORK}" commit --quiet -m 'align 0.1.1 for push-fail'
git -C "${WORK}" push --quiet origin HEAD:master 2>/dev/null \
  || git -C "${WORK}" push --quiet origin HEAD:main
VER_BEFORE_PUSH="$(tr -d '[:space:]' <"${WORK}/VERSION")"
git -C "${WORK}" remote set-url origin "${EVIDENCE}/git/no-such-bare.git"
set +e
bash -c "cd \"${WORK}\" && \"${GIT_TAG}\" auto" \
  >"${EVIDENCE}/runs/git-pushfail.out" 2>"${EVIDENCE}/runs/git-pushfail.err"
RC=$?
set -e
record "git_tag_push_refuse" "${RC}" 1
VER_AFTER_PUSH="$(tr -d '[:space:]' <"${WORK}/VERSION")"
HEAD_VER="$(git -C "${WORK}" show HEAD:VERSION | tr -d '[:space:]')"
if [[ "${VER_AFTER_PUSH}" != "${VER_BEFORE_PUSH}" \
  && "${VER_AFTER_PUSH}" == "${HEAD_VER}" \
  && -f "${WORK}/changelog/v${VER_AFTER_PUSH}.md" \
  && -z "$(git -C "${WORK}" status --porcelain)" ]]; then
  pass "push 失败不回滚已提交 VERSION/changelog"
else
  fail "push 失败后 VERSION/changelog 被回滚或变 dirty"
fi

# 确定性 generated_at：同 archive 连构两次 provenance/SHA256SUMS bytes 不变
DET_A="${EVIDENCE}/runs/det-a"
DET_B="${EVIDENCE}/runs/det-b"
rm -rf -- "${DET_A}" "${DET_B}"
set +e
bash "${GEN}" --config "${CONFIG}" --output "${DET_A}" \
  --downloads-json "${FIX_JSON}" --archive-dir "${FIX_ARCH}" --version go7.7.7 \
  >"${EVIDENCE}/runs/det-a.out" 2>"${EVIDENCE}/runs/det-a.err"
RC_A=$?
bash "${GEN}" --config "${CONFIG}" --output "${DET_B}" \
  --downloads-json "${FIX_JSON}" --archive-dir "${FIX_ARCH}" --version go7.7.7 \
  >"${EVIDENCE}/runs/det-b.out" 2>"${EVIDENCE}/runs/det-b.err"
RC_B=$?
set -e
record "deterministic_build_a" "${RC_A}" 0
record "deterministic_build_b" "${RC_B}" 0
if cmp -s -- "${DET_A}/provenance.json" "${DET_B}/provenance.json" \
  && cmp -s -- "${DET_A}/SHA256SUMS" "${DET_B}/SHA256SUMS"; then
  pass "generated_at/SHA256SUMS 确定性可复用"
else
  fail "provenance 或 SHA256SUMS 随墙钟漂"
fi

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
