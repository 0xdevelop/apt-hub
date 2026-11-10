#!/usr/bin/env bash
# C 路径自测：发行版筛选、每软件 repos 隔离 APT、workflow 元数据契约。证据只写 tmp/metadata-C。
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$ROOT"
export LC_ALL=C
export LANG=C
export LANGUAGE=C

REL="$ROOT/scripts/ubuntu_releases.sh"
VER="$ROOT/scripts/verify_ubuntu.sh"
PUB=".github/workflows/ubuntu-publish.yml"
TST=".github/workflows/ubuntu-test.yml"
BASE="$ROOT/tmp/metadata-C"
mkdir -p "$ROOT/tmp"
# 只清本路自测子树，不动 probe / A / B / controller 证据。
# 入场前只停确切本测试 GNUPGHOME agent，再清测试子树；拒 symlink。
TEST_GPG_HOME="$BASE/test/gnupg"
if [[ -L "$TEST_GPG_HOME" ]]; then
  echo "ubuntu_test: 拒绝 symlink 的 test/gnupg: $TEST_GPG_HOME" >&2
  exit 2
fi
if [[ -d "$TEST_GPG_HOME" ]]; then
  gpgconf --homedir "$TEST_GPG_HOME" --kill all >/dev/null 2>&1 || true
fi
rm -rf "$BASE/test"
mkdir -p "$BASE/test" "$BASE/bin"
BASE="$BASE/test"
GPGHOME="$BASE/gnupg"

# 退场：只杀本测试 agent 并移除测试私钥材料；保留日志/签名/公钥证据。
# EXIT trap 调用；SC2317 误报死代码。
# shellcheck disable=SC2317
scrub_ubuntu_test_gpg() {
  local home="$GPGHOME"
  if [[ -L "$home" ]]; then
    echo "ubuntu_test: 拒绝清理 symlink gnupg: $home" >&2
    return 0
  fi
  if [[ -d "$home" ]]; then
    gpgconf --homedir "$home" --kill all >/dev/null 2>&1 || true
    rm -rf -- "$home/private-keys-v1.d" "$home/openpgp-revocs.d" 2>/dev/null || true
    rm -f -- "$home/pubring.kbx" "$home/pubring.kbx~" "$home/trustdb.gpg" \
      "$home/random_seed" "$home/S.gpg-agent" "$home/S.gpg-agent."* 2>/dev/null || true
  fi
}
trap 'scrub_ubuntu_test_gpg' EXIT

failures=0
pass() { echo "OK  $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

expect_rc() {
  local name="$1" want="$2"
  shift 2
  local rc=0
  set +e
  "$@"
  rc=$?
  set -e
  if [[ "$rc" -eq "$want" ]]; then
    pass "$name (exit $rc)"
  else
    fail "$name (want exit $want, got $rc)"
  fi
}

snap_system() {
  {
    sha256sum /etc/apt/sources.list /var/lib/dpkg/status /usr/share/keyrings/ubuntu-archive-keyring.gpg 2>/dev/null
    find /etc/apt/sources.list.d /etc/apt/trusted.gpg.d /etc/apt/apt.conf.d -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null
  } | sha256sum | awk '{print $1}'
}

independent_filter() {
  local csv="$1" today="$2"
  awk -v today="$today" -F, '
    function isdate(s) { return s ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ }
    NR == 1 { next }
    {
      gsub(/\r/, "")
      version = $1
      series = $3
      rel = $5
      eol = $6
      eol_server = $7
      std = (eol_server != "" ? eol_server : eol)
      if (series == "" || version == "") next
      if (!isdate(rel) || !isdate(std)) next
      if (rel > today) next
      if (std <= today) next
      print series
    }
  ' "$csv" | sort
}

build_deb() {
  local name="$1" ver="$2" arch="$3" depends="$4" dest="$5"
  local pkgdir="$BASE/pkgbuild/${name}_${arch}"
  rm -rf "$pkgdir"
  mkdir -p "$pkgdir/DEBIAN"
  cat >"$pkgdir/DEBIAN/control" <<EOF
Package: ${name}
Version: ${ver}
Section: misc
Priority: optional
Architecture: ${arch}
Depends: ${depends}
Maintainer: apt-hub verify fixture <apt-hub-test@invalid>
Description: apt-hub verify fixture, not for production
EOF
  dpkg-deb --root-owner-group -b "$pkgdir" "$dest" >/dev/null
}

make_gpg_home() {
  local gpghome="$1"
  if [[ -L "$gpghome" ]]; then
    echo "ubuntu_test: 拒绝 symlink gnupg: $gpghome" >&2
    return 2
  fi
  # 重建前先停本 home agent，避免残留 agent 指向已删目录导致 agent_genkey 失败。
  if [[ -d "$gpghome" ]]; then
    gpgconf --homedir "$gpghome" --kill all >/dev/null 2>&1 || true
  fi
  rm -rf "$gpghome"
  mkdir -p "$gpghome"
  chmod 700 "$gpghome"
  cat >"$BASE/gpg-batch" <<'EOF'
%echo generating apt-hub verify fixture key, not for production
Key-Type: RSA
Key-Length: 2048
Name-Real: apt-hub verify fixture
Name-Email: apt-hub-verify-fixture@invalid
Expire-Date: 2d
%no-protection
%commit
%echo done
EOF
  gpg --homedir "$gpghome" --batch --generate-key "$BASE/gpg-batch" >/dev/null 2>"$BASE/gpg-gen.log"
}

sign_release() {
  local gpghome="$1" dist="$2"
  gpg --homedir "$gpghome" --batch --yes --pinentry-mode loopback \
    --clearsign -o "$dist/InRelease" "$dist/Release"
  gpg --homedir "$gpghome" --batch --yes --pinentry-mode loopback \
    --detach-sign --armor -o "$dist/Release.gpg" "$dist/Release"
}

# 独立构造 schema2 / repos/<id> 元数据站点，不调用 A 的 sync.sh。
# 参数: site gpghome series_csv 以及多组 id|pkg|ver|dep|origin|relpath_prefix
build_metadata_site() {
  local site="$1" gpghome="$2" series_csv="$3"
  shift 3
  local entries=("$@")
  local series_json packages_json ent id pkg ver dep origin relprefix
  local arch series deb size sha filename url assets_json apt_uri h
  rm -rf "$site"
  mkdir -p "$site/repos"
  series_json=$(printf '%s' "$series_csv" | jq -R 'split(",")')
  packages_json='[]'
  for ent in "${entries[@]}"; do
    IFS='|' read -r id pkg ver dep origin relprefix <<<"$ent"
    mkdir -p "$site/repos/$id"
    rm -rf "$BASE/tmp-pool-$id"
    mkdir -p "$BASE/tmp-pool-$id"
    assets_json='[]'
    for arch in amd64 arm64; do
      deb="$BASE/tmp-pool-$id/${pkg}_${ver}_${arch}.deb"
      build_deb "$pkg" "$ver" "$arch" "$dep" "$deb"
      size=$(stat -c '%s' "$deb")
      sha=$(sha256sum "$deb" | awk '{print $1}')
      filename="${relprefix}/${pkg}_${ver}_${arch}.deb"
      url="${origin%/}/${filename}"
      assets_json=$(jq -c --arg a "$arch" --arg f "$filename" --arg s "$sha" --arg z "$size" --arg u "$url" \
        '. + [{architecture:$a,filename:$f,sha256:$s,size:$z,url:$u}]' <<<"$assets_json")
    done
    IFS=',' read -r -a series_list <<<"$series_csv"
    for series in "${series_list[@]}"; do
      for arch in amd64 arm64; do
        deb="$BASE/tmp-pool-$id/${pkg}_${ver}_${arch}.deb"
        size=$(stat -c '%s' "$deb")
        sha=$(sha256sum "$deb" | awk '{print $1}')
        filename="${relprefix}/${pkg}_${ver}_${arch}.deb"
        mkdir -p "$site/repos/$id/dists/${series}/main/binary-${arch}/by-hash/SHA256"
        cat >"$site/repos/$id/dists/${series}/main/binary-${arch}/Packages" <<EOF
Package: ${pkg}
Version: ${ver}
Architecture: ${arch}
Maintainer: apt-hub verify fixture <apt-hub-test@invalid>
Depends: ${dep}
Filename: ${filename}
Size: ${size}
SHA256: ${sha}
Description: apt-hub verify fixture, not for production

EOF
        gzip -9c "$site/repos/$id/dists/${series}/main/binary-${arch}/Packages" \
          >"$site/repos/$id/dists/${series}/main/binary-${arch}/Packages.gz"
        h=$(sha256sum "$site/repos/$id/dists/${series}/main/binary-${arch}/Packages" | awk '{print $1}')
        cp "$site/repos/$id/dists/${series}/main/binary-${arch}/Packages" \
          "$site/repos/$id/dists/${series}/main/binary-${arch}/by-hash/SHA256/$h"
        h=$(sha256sum "$site/repos/$id/dists/${series}/main/binary-${arch}/Packages.gz" | awk '{print $1}')
        cp "$site/repos/$id/dists/${series}/main/binary-${arch}/Packages.gz" \
          "$site/repos/$id/dists/${series}/main/binary-${arch}/by-hash/SHA256/$h"
      done
      cat >"$BASE/apt-ftparchive-${id}-${series}.conf" <<EOF
APT::FTPArchive::Release::Origin "apt-hub-test";
APT::FTPArchive::Release::Label "apt-hub-test";
APT::FTPArchive::Release::Suite "${series}";
APT::FTPArchive::Release::Codename "${series}";
APT::FTPArchive::Release::Architectures "amd64 arm64";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "apt-hub metadata fixture";
EOF
      apt-ftparchive -c "$BASE/apt-ftparchive-${id}-${series}.conf" release \
        "$site/repos/$id/dists/${series}" >"$site/repos/$id/dists/${series}/Release"
      sign_release "$gpghome" "$site/repos/$id/dists/${series}"
      cat >"$site/repos/$id/${series}.sources" <<EOF
Types: deb
URIs: mirror+https://example.invalid/repos/${id}/mirror.list
Suites: ${series}
Components: main
Signed-By: /etc/apt/keyrings/apt-hub.gpg
Architectures: amd64 arm64
EOF
    done
    printf 'https://example.invalid/repos/%s/\tpriority:1 type:index\n%s/\tpriority:1 type:deb\n' \
      "$id" "${origin%/}" >"$site/repos/$id/mirror.list"
    apt_uri="mirror+https://example.invalid/repos/${id}/mirror.list"
    packages_json=$(jq -c --arg id "$id" --arg pkg "$pkg" --arg ver "$ver" --arg origin "$origin" \
      --arg uri "$apt_uri" --argjson series "$series_json" --argjson assets "$assets_json" \
      --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      . + [{
        id:$id,
        package:$pkg,
        repository:("apt-hub/"+$id),
        description:("verify fixture "+$id),
        version:$ver,
        release_url:($origin+"/"+ $id),
        source_url:($origin+"/"+ $id),
        license:"MIT",
        updated_at:$checked,
        ubuntu_series:$series,
        architectures:["amd64","arm64"],
        apt_source_uri:$uri,
        assets:$assets
      }]
    ' <<<"$packages_json")
    rm -rf "$BASE/tmp-pool-$id"
  done
  gpg --homedir "$gpghome" --batch --export --armor >"$site/apt-hub.gpg"
  jq -n --argjson packages "$packages_json" --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:"2", packages:$packages, checked_at:$checked}' >"$site/state.json"
  printf '<html>apt-hub metadata fixture</html>\n' >"$site/index.html"
  printf '#!/usr/bin/env bash\n# Metadata fixture only; not an installer.\n' >"$site/add_source.sh"
  chmod 0644 "$site/add_source.sh"
  if find "$site" -name '*.deb' | grep -q .; then
    echo "build_metadata_site 内部错误: 站点含 deb" >&2
    return 1
  fi
}

write_releases() {
  local dest="$1"
  shift
  local arr='[]'
  local item
  for item in "$@"; do
    IFS='|' read -r series version release_date eol_date <<<"$item"
    arr=$(jq -c --arg series "$series" --arg version "$version" --arg release_date "$release_date" --arg eol_date "$eol_date" \
      '. + [{series:$series,version:$version,release_date:$release_date,eol_date:$eol_date}]' <<<"$arr")
  done
  jq -n --argjson releases "$arr" --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1,source_url:"https://salsa.debian.org/debian/distro-info-data/-/raw/main/ubuntu.csv",checked_at:$checked,releases:$releases}' \
    >"$dest"
}

