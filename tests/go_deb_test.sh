#!/usr/bin/env bash
# tests/go_deb_test.sh — apt-hub-go 官方归档构包：默认离线夹具；可选 --live 用现有缓存真实验收。
set -euo pipefail
export LC_ALL=C
export LANG=C
export LANGUAGE=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${ROOT}/scripts/build_go_deb.sh"
CONFIG="${ROOT}/config/go.json"
TMP="${ROOT}/tmp/go-build-v9"
EVIDENCE="${TMP}/evidence.log"
# 优先 PATH 既有 shellcheck；无则跳过硬编码本机路径（调用方可将 binary 放入独占 bin）。
SHELLCHECK_BIN="$(command -v shellcheck 2>/dev/null || true)"
PASS=0
FAIL=0
HOST_ARCH="$(dpkg --print-architecture)"

LIVE=0
LIVE_DOWNLOADS_JSON=""
LIVE_ARCHIVE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live)
      LIVE=1
      shift
      ;;
    --downloads-json)
      [[ $# -ge 2 ]] || { echo "缺少 --downloads-json 参数" >&2; exit 2; }
      LIVE_DOWNLOADS_JSON="$2"
      shift 2
      ;;
    --archive-dir)
      [[ $# -ge 2 ]] || { echo "缺少 --archive-dir 参数" >&2; exit 2; }
      LIVE_ARCHIVE_DIR="$2"
      shift 2
      ;;
    -h|--help)
      cat >&2 <<'EOF'
用法: tests/go_deb_test.sh [--live --downloads-json <官方JSON> --archive-dir <已缓存归档目录>]
默认仅离线夹具；--live 追加真官方缓存验收（不重下大包）。
EOF
      exit 2
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "${LIVE}" -eq 1 ]]; then
  [[ -n "${LIVE_DOWNLOADS_JSON}" && -n "${LIVE_ARCHIVE_DIR}" ]] \
    || { echo "--live 需要同时提供 --downloads-json 与 --archive-dir" >&2; exit 2; }
fi

APT_ROOT=""
GNUPG_TEST_HOME=""

# EXIT：无论成败停本测 home agent、只清本测私钥目录。
trap 'rc=$?;
  if [[ -n "${GNUPG_TEST_HOME}" && -d "${GNUPG_TEST_HOME}" && ! -L "${GNUPG_TEST_HOME}" ]]; then
    GNUPGHOME="${GNUPG_TEST_HOME}" gpgconf --kill all >/dev/null 2>&1 || true
    rm -rf -- "${GNUPG_TEST_HOME}"
  fi
  if [[ -n "${APT_ROOT}" && -d "${APT_ROOT}/gnupg" && ! -L "${APT_ROOT}/gnupg" ]]; then
    GNUPGHOME="${APT_ROOT}/gnupg" gpgconf --kill all >/dev/null 2>&1 || true
    rm -rf -- "${APT_ROOT}/gnupg"
  fi
  unset GNUPGHOME 2>/dev/null || true
  exit "${rc}"' EXIT

mkdir -p -- "${ROOT}/tmp"
mkdir -p -- "${TMP}"
# 保留官方归档供 parent 复用；清理本批测试子目录。
rm -rf -- "${TMP}/test" "${TMP}/out" "${TMP}/apt-upgrade" "${TMP}/extract-official" \
  "${TMP}/gnupg-test" "${TMP}/listener" "${TMP}/red-probe"
mkdir -p -- "${TMP}/test/bin" "${TMP}/test/fixtures" "${TMP}/test/archives" \
  "${TMP}/test/sentinels" "${TMP}/archives"

{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "root=${ROOT}"
  echo "host_arch=${HOST_ARCH}"
  echo "live=${LIVE}"
} >"${EVIDENCE}"

log() {
  printf '%s\n' "$*" | tee -a "${EVIDENCE}"
}

record() {
  local name="$1" rc="$2" expect="$3"
  log "CASE ${name}: exit=${rc} expect=${expect}"
  if [[ "${rc}" -eq "${expect}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    log "FAIL ${name}"
  fi
}

assert_file() {
  local f="$1"
  [[ -f "${f}" ]] || { log "缺少文件 ${f}"; return 1; }
}

assert_same_bytes() {
  local a="$1" b="$2"
  cmp -s -- "${a}" "${b}" || { log "字节不一致: ${a} vs ${b}"; return 1; }
}

write_min_elf() {
  local out="$1" arch="$2"
  local machine
  case "${arch}" in
    amd64) machine="3e00" ;;
    arm64) machine="b700" ;;
    *) log "未知 ELF 架构 ${arch}"; return 1 ;;
  esac
  # 可辨识测试 ELF，非官方 Go；仅供 readelf Machine 校验。
  xxd -r -p >"${out}" <<EOF
7f454c460201010000000000000000000200${machine}010000000000000000000000400000000000000000000000000000000000000000000000400038000100400000000000000000000000
EOF
  printf 'APT_HUB_GO_TEST_FIXTURE_ELF\n' >>"${out}"
  chmod 755 -- "${out}"
}

make_fixture_tree() {
  local root="$1" ver_tag="$2" arch="$3"
  local triple
  case "${arch}" in
    amd64) triple=linux_amd64 ;;
    arm64) triple=linux_arm64 ;;
    *) return 1 ;;
  esac
  rm -rf -- "${root}"
  mkdir -p -- "${root}/go/bin" "${root}/go/pkg/tool/${triple}" "${root}/go/src"
  printf '%s\ntime 2023-11-14T00:00:00Z\n' "${ver_tag}" >"${root}/go/VERSION"
  printf 'TEST FIXTURE LICENSE — not official Go\n' >"${root}/go/LICENSE"
  write_min_elf "${root}/go/bin/go" "${arch}"
  write_min_elf "${root}/go/bin/gofmt" "${arch}"
  write_min_elf "${root}/go/pkg/tool/${triple}/compile" "${arch}"
  printf 'package main\nfunc main(){}\n' >"${root}/go/src/hello.go"
}

pack_fixture_archive() {
  local tree="$1" dest="$2" epoch="${3:-1700000000}"
  [[ -d "${tree}/go" ]] || { log "夹具缺少 ${tree}/go"; return 1; }
  find -- "${tree}/go" -print0 | while IFS= read -r -d '' p; do
    touch -h -d "@${epoch}" -- "${p}"
  done
  (
    cd -- "${tree}"
    tar --sort=name --mtime="@${epoch}" --owner=0 --group=0 --numeric-owner \
      -czf "${dest}.tmp" go
  )
  mv -f -- "${dest}.tmp" "${dest}"
  touch -d "@${epoch}" -- "${dest}"
}

write_fixture_json() {
  local out="$1" ver_tag="$2" amd_file="$3" arm_file="$4"
  local amd_sha amd_size arm_sha arm_size
  amd_sha="$(sha256sum -- "${amd_file}" | awk '{print $1}')"
  amd_size="$(stat -c '%s' -- "${amd_file}")"
  arm_sha="$(sha256sum -- "${arm_file}" | awk '{print $1}')"
  arm_size="$(stat -c '%s' -- "${arm_file}")"
  jq -n \
    --arg ver "${ver_tag}" \
    --arg af "$(basename -- "${amd_file}")" --arg as "${amd_sha}" --arg az "${amd_size}" \
    --arg rf "$(basename -- "${arm_file}")" --arg rs "${arm_sha}" --arg rz "${arm_size}" \
    '[
      {
        version:$ver,
        stable:true,
        files:[
          {filename:$af, os:"linux", arch:"amd64", version:$ver, sha256:$as, size:($az|tonumber), kind:"archive"},
          {filename:$rf, os:"linux", arch:"arm64", version:$ver, sha256:$rs, size:($rz|tonumber), kind:"archive"}
        ]
      },
      {
        version:"go1.0.0",
        stable:true,
        files:[
          {filename:"go1.0.0.linux-amd64.tar.gz", os:"linux", arch:"amd64", version:"go1.0.0", sha256:("0"*64), size:1, kind:"archive"},
          {filename:"go1.0.0.linux-arm64.tar.gz", os:"linux", arch:"arm64", version:"go1.0.0", sha256:("0"*64), size:1, kind:"archive"}
        ]
      }
    ]' >"${out}"
}

