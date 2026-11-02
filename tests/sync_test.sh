#!/usr/bin/env bash
# tests/sync_test.sh — 本地夹具测试 sync.sh。curl shim 为夹具，不是真实网络证据。
set -euo pipefail
export LC_ALL=C
export LANG=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="${ROOT}/scripts/sync.sh"
CATALOG_PROD="${ROOT}/config/packages.json"
TMP="${ROOT}/tmp/sync-test"
EVIDENCE="${TMP}/evidence.log"
SENTINEL="${TMP}/MAINTAINER_RAN"
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
# 要求调用方显式限制 TLS/重定向为 HTTPS，防止 http 降级。
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

log "CASE syntax: bash -n"
bash -n -- "${SYNC}"
record_rc syntax_sync "$?" 0
bash -n -- "${ROOT}/tests/sync_test.sh"
record_rc syntax_test "$?" 0

log "CASE prod_catalog_schema"
jq -e '.schema_version==1 and (.packages|length)>=1 and .packages[0].id=="rustdesk"' "${CATALOG_PROD}" >/dev/null
record_rc prod_catalog_schema "$?" 0

# 测试签名密钥（仅测试用途）
GNUPG="${TMP}/gnupg"
mkdir -m 700 -- "${GNUPG}"
printf 'allow-loopback-pinentry\n' >"${GNUPG}/gpg-agent.conf"
gpg --homedir "${GNUPG}" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "apt-hub test key <apt-hub-test@invalid>" ed25519 sign never
FP="$(gpg --homedir "${GNUPG}" --batch --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')"
log "test_fingerprint=${FP}"
[[ "${#FP}" -eq 40 ]]

# 构造两个软件、两个架构、两个版本的本地 .deb
for pkg in alpha beta; do
  for ver in 1.0.0 2.0.0; do
    build_deb "${pkg}" "${ver}" amd64 "${TMP}/debs/${pkg}-${ver}-x86_64.deb" v"${ver}"
    build_deb "${pkg}" "${ver}" arm64 "${TMP}/debs/${pkg}-${ver}-aarch64.deb" v"${ver}"
  done
done
# 同版本不同内容（替换拒绝用）
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
  schema_version:1,
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

run_sync() {
  local prev="$1" out="$2"
  "${SYNC}" \
    --catalog "${TMP}/catalog.json" \
    --releases "${TMP}/releases.json" \
    --previous "${prev}" \
    --output "${out}" \
    --gnupghome "${GNUPG}" \
    --fingerprint "${FP}"
}

capture_rc() {
  local logf="$1" rc=0
  shift
  if "$@" >"${logf}" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "${rc}"
}

rm -f -- "${SENTINEL}"
rc="$(capture_rc "${TMP}/run1.log" run_sync "${TMP}/empty-prev" "${TMP}/site1")"
cat "${TMP}/run1.log" >>"${EVIDENCE}"
record_rc first_sync "${rc}" 0

assert_file "${TMP}/site1/state.json"
assert_file "${TMP}/site1/apt-hub.gpg"
assert_no_file "${SENTINEL}"
record_rc maintainer_script_not_run "$?" 0

jq -e '.packages|length==2' "${TMP}/site1/state.json" >/dev/null
test "$(jq -r '.packages[]|select(.id=="alpha")|.version' "${TMP}/site1/state.json")" = "1.0.0"
test "$(jq -r '.packages[]|select(.id=="beta")|.ubuntu_series|join(",")' "${TMP}/site1/state.json")" = "jammy"
test "$(jq -r '.packages[]|select(.id=="alpha")|.ubuntu_series|join(",")' "${TMP}/site1/state.json")" = "jammy,noble"
test "$(jq -r '.packages[]|select(.id=="alpha")|.architectures|join(",")' "${TMP}/site1/state.json")" = "amd64,arm64"
test "$(jq -r '.packages[]|select(.id=="alpha")|.release_url' "${TMP}/site1/state.json")" = "https://github.com/fixture/alpha/releases/tag/1.0.0"
test "$(jq -r '.packages[]|select(.id=="alpha")|.source_url' "${TMP}/site1/state.json")" = "https://github.com/fixture/alpha/tree/1.0.0"
UPDATED1="$(jq -r '.packages[]|select(.id=="alpha")|.updated_at' "${TMP}/site1/state.json")"
[[ "${UPDATED1}" =~ Z$ ]]
assert_file "${TMP}/site1/pool/main/a/alpha/alpha_1.0.0_amd64.deb"
assert_file "${TMP}/site1/pool/main/a/alpha/alpha_1.0.0_arm64.deb"
assert_file "${TMP}/site1/pool/main/b/beta/beta_1.0.0_amd64.deb"
assert_file "${TMP}/site1/pool/main/b/beta/beta_1.0.0_arm64.deb"
grep -q '^Package: alpha$' "${TMP}/site1/dists/jammy/main/binary-amd64/Packages"
grep -q '^Package: beta$' "${TMP}/site1/dists/jammy/main/binary-amd64/Packages"
grep -q '^Package: alpha$' "${TMP}/site1/dists/noble/main/binary-amd64/Packages"
if grep -q '^Package: beta$' "${TMP}/site1/dists/noble/main/binary-amd64/Packages"; then
  log "FAIL noble 不应包含仅 jammy 的 beta"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
  log "CASE beta_not_in_noble: exit=0 expect=0"