find_shellcheck() {
  if command -v shellcheck >/dev/null 2>&1; then
    command -v shellcheck
    return 0
  fi
  if [[ -x "$ROOT/tmp/metadata-C/bin/shellcheck" ]]; then
    printf '%s\n' "$ROOT/tmp/metadata-C/bin/shellcheck"
    return 0
  fi
  return 1
}

echo "== bash -n / shellcheck =="
if bash -n "$REL" && bash -n "$VER" && bash -n "$ROOT/tests/ubuntu_test.sh"; then
  pass "bash -n C 脚本"
else
  fail "bash -n C 脚本"
fi
SC_BIN=""
if SC_BIN=$(find_shellcheck); then
  sc_log="$BASE/shellcheck.gcc"
  set +e
  "$SC_BIN" -f gcc -s bash "$REL" "$VER" "$ROOT/tests/ubuntu_test.sh" >"$sc_log" 2>&1
  sc_rc=$?
  set -e
  if [[ "$sc_rc" -eq 0 ]]; then
    pass "shellcheck"
  else
    fail "shellcheck exit=$sc_rc"
    head -n 30 "$sc_log" | while IFS= read -r line; do
      fail "shellcheck-diag $line"
    done
  fi
else
  fail "shellcheck 不可用，不能跳过 lint"
fi

echo "== 用法与越界 =="
expect_rc "ubuntu_releases 无参数" 2 "$REL"
expect_rc "verify_ubuntu 无参数" 2 "$VER"
expect_rc "输出跳出 tmp" 1 "$REL" --output /tmp/ubuntu-releases-outside.json

echo "== 夹具 CSV：ESM 不是标准支持 =="
fixture_csv="$BASE/ubuntu.fixture.csv"
cat >"$fixture_csv" <<'EOF'
version,codename,series,created,release,eol,eol-server,eol-esm,eol-legacy
14.04 LTS,Trusty Tahr,trusty,2013-10-17,2014-04-17,2019-04-25,2019-04-25,2024-04-25,2029-04-26
20.04 LTS,Focal Fossa,focal,2019-10-17,2020-04-23,2025-05-29,2025-05-29,2030-04-23,2035-04-26
22.04 LTS,Jammy Jellyfish,jammy,2021-10-14,2022-04-21,2027-06-01,2027-06-01,2032-04-21,2037-04-30
24.04 LTS,Noble Numbat,noble,2023-10-12,2024-04-25,2029-05-31,2029-05-31,2034-04-25,2039-04-28
25.10,Questing Quokka,questing,2025-04-17,2025-10-09,2026-07-09
26.04 LTS,Resolute Raccoon,resolute,2025-10-09,2026-04-23,2031-05-29,2031-05-29,2036-04-23,2041-04-30
26.10,Stonking Stingray,stonking,2026-04-24,2026-10-15,2027-07-15
27.04,Tenacious T-Rex,tenacious,2026-10-16,2027-04-22,2028-01-20
99.04,Unreleased Example,unreleased,2026-10-16,,,
EOF

fixture_out="$BASE/releases.fixture.json"
"$REL" --output "$fixture_out" --csv "$fixture_csv"
got_series=$(jq -r '.releases[].series' "$fixture_out" | sort | tr '\n' ' ')
today=$(date -u +%Y-%m-%d)
want_series=$(independent_filter "$fixture_csv" "$today" | tr '\n' ' ')
if [[ "$got_series" == "$want_series" ]]; then
  pass "夹具筛选与独立 CSV 过滤一致: $got_series"
else
  fail "夹具筛选不一致 got=[$got_series] want=[$want_series]"
fi
if jq -e '.releases[].series | select(.=="trusty" or .=="focal" or .=="questing" or .=="tenacious" or .=="unreleased")' "$fixture_out" >/dev/null; then
  fail "夹具输出含 ESM/已结束/未发布版本"
else
  pass "夹具排除 trusty/focal/questing/tenacious/unreleased"
fi
if jq -e '.releases | map(.series) | index("jammy") and index("noble") and index("resolute") and index("stonking")' "$fixture_out" >/dev/null; then
  pass "夹具包含当前标准支持 jammy/noble/resolute/stonking"
