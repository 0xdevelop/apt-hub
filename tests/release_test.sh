#!/usr/bin/env bash
# 统一 vtag 构包与母版发布链：不覆盖旧 golang Release 状态机。
set -euo pipefail
export LC_ALL=C
export LANG=C
export LANGUAGE=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE="${ROOT}/tmp/first-live-deploy/template-realignment/A/release-test"
BUILD_SH="${ROOT}/build.sh"
GEN_DEBS="${ROOT}/gen_debs.sh"
GEN_GO="${ROOT}/scripts/gen_deb_golang.sh"
ASSETS="${ROOT}/scripts/release_assets.sh"
PUBLISH="${ROOT}/scripts/publish_apt_site.sh"
WF_REL="${ROOT}/.github/workflows/release.yml"
VERSION_FILE="${ROOT}/VERSION"
SHELLCHECK_BIN=""
if command -v shellcheck >/dev/null 2>&1; then
  SHELLCHECK_BIN="$(command -v shellcheck)"
elif [[ -x "${ROOT}/tmp/go-final-parent/bin/shellcheck" ]]; then
  SHELLCHECK_BIN="${ROOT}/tmp/go-final-parent/bin/shellcheck"
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
    fail "${name} rc=${rc} want=${expect}"
  fi
}

VER_BEFORE="$(tr -d '[:space:]' <"${VERSION_FILE}")"

if [[ ! -e "${ROOT}/scripts/release_golang.sh" && ! -e "${ROOT}/gen_deb_golang.sh" ]]; then
  pass "已删除独立 Go 发布脚本与根 gen_deb_golang"
else
  fail "仍存在 release_golang.sh 或根 gen_deb_golang.sh"
fi
if [[ -f "${GEN_DEBS}" && -f "${GEN_GO}" && -f "${ASSETS}" && -f "${PUBLISH}" ]]; then
  pass "统一入口文件在位"
else
  fail "缺少 gen_debs/scripts gen/assets/publish"
fi

if [[ -n "${SHELLCHECK_BIN}" ]]; then
  set +e
  "${SHELLCHECK_BIN}" -s bash -- "${BUILD_SH}" "${GEN_DEBS}" "${GEN_GO}" "${ASSETS}" "${PUBLISH}" \
    >"${EVIDENCE}/runs/shellcheck.out" 2>&1
  RC=$?
  set -e
  record "shellcheck_a_scripts" "${RC}" 0
else
  fail "PATH 和 tmp/go-final-parent/bin 都没有 shellcheck"
fi

# ---------- 离线夹具构包 ----------
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
FIX_ARCH="${EVIDENCE}/fixtures/archives"
FIX_JSON="${EVIDENCE}/fixtures/downloads.json"
mkdir -p -- "${FIX_ARCH}"
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

OUT_BUILD="${EVIDENCE}/out-build"
rm -rf -- "${OUT_BUILD}"
set +e
"${BUILD_SH}" --output "${OUT_BUILD}" --go-version go7.7.7 \
  --downloads-json "${FIX_JSON}" --archive-dir "${FIX_ARCH}" \
  >"${EVIDENCE}/runs/build.out" 2>"${EVIDENCE}/runs/build.err"
RC=$?
set -e
record "build_explicit_output" "${RC}" 0
names="$(find "${OUT_BUILD}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
if [[ -f "${OUT_BUILD}/golang_7.7.7-1_amd64.deb" \
  && -f "${OUT_BUILD}/golang_7.7.7-1_arm64.deb" \
  && -f "${OUT_BUILD}/golang-go_7.7.7-1_amd64.deb" \
  && -f "${OUT_BUILD}/golang-go_7.7.7-1_arm64.deb" \
  && -f "${OUT_BUILD}/golang.provenance.json" \
  && -f "${OUT_BUILD}/SHA256SUMS" \
  && ! -e "${OUT_BUILD}/provenance.json" ]]; then
  pass "上传集仅四 deb + golang.provenance.json + SHA256SUMS"
else
  fail "上传集不符: ${names}"
fi
if jq -e '.schema_version=="1" and (.upstream.epoch=="2") and (.packages|length==4)' \
  "${OUT_BUILD}/golang.provenance.json" >/dev/null 2>&1; then
  pass "golang.provenance.json 仍为 schema1"
else
  fail "来源文件 schema 被改"
fi
if ( cd -- "${OUT_BUILD}" && sha256sum -c -- SHA256SUMS >/dev/null ); then
  pass "SHA256SUMS 对得上构造包与来源文件"
else
  fail "SHA256SUMS 校验失败"
fi

OUT_FAIL="${EVIDENCE}/out-fail"
rm -rf -- "${OUT_FAIL}"
mkdir -p -- "${OUT_FAIL}"
set +e
"${BUILD_SH}" --output "${OUT_FAIL}" --go-version go0.0.0 \
  --downloads-json "${FIX_JSON}" --archive-dir "${FIX_ARCH}" \
  >"${EVIDENCE}/runs/build-fail.out" 2>"${EVIDENCE}/runs/build-fail.err"
RC=$?
set -e
record "build_bad_version_fails" "${RC}" 1
if find -- "${OUT_FAIL}" -type f \( -name '*.deb' -o -name '*.provenance.json' -o -name 'SHA256SUMS' \) | grep -q .; then
  fail "失败路径留下产物"
else
  pass "失败无产物"
fi

