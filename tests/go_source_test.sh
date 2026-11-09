#!/usr/bin/env bash
# Go exactRelease + provenance/上游双 hash + rotate-from + verify-downloads 长期链。
# 夹具 curl，非真实外网；工作目录独占 tmp/delivery-v16/core。
set -euo pipefail
export LC_ALL=C
export LANG=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="${ROOT}/scripts/sync.sh"
UPD="${ROOT}/scripts/update_sources.sh"
VER="${ROOT}/scripts/verify_ubuntu.sh"
TMP="${ROOT}/tmp/delivery-v16/core/go-source"
EVIDENCE="${TMP}/evidence.log"
SITE_URL='https://apt-hub.example.test'
PKG_REPO='fixture/apt-hub'
GO_TAG='apt-hub-go-9.9.9-1'
PASS=0
FAIL=0

mkdir -p -- "${ROOT}/tmp/delivery-v16/core"
rm -rf -- "${TMP}"
mkdir -p -- "${TMP}/bin" "${TMP}/debs" "${TMP}/api" "${TMP}/empty-prev"

{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "root=${ROOT}"
} >"${EVIDENCE}"

log() { printf '%s\n' "$*" | tee -a "${EVIDENCE}"; }
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
  local pkg="$1" ver="$2" arch="$3" dest="$4" extra="${5:-}"
  local root="${TMP}/debroot/${pkg}-${ver}-${arch}-${extra}"
  rm -rf -- "${root}"
  mkdir -p -- "${root}/DEBIAN" "${root}/usr/share/doc/${pkg}"
  cat >"${root}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${ver}
Architecture: ${arch}
Maintainer: apt-hub-go-source-test <invalid>
Depends: libc6
Description: go source fixture ${pkg}
EOF
  printf 'payload %s %s %s %s\n' "${pkg}" "${ver}" "${arch}" "${extra}" \
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

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -- "${SYNC}" "${UPD}" "${VER}" "${ROOT}/tests/go_source_test.sh" \
    >"${TMP}/shellcheck.out" 2>&1 || true
  # 生产脚本零告警；本测试文件允许 SC2317（经 capture_rc 间接调用）
  if ! grep -E 'scripts/(sync|update_sources|verify_ubuntu)\.sh' "${TMP}/shellcheck.out" >/dev/null 2>&1; then
    record_rc shellcheck_scripts_clean 0 0 || true
  else
    tee -a "${EVIDENCE}" <"${TMP}/shellcheck.out"
    record_rc shellcheck_scripts_clean 1 0 || true
  fi
else
  log "shellcheck unavailable in PATH; skip"
fi

# --- 小夹具 Go deb + provenance + 官方索引 ---
build_deb apt-hub-go 9.9.9-1 amd64 "${TMP}/debs/apt-hub-go_9.9.9-1_amd64.deb" ok
build_deb apt-hub-go 9.9.9-1 arm64 "${TMP}/debs/apt-hub-go_9.9.9-1_arm64.deb" ok
build_deb apt-hub-go 9.9.9-1 amd64 "${TMP}/debs/apt-hub-go_9.9.9-1_amd64-replaced.deb" replaced
AMD_SHA="$(sha_of "${TMP}/debs/apt-hub-go_9.9.9-1_amd64.deb")"
ARM_SHA="$(sha_of "${TMP}/debs/apt-hub-go_9.9.9-1_arm64.deb")"
AMD_SZ="$(stat -c '%s' -- "${TMP}/debs/apt-hub-go_9.9.9-1_amd64.deb")"
ARM_SZ="$(stat -c '%s' -- "${TMP}/debs/apt-hub-go_9.9.9-1_arm64.deb")"
# 假上游 tar 摘要（与 downloads 索引交叉）
UP_AMD_SHA="$(printf 'amd-upstream-tar-fixture' | sha256sum | awk '{print $1}')"
UP_ARM_SHA="$(printf 'arm-upstream-tar-fixture' | sha256sum | awk '{print $1}')"
UP_AMD_SZ=111
UP_ARM_SZ=222