build_tiny_deb() {
  local pkg="$1" ver="$2" arch="$3" dest="$4"
  local root="${TMP}/test/tinydeb/${pkg}-${ver}-${arch}"
  rm -rf -- "${root}"
  mkdir -p -- "${root}/DEBIAN" "${root}/usr/share/doc/${pkg}"
  cat >"${root}/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${ver}
Architecture: ${arch}
Maintainer: apt-hub-test <apt-hub-test@invalid>
Section: devel
Priority: optional
Description: test old ${pkg}
EOF
  printf 'old fixture %s\n' "${ver}" >"${root}/usr/share/doc/${pkg}/README"
  env SOURCE_DATE_EPOCH=1700000000 dpkg-deb --build --root-owner-group -Zgzip -z9 -- "${root}" "${dest}" >/dev/null
}

run_isolated_apt_upgrade() {
  local new_deb="$1" expect_ver="$2" label="$3"
  local old_deb fp ar
  APT_ROOT="${TMP}/apt-upgrade-${label}"
  rm -rf -- "${APT_ROOT}"
  mkdir -p -- "${APT_ROOT}/repo/pool/main" "${APT_ROOT}/repo/dists/stable/main/binary-amd64" \
    "${APT_ROOT}/gnupg" "${APT_ROOT}/apt-root" "${APT_ROOT}/bin"

  old_deb="${APT_ROOT}/repo/pool/main/apt-hub-go_0.0.1-1_amd64.deb"
  build_tiny_deb apt-hub-go 0.0.1-1 amd64 "${old_deb}"
  cp -a -- "${new_deb}" "${APT_ROOT}/repo/pool/main/"

  cat >"${APT_ROOT}/status-seed" <<'EOF'
Package: apt-hub-go
Status: install ok installed
Priority: optional
Section: devel
Maintainer: apt-hub-test <apt-hub-test@invalid>
Architecture: amd64
Version: 0.0.1-1
Description: old fixture

Package: golang-go
Status: install ok installed
Priority: optional
Section: devel
Maintainer: Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>
Architecture: amd64
Version: 2:1.22~2build1
Description: fixture ubuntu golang-go

EOF

  GNUPG_TEST_HOME="${APT_ROOT}/gnupg"
  if [[ -d "${GNUPG_TEST_HOME}" ]]; then
    GNUPGHOME="${GNUPG_TEST_HOME}" gpgconf --kill all >/dev/null 2>&1 || true
  fi
  rm -rf -- "${GNUPG_TEST_HOME}"
  mkdir -m 700 -- "${GNUPG_TEST_HOME}"
  export GNUPGHOME="${GNUPG_TEST_HOME}"
  gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'apt-hub-go-test <apt-hub-go-test@invalid>' default default never \
    >/dev/null 2>"${APT_ROOT}/gpg-gen.err"
  fp="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
  [[ -n "${fp}" ]]
  gpg --batch --export --armor "${fp}" >"${APT_ROOT}/repo/apt-hub-go-test.gpg"
  mkdir -p -- "${APT_ROOT}/apt-root/etc/apt/trusted.gpg.d"
  gpg --batch --export "${fp}" >"${APT_ROOT}/apt-root/etc/apt/trusted.gpg.d/apt-hub-go-test.gpg"

  (
    cd -- "${APT_ROOT}/repo"
    apt-ftparchive packages pool/main > dists/stable/main/binary-amd64/Packages
    gzip -9n -c dists/stable/main/binary-amd64/Packages > dists/stable/main/binary-amd64/Packages.gz
    apt-ftparchive \
      -o APT::FTPArchive::Release::Origin=apt-hub-go-test \
      -o APT::FTPArchive::Release::Label=apt-hub-go-test \
      -o APT::FTPArchive::Release::Suite=stable \
      -o APT::FTPArchive::Release::Codename=stable \
      -o APT::FTPArchive::Release::Architectures=amd64 \
      -o APT::FTPArchive::Release::Components=main \
      release dists/stable > dists/stable/Release
    gpg --batch --yes --pinentry-mode loopback --passphrase '' \
      --clearsign -o dists/stable/InRelease dists/stable/Release
    gpg --batch --yes --pinentry-mode loopback --passphrase '' \
      -abs -o dists/stable/Release.gpg dists/stable/Release
  )

  cat >"${APT_ROOT}/bin/dpkg" <<'EOF'
#!/bin/sh
echo "dpkg-wrapper: blocked $*" >&2
exit 1
EOF
  chmod 755 -- "${APT_ROOT}/bin/dpkg"

  ar="${APT_ROOT}/apt-root"
  mkdir -p -- \
    "${ar}/var/lib/apt/lists/partial" "${ar}/var/cache/apt/archives/partial" \
    "${ar}/var/lib/dpkg" "${ar}/var/log/apt" \
    "${ar}/etc/apt/apt.conf.d" "${ar}/etc/apt/preferences.d" \
    "${ar}/etc/apt/sources.list.d" "${ar}/etc/apt/trusted.gpg.d"
  cp -a -- "${APT_ROOT}/status-seed" "${ar}/var/lib/dpkg/status"
  : >"${ar}/var/lib/dpkg/available"
  : >"${ar}/var/lib/apt/extended_states"
  printf 'deb [signed-by=%s/etc/apt/trusted.gpg.d/apt-hub-go-test.gpg] file:%s/repo stable main\n' \
    "${ar}" "${APT_ROOT}" >"${ar}/etc/apt/sources.list"
  : >"${ar}/etc/apt/preferences"
  cat >"${ar}/etc/apt/apt.conf" <<EOF
Dir "${ar}";
Dir::State "${ar}/var/lib/apt";
Dir::State::status "${ar}/var/lib/dpkg/status";
Dir::State::extended_states "${ar}/var/lib/apt/extended_states";
Dir::State::lists "${ar}/var/lib/apt/lists";
Dir::Cache "${ar}/var/cache/apt";
Dir::Etc "${ar}/etc/apt";
Dir::Etc::Main "${ar}/etc/apt/apt.conf";
Dir::Etc::Parts "${ar}/etc/apt/apt.conf.d";
Dir::Etc::Sourcelist "${ar}/etc/apt/sources.list";
Dir::Etc::SourceParts "${ar}/etc/apt/sources.list.d";
Dir::Etc::Preferences "${ar}/etc/apt/preferences";
Dir::Etc::PreferencesParts "${ar}/etc/apt/preferences.d";
Dir::Etc::Trusted "${ar}/etc/apt/trusted.gpg";
Dir::Etc::TrustedParts "${ar}/etc/apt/trusted.gpg.d";
Dir::Bin::dpkg "${APT_ROOT}/bin/dpkg";
Dir::Log "${ar}/var/log/apt";
APT::Architecture "amd64";
APT::Architectures "amd64";
APT::Get::AllowUnauthenticated "false";
APT::Update::Error-Mode "any";
Acquire::AllowInsecureRepositories "false";
EOF

  set +e
  APT_CONFIG="${ar}/etc/apt/apt.conf" apt-get update >"${APT_ROOT}/update.log" 2>&1
  RC=$?
  set -e
  record "apt_update_${label}" "${RC}" 0
  if [[ "${RC}" -ne 0 ]]; then
    log "apt_update_${label} failed; skip subsequent upgrade checks"
    GNUPGHOME="${GNUPG_TEST_HOME}" gpgconf --kill all >/dev/null 2>&1 || true
    rm -rf -- "${GNUPG_TEST_HOME}"
    unset GNUPGHOME
    GNUPG_TEST_HOME=""
    return
  fi

  set +e
  APT_CONFIG="${ar}/etc/apt/apt.conf" apt -s upgrade >"${APT_ROOT}/apt-s-upgrade.log" 2>&1
  RC=$?
  set -e
  record "apt_s_upgrade_${label}" "${RC}" 0
  set +e
  grep -E "Inst apt-hub-go\\b.*${expect_ver}" "${APT_ROOT}/apt-s-upgrade.log" >/dev/null
  RC=$?
  set -e
  record "apt_s_selects_new_${label}" "${RC}" 0
  set +e
  grep -E 'Remv golang-go|Inst golang-go' "${APT_ROOT}/apt-s-upgrade.log" >/dev/null
  RC=$?
  set -e
  if [[ "${RC}" -eq 0 ]]; then
    record "apt_s_no_touch_ubuntu_go_${label}" 1 0
  else
    record "apt_s_no_touch_ubuntu_go_${label}" 0 0
  fi

  set +e
  APT_CONFIG="${ar}/etc/apt/apt.conf" apt-get -s upgrade >"${APT_ROOT}/aptget-s-upgrade.log" 2>&1
  RC=$?
  set -e
  record "aptget_s_upgrade_${label}" "${RC}" 0
  set +e
  grep -E "Inst apt-hub-go\\b.*${expect_ver}" "${APT_ROOT}/aptget-s-upgrade.log" >/dev/null
  RC=$?
  set -e
  record "aptget_s_selects_new_${label}" "${RC}" 0
  set +e
  grep -E 'Remv golang-go|Inst golang-go' "${APT_ROOT}/aptget-s-upgrade.log" >/dev/null
  RC=$?
  set -e
  if [[ "${RC}" -eq 0 ]]; then
    record "aptget_s_no_touch_ubuntu_go_${label}" 1 0
  else
    record "aptget_s_no_touch_ubuntu_go_${label}" 0 0
  fi

  GNUPGHOME="${GNUPG_TEST_HOME}" gpgconf --kill all >/dev/null 2>&1 || true
  rm -rf -- "${GNUPG_TEST_HOME}"
  unset GNUPGHOME
  GNUPG_TEST_HOME=""
}

