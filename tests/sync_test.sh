#!/usr/bin/env bash
# tests/sync_test.sh — 本地夹具测试 sync.sh（元数据适配，非 deb 镜像）。
# curl shim 为夹具，不是真实网络证据。
set -euo pipefail
export LC_ALL=C
export LANG=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="${ROOT}/scripts/sync.sh"
CATALOG_PROD="${ROOT}/config/packages.json"
TMP="${ROOT}/tmp/metadata-A"
EVIDENCE="${TMP}/evidence.log"
SENTINEL="${TMP}/MAINTAINER_RAN"
SITE_URL='https://apt-hub.example.test'
PASS=0
FAIL=0

mkdir -p -- "${ROOT}/tmp"
rm -rf -- "${TMP}"
mkdir -p -- "${TMP}/bin" "${TMP}/debs" "${TMP}/api" "${TMP}/empty-prev"

{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "root=${ROOT}"
  echo "shellcheck=unavailable"
} >"${EVIDENCE}"

log() {
  printf '%s\n' "$*" | tee -a "${EVIDENCE}"
}

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

assert_file() {
  local f="$1"
  [[ -f "${f}" ]] || { log "缺少文件 ${f}"; return 1; }
}

assert_no_file() {
  local f="$1"
  [[ ! -e "${f}" ]] || { log "不应存在 ${f}"; return 1; }
}

assert_no_deb_under() {
  local d="$1"
  if find -- "${d}" -type f -name '*.deb' -print -quit | grep -q .; then
    log "不应含 deb: ${d}"
    return 1
  fi
}

dir_manifest() {
  local d="$1"
  (cd -- "${d}" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum)
}

build_deb() {
  local pkg="$1" ver="$2" arch="$3" dest="$4" extra="${5:-}"
  local root="${TMP}/debroot/${pkg}-${ver}-${arch}"
  rm -rf -- "${root}"
  mkdir -p -- "${root}/DEBIAN" "${root}/usr/share/doc/${pkg}"
  cat >"${root}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${ver}
Architecture: ${arch}
Maintainer: apt-hub-test <apt-hub-test@invalid>
Description: test package ${pkg}
EOF
  cat >"${root}/DEBIAN/postinst" <<EOF
#!/bin/sh
echo MAINTAINER_SCRIPT_RAN >> '${SENTINEL}'
exit 1
EOF
  chmod 755 -- "${root}/DEBIAN/postinst"
  printf 'payload %s %s %s %s\n' "${pkg}" "${ver}" "${arch}" "${extra}" >"${root}/usr/share/doc/${pkg}/README"
  dpkg-deb --build --root-owner-group -- "${root}" "${dest}" >/dev/null
}

write_release_json() {
  local pkg="$1" ver="$2" out="$3"
  local amd="${TMP}/debs/${pkg}-${ver}-x86_64.deb"
  local arm="${TMP}/debs/${pkg}-${ver}-aarch64.deb"
  local amd_size amd_sha arm_size arm_sha
  amd_size="$(stat -c '%s' -- "${amd}")"
  arm_size="$(stat -c '%s' -- "${arm}")"
  amd_sha="$(sha256sum -- "${amd}" | awk '{print $1}')"
  arm_sha="$(sha256sum -- "${arm}" | awk '{print $1}')"
  jq -n \
    --arg tag "${ver}" \
    --arg html "https://github.com/fixture/${pkg}/releases/tag/${ver}" \
    --arg n1 "${pkg}-${ver}-x86_64.deb" \
    --arg n2 "${pkg}-${ver}-aarch64.deb" \
    --argjson s1 "${amd_size}" \
    --argjson s2 "${arm_size}" \
    --arg u1 "https://github.com/fixture/${pkg}/releases/download/${ver}/${pkg}-${ver}-x86_64.deb" \
    --arg u2 "https://github.com/fixture/${pkg}/releases/download/${ver}/${pkg}-${ver}-aarch64.deb" \
    --arg d1 "sha256:${amd_sha}" \
    --arg d2 "sha256:${arm_sha}" \
    '{
      tag_name:$tag, html_url:$html, draft:false, prerelease:false,
      assets:[
        {name:$n1,size:$s1,browser_download_url:$u1,digest:$d1},
        {name:$n2,size:$s2,browser_download_url:$u2,digest:$d2}
      ]
    }' >"${out}"
}

map_add() {
  printf '%s\t%s\n' "$1" "$2" >>"${TMP}/curl-map.tsv"
}

refresh_maps() {
  : >"${TMP}/curl-map.tsv"
  map_add "https://api.github.com/repos/fixture/alpha/releases/latest" "${TMP}/api/alpha.json"
  map_add "https://api.github.com/repos/fixture/beta/releases/latest" "${TMP}/api/beta.json"
  local pkg ver
  for pkg in alpha beta; do
    for ver in 1.0.0 2.0.0; do
      map_add "https://github.com/fixture/${pkg}/releases/download/${ver}/${pkg}-${ver}-x86_64.deb" "${TMP}/debs/${pkg}-${ver}-x86_64.deb"
      map_add "https://github.com/fixture/${pkg}/releases/download/${ver}/${pkg}-${ver}-aarch64.deb" "${TMP}/debs/${pkg}-${ver}-aarch64.deb"
    done
  done
}

cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
# 测试夹具 curl：只返回 CURL_FIXTURE_MAP 中的本地文件，不是真实网络证据。
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
if [[ -z "${url}" ]]; then
  printf 'fixture-curl: missing url\n' >&2
  exit 1
fi
if [[ "${url}" != https://* ]]; then
  printf 'fixture-curl: URL 必须是 https: %s\n' "${url}" >&2
  exit 1
fi
map="${CURL_FIXTURE_MAP:?fixture-curl: CURL_FIXTURE_MAP 未设置}"
file="$(awk -F '\t' -v u="${url}" '$1==u {print $2; exit}' "${map}")"
if [[ -z "${file}" || ! -f "${file}" ]]; then
  printf 'fixture-curl: 无夹具映射 %s\n' "${url}" >&2
  exit 1
fi
count_file="${CURL_DOWNLOAD_COUNT_FILE:-}"
if [[ -n "${count_file}" && "${url}" == *'/releases/download/'* ]]; then
  printf '%s\n' "${url}" >>"${count_file}"
fi
if [[ -n "${out}" ]]; then
  cp -- "${file}" "${out}"
else
  cat -- "${file}"
fi
EOF
chmod 755 -- "${TMP}/bin/curl" "${SYNC}"

REAL_APT_FTPARCHIVE="$(command -v apt-ftparchive)"
export PATH="${TMP}/bin:${PATH}"
export CURL_FIXTURE_MAP="${TMP}/curl-map.tsv"
export CURL_DOWNLOAD_COUNT_FILE="${TMP}/deb-downloads.log"
: >"${CURL_DOWNLOAD_COUNT_FILE}"

log "CASE syntax: bash -n"
bash -n -- "${SYNC}"
record_rc syntax_sync "$?" 0
bash -n -- "${ROOT}/tests/sync_test.sh"
record_rc syntax_test "$?" 0

log "CASE prod_catalog_schema"
jq -e '.schema_version=="2" and (.packages|length)>=1 and .packages[0].id=="rustdesk"' "${CATALOG_PROD}" >/dev/null
record_rc prod_catalog_schema "$?" 0

GNUPG="${TMP}/gnupg"
mkdir -m 700 -- "${GNUPG}"
printf 'allow-loopback-pinentry\n' >"${GNUPG}/gpg-agent.conf"
gpg --homedir "${GNUPG}" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "apt-hub test key <apt-hub-test@invalid>" ed25519 sign never
FP="$(gpg --homedir "${GNUPG}" --batch --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')"
log "test_fingerprint=${FP}"
[[ "${#FP}" -eq 40 ]]

for pkg in alpha beta; do
  for ver in 1.0.0 2.0.0; do
    build_deb "${pkg}" "${ver}" amd64 "${TMP}/debs/${pkg}-${ver}-x86_64.deb" v"${ver}"
    build_deb "${pkg}" "${ver}" arm64 "${TMP}/debs/${pkg}-${ver}-aarch64.deb" v"${ver}"
  done
done
build_deb alpha 1.0.0 amd64 "${TMP}/debs/alpha-1.0.0-x86_64-replaced.deb" replaced
build_deb alpha 1.0.0 arm64 "${TMP}/debs/alpha-1.0.0-aarch64-replaced.deb" replaced

write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"
write_release_json beta 1.0.0 "${TMP}/api/beta.json"
refresh_maps

jq -n '{
  schema_version:1,
  source_url:"https://salsa.debian.org/debian/distro-info-data/-/raw/main/ubuntu.csv",
  checked_at:"2026-11-02T00:00:00Z",
  releases:[
    {series:"jammy",version:"22.04",release_date:"2022-04-21",eol_date:"2027-06-01"},
    {series:"noble",version:"24.04",release_date:"2024-04-25",eol_date:"2029-05-31"}
  ]
}' >"${TMP}/releases.json"

jq -n '{
  schema_version:"2",
  packages:[
    {
      id:"alpha", repository:"fixture/alpha", package:"alpha",
      description:"测试软件 alpha", source_url:"https://github.com/fixture/alpha",
      license:"MIT", ubuntu_series:"supported",
      architectures:{
        amd64:"^alpha-[0-9][^-]*-x86_64\\.deb$",
        arm64:"^alpha-[0-9][^-]*-aarch64\\.deb$"
      }
    },
    {
      id:"beta", repository:"fixture/beta", package:"beta",
      description:"测试软件 beta", source_url:"https://github.com/fixture/beta",
      license:"MIT", ubuntu_series:["jammy"],
      architectures:{
        amd64:"^beta-[0-9][^-]*-x86_64\\.deb$",
        arm64:"^beta-[0-9][^-]*-aarch64\\.deb$"
      }
    }
  ]
}' >"${TMP}/catalog.json"