write_provenance() {
  local dest="$1" amd_sha="$2" arm_sha="$3" up_amd="$4" up_arm="$5"
  local amd_sz="${6:-${AMD_SZ}}" arm_sz="${7:-${ARM_SZ}}"
  jq -n \
    --arg amd_sha "${amd_sha}" --arg arm_sha "${arm_sha}" \
    --argjson amd_sz "${amd_sz}" --argjson arm_sz "${arm_sz}" \
    --arg up_amd "${up_amd}" --arg up_arm "${up_arm}" \
    --argjson up_amd_sz "${UP_AMD_SZ}" --argjson up_arm_sz "${UP_ARM_SZ}" \
    '{
      schema_version:"1",
      generated_at_utc:"2026-11-09T00:00:00Z",
      upstream:{version:"go9.9.9",version_debian:"9.9.9",revision:"1"},
      packages:[
        {package:"apt-hub-go",version:"9.9.9-1",architecture:"amd64",
         filename:"apt-hub-go_9.9.9-1_amd64.deb",sha256:$amd_sha,size:($amd_sz|tostring),
         upstream:{url:"https://go.dev/dl/go9.9.9.linux-amd64.tar.gz",sha256:$up_amd,size:($up_amd_sz|tostring)}},
        {package:"apt-hub-go",version:"9.9.9-1",architecture:"arm64",
         filename:"apt-hub-go_9.9.9-1_arm64.deb",sha256:$arm_sha,size:($arm_sz|tostring),
         upstream:{url:"https://go.dev/dl/go9.9.9.linux-arm64.tar.gz",sha256:$up_arm,size:($up_arm_sz|tostring)}}
      ]
    }' >"${dest}"
}

write_provenance "${TMP}/api/provenance.json" "${AMD_SHA}" "${ARM_SHA}" "${UP_AMD_SHA}" "${UP_ARM_SHA}"
PROV_SHA="$(sha_of "${TMP}/api/provenance.json")"
PROV_SZ="$(stat -c '%s' -- "${TMP}/api/provenance.json")"

jq -n \
  --arg tag "${GO_TAG}" \
  --arg html "https://github.com/${PKG_REPO}/releases/tag/${GO_TAG}" \
  --arg n1 'apt-hub-go_9.9.9-1_amd64.deb' --arg n2 'apt-hub-go_9.9.9-1_arm64.deb' \
  --argjson s1 "${AMD_SZ}" --argjson s2 "${ARM_SZ}" --argjson sp "${PROV_SZ}" \
  --arg u1 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_amd64.deb" \
  --arg u2 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_arm64.deb" \
  --arg up "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/provenance.json" \
  --arg d1 "sha256:${AMD_SHA}" --arg d2 "sha256:${ARM_SHA}" --arg dp "sha256:${PROV_SHA}" \
  '{
    tag_name:$tag, html_url:$html, draft:false, prerelease:false,
    assets:[
      {name:$n1,size:$s1,browser_download_url:$u1,digest:$d1},
      {name:$n2,size:$s2,browser_download_url:$u2,digest:$d2},
      {name:"provenance.json",size:$sp,browser_download_url:$up,digest:$dp}
    ]
  }' >"${TMP}/api/go-release.json"

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

: >"${TMP}/curl-map.tsv"
map_add "https://api.github.com/repos/${PKG_REPO}/releases/tags/${GO_TAG}" "${TMP}/api/go-release.json"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_amd64.deb" "${TMP}/debs/apt-hub-go_9.9.9-1_amd64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_arm64.deb" "${TMP}/debs/apt-hub-go_9.9.9-1_arm64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/provenance.json" "${TMP}/api/provenance.json"

jq -n '{
  schema_version:1,
  source_url:"fixture",
  checked_at:"2026-11-09T00:00:00Z",
  releases:[{series:"jammy",version:"22.04",release_date:"2022-04-21",eol_date:"2027-06-01"}]
}' >"${TMP}/releases.json"