else
  fail "夹具缺少当前标准支持版本: $(jq -c '[.releases[].series]' "$fixture_out")"
fi

echo "== malformed 已发布行不得静默丢掉 =="
malformed_csv="$BASE/ubuntu.malformed.csv"
cat >"$malformed_csv" <<'EOF'
version,codename,series,created,release,eol,eol-server,eol-esm,eol-legacy
22.04 LTS,Jammy Jellyfish,jammy,2021-10-14,2022-04-21,2027-06-01,2027-06-01,2032-04-21,2037-04-30
24.04 LTS,Broken Current,broken,2023-10-12,2024-04-25,not-a-date
EOF
expect_rc "malformed 当前版本行拒绝" 1 "$REL" --output "$BASE/malformed.json" --csv "$malformed_csv"
if [[ ! -e "$BASE/malformed.json" ]]; then
  pass "malformed 未写出 releases.json"
else
  fail "malformed 仍写出了 releases.json"
fi

echo "== 拒绝非官方 CSV 结构 =="
printf 'Dist: trusty\nSupported: 1\n' >"$BASE/meta-release.txt"
expect_rc "拒绝 meta-release 当 CSV" 1 "$REL" --output "$BASE/bad1.json" --csv "$BASE/meta-release.txt"
printf 'Invalid OpenID transaction\n' >"$BASE/openid.txt"
expect_rc "拒绝 OpenID 错误页" 1 "$REL" --output "$BASE/bad2.json" --csv "$BASE/openid.txt"

echo "== 真实下载官方 CSV + 交叉对照 =="
live_out="$BASE/releases.live.json"
if "$REL" --output "$live_out"; then
  live_series=$(jq -r '.releases[].series' "$live_out" | sort)
  echo "$live_series" >"$BASE/live.series.txt"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 60 \
    -o "$BASE/ubuntu.live.csv" \
    https://salsa.debian.org/debian/distro-info-data/-/raw/main/ubuntu.csv
  indep=$(independent_filter "$BASE/ubuntu.live.csv" "$today")
  if [[ "$live_series" == "$indep" ]]; then
    pass "live 输出与独立过滤官方 CSV 一致"
  else
    fail "live 与独立过滤不一致"
  fi
  if echo "$live_series" | grep -Eq '^(trusty|xenial|bionic|focal|oracular|plucky|questing)$'; then
    fail "live 输出含非标准支持 series"
  else
    pass "live 不含 focal/trusty/questing 等非标准支持版本"
  fi
else
  fail "live ubuntu_releases.sh 失败"
fi

echo "== 构造 schema2 元数据站点并隔离验证 =="
make_gpg_home "$GPGHOME"
sys_before=$(snap_system)

pos_site="$BASE/site-ok"
pos_rel="$BASE/releases-ok.json"
pos_work="$BASE/verify-ok"
if [[ -f "$fixture_out" ]]; then
  cp "$fixture_out" "$pos_rel"
  pos_series_csv=$(jq -r '[.releases[].series] | join(",")' "$pos_rel")
else
  write_releases "$pos_rel" \
    'jammy|22.04 LTS|2022-04-21|2027-06-01' \
    'noble|24.04 LTS|2024-04-25|2029-05-31'
  pos_series_csv="jammy,noble"
fi
pos_combo_want=$(jq '[.releases[].series] | length * 2' "$pos_rel")
build_metadata_site "$pos_site" "$GPGHOME" "$pos_series_csv" \
  'testpkg-alpha|testpkg-alpha|1.0.0|libc6|https://github.com|example/alpha/releases/download/1.0.0' \
  'testpkg-beta|testpkg-beta|2.0.0|libc6|https://github.com|example/beta/releases/download/2.0.0'

if [[ -f "$pos_site/repos/testpkg-alpha/mirror.list" ]]; then
  pass "站点含 repos/<id>/mirror.list"
else
  fail "缺少 per-repo mirror.list"
fi
if jq -e '.schema_version=="2" and (.packages|length)==2 and all(.packages[]; .apt_source_uri and (.assets|length)==2)' \
  "$pos_site/state.json" >/dev/null; then
  pass "state schema2 + apt_source_uri + assets"
else
  fail "state 不符合 schema2: $(head -c 200 "$pos_site/state.json")"
fi
if find "$pos_site" -name '*.deb' | grep -q .; then
  fail "元数据站点含 deb"
else
  pass "元数据站点无 deb"
fi
cand_hash_before=$(sha256sum "$pos_site/repos/testpkg-alpha/mirror.list" | awk '{print $1}')

if "$VER" --site "$pos_site" --releases "$pos_rel" --work-dir "$pos_work"; then
  if jq -e --argjson n "$pos_combo_want" \
    '.ok==true and (.results|length)==$n and all(.results[]; .ok==true and .failure_class==null)' \
    "$pos_work/summary.json" >/dev/null; then
    pass "正向: ${pos_series_csv} × amd64/arm64 精确版本依赖可解析"
  else
    fail "正向 summary 不符合: $(cat "$pos_work/summary.json")"
  fi
  if jq -e 'all(.results[]; .packages|length==2)' "$pos_work/summary.json" >/dev/null; then
    pass "正向每组合含两个软件"
  else
    fail "正向软件数量"
  fi
  if [[ -n "$(find "$pos_work" -name '*.mirror.list' -print -quit)" ]]; then
    pass "work 内生成 mirror+file 列表"
  else
    fail "work 未生成 mirror.list 覆盖"
  fi
  if grep -Rq -- 'mirror+file:' "$pos_work" --include='apt-hub-*.list'; then
    pass "隔离源使用 mirror+file"
  else
    fail "隔离源未使用 mirror+file"
  fi
  # 候选 mirror.list 未被改写
  cand_hash_after=$(sha256sum "$pos_site/repos/testpkg-alpha/mirror.list" | awk '{print $1}')
  if [[ "$cand_hash_before" == "$cand_hash_after" ]]; then
    pass "候选 mirror.list 未被改写"
  else
    fail "候选 mirror.list 被改写"
  fi
  sample_mirror=$(find "$pos_work" -name 'testpkg-alpha.mirror.list' -print -quit)
  if [[ -n "$sample_mirror" ]] && grep -Eq $'^file:.*/repos/testpkg-alpha/\t.*type:index' "$sample_mirror"; then
    pass "work mirror type:index 指向本地 repos"
  else
    fail "work mirror type:index 未指向本地 file"
  fi
  if [[ -n "$sample_mirror" ]] && grep -Eq $'^https://github.com/\t.*type:deb' "$sample_mirror"; then
    pass "work mirror type:deb 仍为官方 HTTPS"
  else
    fail "work mirror 丢失 type:deb 官方来源"
  fi
  mode_ok=true
  while IFS= read -r conf; do
    if ! grep -Fq 'APT::Update::Error-Mode "any"' "$conf"; then
      mode_ok=false
    fi
  done < <(find "$pos_work" -path '*/apt-root/etc/apt/apt.conf')
  if [[ "$mode_ok" == true ]]; then
    pass "APT::Update::Error-Mode=any"
  else
    fail "APT 配置缺少 Error-Mode=any"
  fi
  expect_rc "已有非空 work 拒绝" 1 "$VER" --site "$pos_site" --releases "$pos_rel" --work-dir "$pos_work"
  # find 失败且 stdout 空：不得当空目录；拒前无 .owned
  find_fail_work="$BASE/verify-find-exit2"
  find_fail_bin="$BASE/bin-find-exit2"
  rm -rf -- "$find_fail_work" "$find_fail_bin"
  mkdir -p -- "$find_fail_work" "$find_fail_bin"
  cat >"$find_fail_bin/find" <<'EOF'
#!/bin/sh
exit 2
EOF
  chmod 0755 -- "$find_fail_bin/find"
  set +e
  PATH="$find_fail_bin:$PATH" "$VER" --site "$pos_site" --releases "$pos_rel" --work-dir "$find_fail_work" \
    >"$BASE/verify-find-exit2.stdout" 2>"$BASE/verify-find-exit2.stderr"
  find_fail_rc=$?
  set -e
  if [[ "$find_fail_rc" -ne 0 ]] && [[ ! -e "$find_fail_work/.apt-hub-verify.owned" ]] \
    && grep -Fq '不可访问' "$BASE/verify-find-exit2.stderr"; then
    pass "find exit2 空 stdout 拒绝且无 owned"
  else
    fail "find exit2 未按完整性拒绝 rc=$find_fail_rc"
  fi