CAT_GH="${EVIDENCE}/catalog-githubdeb.json"
jq '{schema_version,packages:[.packages[]|select((.source_type // "githubdeb")=="githubdeb")]}' \
  "${ROOT}/config/packages.json" >"${CAT_GH}"
OUT_GH="${EVIDENCE}/out-githubdeb-only"
rm -rf -- "${OUT_GH}"
set +e
"${BUILD_SH}" --catalog "${CAT_GH}" --output "${OUT_GH}" --go-version go7.7.7 \
  --downloads-json "${FIX_JSON}" --archive-dir "${FIX_ARCH}" \
  >"${EVIDENCE}/runs/build-gh.out" 2>"${EVIDENCE}/runs/build-gh.err"
RC=$?
set -e
record "catalog_githubdeb_skips_go" "${RC}" 0
if find -- "${OUT_GH}" -type f \( -name '*.deb' -o -name '*.provenance.json' \) 2>/dev/null | grep -q .; then
  fail "只有 githubdeb 的 catalog 仍构造了包"
else
  pass "githubdeb 不转存、不构造"
fi
CAT_BAD="${EVIDENCE}/catalog-unknown.json"
printf '%s\n' '{"schema_version":"2","packages":[{"id":"nope","source_type":"made_up","repository":"a/b"}]}' >"${CAT_BAD}"
OUT_BAD="${EVIDENCE}/out-unknown"
rm -rf -- "${OUT_BAD}"
mkdir -p -- "${OUT_BAD}"
set +e
"${BUILD_SH}" --catalog "${CAT_BAD}" --output "${OUT_BAD}" \
  >"${EVIDENCE}/runs/build-unknown.out" 2>"${EVIDENCE}/runs/build-unknown.err"
RC=$?
set -e
record "catalog_unknown_source_type" "${RC}" 1
if grep -Fq '未知 source_type' "${EVIDENCE}/runs/build-unknown.err" \
  && ! find -- "${OUT_BAD}" -type f -name '*.deb' | grep -q .; then
  pass "未知 source_type 拒绝且无产物"
else
  fail "未知 source_type 未按 catalog 拒绝"
fi

# 不删除、不重建当前 build/upload_tmp_dir，也不调用 ./build.sh test（会递归进本测试）。
upload_dir="${ROOT}/build/upload_tmp_dir"
if [[ -d "${upload_dir}" ]]; then
  upload_before="$(find "${upload_dir}" -type f -print0 | sort -z | xargs -0 -r sha256sum)"
else
  upload_before="ABSENT"
fi
set +e
grep -Fq 'args+=(--output build/upload_tmp_dir)' "${BUILD_SH}"
RC=$?
set -e
record "build_default_upload_dir" "${RC}" 0
set +e
( cd -- "${OUT_BUILD}" && sha256sum -c -- SHA256SUMS >/dev/null )
RC=$?
set -e
record "build_test_verifies" "${RC}" 0
if [[ -d "${upload_dir}" ]]; then
  upload_after="$(find "${upload_dir}" -type f -print0 | sort -z | xargs -0 -r sha256sum)"
else
  upload_after="ABSENT"
fi
if [[ "${upload_before}" == "${upload_after}" ]]; then
  pass "测试未改当前上传目录"
else
  fail "测试改了当前上传目录"
fi

# ---------- metadata：官方 JSON，不造 Go 伪 Release ----------
META="${EVIDENCE}/upstream"
rm -rf -- "${META}"
cat >"${EVIDENCE}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
out=""
args=("$@")
i=0
while [[ "${i}" -lt ${#args[@]} ]]; do
  a="${args[$i]}"
  case "${a}" in
    -o) i=$((i + 1)); out="${args[$i]}" ;;
    -w) i=$((i + 1)); printf '%s' "${APT_HUB_CURL_CODE:-200}" ;;
    http://*|https://*) url="${a}" ;;
  esac
  i=$((i + 1))
done
printf '%s\n' "${url}" >>"${APT_HUB_CURL_LOG:?}"
if [[ "${APT_HUB_CURL_FAIL:-0}" == "1" ]]; then
  echo "fixture network fail" >&2
  exit 1
fi
case "${url}" in
  https://api.github.com/repos/rustdesk/rustdesk/releases/latest)
    body='{"tag_name":"1.4.5","html_url":"https://github.com/rustdesk/rustdesk/releases/tag/1.4.5","assets":[{"name":"rustdesk-1.4.5-x86_64.deb","browser_download_url":"https://github.com/rustdesk/rustdesk/releases/download/1.4.5/rustdesk-1.4.5-x86_64.deb","digest":"sha256:abc","size":10}]}'
    ;;
  *)
    echo "curl fixture refuse ${url}" >&2
    exit 2
    ;;
esac
[[ -n "${out}" ]] && printf '%s' "${body}" >"${out}"
EOF
chmod a+x -- "${EVIDENCE}/bin/curl"
: >"${EVIDENCE}/runs/curl-meta.log"
set +e
env PATH="${EVIDENCE}/bin:${PATH}" APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-meta.log" \
  "${GEN_DEBS}" metadata --upstream-dir "${META}" \
  >"${EVIDENCE}/runs/meta.out" 2>"${EVIDENCE}/runs/meta.err"
RC=$?
set -e
record "metadata_rustdesk" "${RC}" 0
if [[ -f "${META}/rustdesk.json" && ! -e "${META}/golang.json" ]] \
  && jq -e '.tag_name=="1.4.5" and (.assets|type=="array")' "${META}/rustdesk.json" >/dev/null; then
  pass "metadata 只保存真实官方响应且不含 Go 伪 Release"
