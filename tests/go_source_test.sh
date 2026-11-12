#!/usr/bin/env bash
# Go 同源双包 golang+golang-go、rotate-from、真 APT type:deb download/upgrade。
set -euo pipefail
export LC_ALL=C
export LANG=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="${ROOT}/scripts/sync.sh"
UPD="${ROOT}/scripts/update_sources.sh"
VER="${ROOT}/scripts/verify_ubuntu.sh"
FIXTURE_JS="${ROOT}/tests/apt_release_fixture.mjs"
TMP="${ROOT}/tmp/b-consumer/go-source"
EVIDENCE="${TMP}/evidence.log"
SITE_URL='https://apt-hub.example.test'
PKG_REPO='fixture/apt-hub'
GO_TAG='v0.0.9'
PROV_ASSET='golang.provenance.json'
LEGACY_TAG='golang-9.9.9-1'
PASS=0
FAIL=0
SERVER_PID=""

mkdir -p -- "${ROOT}/tmp/b-consumer"
rm -rf -- "${TMP}"
mkdir -p -- "${TMP}/bin" "${TMP}/debs" "${TMP}/api" "${TMP}/empty-prev" "${TMP}/tls" "${TMP}/assets"

{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "root=${ROOT}"
} >"${EVIDENCE}"

log() { printf '%s\n' "$*" | tee -a "${EVIDENCE}"; }
# shellcheck disable=SC2317 # EXIT trap 间接调用
cleanup() {
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  gpgconf --homedir "${GNUPG:-/dev/null}" --kill gpg-agent >/dev/null 2>&1 || true
  gpgconf --homedir "${GNUPG2:-/dev/null}" --kill gpg-agent >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'log "ERR line=${LINENO} cmd=${BASH_COMMAND}"; exit 1' ERR

record_rc() {
  local name="$1" rc="$2" expect="$3"
  log "CASE ${name}: exit=${rc} expect=${expect}"
  if [[ "${rc}" -eq "${expect}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    log "FAIL ${name}"
    return 1
  fi
}

capture_rc() {
  local logf="$1" rc=0
  shift
  "$@" >"${logf}" 2>&1 || rc=$?
  printf '%s\n' "${rc}"
}

sha_of() { sha256sum -- "$1" | awk '{print $1}'; }

build_deb() {
  local pkg="$1" ver="$2" arch="$3" dest="$4" depends="${5:-}" marker="${6:-ok}"
  local root="${TMP}/debroot/${pkg}-${ver}-${arch}-${marker}"
  rm -rf -- "${root}"
  mkdir -p -- "${root}/DEBIAN" "${root}/usr/share/doc/${pkg}"
  {
    cat <<EOF
Package: ${pkg}
Version: ${ver}
Architecture: ${arch}
Maintainer: apt-hub-go-source-test <invalid>
Description: go source fixture ${pkg}
EOF
    if [[ -n "${depends}" ]]; then
      printf 'Depends: %s\n' "${depends}"
    fi
  } >"${root}/DEBIAN/control"
  printf 'payload %s %s %s %s\n' "${pkg}" "${ver}" "${arch}" "${marker}" \
    >"${root}/usr/share/doc/${pkg}/README"
  dpkg-deb --build --root-owner-group -- "${root}" "${dest}" >/dev/null
}

map_add() { printf '%s\t%s\n' "$1" "$2" >>"${TMP}/curl-map.tsv"; }

cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="" url="" proto="" proto_redir=""
args=("$@"); i=0
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
    http://*) printf 'fixture-curl: reject http\n' >&2; exit 1 ;;
    --url) i=$((i + 1)); url="${args[$i]}" ;;
  esac
  i=$((i + 1))
done
[[ "${proto}" == "=https" && "${proto_redir}" == "=https" ]] || { echo 'proto' >&2; exit 1; }
[[ -n "${url}" ]] || { echo 'missing url' >&2; exit 1; }
map="${CURL_FIXTURE_MAP:?}"
file="$(awk -F '\t' -v u="${url}" '$1==u {print $2; exit}' "${map}")"
[[ -n "${file}" && -f "${file}" ]] || { printf 'fixture-curl: 无映射 %s\n' "${url}" >&2; exit 1; }
if [[ -n "${out}" ]]; then cp -- "${file}" "${out}"; else cat -- "${file}"; fi
EOF
chmod 755 -- "${TMP}/bin/curl" "${SYNC}" "${UPD}" "${VER}"
export PATH="${TMP}/bin:${PATH}"
export CURL_FIXTURE_MAP="${TMP}/curl-map.tsv"

log "CASE bash_n"
bash -n -- "${SYNC}"; record_rc bash_n_sync "$?" 0 || true
bash -n -- "${UPD}"; record_rc bash_n_upd "$?" 0 || true
bash -n -- "${VER}"; record_rc bash_n_ver "$?" 0 || true
bash -n -- "${ROOT}/tests/go_source_test.sh"; record_rc bash_n_test "$?" 0 || true

# --- 双包夹具：元包 Depends 工具包；无 libc6 ---
VER_FULL='2:9.9.9-1'
build_deb golang-go "${VER_FULL}" amd64 "${TMP}/debs/golang-go_9.9.9-1_amd64.deb"
build_deb golang-go "${VER_FULL}" arm64 "${TMP}/debs/golang-go_9.9.9-1_arm64.deb"
build_deb golang "${VER_FULL}" amd64 "${TMP}/debs/golang_9.9.9-1_amd64.deb" "golang-go (= ${VER_FULL})"
build_deb golang "${VER_FULL}" arm64 "${TMP}/debs/golang_9.9.9-1_arm64.deb" "golang-go (= ${VER_FULL})"
build_deb golang "${VER_FULL}" amd64 "${TMP}/debs/golang_9.9.9-1_amd64-replaced.deb" "golang-go (= ${VER_FULL})" replaced
build_deb alpha 1.0.0 amd64 "${TMP}/debs/alpha_1.0.0_amd64.deb"
META_AMD_SHA="$(sha_of "${TMP}/debs/golang_9.9.9-1_amd64.deb")"
META_ARM_SHA="$(sha_of "${TMP}/debs/golang_9.9.9-1_arm64.deb")"
TOOL_AMD_SHA="$(sha_of "${TMP}/debs/golang-go_9.9.9-1_amd64.deb")"
TOOL_ARM_SHA="$(sha_of "${TMP}/debs/golang-go_9.9.9-1_arm64.deb")"
META_AMD_SZ="$(stat -c '%s' -- "${TMP}/debs/golang_9.9.9-1_amd64.deb")"
META_ARM_SZ="$(stat -c '%s' -- "${TMP}/debs/golang_9.9.9-1_arm64.deb")"
TOOL_AMD_SZ="$(stat -c '%s' -- "${TMP}/debs/golang-go_9.9.9-1_amd64.deb")"
TOOL_ARM_SZ="$(stat -c '%s' -- "${TMP}/debs/golang-go_9.9.9-1_arm64.deb")"
UP_AMD_SHA="$(printf 'amd-upstream-tar-fixture' | sha256sum | awk '{print $1}')"
UP_ARM_SHA="$(printf 'arm-upstream-tar-fixture' | sha256sum | awk '{print $1}')"
UP_AMD_SZ=111
UP_ARM_SZ=222

write_provenance() {
  local dest="$1"
  local meta_amd="${2:-${META_AMD_SHA}}" meta_arm="${3:-${META_ARM_SHA}}"
  local tool_amd="${4:-${TOOL_AMD_SHA}}" tool_arm="${5:-${TOOL_ARM_SHA}}"
  local up_amd="${6:-${UP_AMD_SHA}}" up_arm="${7:-${UP_ARM_SHA}}"
  local meta_amd_sz="${8:-${META_AMD_SZ}}" meta_arm_sz="${9:-${META_ARM_SZ}}"
  local tool_amd_sz="${10:-${TOOL_AMD_SZ}}" tool_arm_sz="${11:-${TOOL_ARM_SZ}}"
  jq -n \
    --arg meta_amd "${meta_amd}" --arg meta_arm "${meta_arm}" \
    --arg tool_amd "${tool_amd}" --arg tool_arm "${tool_arm}" \
    --argjson meta_amd_sz "${meta_amd_sz}" --argjson meta_arm_sz "${meta_arm_sz}" \
    --argjson tool_amd_sz "${tool_amd_sz}" --argjson tool_arm_sz "${tool_arm_sz}" \
    --arg up_amd "${up_amd}" --arg up_arm "${up_arm}" \
    --argjson up_amd_sz "${UP_AMD_SZ}" --argjson up_arm_sz "${UP_ARM_SZ}" \
    '{
      schema_version:"1",
      generated_at_utc:"2026-11-09T00:00:00Z",
      upstream:{version:"go9.9.9",version_debian:"9.9.9",revision:"1",epoch:"2"},
      packages:[
        {package:"golang",version:"2:9.9.9-1",architecture:"amd64",
         filename:"golang_9.9.9-1_amd64.deb",sha256:$meta_amd,size:($meta_amd_sz|tostring),
         upstream:{url:"https://go.dev/dl/go9.9.9.linux-amd64.tar.gz",sha256:$up_amd,size:($up_amd_sz|tostring)}},
        {package:"golang-go",version:"2:9.9.9-1",architecture:"amd64",
         filename:"golang-go_9.9.9-1_amd64.deb",sha256:$tool_amd,size:($tool_amd_sz|tostring),
         upstream:{url:"https://go.dev/dl/go9.9.9.linux-amd64.tar.gz",sha256:$up_amd,size:($up_amd_sz|tostring)}},
        {package:"golang",version:"2:9.9.9-1",architecture:"arm64",
         filename:"golang_9.9.9-1_arm64.deb",sha256:$meta_arm,size:($meta_arm_sz|tostring),
         upstream:{url:"https://go.dev/dl/go9.9.9.linux-arm64.tar.gz",sha256:$up_arm,size:($up_arm_sz|tostring)}},
        {package:"golang-go",version:"2:9.9.9-1",architecture:"arm64",
         filename:"golang-go_9.9.9-1_arm64.deb",sha256:$tool_arm,size:($tool_arm_sz|tostring),
         upstream:{url:"https://go.dev/dl/go9.9.9.linux-arm64.tar.gz",sha256:$up_arm,size:($up_arm_sz|tostring)}}
      ]
    }' >"${dest}"
}

write_provenance "${TMP}/api/provenance.json"

write_release_json() {
  local dest="$1"
  local prov_path="${2:-${TMP}/api/provenance.json}"
  local meta_amd_sha="${3:-${META_AMD_SHA}}" meta_amd_sz="${4:-${META_AMD_SZ}}"
  local sp dp
  sp="$(stat -c '%s' -- "${prov_path}")"
  dp="$(sha_of "${prov_path}")"
  jq -n \
    --arg tag "${GO_TAG}" \
    --arg html "https://github.com/${PKG_REPO}/releases/tag/${GO_TAG}" \
    --argjson s1 "${meta_amd_sz}" --argjson s2 "${TOOL_AMD_SZ}" \
    --argjson s3 "${META_ARM_SZ}" --argjson s4 "${TOOL_ARM_SZ}" --argjson sp "${sp}" \
    --arg d1 "sha256:${meta_amd_sha}" --arg d2 "sha256:${TOOL_AMD_SHA}" \
    --arg d3 "sha256:${META_ARM_SHA}" --arg d4 "sha256:${TOOL_ARM_SHA}" --arg dp "sha256:${dp}" \
    --arg base "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}" \
    --arg pname "${PROV_ASSET}" \
    '{
      tag_name:$tag, html_url:$html, draft:false, prerelease:false,
      assets:[
        {name:"golang_9.9.9-1_amd64.deb",size:$s1,browser_download_url:($base+"/golang_9.9.9-1_amd64.deb"),digest:$d1},
        {name:"golang-go_9.9.9-1_amd64.deb",size:$s2,browser_download_url:($base+"/golang-go_9.9.9-1_amd64.deb"),digest:$d2},
        {name:"golang_9.9.9-1_arm64.deb",size:$s3,browser_download_url:($base+"/golang_9.9.9-1_arm64.deb"),digest:$d3},
        {name:"golang-go_9.9.9-1_arm64.deb",size:$s4,browser_download_url:($base+"/golang-go_9.9.9-1_arm64.deb"),digest:$d4},
        {name:$pname,size:$sp,browser_download_url:($base+"/"+$pname),digest:$dp}
      ]
    }' >"${dest}"
}
write_release_json "${TMP}/api/go-release.json"