# ---------- 夹具准备 ----------
FIXTURE_VER='go9.9.9'
FIXTURE_AMD_TAR="${TMP}/test/archives/${FIXTURE_VER}.linux-amd64.tar.gz"
FIXTURE_ARM_TAR="${TMP}/test/archives/${FIXTURE_VER}.linux-arm64.tar.gz"
FIXTURE_JSON="${TMP}/test/fixtures/downloads.json"
SENTINEL_IN="${TMP}/test/sentinels/input_sentinel"
SENTINEL_SIDE="${TMP}/test/sentinels/side_sentinel"

make_fixture_tree "${TMP}/test/fixtures/tree-amd64" "${FIXTURE_VER}" amd64
make_fixture_tree "${TMP}/test/fixtures/tree-arm64" "${FIXTURE_VER}" arm64
pack_fixture_archive "${TMP}/test/fixtures/tree-amd64" "${FIXTURE_AMD_TAR}"
pack_fixture_archive "${TMP}/test/fixtures/tree-arm64" "${FIXTURE_ARM_TAR}"
write_fixture_json "${FIXTURE_JSON}" "${FIXTURE_VER}" "${FIXTURE_AMD_TAR}" "${FIXTURE_ARM_TAR}"
printf 'sentinel-input\n' >"${SENTINEL_IN}"
printf 'sentinel-side\n' >"${SENTINEL_SIDE}"
cp -a -- "${SENTINEL_IN}" "${SENTINEL_IN}.orig"
cp -a -- "${SENTINEL_SIDE}" "${SENTINEL_SIDE}.orig"
cp -a -- "${FIXTURE_JSON}" "${FIXTURE_JSON}.orig"
cp -a -- "${FIXTURE_AMD_TAR}" "${FIXTURE_AMD_TAR}.orig"
cp -a -- "${FIXTURE_ARM_TAR}" "${FIXTURE_ARM_TAR}.orig"

chmod a+x -- "${BUILD}" 2>/dev/null || true

# ---------- 基础语法 / shellcheck ----------
bash -n -- "${BUILD}"
record "bash_n_build" $? 0
if [[ -n "${SHELLCHECK_BIN}" && -x "${SHELLCHECK_BIN}" ]]; then
  set +e
  "${SHELLCHECK_BIN}" -f gcc -s bash -x -- "${BUILD}"
  RC=$?
  set -e
  record "shellcheck_build" "${RC}" 0
  set +e
  "${SHELLCHECK_BIN}" -f gcc -s bash -x -- "$0"
  RC=$?
  set -e
  record "shellcheck_test" "${RC}" 0
else
  log "shellcheck missing on PATH"
  record "shellcheck_build" 1 0
  record "shellcheck_test" 1 0
fi
bash -n -- "$0"
record "bash_n_test" $? 0

# HTTPS 策略：curl 调用带 --proto '=https'（已约束 redirect；不把 --proto-redir 当漏洞补丁）
curl_lines="$(grep -cE '^[[:space:]]*curl[[:space:]]' "${BUILD}" || true)"
proto_lines="$(grep -cF -- "--proto '=https'" "${BUILD}" || true)"
if [[ "${curl_lines}" -ge 1 && "${curl_lines}" -eq "${proto_lines}" ]]; then
  record "https_proto_https_all_curl" 0 0
else
  record "https_proto_https_all_curl" 1 0
fi
if grep -F "eval " "${BUILD}" >/dev/null; then
  record "no_eval_in_build" 1 0
else
  record "no_eval_in_build" 0 0
fi

# ---------- 正常夹具构包 ----------
OUT_OK="${TMP}/out/fixture-ok"
rm -rf -- "${OUT_OK}" "${OUT_OK}.work" "${OUT_OK}.scratch" "${OUT_OK}.staging" "${OUT_OK}.hold-empty" "${OUT_OK}.lock"
mkdir -p -- "$(dirname -- "${OUT_OK}")"
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_OK}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives"
RC=$?
set -e
record "fixture_build_ok" "${RC}" 0
assert_file "${OUT_OK}/apt-hub-go_9.9.9-1_amd64.deb"
assert_file "${OUT_OK}/apt-hub-go_9.9.9-1_arm64.deb"
assert_file "${OUT_OK}/provenance.json"

set +e
dpkg-deb -f "${OUT_OK}/apt-hub-go_9.9.9-1_amd64.deb" Package | grep -Fxq 'apt-hub-go'
RC=$?
set -e
record "control_package" "${RC}" 0
set +e
dpkg-deb -f "${OUT_OK}/apt-hub-go_9.9.9-1_amd64.deb" Version | grep -Fxq '9.9.9-1'
RC=$?
set -e
record "control_version" "${RC}" 0
set +e
dpkg-deb -f "${OUT_OK}/apt-hub-go_9.9.9-1_amd64.deb" Architecture | grep -Fxq 'amd64'
RC=$?
set -e
record "control_arch_amd64" "${RC}" 0
set +e
dpkg-deb -c "${OUT_OK}/apt-hub-go_9.9.9-1_amd64.deb" | grep -q 'usr/lib/apt-hub/go/bin/go'
RC=$?
set -e
record "contents_go_tree" "${RC}" 0
set +e
dpkg-deb -c "${OUT_OK}/apt-hub-go_9.9.9-1_amd64.deb" | grep -q 'usr/bin/apt-hub-go'
RC=$?
set -e
record "contents_entrypoint" "${RC}" 0
set +e
dpkg-deb -c "${OUT_OK}/apt-hub-go_9.9.9-1_amd64.deb" | grep -E -q 'usr/bin/go$|usr/bin/gofmt$|usr/lib/go'
RC=$?
set -e
if [[ "${RC}" -eq 0 ]]; then
  record "no_ubuntu_paths" 1 0
else
  record "no_ubuntu_paths" 0 0
fi
set +e
jq -e '
  .schema_version=="1"
  and .upstream.version=="go9.9.9"
  and .upstream.version_debian=="9.9.9"
  and .upstream.revision=="1"
  and (.packages|length)==2
  and (.packages[0].size|type=="string")
  and (.packages[0].upstream.size|type=="string")
' "${OUT_OK}/provenance.json" >/dev/null
RC=$?
set -e
record "provenance_schema" "${RC}" 0

# 可复现：同输入重复构包字节相同
OUT_OK2="${TMP}/out/fixture-ok-repeat"
rm -rf -- "${OUT_OK2}" "${OUT_OK2}.work" "${OUT_OK2}.scratch" "${OUT_OK2}.staging" "${OUT_OK2}.hold-empty" "${OUT_OK2}.lock"
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_OK2}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives"
RC=$?
set -e
record "fixture_build_repeat" "${RC}" 0
set +e
assert_same_bytes "${OUT_OK}/apt-hub-go_9.9.9-1_amd64.deb" "${OUT_OK2}/apt-hub-go_9.9.9-1_amd64.deb"
RC=$?
set -e
record "repro_amd64_bytes" "${RC}" 0
set +e
assert_same_bytes "${OUT_OK}/apt-hub-go_9.9.9-1_arm64.deb" "${OUT_OK2}/apt-hub-go_9.9.9-1_arm64.deb"
RC=$?
set -e
record "repro_arm64_bytes" "${RC}" 0