jq -n '{
  schema_version:"2",
  packages:[{
    id:"golang", package:"apt-hub-go", source_type:"go_official_archive",
    repository:"golang/go", description:"Go fixture",
    source_url:"https://go.dev", license:"BSD-3-Clause",
    ubuntu_series:["jammy"],
    architectures:{
      amd64:"^apt-hub-go_[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+_amd64\\.deb$",
      arm64:"^apt-hub-go_[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+_arm64\\.deb$"
    }
  }]
}' >"${TMP}/catalog-go.json"

jq '(.packages[0].architectures |= del(.arm64))' "${TMP}/catalog-go.json" >"${TMP}/catalog-go-amd64-only.json"

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
    --go-release-tag "${GO_TAG}" \
    --go-downloads-json "${TMP}/api/go-downloads.json" \
    "$@"
}

# 缺参数拒绝
rc="$(capture_rc "${TMP}/run-no-tag.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-no-tag" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}")"
record_rc go_missing_release_tag_rejected "${rc}" 1 || true
rc=0
grep -Fq 'go-release-tag' "${TMP}/run-no-tag.log" || rc=1
record_rc go_missing_tag_reason "${rc}" 0 || true

# 缺架构：release 去掉 arm64 deb（保留 provenance）
jq '(.assets |= map(select(.name != "apt-hub-go_9.9.9-1_arm64.deb")))' \
  "${TMP}/api/go-release.json" >"${TMP}/api/go-release-no-arm.json"
cp -f -- "${TMP}/api/go-release-no-arm.json" "${TMP}/api/go-release.json"
rc="$(capture_rc "${TMP}/run-no-arch.log" run_sync_go "${TMP}/empty-prev" "${TMP}/site-no-arch")"
record_rc go_missing_arch_rejected "${rc}" 1 || true
# 恢复完整 release
jq -n \
  --arg tag "${GO_TAG}" \
  --arg html "https://github.com/${PKG_REPO}/releases/tag/${GO_TAG}" \
  --arg n1 'apt-hub-go_9.9.9-1_amd64.deb' --arg n2 'apt-hub-go_9.9.9-1_arm64.deb' \
  --argjson s1 "${AMD_SZ}" --argjson s2 "${ARM_SZ}" --argjson sp "${PROV_SZ}" \
  --arg u1 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_amd64.deb" \
  --arg u2 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_arm64.deb" \
  --arg up "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/provenance.json" \
  --arg d1 "sha256:${AMD_SHA}" --arg d2 "sha256:${ARM_SHA}" --arg dp "sha256:${PROV_SHA}" \
  '{
    tag_name:$tag, html_url:$html, draft:false, prerelease:false,
    assets:[
      {name:$n1,size:$s1,browser_download_url:$u1,digest:$d1},
      {name:$n2,size:$s2,browser_download_url:$u2,digest:$d2},
      {name:"provenance.json",size:$sp,browser_download_url:$up,digest:$dp}
    ]
  }' >"${TMP}/api/go-release.json"

# manifest/provenance hash 不符（digest 错）
BAD_PROV_SHA="$(printf 'bad-prov' | sha256sum | awk '{print $1}')"
jq --arg d "sha256:${BAD_PROV_SHA}" \
  '(.assets |= map(if .name=="provenance.json" then .digest=$d else . end))' \
  "${TMP}/api/go-release.json" >"${TMP}/api/go-release-bad-prov.json"
cp -f -- "${TMP}/api/go-release-bad-prov.json" "${TMP}/api/go-release.json"
rc="$(capture_rc "${TMP}/run-bad-prov.log" run_sync_go "${TMP}/empty-prev" "${TMP}/site-bad-prov")"
record_rc go_manifest_hash_rejected "${rc}" 1 || true
# 恢复
jq --arg d "sha256:${PROV_SHA}" \
  '(.assets |= map(if .name=="provenance.json" then .digest=$d else . end))' \
  "${TMP}/api/go-release-bad-prov.json" >"${TMP}/api/go-release.json"