jq -n \
  --arg up_amd "${UP_AMD_SHA}" --arg up_arm "${UP_ARM_SHA}" \
  --argjson up_amd_sz "${UP_AMD_SZ}" --argjson up_arm_sz "${UP_ARM_SZ}" \
  '[{
    version:"go9.9.9", stable:true,
    files:[
      {filename:"go9.9.9.linux-amd64.tar.gz",os:"linux",arch:"amd64",version:"go9.9.9",
       sha256:$up_amd,size:$up_amd_sz,kind:"archive"},
      {filename:"go9.9.9.linux-arm64.tar.gz",os:"linux",arch:"arm64",version:"go9.9.9",
       sha256:$up_arm,size:$up_arm_sz,kind:"archive"}
    ]
  }]' >"${TMP}/api/go-downloads.json"

reset_curl_map() {
  : >"${TMP}/curl-map.tsv"
  map_add "https://api.github.com/repos/${PKG_REPO}/releases/tags/${GO_TAG}" "${TMP}/api/go-release.json"
  map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang_9.9.9-1_amd64.deb" "${TMP}/debs/golang_9.9.9-1_amd64.deb"
  map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang-go_9.9.9-1_amd64.deb" "${TMP}/debs/golang-go_9.9.9-1_amd64.deb"
  map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang_9.9.9-1_arm64.deb" "${TMP}/debs/golang_9.9.9-1_arm64.deb"
  map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang-go_9.9.9-1_arm64.deb" "${TMP}/debs/golang-go_9.9.9-1_arm64.deb"
  map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/${PROV_ASSET}" "${TMP}/api/provenance.json"
}
reset_curl_map
mkdir -p -- "${TMP}/upstream"
printf '%s\n' '{"tag_name":"v9.9.9","draft":false,"prerelease":false,"html_url":"https://github.com/fixture/apt-hub/releases/tag/v9.9.9","assets":[]}' \
  >"${TMP}/upstream/golang.json"

