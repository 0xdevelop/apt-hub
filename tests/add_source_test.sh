#!/usr/bin/env bash
# tests/add_source_test.sh — 隔离根真 gpgv/apt 消费；openssl s_server -HTTP；不改本机系统源。
set -euo pipefail
export LC_ALL=C
export LANG=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ADD="${ROOT}/scripts/add_source.sh"
FIX="${ROOT}/tmp/add-source-last-preflight"
BASE="${FIX}/testrun"
SITE="${BASE}/site"
HTTP_TREE="${BASE}/http-tree"
GNUPG="${BASE}/gnupg"
TLS="${BASE}/tls"
EVIDENCE="${BASE}/evidence.log"
SYSTEM_SHA_BEFORE="${FIX}/system-apt-sha.before"
SYSTEM_SHA_AFTER="${FIX}/system-apt-sha.after"
PASS=0
FAIL=0
SERVER_PID=""
HTTPS_PORT=18771
SITE_URL="https://127.0.0.2:${HTTPS_PORT}"
SOFTWARE_ID="demoapp"
SOFTWARE_ID2="demoapp2"
PKG_NAME="demo-app"
PKG_NAME2="demo-app-two"
SERIES="noble"

system_apt_sha() {
  {
    sha256sum /etc/apt/sources.list 2>/dev/null || true
    if [[ -d /etc/apt/sources.list.d ]]; then
      find /etc/apt/sources.list.d -maxdepth 1 -type f -print0 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum
    fi
    if [[ -d /etc/apt/keyrings ]]; then
      find /etc/apt/keyrings -maxdepth 1 -type f -print0 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum
    fi
  } | sha256sum | awk '{print $1}'
}

kill_gpg_home() {
  local gpghome="$1"
  if [[ -d "${gpghome}" && ! -L "${gpghome}" ]]; then
    gpgconf --homedir "${gpghome}" --kill all >/dev/null 2>&1 || true
  fi
}

# 开跑前：只清本任务目录与本脚本保存的 SERVER_PID（不动他人进程/端口）
mkdir -p -- "${FIX}"
kill_gpg_home "${GNUPG}"
kill_gpg_home "${BASE}/gnupg-other"
kill_gpg_home "${BASE}/gnupg-new"
if [[ -n "${SERVER_PID:-}" ]]; then
  kill "${SERVER_PID}" 2>/dev/null || true
  wait "${SERVER_PID}" 2>/dev/null || true
  SERVER_PID=""
fi
rm -rf -- "${BASE}"
mkdir -p -- "${BASE}/bin" "${BASE}/roots" "${BASE}/copies" "${GNUPG}" "${TLS}" "${SITE}" "${HTTP_TREE}"
chmod 700 -- "${GNUPG}" "${TLS}"

system_apt_sha >"${SYSTEM_SHA_BEFORE}"

{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "root=${ROOT}"
  echo "system_apt_sha_before=$(cat "${SYSTEM_SHA_BEFORE}")"
  echo "path_has_bun=$(command -v bun >/dev/null 2>&1 && echo yes || echo no)"
} >"${EVIDENCE}"

log() { printf '%s\n' "$*" | tee -a "${EVIDENCE}"; }

cleanup_secrets() {
  # 退出清测试私钥/TLS key；保留公钥、签名与日志；只杀本脚本保存的 SERVER_PID
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
  fi
  kill_gpg_home "${GNUPG}"
  kill_gpg_home "${BASE}/gnupg-other"
  kill_gpg_home "${BASE}/gnupg-new"
  rm -f -- "${TLS}/tls.key"
  if [[ -d "${GNUPG}" ]]; then
    find "${GNUPG}" -type f \( -name '*private*' -o -name 'private-keys-v1.d' \) -delete 2>/dev/null || true
    rm -rf -- "${GNUPG}/private-keys-v1.d" 2>/dev/null || true
  fi
  if [[ -d "${BASE}/gnupg-other" ]]; then
    rm -rf -- "${BASE}/gnupg-other/private-keys-v1.d" 2>/dev/null || true
  fi
  if [[ -d "${BASE}/gnupg-new" ]]; then
    rm -rf -- "${BASE}/gnupg-new/private-keys-v1.d" 2>/dev/null || true
  fi
}