else
  fail "metadata 输出不对"
fi
rm -rf -- "${META}"
mkdir -p -- "${META}"
: >"${EVIDENCE}/runs/curl-meta-fail.log"
set +e
env PATH="${EVIDENCE}/bin:${PATH}" APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-meta-fail.log" \
  APT_HUB_CURL_FAIL=1 \
  "${GEN_DEBS}" metadata --upstream-dir "${META}" \
  >"${EVIDENCE}/runs/meta-fail.out" 2>"${EVIDENCE}/runs/meta-fail.err"
RC=$?
set -e
record "metadata_network_fails" "${RC}" 1
if find -- "${META}" -type f -name '*.json' | grep -q .; then
  fail "metadata 失败仍留下部分 JSON"
else
  pass "metadata 失败无部分 JSON"
fi
printf '%s\n' '{"keep":true}' >"${META}/keep.json"
set +e
env PATH="${EVIDENCE}/bin:${PATH}" APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-meta.log" \
  "${GEN_DEBS}" metadata --upstream-dir "${META}" \
  >"${EVIDENCE}/runs/meta-keep.out" 2>"${EVIDENCE}/runs/meta-keep.err"
RC=$?
set -e
record "metadata_refuses_nonempty" "${RC}" 1
if [[ -f "${META}/keep.json" ]] && jq -e '.keep==true' "${META}/keep.json" >/dev/null; then
  pass "非空 upstream-dir 不被清掉"
else
  fail "非空 upstream-dir 被清掉或改写"
fi
ESCAPE="${ROOT}/build/gen-debs-escape"
mkdir -p -- "${ROOT}/build"
rm -rf -- "${ESCAPE}"
set +e
env PATH="${EVIDENCE}/bin:${PATH}" APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-meta.log" \
  "${GEN_DEBS}" metadata --upstream-dir "${ROOT}/tmp/../build/gen-debs-escape" \
  >"${EVIDENCE}/runs/meta-escape.out" 2>"${EVIDENCE}/runs/meta-escape.err"
RC=$?
set -e
record "metadata_rejects_dotdot" "${RC}" 1
if [[ -e "${ESCAPE}" ]]; then
  fail "metadata 穿过 .. 写出了目录"
  rm -rf -- "${ESCAPE}"
else
  pass "metadata 拒绝 .. 逃出 tmp"
fi
cat >"${EVIDENCE}/bin/jq" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-r" && "${APT_HUB_JQ_FAIL:-0}" == "1" ]]; then
  printf '%s\n' rustdesk
  exit 1
fi
exec /usr/bin/jq "$@"
EOF
chmod a+x -- "${EVIDENCE}/bin/jq"
rm -rf -- "${META}"
mkdir -p -- "${META}"
set +e
env PATH="${EVIDENCE}/bin:${PATH}" APT_HUB_JQ_FAIL=1 \
  APT_HUB_CURL_LOG="${EVIDENCE}/runs/curl-meta.log" \
  "${GEN_DEBS}" metadata --upstream-dir "${META}" \
  >"${EVIDENCE}/runs/meta-jq.out" 2>"${EVIDENCE}/runs/meta-jq.err"
RC=$?
set -e
record "metadata_jq_partial_fails" "${RC}" 1
if find -- "${META}" -type f -name '*.json' | grep -q .; then
  fail "jq 失败仍提交了部分 JSON"
else
  pass "jq 部分输出不当成功"
fi
rm -f -- "${EVIDENCE}/bin/jq"

# ---------- 资产：完整则跳过，空则上传，不同 bytes/部分拒绝 ----------
cat >"${EVIDENCE}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${APT_HUB_GH_LOG:?}"
if [[ "${1:-}" == "api" ]]; then
  printf '%s' "${APT_HUB_RELEASE_JSON:-[]}"
  exit 0
fi
if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then
  dir="" pattern=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-R) shift 2 ;;
      --dir|-D) dir="$2"; shift 2 ;;
      --pattern|-p) pattern="$2"; shift 2 ;;
      --clobber) shift ;;
      *) shift ;;
    esac
  done
  [[ -n "${dir}" && -n "${pattern}" && -f "${APT_HUB_ASSET_DIR:?}/${pattern}" ]] || exit 1
  cp -f -- "${APT_HUB_ASSET_DIR}/${pattern}" "${dir}/${pattern}"
  exit 0