# 重写正确 digest 的完整 release（上面一行仍是坏 size 组合，直接重写）
PROV_SHA="$(sha_of "${TMP}/api/provenance.json")"
jq -n \
  --arg tag "${GO_TAG}" \
  --arg html "https://github.com/${PKG_REPO}/releases/tag/${GO_TAG}" \
  --arg n1 'apt-hub-go_9.9.9-1_amd64.deb' --arg n2 'apt-hub-go_9.9.9-1_arm64.deb' \
  --argjson s1 "${AMD_SZ}" --argjson s2 "${ARM_SZ}" --argjson sp "${PROV_SZ}" \
  --arg u1 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_amd64.deb" \
  --arg u2 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_arm64.deb" \
  --arg up "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/provenance.json" \
  --arg d1 "sha256:${AMD_SHA}" --arg d2 "sha256:${ARM_SHA}" --arg dp "sha256:${PROV_SHA}" \
  '{
    tag_name:$tag, html_url:$html, draft:false, prerelease:false,
    assets:[
      {name:$n1,size:$s1,browser_download_url:$u1,digest:$d1},
      {name:$n2,size:$s2,browser_download_url:$u2,digest:$d2},
      {name:"provenance.json",size:$sp,browser_download_url:$up,digest:$dp}
    ]
  }' >"${TMP}/api/go-release.json"

# 官方原 tar hash 不符
BAD_UP="$(printf 'bad-up' | sha256sum | awk '{print $1}')"
write_provenance "${TMP}/api/provenance-bad-up.json" "${AMD_SHA}" "${ARM_SHA}" "${BAD_UP}" "${UP_ARM_SHA}"
BAD_UP_PROV_SHA="$(sha_of "${TMP}/api/provenance-bad-up.json")"
BAD_UP_PROV_SZ="$(stat -c '%s' -- "${TMP}/api/provenance-bad-up.json")"
cp -f -- "${TMP}/api/provenance-bad-up.json" "${TMP}/api/provenance.json"
jq -n \
  --arg tag "${GO_TAG}" \
  --arg html "https://github.com/${PKG_REPO}/releases/tag/${GO_TAG}" \
  --arg n1 'apt-hub-go_9.9.9-1_amd64.deb' --arg n2 'apt-hub-go_9.9.9-1_arm64.deb' \
  --argjson s1 "${AMD_SZ}" --argjson s2 "${ARM_SZ}" --argjson sp "${BAD_UP_PROV_SZ}" \
  --arg u1 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_amd64.deb" \
  --arg u2 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_arm64.deb" \
  --arg up "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/provenance.json" \
  --arg d1 "sha256:${AMD_SHA}" --arg d2 "sha256:${ARM_SHA}" --arg dp "sha256:${BAD_UP_PROV_SHA}" \
  '{
    tag_name:$tag, html_url:$html, draft:false, prerelease:false,
    assets:[
      {name:$n1,size:$s1,browser_download_url:$u1,digest:$d1},
      {name:$n2,size:$s2,browser_download_url:$u2,digest:$d2},
      {name:"provenance.json",size:$sp,browser_download_url:$up,digest:$dp}
    ]
  }' >"${TMP}/api/go-release.json"
rc="$(capture_rc "${TMP}/run-bad-up.log" run_sync_go "${TMP}/empty-prev" "${TMP}/site-bad-up")"
record_rc go_upstream_tar_hash_rejected "${rc}" 1 || true
rc=0
grep -Fq '官方原 tar' "${TMP}/run-bad-up.log" || grep -Fqi 'go.dev' "${TMP}/run-bad-up.log" || rc=1
record_rc go_upstream_reason "${rc}" 0 || true

# 恢复正确 provenance/release
write_provenance "${TMP}/api/provenance.json" "${AMD_SHA}" "${ARM_SHA}" "${UP_AMD_SHA}" "${UP_ARM_SHA}"
PROV_SHA="$(sha_of "${TMP}/api/provenance.json")"
PROV_SZ="$(stat -c '%s' -- "${TMP}/api/provenance.json")"
jq -n \
  --arg tag "${GO_TAG}" \
  --arg html "https://github.com/${PKG_REPO}/releases/tag/${GO_TAG}" \
  --arg n1 'apt-hub-go_9.9.9-1_amd64.deb' --arg n2 'apt-hub-go_9.9.9-1_arm64.deb' \
  --argjson s1 "${AMD_SZ}" --argjson s2 "${ARM_SZ}" --argjson sp "${PROV_SZ}" \
  --arg u1 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_amd64.deb" \
  --arg u2 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_arm64.deb" \
  --arg up "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/provenance.json" \
  --arg d1 "sha256:${AMD_SHA}" --arg d2 "sha256:${ARM_SHA}" --arg dp "sha256:${PROV_SHA}" \
  '{
    tag_name:$tag, html_url:$html, draft:false, prerelease:false,
    assets:[
      {name:$n1,size:$s1,browser_download_url:$u1,digest:$d1},
      {name:$n2,size:$s2,browser_download_url:$u2,digest:$d2},
      {name:"provenance.json",size:$sp,browser_download_url:$up,digest:$dp}
    ]
  }' >"${TMP}/api/go-release.json"