cleanup() {
  local rc=$?
  cleanup_secrets || true
  system_apt_sha >"${SYSTEM_SHA_AFTER}" || true
  if [[ -f "${SYSTEM_SHA_BEFORE}" && -f "${SYSTEM_SHA_AFTER}" ]]; then
    if cmp -s -- "${SYSTEM_SHA_BEFORE}" "${SYSTEM_SHA_AFTER}"; then
      log "system_apt_sha_unchanged=$(cat "${SYSTEM_SHA_AFTER}")"
    else
      log "system_apt_sha_CHANGED before=$(cat "${SYSTEM_SHA_BEFORE}") after=$(cat "${SYSTEM_SHA_AFTER}")"
    fi
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'log "ERR line=${LINENO} cmd=${BASH_COMMAND}"; exit 1' ERR

pass() {
  PASS=$((PASS + 1))
  log "PASS $*"
}

fail() {
  FAIL=$((FAIL + 1))
  log "FAIL $*"
}

record_rc() {
  local name="$1" rc="$2" expect="$3"
  log "CASE ${name}: exit=${rc} expect=${expect}"
  if [[ "${rc}" -eq "${expect}" ]]; then
    pass "${name}"
  else
    fail "${name}"
  fi
}

capture_rc() {
  local logf="$1" rc=0
  shift
  "$@" >"${logf}" 2>&1 || rc=$?
  printf '%s\n' "${rc}"
}

find_shellcheck() {
  if [[ -x "${ROOT}/tmp/metadata-C/bin/shellcheck" ]]; then
    printf '%s\n' "${ROOT}/tmp/metadata-C/bin/shellcheck"
    return 0
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    command -v shellcheck
    return 0
  fi
  return 1
}

assert_no_symlink_in_tree() {
  local dir="$1"
  if find -- "${dir}" -type l -print -quit | grep -q .; then
    echo "fixture 含 symlink: ${dir}" >&2
    return 1
  fi
}

prepare_isolated_root() {
  local root="$1" series="${2:-${SERIES}}" arch="${3:-amd64}"
  local use_symlink_os="${4:-symlink}"
  rm -rf -- "${root}"
  mkdir -p -- \
    "${root}/etc/apt/keyrings" \
    "${root}/etc/apt/sources.list.d" \
    "${root}/etc/apt/apt.conf.d" \
    "${root}/etc/apt/preferences.d" \
    "${root}/etc/apt/trusted.gpg.d" \
    "${root}/usr/lib" \
    "${root}/var/lib/apt/lists/partial" \
    "${root}/var/lib/apt/periodic" \
    "${root}/var/cache/apt/archives/partial" \
    "${root}/var/lib/dpkg/info" \
    "${root}/var/lib/dpkg/updates" \
    "${root}/var/lib/dpkg/triggers" \
    "${root}/var/log/apt"
  : >"${root}/var/lib/dpkg/status"
  : >"${root}/var/lib/apt/extended_states"
  : >"${root}/var/lib/dpkg/available"
  : >"${root}/etc/apt/sources.list"
  : >"${root}/etc/apt/preferences"
  : >"${root}/etc/apt/trusted.gpg"
  cat >"${root}/usr/lib/os-release" <<EOF
NAME="Ubuntu"
ID=ubuntu
VERSION_CODENAME=${series}
EOF
  if [[ "${use_symlink_os}" == "symlink" ]]; then
    ln -s ../usr/lib/os-release "${root}/etc/os-release"
  else
    cp -f -- "${root}/usr/lib/os-release" "${root}/etc/os-release"
  fi
  printf '%s\n' "${arch}" >"${root}/.test-arch"
}

build_deb_meta_only() {
  local pkg="$1" ver="$2" arch="$3"
  local sha size
  sha="$(printf 'fixture-%s-%s-%s' "${pkg}" "${ver}" "${arch}" | sha256sum | awk '{print $1}')"
  size=1234
  cat <<EOF
Package: ${pkg}
Version: ${ver}
Architecture: ${arch}
Maintainer: apt-hub add-source fixture <apt-hub-test@invalid>
Filename: releases/download/v${ver}/${pkg}_${ver}_${arch}.deb
Size: ${size}
SHA256: ${sha}
Description: add-source fixture, not for production

EOF
}

make_gpg_home() {
  local gpghome="$1"
  kill_gpg_home "${gpghome}"
  rm -rf -- "${gpghome}"
  mkdir -p -- "${gpghome}"
  chmod 700 -- "${gpghome}"
  cat >"${BASE}/gpg-batch" <<'EOF'
%echo generating apt-hub add-source fixture key
Key-Type: RSA
Key-Length: 2048
Name-Real: apt-hub add-source fixture
Name-Email: apt-hub-add-source-fixture@invalid
Expire-Date: 2d
%no-protection
%commit
%echo done
EOF
  gpg --homedir "${gpghome}" --batch --generate-key "${BASE}/gpg-batch" \
    >/dev/null 2>"${BASE}/gpg-gen.log"
}

sign_release() {
  local gpghome="$1" dist="$2"
  gpg --homedir "${gpghome}" --batch --yes --pinentry-mode loopback \
    --personal-digest-preferences SHA256 --digest-algo SHA256 \
    --clearsign -o "${dist}/InRelease" "${dist}/Release"
  gpg --homedir "${gpghome}" --batch --yes --pinentry-mode loopback \
    --personal-digest-preferences SHA256 --digest-algo SHA256 \
    --detach-sign --armor -o "${dist}/Release.gpg" "${dist}/Release"
}

add_software_to_site() {
  local site="$1" gpghome="$2" series="$3" id="$4" pkg="$5" ver="$6" site_url="$7"
  local arch h
  mkdir -p -- "${site}/repos/${id}"
  for arch in amd64 arm64; do
    mkdir -p -- "${site}/repos/${id}/dists/${series}/main/binary-${arch}/by-hash/SHA256"
    build_deb_meta_only "${pkg}" "${ver}" "${arch}" \
      >"${site}/repos/${id}/dists/${series}/main/binary-${arch}/Packages"
    gzip -9c "${site}/repos/${id}/dists/${series}/main/binary-${arch}/Packages" \
      >"${site}/repos/${id}/dists/${series}/main/binary-${arch}/Packages.gz"
    h="$(sha256sum "${site}/repos/${id}/dists/${series}/main/binary-${arch}/Packages" | awk '{print $1}')"
    cp -- "${site}/repos/${id}/dists/${series}/main/binary-${arch}/Packages" \
      "${site}/repos/${id}/dists/${series}/main/binary-${arch}/by-hash/SHA256/${h}"
    h="$(sha256sum "${site}/repos/${id}/dists/${series}/main/binary-${arch}/Packages.gz" | awk '{print $1}')"
    cp -- "${site}/repos/${id}/dists/${series}/main/binary-${arch}/Packages.gz" \
      "${site}/repos/${id}/dists/${series}/main/binary-${arch}/by-hash/SHA256/${h}"
  done
  cat >"${BASE}/apt-ftparchive-${id}-${series}.conf" <<EOF
APT::FTPArchive::MD5 "false";
APT::FTPArchive::SHA1 "false";
APT::FTPArchive::SHA512 "false";
APT::FTPArchive::SHA256 "true";
APT::FTPArchive::Release::Origin "apt-hub-add-source-test";
APT::FTPArchive::Release::Label "apt-hub-add-source-test";
APT::FTPArchive::Release::Suite "${series}";
APT::FTPArchive::Release::Codename "${series}";
APT::FTPArchive::Release::Architectures "amd64 arm64";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "apt-hub add-source fixture";
APT::FTPArchive::Release::Acquire-By-Hash "yes";
APT::FTPArchive::Release::ValidTime "604800";
EOF
  rm -f -- "${site}/repos/${id}/dists/${series}/Release" \
    "${site}/repos/${id}/dists/${series}/Release.gpg" \
    "${site}/repos/${id}/dists/${series}/InRelease"
  apt-ftparchive -c "${BASE}/apt-ftparchive-${id}-${series}.conf" release \
    "${site}/repos/${id}/dists/${series}" >"${BASE}/Release-${id}-${series}.txt"
  if grep -E '[[:space:]]Release$' "${BASE}/Release-${id}-${series}.txt" >/dev/null; then
    echo "Release 不应自指摘要" >&2
    return 1
  fi
  mv -- "${BASE}/Release-${id}-${series}.txt" "${site}/repos/${id}/dists/${series}/Release"
  grep -q '^Valid-Until:' "${site}/repos/${id}/dists/${series}/Release" || {
    echo "Release 缺少 Valid-Until" >&2
    return 1
  }
  sign_release "${gpghome}" "${site}/repos/${id}/dists/${series}"
  cat >"${site}/repos/${id}/${series}.sources" <<EOF
Types: deb
URIs: mirror+${site_url}/repos/${id}/mirror.list
Suites: ${series}
Components: main
Signed-By: /etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
  printf '%s/repos/%s/\ttype:index\nhttps://example.invalid/official/\ttype:deb\n' \
    "${site_url}" "${id}" >"${site}/repos/${id}/mirror.list"
}

build_site() {
  local site="$1" gpghome="$2" series="$3" site_url="$4"
  rm -rf -- "${site}"
  mkdir -p -- "${site}"
  add_software_to_site "${site}" "${gpghome}" "${series}" \
    "${SOFTWARE_ID}" "${PKG_NAME}" "1.0.0" "${site_url}"
  add_software_to_site "${site}" "${gpghome}" "${series}" \
    "${SOFTWARE_ID2}" "${PKG_NAME2}" "2.0.0" "${site_url}"
  gpg --homedir "${gpghome}" --batch --export --armor >"${site}/apt-hub.gpg"
  printf '<html>add-source fixture</html>\n' >"${site}/index.html"
  assert_no_symlink_in_tree "${site}"
  if find "${site}" -name '*.deb' | grep -q .; then
    echo "站点不应含 deb" >&2
    return 1
  fi
}

# 从站点文件生成 openssl s_server -HTTP 响应树（含 Content-Length + Connection: close）
build_http_tree() {
  local src="$1" dest="$2"
  local path rel len destf destdir
  rm -rf -- "${dest}"
  mkdir -p -- "${dest}"
  chmod 755 -- "${dest}"
  assert_no_symlink_in_tree "${src}"
  while IFS= read -r -d '' path; do
    rel="${path#"${src}"/}"
    case "${rel}" in
      *.deb)
        echo "拒绝托管 deb: ${rel}" >&2; return 1 ;;
      *.key)
        echo "拒绝托管私钥: ${rel}" >&2; return 1 ;;
      *private*)
        echo "拒绝托管私钥路径: ${rel}" >&2; return 1 ;;
    esac
    destf="${dest}/${rel}"
    destdir="$(dirname -- "${destf}")"
    mkdir -p -- "${destdir}"
    len="$(wc -c <"${path}" | tr -d ' ')"
    {
      printf 'HTTP/1.0 200 OK\r\n'
      printf 'Content-Type: application/octet-stream\r\n'
      printf 'Content-Length: %s\r\n' "${len}"
      printf 'Connection: close\r\n'
      printf '\r\n'
      cat -- "${path}"
    } >"${destf}"
  done < <(find -- "${src}" -type f -print0)
  assert_no_symlink_in_tree "${dest}"
}

https_port_busy() {
  # 仅探测，不杀进程
  fuser "${HTTPS_PORT}/tcp" >/dev/null 2>&1
}

stop_https() {
  # 只杀本脚本保存的 SERVER_PID；不按端口杀他人
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
  fi
}

start_https() {
  local site_root="$1"
  stop_https
  if https_port_busy; then
    log "HTTPS port ${HTTPS_PORT} occupied; refuse without killing foreign process"
    return 1
  fi
  if [[ ! -f "${TLS}/tls.crt" || ! -f "${TLS}/tls.key" ]]; then
    openssl req -x509 -newkey rsa:2048 -noenc -days 2 -subj '/CN=apt-hub add-source fixture' \
      -addext 'subjectAltName=IP:127.0.0.2' \
      -keyout "${TLS}/tls.key" -out "${TLS}/tls.crt" >"${TLS}/tls-gen.log" 2>&1
    chmod 600 -- "${TLS}/tls.key"
  fi
  build_http_tree "${site_root}" "${HTTP_TREE}"
  # 原生 OpenSSL；不引入 Bun/Node
  (
    cd -- "${HTTP_TREE}"
    exec openssl s_server \
      -accept "127.0.0.2:${HTTPS_PORT}" \
      -cert "${TLS}/tls.crt" \
      -key "${TLS}/tls.key" \
      -HTTP \
      -http_server_binmode
  ) >"${BASE}/https-server.log" 2>&1 &
  SERVER_PID=$!
  local ready=0 _try
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if curl -fsS --noproxy '*' --cacert "${TLS}/tls.crt" --connect-timeout 1 --max-time 2 \
      "${SITE_URL}/index.html" >"${BASE}/https-ready.body" 2>"${BASE}/https-ready.err"; then
      ready=1
      break
    fi
    sleep 0.15
  done
  [[ "${ready}" -eq 1 ]] || {
    log "HTTPS fixture 未就绪"
    cat "${BASE}/https-server.log" >>"${EVIDENCE}" || true
    return 1
  }
  log "https_fixture_ready port=${HTTPS_PORT} pid=${SERVER_PID} engine=openssl-s_server-HTTP"
}