# 同 archive 不同本地 mtime → deb 字节相同
MT_A="${TMP}/test/archives-mtime-a"
MT_B="${TMP}/test/archives-mtime-b"
rm -rf -- "${MT_A}" "${MT_B}"
mkdir -p -- "${MT_A}" "${MT_B}"
cp -a -- "${FIXTURE_AMD_TAR}" "${MT_A}/"
cp -a -- "${FIXTURE_ARM_TAR}" "${MT_A}/"
cp -a -- "${FIXTURE_AMD_TAR}" "${MT_B}/"
cp -a -- "${FIXTURE_ARM_TAR}" "${MT_B}/"
touch -d '@1600000000' -- "${MT_A}/${FIXTURE_VER}.linux-amd64.tar.gz" "${MT_A}/${FIXTURE_VER}.linux-arm64.tar.gz"
touch -d '@1800000000' -- "${MT_B}/${FIXTURE_VER}.linux-amd64.tar.gz" "${MT_B}/${FIXTURE_VER}.linux-arm64.tar.gz"
OUT_MT_A="${TMP}/out/mtime-a"
OUT_MT_B="${TMP}/out/mtime-b"
rm -rf -- "${OUT_MT_A}" "${OUT_MT_A}.work" "${OUT_MT_A}.scratch" "${OUT_MT_A}.staging" "${OUT_MT_A}.hold-empty" "${OUT_MT_A}.lock"
rm -rf -- "${OUT_MT_B}" "${OUT_MT_B}.work" "${OUT_MT_B}.scratch" "${OUT_MT_B}.staging" "${OUT_MT_B}.hold-empty" "${OUT_MT_B}.lock"
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_MT_A}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${MT_A}"
RC=$?
set -e
record "mtime_build_a" "${RC}" 0
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_MT_B}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${MT_B}"
RC=$?
set -e
record "mtime_build_b" "${RC}" 0
set +e
assert_same_bytes "${OUT_MT_A}/apt-hub-go_9.9.9-1_amd64.deb" "${OUT_MT_B}/apt-hub-go_9.9.9-1_amd64.deb"
RC=$?
set -e
record "mtime_invariant_amd64" "${RC}" 0
set +e
assert_same_bytes "${OUT_MT_A}/apt-hub-go_9.9.9-1_arm64.deb" "${OUT_MT_B}/apt-hub-go_9.9.9-1_arm64.deb"
RC=$?
set -e
record "mtime_invariant_arm64" "${RC}" 0

# 无 VERSION time：认证内部 mtime 固定；改本地 archive mtime/umask 仍同字节
NT_ROOT_A="${TMP}/test/fixtures/no-time-a"
NT_ROOT_B="${TMP}/test/fixtures/no-time-b"
NT_ARCH_A="${TMP}/test/archives-mtime-notime-a"
NT_ARCH_B="${TMP}/test/archives-mtime-notime-b"
rm -rf -- "${NT_ROOT_A}" "${NT_ROOT_B}" "${NT_ARCH_A}" "${NT_ARCH_B}"
mkdir -p -- "${NT_ARCH_A}" "${NT_ARCH_B}"
make_fixture_tree "${NT_ROOT_A}" "${FIXTURE_VER}" amd64
make_fixture_tree "${NT_ROOT_B}" "${FIXTURE_VER}" arm64
# 仅首行版本，无 time 行；内部成员 mtime 由 pack 固定
printf '%s\n' "${FIXTURE_VER}" >"${NT_ROOT_A}/go/VERSION"
printf '%s\n' "${FIXTURE_VER}" >"${NT_ROOT_B}/go/VERSION"
NT_AMD="${NT_ARCH_A}/${FIXTURE_VER}.linux-amd64.tar.gz"
NT_ARM="${NT_ARCH_A}/${FIXTURE_VER}.linux-arm64.tar.gz"
pack_fixture_archive "${NT_ROOT_A}" "${NT_AMD}" 1700000000
pack_fixture_archive "${NT_ROOT_B}" "${NT_ARM}" 1700000000
cp -a -- "${NT_AMD}" "${NT_ARCH_B}/"
cp -a -- "${NT_ARM}" "${NT_ARCH_B}/"
NT_JSON="${TMP}/test/fixtures/no-time-downloads.json"
write_fixture_json "${NT_JSON}" "${FIXTURE_VER}" "${NT_AMD}" "${NT_ARM}"
( umask 022; touch -d '@1600000000' -- "${NT_ARCH_A}/${FIXTURE_VER}.linux-amd64.tar.gz" "${NT_ARCH_A}/${FIXTURE_VER}.linux-arm64.tar.gz" )
( umask 077; touch -d '@1800000000' -- "${NT_ARCH_B}/${FIXTURE_VER}.linux-amd64.tar.gz" "${NT_ARCH_B}/${FIXTURE_VER}.linux-arm64.tar.gz" )
OUT_NT_A="${TMP}/out/mtime-notime-a"
OUT_NT_B="${TMP}/out/mtime-notime-b"
rm -rf -- "${OUT_NT_A}" "${OUT_NT_A}.work" "${OUT_NT_A}.scratch" "${OUT_NT_A}.staging" "${OUT_NT_A}.lock" "${OUT_NT_A}.hold-empty"
rm -rf -- "${OUT_NT_B}" "${OUT_NT_B}.work" "${OUT_NT_B}.scratch" "${OUT_NT_B}.staging" "${OUT_NT_B}.lock" "${OUT_NT_B}.hold-empty"
set +e
( umask 022; "${BUILD}" --config "${CONFIG}" --output "${OUT_NT_A}" \
  --downloads-json "${NT_JSON}" --archive-dir "${NT_ARCH_A}" )
RC=$?
set -e
record "mtime_notime_build_a" "${RC}" 0
set +e
( umask 077; "${BUILD}" --config "${CONFIG}" --output "${OUT_NT_B}" \
  --downloads-json "${NT_JSON}" --archive-dir "${NT_ARCH_B}" )
RC=$?
set -e
record "mtime_notime_build_b" "${RC}" 0
set +e
assert_same_bytes "${OUT_NT_A}/apt-hub-go_9.9.9-1_amd64.deb" "${OUT_NT_B}/apt-hub-go_9.9.9-1_amd64.deb"
RC=$?
set -e
record "mtime_notime_invariant_amd64" "${RC}" 0
set +e
assert_same_bytes "${OUT_NT_A}/apt-hub-go_9.9.9-1_arm64.deb" "${OUT_NT_B}/apt-hub-go_9.9.9-1_arm64.deb"
RC=$?
set -e
record "mtime_notime_invariant_arm64" "${RC}" 0

# ---------- 失败路径 ----------
expect_fail_preserve() {
  local name="$1"
  shift
  local out="${TMP}/out/fail-${name}"
  rm -rf -- "${out}" "${out}.work" "${out}.scratch" "${out}.staging" "${out}.hold-empty" "${out}.lock"
  set +e
  "$@" --output "${out}"
  RC=$?
  set -e
  record "fail_${name}" "${RC}" 1
  set +e
  cmp -s -- "${SENTINEL_IN}" "${SENTINEL_IN}.orig"
  RC=$?
  set -e
  record "sentinel_in_${name}" "${RC}" 0
  set +e
  cmp -s -- "${SENTINEL_SIDE}" "${SENTINEL_SIDE}.orig"
  RC=$?
  set -e
  record "sentinel_side_${name}" "${RC}" 0
  set +e
  cmp -s -- "${FIXTURE_JSON}" "${FIXTURE_JSON}.orig"
  RC=$?
  set -e
  record "json_preserved_${name}" "${RC}" 0
  set +e
  cmp -s -- "${FIXTURE_AMD_TAR}" "${FIXTURE_AMD_TAR}.orig"
  RC=$?
  set -e
  record "amd_tar_preserved_${name}" "${RC}" 0
  # 失败不得在 output 留下 deb/provenance
  set +e
  find -- "${out}" -type f \( -name '*.deb' -o -name 'provenance.json' \) 2>/dev/null | grep -q .
  RC=$?
  set -e
  if [[ "${RC}" -eq 0 ]]; then
    record "no_partial_${name}" 1 0
  else
    record "no_partial_${name}" 0 0
  fi
}

# bad sha
BAD_JSON="${TMP}/test/fixtures/bad-sha.json"
jq '.[0].files[0].sha256 = ("a"*64)' "${FIXTURE_JSON}" >"${BAD_JSON}"
expect_fail_preserve bad_sha \
  "${BUILD}" --config "${CONFIG}" --downloads-json "${BAD_JSON}" --archive-dir "${TMP}/test/archives"

# bad size
BAD_JSON="${TMP}/test/fixtures/bad-size.json"
jq '.[0].files[0].size = 1' "${FIXTURE_JSON}" >"${BAD_JSON}"
expect_fail_preserve bad_size \
  "${BUILD}" --config "${CONFIG}" --downloads-json "${BAD_JSON}" --archive-dir "${TMP}/test/archives"