fi
grep -q '^Filename: pool/main/a/alpha/alpha_1.0.0_amd64.deb$' "${TMP}/site1/dists/jammy/main/binary-amd64/Packages"
grep -q '^SHA256:' "${TMP}/site1/dists/jammy/Release"
if grep -E '[[:space:]]Release$' "${TMP}/site1/dists/jammy/Release" >/dev/null; then
  log "FAIL Release 含对自身的摘要"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
  log "CASE release_no_self_hash: exit=0 expect=0"
fi
if grep -E '^(MD5Sum|SHA1|SHA512):' "${TMP}/site1/dists/jammy/Release" >/dev/null; then
  log "FAIL Release 含非 SHA256"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
  log "CASE release_sha256_only: exit=0 expect=0"
fi
grep -q '^Acquire-By-Hash: yes$' "${TMP}/site1/dists/jammy/Release"
grep -q '^Valid-Until:' "${TMP}/site1/dists/jammy/Release"
DATE_R="$(awk -F': ' '/^Date:/{print $2}' "${TMP}/site1/dists/jammy/Release")"
VU_R="$(awk -F': ' '/^Valid-Until:/{print $2}' "${TMP}/site1/dists/jammy/Release")"
DS="$(date -u -d "${DATE_R}" +%s)"
VS="$(date -u -d "${VU_R}" +%s)"
test "$((VS - DS))" -eq 1209600
record_rc valid_until_14d "$?" 0

HASH_P="$(sha256sum -- "${TMP}/site1/dists/jammy/main/binary-amd64/Packages" | awk '{print $1}')"
HASH_Z="$(sha256sum -- "${TMP}/site1/dists/jammy/main/binary-amd64/Packages.gz" | awk '{print $1}')"
assert_file "${TMP}/site1/dists/jammy/main/binary-amd64/by-hash/SHA256/${HASH_P}"
assert_file "${TMP}/site1/dists/jammy/main/binary-amd64/by-hash/SHA256/${HASH_Z}"
printf '%s\n' "${HASH_P}" >"${TMP}/site1-jammy-amd64-packages.sha256"

gpg --homedir "${GNUPG}" --verify -- "${TMP}/site1/dists/jammy/InRelease" >>"${EVIDENCE}" 2>&1
record_rc gpg_inrelease "$?" 0
gpg --no-default-keyring --keyring "${TMP}/site1/apt-hub.gpg" --verify -- "${TMP}/site1/dists/noble/Release.gpg" "${TMP}/site1/dists/noble/Release" >>"${EVIDENCE}" 2>&1
record_rc gpg_release_with_site_key "$?" 0
if grep -R -- 'BEGIN PGP PRIVATE KEY' "${TMP}/site1" >/dev/null; then
  log "FAIL 站点含私钥"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
  log "CASE no_private_key: exit=0 expect=0"
fi

# 幂等重跑，updated_at 不变
sleep 1
rc="$(capture_rc "${TMP}/run2.log" run_sync "${TMP}/site1" "${TMP}/site2")"
cat "${TMP}/run2.log" >>"${EVIDENCE}"
record_rc rerun_sync "${rc}" 0
UPDATED2="$(jq -r '.packages[]|select(.id=="alpha")|.updated_at' "${TMP}/site2/state.json")"
UPDATED_BETA1="$(jq -r '.packages[]|select(.id=="beta")|.updated_at' "${TMP}/site1/state.json")"
UPDATED_BETA2="$(jq -r '.packages[]|select(.id=="beta")|.updated_at' "${TMP}/site2/state.json")"
test "${UPDATED1}" = "${UPDATED2}"
test "${UPDATED_BETA1}" = "${UPDATED_BETA2}"
record_rc idempotent_updated_at "$?" 0
test "${HASH_P}" = "$(sha256sum -- "${TMP}/site2/dists/jammy/main/binary-amd64/Packages" | awk '{print $1}')"
record_rc idempotent_packages_hash "$?" 0