# HTTPS 资产树（Filename 相对 github.com/）
ASSET_REL="fixture/apt-hub/releases/download/${GO_TAG}"
mkdir -p -- "${TMP}/assets/${ASSET_REL}"
cp -- "${TMP}/debs/"*.deb "${TMP}/assets/${ASSET_REL}/"

jq -n '{
  schema_version:1,
  source_url:"fixture",
  checked_at:"2026-11-09T00:00:00Z",
  releases:[{series:"jammy",version:"22.04",release_date:"2022-04-21",eol_date:"2027-06-01"}]
}' >"${TMP}/releases.json"

jq -n '{
  schema_version:"2",
  packages:[{
    id:"golang", package:"golang", source_type:"go_official_archive",
    repository:"golang/go", description:"Go fixture",
    source_url:"https://go.dev", license:"BSD-3-Clause",
    ubuntu_series:["jammy"],
    architectures:{
      amd64:"^golang_[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+_amd64\\.deb$",
      arm64:"^golang_[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+_arm64\\.deb$"
    }
  }]
}' >"${TMP}/catalog-go.json"
printf '%s\n' '{"schema_version":"2","packages":[]}' >"${TMP}/catalog-empty.json"

GNUPG="${TMP}/gnupg"
GNUPG2="${TMP}/gnupg2"
mkdir -m 700 -- "${GNUPG}" "${GNUPG2}"
printf 'allow-loopback-pinentry\n' >"${GNUPG}/gpg-agent.conf"
printf 'allow-loopback-pinentry\n' >"${GNUPG2}/gpg-agent.conf"
gpg --homedir "${GNUPG}" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "apt-hub go-source <go-source@invalid>" ed25519 sign never
FP="$(gpg --homedir "${GNUPG}" --batch --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')"
gpg --homedir "${GNUPG2}" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "apt-hub go-source-new <go-source-new@invalid>" ed25519 sign never
FP2="$(gpg --homedir "${GNUPG2}" --batch --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')"
log "fp_old=${FP} fp_new=${FP2}"

# 废止 apt-hub-go catalog 拒绝
jq '.packages[0].package="apt-hub-go"' "${TMP}/catalog-go.json" >"${TMP}/catalog-legacy.json"
rc="$(capture_rc "${TMP}/run-legacy-cat.log" "${SYNC}" \
  --catalog "${TMP}/catalog-legacy.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-legacy" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}" --release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json")"
record_rc legacy_apt_hub_go_catalog_rejected "${rc}" 1 || true
rc=0
grep -Eq '必须是 golang|apt-hub-go' "${TMP}/run-legacy-cat.log" || rc=1
record_rc legacy_apt_hub_go_reason "${rc}" 0 || true

# shellcheck disable=SC2317 # 经 capture_rc "$@" 间接调用
run_sync_go() {
  local prev="$1" out="$2"
  shift 2
  "${SYNC}" \
    --catalog "${TMP}/catalog-go.json" \
    --releases "${TMP}/releases.json" \
    --previous "${prev}" \
    --output "${out}" \
    --gnupghome "${GNUPG}" \
    --fingerprint "${FP}" \
    --site-url "${SITE_URL}" \
    --package-repository "${PKG_REPO}" \
    --release-tag "${GO_TAG}" \
    --upstream-dir "${TMP}/upstream" \
    --go-downloads-json "${TMP}/api/go-downloads.json" \
    "$@"
}

# 缺 release-tag 拒
rc="$(capture_rc "${TMP}/run-no-tag.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-no-tag" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}")"
record_rc go_missing_release_tag_rejected "${rc}" 1 || true
rc=0
grep -Fq 'release-tag' "${TMP}/run-no-tag.log" || rc=1
record_rc go_missing_tag_reason "${rc}" 0 || true
rc=0
[[ ! -e "${TMP}/site-no-tag" ]] || rc=1
record_rc go_missing_tag_no_output "${rc}" 0 || true

# 新活跃拒绝存量 golang-* tag
rc="$(capture_rc "${TMP}/run-legacy-tag.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-legacy-tag" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}" --release-tag "${LEGACY_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json")"
record_rc go_legacy_tag_active_rejected "${rc}" 1 || true
rc=0
grep -Fq '严格 vX.Y.Z' "${TMP}/run-legacy-tag.log" || rc=1
record_rc go_legacy_tag_reason "${rc}" 0 || true

# 缺工具包 golang-go arm64：release 去掉该资产，外层 provenance 仍完整
jq '(.assets |= map(select(.name != "golang-go_9.9.9-1_arm64.deb")))' \
  "${TMP}/api/go-release.json" >"${TMP}/api/go-release-no-tool-arm.json"
cp -f -- "${TMP}/api/go-release-no-tool-arm.json" "${TMP}/api/go-release.json"
(cd "${TMP}/empty-prev" && find . -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum) \
  >"${TMP}/empty-prev.before" || : >"${TMP}/empty-prev.before"
rc="$(capture_rc "${TMP}/run-no-tool-arm.log" run_sync_go "${TMP}/empty-prev" "${TMP}/site-no-tool-arm")"
record_rc go_missing_tool_arm64_rejected "${rc}" 1 || true
rc=0
[[ ! -e "${TMP}/site-no-tool-arm" ]] || rc=1
record_rc go_missing_tool_arm64_no_output "${rc}" 0 || true
rc=0
cmp -s "${TMP}/empty-prev.before" \
  <(cd "${TMP}/empty-prev" && find . -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum || true) || rc=1
record_rc go_missing_tool_arm64_previous_unchanged "${rc}" 0 || true
write_release_json "${TMP}/api/go-release.json"
reset_curl_map

# 缺主包架构：catalog 声明 arm64 但 release 去掉 golang arm64
jq '(.assets |= map(select(.name != "golang_9.9.9-1_arm64.deb")))' \
  "${TMP}/api/go-release.json" >"${TMP}/api/go-release-no-meta-arm.json"
cp -f -- "${TMP}/api/go-release-no-meta-arm.json" "${TMP}/api/go-release.json"
rc="$(capture_rc "${TMP}/run-no-arch.log" run_sync_go "${TMP}/empty-prev" "${TMP}/site-no-arch")"
record_rc go_missing_arch_rejected "${rc}" 1 || true
rc=0
[[ ! -e "${TMP}/site-no-arch" ]] || rc=1
record_rc go_missing_arch_no_output "${rc}" 0 || true
write_release_json "${TMP}/api/go-release.json"
reset_curl_map

# provenance 外层 digest 不符（内层文件未改）
BAD_PROV_SHA="$(printf 'bad-prov' | sha256sum | awk '{print $1}')"
jq --arg d "sha256:${BAD_PROV_SHA}" \
  --arg n "${PROV_ASSET}" \
  '(.assets |= map(if .name==$n then .digest=$d else . end))' \
  "${TMP}/api/go-release.json" >"${TMP}/api/go-release-bad-prov.json"
cp -f -- "${TMP}/api/go-release-bad-prov.json" "${TMP}/api/go-release.json"
rc="$(capture_rc "${TMP}/run-bad-prov.log" run_sync_go "${TMP}/empty-prev" "${TMP}/site-bad-prov")"
record_rc go_manifest_hash_rejected "${rc}" 1 || true
write_release_json "${TMP}/api/go-release.json"
reset_curl_map