# shellcheck disable=SC2317 # 经 capture_rc "$@" 间接调用
run_sync() {
  local prev="$1" out="$2"
  "${SYNC}" \
    --catalog "${TMP}/catalog.json" \
    --releases "${TMP}/releases.json" \
    --previous "${prev}" \
    --output "${out}" \
    --gnupghome "${GNUPG}" \
    --fingerprint "${FP}" \
    --site-url "${SITE_URL}"
}

capture_rc() {
  local logf="$1" rc=0
  shift
  "$@" >"${logf}" 2>&1 || rc=$?
  printf '%s\n' "${rc}"
}

# 缺少 --site-url
rc="$(capture_rc "${TMP}/run-nosite.log" "${SYNC}" \
  --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-nosite" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}")"
cat "${TMP}/run-nosite.log" >>"${EVIDENCE}"
record_rc missing_site_url_rejected "${rc}" 2

# localhost 拒绝
rc="$(capture_rc "${TMP}/run-localhost.log" "${SYNC}" \
  --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-localhost" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" \
  --site-url 'https://localhost/apt-hub')"
cat "${TMP}/run-localhost.log" >>"${EVIDENCE}"
record_rc localhost_site_url_rejected "${rc}" 1

rm -f -- "${SENTINEL}"
: >"${CURL_DOWNLOAD_COUNT_FILE}"
rc="$(capture_rc "${TMP}/run1.log" run_sync "${TMP}/empty-prev" "${TMP}/site1")"
cat "${TMP}/run1.log" >>"${EVIDENCE}"
record_rc first_sync "${rc}" 0

assert_file "${TMP}/site1/state.json"
assert_file "${TMP}/site1/apt-hub.gpg"
assert_no_file "${SENTINEL}"
record_rc maintainer_script_not_run "$?" 0
assert_no_deb_under "${TMP}/site1"
record_rc metadata_no_deb "$?" 0
assert_no_file "${TMP}/site1/pool"
record_rc no_pool_dir "$?" 0

jq -e '.schema_version=="2" and (.packages|length==2)' "${TMP}/site1/state.json" >/dev/null
test "$(jq -r '.packages[]|select(.id=="alpha")|.version' "${TMP}/site1/state.json")" = "1.0.0"
test "$(jq -r '.packages[]|select(.id=="beta")|.ubuntu_series|join(",")' "${TMP}/site1/state.json")" = "jammy"
test "$(jq -r '.packages[]|select(.id=="alpha")|.ubuntu_series|join(",")' "${TMP}/site1/state.json")" = "jammy,noble"
test "$(jq -r '.packages[]|select(.id=="alpha")|.architectures|join(",")' "${TMP}/site1/state.json")" = "amd64,arm64"
test "$(jq -r '.packages[]|select(.id=="alpha")|.release_url' "${TMP}/site1/state.json")" = "https://github.com/fixture/alpha/releases/tag/1.0.0"
test "$(jq -r '.packages[]|select(.id=="alpha")|.source_url' "${TMP}/site1/state.json")" = "https://github.com/fixture/alpha/tree/1.0.0"
test "$(jq -r '.packages[]|select(.id=="alpha")|.apt_source_uri' "${TMP}/site1/state.json")" = "mirror+https://apt-hub.example.test/repos/alpha/mirror.list"
test "$(jq -r '.packages[]|select(.id=="alpha")|.assets[0].size|type' "${TMP}/site1/state.json")" = "string"
test "$(jq -r '.packages[]|select(.id=="alpha")|.assets[]|select(.architecture=="amd64")|.filename' "${TMP}/site1/state.json")" = "fixture/alpha/releases/download/1.0.0/alpha-1.0.0-x86_64.deb"
UPDATED1="$(jq -r '.packages[]|select(.id=="alpha")|.updated_at' "${TMP}/site1/state.json")"
rc=0
[[ "${UPDATED1}" =~ Z$ ]] || rc=1
record_rc state_schema2_fields "${rc}" 0

assert_file "${TMP}/site1/repos/alpha/mirror.list"
assert_file "${TMP}/site1/repos/beta/mirror.list"
assert_file "${TMP}/site1/repos/alpha/jammy.sources"
assert_file "${TMP}/site1/repos/alpha/noble.sources"
assert_file "${TMP}/site1/repos/beta/jammy.sources"
assert_no_file "${TMP}/site1/repos/beta/noble.sources"
grep -P $'^https://apt-hub\\.example\\.test/repos/alpha/\ttype:index$' "${TMP}/site1/repos/alpha/mirror.list"
grep -P $'^https://github\\.com/\ttype:deb$' "${TMP}/site1/repos/alpha/mirror.list"
if grep -vE '^(#|$)' "${TMP}/site1/repos/alpha/mirror.list" | grep -v $'\ttype:' | grep -q .; then
  log "FAIL mirror.list 含未标 type 的通用 fallback"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
  log "CASE mirror_list_typed_only: exit=0 expect=0"
fi
grep -q '^URIs: mirror+https://apt-hub.example.test/repos/alpha/mirror.list$' "${TMP}/site1/repos/alpha/jammy.sources"
grep -q '^Signed-By: /etc/apt/keyrings/apt-hub.gpg$' "${TMP}/site1/repos/alpha/jammy.sources"
grep -q '^Architectures: amd64 arm64$' "${TMP}/site1/repos/alpha/jammy.sources"
record_rc repo_layout_sources "$?" 0

assert_file "${TMP}/site1/repos/jammy.sources"
assert_file "${TMP}/site1/repos/noble.sources"
alpha_bytes="$(wc -c <"${TMP}/site1/repos/alpha/jammy.sources" | tr -d ' ')"
rc=0
head -c "${alpha_bytes}" -- "${TMP}/site1/repos/jammy.sources" | cmp -s -- "${TMP}/site1/repos/alpha/jammy.sources" - || rc=1
test "$(awk -F/ '/^URIs: /{print $(NF-1)}' "${TMP}/site1/repos/jammy.sources" | paste -sd, -)" = "alpha,beta" || rc=1
test "$(awk -F/ '/^URIs: /{print $(NF-1)}' "${TMP}/site1/repos/noble.sources" | paste -sd, -)" = "alpha" || rc=1
record_rc aggregate_series_sources "${rc}" 0

grep -q '^Package: alpha$' "${TMP}/site1/repos/alpha/dists/jammy/main/binary-amd64/Packages"
grep -q '^Package: alpha$' "${TMP}/site1/repos/alpha/dists/noble/main/binary-amd64/Packages"
grep -q '^Package: beta$' "${TMP}/site1/repos/beta/dists/jammy/main/binary-amd64/Packages"
assert_no_file "${TMP}/site1/repos/beta/dists/noble"
grep -q '^Filename: fixture/alpha/releases/download/1.0.0/alpha-1.0.0-x86_64.deb$' \
  "${TMP}/site1/repos/alpha/dists/jammy/main/binary-amd64/Packages"
if grep -q '^Package: beta$' "${TMP}/site1/repos/alpha/dists/jammy/main/binary-amd64/Packages"; then
  log "FAIL alpha repo 不应混入 beta"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
  log "CASE repo_isolation: exit=0 expect=0"