else
  fail "正向 verify_ubuntu 失败，见 $pos_work"
  find "$pos_work" -name 'result.json' -o -name '*.log' 2>/dev/null | while read -r f; do
    echo "---- $f ----"
    tail -n 40 "$f" || true
  done
fi

echo "== work/site 重叠与符号链接 =="
anc="$BASE/overlap-work-ancestor"
mkdir -p "$anc/site"
printf 'keep-work\n' >"$anc/KEEP_WORK"
expect_rc "work 为 site 祖先拒绝" 1 "$VER" --site "$anc/site" --releases "$pos_rel" --work-dir "$anc"
if [[ -f "$anc/KEEP_WORK" ]]; then
  pass "祖先重叠未删除 work 哨兵"
else
  fail "祖先重叠删除了 work 哨兵"
fi
mkdir -p "$BASE/symlink-target"
ln -sfn "$BASE/symlink-target" "$BASE/symlink-work"
expect_rc "work 祖先含符号链接拒绝" 1 "$VER" --site "$pos_site" --releases "$pos_rel" --work-dir "$BASE/symlink-work/child"

echo "== 依赖不可解 =="
dep_site="$BASE/site-dep"
dep_work="$BASE/verify-dep"
build_metadata_site "$dep_site" "$GPGHOME" "noble" \
  'testpkg-alpha|testpkg-alpha|1.0.0|libc6|https://github.com|example/alpha/releases/download/1.0.0' \
  'testpkg-beta|testpkg-beta|2.0.0|apt-hub-no-such-package-xyz|https://github.com|example/beta/releases/download/2.0.0'
write_releases "$BASE/releases-noble.json" 'noble|24.04 LTS|2024-04-25|2029-05-31'
set +e
"$VER" --site "$dep_site" --releases "$BASE/releases-noble.json" --work-dir "$dep_work"
dep_rc=$?
set -e
if [[ "$dep_rc" -eq 1 ]] && jq -e '.ok==false and any(.results[]; .failure_class=="dependency")' "$dep_work/summary.json" >/dev/null; then
  pass "依赖失败 class=dependency 且整批拒绝"
else
  fail "依赖失败分类错误 rc=$dep_rc summary=$(cat "$dep_work/summary.json" 2>/dev/null || true)"
fi

echo "== 网络/抓取失败不是依赖 =="
net_site="$BASE/site-net"
net_work="$BASE/verify-net"
build_metadata_site "$net_site" "$GPGHOME" "noble" \
  'testpkg-alpha|testpkg-alpha|1.0.0|libc6|https://github.com|example/alpha/releases/download/1.0.0'
jq '.packages[].ubuntu_series=["nosuchsuite"]' "$net_site/state.json" >"$net_site/state.json.tmp"
mv "$net_site/state.json.tmp" "$net_site/state.json"
mkdir -p "$net_site/repos/testpkg-alpha/dists/nosuchsuite/main/binary-amd64" \
  "$net_site/repos/testpkg-alpha/dists/nosuchsuite/main/binary-arm64"
for arch in amd64 arm64; do
  cp "$net_site/repos/testpkg-alpha/dists/noble/main/binary-${arch}/Packages" \
    "$net_site/repos/testpkg-alpha/dists/nosuchsuite/main/binary-${arch}/Packages"
  cp "$net_site/repos/testpkg-alpha/dists/noble/main/binary-${arch}/Packages.gz" \
    "$net_site/repos/testpkg-alpha/dists/nosuchsuite/main/binary-${arch}/Packages.gz"
done
cp "$net_site/repos/testpkg-alpha/dists/noble/Release" "$net_site/repos/testpkg-alpha/dists/nosuchsuite/Release"
sed -i 's/noble/nosuchsuite/g' "$net_site/repos/testpkg-alpha/dists/nosuchsuite/Release"
sign_release "$GPGHOME" "$net_site/repos/testpkg-alpha/dists/nosuchsuite"
write_releases "$BASE/releases-net.json" 'nosuchsuite|99.99|2020-01-01|2099-01-01'
set +e
env LANGUAGE=zh_CN:zh LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \
  "$VER" --site "$net_site" --releases "$BASE/releases-net.json" --work-dir "$net_work"
net_rc=$?
set -e
if [[ "$net_rc" -eq 1 ]] && jq -e '.ok==false and any(.results[]; .failure_class=="network") and all(.results[] | select(.ok==false); .failure_class!="dependency")' "$net_work/summary.json" >/dev/null; then
  pass "官方源 404 记为 network，不是 dependency"
else
  fail "网络失败分类错误 rc=$net_rc summary=$(cat "$net_work/summary.json" 2>/dev/null || true)"
fi

echo "== 签名篡改拒绝 =="
sig_site="$BASE/site-sig"
sig_work="$BASE/verify-sig"
build_metadata_site "$sig_site" "$GPGHOME" "noble" \
  'testpkg-alpha|testpkg-alpha|1.0.0|libc6|https://github.com|example/alpha/releases/download/1.0.0'
echo 'tampered' >>"$sig_site/repos/testpkg-alpha/dists/noble/InRelease"
write_releases "$BASE/releases-sig.json" 'noble|24.04 LTS|2024-04-25|2029-05-31'
set +e
"$VER" --site "$sig_site" --releases "$BASE/releases-sig.json" --work-dir "$sig_work"
sig_rc=$?
set -e
if [[ "$sig_rc" -eq 1 ]] && jq -e '.ok==false and any(.results[]; .failure_class=="signature")' "$sig_work/summary.json" >/dev/null; then
  pass "站点 InRelease 篡改 class=signature"
else
  fail "签名篡改分类错误 rc=$sig_rc summary=$(cat "$sig_work/summary.json" 2>/dev/null || true)"
fi

echo "== 声明非标准支持 series 拒绝 =="
bad_state_site="$BASE/site-badseries"
cp -a "$pos_site" "$bad_state_site"
jq '.packages[].ubuntu_series=["focal"]' "$bad_state_site/state.json" >"$bad_state_site/state.json.tmp"
mv "$bad_state_site/state.json.tmp" "$bad_state_site/state.json"
expect_rc "state 含 focal 拒绝" 1 "$VER" --site "$bad_state_site" --releases "$pos_rel" --work-dir "$BASE/verify-badseries"

echo "== id 与 sync 安全路径字符集一致 =="
# sync 允许 underscore；verify 须同集并显式拒 ..。真实入口，不靠 grep。
id_rel="$BASE/releases-id.json"
write_releases "$id_rel" 'noble|24.04 LTS|2024-04-25|2029-05-31'
id_site="$BASE/site-my_app"
id_work="$BASE/verify-my_app"
build_metadata_site "$id_site" "$GPGHOME" "noble" \
  'my_app|my-app|1.0.0|libc6|https://github.com|example/my_app/releases/download/1.0.0'
if "$VER" --site "$id_site" --releases "$id_rel" --work-dir "$id_work"; then
  if jq -e '.ok==true and (.results|length)==2 and all(.results[]; .ok==true)' \
    "$id_work/summary.json" >/dev/null; then
    pass "sync 合法 id my_app 可达验证"
  else
    fail "my_app summary 不符合: $(cat "$id_work/summary.json")"
  fi
else
  fail "my_app verify 失败，见 $id_work"
fi

id_dotdot_site="$BASE/site-id-dotdot"
cp -a "$id_site" "$id_dotdot_site"
jq '(.packages[0].id="a..b")' "$id_dotdot_site/state.json" >"$id_dotdot_site/state.json.tmp"
mv "$id_dotdot_site/state.json.tmp" "$id_dotdot_site/state.json"
expect_rc "id 含 .. 拒绝" 1 "$VER" --site "$id_dotdot_site" --releases "$id_rel" \
  --work-dir "$BASE/verify-id-dotdot"

id_slash_site="$BASE/site-id-slash"
cp -a "$id_site" "$id_slash_site"
jq '(.packages[0].id="../evil")' "$id_slash_site/state.json" >"$id_slash_site/state.json.tmp"
mv "$id_slash_site/state.json.tmp" "$id_slash_site/state.json"
expect_rc "id 路径穿越拒绝" 1 "$VER" --site "$id_slash_site" --releases "$id_rel" \
  --work-dir "$BASE/verify-id-slash"