# 官方上游 tar 摘要不符：改 provenance 内层并同步外层 digest，避免外层先拒
BAD_UP="$(printf 'bad-up' | sha256sum | awk '{print $1}')"
write_provenance "${TMP}/api/provenance-bad-up.json" \
  "${META_AMD_SHA}" "${META_ARM_SHA}" "${TOOL_AMD_SHA}" "${TOOL_ARM_SHA}" \
  "${BAD_UP}" "${UP_ARM_SHA}"
cp -f -- "${TMP}/api/provenance-bad-up.json" "${TMP}/api/provenance.json"
write_release_json "${TMP}/api/go-release.json" "${TMP}/api/provenance.json"
reset_curl_map
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/${PROV_ASSET}" "${TMP}/api/provenance.json"
rc="$(capture_rc "${TMP}/run-bad-up.log" run_sync_go "${TMP}/empty-prev" "${TMP}/site-bad-up")"
record_rc go_upstream_tar_hash_rejected "${rc}" 1 || true
rc=0
grep -Fq '官方原 tar' "${TMP}/run-bad-up.log" || grep -Fqi 'go.dev' "${TMP}/run-bad-up.log" || rc=1
record_rc go_upstream_reason "${rc}" 0 || true
write_provenance "${TMP}/api/provenance.json"
write_release_json "${TMP}/api/go-release.json"
reset_curl_map

# GREEN：首次 sync
rc="$(capture_rc "${TMP}/run-ok.log" run_sync_go "${TMP}/empty-prev" "${TMP}/site-go1")"
cat "${TMP}/run-ok.log" >>"${EVIDENCE}"
record_rc go_first_sync "${rc}" 0 || true
rc=0
jq -e '
  .schema_version=="2"
  and (.packages|length==1)
  and .packages[0].id=="golang"
  and .packages[0].package=="golang"
  and .packages[0].source_type=="go_official_archive"
  and .packages[0].version=="2:9.9.9-1"
  and .packages[0].release_tag=="v0.0.9"
  and (.packages[0].assets|length==4)
  and ([.packages[0].assets[].package]|sort)==["golang","golang","golang-go","golang-go"]
  and all(.packages[0].assets[]; (.upstream.sha256|type)=="string")
' "${TMP}/site-go1/state.json" >/dev/null || rc=$?
record_rc go_state_dual_assets "${rc}" 0 || true
rc=0
# Packages 含两 stanza
grep -c '^Package: ' "${TMP}/site-go1/repos/golang/dists/jammy/main/binary-amd64/Packages" | grep -qx 2 || rc=1
record_rc go_packages_two_stanzas_amd64 "${rc}" 0 || true
rc=0
if find -- "${TMP}/site-go1" -type f -name '*.deb' -print -quit | grep -q .; then rc=1; fi
record_rc go_metadata_no_deb "${rc}" 0 || true

# 同版本内容替换拒（golang amd64 bytes 变，外层 digest 与 provenance 同步更新）
REPL_SHA="$(sha_of "${TMP}/debs/golang_9.9.9-1_amd64-replaced.deb")"
REPL_SZ="$(stat -c '%s' -- "${TMP}/debs/golang_9.9.9-1_amd64-replaced.deb")"
write_provenance "${TMP}/api/provenance-repl.json" \
  "${REPL_SHA}" "${META_ARM_SHA}" "${TOOL_AMD_SHA}" "${TOOL_ARM_SHA}" \
  "${UP_AMD_SHA}" "${UP_ARM_SHA}" \
  "${REPL_SZ}" "${META_ARM_SZ}" "${TOOL_AMD_SZ}" "${TOOL_ARM_SZ}"
write_release_json "${TMP}/api/go-release-repl.json" "${TMP}/api/provenance-repl.json" \
  "${REPL_SHA}" "${REPL_SZ}"