fi
echo "gh fixture refuse $*" >&2
exit 2
EOF
chmod a+x -- "${EVIDENCE}/bin/gh"
asset_case() {
  local name="$1" json="$2" want="$3"
  : >"${EVIDENCE}/runs/gh-${name}.log"
  set +e
  env PATH="${EVIDENCE}/bin:${PATH}" GH_TOKEN=t \
    APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-${name}.log" \
    APT_HUB_RELEASE_JSON="${json}" \
    APT_HUB_ASSET_DIR="${OUT_BUILD}" \
    "${ASSETS}" remote-status --repository example/apt-hub --tag v0.0.2 \
    >"${EVIDENCE}/runs/assets-${name}.out" 2>"${EVIDENCE}/runs/assets-${name}.err"
  RC=$?
  set -e
  record "assets_${name}" "${RC}" "${want}"
}
asset_case empty '{"tag_name":"v0.0.2","draft":false,"assets":[]}' 10
asset_case array '[]' 1
asset_case partial '{"tag_name":"v0.0.2","draft":false,"assets":[{"name":"golang_7.7.7-1_amd64.deb","size":1,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","state":"uploaded"}]}' 1
# 名字齐全但 digest 与真实字节不符，不能当 complete。
bad_digest='{"tag_name":"v0.0.2","draft":false,"assets":[
  {"name":"golang_7.7.7-1_amd64.deb","size":1,"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","state":"uploaded"},
  {"name":"golang_7.7.7-1_arm64.deb","size":1,"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","state":"uploaded"},
  {"name":"golang-go_7.7.7-1_amd64.deb","size":1,"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","state":"uploaded"},
  {"name":"golang-go_7.7.7-1_arm64.deb","size":1,"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","state":"uploaded"},
  {"name":"golang.provenance.json","size":2,"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","state":"uploaded"},
  {"name":"SHA256SUMS","size":3,"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","state":"uploaded"}
]}'
asset_case digest "${bad_digest}" 1
set +e
env PATH="${EVIDENCE}/bin:${PATH}" GH_TOKEN=t TMPDIR="${EVIDENCE}/no-such-tmpdir" \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-tmpdir.log" \
  APT_HUB_RELEASE_JSON='{"tag_name":"v0.0.2","draft":false,"assets":[]}' \
  "${ASSETS}" remote-status --repository example/apt-hub --tag v0.0.2 \
  >"${EVIDENCE}/runs/assets-tmpdir.out" 2>"${EVIDENCE}/runs/assets-tmpdir.err"
RC=$?
set -e
record "assets_tmpdir_not_system" "${RC}" 10
: >"${EVIDENCE}/runs/assets-complete.lines"
while IFS= read -r name; do
  path="${OUT_BUILD}/${name}"
  sum="$(sha256sum -- "${path}" | awk '{print $1}')"
  sz="$(stat -c '%s' -- "${path}")"
  jq -nc --arg n "${name}" --arg s "${sum}" --argjson z "${sz}" \
    '{name:$n,size:$z,digest:("sha256:"+$s),state:"uploaded"}' >>"${EVIDENCE}/runs/assets-complete.lines"