# 生产 curl 不带 --noproxy；回环 DIRECT 只在本测试 APT 配置，不改系统代理。
run_add() {
  local root="$1"
  local software="${SOFTWARE_ID}"
  shift
  if [[ $# -gt 0 && "${1}" != --* ]]; then
    software="$1"
    shift
  fi
  env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u all_proxy \
    "${ADD}" --site-url "${SITE_URL}" --software "${software}" --root "${root}" \
    --architecture amd64 --cacert "${TLS}/tls.crt" "$@"
}

write_apt_conf_for_root() {
  local root="$1" arch="$2" conf="$3"
  cat >"${conf}" <<EOF
Dir "${root}";
Dir::State "${root}/var/lib/apt";
Dir::State::status "${root}/var/lib/dpkg/status";
Dir::State::extended_states "${root}/var/lib/apt/extended_states";
Dir::State::lists "${root}/var/lib/apt/lists";
Dir::Cache "${root}/var/cache/apt";
Dir::Etc "${root}/etc/apt";
Dir::Etc::Main "${root}/etc/apt/apt.conf";
Dir::Etc::Parts "${root}/etc/apt/apt.conf.d";
Dir::Etc::Sourcelist "${root}/etc/apt/sources.list";
Dir::Etc::SourceParts "${root}/etc/apt/sources.list.d";
Dir::Etc::Preferences "${root}/etc/apt/preferences";
Dir::Etc::PreferencesParts "${root}/etc/apt/preferences.d";
Dir::Etc::Trusted "${root}/etc/apt/trusted.gpg";
Dir::Etc::TrustedParts "${root}/etc/apt/trusted.gpg.d";
Dir::Bin::dpkg "/bin/false";
Dir::Log "${root}/var/log/apt";
APT::Architecture "${arch}";
APT::Architectures "${arch}";
APT::Get::AllowUnauthenticated "false";
Acquire::AllowInsecureRepositories "false";
Acquire::AllowDowngradeToInsecureRepositories "false";
Acquire::https::Verify-Peer "true";
Acquire::https::Verify-Host "true";
Acquire::https::127.0.0.2::CaInfo "${TLS}/tls.crt";
Acquire::https::Proxy::127.0.0.2 "DIRECT";
Acquire::Languages "none";
Acquire::Retries "1";
Acquire::https::Timeout "30";
Acquire::By-Hash "force";
APT::Update::Error-Mode "any";
APT::Sandbox::User "$(id -un)";
EOF
}

[[ -x "${ADD}" ]] || { echo "缺少可执行 ${ADD}" >&2; exit 1; }

# 证明生产脚本无强制 noproxy、无 bun 调用；测试用 openssl s_server
if awk '
  /^[[:space:]]*#/ { next }
  /--noproxy/ { found=1 }
  /[[:space:]]bun[[:space:]]/ { found=1 }
  END { exit found ? 0 : 1 }
' "${ADD}"; then
  fail "production_has_bun_or_noproxy"
else
  pass "production_no_bun_noproxy"
fi
if grep -nE 'https-fixture[.]js' "${ROOT}/tests/add_source_test.sh" >/dev/null; then
  fail "test_still_invokes_bun_fixture"
else
  pass "test_no_bun_fixture_invoke"
fi
if grep -q 'openssl s_server' "${ROOT}/tests/add_source_test.sh"; then
  pass "test_uses_openssl_s_server"
else
  fail "test_missing_openssl_s_server"
fi

log "== bash -n / shellcheck =="
rc="$(capture_rc "${BASE}/bash-n.log" bash -n "${ADD}")"
record_rc "bash_n_add_source" "${rc}" 0
rc="$(capture_rc "${BASE}/bash-n-test.log" bash -n "${ROOT}/tests/add_source_test.sh")"
record_rc "bash_n_add_source_test" "${rc}" 0
SC_BIN=""
if SC_BIN="$(find_shellcheck)"; then
  log "shellcheck_bin=${SC_BIN}"
  rc="$(capture_rc "${BASE}/shellcheck.gcc" "${SC_BIN}" -f gcc -s bash "${ADD}" "${ROOT}/tests/add_source_test.sh")"
  record_rc "shellcheck" "${rc}" 0
  if [[ "${rc}" -ne 0 ]]; then
    head -n 40 "${BASE}/shellcheck.gcc" | tee -a "${EVIDENCE}" || true
  fi
else
  fail "shellcheck_unavailable_explicit"
  log "shellcheck 不可用：需要 tmp/metadata-C/bin/shellcheck 或 PATH 中的 shellcheck；本测试不安装"
fi

log "== 构建唯一测试身份与站点 =="
make_gpg_home "${GNUPG}"
FP="$(gpg --homedir "${GNUPG}" --batch --list-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')"
log "fixture_fingerprint=${FP}"
build_site "${SITE}" "${GNUPG}" "${SERIES}" "${SITE_URL}"
# 导出公钥副本留存（清理时私钥删除）
cp -f -- "${SITE}/apt-hub.gpg" "${FIX}/apt-hub.pub.asc"
start_https "${SITE}"

log "== 正向：标准 symlink os-release 布局 =="
R1="${BASE}/roots/first"
prepare_isolated_root "${R1}" "${SERIES}" amd64 symlink
[[ -L "${R1}/etc/os-release" ]] || fail "fixture_os_release_not_symlink"
rc="$(capture_rc "${BASE}/first.log" run_add "${R1}")"
record_rc "first_add_symlink_os_release" "${rc}" 0
if [[ "${rc}" -eq 0 ]]; then
  [[ -f "${R1}/etc/apt/keyrings/apt-hub.gpg" ]] || fail "first_add_key_missing"
  [[ -f "${R1}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" ]] || fail "first_add_sources_missing"
  if grep -q "^Signed-By: ${R1}/etc/apt/keyrings/apt-hub.gpg$" \
    "${R1}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources"; then
    pass "first_add_signed_by_isolated"
  else
    fail "first_add_signed_by_isolated"
  fi
  if grep -q "apt install ${PKG_NAME}" "${BASE}/first.log"; then
    pass "first_add_package_name"
  else
    fail "first_add_package_name"
  fi
  mode_k="$(stat -c '%a' "${R1}/etc/apt/keyrings/apt-hub.gpg")"
  mode_s="$(stat -c '%a' "${R1}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources")"
  if [[ "${mode_k}" == "644" && "${mode_s}" == "644" ]]; then
    pass "first_add_modes"
  else
    fail "first_add_modes"
  fi
fi

log "== 幂等 =="
rc="$(capture_rc "${BASE}/idempotent.log" run_add "${R1}")"
record_rc "idempotent_add" "${rc}" 0
if grep -q '幂等' "${BASE}/idempotent.log"; then
  pass "idempotent_message"
else
  fail "idempotent_message"
fi

log "== 真 apt-get 消费者 #1（Dir::* 隔离） =="
write_apt_conf_for_root "${R1}" amd64 "${R1}/etc/apt/apt.conf"
arc="$(capture_rc "${BASE}/apt-update-1.log" env APT_CONFIG="${R1}/etc/apt/apt.conf" timeout 90 apt-get update)"
record_rc "apt_get_update_consumer_1" "${arc}" 0
if [[ "${arc}" -eq 0 ]]; then
  if grep -R -l "${PKG_NAME}" "${R1}/var/lib/apt/lists" >/dev/null 2>&1; then
    pass "apt_lists_contain_package_1"
  else
    fail "apt_lists_contain_package_1"
  fi
else
  head -n 60 "${BASE}/apt-update-1.log" | tee -a "${EVIDENCE}" || true
fi

log "== 真 apt-get 消费者 #2（回归） =="
arc="$(capture_rc "${BASE}/apt-update-2.log" env APT_CONFIG="${R1}/etc/apt/apt.conf" timeout 90 apt-get update)"
record_rc "apt_get_update_consumer_2" "${arc}" 0
if [[ "${arc}" -eq 0 ]]; then
  if grep -R -l "${PKG_NAME}" "${R1}/var/lib/apt/lists" >/dev/null 2>&1; then
    pass "apt_lists_contain_package_2"
  else
    fail "apt_lists_contain_package_2"
  fi
else
  head -n 60 "${BASE}/apt-update-2.log" | tee -a "${EVIDENCE}" || true
fi

log "== 越界 os-release symlink 拒绝 =="
Rob="${BASE}/roots/osrel-escape"
prepare_isolated_root "${Rob}" "${SERIES}" amd64 plain
rm -f -- "${Rob}/etc/os-release"
ln -s /etc/os-release "${Rob}/etc/os-release"
rc="$(capture_rc "${BASE}/osrel-escape.log" run_add "${Rob}")"
record_rc "os_release_escape_rejected" "${rc}" 1

log "== 不支持组合（错误系列） =="
Rbad="${BASE}/roots/bad-series"
prepare_isolated_root "${Rbad}" "jammy" amd64 symlink
rc="$(capture_rc "${BASE}/bad-series.log" run_add "${Rbad}")"
record_rc "unsupported_series" "${rc}" 1

log "== 错签名 =="
Rsig="${BASE}/roots/badsig"
prepare_isolated_root "${Rsig}"
cp -a -- "${SITE}" "${BASE}/site-badsig"
sig_in="${BASE}/site-badsig/repos/${SOFTWARE_ID}/dists/${SERIES}/InRelease"
awk 'BEGIN{done=0} /^Suite: / && !done {sub(/noble/,"evil"); done=1} {print}' \
  "${sig_in}" >"${sig_in}.bad"
mv -- "${sig_in}.bad" "${sig_in}"
start_https "${BASE}/site-badsig"
rc="$(capture_rc "${BASE}/badsig.log" run_add "${Rsig}")"
record_rc "bad_signature" "${rc}" 1
if [[ ! -e "${Rsig}/etc/apt/keyrings/apt-hub.gpg" ]]; then pass "badsig_no_half_key"; else fail "badsig_no_half_key"; fi
if [[ ! -e "${Rsig}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" ]]; then pass "badsig_no_half_sources"; else fail "badsig_no_half_sources"; fi

log "== 错钥 =="
OTHER_GPG="${BASE}/gnupg-other"
make_gpg_home "${OTHER_GPG}"
cp -a -- "${SITE}" "${BASE}/site-badkey"
gpg --homedir "${OTHER_GPG}" --batch --export --armor >"${BASE}/site-badkey/apt-hub.gpg"
start_https "${BASE}/site-badkey"
Rkey="${BASE}/roots/badkey"
prepare_isolated_root "${Rkey}"
rc="$(capture_rc "${BASE}/badkey.log" run_add "${Rkey}")"
record_rc "wrong_key" "${rc}" 1

log "== 过期 Valid-Until =="
cp -a -- "${SITE}" "${BASE}/site-expired"
dist="${BASE}/site-expired/repos/${SOFTWARE_ID}/dists/${SERIES}"
awk 'BEGIN{done=0} /^Valid-Until:/ {print "Valid-Until: 2000-01-01 00:00:00 UTC"; done=1; next} {print} END{if(!done) print "Valid-Until: 2000-01-01 00:00:00 UTC"}' \
  "${dist}/Release" >"${dist}/Release.new"
mv -- "${dist}/Release.new" "${dist}/Release"
sign_release "${GNUPG}" "${dist}"
start_https "${BASE}/site-expired"
Rexp="${BASE}/roots/expired"
prepare_isolated_root "${Rexp}"
rc="$(capture_rc "${BASE}/expired.log" run_add "${Rexp}")"
record_rc "expired_valid_until" "${rc}" 1

log "== sources 注入其他 host =="
cp -a -- "${SITE}" "${BASE}/site-inject"
cat >"${BASE}/site-inject/repos/${SOFTWARE_ID}/${SERIES}.sources" <<EOF
Types: deb
URIs: mirror+https://evil.example/repos/${SOFTWARE_ID}/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: /etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-inject"
Rinj="${BASE}/roots/inject"
prepare_isolated_root "${Rinj}"
rc="$(capture_rc "${BASE}/inject.log" run_add "${Rinj}")"
record_rc "sources_host_injection" "${rc}" 1

log "== 恢复干净站点 =="
start_https "${SITE}"

log "== 路径 symlink 拒绝 + 哨兵权限不变 =="
Rsym="${BASE}/roots/symlink-root"
prepare_isolated_root "${Rsym}"
rm -rf -- "${BASE}/roots/symlink-link"
ln -s "${Rsym}" "${BASE}/roots/symlink-link"
rc="$(capture_rc "${BASE}/symlink.log" \
  "${ADD}" --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" \
  --root "${BASE}/roots/symlink-link" --architecture amd64 --cacert "${TLS}/tls.crt")"
record_rc "symlink_root_rejected" "${rc}" 1

Ranc="${BASE}/roots/symlink-ancestor"
prepare_isolated_root "${Ranc}/real"
# 哨兵：祖先目录权限
sent_mode_before="$(stat -c '%a' "${Ranc}")"
mkdir -p -- "${BASE}/roots/via"
ln -s "${Ranc}/real" "${BASE}/roots/via/link"
# 在 via 路径上，keyrings 祖先含 symlink —— 脚本应在创建前拒绝
rc="$(capture_rc "${BASE}/symlink-anc.log" \
  "${ADD}" --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" \
  --root "${BASE}/roots/via/link" --architecture amd64 --cacert "${TLS}/tls.crt")"