: >"${TMP}/curl-map.tsv"
map_add "https://api.github.com/repos/${PKG_REPO}/releases/tags/${GO_TAG}" "${TMP}/api/go-release-repl.json"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang_9.9.9-1_amd64.deb" "${TMP}/debs/golang_9.9.9-1_amd64-replaced.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang-go_9.9.9-1_amd64.deb" "${TMP}/debs/golang-go_9.9.9-1_amd64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang_9.9.9-1_arm64.deb" "${TMP}/debs/golang_9.9.9-1_arm64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang-go_9.9.9-1_arm64.deb" "${TMP}/debs/golang-go_9.9.9-1_arm64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/${PROV_ASSET}" "${TMP}/api/provenance-repl.json"
cp -f -- "${TMP}/api/go-release-repl.json" "${TMP}/api/go-release.json"
cp -f -- "${TMP}/api/provenance-repl.json" "${TMP}/api/provenance.json"
(cd "${TMP}/site-go1" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"${TMP}/site-go1-before-repl"
rc="$(capture_rc "${TMP}/run-repl.log" run_sync_go "${TMP}/site-go1" "${TMP}/site-go-repl")"
record_rc go_same_version_replace_rejected "${rc}" 1 || true
rc=0
grep -Fq '同名版本内容替换' "${TMP}/run-repl.log" || rc=1
record_rc go_replace_reason "${rc}" 0 || true
rc=0
[[ ! -e "${TMP}/site-go-repl" ]] || rc=1
record_rc go_replace_no_output "${rc}" 0 || true
rc=0
cmp -s "${TMP}/site-go1-before-repl" \
  <(cd "${TMP}/site-go1" && find . -type f -print0 | sort -z | xargs -0 sha256sum) || rc=1
record_rc go_replace_previous_unchanged "${rc}" 0 || true
write_provenance "${TMP}/api/provenance.json"
write_release_json "${TMP}/api/go-release.json"
reset_curl_map

# 跨 tag 同版换字节：URL 不同也必须拒
saved_tag="${GO_TAG}"
GO_TAG='v0.0.10'
write_provenance "${TMP}/api/provenance-cross-bad.json" \
  "${REPL_SHA}" "${META_ARM_SHA}" "${TOOL_AMD_SHA}" "${TOOL_ARM_SHA}" \
  "${UP_AMD_SHA}" "${UP_ARM_SHA}" \
  "${REPL_SZ}" "${META_ARM_SZ}" "${TOOL_AMD_SZ}" "${TOOL_ARM_SZ}"
write_release_json "${TMP}/api/go-release-cross-bad.json" "${TMP}/api/provenance-cross-bad.json" \
  "${REPL_SHA}" "${REPL_SZ}"
: >"${TMP}/curl-map.tsv"
map_add "https://api.github.com/repos/${PKG_REPO}/releases/tags/${GO_TAG}" "${TMP}/api/go-release-cross-bad.json"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang_9.9.9-1_amd64.deb" "${TMP}/debs/golang_9.9.9-1_amd64-replaced.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang-go_9.9.9-1_amd64.deb" "${TMP}/debs/golang-go_9.9.9-1_amd64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang_9.9.9-1_arm64.deb" "${TMP}/debs/golang_9.9.9-1_arm64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/golang-go_9.9.9-1_arm64.deb" "${TMP}/debs/golang-go_9.9.9-1_arm64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/${PROV_ASSET}" "${TMP}/api/provenance-cross-bad.json"
cp -f -- "${TMP}/api/go-release-cross-bad.json" "${TMP}/api/go-release.json"
cp -f -- "${TMP}/api/provenance-cross-bad.json" "${TMP}/api/provenance.json"
rc="$(capture_rc "${TMP}/run-cross-bad.log" run_sync_go "${TMP}/site-go1" "${TMP}/site-cross-bad")"
record_rc go_cross_tag_byte_rejected "${rc}" 1 || true
rc=0
grep -Fq '禁止同包同版内容替换' "${TMP}/run-cross-bad.log" || rc=1
record_rc go_cross_tag_byte_reason "${rc}" 0 || true
rc=0
[[ ! -e "${TMP}/site-cross-bad" ]] || rc=1
record_rc go_cross_tag_byte_no_output "${rc}" 0 || true

# 跨 tag 同字节换址：允许，并保留 previous by-hash
GO_TAG='v0.0.10'
write_provenance "${TMP}/api/provenance.json"
write_release_json "${TMP}/api/go-release.json"
reset_curl_map
old_byhash="$(find "${TMP}/site-go1/repos/golang/dists/jammy/main/binary-amd64/by-hash/SHA256" -type f -printf '%f\n' | head -1)"
rc="$(capture_rc "${TMP}/run-cross-ok.log" run_sync_go "${TMP}/site-go1" "${TMP}/site-cross-ok")"
record_rc go_cross_tag_same_bytes "${rc}" 0 || true
rc=0
jq -e --arg t "${GO_TAG}" --arg s "${META_AMD_SHA}" '
  .packages[0].release_tag==$t
  and any(.packages[0].assets[]; .package=="golang" and .architecture=="amd64" and .sha256==$s)
' "${TMP}/site-cross-ok/state.json" >/dev/null || rc=1
record_rc go_cross_tag_same_bytes_state "${rc}" 0 || true
rc=0
[[ -n "${old_byhash}" && -f "${TMP}/site-cross-ok/repos/golang/dists/jammy/main/binary-amd64/by-hash/SHA256/${old_byhash}" ]] || rc=1
record_rc go_cross_tag_keeps_byhash "${rc}" 0 || true
GO_TAG="${saved_tag}"
write_provenance "${TMP}/api/provenance.json"
write_release_json "${TMP}/api/go-release.json"
reset_curl_map

# 存量 previous：旧 golang-* 与 provenance.json 仍可再验，不改写成新 tag
legacy_src="${TMP}/site-legacy-prev"
rm -rf -- "${legacy_src}"
cp -a -- "${TMP}/site-go1" "${legacy_src}"
jq --arg a "${saved_tag}" --arg b "${LEGACY_TAG}" '
  def swap($x;$y): split($x)|join($y);
  .packages[0].release_tag=$b
  | .packages[0].release_url |= swap($a;$b)
  | .packages[0].assets |= map(.url |= swap($a;$b) | .filename |= swap($a;$b))
' "${legacy_src}/state.json" >"${legacy_src}/state.json.tmp"
mv -- "${legacy_src}/state.json.tmp" "${legacy_src}/state.json"
legacy_dist="${legacy_src}/repos/golang/dists/jammy"
for arch in amd64 arm64; do
  sed -i "s|${saved_tag}|${LEGACY_TAG}|g" "${legacy_dist}/main/binary-${arch}/Packages"
  gzip -n -9 -c -- "${legacy_dist}/main/binary-${arch}/Packages" >"${legacy_dist}/main/binary-${arch}/Packages.gz"
done
rm -f -- "${legacy_dist}/Release" "${legacy_dist}/Release.gpg" "${legacy_dist}/InRelease"
cat >"${TMP}/legacy-release.conf" <<'EOF'
APT::FTPArchive::MD5 "false";
APT::FTPArchive::SHA1 "false";
APT::FTPArchive::SHA512 "false";
APT::FTPArchive::SHA256 "true";
APT::FTPArchive::Release::Origin "apt-hub";
APT::FTPArchive::Release::Label "apt-hub";
APT::FTPArchive::Release::Suite "jammy";
APT::FTPArchive::Release::Codename "jammy";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Architectures "amd64 arm64";
APT::FTPArchive::Release::Acquire-By-Hash "yes";
APT::FTPArchive::Release::ValidTime "1209600";
EOF
apt-ftparchive -c "${TMP}/legacy-release.conf" release "${legacy_dist}" >"${TMP}/legacy-Release.body"
mv -- "${TMP}/legacy-Release.body" "${legacy_dist}/Release"
for arch in amd64 arm64; do
  for pkgf in Packages Packages.gz; do
    h="$(sha256sum -- "${legacy_dist}/main/binary-${arch}/${pkgf}" | awk '{print $1}')"
    install -m 644 -- "${legacy_dist}/main/binary-${arch}/${pkgf}" \
      "${legacy_dist}/main/binary-${arch}/by-hash/SHA256/${h}"
  done
done
gpg --homedir "${GNUPG}" --batch --yes --pinentry-mode loopback \
  --local-user "${FP}" --passphrase '' \
  --detach-sign --armor --output "${legacy_dist}/Release.gpg" -- "${legacy_dist}/Release"
gpg --homedir "${GNUPG}" --batch --yes --pinentry-mode loopback \
  --local-user "${FP}" --passphrase '' \
  --clearsign --output "${legacy_dist}/InRelease" -- "${legacy_dist}/Release"
jq --arg tag "${LEGACY_TAG}" --arg old "${saved_tag}" --arg repo "${PKG_REPO}" '
  def swap($x;$y): split($x)|join($y);
  .tag_name=$tag
  | .html_url=("https://github.com/"+$repo+"/releases/tag/"+$tag)
  | .assets |= map(
      .browser_download_url |= swap($old;$tag)
      | if .name=="golang.provenance.json" then
          .name="provenance.json"
          | .browser_download_url |= swap("golang.provenance.json";"provenance.json")
        else . end
    )
' "${TMP}/api/go-release.json" >"${TMP}/api/go-release-legacy.json"
map_add "https://api.github.com/repos/${PKG_REPO}/releases/tags/${LEGACY_TAG}" "${TMP}/api/go-release-legacy.json"
map_add "https://github.com/${PKG_REPO}/releases/download/${LEGACY_TAG}/golang_9.9.9-1_amd64.deb" "${TMP}/debs/golang_9.9.9-1_amd64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${LEGACY_TAG}/golang-go_9.9.9-1_amd64.deb" "${TMP}/debs/golang-go_9.9.9-1_amd64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${LEGACY_TAG}/golang_9.9.9-1_arm64.deb" "${TMP}/debs/golang_9.9.9-1_arm64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${LEGACY_TAG}/golang-go_9.9.9-1_arm64.deb" "${TMP}/debs/golang-go_9.9.9-1_arm64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${LEGACY_TAG}/provenance.json" "${TMP}/api/provenance.json"
legacy_byhash="$(find "${legacy_src}/repos/golang/dists/jammy/main/binary-amd64/by-hash/SHA256" -type f -printf '%f\n' | head -1)"
rc="$(capture_rc "${TMP}/run-legacy-read.log" "${SYNC}" \
  --catalog "${TMP}/catalog-empty.json" --releases "${TMP}/releases.json" \
  --previous "${legacy_src}" --output "${TMP}/site-legacy-read" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}" \
  --go-downloads-json "${TMP}/api/go-downloads.json")"