id_badchar_site="$BASE/site-id-badchar"
cp -a "$id_site" "$id_badchar_site"
jq '(.packages[0].id="bad/id")' "$id_badchar_site/state.json" >"$id_badchar_site/state.json.tmp"
mv "$id_badchar_site/state.json.tmp" "$id_badchar_site/state.json"
expect_rc "id 含分隔符拒绝" 1 "$VER" --site "$id_badchar_site" --releases "$id_rel" \
  --work-dir "$BASE/verify-id-badchar"

sys_after=$(snap_system)
if [[ "$sys_before" == "$sys_after" ]]; then
  pass "系统 APT/dpkg/keyring 未被修改"
else
  fail "系统 APT 状态在测试后发生变化"
fi

echo "== workflow 约束 =="
for sha in \
  'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' \
  'actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9' \
  'actions/deploy-pages@368f82528645a54fb793d4d04e342629a3f51346'; do
  if grep -Fq "$sha" "$PUB" "$TST"; then
    pass "workflow 固定 SHA $sha"
  else
    fail "workflow 缺少 SHA $sha"
  fi
done
if grep -Fq 'cancel-in-progress: false' "$PUB"; then
  pass "发布 concurrency 不取消在途"
else
  fail "发布 concurrency"
fi
if grep -Eq 'GIT_AUTHOR_NAME:[[:space:]]*github-actions|github-actions\[bot\]' "$PUB"; then
  fail "publish 使用 github-actions bot 身份"
else
  pass "publish 无 github-actions bot 身份"
fi
if grep -Eq 'vars\.APT_HUB_GIT_(NAME|EMAIL)|APT_HUB_GIT_NAME: \$\{\{ vars\.' "$PUB"; then
  fail "publish 仍要求 git 身份 vars"
else
  pass "publish 不再要求 git 身份 vars"
fi
if grep -Fq "APT_HUB_GIT_NAME='yerikokay'" "$PUB" \
  || grep -Fq '129245892+yerikokay@users.noreply.github.com' "$PUB"; then
  fail "publish 仍硬编码原维护者身份"
else
  pass "publish 无硬编码原维护者身份"
fi
if grep -Fq 'github.actor' "$PUB" && grep -Fq 'github.actor_id' "$PUB" \
  && grep -Fq '解析发布者命令级身份' "$PUB" \
  && grep -Fq 'steps.publisher.outputs.git_name' "$PUB" \
  && grep -Fq 'needs.build_verify.outputs.git_name' "$PUB"; then
  pass "提交身份经 github.actor 核验后命令级消费"
else
  fail "缺少 actor 核验与命令级身份消费"
fi
if grep -Fq '拒绝非人类 actor' "$PUB" && grep -Fq '"User"' "$PUB"; then
  pass "发布者身份拒绝非 User"
else
  fail "未拒绝非人类 actor"
fi
if grep -Eq 'git[[:space:]]+push[[:space:]].*(--force|-f )|push[[:space:]]+--force' "$PUB"; then
  fail "publish 含 force-push"
else
  pass "publish 无 force-push"
fi
if grep -Fq 'APT_HUB_GPG_FINGERPRINT' "$PUB"; then
  fail "仍要求 fingerprint Secret"
else
  pass "已删除 fingerprint Secret 要求"
fi
if grep -Fq 'APT_HUB_GPG_PRIVATE_KEY' "$PUB"; then
  pass "私钥 Secret 仍为必填"
else
  fail "缺少私钥 Secret"
fi
if grep -Fq 'primary secret identity' "$PUB" || grep -Fq '恰好一个 primary' "$PUB"; then
  pass "导入后核验唯一 primary secret identity"
else
  fail "未核验唯一 primary fingerprint"
fi
if grep -Fq 'pages: read' "$PUB" && grep -Fq '/pages' "$PUB" && grep -Fq 'html_url' "$PUB"; then
  pass "Pages URL 经只读 API 取得"
else
  fail "未用 Pages 只读 API 取 html_url"
fi
if grep -Eq 'configure-pages|peaceiris/actions-gh-pages|启用 Pages|custom domain' "$PUB"; then
  fail "仍自动启用 Pages 或猜域名"
else
  pass "不自动启用 Pages / 不猜域名"
fi
if grep -Fq -- '--site-url' "$PUB"; then
  pass "构建步向 sync 传 --site-url"
else
  fail "构建步未传 --site-url"
fi
if grep -Fq '104857600' "$PUB" || grep -Fq '100MiB' "$PUB"; then
  fail "仍保留 100MiB 包门禁"
else
  pass "已移除 100MiB 包门禁"
fi
if grep -Fq '1073741824' "$PUB"; then
  pass "Pages 1GB 上限检查"
else
  fail "缺少 1GB 上限"
fi
if grep -Fq 'names=(apt-hub.gpg state.json index.html add_source.sh repos)' "$PUB"; then
  pass "apt-data 白名单为元数据与单一公开加源脚本"
else
  fail "apt-data 白名单不是 gpg/state/index/add_source.sh/repos"
fi
if grep -E 'names=\(.*pool|tmp/site/pool' "$PUB"; then
  fail "apt-data 白名单仍含 pool"
else
  pass "保存路径不再要求 pool"
fi
if grep -Fq 'git add -A' "$PUB"; then
  fail "apt-data 保存仍 git add -A"
else
  pass "apt-data 保存无 git add -A"
fi
if grep -A20 '^  update_readme:' "$PUB" | grep -q 'build_verify' \
  && grep -A20 '^  update_readme:' "$PUB" | grep -q 'deploy_pages'; then
  pass "README 回写同时 needs build_verify 与 deploy_pages"
else
  fail "README 回写未同时绑定 build 与 deploy"
fi
if grep -Fq 'apt_data_sha' "$PUB"; then
  pass "build 输出已保存 apt-data SHA"
else
  fail "缺少 apt_data_sha 输出"
fi
archive_sha_needle="git archive \"\$SHA\""
if grep -A80 '用已部署 state 更新 README' "$PUB" | grep -Fq -- "$archive_sha_needle"; then
  pass "README 从指定 SHA 取 state"
else
  fail "README 未从指定 SHA 取 state"
fi
if grep -A80 '用已部署 state 更新 README' "$PUB" | grep -q 'git archive origin/apt-data'; then
  fail "README 仍 archive 当时最新 apt-data"
else
  pass "README 不取 apt-data 最新 tip"
fi
if sed -n '/^on:/,/^permissions:/p' "$PUB" | grep -q 'workflow_dispatch:' \
  && sed -n '/^on:/,/^permissions:/p' "$PUB" | grep -q 'schedule:' \
  && ! sed -n '/^on:/,/^permissions:/p' "$PUB" | grep -q 'pull_request:' \
  && ! sed -n '/^on:/,/^permissions:/p' "$PUB" | grep -q 'push:'; then
  pass "发布仅 schedule/dispatch"
else
  fail "发布触发条件不是仅 schedule/dispatch"
fi
if grep -Fq "awk -F: '/^fpr:/{print toupper(\$10); exit}'" "$PUB"; then
  fail "仍取密钥列表首条指纹"
else
  pass "不取多密钥首条指纹"
fi
if grep -Fq 'gpg-preset-passphrase' "$PUB" || grep -Fq 'allow-preset-passphrase' "$PUB"; then
  fail "仍使用 gpg-preset-passphrase"
else
  pass "无 gpg-preset-passphrase"
fi
if grep -Fq 'tmp/gnupg' "$PUB" && grep -Fq 'gpgconf --kill gpg-agent' "$PUB"; then
  pass "私钥仅临时 gnupg 并清理 agent"
else
  fail "未限制/清理 gnupg"
fi
if grep -Fq 'shellcheck' "$TST"; then
  pass "CI 安装 shellcheck"
else
  fail "CI 未安装 shellcheck"
fi
if grep -Fq 'tests/workflow_test.sh tests/add_source_test.sh' "$TST" \
  && grep -Fq 'tests/update_sources_test.sh' "$TST" \
  && grep -Fq 'scripts/update_sources.sh' "$TST" \
  && grep -Fq "git ls-files -z -- '*.sh'" "$TST" \
  && ! grep -Eq 'setup-(bun|node)|bun install|npm install' "$TST"; then
  pass "CI 加源/单入口测试 chmod 并执行，保留 tracked 全 ShellCheck 且无新运行时"