record_rc "symlink_ancestor_rejected" "${rc}" 1
sent_mode_after="$(stat -c '%a' "${Ranc}")"
if [[ "${sent_mode_before}" == "${sent_mode_after}" ]]; then
  pass "symlink_ancestor_mode_sentinel_unchanged"
else
  fail "symlink_ancestor_mode_sentinel_unchanged"
fi

log "== 目的路径预检：拒绝后无提前新建 / 哨兵不变 =="
# sources.list.d 叶目录 symlink；keyrings 原不存在 → 拒绝后仍不存在
Rleaf="${BASE}/roots/dest-sources-leaf"
prepare_isolated_root "${Rleaf}"
rm -rf -- "${Rleaf}/etc/apt/keyrings" "${Rleaf}/etc/apt/sources.list.d"
mkdir -p -- "${BASE}/roots/dest-outside"
ln -s "${BASE}/roots/dest-outside" "${Rleaf}/etc/apt/sources.list.d"
[[ ! -e "${Rleaf}/etc/apt/keyrings" ]] || fail "dest_leaf_fixture_keyrings_absent"
rc="$(capture_rc "${BASE}/dest-sources-leaf.log" run_add "${Rleaf}")"
record_rc "dest_sources_list_d_symlink_rejected" "${rc}" 1
if [[ ! -e "${Rleaf}/etc/apt/keyrings" ]]; then
  pass "dest_sources_list_d_no_keyrings_mkdir"
else
  fail "dest_sources_list_d_no_keyrings_mkdir"
fi
if grep -q '符号链接' "${BASE}/dest-sources-leaf.log"; then
  pass "dest_sources_list_d_reject_before_download"
else
  fail "dest_sources_list_d_reject_before_download"
fi

# 最终 .sources 悬空 symlink；keyrings 原不存在 → 拒绝后仍不存在
Rdang="${BASE}/roots/dest-sources-dangling"
prepare_isolated_root "${Rdang}"
rm -rf -- "${Rdang}/etc/apt/keyrings"
rm -f -- "${Rdang}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources"
ln -s "${BASE}/roots/dest-outside/missing-${SOFTWARE_ID}.sources" \
  "${Rdang}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources"
[[ ! -e "${Rdang}/etc/apt/keyrings" ]] || fail "dest_dangling_fixture_keyrings_absent"
rc="$(capture_rc "${BASE}/dest-sources-dangling.log" run_add "${Rdang}")"
record_rc "dest_sources_file_symlink_rejected" "${rc}" 1
if [[ ! -e "${Rdang}/etc/apt/keyrings" ]]; then
  pass "dest_sources_file_no_keyrings_mkdir"
else
  fail "dest_sources_file_no_keyrings_mkdir"
fi
if grep -q 'sources 路径是符号链接' "${BASE}/dest-sources-dangling.log"; then
  pass "dest_sources_file_reject_before_download"
else
  fail "dest_sources_file_reject_before_download"
fi

# key 文件 symlink：keyrings 仅作必要 fixture；哨兵与权限不变
Rkeyl="${BASE}/roots/dest-key-link"
prepare_isolated_root "${Rkeyl}"
printf 'keyrings-sentinel\n' >"${Rkeyl}/etc/apt/keyrings/.sentinel"
chmod 0700 -- "${Rkeyl}/etc/apt/keyrings"
key_sent_before="$(sha256sum -- "${Rkeyl}/etc/apt/keyrings/.sentinel" | awk '{print $1}')"
key_mode_before="$(stat -c '%a' "${Rkeyl}/etc/apt/keyrings")"
ln -s "${BASE}/roots/dest-outside/missing.gpg" "${Rkeyl}/etc/apt/keyrings/apt-hub.gpg"
rc="$(capture_rc "${BASE}/dest-key-link.log" run_add "${Rkeyl}")"
record_rc "dest_key_file_symlink_rejected" "${rc}" 1
key_sent_after="$(sha256sum -- "${Rkeyl}/etc/apt/keyrings/.sentinel" | awk '{print $1}')"
key_mode_after="$(stat -c '%a' "${Rkeyl}/etc/apt/keyrings")"
if [[ "${key_sent_before}" == "${key_sent_after}" && "${key_mode_before}" == "${key_mode_after}" ]]; then
  pass "dest_key_link_sentinel_mode_unchanged"
else
  fail "dest_key_link_sentinel_mode_unchanged"
fi
if grep -q '公钥路径是符号链接' "${BASE}/dest-key-link.log"; then
  pass "dest_key_link_reject_before_download"
else
  fail "dest_key_link_reject_before_download"
fi

# lock 文件 symlink：keyrings 仅作必要 fixture；哨兵与权限不变
Rlock="${BASE}/roots/dest-lock-link"
prepare_isolated_root "${Rlock}"
printf 'lock-sentinel\n' >"${Rlock}/etc/apt/keyrings/.sentinel"
chmod 0700 -- "${Rlock}/etc/apt/keyrings"
lock_sent_before="$(sha256sum -- "${Rlock}/etc/apt/keyrings/.sentinel" | awk '{print $1}')"
lock_mode_before="$(stat -c '%a' "${Rlock}/etc/apt/keyrings")"
ln -s "${BASE}/roots/dest-outside/missing.lock" \
  "${Rlock}/etc/apt/keyrings/.apt-hub-add-source.lock"
rc="$(capture_rc "${BASE}/dest-lock-link.log" run_add "${Rlock}")"
record_rc "dest_lock_file_symlink_rejected" "${rc}" 1
lock_sent_after="$(sha256sum -- "${Rlock}/etc/apt/keyrings/.sentinel" | awk '{print $1}')"
lock_mode_after="$(stat -c '%a' "${Rlock}/etc/apt/keyrings")"
if [[ "${lock_sent_before}" == "${lock_sent_after}" && "${lock_mode_before}" == "${lock_mode_after}" ]]; then
  pass "dest_lock_link_sentinel_mode_unchanged"
else
  fail "dest_lock_link_sentinel_mode_unchanged"
fi
if grep -q 'lock 不能是符号链接' "${BASE}/dest-lock-link.log"; then
  pass "dest_lock_link_reject_before_download"