# 旧 by-hash 在升级后仍在
write_release_json alpha 2.0.0 "${TMP}/api/alpha.json"
rc="$(capture_rc "${TMP}/run3.log" run_sync "${TMP}/site2" "${TMP}/site3")"
cat "${TMP}/run3.log" >>"${EVIDENCE}"
record_rc version_bump "${rc}" 0
test "$(jq -r '.packages[]|select(.id=="alpha")|.version' "${TMP}/site3/state.json")" = "2.0.0"
test "$(jq -r '.packages[]|select(.id=="beta")|.version' "${TMP}/site3/state.json")" = "1.0.0"
assert_file "${TMP}/site3/pool/main/a/alpha/alpha_1.0.0_amd64.deb"
assert_file "${TMP}/site3/pool/main/a/alpha/alpha_2.0.0_amd64.deb"
assert_file "${TMP}/site3/dists/jammy/main/binary-amd64/by-hash/SHA256/${HASH_P}"
assert_file "${TMP}/site3/dists/jammy/main/binary-amd64/by-hash/SHA256/${HASH_Z}"
record_rc old_byhash_kept "$?" 0
NEW_HASH="$(sha256sum -- "${TMP}/site3/dists/jammy/main/binary-amd64/Packages" | awk '{print $1}')"
[[ "${NEW_HASH}" != "${HASH_P}" ]]
assert_file "${TMP}/site3/dists/jammy/main/binary-amd64/by-hash/SHA256/${NEW_HASH}"
grep -q 'alpha_2.0.0_amd64.deb' "${TMP}/site3/dists/jammy/main/binary-amd64/Packages"
if grep -q 'alpha_1.0.0_amd64.deb' "${TMP}/site3/dists/jammy/main/binary-amd64/Packages"; then
  log "FAIL 当前 Packages 不应再索引已升级的旧当前版本为主项以外的历史为必须；若出现可接受但本实现只索引当前版"
fi
test "$(jq -r '.packages[]|select(.id=="alpha")|.updated_at' "${TMP}/site3/state.json")" != "${UPDATED2}"
record_rc bump_changes_updated_at "$?" 0

# 签名篡改后校验拒绝（改签名正文，不是签名块后追加）
cp -- "${TMP}/site3/dists/jammy/InRelease" "${TMP}/InRelease.orig"
sed 's/^Suite: jammy$/Suite: evil/' "${TMP}/InRelease.orig" >"${TMP}/site3/dists/jammy/InRelease"
rc="$(capture_rc "${TMP}/tamper-verify.log" gpg --no-default-keyring --keyring "${TMP}/site3/apt-hub.gpg" --verify -- "${TMP}/site3/dists/jammy/InRelease")"
cat "${TMP}/tamper-verify.log" >>"${EVIDENCE}"
[[ "${rc}" -ne 0 ]]
record_rc tampered_inrelease_rejected 1 1
mv -- "${TMP}/InRelease.orig" "${TMP}/site3/dists/jammy/InRelease"

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
cp -- "${TMP}/debs/alpha-1.0.0-x86_64-replaced.deb" "${TMP}/debs/alpha-2.0.0-x86_64.deb"
cp -- "${TMP}/debs/alpha-1.0.0-aarch64-replaced.deb" "${TMP}/debs/alpha-2.0.0-aarch64.deb"
# 上面覆盖了 2.0.0 文件内容，但 version 仍是 1.0.0 包内版本，会在 Package/Version 阶段失败；
# 真正同版本替换：previous 为 site1（alpha 1.0.0），资产同名同版本不同摘要。
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"
# 恢复 2.0.0 真实包以免后续污染，再单独做 1.0.0 替换夹具
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

# 恢复 1.0.0 原始包
build_deb alpha 1.0.0 amd64 "${TMP}/debs/alpha-1.0.0-x86_64.deb" v1.0.0
build_deb alpha 1.0.0 arm64 "${TMP}/debs/alpha-1.0.0-aarch64.deb" v1.0.0
write_release_json alpha 1.0.0 "${TMP}/api/alpha.json"

# previous by-hash 篡改拒绝
cp -a -- "${TMP}/site1" "${TMP}/site1-tampered"
TAMPER_HASH="$(head -n 1 "${TMP}/site1-jammy-amd64-packages.sha256")"
printf 'x' >>"${TMP}/site1-tampered/dists/jammy/main/binary-amd64/by-hash/SHA256/${TAMPER_HASH}"
dir_manifest "${TMP}/site1-tampered" >"${TMP}/site1-tampered.before"
rc="$(capture_rc "${TMP}/run-badhash.log" run_sync "${TMP}/site1-tampered" "${TMP}/site-badhash")"
cat "${TMP}/run-badhash.log" >>"${EVIDENCE}"
record_rc tampered_byhash_rejected "${rc}" 1
assert_no_file "${TMP}/site-badhash"
cmp -- "${TMP}/site1-tampered.before" <(dir_manifest "${TMP}/site1-tampered")
record_rc previous_unchanged_on_badhash "$?" 0