else
  fail "CI 加源/单入口测试未接线或破坏既有静态检查/运行时约束"
fi
if grep -Fq 'scripts/update_sources.sh' "$PUB" \
  && awk '
    /^      - name: 生成发行版数据并构建候选站点$/ {hit=1; next}
    hit && /^      - name:/ {exit}
    hit && /chmod / {next}
    hit && /(^|[[:space:]])scripts\/sync\.sh([[:space:]]|\\|$)/ {bad=1}
    hit && /(^|[[:space:]])scripts\/verify_ubuntu\.sh([[:space:]]|\\|$)/ {bad=1}
    hit && /(^|[[:space:]])scripts\/ubuntu_releases\.sh([[:space:]]|\\|$)/ {bad=1}
    hit && /(^|[[:space:]])scripts\/render\.sh([[:space:]]|\\|$)/ {bad=1}
    END { exit bad+0 }
  ' "$PUB"; then
  pass "发布构建步改为单入口 update_sources"
else
  fail "发布构建步未改为单入口或不干净"
fi
if grep -Fq 'ShellCheck:' "$TST" || grep -Fq 'shellcheck' "$TST"; then
  pass "失败注解收集 ShellCheck 诊断"
else
  fail "失败注解未收集 ShellCheck"
fi
if grep -Fq "::error title=夹具测试失败::" "$TST"; then
  pass "失败注解标题为常量"
else
  fail "失败注解标题不是简化常量"
fi
if awk '
  /pull_request:/ { pr=1 }
  /secrets\./ { if (pr && FILENAME ~ /ubuntu-test/) bad=1 }
  END { exit bad+0 }
' "$TST"; then
  pass "PR 测试工作流不引用 secrets"
else
  fail "PR 测试工作流引用了 secrets"
fi
if grep -qE 'permissions:[[:space:]]*$' "$TST" && grep -A1 'permissions:' "$TST" | grep -q '{}'; then
  pass "test 工作流默认无权限"
else
  fail "test 工作流 permissions 未收口"
fi
if grep -A6 'name: 部署 GitHub Pages' "$PUB" | grep -q 'pages: write' \
  && grep -A20 'name: 构建校验并保存候选' "$PUB" | grep -q 'contents: write' \
  && grep -A20 'name: 构建校验并保存候选' "$PUB" | grep -q 'pages: read' \
  && ! grep -A20 'name: 构建校验并保存候选' "$PUB" | grep -q 'pages: write'; then
  pass "权限按 job 拆分且 build 含 pages:read"
else
  fail "job 权限拆分不符合契约"
fi

echo "== 真实消费者：copy/site + 隔离 Git 保存/读回/并发 =="
GIT_NAME='fixture-publisher'
GIT_EMAIL='fixture-publisher@invalid'

extract_workflow_fn() {
  local name="$1"
  awk -v name="$name" '
    index($0, "          " name "() {") == 1 {grab=1}
    grab { print }
    grab && $0 == "          }" {exit}
  ' "$ROOT/.github/workflows/ubuntu-publish.yml" | sed 's/^          //'
}

make_git_site() {
  local site="$1" token="${2:-v1}"
  local id="sample" series="jammy" arch f h
  rm -rf "$site"
  mkdir -p "$site/repos/$id/dists/${series}/main/binary-amd64/by-hash/SHA256" \
    "$site/repos/$id/dists/${series}/main/binary-arm64/by-hash/SHA256"
  for arch in amd64 arm64; do
    printf 'Packages-%s-%s\n' "$token" "$arch" >"$site/repos/$id/dists/${series}/main/binary-${arch}/Packages"
    gzip -n -9 -c "$site/repos/$id/dists/${series}/main/binary-${arch}/Packages" \
      >"$site/repos/$id/dists/${series}/main/binary-${arch}/Packages.gz"
    for f in \
      "$site/repos/$id/dists/${series}/main/binary-${arch}/Packages" \
      "$site/repos/$id/dists/${series}/main/binary-${arch}/Packages.gz"
    do
      h=$(sha256sum "$f" | awk '{print $1}')
      cp "$f" "$(dirname "$f")/by-hash/SHA256/$h"
    done
  done
  printf 'https://example.invalid/repos/%s/\tpriority:1 type:index\nhttps://github.com/\tpriority:1 type:deb\n' \
    "$id" >"$site/repos/$id/mirror.list"
  printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'fixture' >"$site/apt-hub.gpg"
  jq -n --arg t "$token" --arg id "$id" \
    '{schema_version:"2",packages:[{id:$id,token:$t,apt_source_uri:("mirror+https://example.invalid/repos/"+$id+"/mirror.list")}]}' \
    >"$site/state.json"
  printf '<html>%s</html>\n' "$token" >"$site/index.html"
  printf '#!/usr/bin/env bash\n# Metadata fixture only: %s; not an installer.\n' "$token" >"$site/add_source.sh"
  chmod 0644 "$site/add_source.sh"
}

extract_workflow_run() {
  local step="$1"
  awk -v step="$step" '
    /^      - name:/ { hit=($0 == "      - name: " step); grab=0 }
    hit && /^        run: \|$/ { grab=1; next }
    grab && /^          / { print substr($0, 11); next }
    grab && NF { grab=0 }
  ' "$ROOT/.github/workflows/ubuntu-publish.yml"
}

# 仅运行候选 gate，不执行构建、安装器、私钥导入或网络 APT 矩阵。
gate_root="$BASE/site-gate"
gate_run="$BASE/site-gate.sh"
extract_workflow_run '检查产物大小并无符号链接' >"$gate_run"
# 加源脚本复制已收口进 update_sources.sh；gate 正向用例按同一契约就地消费，不再 awk 截取失效构建步。
copy_run="$BASE/site-copy-add-source.sh"
cat >"$copy_run" <<'EOF'
set -euo pipefail
[[ -f scripts/add_source.sh && ! -L scripts/add_source.sh ]] || { echo "源码缺少普通加源脚本" >&2; exit 1; }
cp -- scripts/add_source.sh tmp/site/add_source.sh
chmod 0644 tmp/site/add_source.sh
EOF
for gate_case in ok missing symlink directory fifo private deb version mode; do
  rm -rf "$gate_root"
  mkdir -p "$gate_root/tmp" "$gate_root/scripts"
  make_git_site "$gate_root/tmp/site" gate
  cp "$gate_root/tmp/site/add_source.sh" "$gate_root/scripts/add_source.sh"
  if [[ "$gate_case" == ok ]]; then
    rm "$gate_root/tmp/site/add_source.sh"
    chmod 0755 "$gate_root/scripts/add_source.sh"
    (cd "$gate_root" && bash "$copy_run")
  fi
  case "$gate_case" in
    missing) rm "$gate_root/tmp/site/add_source.sh" ;;
    symlink)
      rm "$gate_root/tmp/site/add_source.sh"
      ln -s ../../scripts/add_source.sh "$gate_root/tmp/site/add_source.sh"
      ;;
    directory) rm "$gate_root/tmp/site/add_source.sh"; mkdir "$gate_root/tmp/site/add_source.sh" ;;
    fifo) rm "$gate_root/tmp/site/add_source.sh"; mkfifo "$gate_root/tmp/site/add_source.sh" ;;
    private) printf '%s\n' '-----BEGIN PGP PRIVATE KEY BLOCK-----' >"$gate_root/tmp/site/key.asc" ;;
    deb) printf 'not a package\n' >"$gate_root/tmp/site/stray.deb" ;;
    version) printf '# wrong checkout version\n' >>"$gate_root/tmp/site/add_source.sh" ;;
    mode) chmod 0755 "$gate_root/tmp/site/add_source.sh" ;;
  esac
  gate_rc=0
  (cd "$gate_root" && GITHUB_OUTPUT="$gate_root/output" bash "$gate_run") >"$BASE/gate-${gate_case}.log" 2>&1 || gate_rc=$?
  if [[ "$gate_case" == ok ]]; then
    if [[ "$gate_rc" -eq 0 ]] && grep -qx 'site_ok=true' "$gate_root/output"; then
      pass "真实候选 gate 接受同 checkout 0644 公开加源脚本"
    else
      fail "候选 gate 正向 rc=$gate_rc"
    fi
  elif [[ "$gate_rc" -ne 0 && ! -e "$gate_root/output" ]]; then
    pass "真实候选 gate 拒绝 $gate_case 且不输出成功"
  else
    fail "候选 gate 未拒绝 $gate_case rc=$gate_rc"
  fi