fi
grep -q '^SHA256:' "${TMP}/site1/repos/alpha/dists/jammy/Release"
if grep -E '[[:space:]]Release$' "${TMP}/site1/repos/alpha/dists/jammy/Release" >/dev/null; then
  log "FAIL Release 含对自身的摘要"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
  log "CASE release_no_self_hash: exit=0 expect=0"
fi
if grep -E '^(MD5Sum|SHA1|SHA512):' "${TMP}/site1/repos/alpha/dists/jammy/Release" >/dev/null; then
  log "FAIL Release 含非 SHA256"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
  log "CASE release_sha256_only: exit=0 expect=0"
fi
grep -q '^Acquire-By-Hash: yes$' "${TMP}/site1/repos/alpha/dists/jammy/Release"
grep -q '^Valid-Until:' "${TMP}/site1/repos/alpha/dists/jammy/Release"
DATE_R="$(awk -F': ' '/^Date:/{print $2}' "${TMP}/site1/repos/alpha/dists/jammy/Release")"
VU_R="$(awk -F': ' '/^Valid-Until:/{print $2}' "${TMP}/site1/repos/alpha/dists/jammy/Release")"
DS="$(date -u -d "${DATE_R}" +%s)"
VS="$(date -u -d "${VU_R}" +%s)"
rc=0
test "$((VS - DS))" -eq 1209600 || rc=1
record_rc valid_until_14d "${rc}" 0

HASH_P="$(sha256sum -- "${TMP}/site1/repos/alpha/dists/jammy/main/binary-amd64/Packages" | awk '{print $1}')"
HASH_Z="$(sha256sum -- "${TMP}/site1/repos/alpha/dists/jammy/main/binary-amd64/Packages.gz" | awk '{print $1}')"
assert_file "${TMP}/site1/repos/alpha/dists/jammy/main/binary-amd64/by-hash/SHA256/${HASH_P}"
assert_file "${TMP}/site1/repos/alpha/dists/jammy/main/binary-amd64/by-hash/SHA256/${HASH_Z}"
printf '%s\n' "${HASH_P}" >"${TMP}/site1-alpha-jammy-amd64-packages.sha256"

gpg --homedir "${GNUPG}" --verify -- "${TMP}/site1/repos/alpha/dists/jammy/InRelease" >>"${EVIDENCE}" 2>&1
record_rc gpg_inrelease "$?" 0
gpg --no-default-keyring --keyring "${TMP}/site1/apt-hub.gpg" --verify -- \
  "${TMP}/site1/repos/alpha/dists/noble/Release.gpg" "${TMP}/site1/repos/alpha/dists/noble/Release" >>"${EVIDENCE}" 2>&1
record_rc gpg_release_with_site_key "$?" 0
if grep -R -- 'BEGIN PGP PRIVATE KEY' "${TMP}/site1" >/dev/null; then
  log "FAIL 站点含私钥"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
  log "CASE no_private_key: exit=0 expect=0"
fi

FIRST_DL="$(wc -l <"${CURL_DOWNLOAD_COUNT_FILE}")"
rc=0
[[ "${FIRST_DL}" -eq 4 ]] || rc=1
record_rc first_sync_downloaded_four_debs "${rc}" 0

# 幂等重跑：无变化不重下 deb，updated_at 不变
sleep 1
: >"${CURL_DOWNLOAD_COUNT_FILE}"
rc="$(capture_rc "${TMP}/run2.log" run_sync "${TMP}/site1" "${TMP}/site2")"
cat "${TMP}/run2.log" >>"${EVIDENCE}"
record_rc rerun_sync "${rc}" 0
UPDATED2="$(jq -r '.packages[]|select(.id=="alpha")|.updated_at' "${TMP}/site2/state.json")"
UPDATED_BETA1="$(jq -r '.packages[]|select(.id=="beta")|.updated_at' "${TMP}/site1/state.json")"
UPDATED_BETA2="$(jq -r '.packages[]|select(.id=="beta")|.updated_at' "${TMP}/site2/state.json")"
rc=0
test "${UPDATED1}" = "${UPDATED2}" || rc=1
test "${UPDATED_BETA1}" = "${UPDATED_BETA2}" || rc=1
record_rc idempotent_updated_at "${rc}" 0
rc=0
test "$(awk -F/ '/^URIs: /{print $(NF-1)}' "${TMP}/site2/repos/jammy.sources" | paste -sd, -)" = "alpha,beta" || rc=1
test "$(awk -F/ '/^URIs: /{print $(NF-1)}' "${TMP}/site2/repos/noble.sources" | paste -sd, -)" = "alpha" || rc=1
record_rc aggregate_on_unchanged_rerun "${rc}" 0
rc=0
test "${HASH_P}" = "$(sha256sum -- "${TMP}/site2/repos/alpha/dists/jammy/main/binary-amd64/Packages" | awk '{print $1}')" || rc=1
record_rc idempotent_packages_hash "${rc}" 0
SECOND_DL="$(wc -l <"${CURL_DOWNLOAD_COUNT_FILE}")"
rc=0
[[ "${SECOND_DL}" -eq 0 ]] || rc=1
record_rc unchanged_skips_deb_download "${rc}" 0
assert_no_deb_under "${TMP}/site2"
record_rc rerun_metadata_no_deb "$?" 0

# 版本升级仍保留旧 by-hash；产物无 deb
write_release_json alpha 2.0.0 "${TMP}/api/alpha.json"
: >"${CURL_DOWNLOAD_COUNT_FILE}"
rc="$(capture_rc "${TMP}/run3.log" run_sync "${TMP}/site2" "${TMP}/site3")"
cat "${TMP}/run3.log" >>"${EVIDENCE}"
record_rc version_bump "${rc}" 0
test "$(jq -r '.packages[]|select(.id=="alpha")|.version' "${TMP}/site3/state.json")" = "2.0.0"
test "$(jq -r '.packages[]|select(.id=="beta")|.version' "${TMP}/site3/state.json")" = "1.0.0"
assert_no_deb_under "${TMP}/site3"
assert_file "${TMP}/site3/repos/alpha/dists/jammy/main/binary-amd64/by-hash/SHA256/${HASH_P}"
assert_file "${TMP}/site3/repos/alpha/dists/jammy/main/binary-amd64/by-hash/SHA256/${HASH_Z}"
record_rc old_byhash_kept "$?" 0
NEW_HASH="$(sha256sum -- "${TMP}/site3/repos/alpha/dists/jammy/main/binary-amd64/Packages" | awk '{print $1}')"
[[ "${NEW_HASH}" != "${HASH_P}" ]]
assert_file "${TMP}/site3/repos/alpha/dists/jammy/main/binary-amd64/by-hash/SHA256/${NEW_HASH}"
grep -q 'alpha-2.0.0-x86_64.deb' "${TMP}/site3/repos/alpha/dists/jammy/main/binary-amd64/Packages"
rc=0
test "$(jq -r '.packages[]|select(.id=="alpha")|.updated_at' "${TMP}/site3/state.json")" != "${UPDATED2}" || rc=1
record_rc bump_changes_updated_at "${rc}" 0
BUMP_DL="$(wc -l <"${CURL_DOWNLOAD_COUNT_FILE}")"
# alpha 两架构重下，beta 复用
rc=0
[[ "${BUMP_DL}" -eq 2 ]] || rc=1
record_rc bump_only_redownloads_changed "${rc}" 0

# 签名篡改后校验拒绝
cp -- "${TMP}/site3/repos/alpha/dists/jammy/InRelease" "${TMP}/InRelease.orig"
sed 's/^Suite: jammy$/Suite: evil/' "${TMP}/InRelease.orig" >"${TMP}/site3/repos/alpha/dists/jammy/InRelease"
rc="$(capture_rc "${TMP}/tamper-verify.log" gpg --no-default-keyring --keyring "${TMP}/site3/apt-hub.gpg" --verify -- "${TMP}/site3/repos/alpha/dists/jammy/InRelease")"
cat "${TMP}/tamper-verify.log" >>"${EVIDENCE}"
[[ "${rc}" -ne 0 ]]
record_rc tampered_inrelease_rejected 1 1
mv -- "${TMP}/InRelease.orig" "${TMP}/site3/repos/alpha/dists/jammy/InRelease"