# 非空 output 拒绝
mkdir -p -- "${TMP}/site-nonempty"
printf 'keep\n' >"${TMP}/site-nonempty/stay.txt"
rc="$(capture_rc "${TMP}/run-nonempty.log" run_sync "${TMP}/empty-prev" "${TMP}/site-nonempty")"
cat "${TMP}/run-nonempty.log" >>"${EVIDENCE}"
record_rc nonempty_output_rejected "${rc}" 1
test -f "${TMP}/site-nonempty/stay.txt"
record_rc nonempty_output_preserved "$?" 0

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
  --gnupghome "${GNUPG}" --fingerprint "${FP}")"
cat "${TMP}/run-badseries.log" >>"${EVIDENCE}"
record_rc series_not_subset_rejected "${rc}" 1

# 重叠路径拒绝
rc="$(capture_rc "${TMP}/run-overlap.log" "${SYNC}" --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.json" \
  --previous "${TMP}/site1" --output "${TMP}/site1" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}")"
cat "${TMP}/run-overlap.log" >>"${EVIDENCE}"
record_rc overlap_rejected "${rc}" 1

# --- 精确修复回归 ---

# 1. 预先存在的 .work/.scratch 不得被 cleanup 删除
mkdir -p -- "${TMP}/site-prework.work"
printf 'pre-existing-work-sentinel\n' >"${TMP}/site-prework.work/KEEP.txt"
PREWORK_HASH="$(sha256sum -- "${TMP}/site-prework.work/KEEP.txt" | awk '{print $1}')"
rc="$(capture_rc "${TMP}/run-prework.log" run_sync "${TMP}/empty-prev" "${TMP}/site-prework")"
cat "${TMP}/run-prework.log" >>"${EVIDENCE}"
record_rc preexisting_work_rejected "${rc}" 1
test -f "${TMP}/site-prework.work/KEEP.txt"
test "${PREWORK_HASH}" = "$(sha256sum -- "${TMP}/site-prework.work/KEEP.txt" | awk '{print $1}')"
record_rc preexisting_work_sentinel_intact "$?" 0
assert_no_file "${TMP}/site-prework"

mkdir -p -- "${TMP}/site-prescratch.scratch"
printf 'pre-existing-scratch-sentinel\n' >"${TMP}/site-prescratch.scratch/KEEP.txt"
PRESCRATCH_HASH="$(sha256sum -- "${TMP}/site-prescratch.scratch/KEEP.txt" | awk '{print $1}')"
rc="$(capture_rc "${TMP}/run-prescratch.log" run_sync "${TMP}/empty-prev" "${TMP}/site-prescratch")"
cat "${TMP}/run-prescratch.log" >>"${EVIDENCE}"
record_rc preexisting_scratch_rejected "${rc}" 1
test -f "${TMP}/site-prescratch.scratch/KEEP.txt"
test "${PRESCRATCH_HASH}" = "$(sha256sum -- "${TMP}/site-prescratch.scratch/KEEP.txt" | awk '{print $1}')"
record_rc preexisting_scratch_sentinel_intact "$?" 0
assert_no_file "${TMP}/site-prescratch"

# 2. lock 不得截断/跟随符号链接；活跃锁不可绕过
printf 'lock-target-sentinel\n' >"${TMP}/lock-target.txt"
LOCK_TARGET_HASH="$(sha256sum -- "${TMP}/lock-target.txt" | awk '{print $1}')"
ln -s -- "${TMP}/lock-target.txt" "${TMP}/site-locksym.lock"
rc="$(capture_rc "${TMP}/run-locksym.log" run_sync "${TMP}/empty-prev" "${TMP}/site-locksym")"
cat "${TMP}/run-locksym.log" >>"${EVIDENCE}"
record_rc lock_symlink_rejected "${rc}" 1
test -f "${TMP}/lock-target.txt"
test "${LOCK_TARGET_HASH}" = "$(sha256sum -- "${TMP}/lock-target.txt" | awk '{print $1}')"
test "$(cat -- "${TMP}/lock-target.txt")" = "lock-target-sentinel"
record_rc lock_symlink_target_intact "$?" 0
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
test "$(cat -- "${TMP}/site-held.lock")" = "keep-lock-bytes"
record_rc active_lock_not_truncated "$?" 0
assert_no_file "${TMP}/site-held"
assert_no_file "${TMP}/site-held.work"