else
  fail "dest_lock_link_reject_before_download"
fi

log "== 已有冲突源 =="
Rconf="${BASE}/roots/conflict"
prepare_isolated_root "${Rconf}"
run_add "${Rconf}" >"${BASE}/conflict-seed.log" 2>&1
printf 'Types: deb\nURIs: https://evil.example/\nSuites: noble\nComponents: main\nSigned-By: /etc/apt/keyrings/apt-hub.gpg\nArchitectures: amd64\n' \
  >"${Rconf}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources"
rc="$(capture_rc "${BASE}/conflict.log" run_add "${Rconf}")"
record_rc "existing_sources_conflict" "${rc}" 1

log "== 旧钥拒换 =="
Rswap="${BASE}/roots/keyswap"
prepare_isolated_root "${Rswap}"
run_add "${Rswap}" >"${BASE}/keyswap-seed.log" 2>&1
gpg --homedir "${OTHER_GPG}" --batch --export >"${Rswap}/etc/apt/keyrings/apt-hub.gpg"
rc="$(capture_rc "${BASE}/keyswap.log" run_add "${Rswap}")"
record_rc "refuse_key_swap" "${rc}" 1

log "== 显式完整指纹换钥 =="
NEW_GPG="${BASE}/gnupg-new"
make_gpg_home "${NEW_GPG}"
NEW_FP="$(gpg --homedir "${NEW_GPG}" --batch --list-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')"
NEW_FP="$(printf '%s' "${NEW_FP}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
log "fixture_new_fingerprint=${NEW_FP}"
build_site "${BASE}/site-newkey" "${NEW_GPG}" "${SERIES}" "${SITE_URL}"

Rrep="${BASE}/roots/replace-key"
prepare_isolated_root "${Rrep}"
run_add "${Rrep}" >"${BASE}/replace-seed.log" 2>&1
run_add "${Rrep}" "${SOFTWARE_ID2}" >"${BASE}/replace-seed2.log" 2>&1
key_sha_before="$(sha256sum -- "${Rrep}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
src_sha_before="$(sha256sum -- "${Rrep}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" | awk '{print $1}')"
src2_sha_before="$(sha256sum -- "${Rrep}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID2}.sources" | awk '{print $1}')"
key_mode_before="$(stat -c '%a' "${Rrep}/etc/apt/keyrings/apt-hub.gpg")"

start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-noflag.log" run_add "${Rrep}")"
record_rc "replace_key_without_flag_rejected" "${rc}" 1
key_sha_mid="$(sha256sum -- "${Rrep}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
src_sha_mid="$(sha256sum -- "${Rrep}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" | awk '{print $1}')"
if [[ "${key_sha_mid}" == "${key_sha_before}" && "${src_sha_mid}" == "${src_sha_before}" ]]; then
  pass "replace_key_without_flag_digests_unchanged"
else
  fail "replace_key_without_flag_digests_unchanged"
fi

WRONG_FP='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
rc="$(capture_rc "${BASE}/replace-badfp.log" run_add "${Rrep}" --replace-key "${WRONG_FP}")"
record_rc "replace_key_wrong_fp_rejected" "${rc}" 1
key_sha_mid="$(sha256sum -- "${Rrep}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
src_sha_mid="$(sha256sum -- "${Rrep}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" | awk '{print $1}')"
if [[ "${key_sha_mid}" == "${key_sha_before}" && "${src_sha_mid}" == "${src_sha_before}" ]]; then
  pass "replace_key_wrong_fp_digests_unchanged"
else
  fail "replace_key_wrong_fp_digests_unchanged"
fi

cp -a -- "${BASE}/site-newkey" "${BASE}/site-newkey-badsig"
sig_in="${BASE}/site-newkey-badsig/repos/${SOFTWARE_ID}/dists/${SERIES}/InRelease"
awk 'BEGIN{done=0} /^Suite: / && !done {sub(/noble/,"evil"); done=1} {print}' \
  "${sig_in}" >"${sig_in}.bad"
mv -- "${sig_in}.bad" "${sig_in}"
start_https "${BASE}/site-newkey-badsig"
rc="$(capture_rc "${BASE}/replace-badsig.log" run_add "${Rrep}" --replace-key "${NEW_FP}")"
record_rc "replace_key_bad_signature_rejected" "${rc}" 1
key_sha_mid="$(sha256sum -- "${Rrep}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
src_sha_mid="$(sha256sum -- "${Rrep}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" | awk '{print $1}')"
if [[ "${key_sha_mid}" == "${key_sha_before}" && "${src_sha_mid}" == "${src_sha_before}" ]]; then
  pass "replace_key_bad_signature_digests_unchanged"
else
  fail "replace_key_bad_signature_digests_unchanged"
fi

# 异站共享钥：必须在旧站点 seed，再切到新站点换钥，才能触发替换路径上的同站校验
start_https "${SITE}"
Rdiff="${BASE}/roots/replace-diff-site"
prepare_isolated_root "${Rdiff}"
run_add "${Rdiff}" >"${BASE}/replace-diff-seed.log" 2>&1
cat >"${Rdiff}/etc/apt/sources.list.d/apt-hub-othersite.sources" <<EOF
Types: deb
URIs: mirror+https://other.example.test/tools/repos/othersite/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: ${Rdiff}/etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-diff-site.log" run_add "${Rdiff}" --replace-key "${NEW_FP}")"
record_rc "replace_key_shared_other_site_rejected" "${rc}" 1
got_fp="$(gpg --batch --show-keys --with-colons -- "${Rdiff}/etc/apt/keyrings/apt-hub.gpg" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
got_fp="$(printf '%s' "${got_fp}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
if [[ "${got_fp}" == "${FP}" ]]; then
  pass "replace_key_shared_other_site_key_unchanged"
else
  fail "replace_key_shared_other_site_key_unchanged"
fi

start_https "${SITE}"
Rrollkey="${BASE}/roots/replace-rollback"
prepare_isolated_root "${Rrollkey}"
run_add "${Rrollkey}" "${SOFTWARE_ID2}" >"${BASE}/replace-roll-seed.log" 2>&1
roll_key_sha_before="$(sha256sum -- "${Rrollkey}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
roll_key_mode_before="$(stat -c '%a' "${Rrollkey}/etc/apt/keyrings/apt-hub.gpg")"
chmod a-w -- "${Rrollkey}/etc/apt/sources.list.d"
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-rollback.log" run_add "${Rrollkey}" --replace-key "${NEW_FP}")"
chmod u+w -- "${Rrollkey}/etc/apt/sources.list.d" || true
record_rc "replace_key_sources_fail_rolls_back_key" "${rc}" 1
roll_key_sha_after="$(sha256sum -- "${Rrollkey}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
roll_key_mode_after="$(stat -c '%a' "${Rrollkey}/etc/apt/keyrings/apt-hub.gpg")"
if [[ "${roll_key_sha_after}" == "${roll_key_sha_before}" && "${roll_key_mode_after}" == "${roll_key_mode_before}" ]]; then
  pass "replace_key_sources_fail_key_bytes_mode_restored"
else
  fail "replace_key_sources_fail_key_bytes_mode_restored"
fi
if [[ ! -e "${Rrollkey}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" ]]; then
  pass "replace_key_sources_fail_no_half_sources"
else
  fail "replace_key_sources_fail_no_half_sources"
fi

start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-ok.log" run_add "${Rrep}" --replace-key "${NEW_FP}")"
record_rc "replace_key_with_correct_fp" "${rc}" 0
if [[ "${rc}" -eq 0 ]]; then
  got_fp="$(gpg --batch --show-keys --with-colons -- "${Rrep}/etc/apt/keyrings/apt-hub.gpg" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
  got_fp="$(printf '%s' "${got_fp}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  if [[ "${got_fp}" == "${NEW_FP}" ]]; then
    pass "replace_key_installed_new_fingerprint"
  else
    fail "replace_key_installed_new_fingerprint"
  fi
  src2_sha_after="$(sha256sum -- "${Rrep}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID2}.sources" | awk '{print $1}')"
  if [[ "${src2_sha_after}" == "${src2_sha_before}" ]]; then
    pass "replace_key_peer_sources_unchanged"
  else
    fail "replace_key_peer_sources_unchanged"
  fi
  key_mode_after="$(stat -c '%a' "${Rrep}/etc/apt/keyrings/apt-hub.gpg")"
  if [[ "${key_mode_after}" == "${key_mode_before}" ]]; then
    pass "replace_key_mode_preserved"
  else
    fail "replace_key_mode_preserved"
  fi
  write_apt_conf_for_root "${Rrep}" amd64 "${Rrep}/etc/apt/apt.conf"
  arc="$(capture_rc "${BASE}/replace-apt-update.log" env APT_CONFIG="${Rrep}/etc/apt/apt.conf" timeout 90 apt-get update)"
  record_rc "replace_key_apt_get_update" "${arc}" 0
  if [[ "${arc}" -eq 0 ]]; then
    if grep -R -l "${PKG_NAME}" "${Rrep}/var/lib/apt/lists" >/dev/null 2>&1; then
      pass "replace_key_apt_lists_contain_package"
    else
      fail "replace_key_apt_lists_contain_package"
    fi
  else
    head -n 60 "${BASE}/replace-apt-update.log" | tee -a "${EVIDENCE}" || true
  fi