# metadata ambiguity：同 arch 两条 archive
BAD_JSON="${TMP}/test/fixtures/ambiguous.json"
jq '.[0].files += [.[0].files[0]]' "${FIXTURE_JSON}" >"${BAD_JSON}"
expect_fail_preserve ambiguous_meta \
  "${BUILD}" --config "${CONFIG}" --downloads-json "${BAD_JSON}" --archive-dir "${TMP}/test/archives"

# bad version tag
BAD_JSON="${TMP}/test/fixtures/bad-version.json"
jq 'map(.stable=false) | . + [{"version":"go1.99.0-rc1","stable":true,"files":[{"filename":"go1.99.0-rc1.linux-amd64.tar.gz","os":"linux","arch":"amd64","version":"go1.99.0-rc1","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":10,"kind":"archive"},{"filename":"go1.99.0-rc1.linux-arm64.tar.gz","os":"linux","arch":"arm64","version":"go1.99.0-rc1","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","size":10,"kind":"archive"}]}]' "${FIXTURE_JSON}" >"${BAD_JSON}"
expect_fail_preserve bad_version \
  "${BUILD}" --config "${CONFIG}" --downloads-json "${BAD_JSON}" --archive-dir "${TMP}/test/archives"

# LICENSE 缺失
NOLIC_DIR="${TMP}/test/fixtures/no-license"
make_fixture_tree "${NOLIC_DIR}" "${FIXTURE_VER}" amd64
rm -f -- "${NOLIC_DIR}/go/LICENSE"
NOLIC_TAR="${TMP}/test/archives-nolic/${FIXTURE_VER}.linux-amd64.tar.gz"
mkdir -p -- "$(dirname -- "${NOLIC_TAR}")"
pack_fixture_archive "${NOLIC_DIR}" "${NOLIC_TAR}"
cp -a -- "${FIXTURE_ARM_TAR}" "$(dirname -- "${NOLIC_TAR}")/"
BAD_JSON="${TMP}/test/fixtures/no-license.json"
write_fixture_json "${BAD_JSON}" "${FIXTURE_VER}" "${NOLIC_TAR}" "${FIXTURE_ARM_TAR}"
expect_fail_preserve missing_license \
  "${BUILD}" --config "${CONFIG}" --downloads-json "${BAD_JSON}" --archive-dir "$(dirname -- "${NOLIC_TAR}")"

# wrong ELF arch
WRONG_ELF_DIR="${TMP}/test/fixtures/wrong-elf"
make_fixture_tree "${WRONG_ELF_DIR}" "${FIXTURE_VER}" arm64
WRONG_ELF_TAR="${TMP}/test/archives-wrong-elf/${FIXTURE_VER}.linux-amd64.tar.gz"
mkdir -p -- "$(dirname -- "${WRONG_ELF_TAR}")"
pack_fixture_archive "${WRONG_ELF_DIR}" "${WRONG_ELF_TAR}"
cp -a -- "${FIXTURE_ARM_TAR}" "$(dirname -- "${WRONG_ELF_TAR}")/"
BAD_JSON="${TMP}/test/fixtures/wrong-elf.json"
write_fixture_json "${BAD_JSON}" "${FIXTURE_VER}" "${WRONG_ELF_TAR}" "${FIXTURE_ARM_TAR}"
expect_fail_preserve bad_elf \
  "${BUILD}" --config "${CONFIG}" --downloads-json "${BAD_JSON}" --archive-dir "$(dirname -- "${WRONG_ELF_TAR}")"

# path traversal
EVIL_TAR="${TMP}/test/archives-evil/go9.9.9.linux-amd64.tar.gz"
mkdir -p -- "$(dirname -- "${EVIL_TAR}")"
rm -rf -- "${TMP}/test/fixtures/evil-root"
mkdir -p -- "${TMP}/test/fixtures/evil-root/go/bin" "${TMP}/test/fixtures/evil-root/go/pkg/tool/linux_amd64"
printf '%s\ntime 2023-11-14T00:00:00Z\n' "${FIXTURE_VER}" >"${TMP}/test/fixtures/evil-root/go/VERSION"
printf 'TEST FIXTURE LICENSE — not official Go\n' >"${TMP}/test/fixtures/evil-root/go/LICENSE"
write_min_elf "${TMP}/test/fixtures/evil-root/go/bin/go" amd64
write_min_elf "${TMP}/test/fixtures/evil-root/go/bin/gofmt" amd64
write_min_elf "${TMP}/test/fixtures/evil-root/go/pkg/tool/linux_amd64/compile" amd64
printf 'evil\n' >"${TMP}/test/fixtures/evil-root/evil.txt"
(
  cd -- "${TMP}/test/fixtures/evil-root"
  tar --transform='s|^evil.txt|go/../evil.txt|' -czf "${EVIL_TAR}" go evil.txt
)
cp -a -- "${FIXTURE_ARM_TAR}" "$(dirname -- "${EVIL_TAR}")/"
BAD_JSON="${TMP}/test/fixtures/evil-trav.json"
write_fixture_json "${BAD_JSON}" "${FIXTURE_VER}" "${EVIL_TAR}" "${FIXTURE_ARM_TAR}"
expect_fail_preserve path_traversal \
  "${BUILD}" --config "${CONFIG}" --downloads-json "${BAD_JSON}" --archive-dir "$(dirname -- "${EVIL_TAR}")"

# symlink in archive
SYM_ROOT="${TMP}/test/fixtures/sym-root"
rm -rf -- "${SYM_ROOT}"
make_fixture_tree "${SYM_ROOT}" "${FIXTURE_VER}" amd64
ln -s -- "go" "${SYM_ROOT}/go/bin/link-evil"
SYM_TAR="${TMP}/test/archives-sym/${FIXTURE_VER}.linux-amd64.tar.gz"
mkdir -p -- "$(dirname -- "${SYM_TAR}")"
(
  cd -- "${SYM_ROOT}"
  tar --mtime='@1700000000' --owner=0 --group=0 --numeric-owner -czf "${SYM_TAR}" go
)
touch -d '@1700000000' -- "${SYM_TAR}"
cp -a -- "${FIXTURE_ARM_TAR}" "$(dirname -- "${SYM_TAR}")/"
BAD_JSON="${TMP}/test/fixtures/sym.json"
write_fixture_json "${BAD_JSON}" "${FIXTURE_VER}" "${SYM_TAR}" "${FIXTURE_ARM_TAR}"
expect_fail_preserve symlink_member \
  "${BUILD}" --config "${CONFIG}" --downloads-json "${BAD_JSON}" --archive-dir "$(dirname -- "${SYM_TAR}")"

# FIFO member
FIFO_ROOT="${TMP}/test/fixtures/fifo-root"
rm -rf -- "${FIFO_ROOT}"
make_fixture_tree "${FIFO_ROOT}" "${FIXTURE_VER}" amd64
mkfifo -- "${FIFO_ROOT}/go/fifo-evil"
FIFO_TAR="${TMP}/test/archives-fifo/${FIXTURE_VER}.linux-amd64.tar.gz"
mkdir -p -- "$(dirname -- "${FIFO_TAR}")"
(
  cd -- "${FIFO_ROOT}"
  tar --mtime='@1700000000' --owner=0 --group=0 --numeric-owner -czf "${FIFO_TAR}" go
)
touch -d '@1700000000' -- "${FIFO_TAR}"
cp -a -- "${FIXTURE_ARM_TAR}" "$(dirname -- "${FIFO_TAR}")/"
BAD_JSON="${TMP}/test/fixtures/fifo.json"
write_fixture_json "${BAD_JSON}" "${FIXTURE_VER}" "${FIFO_TAR}" "${FIXTURE_ARM_TAR}"
expect_fail_preserve fifo_member \
  "${BUILD}" --config "${CONFIG}" --downloads-json "${BAD_JSON}" --archive-dir "$(dirname -- "${FIFO_TAR}")"

# 第二 arch 错 sha：失败后 output 无 deb/provenance
BAD_JSON="${TMP}/test/fixtures/second-arch-bad.json"
jq '.[0].files[1].sha256 = ("0"*64)' "${FIXTURE_JSON}" >"${BAD_JSON}"
OUT_PARTIAL="${TMP}/out/partial-second-arch"
rm -rf -- "${OUT_PARTIAL}" "${OUT_PARTIAL}.work" "${OUT_PARTIAL}.scratch" "${OUT_PARTIAL}.staging" "${OUT_PARTIAL}.hold-empty" "${OUT_PARTIAL}.lock"
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_PARTIAL}" \
  --downloads-json "${BAD_JSON}" --archive-dir "${TMP}/test/archives"