done

# 批量特殊文件/链接/deb 与 find 失败：覆盖 grep -q SIGPIPE 假放行边界。
for gate_batch in fifo symlink deb; do
  rm -rf "$gate_root"
  mkdir -p "$gate_root/tmp" "$gate_root/scripts"
  make_git_site "$gate_root/tmp/site" gate
  cp "$gate_root/tmp/site/add_source.sh" "$gate_root/scripts/add_source.sh"
  case "$gate_batch" in
    fifo)
      for i in $(seq 1 2048); do mkfifo "$gate_root/tmp/site/fifo-$i"; done
      gate_batch_n=$(find "$gate_root/tmp/site" ! -type f ! -type d | wc -l)
      ;;
    symlink)
      for i in $(seq 1 2048); do ln -s add_source.sh "$gate_root/tmp/site/link-$i"; done
      gate_batch_n=$(find "$gate_root/tmp/site" -type l | wc -l)
      ;;
    deb)
      for i in $(seq 1 2048); do printf 'not a package\n' >"$gate_root/tmp/site/stray-$i.deb"; done
      gate_batch_n=$(find "$gate_root/tmp/site" -name '*.deb' | wc -l)
      ;;
  esac
  if [[ "$gate_batch_n" -ne 2048 ]]; then
    fail "批量 $gate_batch 夹具数量 $gate_batch_n != 2048"
  else
    gate_rc=0
    rm -f "$gate_root/output"
    (cd "$gate_root" && GITHUB_OUTPUT="$gate_root/output" bash "$gate_run") \
      >"$BASE/gate-batch-${gate_batch}.log" 2>&1 || gate_rc=$?
    if [[ "$gate_rc" -ne 0 && ! -e "$gate_root/output" ]]; then
      pass "真实候选 gate 拒绝批量 $gate_batch(2048) 且不输出成功"
    else
      fail "候选 gate 未拒绝批量 $gate_batch rc=$gate_rc"
    fi
  fi
done

rm -rf "$gate_root"
mkdir -p "$gate_root/tmp" "$gate_root/scripts" "$gate_root/bin"
make_git_site "$gate_root/tmp/site" gate
cp "$gate_root/tmp/site/add_source.sh" "$gate_root/scripts/add_source.sh"
cat >"$gate_root/bin/find" <<'EOF'
#!/usr/bin/env bash
echo "find: simulated failure" >&2
exit 2
EOF
chmod 0755 "$gate_root/bin/find"
gate_rc=0
rm -f "$gate_root/output"
(cd "$gate_root" && PATH="$gate_root/bin:$PATH" GITHUB_OUTPUT="$gate_root/output" bash "$gate_run") \
  >"$BASE/gate-find-fail.log" 2>&1 || gate_rc=$?
if [[ "$gate_rc" -ne 0 && ! -e "$gate_root/output" ]]; then
  pass "真实候选 gate 在 find 失败时拒绝且不输出成功"
else
  fail "候选 gate find 失败未拒绝 rc=$gate_rc"
fi

isolated_save() {
  local sandbox="$1" origin="$2" out="$3" log="$4"
  local rc=0
  (
    cd "$sandbox"
    set -euo pipefail
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME="$GIT_NAME"
    export GIT_AUTHOR_EMAIL="$GIT_EMAIL"
    export GIT_COMMITTER_NAME="$GIT_NAME"
    export GIT_COMMITTER_EMAIL="$GIT_EMAIL"
    APT_HUB_GIT_NAME="$GIT_NAME"
    APT_HUB_GIT_EMAIL="$GIT_EMAIL"
    work="$PWD/tmp/apt-data-git"
    rm -rf "$work"
    mkdir -p "$work"
    git -C "$work" init
    git -C "$work" remote add origin "$origin"
    git_auth() { git -C "$work" "$@"; }
    eval "$(extract_workflow_fn copy_site)"
    eval "$(extract_workflow_fn refuse_non_whitelist)"
    if [[ -s tmp/apt-data-base.sha ]]; then
      base=$(tr -d '[:space:]' < tmp/apt-data-base.sha)
      [[ "$base" =~ ^[0-9a-f]{40}$ ]] || { echo "apt-data 基线 SHA 非法" >&2; exit 1; }
      git_auth fetch origin refs/heads/apt-data:refs/remotes/origin/apt-data
      git -C "$work" checkout -B apt-data "$base"
      refuse_non_whitelist
      copy_site
      refuse_non_whitelist
      if git -C "$work" diff --cached --quiet; then
        echo "apt-data 已与候选一致，无需新提交"
      else
        git -C "$work" -c "user.name=${APT_HUB_GIT_NAME}" -c "user.email=${APT_HUB_GIT_EMAIL}" commit -m "更新候选 APT 站点数据"
      fi
      if ! git_auth push origin apt-data; then
        echo "apt-data 快进推送失败，禁止 force，请重跑" >&2
        exit 1
      fi
    else
      if git -C "$work" ls-remote --heads origin apt-data | grep -q .; then
        echo "apt-data 在恢复后被创建，禁止把首轮快照覆到新分支上" >&2
        exit 1
      fi
      git -C "$work" checkout -B apt-data
      copy_site
      refuse_non_whitelist
      git -C "$work" -c "user.name=${APT_HUB_GIT_NAME}" -c "user.email=${APT_HUB_GIT_EMAIL}" commit -m "初始化候选 APT 站点数据"
      if ! git_auth push -u origin apt-data; then
        echo "创建 apt-data 失败（网络/鉴权/并发），不能当已发布" >&2
        exit 1
      fi
    fi
    saved=$(git -C "$work" rev-parse HEAD)
    [[ "$saved" =~ ^[0-9a-f]{40}$ ]] || { echo "无法读取保存后的 apt-data SHA" >&2; exit 1; }
    printf '%s\n' "$saved" >"$out"
  ) >"$log" 2>&1 || rc=$?
  return "$rc"
}

copy_fn=$(extract_workflow_fn copy_site)
refuse_fn=$(extract_workflow_fn refuse_non_whitelist)
copy_add_needle="git -C \"\$work\" add --"
if [[ "$copy_fn" == copy_site* ]] && grep -Fq -- "$copy_add_needle" <<<"$copy_fn"; then
  pass "从 workflow 提取到真实 copy_site"
else
  fail "未能提取 copy_site"
fi
if [[ "$refuse_fn" == refuse_non_whitelist* ]]; then
  pass "从 workflow 提取到 refuse_non_whitelist"
else
  fail "未能提取 refuse_non_whitelist"
fi
if grep -q 'repos' <<<"$copy_fn" && ! grep -qE '\bpool\b' <<<"$copy_fn"; then
  pass "copy_site 含 repos、不含 pool"
else
  fail "copy_site 白名单不符合元数据布局"
fi

gs="$BASE/git-save"
sandbox="$gs/root"
origin="$gs/origin.git"
shafile="$gs/saved.sha"
savelog="$gs/save.log"
rm -rf "$gs"
mkdir -p "$sandbox/tmp" "$origin"
git init --bare "$origin" >/dev/null 2>&1
make_git_site "$sandbox/tmp/site" v1
mkdir -p "$sandbox/tmp/gnupg"
printf '%s\n' '-----BEGIN PGP PRIVATE KEY BLOCK-----' 'secret' >"$sandbox/tmp/gnupg/private.key"
printf 'should-not-be-saved\n' >"$sandbox/tmp/site/not-whitelisted.txt"
: >"$sandbox/tmp/apt-data-base.sha"

set +e
isolated_save "$sandbox" "$origin" "$shafile" "$savelog"
save1_rc=$?
set -e
sha1=$(tr -d '[:space:]' <"$shafile" 2>/dev/null || true)
if [[ "$save1_rc" -eq 0 && "$sha1" =~ ^[0-9a-f]{40}$ ]]; then
  pass "首次空分支保存 (exit 0) $sha1"
else
  fail "首次空分支保存失败 rc=$save1_rc log=$(cat "$savelog" 2>/dev/null || true)"
fi
readback="$gs/readback1"
rm -rf "$readback"
mkdir -p "$readback"
if [[ -n "$sha1" ]]; then
  git --git-dir="$origin" archive "$sha1" | tar -x -C "$readback"