# GREEN：首次 sync
rc="$(capture_rc "${TMP}/run-ok.log" run_sync_go "${TMP}/empty-prev" "${TMP}/site-go1")"
cat "${TMP}/run-ok.log" >>"${EVIDENCE}"
record_rc go_first_sync "${rc}" 0 || true
rc=0
jq -e '
  .schema_version=="2"
  and (.packages|length==1)
  and .packages[0].id=="golang"
  and .packages[0].source_type=="go_official_archive"
  and .packages[0].source_url=="https://go.dev"
  and .packages[0].package_repository=="fixture/apt-hub"
  and .packages[0].release_tag=="apt-hub-go-9.9.9-1"
  and .packages[0].version=="9.9.9-1"
  and (.packages[0].assets|length==2)
  and all(.packages[0].assets[]; (.upstream.sha256|type)=="string")
' "${TMP}/site-go1/state.json" >/dev/null || rc=$?
record_rc go_state_fields "${rc}" 0 || true
rc=0
if find -- "${TMP}/site-go1" -type f -name '*.deb' -print -quit | grep -q .; then rc=1; fi
record_rc go_metadata_no_deb "${rc}" 0 || true

# 同版本内容替换拒绝
REPL_SHA="$(sha_of "${TMP}/debs/apt-hub-go_9.9.9-1_amd64-replaced.deb")"
REPL_SZ="$(stat -c '%s' -- "${TMP}/debs/apt-hub-go_9.9.9-1_amd64-replaced.deb")"
write_provenance "${TMP}/api/provenance-repl.json" "${REPL_SHA}" "${ARM_SHA}" "${UP_AMD_SHA}" "${UP_ARM_SHA}" "${REPL_SZ}" "${ARM_SZ}"
: >"${TMP}/curl-map.tsv"
map_add "https://api.github.com/repos/${PKG_REPO}/releases/tags/${GO_TAG}" "${TMP}/api/go-release-repl.json"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_amd64.deb" "${TMP}/debs/apt-hub-go_9.9.9-1_amd64-replaced.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_arm64.deb" "${TMP}/debs/apt-hub-go_9.9.9-1_arm64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/provenance.json" "${TMP}/api/provenance-repl.json"
REPL_PROV_SHA="$(sha_of "${TMP}/api/provenance-repl.json")"
REPL_PROV_SZ="$(stat -c '%s' -- "${TMP}/api/provenance-repl.json")"
jq -n \
  --arg tag "${GO_TAG}" \
  --arg html "https://github.com/${PKG_REPO}/releases/tag/${GO_TAG}" \
  --arg n1 'apt-hub-go_9.9.9-1_amd64.deb' --arg n2 'apt-hub-go_9.9.9-1_arm64.deb' \
  --argjson s1 "${REPL_SZ}" --argjson s2 "${ARM_SZ}" --argjson sp "${REPL_PROV_SZ}" \
  --arg u1 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_amd64.deb" \
  --arg u2 "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_arm64.deb" \
  --arg up "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/provenance.json" \
  --arg d1 "sha256:${REPL_SHA}" --arg d2 "sha256:${ARM_SHA}" --arg dp "sha256:${REPL_PROV_SHA}" \
  '{
    tag_name:$tag, html_url:$html, draft:false, prerelease:false,
    assets:[
      {name:$n1,size:$s1,browser_download_url:$u1,digest:$d1},
      {name:$n2,size:$s2,browser_download_url:$u2,digest:$d2},
      {name:"provenance.json",size:$sp,browser_download_url:$up,digest:$dp}
    ]
  }' >"${TMP}/api/go-release-repl.json"