RC=$?
set -e
record "fail_second_arch_sha" "${RC}" 1
set +e
find -- "${OUT_PARTIAL}" -type f \( -name '*.deb' -o -name 'provenance.json' \) 2>/dev/null | grep -q .
RC=$?
set -e
if [[ "${RC}" -eq 0 ]]; then
  record "no_partial_second_arch" 1 0
else
  record "no_partial_second_arch" 0 0
fi

# lock 路径命令注入：字面 $(...) 不得执行 sentinel；record 必须在父 shell
LOCK_INJECT_DIR="${TMP}/out"
LOCK_SENTINEL="${TMP}/test/sentinels/LOCK_PATH_EXECUTED"
rm -f -- "${LOCK_SENTINEL}" "${ROOT}/LOCK_PATH_EXECUTED" "${TMP}/test/sentinels/LOCK_PATH_EXECUTED"
# shellcheck disable=SC2016
OUT_INJECT_LITERAL='out-$(touch${IFS}LOCK_PATH_EXECUTED)'
rm -rf -- "${LOCK_INJECT_DIR:?}/${OUT_INJECT_LITERAL:?}" \
  "${LOCK_INJECT_DIR:?}/${OUT_INJECT_LITERAL:?}.work" \
  "${LOCK_INJECT_DIR:?}/${OUT_INJECT_LITERAL:?}.scratch" \
  "${LOCK_INJECT_DIR:?}/${OUT_INJECT_LITERAL:?}.staging" \
  "${LOCK_INJECT_DIR:?}/${OUT_INJECT_LITERAL:?}.hold-empty" \
  "${LOCK_INJECT_DIR:?}/${OUT_INJECT_LITERAL:?}.lock" \
  "${LOCK_INJECT_DIR:?}/out-.lock"
set +e
(
  cd -- "${TMP}/test/sentinels"
  "${BUILD}" --config "${CONFIG}" \
    --output "${LOCK_INJECT_DIR}/${OUT_INJECT_LITERAL}" \
    --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives"
)
RC=$?
set -e
log "lock_inject_build_rc=${RC}"
if [[ -e "${LOCK_SENTINEL}" || -e "${ROOT}/LOCK_PATH_EXECUTED" || -e "${TMP}/test/sentinels/LOCK_PATH_EXECUTED" ]]; then
  record "lock_path_no_exec" 1 0
else
  record "lock_path_no_exec" 0 0
fi

# output symlink
OUT_SYM="${TMP}/out/sym-out"
rm -rf -- "${OUT_SYM}" "${OUT_SYM}.lock" "${TMP}/out/sym-target"
mkdir -p -- "${TMP}/out/sym-target"
ln -s -- "${TMP}/out/sym-target" "${OUT_SYM}"
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_SYM}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives"
RC=$?
set -e
record "fail_output_symlink" "${RC}" 1

# non-empty output
OUT_NE="${TMP}/out/nonempty"
rm -rf -- "${OUT_NE}" "${OUT_NE}.lock"
mkdir -p -- "${OUT_NE}"
printf 'x\n' >"${OUT_NE}/keep"
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_NE}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives"
RC=$?
set -e
record "fail_output_nonempty" "${RC}" 1
if [[ -f "${OUT_NE}/keep" ]]; then
  record "nonempty_preserved" 0 0
else
  record "nonempty_preserved" 1 0
fi

# overlap archive-dir inside output
set +e
"${BUILD}" --config "${CONFIG}" --output "${TMP}/test/archives/nested-out" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives"
RC=$?
set -e
record "fail_overlap" "${RC}" 1

# concurrent lock
OUT_LOCK="${TMP}/out/lock-test"
rm -rf -- "${OUT_LOCK}" "${OUT_LOCK}.work" "${OUT_LOCK}.scratch" "${OUT_LOCK}.staging" "${OUT_LOCK}.hold-empty" "${OUT_LOCK}.lock"
mkdir -p -- "$(dirname -- "${OUT_LOCK}")"
exec 8>>"${OUT_LOCK}.lock"
flock -n 8
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_LOCK}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives"
RC=$?
set -e
record "fail_concurrent_lock" "${RC}" 1
exec 8>&-

# find 枚举失败：已有用户内容 + find exit2 空 stdout → 拒绝且无副作用
OUT_FIND="${TMP}/out/find-deny"
rm -rf -- "${OUT_FIND}" "${OUT_FIND}.work" "${OUT_FIND}.scratch" "${OUT_FIND}.staging" "${OUT_FIND}.hold-empty" "${OUT_FIND}.lock"
mkdir -m 700 -- "${OUT_FIND}"
printf 'user-keep\n' >"${OUT_FIND}/provenance.json"
FIND_BEFORE="$(sha256sum -- "${OUT_FIND}/provenance.json" | awk '{print $1}')"
FIND_MODE_BEFORE="$(stat -c '%a' -- "${OUT_FIND}")"
REAL_FIND="$(command -v find)"
mkdir -p -- "${TMP}/test/bin"
cat >"${TMP}/test/bin/find" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [[ "\$a" == "${OUT_FIND}" ]]; then
    echo "find: \$a: Permission denied" >&2
    exit 2
  fi
done
exec "${REAL_FIND}" "\$@"
EOF
chmod 755 -- "${TMP}/test/bin/find"
set +e
PATH="${TMP}/test/bin:${PATH}" "${BUILD}" --config "${CONFIG}" --output "${OUT_FIND}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives" \
  >"${TMP}/test/find-deny.log" 2>&1
RC=$?
set -e
record "fail_find_enumerate" "${RC}" 1
FIND_AFTER="$(sha256sum -- "${OUT_FIND}/provenance.json" | awk '{print $1}')"
FIND_MODE_AFTER="$(stat -c '%a' -- "${OUT_FIND}")"
if [[ "${FIND_BEFORE}" == "${FIND_AFTER}" && "${FIND_MODE_BEFORE}" == "${FIND_MODE_AFTER}" \
  && ! -L "${OUT_FIND}/provenance.json" && -d "${OUT_FIND}" ]]; then
  record "find_deny_no_side_effect" 0 0
else
  record "find_deny_no_side_effect" 1 0
fi
rm -f -- "${TMP}/test/bin/find"

# 构包中途最终路径不可见半成品（后台观察）；成功则一次完整提交
OUT_ATOM="${TMP}/out/atomic-commit"
rm -rf -- "${OUT_ATOM}" "${OUT_ATOM}.work" "${OUT_ATOM}.scratch" "${OUT_ATOM}.staging" "${OUT_ATOM}.hold-empty" "${OUT_ATOM}.lock"
mkdir -p -- "$(dirname -- "${OUT_ATOM}")"
ATOM_OBS="${TMP}/test/atomic-observation.txt"
: >"${ATOM_OBS}"
(
  while [[ ! -f "${TMP}/test/atomic-watch-stop" ]]; do
    if compgen -G "${OUT_ATOM}/*.deb" >/dev/null 2>&1; then
      if [[ ! -f "${OUT_ATOM}/provenance.json" ]]; then
        echo "partial_visible_before_provenance=yes" >>"${ATOM_OBS}"
      fi
    fi
    sleep 0.05
  done
) &
ATOM_WATCH_PID=$!
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_ATOM}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives"
RC=$?
set -e
: >"${TMP}/test/atomic-watch-stop"
wait "${ATOM_WATCH_PID}" 2>/dev/null || true
rm -f -- "${TMP}/test/atomic-watch-stop"
record "atomic_build_ok" "${RC}" 0
if [[ -f "${OUT_ATOM}/apt-hub-go_9.9.9-1_amd64.deb" \
  && -f "${OUT_ATOM}/apt-hub-go_9.9.9-1_arm64.deb" \
  && -f "${OUT_ATOM}/provenance.json" ]]; then
  record "atomic_full_commit" 0 0
else
  record "atomic_full_commit" 1 0
fi
if grep -q 'partial_visible_before_provenance=yes' "${ATOM_OBS}" 2>/dev/null; then
  record "atomic_no_partial_observed" 1 0
else
  record "atomic_no_partial_observed" 0 0
fi

# 预置空 output：rename 失败时保持空目录与原权限
OUT_REN="${TMP}/out/rename-fail"
rm -rf -- "${OUT_REN}" "${OUT_REN}.work" "${OUT_REN}.scratch" "${OUT_REN}.staging" "${OUT_REN}.hold-empty" "${OUT_REN}.lock"
mkdir -m 700 -- "${OUT_REN}"
REN_MODE_BEFORE="$(stat -c '%a' -- "${OUT_REN}")"
# 预置冲突 hold-empty，迫使提交路径拒绝且不改空 output
mkdir -m 755 -- "${OUT_REN}.hold-empty"
set +e
"${BUILD}" --config "${CONFIG}" --output "${OUT_REN}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives" \
  >"${TMP}/test/rename-fail.log" 2>&1