fi

rc="$(capture_rc "${BASE}/replace-idempotent.log" run_add "${Rrep}" --replace-key "${NEW_FP}")"
record_rc "replace_key_already_installed_idempotent" "${rc}" 0
if grep -q '幂等' "${BASE}/replace-idempotent.log"; then
  pass "replace_key_idempotent_message"
else
  fail "replace_key_idempotent_message"
fi

# 恢复原站点供后续用例
start_https "${SITE}"

log "== 预检：sources 路径是目录（非提交第二步） =="
Rroll="${BASE}/roots/rollback-preflight-dir"
prepare_isolated_root "${Rroll}"
mkdir -p -- "${Rroll}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources"
rc="$(capture_rc "${BASE}/rollback-preflight-dir.log" run_add "${Rroll}")"
record_rc "dest_sources_path_is_dir_preflight_rejected" "${rc}" 1
if [[ ! -e "${Rroll}/etc/apt/keyrings/apt-hub.gpg" ]]; then
  pass "preflight_dir_no_key_written"
else
  fail "preflight_dir_no_key_written"
fi
if grep -q '目的文件路径类型非法\|符号链接\|路径' "${BASE}/rollback-preflight-dir.log"; then
  pass "preflight_dir_reject_message"
else
  fail "preflight_dir_reject_message"
fi

log "== 真提交第二步失败回滚（mv 注入，非预检） =="
mkdir -p -- "${BASE}/bin-fault-sources"
cat >"${BASE}/bin-fault-sources/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dest="${!#}"
case "${dest}" in
  *.sources)
    exit 1
    ;;
esac
exec /bin/mv "$@"
EOF
chmod 0755 -- "${BASE}/bin-fault-sources/mv"
Rcommit="${BASE}/roots/commit-sources-fail"
prepare_isolated_root "${Rcommit}"
rc="$(capture_rc "${BASE}/commit-sources-fail.log" \
  env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u all_proxy \
  PATH="${BASE}/bin-fault-sources:${PATH}" \
  "${ADD}" --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" --root "${Rcommit}" \
  --architecture amd64 --cacert "${TLS}/tls.crt")"
record_rc "commit_second_step_sources_mv_fail" "${rc}" 1
if [[ ! -e "${Rcommit}/etc/apt/keyrings/apt-hub.gpg" ]]; then
  pass "commit_second_step_key_rolled_back"
else
  fail "commit_second_step_key_rolled_back"
fi
if [[ ! -e "${Rcommit}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" ]]; then
  pass "commit_second_step_no_half_sources"
else
  fail "commit_second_step_no_half_sources"
fi
if grep -q '写入 sources 失败' "${BASE}/commit-sources-fail.log"; then
  pass "commit_second_step_fail_message"
else
  fail "commit_second_step_fail_message"
fi
if grep -q '已回滚本次写入' "${BASE}/commit-sources-fail.log"; then
  fail "commit_second_step_no_false_rollback_claim"
else
  pass "commit_second_step_no_false_rollback_claim"
fi

log "== 换钥：多 URI / 续行 / 第二 stanza / symlink peer =="
start_https "${SITE}"
Rmulti="${BASE}/roots/replace-multi-uri"
prepare_isolated_root "${Rmulti}"
run_add "${Rmulti}" >"${BASE}/replace-multi-seed.log" 2>&1

cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-multiuri.sources" <<EOF
Types: deb
URIs: mirror+${SITE_URL}/repos/${SOFTWARE_ID2}/mirror.list mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: ${Rmulti}/etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-multiuri.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_multi_uri_foreign_rejected" "${rc}" 1
got_fp="$(gpg --batch --show-keys --with-colons -- "${Rmulti}/etc/apt/keyrings/apt-hub.gpg" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
got_fp="$(printf '%s' "${got_fp}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
if [[ "${got_fp}" == "${FP}" ]]; then
  pass "replace_key_multi_uri_key_unchanged"
else
  fail "replace_key_multi_uri_key_unchanged"
fi

start_https "${SITE}"
rm -f -- "${Rmulti}/etc/apt/sources.list.d/apt-hub-multiuri.sources"
cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-conturi.sources" <<EOF
Types: deb
URIs: mirror+${SITE_URL}/repos/${SOFTWARE_ID2}/mirror.list
 mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: ${Rmulti}/etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-conturi.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_continued_uri_foreign_rejected" "${rc}" 1

start_https "${SITE}"
rm -f -- "${Rmulti}/etc/apt/sources.list.d/apt-hub-conturi.sources"
cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-twostanza.sources" <<EOF
Types: deb
URIs: mirror+${SITE_URL}/repos/${SOFTWARE_ID2}/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: ${Rmulti}/etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64

Types: deb
URIs: mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: ${Rmulti}/etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-twostanza.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_second_stanza_foreign_rejected" "${rc}" 1

start_https "${SITE}"
rm -f -- "${Rmulti}/etc/apt/sources.list.d/apt-hub-twostanza.sources"
cat >"${BASE}/peer-evil.sources" <<EOF
Types: deb
URIs: mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: ${Rmulti}/etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
ln -s "${BASE}/peer-evil.sources" \
  "${Rmulti}/etc/apt/sources.list.d/apt-hub-peerlink.sources"
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-peerlink.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_symlink_peer_sources_rejected" "${rc}" 1
if grep -q '符号链接' "${BASE}/replace-peerlink.log"; then
  pass "replace_key_symlink_peer_message"
else
  fail "replace_key_symlink_peer_message"
fi

# Signed-By 多 keyring token：本专用钥在列表中亦须校验全部 URIs
start_https "${SITE}"
rm -f -- "${Rmulti}/etc/apt/sources.list.d/apt-hub-peerlink.sources"
cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-multikey.sources" <<EOF
Types: deb
URIs: mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: /etc/apt/keyrings/apt-hub.gpg /etc/apt/keyrings/another.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-multikey.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_signedby_multi_token_foreign_rejected" "${rc}" 1

start_https "${SITE}"
cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-multikey.sources" <<EOF
Types: deb
URIs: mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: /etc/apt/keyrings/another.gpg /etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-multikey-tail.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_signedby_multi_token_tail_foreign_rejected" "${rc}" 1

# Signed-By 续行中的本专用钥
start_https "${SITE}"
cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-multikey.sources" <<EOF
Types: deb
URIs: mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: /etc/apt/keyrings/another.gpg
 /etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-multikey-cont.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_signedby_continued_multi_token_rejected" "${rc}" 1

# Deb822 字段名大小写不敏感
start_https "${SITE}"
cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-multikey.sources" <<EOF
types: deb
uris: mirror+https://other.example.test/tools/repos/evil/mirror.list
suites: ${SERIES}
components: main
signed-by: /etc/apt/keyrings/apt-hub.gpg
architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-lowercase.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_lowercase_fields_foreign_rejected" "${rc}" 1

# 续行间合法 # 注释不得切断 Signed-By / URIs 字段
start_https "${SITE}"
cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-multikey.sources" <<EOF
Types: deb
URIs: mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: /etc/apt/keyrings/another.gpg
# comment between continuation
 /etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-signedby-comment.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_signedby_comment_continuation_rejected" "${rc}" 1

start_https "${SITE}"
cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-multikey.sources" <<EOF
Types: deb
URIs: mirror+${SITE_URL}/repos/${SOFTWARE_ID2}/mirror.list
# comment between uri continuation
 mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: /etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-uris-comment.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_uris_comment_continuation_rejected" "${rc}" 1

# 无关 Signed-By 的异站 URI 不得挡换钥（精确路径，不误命中 .not-ours）
start_https "${SITE}"
rm -f -- "${Rmulti}/etc/apt/sources.list.d/apt-hub-multikey.sources"
cat >"${Rmulti}/etc/apt/sources.list.d/apt-hub-unrelated.sources" <<EOF
Types: deb
URIs: mirror+https://other.example.test/tools/repos/evil/mirror.list
Suites: ${SERIES}
Components: main
Signed-By: /etc/apt/keyrings/apt-hub.gpg.not-ours
Architectures: amd64 arm64
EOF
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-unrelated.log" run_add "${Rmulti}" --replace-key "${NEW_FP}")"
record_rc "replace_key_unrelated_signedby_ignored" "${rc}" 0
# 恢复旧钥现场供后续故障注入（上面已换成新钥）
start_https "${SITE}"
prepare_isolated_root "${Rmulti}"
run_add "${Rmulti}" >"${BASE}/replace-multi-reseed.log" 2>&1

log "== 换钥：sources 失败且恢复旧钥再失败，保留备份 =="
mkdir -p -- "${BASE}/bin-fault-restore"
: >"${BASE}/mv-gpg-writes.count"
cat >"${BASE}/bin-fault-restore/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
dest="\${!#}"
count_file="${BASE}/mv-gpg-writes.count"
case "\${dest}" in
  */apt-hub.gpg)
    n="\$(cat -- "\${count_file}" 2>/dev/null || printf '0')"
    n=\$((n + 1))
    printf '%s\n' "\${n}" >"\${count_file}"
    if [[ "\${n}" -ge 2 ]]; then
      exit 1
    fi
    ;;
  *.sources)
    exit 1
    ;;