# 失败不动 previous：降级
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"
dir_manifest "${TMP}/site3" >"${TMP}/site3.before"
rc="$(capture_rc "${TMP}/run-downgrade.log" run_sync "${TMP}/site3" "${TMP}/site-downgrade")"
cat "${TMP}/run-downgrade.log" >>"${EVIDENCE}"
record_rc downgrade_rejected "${rc}" 1
assert_no_file "${TMP}/site-downgrade"
assert_no_file "${TMP}/site-downgrade.work"
assert_no_file "${TMP}/site-downgrade.scratch"
dir_manifest "${TMP}/site3" >"${TMP}/site3.after"
cmp -- "${TMP}/site3.before" "${TMP}/site3.after"
record_rc previous_unchanged_on_downgrade "$?" 0

# 同版本内容替换拒绝
write_release_json alpha 2.0.0 "${TMP}/api/alpha.json"
build_deb alpha 2.0.0 amd64 "${TMP}/debs/alpha-2.0.0-x86_64.deb" v2.0.0
build_deb alpha 2.0.0 arm64 "${TMP}/debs/alpha-2.0.0-aarch64.deb" v2.0.0
cp -- "${TMP}/debs/alpha-1.0.0-x86_64-replaced.deb" "${TMP}/debs/alpha-1.0.0-x86_64.deb"
cp -- "${TMP}/debs/alpha-1.0.0-aarch64-replaced.deb" "${TMP}/debs/alpha-1.0.0-aarch64.deb"
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"
dir_manifest "${TMP}/site1" >"${TMP}/site1.before"
rc="$(capture_rc "${TMP}/run-replace.log" run_sync "${TMP}/site1" "${TMP}/site-replace")"
cat "${TMP}/run-replace.log" >>"${EVIDENCE}"
record_rc same_version_replace_rejected "${rc}" 1
assert_no_file "${TMP}/site-replace"
cmp -- "${TMP}/site1.before" <(dir_manifest "${TMP}/site1")
record_rc previous_unchanged_on_replace "$?" 0

build_deb alpha 1.0.0 amd64 "${TMP}/debs/alpha-1.0.0-x86_64.deb" v1.0.0
build_deb alpha 1.0.0 arm64 "${TMP}/debs/alpha-1.0.0-aarch64.deb" v1.0.0
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"
write_release_json beta 1.0.0 "${TMP}/api/beta.json"
refresh_maps

# previous by-hash 篡改：复用路径应失败或重核验；这里破坏后同版本复用必须拒绝盲签
# 使用与当前夹具摘要一致的新站点作为 previous 基线
rc="$(capture_rc "${TMP}/run-base-for-tamper.log" run_sync "${TMP}/empty-prev" "${TMP}/site-base")"
cat "${TMP}/run-base-for-tamper.log" >>"${EVIDENCE}"
record_rc base_for_tamper "${rc}" 0
HASH_BASE="$(sha256sum -- "${TMP}/site-base/repos/alpha/dists/jammy/main/binary-amd64/Packages" | awk '{print $1}')"
cp -a -- "${TMP}/site-base" "${TMP}/site1-tampered"
printf 'x' >>"${TMP}/site1-tampered/repos/alpha/dists/jammy/main/binary-amd64/by-hash/SHA256/${HASH_BASE}"
# 同步破坏当前 Packages，使摘要与 Release 不一致
printf 'x' >>"${TMP}/site1-tampered/repos/alpha/dists/jammy/main/binary-amd64/Packages"
dir_manifest "${TMP}/site1-tampered" >"${TMP}/site1-tampered.before"
rc="$(capture_rc "${TMP}/run-badhash.log" run_sync "${TMP}/site1-tampered" "${TMP}/site-badhash")"
cat "${TMP}/run-badhash.log" >>"${EVIDENCE}"
record_rc tampered_previous_rejected "${rc}" 1
assert_no_file "${TMP}/site-badhash"
cmp -- "${TMP}/site1-tampered.before" <(dir_manifest "${TMP}/site1-tampered")
record_rc previous_unchanged_on_badhash "$?" 0