record_rc go_legacy_previous_read "${rc}" 0 || true
rc=0
jq -e --arg t "${LEGACY_TAG}" '.packages[0].release_tag==$t and .packages[0].source_type=="go_official_archive"' \
  "${TMP}/site-legacy-read/state.json" >/dev/null || rc=1
record_rc go_legacy_tag_kept "${rc}" 0 || true
rc=0
[[ -n "${legacy_byhash}" && -f "${TMP}/site-legacy-read/repos/golang/dists/jammy/main/binary-amd64/by-hash/SHA256/${legacy_byhash}" ]] || rc=1
record_rc go_legacy_keeps_byhash "${rc}" 0 || true
reset_curl_map

# retained 续签
UPDATED1="$(jq -r '.packages[0].updated_at' "${TMP}/site-go1/state.json")"
rc="$(capture_rc "${TMP}/run-retain.log" "${SYNC}" \
  --catalog "${TMP}/catalog-empty.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-go1" --output "${TMP}/site-go-retain" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}" \
  --go-downloads-json "${TMP}/api/go-downloads.json")"
record_rc go_retained_resign "${rc}" 0 || true
rc=0
jq -e --arg u "${UPDATED1}" '
  .packages[0].id=="golang" and .packages[0].updated_at==$u
  and .packages[0].source_type=="go_official_archive"
' "${TMP}/site-go-retain/state.json" >/dev/null || rc=1
record_rc go_retained_updated_at_kept "${rc}" 0 || true

# 静默换钥拒绝
rc="$(capture_rc "${TMP}/run-silent-rot.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-go1" --output "${TMP}/site-silent-rot" \
  --gnupghome "${GNUPG2}" --fingerprint "${FP2}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}" --release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json")"
record_rc silent_rotate_rejected "${rc}" 1 || true
rc=0
grep -Fq '拒绝静默换钥' "${TMP}/run-silent-rot.log" || rc=1
record_rc silent_rotate_reason "${rc}" 0 || true

# 错旧 fp
rc="$(capture_rc "${TMP}/run-bad-rot-fp.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-go1" --output "${TMP}/site-bad-rot-fp" \
  --gnupghome "${GNUPG2}" --fingerprint "${FP2}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}" --release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json" \
  --rotate-from AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)"
record_rc rotate_wrong_fp_rejected "${rc}" 1 || true
rc=0
[[ ! -e "${TMP}/site-bad-rot-fp" ]] || rc=1
record_rc rotate_wrong_fp_no_output "${rc}" 0 || true

# 坏旧签名 active（catalog 仍含 golang，换钥须先验 previous）
cp -a -- "${TMP}/site-go1" "${TMP}/site-bad-sig-active"
printf 'tampered\n' >>"${TMP}/site-bad-sig-active/repos/golang/dists/jammy/main/binary-amd64/Packages"
(cd "${TMP}/site-bad-sig-active" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"${TMP}/site-bad-sig-active.before"
rc="$(capture_rc "${TMP}/run-bad-sig-active.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-bad-sig-active" --output "${TMP}/site-bad-sig-active-out" \
  --gnupghome "${GNUPG2}" --fingerprint "${FP2}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}" --release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json" \
  --rotate-from "${FP}")"
record_rc rotate_active_bad_signature_rejected "${rc}" 1 || true
rc=0
[[ ! -e "${TMP}/site-bad-sig-active-out" ]] || rc=1
record_rc rotate_active_bad_sig_no_output "${rc}" 0 || true
rc=0
cmp -s "${TMP}/site-bad-sig-active.before" \
  <(cd "${TMP}/site-bad-sig-active" && find . -type f -print0 | sort -z | xargs -0 sha256sum) || rc=1
record_rc rotate_active_previous_unchanged "${rc}" 0 || true

# 坏旧签名 retained（空 catalog）
cp -a -- "${TMP}/site-go1" "${TMP}/site-bad-sig-ret"
printf 'tampered\n' >>"${TMP}/site-bad-sig-ret/repos/golang/dists/jammy/main/binary-amd64/Packages"
rc="$(capture_rc "${TMP}/run-bad-sig-ret.log" "${SYNC}" \
  --catalog "${TMP}/catalog-empty.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-bad-sig-ret" --output "${TMP}/site-bad-sig-ret-out" \
  --gnupghome "${GNUPG2}" --fingerprint "${FP2}" --site-url "${SITE_URL}" \
  --go-downloads-json "${TMP}/api/go-downloads.json" \
  --rotate-from "${FP}")"
record_rc rotate_retained_bad_signature_rejected "${rc}" 1 || true
rc=0
[[ ! -e "${TMP}/site-bad-sig-ret-out" ]] || rc=1
record_rc rotate_retained_bad_sig_no_output "${rc}" 0 || true

# 正确 rotate-from
(cd "${TMP}/site-go1" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"${TMP}/site-go1.before"
rc="$(capture_rc "${TMP}/run-rot-ok.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-go1" --output "${TMP}/site-go-rot" \
  --gnupghome "${GNUPG2}" --fingerprint "${FP2}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}" --release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json" \
  --rotate-from "${FP}")"
cat "${TMP}/run-rot-ok.log" >>"${EVIDENCE}"
record_rc rotate_from_success "${rc}" 0 || true
NEW_FP_EXPORT="$(gpg --batch --show-keys --with-colons -- "${TMP}/site-go-rot/apt-hub.gpg" | awk -F: '$1=="fpr"{print $10; exit}')"
rc=0
[[ "${NEW_FP_EXPORT}" == "${FP2}" ]] || rc=1
record_rc rotate_exports_new_pubkey "${rc}" 0 || true
gpg --homedir "${GNUPG2}" --batch --export -- "${FP2}" >"${TMP}/new-trusted.gpg"
rc=0
gpgv --keyring "${TMP}/new-trusted.gpg" \
  -- "${TMP}/site-go-rot/repos/golang/dists/jammy/InRelease" >/dev/null 2>&1 \
  || gpgv --keyring "${TMP}/new-trusted.gpg" \
       "${TMP}/site-go-rot/repos/golang/dists/jammy/Release.gpg" \
       "${TMP}/site-go-rot/repos/golang/dists/jammy/Release" >/dev/null 2>&1 \
  || rc=1
record_rc rotate_signed_by_new_key "${rc}" 0 || true
rc=0
cmp -s "${TMP}/site-go1.before" <(cd "${TMP}/site-go1" && find . -type f -print0 | sort -z | xargs -0 sha256sum) || rc=1
record_rc rotate_previous_unchanged "${rc}" 0 || true

# amd64-only 站点：紧测避开 ports.ubuntu.com 长超时
jq '(.packages[0].architectures |= del(.arm64))' "${TMP}/catalog-go.json" >"${TMP}/catalog-go-amd64.json"
rc="$(capture_rc "${TMP}/run-amd64-only.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go-amd64.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-go-amd64" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}" --release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json")"
record_rc go_amd64_only_sync "${rc}" 0 || true