RC=$?
set -e
record "fail_rename_preexisting_hold" "${RC}" 1
REN_MODE_AFTER="$(stat -c '%a' -- "${OUT_REN}")"
set +e
find -- "${OUT_REN}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
RC_NE=$?
set -e
if [[ "${REN_MODE_BEFORE}" == "${REN_MODE_AFTER}" && "${RC_NE}" -ne 0 ]]; then
  record "rename_fail_empty_preserved" 0 0
else
  record "rename_fail_empty_preserved" 1 0
fi

# 认证树 cp 失败：非 0 且无成功 deb/provenance
OUT_CP="${TMP}/out/cp-fail"
rm -rf -- "${OUT_CP}" "${OUT_CP}.work" "${OUT_CP}.scratch" "${OUT_CP}.staging" "${OUT_CP}.hold-empty" "${OUT_CP}.lock"
REAL_CP="$(command -v cp)"
cat >"${TMP}/test/bin/cp" <<EOF
#!/bin/bash
if [[ "\$*" == *"/usr/lib/apt-hub/go"* ]]; then
  echo "test: injected verified-tree copy failure" >&2
  exit 24
fi
exec "${REAL_CP}" "\$@"
EOF
chmod 755 -- "${TMP}/test/bin/cp"
set +e
PATH="${TMP}/test/bin:${PATH}" "${BUILD}" --config "${CONFIG}" --output "${OUT_CP}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives" \
  >"${TMP}/test/cp-fail.log" 2>&1
RC=$?
set -e
record "fail_cp_tree" "${RC}" 1
set +e
find -- "${OUT_CP}" -type f \( -name '*.deb' -o -name 'provenance.json' \) 2>/dev/null | grep -q .
RC=$?
set -e
if [[ "${RC}" -eq 0 ]]; then
  record "cp_fail_no_output" 1 0
else
  record "cp_fail_no_output" 0 0
fi
rm -f -- "${TMP}/test/bin/cp"

# 架构枚举 jq 失败不得被 mapfile/进程替换吞掉（完整入口）
REAL_JQ="$(command -v jq)"
assert_arch_enum_jq_fail() {
  local name="$1" mode="$2"
  local out="${TMP}/out/fail-${name}"
  local logf="${TMP}/test/${name}.log"
  rm -rf -- "${out}" "${out}.work" "${out}.scratch" "${out}.staging" "${out}.hold-empty" "${out}.lock"
  rm -f -- "${TMP}/test/bin/jq"
  case "${mode}" in
    partial24)
      cat >"${TMP}/test/bin/jq" <<EOF
#!/bin/bash
if [[ "\${1:-}" == -r && "\${2:-}" == '.architectures[]' ]]; then
  printf 'amd64\n'
  exit 24
fi
exec "${REAL_JQ}" "\$@"
EOF
      ;;
    empty25)
      cat >"${TMP}/test/bin/jq" <<EOF
#!/bin/bash
if [[ "\${1:-}" == -r && "\${2:-}" == '.architectures[]' ]]; then
  exit 25
fi
exec "${REAL_JQ}" "\$@"
EOF
      ;;
    *)
      log "未知 arch-enum 故障模式 ${mode}"
      return 1
      ;;
  esac
  chmod 755 -- "${TMP}/test/bin/jq"
  set +e
  PATH="${TMP}/test/bin:${PATH}" "${BUILD}" --config "${CONFIG}" --output "${out}" \
    --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives" \
    >"${logf}" 2>&1
  RC=$?
  set -e
  # 断言必须在父 shell 计数，不得在子 shell 里 record。
  if [[ "${RC}" -ne 0 ]]; then
    record "fail_${name}" 0 0
  else
    record "fail_${name}" 1 0
  fi
  set +e
  cmp -s -- "${SENTINEL_IN}" "${SENTINEL_IN}.orig"
  RC=$?
  set -e
  record "sentinel_in_${name}" "${RC}" 0
  set +e
  cmp -s -- "${SENTINEL_SIDE}" "${SENTINEL_SIDE}.orig"
  RC=$?
  set -e
  record "sentinel_side_${name}" "${RC}" 0
  set +e
  find -- "${out}" -type f \( -name '*.deb' -o -name 'provenance.json' \) 2>/dev/null | grep -q .
  RC=$?
  set -e
  if [[ "${RC}" -eq 0 ]]; then
    record "no_partial_${name}" 1 0
  else
    record "no_partial_${name}" 0 0
  fi
  set +e
  grep -F 'ok packages=' "${logf}" >/dev/null
  RC=$?
  set -e
  if [[ "${RC}" -eq 0 ]]; then
    record "no_success_${name}" 1 0
  else
    record "no_success_${name}" 0 0
  fi
  rm -f -- "${TMP}/test/bin/jq"
}
assert_arch_enum_jq_fail arch_enum_partial24 partial24
assert_arch_enum_jq_fail arch_enum_empty25 empty25

# 单 arch 合法配置仍可用（不硬编码只能两项）
CFG_ONE="${TMP}/test/fixtures/go-one-arch.json"
jq '.architectures=["amd64"]' "${CONFIG}" >"${CFG_ONE}"
OUT_ONE="${TMP}/out/fixture-one-arch"
rm -rf -- "${OUT_ONE}" "${OUT_ONE}.work" "${OUT_ONE}.scratch" "${OUT_ONE}.staging" "${OUT_ONE}.hold-empty" "${OUT_ONE}.lock"
set +e
"${BUILD}" --config "${CFG_ONE}" --output "${OUT_ONE}" \
  --downloads-json "${FIXTURE_JSON}" --archive-dir "${TMP}/test/archives" \
  >"${TMP}/test/one-arch.log" 2>&1
RC=$?
set -e
record "fixture_one_arch_ok" "${RC}" 0
set +e
[[ -f "${OUT_ONE}/apt-hub-go_9.9.9-1_amd64.deb" && ! -f "${OUT_ONE}/apt-hub-go_9.9.9-1_arm64.deb" ]]
RC=$?
set -e
record "one_arch_deb_set" "${RC}" 0
set +e
jq -e --argjson want '["amd64"]' '
  ([.packages[].architecture]|sort) == ($want|sort)
  and (.packages|length)==($want|length)
' "${OUT_ONE}/provenance.json" >/dev/null
RC=$?
set -e
record "one_arch_provenance" "${RC}" 0

# ---------- 默认：夹具签名 APT（两版本比较，不伪装系统安装） ----------
run_isolated_apt_upgrade \
  "${OUT_OK}/apt-hub-go_9.9.9-1_amd64.deb" \
  "9.9.9-1" \
  "fixture"