# 旁路 Release/Packages 篡改：InRelease 字节不动，官方资产字段不动；复用路径必须拒绝
sidecar_tamper_release_packages() {
  local dist="$1"
  local packages="${dist}/main/binary-amd64/Packages"
  local release="${dist}/Release"
  local tmp hash size
  tmp="$(mktemp -- "${TMP}/packages.XXXXXX")"
  awk '
    /^Architecture: / { print; print "Depends: regression-injected-dependency"; next }
    { print }
  ' "${packages}" >"${tmp}"
  mv -- "${tmp}" "${packages}"
  hash="$(sha256sum -- "${packages}" | awk '{print $1}')"
  size="$(stat -c '%s' -- "${packages}")"
  tmp="$(mktemp -- "${TMP}/release.XXXXXX")"
  awk -v h="${hash}" -v s="${size}" -v f="main/binary-amd64/Packages" '
    $1 == "SHA256:" { print; insha = 1; next }
    insha && NF >= 3 {
      path = $3
      sub(/^\.\//, "", path)
      if (path == f) {
        printf " %s %16s %s\n", h, s, f
        next
      }
    }
    { print }
  ' "${release}" >"${tmp}"
  mv -- "${tmp}" "${release}"
}

cp -a -- "${TMP}/site-base" "${TMP}/site-sidecar-tamper"
: >"${TMP}/sidecar-inrelease.sha.before"
: >"${TMP}/sidecar-inrelease.sha.after"
while IFS= read -r -d '' dist; do
  sha256sum -- "${dist}/InRelease" >>"${TMP}/sidecar-inrelease.sha.before"
  sidecar_tamper_release_packages "${dist}"
  sha256sum -- "${dist}/InRelease" >>"${TMP}/sidecar-inrelease.sha.after"
done < <(find -- "${TMP}/site-sidecar-tamper/repos/alpha/dists" -mindepth 1 -maxdepth 1 -type d -print0)
cmp -- "${TMP}/sidecar-inrelease.sha.before" "${TMP}/sidecar-inrelease.sha.after"
grep -q '^Depends: regression-injected-dependency$' \
  "${TMP}/site-sidecar-tamper/repos/alpha/dists/jammy/main/binary-amd64/Packages"
grep -q 'alpha-1.0.0-x86_64.deb' \
  "${TMP}/site-sidecar-tamper/repos/alpha/dists/jammy/main/binary-amd64/Packages"
dir_manifest "${TMP}/site-sidecar-tamper" >"${TMP}/site-sidecar-tamper.before"
rc="$(capture_rc "${TMP}/run-sidecar-tamper.log" run_sync "${TMP}/site-sidecar-tamper" "${TMP}/site-sidecar-out")"
cat "${TMP}/run-sidecar-tamper.log" >>"${EVIDENCE}"
record_rc sidecar_release_tamper_rejected "${rc}" 1
assert_no_file "${TMP}/site-sidecar-out"
cmp -- "${TMP}/site-sidecar-tamper.before" <(dir_manifest "${TMP}/site-sidecar-tamper")
record_rc previous_unchanged_on_sidecar_tamper "$?" 0

# 坏签名 InRelease：必须拒绝（所有 series，避免复用落到未破坏套件）
cp -a -- "${TMP}/site-base" "${TMP}/site-badsig"
while IFS= read -r -d '' ir; do
  dd if=/dev/zero of="${ir}" bs=1 seek=64 count=1 conv=notrunc status=none
done < <(find -- "${TMP}/site-badsig/repos/alpha/dists" -type f -name InRelease -print0)
dir_manifest "${TMP}/site-badsig" >"${TMP}/site-badsig.before"
rc="$(capture_rc "${TMP}/run-badsig.log" run_sync "${TMP}/site-badsig" "${TMP}/site-badsig-out")"
cat "${TMP}/run-badsig.log" >>"${EVIDENCE}"
record_rc bad_inrelease_signature_rejected "${rc}" 1
assert_no_file "${TMP}/site-badsig-out"
cmp -- "${TMP}/site-badsig.before" <(dir_manifest "${TMP}/site-badsig")
record_rc previous_unchanged_on_badsig "$?" 0

# 旧 schema / pool 镜像 previous 明确拒绝且不动输入
mkdir -p -- "${TMP}/old-mirror/pool/main/a/alpha"
printf 'fake\n' >"${TMP}/old-mirror/pool/main/a/alpha/alpha_1.0.0_amd64.deb"
printf '%s\n' '{"schema_version":1,"packages":[]}' >"${TMP}/old-mirror/state.json"
dir_manifest "${TMP}/old-mirror" >"${TMP}/old-mirror.before"
rc="$(capture_rc "${TMP}/run-oldschema.log" run_sync "${TMP}/old-mirror" "${TMP}/site-oldschema")"
cat "${TMP}/run-oldschema.log" >>"${EVIDENCE}"
record_rc old_schema_pool_rejected "${rc}" 1
assert_no_file "${TMP}/site-oldschema"
cmp -- "${TMP}/old-mirror.before" <(dir_manifest "${TMP}/old-mirror")
record_rc old_previous_untouched "$?" 0

# 非空 output 拒绝
mkdir -p -- "${TMP}/site-nonempty"
printf 'keep\n' >"${TMP}/site-nonempty/stay.txt"
rc="$(capture_rc "${TMP}/run-nonempty.log" run_sync "${TMP}/empty-prev" "${TMP}/site-nonempty")"
cat "${TMP}/run-nonempty.log" >>"${EVIDENCE}"
record_rc nonempty_output_rejected "${rc}" 1
rc=0
test -f "${TMP}/site-nonempty/stay.txt" || rc=1
record_rc nonempty_output_preserved "${rc}" 0

# 缺少官方 digest
jq 'del(.assets[].digest)' "${TMP}/api/alpha.json" >"${TMP}/api/alpha.nodigest.json"
mv -- "${TMP}/api/alpha.nodigest.json" "${TMP}/api/alpha.json"
rc="$(capture_rc "${TMP}/run-nodigest.log" run_sync "${TMP}/empty-prev" "${TMP}/site-nodigest")"
cat "${TMP}/run-nodigest.log" >>"${EVIDENCE}"
record_rc missing_digest_rejected "${rc}" 1
assert_no_file "${TMP}/site-nodigest"
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"

# ubuntu_series 不是支持集子集
jq '.packages[1].ubuntu_series=["bogus"]' "${TMP}/catalog.json" >"${TMP}/catalog.badseries.json"
rc="$(capture_rc "${TMP}/run-badseries.log" "${SYNC}" --catalog "${TMP}/catalog.badseries.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-badseries" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-badseries.log" >>"${EVIDENCE}"
record_rc series_not_subset_rejected "${rc}" 1

# 重叠路径拒绝
rc="$(capture_rc "${TMP}/run-overlap.log" "${SYNC}" --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site1" --output "${TMP}/site1" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-overlap.log" >>"${EVIDENCE}"
record_rc overlap_rejected "${rc}" 1

# 预先存在的 .work/.scratch 不得被 cleanup 删除
mkdir -p -- "${TMP}/site-prework.work"
printf 'pre-existing-work-sentinel\n' >"${TMP}/site-prework.work/KEEP.txt"
PREWORK_HASH="$(sha256sum -- "${TMP}/site-prework.work/KEEP.txt" | awk '{print $1}')"
rc="$(capture_rc "${TMP}/run-prework.log" run_sync "${TMP}/empty-prev" "${TMP}/site-prework")"
cat "${TMP}/run-prework.log" >>"${EVIDENCE}"
record_rc preexisting_work_rejected "${rc}" 1
rc=0
test -f "${TMP}/site-prework.work/KEEP.txt" || rc=1
test "${PREWORK_HASH}" = "$(sha256sum -- "${TMP}/site-prework.work/KEEP.txt" | awk '{print $1}')" || rc=1
record_rc preexisting_work_sentinel_intact "${rc}" 0
assert_no_file "${TMP}/site-prework"

mkdir -p -- "${TMP}/site-prescratch.scratch"
printf 'pre-existing-scratch-sentinel\n' >"${TMP}/site-prescratch.scratch/KEEP.txt"
PRESCRATCH_HASH="$(sha256sum -- "${TMP}/site-prescratch.scratch/KEEP.txt" | awk '{print $1}')"
rc="$(capture_rc "${TMP}/run-prescratch.log" run_sync "${TMP}/empty-prev" "${TMP}/site-prescratch")"
cat "${TMP}/run-prescratch.log" >>"${EVIDENCE}"
record_rc preexisting_scratch_rejected "${rc}" 1
rc=0
test -f "${TMP}/site-prescratch.scratch/KEEP.txt" || rc=1
test "${PRESCRATCH_HASH}" = "$(sha256sum -- "${TMP}/site-prescratch.scratch/KEEP.txt" | awk '{print $1}')" || rc=1
record_rc preexisting_scratch_sentinel_intact "${rc}" 0
assert_no_file "${TMP}/site-prescratch"

# lock 不得截断/跟随符号链接；活跃锁不可绕过
printf 'lock-target-sentinel\n' >"${TMP}/lock-target.txt"
LOCK_TARGET_HASH="$(sha256sum -- "${TMP}/lock-target.txt" | awk '{print $1}')"
ln -s -- "${TMP}/lock-target.txt" "${TMP}/site-locksym.lock"
rc="$(capture_rc "${TMP}/run-locksym.log" run_sync "${TMP}/empty-prev" "${TMP}/site-locksym")"
cat "${TMP}/run-locksym.log" >>"${EVIDENCE}"
record_rc lock_symlink_rejected "${rc}" 1
rc=0
test -f "${TMP}/lock-target.txt" || rc=1
test "${LOCK_TARGET_HASH}" = "$(sha256sum -- "${TMP}/lock-target.txt" | awk '{print $1}')" || rc=1
test "$(cat -- "${TMP}/lock-target.txt")" = "lock-target-sentinel" || rc=1
record_rc lock_symlink_target_intact "${rc}" 0
assert_no_file "${TMP}/site-locksym"

mkdir -p -- "${TMP}/realbase/parent"
ln -s -- "${TMP}/realbase" "${TMP}/wrapbase"
rc="$(capture_rc "${TMP}/run-lock-ancestor.log" run_sync "${TMP}/empty-prev" "${TMP}/wrapbase/parent/site")"
cat "${TMP}/run-lock-ancestor.log" >>"${EVIDENCE}"
record_rc lock_symlink_ancestor_rejected "${rc}" 1
assert_no_file "${TMP}/wrapbase/parent/site"
assert_no_file "${TMP}/realbase/parent/site"

printf 'keep-lock-bytes\n' >"${TMP}/site-held.lock"
exec 8>>"${TMP}/site-held.lock"
flock -n 8
rc="$(capture_rc "${TMP}/run-held.lock.log" run_sync "${TMP}/empty-prev" "${TMP}/site-held")"
cat "${TMP}/run-held.lock.log" >>"${EVIDENCE}"
record_rc active_lock_blocks "${rc}" 1
flock -u 8
exec 8>&-
rc=0
test "$(cat -- "${TMP}/site-held.lock")" = "keep-lock-bytes" || rc=1
record_rc active_lock_not_truncated "${rc}" 0
assert_no_file "${TMP}/site-held"
assert_no_file "${TMP}/site-held.work"

# apt-ftparchive packages 失败必须拒绝
cat >"${TMP}/bin/apt-ftparchive" <<EOF
#!/usr/bin/env bash
for _a in "\$@"; do
  if [[ "\${_a}" == "packages" ]]; then
    printf 'apt-ftparchive-shim: injected packages failure\n' >&2
    exit 1
  fi
done
exec "${REAL_APT_FTPARCHIVE}" "\$@"
EOF
chmod 755 -- "${TMP}/bin/apt-ftparchive"
dir_manifest "${TMP}/empty-prev" >"${TMP}/empty-prev.afa.before"
rc="$(capture_rc "${TMP}/run-afa.log" run_sync "${TMP}/empty-prev" "${TMP}/site-afa-fail")"
cat "${TMP}/run-afa.log" >>"${EVIDENCE}"
record_rc apt_ftparchive_packages_fail "${rc}" 1
grep -q 'apt-ftparchive packages 失败' "${TMP}/run-afa.log"
record_rc apt_ftparchive_error_not_swallowed "$?" 0
grep -q 'apt-ftparchive-shim: injected packages failure' "${TMP}/run-afa.log"
record_rc apt_ftparchive_shim_injected "$?" 0
assert_no_file "${TMP}/site-afa-fail"
assert_no_file "${TMP}/site-afa-fail.work"
assert_no_file "${TMP}/site-afa-fail.scratch"
cmp -- "${TMP}/empty-prev.afa.before" <(dir_manifest "${TMP}/empty-prev")
record_rc previous_unchanged_on_afa_fail "$?" 0
rm -f -- "${TMP}/bin/apt-ftparchive"

# previous filename 拒绝绝对路径 / .. / 换行（官方相对路径语义）
cp -a -- "${TMP}/site-base" "${TMP}/site-absname"
jq '.packages[0].assets[0].filename="/etc/os-release"' "${TMP}/site-base/state.json" >"${TMP}/site-absname/state.json"
dir_manifest "${TMP}/site-absname" >"${TMP}/site-absname.before"
rc="$(capture_rc "${TMP}/run-absname.log" run_sync "${TMP}/site-absname" "${TMP}/site-absname-out")"
cat "${TMP}/run-absname.log" >>"${EVIDENCE}"
record_rc absolute_filename_rejected "${rc}" 1
assert_no_file "${TMP}/site-absname-out"
cmp -- "${TMP}/site-absname.before" <(dir_manifest "${TMP}/site-absname")
record_rc previous_unchanged_on_abs_filename "$?" 0

cp -a -- "${TMP}/site-base" "${TMP}/site-dotdot"
jq '.packages[0].assets[0].filename="fixture/alpha/../../../etc/os-release"' "${TMP}/site-base/state.json" >"${TMP}/site-dotdot/state.json"
rc="$(capture_rc "${TMP}/run-dotdot.log" run_sync "${TMP}/site-dotdot" "${TMP}/site-dotdot-out")"
cat "${TMP}/run-dotdot.log" >>"${EVIDENCE}"
record_rc dotdot_filename_rejected "${rc}" 1
assert_no_file "${TMP}/site-dotdot-out"

cp -a -- "${TMP}/site-base" "${TMP}/site-nlname"
jq --arg f $'fixture/alpha/releases/download/1.0.0/alpha-1.0.0-x86_64.deb\n/etc/os-release' \
  '.packages[0].assets[0].filename=$f' "${TMP}/site-base/state.json" >"${TMP}/site-nlname/state.json"
rc="$(capture_rc "${TMP}/run-nlname.log" run_sync "${TMP}/site-nlname" "${TMP}/site-nlname-out")"
cat "${TMP}/run-nlname.log" >>"${EVIDENCE}"
record_rc newline_filename_rejected "${rc}" 1
assert_no_file "${TMP}/site-nlname-out"

# releases 日期必须是当前标准支持窗口
TODAY_UTC="$(date -u +%Y-%m-%d)"
jq '.releases[0].release_date="2018-04-26" | .releases[0].eol_date="2023-05-31"' "${TMP}/releases.json" >"${TMP}/releases.expired.json"
rc="$(capture_rc "${TMP}/run-expired.log" "${SYNC}" --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.expired.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-expired" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-expired.log" >>"${EVIDENCE}"
record_rc expired_series_rejected "${rc}" 1
grep -q '已结束标准支持期' "${TMP}/run-expired.log"
record_rc expired_series_reason "$?" 0
assert_no_file "${TMP}/site-expired"

jq '.releases[0].release_date="2099-01-01" | .releases[0].eol_date="2100-01-01"' "${TMP}/releases.json" >"${TMP}/releases.future.json"
rc="$(capture_rc "${TMP}/run-future.log" "${SYNC}" --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.future.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-future" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-future.log" >>"${EVIDENCE}"
record_rc future_series_rejected "${rc}" 1
assert_no_file "${TMP}/site-future"

jq --arg d "${TODAY_UTC}" '.releases[0].eol_date=$d' "${TMP}/releases.json" >"${TMP}/releases.eol-today.json"
rc="$(capture_rc "${TMP}/run-eol-today.log" "${SYNC}" --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.eol-today.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-eol-today" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-eol-today.log" >>"${EVIDENCE}"
record_rc eol_today_rejected "${rc}" 1
assert_no_file "${TMP}/site-eol-today"

# html_url / browser_download_url 必须锚定清单仓库
jq '.html_url="https://github.com/evil/alpha/releases/tag/1.0.0"' "${TMP}/api/alpha.json" >"${TMP}/api/alpha.evilhtml.json"
cp -- "${TMP}/api/alpha.evilhtml.json" "${TMP}/api/alpha.json"
rc="$(capture_rc "${TMP}/run-evilhtml.log" run_sync "${TMP}/empty-prev" "${TMP}/site-evilhtml")"
cat "${TMP}/run-evilhtml.log" >>"${EVIDENCE}"
record_rc evil_html_url_rejected "${rc}" 1
assert_no_file "${TMP}/site-evilhtml"
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"

jq '.assets[0].browser_download_url="https://evil.example/alpha.deb"' "${TMP}/api/alpha.json" >"${TMP}/api/alpha.evildl.json"
cp -- "${TMP}/api/alpha.evildl.json" "${TMP}/api/alpha.json"
rc="$(capture_rc "${TMP}/run-evildl.log" run_sync "${TMP}/empty-prev" "${TMP}/site-evildl")"
cat "${TMP}/run-evildl.log" >>"${EVIDENCE}"
record_rc evil_download_url_rejected "${rc}" 1
assert_no_file "${TMP}/site-evildl"
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"

jq '.assets[0].browser_download_url="https://github.com/fixture/alpha/releases/download/1.0.0/../../evil.deb"' "${TMP}/api/alpha.json" >"${TMP}/api/alpha.dotdoturl.json"
cp -- "${TMP}/api/alpha.dotdoturl.json" "${TMP}/api/alpha.json"
rc="$(capture_rc "${TMP}/run-dotdoturl.log" run_sync "${TMP}/empty-prev" "${TMP}/site-dotdoturl")"
cat "${TMP}/run-dotdoturl.log" >>"${EVIDENCE}"
record_rc dotted_download_url_rejected "${rc}" 1
assert_no_file "${TMP}/site-dotdoturl"
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"

# 静默换钥拒绝
GNUPG2="${TMP}/gnupg2"
mkdir -m 700 -- "${GNUPG2}"
printf 'allow-loopback-pinentry\n' >"${GNUPG2}/gpg-agent.conf"
gpg --homedir "${GNUPG2}" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "apt-hub other key <apt-hub-other@invalid>" ed25519 sign never
FP2="$(gpg --homedir "${GNUPG2}" --batch --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')"
rc="$(capture_rc "${TMP}/run-rekey.log" "${SYNC}" \
  --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-base" --output "${TMP}/site-rekey" \
  --gnupghome "${GNUPG2}" --fingerprint "${FP2}" --site-url "${SITE_URL}")"