done < <(find "${OUT_BUILD}" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
jq -s '{tag_name:"v0.0.2",draft:false,assets:.}' "${EVIDENCE}/runs/assets-complete.lines" \
  >"${EVIDENCE}/runs/assets-complete.json"
set +e
env PATH="${EVIDENCE}/bin:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-realcomplete.log" \
  APT_HUB_RELEASE_JSON="$(cat "${EVIDENCE}/runs/assets-complete.json")" \
  APT_HUB_ASSET_DIR="${OUT_BUILD}" \
  "${ASSETS}" remote-status --repository example/apt-hub --tag v0.0.2 \
  >"${EVIDENCE}/runs/assets-realcomplete.out" 2>"${EVIDENCE}/runs/assets-realcomplete.err"
RC=$?
set -e
record "assets_bytes_match" "${RC}" 0
empty_dir="${EVIDENCE}/empty-prov"
rm -rf -- "${empty_dir}"
mkdir -p -- "${empty_dir}"
printf '%s\n' '{"schema_version":"1","upstream":{},"packages":[]}' >"${empty_dir}/golang.provenance.json"
( cd -- "${empty_dir}" && sha256sum -- golang.provenance.json >SHA256SUMS )
: >"${EVIDENCE}/runs/assets-emptyprov.lines"
while IFS= read -r name; do
  path="${empty_dir}/${name}"
  sum="$(sha256sum -- "${path}" | awk '{print $1}')"
  sz="$(stat -c '%s' -- "${path}")"
  jq -nc --arg n "${name}" --arg s "${sum}" --argjson z "${sz}" \
    '{name:$n,size:$z,digest:("sha256:"+$s),state:"uploaded"}' >>"${EVIDENCE}/runs/assets-emptyprov.lines"
done < <(find "${empty_dir}" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
jq -s '{tag_name:"v0.0.2",draft:false,assets:.}' "${EVIDENCE}/runs/assets-emptyprov.lines" \
  >"${EVIDENCE}/runs/assets-emptyprov.json"
set +e
env PATH="${EVIDENCE}/bin:${PATH}" GH_TOKEN=t \
  APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-emptyprov.log" \
  APT_HUB_RELEASE_JSON="$(cat "${EVIDENCE}/runs/assets-emptyprov.json")" \
  APT_HUB_ASSET_DIR="${empty_dir}" \
  "${ASSETS}" remote-status --repository example/apt-hub --tag v0.0.2 \
  >"${EVIDENCE}/runs/assets-emptyprov.out" 2>"${EVIDENCE}/runs/assets-emptyprov.err"
RC=$?
set -e
record "assets_empty_packages" "${RC}" 1
if grep -Fq '来源与规定组合不一致' "${EVIDENCE}/runs/assets-emptyprov.err"; then
  pass "空 packages 不能当完整"
else
  fail "空 packages 未按组合拒绝"
fi
asset_case bad_filename '{"tag_name":"v0.0.2","draft":false,"assets":[{"name":"../SHA256SUMS","size":1,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","state":"uploaded"}]}' 1
if grep -Fq '资产文件名非法' "${EVIDENCE}/runs/assets-bad_filename.err"; then
  pass "资产文件名拒绝斜杠与 .."
else
  fail "非法资产文件名未拒绝"
fi
assets_from_dir() {
  local name="$1" dir="$2" want="$3" fname path sum sz sums
  sums="$(mktemp "${EVIDENCE}/sums.XXXXXX")"
  (
    cd -- "${dir}"
    while IFS= read -r fname; do
      sha256sum -- "${fname}"
    done < <(find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort) \
      | LC_ALL=C sort -k2 >"${sums}"
  )
  mv -- "${sums}" "${dir}/SHA256SUMS"
  : >"${EVIDENCE}/runs/assets-${name}.lines"
  while IFS= read -r fname; do
    path="${dir}/${fname}"
    sum="$(sha256sum -- "${path}" | awk '{print $1}')"
    sz="$(stat -c '%s' -- "${path}")"
    jq -nc --arg n "${fname}" --arg s "${sum}" --argjson z "${sz}" \
      '{name:$n,size:$z,digest:("sha256:"+$s),state:"uploaded"}' >>"${EVIDENCE}/runs/assets-${name}.lines"
  done < <(find "${dir}" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
  jq -s '{tag_name:"v0.0.2",draft:false,assets:.}' "${EVIDENCE}/runs/assets-${name}.lines" \
    >"${EVIDENCE}/runs/assets-${name}.json"
  set +e
  env PATH="${EVIDENCE}/bin:${PATH}" GH_TOKEN=t \
    APT_HUB_GH_LOG="${EVIDENCE}/runs/gh-${name}.log" \
    APT_HUB_RELEASE_JSON="$(cat "${EVIDENCE}/runs/assets-${name}.json")" \
    APT_HUB_ASSET_DIR="${dir}" \
    "${ASSETS}" remote-status --repository example/apt-hub --tag v0.0.2 \
    >"${EVIDENCE}/runs/assets-${name}.out" 2>"${EVIDENCE}/runs/assets-${name}.err"
  RC=$?
  set -e
  record "assets_${name}" "${RC}" "${want}"
}
miss_go="${EVIDENCE}/miss-golang-go"
rm -rf -- "${miss_go}"
mkdir -p -- "${miss_go}"
cp -a -- "${OUT_BUILD}/." "${miss_go}/"
rm -f -- "${miss_go}"/golang-go_*.deb
jq 'del(.packages[] | select(.package=="golang-go"))' \
  "${OUT_BUILD}/golang.provenance.json" >"${miss_go}/golang.provenance.json"
assets_from_dir missing_golang_go "${miss_go}" 1
if grep -Fq '来源与规定组合不一致' "${EVIDENCE}/runs/assets-missing_golang_go.err"; then
  pass "缺整组 golang-go 拒绝"
else
  fail "缺整组 golang-go 未拒绝"
fi
extra_dir="${EVIDENCE}/extra-family"
rm -rf -- "${extra_dir}"
mkdir -p -- "${extra_dir}"
cp -a -- "${OUT_BUILD}/." "${extra_dir}/"
cp -a -- "${extra_dir}/golang_7.7.7-1_amd64.deb" "${extra_dir}/extra_7.7.7-1_amd64.deb"
cp -a -- "${extra_dir}/golang_7.7.7-1_arm64.deb" "${extra_dir}/extra_7.7.7-1_arm64.deb"
jq '.packages += [.packages[] | select(.package=="golang") | .package="extra-lang" | .filename=("extra_7.7.7-1_"+.architecture+".deb")]' \
  "${OUT_BUILD}/golang.provenance.json" >"${extra_dir}/golang.provenance.json"
assets_from_dir extra_family "${extra_dir}" 1
if grep -Fq '来源与规定组合不一致' "${EVIDENCE}/runs/assets-extra_family.err"; then
  pass "多余包族拒绝"
else
  fail "多余包族未拒绝"
fi
badname_dir="${EVIDENCE}/bad-prov-name"
rm -rf -- "${badname_dir}"
mkdir -p -- "${badname_dir}"
cp -a -- "${OUT_BUILD}/." "${badname_dir}/"
mv -- "${badname_dir}/golang.provenance.json" "${badname_dir}/not-golang.provenance.json"
assets_from_dir prov_name "${badname_dir}" 1
if grep -Fq '来源文件名与 catalog 不一致' "${EVIDENCE}/runs/assets-prov_name.err"; then
  pass "来源文件名与 catalog id 不一致拒绝"
else
  fail "来源文件名错乱未拒绝"
fi
dup_dir="${EVIDENCE}/dup-pair"
rm -rf -- "${dup_dir}"
mkdir -p -- "${dup_dir}"
cp -a -- "${OUT_BUILD}/." "${dup_dir}/"
cp -a -- "${dup_dir}/golang_7.7.7-1_amd64.deb" "${dup_dir}/golang_7.7.7-1_amd64_dup.deb"
rm -f -- "${dup_dir}/golang-go_7.7.7-1_arm64.deb"
jq '
  (.packages | map(select(.package=="golang" and .architecture=="amd64"))[0]) as $dup
  | .packages |= (map(select(.package!="golang-go" or .architecture!="arm64"))
      + [$dup | .filename="golang_7.7.7-1_amd64_dup.deb"])
' "${OUT_BUILD}/golang.provenance.json" >"${dup_dir}/golang.provenance.json"
assets_from_dir duplicate_pair "${dup_dir}" 1
if grep -Fq '来源与规定组合不一致' "${EVIDENCE}/runs/assets-duplicate_pair.err"; then
  pass "重复组合且总数不变仍拒绝"
else
  fail "重复组合未拒绝"
fi

# ---------- workflow 骨架 ----------
if grep -Eq '^  release:' "${WF_REL}" \
  && grep -Eq '^  Build:' "${WF_REL}" \
  && grep -Eq '^  RemoveOldRelease:' "${WF_REL}" \
  && grep -Fq 'ncipollo/release-action@339a81892b84b4eeb0f6e744e4574d79d0d9b8dd' "${WF_REL}" \
  && grep -Fq 'george012/upload_github_release_assets_action@b56f61e7a10692c6ee2d7482b451911393479030' "${WF_REL}" \
  && ! grep -Eq 'upload-pages-artifact|deploy-pages@|upload-artifact|download-artifact' "${WF_REL}" \
  && grep -Fq 'site#http://' "${PUBLISH}" \
  && grep -Fq 'publish_apt_site.sh publish' "${WF_REL}" \
  && grep -Fq 'publish_apt_site.sh remove-old' "${WF_REL}" \
  && grep -Fq 'get_pre_del_tag' "${PUBLISH}" \
  && ! grep -Fq 'release_golang.sh' "${WF_REL}" \
  && ! grep -Fq 'go-downloads-json' "${WF_REL}" \
  && [[ ! -e "${ROOT}/.github/workflows/ubuntu-test.yml" && ! -e "${ROOT}/.github/workflows/ubuntu-publish.yml" ]]; then
  pass "release.yml 三条 job + 母版 Action + Pages"
else
  fail "release.yml 未按统一链收口"
fi
if grep -Fq '拒绝删除 golang' "${PUBLISH}"; then
  pass "RemoveOld 拒绝删除 golang Release"
else
  fail "RemoveOld 未禁止删除 golang Release"
fi

# 两代清理真 run：脚本即生产入口
cat >"${EVIDENCE}/bin/gh-old" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${APT_HUB_GH_LOG:?}"
if [[ "${1:-}" != "release" ]]; then
  echo "unexpected $*" >&2
  exit 2
fi
sub="${2:-}"
tag="${3:-}"
case "${sub}" in
  view)
    if [[ "${APT_HUB_VIEW_MODE:-missing}" == "503" ]]; then
      echo "HTTP 503" >&2
      exit 1
    fi
    if [[ "${APT_HUB_VIEW_MODE:-missing}" == "404" || ! -f "${APT_HUB_STATE:?}/${tag}.present" ]]; then
      echo "release not found" >&2
      exit 1
    fi
    exit 0
    ;;
  delete)
    rm -f -- "${APT_HUB_STATE:?}/${tag}.present"
    printf 'deleted %s\n' "${tag}" >>"${APT_HUB_STATE}/deleted.log"
    ;;
  *) exit 2 ;;