# githubdeb：upstream-dir 是真实响应缓存，digest 仍核验
ALPHA_SHA="$(sha_of "${TMP}/debs/alpha_1.0.0_amd64.deb")"
ALPHA_SZ="$(stat -c '%s' -- "${TMP}/debs/alpha_1.0.0_amd64.deb")"
jq -n --arg digest "sha256:${ALPHA_SHA}" --argjson sz "${ALPHA_SZ}" '{
  tag_name:"v1.2.3",
  html_url:"https://github.com/fixture/alpha/releases/tag/v1.2.3",
  draft:false, prerelease:false,
  assets:[{
    name:"alpha_1.0.0_amd64.deb", size:$sz, digest:$digest,
    browser_download_url:"https://github.com/fixture/alpha/releases/download/v1.2.3/alpha_1.0.0_amd64.deb"
  }]
}' >"${TMP}/upstream/alpha.json"
jq -n '{
  schema_version:"2",
  packages:[{
    id:"alpha", repository:"fixture/alpha", package:"alpha",
    description:"alpha fixture", source_url:"https://github.com/fixture/alpha",
    license:"MIT", ubuntu_series:["jammy"],
    architectures:{amd64:"^alpha_1\\.0\\.0_amd64\\.deb$"}
  }]
}' >"${TMP}/catalog-alpha.json"
map_add "https://github.com/fixture/alpha/releases/download/v1.2.3/alpha_1.0.0_amd64.deb" "${TMP}/debs/alpha_1.0.0_amd64.deb"
rc="$(capture_rc "${TMP}/run-upstream.log" "${SYNC}" \
  --catalog "${TMP}/catalog-alpha.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-alpha" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}" \
  --upstream-dir "${TMP}/upstream")"
record_rc upstream_dir_githubdeb "${rc}" 0 || true
rc=0
jq -e '.packages[0].source_url=="https://github.com/fixture/alpha/tree/v1.2.3"
  and .packages[0].release_url=="https://github.com/fixture/alpha/releases/tag/v1.2.3"' \
  "${TMP}/site-alpha/state.json" >/dev/null || rc=1
record_rc upstream_dir_tag "${rc}" 0 || true
jq '.assets[0].digest="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"' \
  "${TMP}/upstream/alpha.json" >"${TMP}/upstream/alpha-bad.json"
mv -- "${TMP}/upstream/alpha-bad.json" "${TMP}/upstream/alpha.json"
rc="$(capture_rc "${TMP}/run-upstream-bad.log" "${SYNC}" \
  --catalog "${TMP}/catalog-alpha.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-alpha-bad" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}" \
  --upstream-dir "${TMP}/upstream")"
record_rc upstream_dir_bad_digest_rejected "${rc}" 1 || true

# --- HTTPS 夹具：真 APT download + upgrade（type:deb 不改写）---
command -v node >/dev/null 2>&1 || { log "缺少 node，无法跑 APT HTTPS fixture"; exit 1; }
openssl req -x509 -newkey rsa:2048 -noenc -days 2 -subj '/CN=apt-hub go-source fixture' \
  -addext 'subjectAltName=IP:127.0.0.2,DNS:github.com' \
  -keyout "${TMP}/tls/key.pem" -out "${TMP}/tls/cert.pem" >"${TMP}/tls/gen.log" 2>&1
chmod 600 -- "${TMP}/tls/key.pem"
: >"${TMP}/access.jsonl"
mkdir -p -- "${TMP}/site-empty-meta"
node "${FIXTURE_JS}" "${TMP}/site-empty-meta" "${TMP}/assets" \
  "${TMP}/tls/cert.pem" "${TMP}/tls/key.pem" "${TMP}/ready.json" "${TMP}/access.jsonl" \
  >"${TMP}/fixture-server.log" 2>&1 &
SERVER_PID=$!
ready=0
for _try in $(seq 1 40); do
  if [[ -f "${TMP}/ready.json" ]]; then ready=1; break; fi
  sleep 0.1
done
[[ "${ready}" -eq 1 ]] || { log "HTTPS fixture 未就绪"; cat "${TMP}/fixture-server.log" >>"${EVIDENCE}" || true; exit 1; }
PROXY_URL="$(jq -r .proxy_url "${TMP}/ready.json")"
log "https_fixture proxy=${PROXY_URL} pid=${SERVER_PID}"

# 基础 verify（无 download）
rm -rf -- "${TMP}/ver-basic"
rc="$(capture_rc "${TMP}/run-ver-basic.log" "${VER}" \
  --site "${TMP}/site-go-amd64" --releases "${TMP}/releases.json" --work-dir "${TMP}/ver-basic")"
record_rc verify_basic_mode "${rc}" 0 || true
if [[ "${rc}" -eq 0 ]]; then
  rc=0
  jq -e 'all(.results[]; .verify_downloads==false)' "${TMP}/ver-basic/summary.json" >/dev/null || rc=1
  record_rc verify_basic_flag_false "${rc}" 0 || true
  if find "${TMP}/ver-basic" -path '*/archives/*.deb' -print -quit | grep -q .; then
    record_rc verify_basic_no_archives_deb 1 0 || true
  else
    record_rc verify_basic_no_archives_deb 0 0 || true
  fi
fi

# 真 download + upgrade
rm -rf -- "${TMP}/ver-dl"
rc="$(capture_rc "${TMP}/run-ver-dl.log" "${VER}" \
  --site "${TMP}/site-go-amd64" --releases "${TMP}/releases.json" --work-dir "${TMP}/ver-dl" \
  --verify-downloads \
  --acquire-https-ca "${TMP}/tls/cert.pem" \
  --github-https-proxy "${PROXY_URL}")"
cat "${TMP}/run-ver-dl.log" >>"${EVIDENCE}"
record_rc verify_downloads_https "${rc}" 0 || true
if [[ "${rc}" -eq 0 ]]; then
  rc=0
  jq -e 'all(.results[]; .ok==true and .verify_downloads==true and .download_exit==0 and .upgrade_exit==0)' \
    "${TMP}/ver-dl/summary.json" >/dev/null || rc=1
  record_rc verify_downloads_summary "${rc}" 0 || true
  rc=0
  grep -Fq $'https://github.com/\ttype:deb' "${TMP}/site-go-amd64/repos/golang/mirror.list" || rc=1
  if grep -E $'file:.*\ttype:deb' "${TMP}/ver-dl/"*/*.mirror.list >/dev/null 2>&1; then rc=1; fi
  record_rc verify_keeps_type_deb_origin "${rc}" 0 || true
  rc=0
  arch_root="$(find "${TMP}/ver-dl" -type d -path '*/apt-root/var/cache/apt/archives' | head -1 || true)"
  [[ -n "${arch_root}" ]] || rc=1
  meta_hit="$(find -- "${arch_root}" -maxdepth 1 -type f -name 'golang_*.deb' -print -quit || true)"
  tool_hit="$(find -- "${arch_root}" -maxdepth 1 -type f -name 'golang-go_*.deb' -print -quit || true)"
  [[ -n "${meta_hit}" && -n "${tool_hit}" ]] || rc=1
  record_rc verify_archives_both_packages "${rc}" 0 || true
  rc=0
  grep -F 'Inst golang [2:1.22~2build1] (2:9.9.9-1' "${TMP}/ver-dl/"*/upgrade.log >/dev/null || rc=1
  grep -F 'Inst golang-go [2:1.22~2build1] (2:9.9.9-1' "${TMP}/ver-dl/"*/upgrade.log >/dev/null || rc=1
  ! grep -q '^Remv ' "${TMP}/ver-dl/"*/upgrade.log || rc=1
  record_rc verify_upgrade_both_no_remv "${rc}" 0 || true
  rc=0
  jq -e 'select(.role=="release-fixture" and .method=="GET" and .status==200)' "${TMP}/access.jsonl" >/dev/null || rc=1
  record_rc verify_release_fixture_get "${rc}" 0 || true