# ---------- 可选 live：现有缓存真官方 ----------
if [[ "${LIVE}" -eq 1 ]]; then
  assert_file "${LIVE_DOWNLOADS_JSON}"
  [[ -d "${LIVE_ARCHIVE_DIR}" && ! -L "${LIVE_ARCHIVE_DIR}" ]] \
    || { log "live archive-dir 非法"; exit 1; }

  OFFICIAL_AMD_NAME="$(jq -r '
    [.[] | select(.stable==true)] | max_by(.version|ltrimstr("go")|split(".")|map(tonumber))
    | .files[] | select(.os=="linux" and .arch=="amd64" and .kind=="archive") | .filename
  ' "${LIVE_DOWNLOADS_JSON}")"
  OFFICIAL_AMD_SHA="$(jq -r --arg f "${OFFICIAL_AMD_NAME}" '
    .[] | .files[]? | select(.filename==$f) | .sha256
  ' "${LIVE_DOWNLOADS_JSON}")"
  OFFICIAL_AMD_SIZE="$(jq -r --arg f "${OFFICIAL_AMD_NAME}" '
    .[] | .files[]? | select(.filename==$f) | (.size|tostring)
  ' "${LIVE_DOWNLOADS_JSON}")"
  OFFICIAL_ARM_NAME="$(jq -r '
    [.[] | select(.stable==true)] | max_by(.version|ltrimstr("go")|split(".")|map(tonumber))
    | .files[] | select(.os=="linux" and .arch=="arm64" and .kind=="archive") | .filename
  ' "${LIVE_DOWNLOADS_JSON}")"
  OFFICIAL_ARM_SHA="$(jq -r --arg f "${OFFICIAL_ARM_NAME}" '
    .[] | .files[]? | select(.filename==$f) | .sha256
  ' "${LIVE_DOWNLOADS_JSON}")"
  OFFICIAL_ARM_SIZE="$(jq -r --arg f "${OFFICIAL_ARM_NAME}" '
    .[] | .files[]? | select(.filename==$f) | (.size|tostring)
  ' "${LIVE_DOWNLOADS_JSON}")"

  log "official_amd=${OFFICIAL_AMD_NAME} sha=${OFFICIAL_AMD_SHA} size=${OFFICIAL_AMD_SIZE}"
  log "official_arm=${OFFICIAL_ARM_NAME} sha=${OFFICIAL_ARM_SHA} size=${OFFICIAL_ARM_SIZE}"
  log "live_no_redownload=1 archive_dir=${LIVE_ARCHIVE_DIR}"

  got_amd_sha="$(sha256sum -- "${LIVE_ARCHIVE_DIR}/${OFFICIAL_AMD_NAME}" | awk '{print $1}')"
  got_amd_size="$(stat -c '%s' -- "${LIVE_ARCHIVE_DIR}/${OFFICIAL_AMD_NAME}")"
  if [[ "${got_amd_sha}" == "${OFFICIAL_AMD_SHA}" && "${got_amd_size}" == "${OFFICIAL_AMD_SIZE}" ]]; then
    record "official_amd_archive_verified" 0 0
  else
    record "official_amd_archive_verified" 1 0
  fi
  got_arm_sha="$(sha256sum -- "${LIVE_ARCHIVE_DIR}/${OFFICIAL_ARM_NAME}" | awk '{print $1}')"
  got_arm_size="$(stat -c '%s' -- "${LIVE_ARCHIVE_DIR}/${OFFICIAL_ARM_NAME}")"
  if [[ "${got_arm_sha}" == "${OFFICIAL_ARM_SHA}" && "${got_arm_size}" == "${OFFICIAL_ARM_SIZE}" ]]; then
    record "official_arm_archive_verified" 0 0
  else
    record "official_arm_archive_verified" 1 0
  fi

  OUT_OFF="${TMP}/out/official"
  rm -rf -- "${OUT_OFF}" "${OUT_OFF}.work" "${OUT_OFF}.scratch" "${OUT_OFF}.staging" "${OUT_OFF}.hold-empty" "${OUT_OFF}.lock"
  set +e
  "${BUILD}" --config "${CONFIG}" --output "${OUT_OFF}" \
    --downloads-json "${LIVE_DOWNLOADS_JSON}" --archive-dir "${LIVE_ARCHIVE_DIR}"
  RC=$?
  set -e
  record "official_build" "${RC}" 0

  OFF_VER_DEB="$(jq -r '.packages[] | select(.architecture=="amd64") | .version' "${OUT_OFF}/provenance.json")"
  OFF_AMD_DEB="${OUT_OFF}/apt-hub-go_${OFF_VER_DEB}_amd64.deb"
  OFF_ARM_DEB="${OUT_OFF}/apt-hub-go_${OFF_VER_DEB}_arm64.deb"
  assert_file "${OFF_AMD_DEB}"
  assert_file "${OFF_ARM_DEB}"
  log "official_deb_amd_sha=$(sha256sum -- "${OFF_AMD_DEB}" | awk '{print $1}')"
  log "official_deb_arm_sha=$(sha256sum -- "${OFF_ARM_DEB}" | awk '{print $1}')"

  EXTRACT_ARM="${TMP}/extract-official/arm64"
  rm -rf -- "${EXTRACT_ARM}"
  mkdir -p -- "${EXTRACT_ARM}"
  dpkg-deb -x "${OFF_ARM_DEB}" "${EXTRACT_ARM}"
  set +e
  readelf -h "${EXTRACT_ARM}/usr/lib/apt-hub/go/bin/go" | grep -q 'AArch64'
  RC=$?
  set -e
  record "official_arm64_elf" "${RC}" 0
  if [[ "${HOST_ARCH}" != "arm64" ]]; then
    log "skip_arm64_exec host=${HOST_ARCH}"
    record "official_arm64_no_fake_exec" 0 0
  fi

  if [[ "${HOST_ARCH}" == "amd64" ]]; then
    EXTRACT_AMD="${TMP}/extract-official/amd64"
    GOCACHE="${TMP}/extract-official/gocache"
    GOTMP="${TMP}/extract-official/gotmp"
    HELLO_DIR="${TMP}/extract-official/hello"
    rm -rf -- "${EXTRACT_AMD}" "${GOCACHE}" "${GOTMP}" "${HELLO_DIR}"
    mkdir -p -- "${EXTRACT_AMD}" "${GOCACHE}" "${GOTMP}" "${HELLO_DIR}"
    dpkg-deb -x "${OFF_AMD_DEB}" "${EXTRACT_AMD}"
    GO_BIN="${EXTRACT_AMD}/usr/bin/apt-hub-go"
    if [[ -x "${EXTRACT_AMD}/usr/lib/apt-hub/go/bin/go" ]]; then
      record "official_amd_bin_present" 0 0
    else
      record "official_amd_bin_present" 1 0
    fi
    set +e
    OUT_VER="$(env -i PATH="/usr/bin:/bin" HOME="${TMP}/extract-official/home" \
      GOTOOLCHAIN=local GOCACHE="${GOCACHE}" GOTMPDIR="${GOTMP}" \
      "${GO_BIN}" version 2>"${TMP}/extract-official/version.err")"
    RC=$?
    set -e
    log "go_version_out=${OUT_VER}"
    record "official_amd_go_version" "${RC}" 0
    set +e
    printf '%s\n' "${OUT_VER}" | grep -q 'go'"${OFF_VER_DEB%-*}"
    RC=$?
    set -e
    record "official_amd_version_match" "${RC}" 0

    set +e
    OUT_ENV="$(env -i PATH="/usr/bin:/bin" HOME="${TMP}/extract-official/home" \
      GOTOOLCHAIN=local GOCACHE="${GOCACHE}" GOTMPDIR="${GOTMP}" \
      "${GO_BIN}" env GOROOT GOTOOLDIR 2>"${TMP}/extract-official/env.err")"
    RC=$?
    set -e
    log "go_env_out=${OUT_ENV}"
    record "official_amd_go_env" "${RC}" 0
    set +e
    printf '%s\n' "${OUT_ENV}" | grep -q '/usr/lib/apt-hub/go'
    RC=$?
    set -e
    record "official_amd_goroot" "${RC}" 0

    cat >"${HELLO_DIR}/hello.go" <<'EOF'
package main
import "fmt"
func main() { fmt.Println("apt-hub-go-hello") }
EOF
    set +e
    env -i PATH="/usr/bin:/bin" HOME="${TMP}/extract-official/home" \
      GOTOOLCHAIN=local GOCACHE="${GOCACHE}" GOTMPDIR="${GOTMP}" \
      "${GO_BIN}" build -o "${HELLO_DIR}/hello" "${HELLO_DIR}/hello.go" \
      >"${TMP}/extract-official/build.out" 2>"${TMP}/extract-official/build.err"
    RC=$?
    set -e
    record "official_amd_hello_build" "${RC}" 0
    set +e
    HELLO_OUT="$("${HELLO_DIR}/hello")"
    RC=$?
    set -e
    log "hello_out=${HELLO_OUT}"
    if [[ "${HELLO_OUT}" == "apt-hub-go-hello" ]]; then
      record "official_amd_hello_run" 0 0
    else
      record "official_amd_hello_run" 1 0
    fi
    if [[ -e "${TMP}/extract-official/home/go/env" ]]; then
      record "no_go_env_w" 1 0
    else
      record "no_go_env_w" 0 0
    fi
  else
    log "host not amd64; skip offline run"
  fi

  run_isolated_apt_upgrade "${OFF_AMD_DEB}" "${OFF_VER_DEB}" "official"

  set +e
  dpkg-deb -f "${OFF_AMD_DEB}" Package | grep -Fxq apt-hub-go
  RC=$?
  set -e
  record "final_control_package" "${RC}" 0
  set +e
  dpkg-deb -f "${OFF_AMD_DEB}" Version | grep -Fxq "${OFF_VER_DEB}"
  RC=$?
  set -e
  record "final_control_version" "${RC}" 0
fi

# 不删 ${TMP}/archives 与 ${TMP}/out/official

log "TOTAL pass=${PASS} fail=${FAIL}"
echo "TOTAL=${PASS} PASS=${PASS} FAIL=${FAIL}"
if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi
exit 0