cat "${TMP}/run-rekey.log" >>"${EVIDENCE}"
record_rc silent_rekey_rejected "${rc}" 1
assert_no_file "${TMP}/site-rekey"

# 错误签名身份：apt-hub.gpg 仍是当前 fingerprint，但索引被另一已导入钥重签；不得因 keyring 碰巧有该钥而接受
cp -a -- "${TMP}/site-base" "${TMP}/site-wrong-identity"
gpg --homedir "${GNUPG2}" --batch --export -- "${FP2}" \
  | gpg --homedir "${GNUPG}" --batch --import >/dev/null 2>&1
while IFS= read -r -d '' release_path; do
  dist="$(dirname -- "${release_path}")"
  gpg --homedir "${GNUPG2}" --batch --yes --pinentry-mode loopback --passphrase '' \
    --local-user "${FP2}" --detach-sign --armor --output "${dist}/Release.gpg" -- "${dist}/Release"
  gpg --homedir "${GNUPG2}" --batch --yes --pinentry-mode loopback --passphrase '' \
    --local-user "${FP2}" --clearsign --output "${dist}/InRelease" -- "${dist}/Release"
done < <(find -- "${TMP}/site-wrong-identity/repos" -type f -name Release -print0)
dir_manifest "${TMP}/site-wrong-identity" >"${TMP}/site-wrong-identity.before"
rc="$(capture_rc "${TMP}/run-wrong-identity.log" run_sync "${TMP}/site-wrong-identity" "${TMP}/site-wrong-identity-out")"
cat "${TMP}/run-wrong-identity.log" >>"${EVIDENCE}"
record_rc wrong_signing_identity_rejected "${rc}" 1
assert_no_file "${TMP}/site-wrong-identity-out"
cmp -- "${TMP}/site-wrong-identity.before" <(dir_manifest "${TMP}/site-wrong-identity")
record_rc previous_unchanged_on_wrong_identity "$?" 0