rc="$(capture_rc "${TMP}/run-repl.log" run_sync_go "${TMP}/site-go1" "${TMP}/site-go-repl")"
record_rc go_same_version_replace_rejected "${rc}" 1 || true
rc=0
grep -Fq '同名版本内容替换' "${TMP}/run-repl.log" || rc=1
record_rc go_replace_reason "${rc}" 0 || true

# 恢复 map 与 release；retained 续签（空 catalog + previous=site-go1）
: >"${TMP}/curl-map.tsv"
map_add "https://api.github.com/repos/${PKG_REPO}/releases/tags/${GO_TAG}" "${TMP}/api/go-release.json"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_amd64.deb" "${TMP}/debs/apt-hub-go_9.9.9-1_amd64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/apt-hub-go_9.9.9-1_arm64.deb" "${TMP}/debs/apt-hub-go_9.9.9-1_arm64.deb"
map_add "https://github.com/${PKG_REPO}/releases/download/${GO_TAG}/provenance.json" "${TMP}/api/provenance.json"
printf '%s\n' '{"schema_version":"2","packages":[]}' >"${TMP}/catalog-empty.json"
UPDATED1="$(jq -r '.packages[0].updated_at' "${TMP}/site-go1/state.json")"
rc="$(capture_rc "${TMP}/run-retain.log" "${SYNC}" \
  --catalog "${TMP}/catalog-empty.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-go1" --output "${TMP}/site-go-retain" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
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
  --package-repository "${PKG_REPO}" --go-release-tag "${GO_TAG}" \
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
  --package-repository "${PKG_REPO}" --go-release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json" \
  --rotate-from AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)"
record_rc rotate_wrong_fp_rejected "${rc}" 1 || true

# 坏旧签名：篡改 Packages 但保留 apt-hub.gpg
cp -a -- "${TMP}/site-go1" "${TMP}/site-bad-sig"
printf 'tampered\n' >>"${TMP}/site-bad-sig/repos/golang/dists/jammy/main/binary-amd64/Packages"
rc="$(capture_rc "${TMP}/run-bad-sig.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-bad-sig" --output "${TMP}/site-bad-sig-out" \
  --gnupghome "${GNUPG2}" --fingerprint "${FP2}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}" --go-release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json" \
  --rotate-from "${FP}")"
record_rc rotate_bad_signature_rejected "${rc}" 1 || true
rc=0
[[ ! -e "${TMP}/site-bad-sig-out" ]] || rc=1
record_rc rotate_bad_sig_no_output "${rc}" 0 || true

# 正确 rotate-from：旧公钥认证 + 新钥签名
(cd "${TMP}/site-go1" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"${TMP}/site-go1.before"
rc="$(capture_rc "${TMP}/run-rot-ok.log" "${SYNC}" \
  --catalog "${TMP}/catalog-go.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-go1" --output "${TMP}/site-go-rot" \
  --gnupghome "${GNUPG2}" --fingerprint "${FP2}" --site-url "${SITE_URL}" \
  --package-repository "${PKG_REPO}" --go-release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json" \
  --rotate-from "${FP}")"
cat "${TMP}/run-rot-ok.log" >>"${EVIDENCE}"
record_rc rotate_from_success "${rc}" 0 || true
NEW_FP_EXPORT="$(gpg --batch --show-keys --with-colons -- "${TMP}/site-go-rot/apt-hub.gpg" | awk -F: '$1=="fpr"{print $10; exit}')"
rc=0
[[ "${NEW_FP_EXPORT}" == "${FP2}" ]] || rc=1
record_rc rotate_exports_new_pubkey "${rc}" 0 || true
# 新 InRelease 必须由新钥验过
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