# 3. apt-ftparchive packages 失败必须拒绝
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

# 4. previous filename 必须是安全 pool 相对路径
cp -a -- "${TMP}/site1" "${TMP}/site-absname"
jq '.packages[0].assets[0].filename="/etc/os-release"' "${TMP}/site1/state.json" >"${TMP}/site-absname/state.json"
dir_manifest "${TMP}/site-absname" >"${TMP}/site-absname.before"
rc="$(capture_rc "${TMP}/run-absname.log" run_sync "${TMP}/site-absname" "${TMP}/site-absname-out")"
cat "${TMP}/run-absname.log" >>"${EVIDENCE}"
record_rc absolute_filename_rejected "${rc}" 1
assert_no_file "${TMP}/site-absname-out"
cmp -- "${TMP}/site-absname.before" <(dir_manifest "${TMP}/site-absname")
record_rc previous_unchanged_on_abs_filename "$?" 0

cp -a -- "${TMP}/site1" "${TMP}/site-dotdot"
jq '.packages[0].assets[0].filename="pool/main/a/alpha/../../../etc/os-release"' "${TMP}/site1/state.json" >"${TMP}/site-dotdot/state.json"
rc="$(capture_rc "${TMP}/run-dotdot.log" run_sync "${TMP}/site-dotdot" "${TMP}/site-dotdot-out")"
cat "${TMP}/run-dotdot.log" >>"${EVIDENCE}"
record_rc dotdot_filename_rejected "${rc}" 1
assert_no_file "${TMP}/site-dotdot-out"

cp -a -- "${TMP}/site1" "${TMP}/site-nlname"
jq --arg f $'pool/main/a/alpha/alpha_1.0.0_amd64.deb\n/etc/os-release' \
  '.packages[0].assets[0].filename=$f' "${TMP}/site1/state.json" >"${TMP}/site-nlname/state.json"
rc="$(capture_rc "${TMP}/run-nlname.log" run_sync "${TMP}/site-nlname" "${TMP}/site-nlname-out")"
cat "${TMP}/run-nlname.log" >>"${EVIDENCE}"
record_rc newline_filename_rejected "${rc}" 1
assert_no_file "${TMP}/site-nlname-out"

# 5. releases 日期必须是当前标准支持窗口
TODAY_UTC="$(date -u +%Y-%m-%d)"
jq '.releases[0].release_date="2018-04-26" | .releases[0].eol_date="2023-05-31"' "${TMP}/releases.json" >"${TMP}/releases.expired.json"
rc="$(capture_rc "${TMP}/run-expired.log" "${SYNC}" --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.expired.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-expired" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}")"
cat "${TMP}/run-expired.log" >>"${EVIDENCE}"
record_rc expired_series_rejected "${rc}" 1
grep -q '已结束标准支持期' "${TMP}/run-expired.log"
record_rc expired_series_reason "$?" 0
assert_no_file "${TMP}/site-expired"

jq '.releases[0].release_date="2099-01-01" | .releases[0].eol_date="2100-01-01"' "${TMP}/releases.json" >"${TMP}/releases.future.json"
rc="$(capture_rc "${TMP}/run-future.log" "${SYNC}" --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.future.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-future" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}")"
cat "${TMP}/run-future.log" >>"${EVIDENCE}"
record_rc future_series_rejected "${rc}" 1
assert_no_file "${TMP}/site-future"

jq --arg d "${TODAY_UTC}" '.releases[0].eol_date=$d' "${TMP}/releases.json" >"${TMP}/releases.eol-today.json"
rc="$(capture_rc "${TMP}/run-eol-today.log" "${SYNC}" --catalog "${TMP}/catalog.json" --releases "${TMP}/releases.eol-today.json" \
  --previous "${TMP}/empty-prev" --output "${TMP}/site-eol-today" \
  --gnupghome "${GNUPG}" --fingerprint "${FP}")"
cat "${TMP}/run-eol-today.log" >>"${EVIDENCE}"
record_rc eol_today_rejected "${rc}" 1
assert_no_file "${TMP}/site-eol-today"

# 6. html_url / browser_download_url 必须锚定清单仓库
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

gpgconf --homedir "${GNUPG}" --kill gpg-agent >/dev/null 2>&1 || true

log "PASS=${PASS} FAIL=${FAIL}"
if [[ "${FAIL}" -ne 0 ]]; then
  log "同步测试失败"
  exit 1
fi
log "同步测试通过"
exit 0