# 存量软件目录：catalog 去掉 beta 后仍保留 repos/beta；有效签名须续期 Valid-Until
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"
write_release_json beta 1.0.0 "${TMP}/api/beta.json"
refresh_maps
jq '.packages=[.packages[0]]' "${TMP}/catalog.json" >"${TMP}/catalog.alpha-only.json"
BETA_PKG_BEFORE="$(sha256sum -- "${TMP}/site-base/repos/beta/dists/jammy/main/binary-amd64/Packages" | awk '{print $1}')"
BETA_UPDATED_BEFORE="$(jq -r '.packages[]|select(.id=="beta")|.updated_at' "${TMP}/site-base/state.json")"
BETA_VU_BEFORE="$(awk -F': ' '/^Valid-Until:/{print $2; exit}' "${TMP}/site-base/repos/beta/dists/jammy/Release")"
# 保证续期墙钟可区分：夹具 Release 时间戳早于本步
sleep 1
rc="$(capture_rc "${TMP}/run-retain.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-only.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-base" --output "${TMP}/site-retain" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-retain.log" >>"${EVIDENCE}"
record_rc retain_previous_plugin_repo "${rc}" 0
assert_file "${TMP}/site-retain/repos/beta/mirror.list"
jq -e '.packages|map(.id)|index("beta")!=null' "${TMP}/site-retain/state.json" >/dev/null
record_rc retain_previous_plugin_state "$?" 0
BETA_PKG_AFTER="$(sha256sum -- "${TMP}/site-retain/repos/beta/dists/jammy/main/binary-amd64/Packages" | awk '{print $1}')"
BETA_UPDATED_AFTER="$(jq -r '.packages[]|select(.id=="beta")|.updated_at' "${TMP}/site-retain/state.json")"
BETA_VU_AFTER="$(awk -F': ' '/^Valid-Until:/{print $2; exit}' "${TMP}/site-retain/repos/beta/dists/jammy/Release")"
rc=0
[[ "${BETA_PKG_BEFORE}" == "${BETA_PKG_AFTER}" ]] || rc=1
record_rc retain_packages_unchanged "${rc}" 0
rc=0
[[ "${BETA_UPDATED_BEFORE}" == "${BETA_UPDATED_AFTER}" ]] || rc=1
record_rc retain_updated_at_unchanged "${rc}" 0
rc=0
[[ -n "${BETA_VU_AFTER}" && "${BETA_VU_AFTER}" != "${BETA_VU_BEFORE}" ]] || rc=1
record_rc retain_valid_until_renewed "${rc}" 0
gpg --homedir "${GNUPG}" --batch --verify -- "${TMP}/site-retain/repos/beta/dists/jammy/InRelease" >>"${EVIDENCE}" 2>&1
record_rc retain_inrelease_verifies "$?" 0
rc=0
cmp -s -- "${TMP}/site-base/repos/beta/dists/jammy/Release" \
  "${TMP}/site-retain/repos/beta/dists/jammy/Release" && rc=1
record_rc retain_release_not_byte_identical "${rc}" 0
rc=0
test "$(awk -F/ '/^URIs: /{print $(NF-1)}' "${TMP}/site-retain/repos/jammy.sources" | paste -sd, -)" = "alpha,beta" || rc=1
test "$(awk -F/ '/^URIs: /{print $(NF-1)}' "${TMP}/site-retain/repos/noble.sources" | paste -sd, -)" = "alpha" || rc=1
record_rc retain_aggregate_includes_beta "${rc}" 0

# site-url 变更时存量 mirror/sources/state 前缀须跟上，不长期指旧站
SITE_URL_NEW='https://apt-hub-renewed.example.test'
rc="$(capture_rc "${TMP}/run-retain-siteurl.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-only.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-base" --output "${TMP}/site-retain-siteurl" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL_NEW}")"
cat "${TMP}/run-retain-siteurl.log" >>"${EVIDENCE}"
record_rc retain_siteurl_sync "${rc}" 0
grep -Fq $'https://apt-hub-renewed.example.test/repos/beta/\ttype:index' \
  "${TMP}/site-retain-siteurl/repos/beta/mirror.list"
record_rc retain_mirror_index_siteurl "$?" 0
grep -Fq 'URIs: mirror+https://apt-hub-renewed.example.test/repos/beta/mirror.list' \
  "${TMP}/site-retain-siteurl/repos/beta/jammy.sources"
record_rc retain_sources_siteurl "$?" 0
jq -e --arg u 'mirror+https://apt-hub-renewed.example.test/repos/beta/mirror.list' \
  '.packages[]|select(.id=="beta")|.apt_source_uri==$u' \
  "${TMP}/site-retain-siteurl/state.json" >/dev/null
record_rc retain_state_apt_uri_siteurl "$?" 0
rc=0
grep -Fq 'URIs: mirror+https://apt-hub-renewed.example.test/repos/alpha/mirror.list' \
  "${TMP}/site-retain-siteurl/repos/jammy.sources" || rc=1
grep -Fq 'URIs: mirror+https://apt-hub-renewed.example.test/repos/beta/mirror.list' \
  "${TMP}/site-retain-siteurl/repos/jammy.sources" || rc=1
record_rc retain_aggregate_siteurl "${rc}" 0

# 未匹配 catalog 的存量被旁路篡改：不得重新发布 / 不得续签
cp -a -- "${TMP}/site-base" "${TMP}/site-retain-tamper"
sidecar_tamper_release_packages "${TMP}/site-retain-tamper/repos/beta/dists/jammy"
dir_manifest "${TMP}/site-retain-tamper" >"${TMP}/site-retain-tamper.before"
rc="$(capture_rc "${TMP}/run-retain-tamper.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-only.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-retain-tamper" --output "${TMP}/site-retain-tamper-out" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-retain-tamper.log" >>"${EVIDENCE}"
record_rc retain_sidecar_tamper_rejected "${rc}" 1
assert_no_file "${TMP}/site-retain-tamper-out"
cmp -- "${TMP}/site-retain-tamper.before" <(dir_manifest "${TMP}/site-retain-tamper")
record_rc previous_unchanged_on_retain_tamper "$?" 0

# 合法发行版窗口迁移：当前 series 与 previous 无交集时，须从旧受信系列复用已核验 control
jq '.packages=[.packages[0] | .ubuntu_series=["jammy"]]' "${TMP}/catalog.json" >"${TMP}/catalog.alpha-jammy.json"
rc="$(capture_rc "${TMP}/run-alpha-jammy-only.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-jammy.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-alpha-jammy" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-alpha-jammy-only.log" >>"${EVIDENCE}"
record_rc alpha_jammy_only_site "${rc}" 0
assert_file "${TMP}/site-alpha-jammy/repos/alpha/dists/jammy/InRelease"
assert_no_file "${TMP}/site-alpha-jammy/repos/alpha/dists/noble"
jq -n '{schema_version:1, source_url:"https://example.test/ubuntu.csv", checked_at:"2026-11-06T00:00:00Z",
  releases:[{series:"noble",version:"24.04",release_date:"2024-04-25",eol_date:"2029-05-31"}]}' \
  >"${TMP}/releases.noble-only.json"
jq '.packages=[.packages[0] | .ubuntu_series=["noble"]]' "${TMP}/catalog.json" >"${TMP}/catalog.alpha-noble.json"
: >"${CURL_DOWNLOAD_COUNT_FILE}"
rc="$(capture_rc "${TMP}/run-series-migrate.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-noble.json" --releases "${TMP}/releases.noble-only.json" \
  --previous "${TMP}/site-alpha-jammy" --output "${TMP}/site-series-migrate" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-series-migrate.log" >>"${EVIDENCE}"
record_rc series_window_reuse_from_old "${rc}" 0
assert_file "${TMP}/site-series-migrate/repos/alpha/dists/noble/InRelease"
assert_no_file "${TMP}/site-series-migrate/repos/alpha/dists/jammy/InRelease"
assert_no_file "${TMP}/site-series-migrate/repos/alpha/dists/jammy/Release"
jq -e '.packages[]|select(.id=="alpha")|.ubuntu_series==["noble"]' \
  "${TMP}/site-series-migrate/state.json" >/dev/null
record_rc series_window_state_noble_only "$?" 0
MIGRATE_DL="$(wc -l <"${CURL_DOWNLOAD_COUNT_FILE}")"
rc=0
[[ "${MIGRATE_DL}" -eq 0 ]] || rc=1
record_rc series_window_reuse_no_download "${rc}" 0
grep -q 'alpha-1.0.0-x86_64.deb' \
  "${TMP}/site-series-migrate/repos/alpha/dists/noble/main/binary-amd64/Packages"
record_rc series_window_noble_packages "$?" 0

# catalog 与 verify 一致：含 .. 的 id 在 producer 入口拒绝
jq '.packages[0].id="a..b"' "${TMP}/catalog.json" >"${TMP}/catalog.dotdot-id.json"
rc="$(capture_rc "${TMP}/run-dotdot-id.log" "${SYNC}" \
  --catalog "${TMP}/catalog.dotdot-id.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-dotdot-id" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-dotdot-id.log" >>"${EVIDENCE}"