# --- 同源 update → verify-downloads 真实下载 + upgrade 模拟 ---
rm -rf -- "${TMP}/work-upd" "${TMP}/work-upd.lock"
mkdir -p -- "${TMP}/work-upd" "${TMP}/prev-upd"
rc="$(capture_rc "${TMP}/run-upd.log" "${UPD}" \
  --catalog "${TMP}/catalog-go.json" \
  --previous "${TMP}/prev-upd" \
  --work-dir "${TMP}/work-upd" \
  --gnupghome "${GNUPG}" \
  --fingerprint "${FP}" \
  --site-url "${SITE_URL}" \
  --releases "${TMP}/releases.json" \
  --package-repository "${PKG_REPO}" \
  --go-release-tag "${GO_TAG}" \
  --go-downloads-json "${TMP}/api/go-downloads.json")"
cat "${TMP}/run-upd.log" >>"${EVIDENCE}"
record_rc update_go_chain "${rc}" 0 || true
if [[ "${rc}" -eq 0 ]]; then
  rc=0
  jq -e '.ok==true' "${TMP}/work-upd/success.json" >/dev/null || rc=1
  record_rc update_success_json "${rc}" 0 || true
  rc=0
  jq -e 'all(.results[]; .ok==true and .verify_downloads==true and .download_exit==0 and .upgrade_exit==0)' \
    "${TMP}/work-upd/verify/summary.json" >/dev/null || rc=1
  record_rc update_verify_downloads_gate "${rc}" 0 || true
  # archives 内真实普通文件（非日志冒充）
  rc=0
  arch_root="$(find "${TMP}/work-upd/verify" -type d -path '*/apt-root/var/cache/apt/archives' | head -1 || true)"
  [[ -n "${arch_root}" ]] || rc=1
  deb_hit=""
  if [[ -n "${arch_root}" ]]; then
    deb_hit="$(find -- "${arch_root}" -maxdepth 1 -type f -name 'apt-hub-go_*.deb' -print -quit || true)"
  fi
  [[ -n "${deb_hit}" && -f "${deb_hit}" && ! -L "${deb_hit}" ]] || rc=1
  if [[ -n "${deb_hit}" ]]; then
    got="$(sha_of "${deb_hit}")"
    [[ "${got}" == "${AMD_SHA}" || "${got}" == "${ARM_SHA}" ]] || rc=1
  fi
  record_rc update_archives_real_deb "${rc}" 0 || true
  rc=0
  grep -Eq '^Inst ' "${TMP}/work-upd/verify/"*"/upgrade.log" || rc=1
  record_rc update_upgrade_sim_inst "${rc}" 0 || true
fi

# 基础模式：无 --verify-downloads 时不下包（显式保留）
rm -rf -- "${TMP}/ver-basic"
rc="$(capture_rc "${TMP}/run-ver-basic.log" "${VER}" \
  --site "${TMP}/site-go1" --releases "${TMP}/releases.json" --work-dir "${TMP}/ver-basic")"
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

# 坏 URL 下载门禁
cp -a -- "${TMP}/site-go1" "${TMP}/site-bad-url"
jq '(.packages[0].assets |= map(.url="https://github.com/fixture/apt-hub/releases/download/missing/nope.deb"))' \
  "${TMP}/site-bad-url/state.json" >"${TMP}/site-bad-url/state.json.tmp"
mv -- "${TMP}/site-bad-url/state.json.tmp" "${TMP}/site-bad-url/state.json"
rm -rf -- "${TMP}/ver-bad-url"
rc="$(capture_rc "${TMP}/run-ver-bad-url.log" "${VER}" \
  --site "${TMP}/site-bad-url" --releases "${TMP}/releases.json" \
  --work-dir "${TMP}/ver-bad-url" --verify-downloads)"
record_rc verify_bad_url_rejected "${rc}" 1 || true

gpgconf --homedir "${GNUPG}" --kill gpg-agent >/dev/null 2>&1 || true
gpgconf --homedir "${GNUPG2}" --kill gpg-agent >/dev/null 2>&1 || true

log "PASS=${PASS} FAIL=${FAIL}"
echo "pass=${PASS} fail=${FAIL} evidence=${EVIDENCE}"
if [[ "${FAIL}" -ne 0 ]]; then
  log "go_source_test 失败"
  exit 1
fi
log "go_source_test 通过"
exit 0