fi
if [[ -f "$readback/state.json" ]] && cmp -s "$readback/state.json" "$sandbox/tmp/site/state.json"; then
  pass "读回 SHA1 state 与候选一致"
else
  fail "读回 SHA1 state 不一致"
fi
if [[ -f "$readback/add_source.sh" && ! -L "$readback/add_source.sh" ]] \
  && cmp -s "$readback/add_source.sh" "$sandbox/tmp/site/add_source.sh" \
  && git --git-dir="$origin" ls-tree "$sha1" -- add_source.sh | grep -q '^100644 blob '; then
  pass "读回 SHA1 公开加源脚本字节一致且 Git 模式 100644"
else
  fail "读回 SHA1 公开加源脚本缺失、字节或模式不符"
fi
author=$(git --git-dir="$origin" log -1 --format='%an <%ae>' "$sha1" 2>/dev/null || true)
if [[ "$author" == "$GIT_NAME <$GIT_EMAIL>" ]]; then
  pass "提交身份 $author"
else
  fail "提交身份错误: $author"
fi
if git --git-dir="$origin" ls-tree --name-only "$sha1" 2>/dev/null | grep -qx repos; then
  pass "数据分支根含 repos"
else
  fail "数据分支根缺少 repos"
fi
if git --git-dir="$origin" ls-tree --name-only "$sha1" 2>/dev/null | grep -Eq '^(pool|by-hash)$'; then
  fail "数据分支根含 pool/by-hash"
else
  pass "数据分支根无 pool/by-hash"
fi
if git --git-dir="$origin" ls-tree -r --name-only "$sha1" 2>/dev/null | grep -q '/by-hash/SHA256/'; then
  pass "数据分支含 dists 内 by-hash"
else
  fail "数据分支缺少嵌套 by-hash"
fi
if git --git-dir="$origin" ls-tree --name-only "$sha1" 2>/dev/null | grep -Eq 'not-whitelisted|gnupg|private.key|BEGIN PGP PRIVATE'; then
  fail "未知文件或私钥进入数据分支"
else
  pass "未知根文件与私钥未进入数据分支"
fi
if git -C "$sandbox/tmp/apt-data-git" config --local --get user.name >/dev/null 2>&1; then
  fail "隔离保存写了 local user.name"
else
  pass "隔离保存未写 git config user.name"
fi

printf '%s\n' "$sha1" >"$sandbox/tmp/apt-data-base.sha"
make_git_site "$sandbox/tmp/site" v2
printf 'should-not-be-saved\n' >"$sandbox/tmp/site/not-whitelisted.txt"
set +e
isolated_save "$sandbox" "$origin" "$shafile" "$savelog"
save2_rc=$?
set -e
sha2=$(tr -d '[:space:]' <"$shafile" 2>/dev/null || true)
if [[ "$save2_rc" -eq 0 && "$sha2" =~ ^[0-9a-f]{40}$ && "$sha2" != "$sha1" ]]; then
  pass "从旧 SHA 再次保存 (exit 0) $sha2"
else
  fail "从旧 SHA 再次保存失败 rc=$save2_rc sha=$sha2 log=$(cat "$savelog" 2>/dev/null || true)"
fi
readback2="$gs/readback2"
rm -rf "$readback2"
mkdir -p "$readback2"
if [[ -n "$sha2" ]]; then
  git --git-dir="$origin" archive "$sha2" | tar -x -C "$readback2"
fi
if [[ -f "$readback2/state.json" ]] && cmp -s "$readback2/state.json" "$sandbox/tmp/site/state.json" \
  && jq -e '.packages[0].token=="v2"' "$readback2/state.json" >/dev/null; then
  pass "读回 SHA2 state 与候选 v2 一致"
else
  fail "读回 SHA2 state 不一致"
fi
if [[ -f "$readback2/add_source.sh" ]] && cmp -s "$readback2/add_source.sh" "$sandbox/tmp/site/add_source.sh"; then
  pass "读回 SHA2 加源脚本与候选 v2 一致"
else
  fail "读回 SHA2 加源脚本不一致"
fi
if git --git-dir="$origin" show "$sha1:add_source.sh" >"$gs/old-deployment-add_source.sh" \
  && cmp -s "$gs/old-deployment-add_source.sh" "$readback/add_source.sh" \
  && ! cmp -s "$gs/old-deployment-add_source.sh" "$readback2/add_source.sh"; then
  pass "旧部署 SHA1 加源脚本未被新候选替换"
else
  fail "旧部署脚本未固定到精确 SHA"
fi
parent=$(git --git-dir="$origin" rev-parse "${sha2}^" 2>/dev/null || true)
if [[ "$parent" == "$sha1" ]]; then
  pass "第二次提交父节点是旧 SHA"
else
  fail "第二次提交父节点不是旧 SHA: $parent"
fi

side="$gs/side"
rm -rf "$side"
git clone -q "$origin" "$side" >/dev/null 2>"$gs/clone.err"
git -C "$side" checkout -q apt-data >/dev/null
jq '.packages[0].token="concurrent"' "$side/state.json" >"$side/state.json.tmp"
mv "$side/state.json.tmp" "$side/state.json"
git -C "$side" add -- state.json
git -C "$side" \
  -c "user.name=$GIT_NAME" -c "user.email=$GIT_EMAIL" \
  commit -m "并发推进基线" >/dev/null
git -C "$side" push -q origin apt-data >/dev/null 2>&1
concurrent_sha=$(git --git-dir="$origin" rev-parse apt-data)
printf '%s\n' "$sha2" >"$sandbox/tmp/apt-data-base.sha"
make_git_site "$sandbox/tmp/site" v3
set +e
isolated_save "$sandbox" "$origin" "$shafile" "$savelog"
save3_rc=$?
set -e
if [[ "$save3_rc" -ne 0 ]] && grep -Fq 'apt-data 快进推送失败，禁止 force' "$savelog"; then
  pass "基线被并发推进时普通推送拒绝 (exit $save3_rc)"
else
  fail "并发推进未拒绝 rc=$save3_rc log=$(cat "$savelog" 2>/dev/null || true)"
fi
now_tip=$(git --git-dir="$origin" rev-parse apt-data)
if [[ "$now_tip" == "$concurrent_sha" ]]; then
  pass "并发拒绝后远端仍是并发提交"
else
  fail "并发拒绝后远端被改写: $now_tip"
fi

dirty_side="$gs/dirty"
rm -rf "$dirty_side"
git clone -q "$origin" "$dirty_side" >/dev/null 2>"$gs/clone2.err"
git -C "$dirty_side" checkout -q apt-data >/dev/null
printf '%s\n' leftover >"$dirty_side/unknown.txt"
printf '%s\n' '-----BEGIN PGP PRIVATE KEY BLOCK-----' >"$dirty_side/secring.gpg"
git -C "$dirty_side" add -- unknown.txt secring.gpg
git -C "$dirty_side" \
  -c "user.name=$GIT_NAME" -c "user.email=$GIT_EMAIL" \
  commit -m "脏历史未知根文件" >/dev/null
git -C "$dirty_side" push -q origin apt-data >/dev/null 2>&1
dirty_sha=$(git --git-dir="$origin" rev-parse apt-data)
printf '%s\n' "$dirty_sha" >"$sandbox/tmp/apt-data-base.sha"
make_git_site "$sandbox/tmp/site" v4
set +e
isolated_save "$sandbox" "$origin" "$shafile" "$savelog"
save4_rc=$?
set -e
if [[ "$save4_rc" -ne 0 ]] && grep -Fq 'apt-data 含白名单外路径，拒绝保存' "$savelog"; then
  pass "历史脏数据明确拒绝 (exit $save4_rc)"
else
  fail "脏历史未拒绝 rc=$save4_rc log=$(cat "$savelog" 2>/dev/null || true)"
fi
after_dirty=$(git --git-dir="$origin" rev-parse apt-data)
if [[ "$after_dirty" == "$dirty_sha" ]]; then
  pass "脏历史拒绝后未改写远端"
else
  fail "脏历史拒绝后远端被改写"
fi

echo "== 证据清单 =="
find "$BASE" -type f | sort >"$BASE/files.txt"
wc -l "$BASE/files.txt"
echo "failures=$failures"
if [[ "$failures" -ne 0 ]]; then
  echo "ubuntu_test: $failures 项失败" >&2
  exit 1
fi
echo "ubuntu_test: 全部通过"
exit 0