esac
exec /bin/mv "\$@"
EOF
chmod 0755 -- "${BASE}/bin-fault-restore/mv"
Rrestfail="${BASE}/roots/replace-restore-fail"
prepare_isolated_root "${Rrestfail}"
run_add "${Rrestfail}" "${SOFTWARE_ID2}" >"${BASE}/replace-restore-seed.log" 2>&1
old_key_sha="$(sha256sum -- "${Rrestfail}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-restore-fail.log" \
  env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u all_proxy \
  PATH="${BASE}/bin-fault-restore:${PATH}" \
  "${ADD}" --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" --root "${Rrestfail}" \
  --architecture amd64 --cacert "${TLS}/tls.crt" --replace-key "${NEW_FP}")"
record_rc "replace_key_restore_fail_nonzero" "${rc}" 1
new_key_sha="$(sha256sum -- "${Rrestfail}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
if [[ "${new_key_sha}" != "${old_key_sha}" ]]; then
  pass "replace_key_restore_fail_left_new_key"
else
  fail "replace_key_restore_fail_left_new_key"
fi
if grep -q '恢复旧公钥失败，备份保留于' "${BASE}/replace-restore-fail.log"; then
  pass "replace_key_restore_fail_backup_message"
else
  fail "replace_key_restore_fail_backup_message"
fi
backup_path="$(awk -F'备份保留于 ' '/恢复旧公钥失败，备份保留于 /{print $2; exit}' "${BASE}/replace-restore-fail.log")"
if [[ -n "${backup_path}" && -f "${backup_path}" && ! -L "${backup_path}" ]]; then
  pass "replace_key_restore_fail_backup_retained"
  backup_mode="$(stat -c '%a' "$(dirname -- "${backup_path}")")"
  if [[ "${backup_mode}" == "700" ]]; then
    pass "replace_key_restore_fail_scratch_mode_0700"
  else
    fail "replace_key_restore_fail_scratch_mode_0700"
  fi
  if cmp -s -- <(sha256sum -- "${backup_path}" | awk '{print $1}') <(printf '%s\n' "${old_key_sha}"); then
    pass "replace_key_restore_fail_backup_is_old_key"
  else
    fail "replace_key_restore_fail_backup_is_old_key"
  fi
else
  fail "replace_key_restore_fail_backup_retained"
  fail "replace_key_restore_fail_scratch_mode_0700"
  fail "replace_key_restore_fail_backup_is_old_key"
fi
if grep -q '已回滚本次写入' "${BASE}/replace-restore-fail.log"; then
  fail "replace_key_restore_fail_no_false_rollback_claim"
else
  pass "replace_key_restore_fail_no_false_rollback_claim"
fi

log "== 换钥：SIGTERM 在新钥已提交、sources 未提交时回滚 =="
mkdir -p -- "${BASE}/bin-fault-term"
cat >"${BASE}/bin-fault-term/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dest="${!#}"
case "${dest}" in
  *.sources)
    kill -TERM "${PPID}" 2>/dev/null || true
    sleep 2
    exit 1
    ;;
esac
exec /bin/mv "$@"
EOF
chmod 0755 -- "${BASE}/bin-fault-term/mv"
Rterm="${BASE}/roots/replace-sigterm"
prepare_isolated_root "${Rterm}"
start_https "${SITE}"
run_add "${Rterm}" "${SOFTWARE_ID2}" >"${BASE}/replace-term-seed.log" 2>&1
term_key_before="$(sha256sum -- "${Rterm}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-sigterm.log" \
  env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u all_proxy \
  PATH="${BASE}/bin-fault-term:${PATH}" \
  "${ADD}" --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" --root "${Rterm}" \
  --architecture amd64 --cacert "${TLS}/tls.crt" --replace-key "${NEW_FP}")"
# INT/TERM 路径非零；具体码依 trap
if [[ "${rc}" -ne 0 ]]; then
  pass "replace_key_sigterm_nonzero"
else
  fail "replace_key_sigterm_nonzero"
fi
term_key_after="$(sha256sum -- "${Rterm}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
if [[ "${term_key_after}" == "${term_key_before}" ]]; then
  pass "replace_key_sigterm_key_restored"
else
  fail "replace_key_sigterm_key_restored"
fi
if [[ ! -e "${Rterm}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" ]]; then
  pass "replace_key_sigterm_no_half_sources"
else
  fail "replace_key_sigterm_no_half_sources"
fi

log "== TERM 落在 rename 成功之后、标志窗口（真实 mv 后发信号） =="
mkdir -p -- "${BASE}/bin-fault-term-after-key" "${BASE}/bin-fault-term-after-sources" \
  "${BASE}/bin-fault-term-after-newkey"
: >"${BASE}/term-after-key.once"
cat >"${BASE}/bin-fault-term-after-key/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
dest="\${!#}"
once="${BASE}/term-after-key.once"
/bin/mv "\$@"
case "\${dest}" in
  */apt-hub.gpg)
    if [[ -f "\${once}" ]]; then
      rm -f -- "\${once}"
      kill -TERM "\${PPID}" 2>/dev/null || true
      sleep 2
    fi
    ;;
esac
EOF
chmod 0755 -- "${BASE}/bin-fault-term-after-key/mv"
Rtermkey="${BASE}/roots/replace-term-after-key"
prepare_isolated_root "${Rtermkey}"
start_https "${SITE}"
run_add "${Rtermkey}" "${SOFTWARE_ID2}" >"${BASE}/replace-term-after-key-seed.log" 2>&1
term_after_key_before="$(sha256sum -- "${Rtermkey}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
peer_src="${Rtermkey}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID2}.sources"
peer_src_before="$(sha256sum -- "${peer_src}" | awk '{print $1}')"
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-term-after-key.log" \
  env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u all_proxy \
  PATH="${BASE}/bin-fault-term-after-key:${PATH}" \
  "${ADD}" --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" --root "${Rtermkey}" \
  --architecture amd64 --cacert "${TLS}/tls.crt" --replace-key "${NEW_FP}")"
if [[ "${rc}" -ne 0 ]]; then
  pass "replace_key_term_after_key_rename_nonzero"
else
  fail "replace_key_term_after_key_rename_nonzero"
fi
term_after_key_after="$(sha256sum -- "${Rtermkey}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
if [[ "${term_after_key_after}" == "${term_after_key_before}" ]]; then
  pass "replace_key_term_after_key_rename_restored"
else
  fail "replace_key_term_after_key_rename_restored"
fi
if [[ ! -e "${Rtermkey}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" ]]; then
  pass "replace_key_term_after_key_rename_no_half_sources"
else
  fail "replace_key_term_after_key_rename_no_half_sources"
fi
peer_src_after="$(sha256sum -- "${peer_src}" | awk '{print $1}')"
if [[ "${peer_src_after}" == "${peer_src_before}" ]]; then
  pass "replace_key_term_after_key_rename_peer_sources_untouched"
else
  fail "replace_key_term_after_key_rename_peer_sources_untouched"
fi

: >"${BASE}/term-after-sources.once"
cat >"${BASE}/bin-fault-term-after-sources/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
dest="\${!#}"
once="${BASE}/term-after-sources.once"
/bin/mv "\$@"
case "\${dest}" in
  *.sources)
    if [[ -f "\${once}" ]]; then
      rm -f -- "\${once}"
      kill -TERM "\${PPID}" 2>/dev/null || true
      sleep 2
    fi
    ;;
esac
EOF
chmod 0755 -- "${BASE}/bin-fault-term-after-sources/mv"
Rtermsrc="${BASE}/roots/replace-term-after-sources"
prepare_isolated_root "${Rtermsrc}"
start_https "${SITE}"
run_add "${Rtermsrc}" "${SOFTWARE_ID2}" >"${BASE}/replace-term-after-sources-seed.log" 2>&1
term_after_src_key_before="$(sha256sum -- "${Rtermsrc}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
start_https "${BASE}/site-newkey"
rc="$(capture_rc "${BASE}/replace-term-after-sources.log" \
  env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u all_proxy \
  PATH="${BASE}/bin-fault-term-after-sources:${PATH}" \
  "${ADD}" --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" --root "${Rtermsrc}" \
  --architecture amd64 --cacert "${TLS}/tls.crt" --replace-key "${NEW_FP}")"
if [[ "${rc}" -ne 0 ]]; then
  pass "replace_key_term_after_sources_rename_nonzero"
else
  fail "replace_key_term_after_sources_rename_nonzero"
fi
term_after_src_key_after="$(sha256sum -- "${Rtermsrc}/etc/apt/keyrings/apt-hub.gpg" | awk '{print $1}')"
if [[ "${term_after_src_key_after}" == "${term_after_src_key_before}" ]]; then
  pass "replace_key_term_after_sources_rename_key_restored"
else
  fail "replace_key_term_after_sources_rename_key_restored"
fi
if [[ ! -e "${Rtermsrc}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" ]]; then
  pass "replace_key_term_after_sources_rename_sources_removed"
else
  fail "replace_key_term_after_sources_rename_sources_removed"
fi

: >"${BASE}/term-after-newkey.once"
cat >"${BASE}/bin-fault-term-after-newkey/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
dest="\${!#}"
once="${BASE}/term-after-newkey.once"
/bin/mv "\$@"
case "\${dest}" in
  */apt-hub.gpg)
    if [[ -f "\${once}" ]]; then
      rm -f -- "\${once}"
      kill -TERM "\${PPID}" 2>/dev/null || true
      sleep 2
    fi
    ;;