record_rc catalog_dotdot_id_rejected "${rc}" 1
assert_no_file "${TMP}/site-dotdot-id"
grep -Fq '非法 id: a..b' "${TMP}/run-dotdot-id.log"
record_rc catalog_dotdot_id_reason "$?" 0

# previous state id 路径穿越：源 inputs/side 与目标 outputs/side 分离，哨兵不同
# 未修时会把源覆盖到目标；修后拒绝且目标哨兵不变。previous/repos/../../side 与
# output.work/repos/../../side 不得再归一成同一路径。
mkdir -p -- "${TMP}/inputs" "${TMP}/outputs"
cp -a -- "${TMP}/site-base" "${TMP}/inputs/previous"
cp -a -- "${TMP}/site-base/repos/beta" "${TMP}/inputs/side"
printf 'source-controlled-overwrite\n' >"${TMP}/inputs/side/SENTINEL.txt"
mkdir -p -- "${TMP}/outputs/side"
printf 'preexisting-output-sentinel\n' >"${TMP}/outputs/side/SENTINEL.txt"
sha256sum -- "${TMP}/outputs/side/SENTINEL.txt" >"${TMP}/outputs/side.sentinel.before"
jq '.packages=[.packages[] | select(.id=="beta") | .id="../../side"]' \
  "${TMP}/site-base/state.json" >"${TMP}/inputs/previous/state.json"
rm -rf -- "${TMP}/inputs/previous/repos/beta"
dir_manifest "${TMP}/inputs/previous" >"${TMP}/inputs/previous.before"
rc="$(capture_rc "${TMP}/run-prev-traversal.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-only.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/inputs/previous" --output "${TMP}/outputs/site-prev-traversal" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-prev-traversal.log" >>"${EVIDENCE}"
record_rc previous_id_traversal_rejected "${rc}" 1
assert_no_file "${TMP}/outputs/site-prev-traversal"
cmp -- "${TMP}/inputs/previous.before" <(dir_manifest "${TMP}/inputs/previous")
record_rc previous_unchanged_on_id_traversal "$?" 0
cmp -- "${TMP}/outputs/side.sentinel.before" <(sha256sum -- "${TMP}/outputs/side/SENTINEL.txt")
record_rc outside_work_sentinel_unchanged_on_id_traversal "$?" 0
rc=0
[[ "$(cat -- "${TMP}/outputs/side/SENTINEL.txt")" == "preexisting-output-sentinel" ]] || rc=1
record_rc outside_work_sentinel_content_intact "${rc}" 0
rc=0
[[ "$(cat -- "${TMP}/inputs/side/SENTINEL.txt")" == "source-controlled-overwrite" ]] || rc=1
record_rc outside_source_sentinel_intact "${rc}" 0
assert_no_file "${TMP}/outputs/side/dists"
record_rc outside_work_escaped_repo_absent "$?" 0

# 存量仅篡改 Packages.gz：拒绝续签，previous 不变
cp -a -- "${TMP}/site-base" "${TMP}/site-retain-gzip"
while IFS= read -r -d '' gz; do
  plain="${gz%.gz}"
  awk '/^Description:/ { print "Depends: apt-hub-regression-injected-dependency"; print; next } {print}' \
    "${plain}" | gzip -n -9 >"${gz}"
done < <(find -- "${TMP}/site-retain-gzip/repos/beta" -type f -name 'Packages.gz' -print0)
dir_manifest "${TMP}/site-retain-gzip" >"${TMP}/site-retain-gzip.before"
rc="$(capture_rc "${TMP}/run-retain-gzip.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-only.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-retain-gzip" --output "${TMP}/site-retain-gzip-out" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-retain-gzip.log" >>"${EVIDENCE}"
record_rc retain_gzip_tamper_rejected "${rc}" 1
assert_no_file "${TMP}/site-retain-gzip-out"
cmp -- "${TMP}/site-retain-gzip.before" <(dir_manifest "${TMP}/site-retain-gzip")
record_rc previous_unchanged_on_retain_gzip_tamper "$?" 0

# 存量 mirror type:deb 被改为第三方：拒绝，previous 不变
cp -a -- "${TMP}/site-base" "${TMP}/site-retain-mirror"
printf '%s\n' \
  $'https://apt-hub.example.test/repos/beta/\ttype:index' \
  $'https://third-party.invalid/\ttype:deb' \
  >"${TMP}/site-retain-mirror/repos/beta/mirror.list"
dir_manifest "${TMP}/site-retain-mirror" >"${TMP}/site-retain-mirror.before"
rc="$(capture_rc "${TMP}/run-retain-mirror.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-only.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-retain-mirror" --output "${TMP}/site-retain-mirror-out" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-retain-mirror.log" >>"${EVIDENCE}"
record_rc retain_third_party_mirror_rejected "${rc}" 1
assert_no_file "${TMP}/site-retain-mirror-out"
cmp -- "${TMP}/site-retain-mirror.before" <(dir_manifest "${TMP}/site-retain-mirror")
record_rc previous_unchanged_on_retain_mirror_tamper "$?" 0

# 存量跨字段：仅替 beta asset.url 文件名（assets-url-path-mismatch）；认证 Filename/sha 不动
cp -a -- "${TMP}/site-base" "${TMP}/site-assets-url-path-mismatch"
jq '(.packages |= map(if .id=="beta" then .assets[0].url="https://github.com/fixture/beta/releases/download/1.0.0/not-the-signed-file.deb" else . end))' \
  "${TMP}/site-base/state.json" >"${TMP}/site-assets-url-path-mismatch/state.json"
dir_manifest "${TMP}/site-assets-url-path-mismatch" >"${TMP}/site-assets-url-path-mismatch.before"
rc="$(capture_rc "${TMP}/run-assets-url-path-mismatch.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-only.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-assets-url-path-mismatch" --output "${TMP}/site-assets-url-path-mismatch-out" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-assets-url-path-mismatch.log" >>"${EVIDENCE}"
record_rc assets_url_path_mismatch_rejected "${rc}" 1
assert_no_file "${TMP}/site-assets-url-path-mismatch-out"
cmp -- "${TMP}/site-assets-url-path-mismatch.before" <(dir_manifest "${TMP}/site-assets-url-path-mismatch")
record_rc previous_unchanged_on_assets_url_path_mismatch "$?" 0
grep -Fq 'asset.url 路径与签名 Packages Filename 不符' "${TMP}/run-assets-url-path-mismatch.log"
record_rc assets_url_path_mismatch_reason "$?" 0

# 存量跨字段：同时替 beta repository 与 url（assets-repo-and-url-replaced），保留认证 Filename/sha/size/arch
cp -a -- "${TMP}/site-base" "${TMP}/site-assets-repo-and-url-replaced"
jq '(.packages |= map(if .id=="beta" then .repository="other/not-official" | .assets[0].url="https://github.com/other/not-official/releases/download/1.0.0/beta-1.0.0-x86_64.deb" else . end))' \
  "${TMP}/site-base/state.json" >"${TMP}/site-assets-repo-and-url-replaced/state.json"
dir_manifest "${TMP}/site-assets-repo-and-url-replaced" >"${TMP}/site-assets-repo-and-url-replaced.before"
rc="$(capture_rc "${TMP}/run-assets-repo-and-url-replaced.log" "${SYNC}" \
  --catalog "${TMP}/catalog.alpha-only.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site-assets-repo-and-url-replaced" --output "${TMP}/site-assets-repo-and-url-replaced-out" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}" --site-url "${SITE_URL}")"
cat "${TMP}/run-assets-repo-and-url-replaced.log" >>"${EVIDENCE}"
record_rc assets_repo_and_url_replaced_rejected "${rc}" 1
assert_no_file "${TMP}/site-assets-repo-and-url-replaced-out"
cmp -- "${TMP}/site-assets-repo-and-url-replaced.before" <(dir_manifest "${TMP}/site-assets-repo-and-url-replaced")
record_rc previous_unchanged_on_assets_repo_and_url_replaced "$?" 0
grep -Fq 'asset.url 路径与签名 Packages Filename 不符' "${TMP}/run-assets-repo-and-url-replaced.log"
record_rc assets_repo_and_url_replaced_reason "$?" 0

gpgconf --homedir "${GNUPG}" --kill gpg-agent >/dev/null 2>&1 || true
gpgconf --homedir "${GNUPG2}" --kill gpg-agent >/dev/null 2>&1 || true

log "PASS=${PASS} FAIL=${FAIL}"
if [[ "${FAIL}" -ne 0 ]]; then
  log "同步测试失败"
  exit 1
fi
log "同步测试通过"
exit 0