esac
EOF
chmod a+x -- "${EVIDENCE}/bin/gh-old"
cat >"${EVIDENCE}/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"${APT_HUB_GH_LOG:?}"
if [[ "${1:-}" == "fetch" ]]; then
  [[ "${APT_HUB_FETCH_FAIL:-0}" == "1" ]] && exit 1
  exit 0
fi
if [[ "${1:-}" == "grep" ]]; then
  [[ "${APT_HUB_TAG_REFERENCED:-0}" == "1" ]] && exit 0
  exit 1
fi
if [[ "${1:-}" == "push" && "${2:-}" == "origin" && "${3:-}" == "--delete" ]]; then
  printf 'git-delete %s\n' "${4:-}" >>"${APT_HUB_STATE:?}/deleted.log"
  exit 0
fi
if [[ "${1:-}" == "rev-parse" ]]; then
  printf 'abcabcabcabcabcabcabcabcabcabcabcabcabca\n'
  exit 0
fi
if [[ "${1:-}" == "archive" ]]; then
  if [[ -n "${APT_HUB_ARCHIVE_DIR:-}" ]]; then
    tar -C "${APT_HUB_ARCHIVE_DIR}" -cf - .
  else
    tar -cf - --files-from /dev/null
  fi
  exit 0
fi
if [[ "${1:-}" == "ls-remote" ]]; then
  [[ "${APT_HUB_TAG_EXISTS:-0}" == "1" ]] && exit 0
  exit 2
fi
echo "git fixture refuse $*" >&2
exit 2
EOF
chmod a+x -- "${EVIDENCE}/bin/git"
OLD_STATE="${EVIDENCE}/old-state"
rm -rf -- "${OLD_STATE}"
mkdir -p -- "${OLD_STATE}"
run_old() {
  local name="$1"
  shift
  : >"${EVIDENCE}/runs/old-${name}.log"
  : >"${OLD_STATE}/deleted.log"
  set +e
  env PATH="${EVIDENCE}/bin:${PATH}" GH_TOKEN=t \
    APT_HUB_GH_LOG="${EVIDENCE}/runs/old-${name}.log" \
    APT_HUB_STATE="${OLD_STATE}" \
    "$@" \
    "${PUBLISH}" remove-old \
    >"${EVIDENCE}/runs/old-${name}.out" 2>"${EVIDENCE}/runs/old-${name}.err"
  RC=$?
  set -e
  printf '%s\n' "${RC}"
}
# gh fixture name is gh-old; put it on PATH as gh
ln -sfn gh-old "${EVIDENCE}/bin/gh"
printf '1\n' >"${OLD_STATE}/v0.0.3.present"
rc="$(run_old hit EVENT_NAME=push REF=refs/tags/v0.0.5 APT_HUB_VIEW_MODE=present APT_HUB_TAG_REFERENCED=0 APT_HUB_TAG_EXISTS=1)"
record "remove_old_two_gen" "${rc}" 0
if grep -Fq 'deleted v0.0.3' "${OLD_STATE}/deleted.log" \
  && grep -Fq 'git-delete v0.0.3' "${OLD_STATE}/deleted.log"; then
  pass "两代前 v0.0.3 删除 Release 与 tag"