esac
EOF
chmod 0755 -- "${BASE}/bin-fault-term-after-newkey/mv"
Rtermnew="${BASE}/roots/term-after-newkey"
prepare_isolated_root "${Rtermnew}"
start_https "${SITE}"
rc="$(capture_rc "${BASE}/term-after-newkey.log" \
  env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u all_proxy \
  PATH="${BASE}/bin-fault-term-after-newkey:${PATH}" \
  "${ADD}" --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" --root "${Rtermnew}" \
  --architecture amd64 --cacert "${TLS}/tls.crt")"
if [[ "${rc}" -ne 0 ]]; then
  pass "new_key_term_after_rename_nonzero"
else
  fail "new_key_term_after_rename_nonzero"
fi
if [[ ! -e "${Rtermnew}/etc/apt/keyrings/apt-hub.gpg" ]]; then
  pass "new_key_term_after_rename_key_removed"
else
  fail "new_key_term_after_rename_key_removed"
fi
if [[ ! -e "${Rtermnew}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" ]]; then
  pass "new_key_term_after_rename_no_sources"
else
  fail "new_key_term_after_rename_no_sources"
fi

log "== scratch 祖先符号链接：拒绝且不写 link 目标 =="
SCRATCH_OUT="${BASE}/scratch-link-outside"
rm -rf -- "${SCRATCH_OUT}"
mkdir -p -- "${SCRATCH_OUT}"
printf 'scratch-sentinel\n' >"${SCRATCH_OUT}/.sentinel"
chmod 0700 -- "${SCRATCH_OUT}"
sent_before="$(sha256sum -- "${SCRATCH_OUT}/.sentinel" | awk '{print $1}')"
# 清掉既有普通目录，再植入祖先 link（目标仅本测试 outside）
Rscr="${BASE}/roots/scratch-ancestor"
prepare_isolated_root "${Rscr}"
start_https "${SITE}"
rm -rf -- "${ROOT}/tmp/add-source-run"
ln -s "${SCRATCH_OUT}" "${ROOT}/tmp/add-source-run"
[[ -L "${ROOT}/tmp/add-source-run" ]] || fail "scratch_ancestor_fixture_not_symlink"
rc="$(capture_rc "${BASE}/scratch-ancestor.log" run_add "${Rscr}")"
record_rc "scratch_ancestor_symlink_rejected" "${rc}" 1
sent_after="$(sha256sum -- "${SCRATCH_OUT}/.sentinel" | awk '{print $1}')"
if [[ "${sent_before}" == "${sent_after}" ]]; then
  pass "scratch_ancestor_sentinel_unchanged"
else
  fail "scratch_ancestor_sentinel_unchanged"
fi
if find -- "${SCRATCH_OUT}" -mindepth 1 -maxdepth 1 ! -name '.sentinel' | grep -q .; then
  fail "scratch_ancestor_no_side_effect_write"
else
  pass "scratch_ancestor_no_side_effect_write"
fi
if grep -q 'scratch 父目录是符号链接' "${BASE}/scratch-ancestor.log"; then
  pass "scratch_ancestor_reject_message"
else
  fail "scratch_ancestor_reject_message"
fi
# dangling
rm -rf -- "${ROOT}/tmp/add-source-run"
ln -s "${SCRATCH_OUT}/missing-dangling" "${ROOT}/tmp/add-source-run"
[[ -L "${ROOT}/tmp/add-source-run" ]] || fail "scratch_dangling_fixture_not_symlink"
rc="$(capture_rc "${BASE}/scratch-dangling.log" run_add "${Rscr}")"
record_rc "scratch_dangling_symlink_rejected" "${rc}" 1
if grep -q 'scratch 父目录是符号链接' "${BASE}/scratch-dangling.log"; then
  pass "scratch_dangling_reject_message"
else
  fail "scratch_dangling_reject_message"
fi
rm -rf -- "${ROOT}/tmp/add-source-run"

start_https "${SITE}"

log "== 同根不同 software 双进程竞争（共享锁） =="
Rconc="${BASE}/roots/concurrent"
prepare_isolated_root "${Rconc}"
(
  run_add "${Rconc}" "${SOFTWARE_ID}" >"${BASE}/conc-a.log" 2>&1
  echo $? >"${BASE}/conc-a.rc"
) &
pid_a=$!
(
  run_add "${Rconc}" "${SOFTWARE_ID2}" >"${BASE}/conc-b.log" 2>&1
  echo $? >"${BASE}/conc-b.rc"
) &
pid_b=$!
wait "${pid_a}" || true
wait "${pid_b}" || true
rc_a="$(cat "${BASE}/conc-a.rc")"
rc_b="$(cat "${BASE}/conc-b.rc")"
log "CASE concurrent_two_software: a=${rc_a} b=${rc_b}"
if [[ "${rc_a}" -eq 0 && "${rc_b}" -eq 0 ]]; then
  pass "concurrent_two_software_both_ok"
else
  fail "concurrent_two_software_both_ok"
  cat "${BASE}/conc-a.log" >>"${EVIDENCE}" || true
  cat "${BASE}/conc-b.log" >>"${EVIDENCE}" || true
fi
if [[ -f "${Rconc}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID}.sources" \
   && -f "${Rconc}/etc/apt/sources.list.d/apt-hub-${SOFTWARE_ID2}.sources" \
   && -f "${Rconc}/etc/apt/keyrings/apt-hub.gpg" ]]; then
  pass "concurrent_shared_key_and_both_sources"
else
  fail "concurrent_shared_key_and_both_sources"
fi
# 单把锁文件名
if [[ -f "${Rconc}/etc/apt/keyrings/.apt-hub-add-source.lock" ]]; then
  pass "shared_root_lock_file"
else
  fail "shared_root_lock_file"
fi

log "== 成功自删副本 / 源码不删 / 失败保留 =="
cp -f -- "${ADD}" "${BASE}/copies/add_source.sh"
chmod 0755 -- "${BASE}/copies/add_source.sh"
Rdel="${BASE}/roots/selfdel"
prepare_isolated_root "${Rdel}"
(
  cd -- "${BASE}/copies"
  rc=0
  ./add_source.sh --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" \
    --root "${Rdel}" --architecture amd64 --cacert "${TLS}/tls.crt" >"${BASE}/selfdel.log" 2>&1 || rc=$?
  printf '%s\n' "${rc}" >"${BASE}/selfdel.rc"
)
rc="$(cat "${BASE}/selfdel.rc")"
record_rc "self_delete_success_rc" "${rc}" 0
if [[ ! -e "${BASE}/copies/add_source.sh" ]]; then pass "self_delete_removed_copy"; else fail "self_delete_removed_copy"; fi
if [[ -x "${ADD}" ]]; then pass "self_delete_kept_source_original"; else fail "self_delete_kept_source_original"; fi

cp -f -- "${ADD}" "${BASE}/copies/add_source.sh"
chmod 0755 -- "${BASE}/copies/add_source.sh"
Rkeep="${BASE}/roots/keepfail"
prepare_isolated_root "${Rkeep}" "jammy" amd64 symlink
(
  cd -- "${BASE}/copies"
  rc=0
  ./add_source.sh --site-url "${SITE_URL}" --software "${SOFTWARE_ID}" \
    --root "${Rkeep}" --architecture amd64 --cacert "${TLS}/tls.crt" >"${BASE}/keepfail.log" 2>&1 || rc=$?
  printf '%s\n' "${rc}" >"${BASE}/keepfail.rc"
)
rc="$(cat "${BASE}/keepfail.rc")"
record_rc "failure_keeps_script_rc" "${rc}" 1
if [[ -f "${BASE}/copies/add_source.sh" ]]; then pass "failure_keeps_script"; else fail "failure_keeps_script"; fi

log "== 非法 site-url =="
Rurl="${BASE}/roots/badurl"
prepare_isolated_root "${Rurl}"
rc="$(capture_rc "${BASE}/badurl.log" \
  "${ADD}" --site-url 'https://user:pass@127.0.0.2:18771' --software "${SOFTWARE_ID}" \
  --root "${Rurl}" --architecture amd64 --cacert "${TLS}/tls.crt")"
record_rc "reject_userinfo_url" "${rc}" 1
rc="$(capture_rc "${BASE}/localhost.log" \
  "${ADD}" --site-url 'https://127.0.0.1:18771' --software "${SOFTWARE_ID}" \
  --root "${Rurl}" --architecture amd64 --cacert "${TLS}/tls.crt")"
record_rc "reject_localhost" "${rc}" 1

log "== 系统 APT sha 对照 =="
system_apt_sha >"${SYSTEM_SHA_AFTER}"
if cmp -s -- "${SYSTEM_SHA_BEFORE}" "${SYSTEM_SHA_AFTER}"; then
  pass "system_apt_sha_before_after_match"
else
  fail "system_apt_sha_before_after_match"
fi

log "== 统计 =="
TOTAL=$((PASS + FAIL))
log "TOTAL=${TOTAL} PASS=${PASS} FAIL=${FAIL}"
echo "TOTAL=${TOTAL} PASS=${PASS} FAIL=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