fi

# 资产 URL/Filename 篡改为与 Packages Filename 不同路径 → 拒
cp -a -- "${TMP}/site-go-amd64" "${TMP}/site-bad-url"
jq '
  .packages[0].assets |= map(
    .url = "https://github.com/fixture/apt-hub/releases/download/missing/nope.deb"
    | .filename = "fixture/apt-hub/releases/download/missing/nope.deb"
  )
' "${TMP}/site-bad-url/state.json" >"${TMP}/site-bad-url/state.json.tmp"
mv -- "${TMP}/site-bad-url/state.json.tmp" "${TMP}/site-bad-url/state.json"
rm -rf -- "${TMP}/ver-bad-url"
rc="$(capture_rc "${TMP}/run-ver-bad-url.log" "${VER}" \
  --site "${TMP}/site-bad-url" --releases "${TMP}/releases.json" \
  --work-dir "${TMP}/ver-bad-url" --verify-downloads \
  --acquire-https-ca "${TMP}/tls/cert.pem" \
  --github-https-proxy "${PROXY_URL}")"
record_rc verify_bad_url_rejected "${rc}" 1 || true
rc=0
jq -e '.ok!=true' "${TMP}/ver-bad-url/summary.json" >/dev/null 2>&1 || [[ ! -f "${TMP}/ver-bad-url/summary.json" ]] || rc=1
record_rc verify_bad_url_no_success "${rc}" 0 || true

# update 入口透传 acquire（amd64-only 同源链）
rm -rf -- "${TMP}/work-upd" "${TMP}/work-upd.lock"
mkdir -p -- "${TMP}/work-upd" "${TMP}/prev-upd"
rc="$(capture_rc "${TMP}/run-upd.log" "${UPD}" \
  --catalog "${TMP}/catalog-go-amd64.json" \
  --previous "${TMP}/prev-upd" \
  --work-dir "${TMP}/work-upd" \
  --gnupghome "${GNUPG}" \
  --fingerprint "${FP}" \
  --site-url "${SITE_URL}" \
  --releases "${TMP}/releases.json" \
  --package-repository "${PKG_REPO}" \
  --release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json" \
  --acquire-https-ca "${TMP}/tls/cert.pem" \
  --github-https-proxy "${PROXY_URL}")"
cat "${TMP}/run-upd.log" >>"${EVIDENCE}"
record_rc update_go_chain_https "${rc}" 0 || true
if [[ "${rc}" -eq 0 ]]; then
  rc=0
  jq -e '.ok==true' "${TMP}/work-upd/success.json" >/dev/null || rc=1
  record_rc update_success_json "${rc}" 0 || true
  rc=0
  jq -e 'all(.results[]; .ok==true and .verify_downloads==true)' \
    "${TMP}/work-upd/verify/summary.json" >/dev/null || rc=1
  record_rc update_verify_gate "${rc}" 0 || true
fi

# 未传 release-tag：由根 VERSION 派生，不向 go.dev 要本仓 tag
DERIVED_RAW="$(tr -d '[:space:]' <"${ROOT}/VERSION")"
case "${DERIVED_RAW}" in
  v[0-9]*.[0-9]*.[0-9]*) DERIVED="${DERIVED_RAW}" ;;
  *) DERIVED="v${DERIVED_RAW}" ;;
esac
saved_tag="${GO_TAG}"
GO_TAG="${DERIVED}"
write_provenance "${TMP}/api/provenance.json"
write_release_json "${TMP}/api/go-release-derived.json"
derived_rel="fixture/apt-hub/releases/download/${DERIVED}"
mkdir -p -- "${TMP}/assets/${derived_rel}"
cp -- "${TMP}/debs/golang_9.9.9-1_amd64.deb" "${TMP}/debs/golang-go_9.9.9-1_amd64.deb" \
  "${TMP}/assets/${derived_rel}/"
map_add "https://api.github.com/repos/${PKG_REPO}/releases/tags/${DERIVED}" "${TMP}/api/go-release-derived.json"
map_add "https://github.com/${PKG_REPO}/releases/download/${DERIVED}/golang_9.9.9-1_amd64.deb" "${TMP}/debs/golang_9.9.9-1_amd64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${DERIVED}/golang-go_9.9.9-1_amd64.deb" "${TMP}/debs/golang-go_9.9.9-1_amd64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${DERIVED}/${PROV_ASSET}" "${TMP}/api/provenance.json"
rm -rf -- "${TMP}/work-derived" "${TMP}/work-derived.lock"
mkdir -p -- "${TMP}/work-derived" "${TMP}/prev-derived"
rc="$(capture_rc "${TMP}/run-derived.log" "${UPD}" \
  --catalog "${TMP}/catalog-go-amd64.json" \
  --previous "${TMP}/prev-derived" \
  --work-dir "${TMP}/work-derived" \
  --gnupghome "${GNUPG}" \
  --fingerprint "${FP}" \
  --site-url "${SITE_URL}" \
  --releases "${TMP}/releases.json" \
  --package-repository "${PKG_REPO}" \
  --go-downloads-json "${TMP}/api/go-downloads.json" \
  --acquire-https-ca "${TMP}/tls/cert.pem" \
  --github-https-proxy "${PROXY_URL}")"
record_rc update_version_derived_tag "${rc}" 0 || true
rc=0
grep -Fq "由 VERSION 派生 release-tag=${DERIVED}" "${TMP}/run-derived.log" || rc=1
if grep -Fq 'go.dev/dl' "${TMP}/run-derived.log"; then rc=1; fi
record_rc update_version_derived_log "${rc}" 0 || true
if [[ -f "${TMP}/work-derived/site/state.json" ]]; then
  rc=0
  jq -e --arg t "${DERIVED}" '.packages[0].release_tag==$t' "${TMP}/work-derived/site/state.json" >/dev/null || rc=1
  record_rc update_version_derived_state "${rc}" 0 || true
fi
GO_TAG="${saved_tag}"

# 精确 pid 清理
if [[ -n "${SERVER_PID}" ]]; then
  kill "${SERVER_PID}" 2>/dev/null || true
  wait "${SERVER_PID}" 2>/dev/null || true
  SERVER_PID=""
fi

log "PASS=${PASS} FAIL=${FAIL}"
echo "pass=${PASS} fail=${FAIL} evidence=${EVIDENCE}"
sha256sum -- "${SYNC}" "${UPD}" "${VER}" "${ROOT}/config/packages.json" \
  "${ROOT}/tests/go_source_test.sh" "${FIXTURE_JS}" | tee -a "${EVIDENCE}"
if [[ "${FAIL}" -ne 0 ]]; then
  log "go_source_test 失败"
  exit 1
fi
log "go_source_test 通过"
exit 0