else
  fail "两代删除目标不对"
fi
rc="$(run_old underflow EVENT_NAME=push REF=refs/tags/v0.0.1 APT_HUB_VIEW_MODE=404 APT_HUB_TAG_REFERENCED=0)"
record "remove_old_v001_noop" "${rc}" 0
if [[ -s "${OLD_STATE}/deleted.log" ]]; then
  fail "v0.0.1 下溢仍删除"
else
  pass "v0.0.1 无两代无操作"
fi
rc="$(run_old net EVENT_NAME=push REF=refs/tags/v0.0.5 APT_HUB_VIEW_MODE=503 APT_HUB_TAG_REFERENCED=0)"
record "remove_old_503" "${rc}" 1
if [[ -s "${OLD_STATE}/deleted.log" ]]; then
  fail "503 仍删除"
else
  pass "503 零删除"
fi
printf '1\n' >"${OLD_STATE}/v0.0.3.present"
ARCH_REF="${EVIDENCE}/archive-ref"
rm -rf -- "${ARCH_REF}"
mkdir -p -- "${ARCH_REF}/repos/golang/dists/jammy/main/binary-amd64/by-hash/SHA256"
printf 'Package: golang\nFilename: ./golang.deb\n' >"${ARCH_REF}/repos/golang/dists/jammy/main/binary-amd64/Packages"
gzip -n -c <<'EOF' >"${ARCH_REF}/repos/golang/dists/jammy/main/binary-amd64/Packages.gz"
Package: golang
Filename: https://github.com/example/apt-hub/releases/download/v0.0.3/golang_7.7.7-1_amd64.deb
EOF
cp -- "${ARCH_REF}/repos/golang/dists/jammy/main/binary-amd64/Packages.gz" \
  "${ARCH_REF}/repos/golang/dists/jammy/main/binary-amd64/by-hash/SHA256/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
rc="$(run_old ref EVENT_NAME=push REF=refs/tags/v0.0.5 APT_HUB_VIEW_MODE=present APT_HUB_ARCHIVE_DIR="${ARCH_REF}")"
record "remove_old_gzip_reference" "${rc}" 0
if [[ -s "${OLD_STATE}/deleted.log" ]]; then
  fail "压缩 Packages 仍引用却删除"
else
  pass "压缩 byhash/Packages.gz 引用不删"
fi
ARCH_PREFIX="${EVIDENCE}/archive-prefix"
rm -rf -- "${ARCH_PREFIX}"
mkdir -p -- "${ARCH_PREFIX}/repos/golang/dists/jammy/main/binary-amd64"
printf 'Filename: https://github.com/example/apt-hub/releases/download/v0.0.10/golang.deb\n' \
  >"${ARCH_PREFIX}/repos/golang/dists/jammy/main/binary-amd64/Packages"
printf '1\n' >"${OLD_STATE}/v0.0.1.present"
rc="$(run_old prefix EVENT_NAME=push REF=refs/tags/v0.0.3 APT_HUB_VIEW_MODE=present APT_HUB_TAG_EXISTS=1 APT_HUB_ARCHIVE_DIR="${ARCH_PREFIX}")"
record "remove_old_tag_prefix" "${rc}" 0
if grep -Fq 'deleted v0.0.1' "${OLD_STATE}/deleted.log"; then
  pass "v0.0.10 不保护 v0.0.1"
else
  fail "v0.0.10 被当成 v0.0.1 引用"
fi
rc="$(run_old orphan EVENT_NAME=push REF=refs/tags/v0.0.5 APT_HUB_VIEW_MODE=404 APT_HUB_TAG_EXISTS=1)"
record "remove_old_orphan_tag" "${rc}" 0
if grep -Fq 'git-delete v0.0.3' "${OLD_STATE}/deleted.log" \
  && ! grep -Fq 'deleted v0.0.3' "${OLD_STATE}/deleted.log"; then
  pass "无 Release 的残留 tag 会补删"
else
  fail "404 后残留 tag 未补删"
fi
rc="$(run_old fetch EVENT_NAME=push REF=refs/tags/v0.0.5 APT_HUB_FETCH_FAIL=1)"
record "remove_old_fetch_fail" "${rc}" 1

cfg_before="$(sha256sum -- "${ROOT}/config/packages.json" "${ROOT}/config/go.json")"
set +e
env -u GH_TOKEN PATH="/usr/bin:/bin" "${ASSETS}" local-status --asset-dir "${OUT_BUILD}" \
  >"${EVIDENCE}/runs/local-ok.out" 2>"${EVIDENCE}/runs/local-ok.err"
rc=$?
set -e
record "local_status_fixture" "${rc}" 0
if grep -Fxq 'release_assets.sh: 本地构造集完整' "${EVIDENCE}/runs/local-ok.out"; then
  pass "local-status 认可用 fixture"
else
  fail "local-status 成功语义不对"
fi
gap="${EVIDENCE}/local-gap"
rm -rf -- "${gap}"
mkdir -p -- "${gap}"
cp -a -- "${OUT_BUILD}/." "${gap}/"
rm -f -- "${gap}"/golang-go_*.deb
jq 'del(.packages[] | select(.package=="golang-go"))' "${gap}/golang.provenance.json" >"${EVIDENCE}/runs/local-gap.prov"
mv -f -- "${EVIDENCE}/runs/local-gap.prov" "${gap}/golang.provenance.json"
(
  cd -- "${gap}"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort \
    | while IFS= read -r fname; do sha256sum -- "${fname}"; done
) | LC_ALL=C sort -k2 >"${EVIDENCE}/runs/local-gap.sums"
mv -f -- "${EVIDENCE}/runs/local-gap.sums" "${gap}/SHA256SUMS"
set +e
env -u GH_TOKEN PATH="/usr/bin:/bin" "${ASSETS}" local-status --asset-dir "${gap}" \
  >"${EVIDENCE}/runs/local-gap.out" 2>"${EVIDENCE}/runs/local-gap.err"
rc=$?
set -e
record "local_status_missing_group" "${rc}" 1
if grep -Fq '来源与规定组合不一致' "${EVIDENCE}/runs/local-gap.err"; then
  pass "缺整组 golang-go 拒绝"
else
  fail "缺整组未按组合拒绝"
fi
cache="${EVIDENCE}/local-cache"
rm -rf -- "${cache}"
mkdir -p -- "${cache}/cache"
cp -a -- "${OUT_BUILD}/." "${cache}/"
printf 'x\n' >"${cache}/cache/obj"
set +e
env -u GH_TOKEN PATH="/usr/bin:/bin" "${ASSETS}" local-status --asset-dir "${cache}" \
  >"${EVIDENCE}/runs/local-cache.out" 2>"${EVIDENCE}/runs/local-cache.err"
rc=$?
set -e
record "local_status_cache" "${rc}" 1
if grep -Fq '目录含非构造文件' "${EVIDENCE}/runs/local-cache.err" \
  && ! grep -Fq '本地构造集完整' "${EVIDENCE}/runs/local-cache.out"; then
  pass "缓存目录拒绝且无完整输出"
else
  fail "缓存目录未拒绝"
fi
sand="${EVIDENCE}/deb-only"
rm -rf -- "${sand}"
mkdir -p -- "${sand}/scripts" "${sand}/config" "${sand}/bin"
cp -f -- "${ASSETS}" "${sand}/scripts/release_assets.sh"
cp -f -- "${ROOT}/config/go.json" "${sand}/config/go.json"
jq '{schema_version,packages:[.packages[]|select((.source_type // "githubdeb")=="githubdeb")]}' \
  "${ROOT}/config/packages.json" >"${sand}/config/packages.json"
jq -e '([.packages[]|select(.id=="rustdesk")]|length)==1 and ([.packages[]|select(.source_type=="go_official_archive")]|length)==0' \
  "${sand}/config/packages.json" >/dev/null || fail "deb-only 副本不是 githubdeb 子集"
printf '%s\n' '#!/bin/bash' "printf \"%s\\n\" \"\$*\" >> \"\${GH_TRIP_LOG:?}\"" 'exit 99' >"${sand}/bin/gh"
chmod a+x -- "${sand}/bin/gh" "${sand}/scripts/release_assets.sh"
: >"${sand}/gh.log"
set +e
env -u GH_TOKEN PATH="${sand}/bin:/usr/bin:/bin" GH_TRIP_LOG="${sand}/gh.log" \
  "${sand}/scripts/release_assets.sh" remote-status --repository example/apt-hub --tag v0.0.2 \
  >"${EVIDENCE}/runs/deb-only.out" 2>"${EVIDENCE}/runs/deb-only.err"
rc=$?
set -e
record "remote_deb_only" "${rc}" 0
if grep -Fq '无可构造条目' "${EVIDENCE}/runs/deb-only.out" && [[ ! -s "${sand}/gh.log" ]]; then
  pass "deb-only 副本跳过且未调 gh"
else
  fail "deb-only 语义不对"
fi
jq '.packages[0].source_type="made_up"' "${sand}/config/packages.json" >"${sand}/config/made_up.json"
mv -f -- "${sand}/config/made_up.json" "${sand}/config/packages.json"
: >"${sand}/gh.log"
set +e
env -u GH_TOKEN PATH="${sand}/bin:/usr/bin:/bin" GH_TRIP_LOG="${sand}/gh.log" \
  "${sand}/scripts/release_assets.sh" remote-status --repository example/apt-hub --tag v0.0.2 \
  >"${EVIDENCE}/runs/unknown.out" 2>"${EVIDENCE}/runs/unknown.err"
rc=$?
set -e
record "remote_unknown_type" "${rc}" 1
if grep -Fq '未知 source_type: made_up' "${EVIDENCE}/runs/unknown.err" && [[ ! -s "${sand}/gh.log" ]]; then
  pass "未知 source_type 在副本中拒绝"
else
  fail "未知 source_type 未拒绝"
fi
if [[ "$(sha256sum -- "${ROOT}/config/packages.json" "${ROOT}/config/go.json")" == "${cfg_before}" ]]; then
  pass "主配置未被测试改写"
else
  fail "主配置被测试改写"
fi

if [[ "$(tr -d '[:space:]' <"${VERSION_FILE}")" == "${VER_BEFORE}" ]]; then
  pass "VERSION 未改"
else
  fail "VERSION 被改"
fi

{
  echo "PASS=${PASS}"
  echo "FAIL=${FAIL}"
} | tee "${EVIDENCE}/summary.txt"
log "TOTAL PASS=${PASS} FAIL=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
