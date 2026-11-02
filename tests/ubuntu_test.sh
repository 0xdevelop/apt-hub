#!/usr/bin/env bash
# C 路径自测：发行版筛选、隔离 APT 依赖解析、workflow 约束。证据只写项目 tmp/。
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$ROOT"
export LC_ALL=C

REL="$ROOT/scripts/ubuntu_releases.sh"
VER="$ROOT/scripts/verify_ubuntu.sh"
BASE="$ROOT/tmp/ubuntu-test"
mkdir -p "$ROOT/tmp"
rm -rf "$BASE"
mkdir -p "$BASE"

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

build_site() {
  local site="$1" gpghome="$2" series_csv="$3" alpha_dep="$4" beta_dep="$5"
  rm -rf "$site"
  mkdir -p "$site/pool/main/t/testpkg-alpha" "$site/pool/main/t/testpkg-beta"
  local arch series
  for arch in amd64 arm64; do
    build_deb testpkg-alpha 1.0.0 "$arch" "$alpha_dep" \
      "$site/pool/main/t/testpkg-alpha/testpkg-alpha_1.0.0_${arch}.deb"
    build_deb testpkg-beta 2.0.0 "$arch" "$beta_dep" \
      "$site/pool/main/t/testpkg-beta/testpkg-beta_2.0.0_${arch}.deb"
  done
  IFS=',' read -r -a series_list <<<"$series_csv"
  (
    cd "$site"
    for series in "${series_list[@]}"; do
      for arch in amd64 arm64; do
        mkdir -p "dists/${series}/main/binary-${arch}"
        dpkg-scanpackages -a "$arch" pool /dev/null \
          >"dists/${series}/main/binary-${arch}/Packages" 2>/dev/null
        gzip -9c "dists/${series}/main/binary-${arch}/Packages" \
          >"dists/${series}/main/binary-${arch}/Packages.gz"
      done
      cat >"$BASE/apt-ftparchive-${series}.conf" <<EOF
APT::FTPArchive::Release::Origin "apt-hub-test";
APT::FTPArchive::Release::Label "apt-hub-test";
APT::FTPArchive::Release::Suite "${series}";
APT::FTPArchive::Release::Codename "${series}";
APT::FTPArchive::Release::Architectures "amd64 arm64";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "apt-hub verify fixture";
EOF
      apt-ftparchive -c "$BASE/apt-ftparchive-${series}.conf" release "dists/${series}" \
        >"dists/${series}/Release"
      sign_release "$gpghome" "dists/${series}"
    done
  )
  gpg --homedir "$gpghome" --batch --export --armor >"$site/apt-hub.gpg"
  local series_json
  series_json=$(printf '%s' "$series_csv" | jq -R 'split(",")')
  jq -n --argjson series "$series_json" --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {
      schema_version: 1,
      packages: [
        {
          id: "testpkg-alpha",
          package: "testpkg-alpha",
          repository: "apt-hub/testpkg-alpha",
          description: "verify fixture alpha",
          version: "1.0.0",
          release_url: "https://example.invalid/alpha",
          source_url: "https://example.invalid/alpha",
          license: "MIT",
          updated_at: $checked,
          ubuntu_series: $series,
          architectures: ["amd64","arm64"],
          assets: [
            {architecture:"amd64",filename:"pool/main/t/testpkg-alpha/testpkg-alpha_1.0.0_amd64.deb",sha256:"00",size:1,url:"https://example.invalid/a"},
            {architecture:"arm64",filename:"pool/main/t/testpkg-alpha/testpkg-alpha_1.0.0_arm64.deb",sha256:"00",size:1,url:"https://example.invalid/a"}
          ]
        },
        {
          id: "testpkg-beta",
          package: "testpkg-beta",
          repository: "apt-hub/testpkg-beta",
          description: "verify fixture beta",
          version: "2.0.0",
          release_url: "https://example.invalid/beta",
          source_url: "https://example.invalid/beta",
          license: "MIT",
          updated_at: $checked,
          ubuntu_series: $series,
          architectures: ["amd64","arm64"],
          assets: [
            {architecture:"amd64",filename:"pool/main/t/testpkg-beta/testpkg-beta_2.0.0_amd64.deb",sha256:"00",size:1,url:"https://example.invalid/b"},
            {architecture:"arm64",filename:"pool/main/t/testpkg-beta/testpkg-beta_2.0.0_arm64.deb",sha256:"00",size:1,url:"https://example.invalid/b"}
          ]
        }
      ]
    }
  ' >"$site/state.json"
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

echo "== bash -n =="
if bash -n "$REL" && bash -n "$VER" && bash -n "$ROOT/tests/ubuntu_test.sh"; then
  pass "bash -n C 脚本"
else
  fail "bash -n C 脚本"
fi
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$REL" "$VER" "$ROOT/tests/ubuntu_test.sh" && pass "shellcheck" || fail "shellcheck"
else
  echo "NOTE shellcheck 不可用，未安装"
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
if jq -e --arg today "$today" 'all(.releases[]; .release_date <= $today and .eol_date > $today)' "$fixture_out" >/dev/null; then
  pass "夹具日期窗口 release<=今天<eol"
else
  fail "夹具日期窗口错误"
fi
if grep -Eq 'select\(\.=="trusty"|=="xenial"|=="bionic"|=="focal"' "$REL"; then
  fail "ubuntu_releases 仍硬编码 ESM series 排除表"
else
  pass "ubuntu_releases 无硬编码 series 排除表"
fi

echo "== malformed 已发布行不得静默丢掉 =="
malformed_csv="$BASE/ubuntu.malformed.csv"
cat >"$malformed_csv" <<'EOF'
version,codename,series,created,release,eol,eol-server,eol-esm,eol-legacy
22.04 LTS,Jammy Jellyfish,jammy,2021-10-14,2022-04-21,2027-06-01,2027-06-01,2032-04-21,2037-04-30
24.04 LTS,Broken Current,broken,2023-10-12,2024-04-25,not-a-date
EOF
expect_rc "malformed 当前版本行拒绝" 1 "$REL" --output "$BASE/malformed.json" --csv "$malformed_csv"
[[ ! -e "$BASE/malformed.json" ]] && pass "malformed 未写出 releases.json" || fail "malformed 仍写出了 releases.json"

missing_eol_csv="$BASE/ubuntu.missing-eol.csv"
cat >"$missing_eol_csv" <<'EOF'
version,codename,series,created,release,eol,eol-server,eol-esm,eol-legacy
24.04 LTS,Noble Numbat,noble,2023-10-12,2024-04-25
EOF
expect_rc "已发布但缺 eol 拒绝" 1 "$REL" --output "$BASE/missing-eol.json" --csv "$missing_eol_csv"

echo "== 拒绝非官方 CSV 结构 =="
printf 'Dist: trusty\nSupported: 1\n' >"$BASE/meta-release.txt"
expect_rc "拒绝 meta-release 当 CSV" 1 "$REL" --output "$BASE/bad1.json" --csv "$BASE/meta-release.txt"
printf 'Invalid OpenID transaction\n' >"$BASE/openid.txt"
expect_rc "拒绝 OpenID 错误页" 1 "$REL" --output "$BASE/bad2.json" --csv "$BASE/openid.txt"
printf '<html>I Challenge Thee</html>\n' >"$BASE/html.txt"
expect_rc "拒绝 HTML 挑战页" 1 "$REL" --output "$BASE/bad3.json" --csv "$BASE/html.txt"

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
    fail "live 与独立过滤不一致 got=$(echo "$live_series" | tr '\n' ',') want=$(echo "$indep" | tr '\n' ',')"
  fi
  if echo "$live_series" | grep -Eq '^(trusty|xenial|bionic|focal|oracular|plucky|questing)$'; then
    fail "live 输出含非标准支持 series"
  else
    pass "live 不含 focal/trusty/questing 等非标准支持版本"
  fi
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 60 \
    -o "$BASE/release-cycle.html" https://ubuntu.com/about/release-cycle || true
  if [[ -s "$BASE/release-cycle.html" ]]; then
    cross_ok=true
    while IFS= read -r s; do
      ver=$(jq -r --arg s "$s" '.releases[] | select(.series==$s) | .version' "$live_out")
      num=$(printf '%s' "$ver" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
      if ! grep -Fq "$num" "$BASE/release-cycle.html"; then
        cross_ok=false
        fail "ubuntu.com 页未出现 live 版本 $num ($s)"
      fi
    done <<<"$live_series"
    if [[ "$cross_ok" == true ]]; then
      pass "live 版本均可在 ubuntu.com/about/release-cycle 找到"
    fi
  else
    fail "未能下载 ubuntu.com 发行周期页做测试交叉对照"
  fi
  jq -e '.schema_version==1 and .source_url=="https://salsa.debian.org/debian/distro-info-data/-/raw/main/ubuntu.csv"' "$live_out" >/dev/null \
    && pass "live JSON schema/source_url" || fail "live JSON schema"
else
  fail "live ubuntu_releases.sh 失败"
fi

echo "== 构造测试站点并隔离验证 =="
GPGHOME="$BASE/gnupg"
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
build_site "$pos_site" "$GPGHOME" "$pos_series_csv" "libc6" "libc6"
if "$VER" --site "$pos_site" --releases "$pos_rel" --work-dir "$pos_work"; then
  if jq -e --argjson n "$pos_combo_want" '.ok==true and (.results|length)==$n and all(.results[]; .ok==true and .failure_class==null)' "$pos_work/summary.json" >/dev/null; then
    pass "正向: ${pos_series_csv} × amd64/arm64 精确版本依赖可解析"
  else
    fail "正向 summary 不符合: $(cat "$pos_work/summary.json")"
  fi
  jq -e 'all(.results[]; .packages|length==2)' "$pos_work/summary.json" >/dev/null \
    && pass "正向每组合含两个软件" || fail "正向软件数量"
  mode_ok=true
  https_ok=true
  http_bad=false
  while IFS= read -r conf; do
    grep -Fq 'APT::Update::Error-Mode "any"' "$conf" || mode_ok=false
  done < <(find "$pos_work" -path '*/apt-root/etc/apt/apt.conf')
  if [[ "$mode_ok" == true ]] && find "$pos_work" -path '*/apt-root/etc/apt/apt.conf' | grep -q .; then
    pass "APT::Update::Error-Mode=any"
  else
    fail "APT 配置缺少 Error-Mode=any"
  fi
  while IFS= read -r src; do
    if [[ "$src" == *-amd64/apt-root/etc/apt/sources.list ]]; then
      grep -Fq 'https://archive.ubuntu.com/ubuntu' "$src" || https_ok=false
      grep -Fq 'https://security.ubuntu.com/ubuntu' "$src" || https_ok=false
    fi
    if [[ "$src" == *-arm64/apt-root/etc/apt/sources.list ]]; then
      grep -Fq 'https://ports.ubuntu.com/ubuntu-ports' "$src" || https_ok=false
    fi
    if grep -Eq 'http://(archive|security|ports)\.ubuntu\.com' "$src"; then
      http_bad=true
    fi
  done < <(find "$pos_work" -path '*/apt-root/etc/apt/sources.list')
  if [[ "$https_ok" == true ]]; then
    pass "官方源使用 HTTPS"
  else
    fail "官方源未改 HTTPS"
  fi
  if [[ "$http_bad" == true ]]; then
    fail "仍使用 HTTP Ubuntu 源"
  else
    pass "无 HTTP Ubuntu 源"
  fi
  [[ -f "$pos_work/.apt-hub-verify.owned" ]] && pass "work 所有权哨兵" || fail "缺少 work 所有权哨兵"
  sum_keep=$(sha256sum "$pos_work/summary.json" | awk '{print $1}')
  expect_rc "已有非空 work 拒绝" 1 "$VER" --site "$pos_site" --releases "$pos_rel" --work-dir "$pos_work"
  sum_after=$(sha256sum "$pos_work/summary.json" | awk '{print $1}')
  if [[ "$sum_keep" == "$sum_after" ]]; then
    pass "非空 work 原有证据未被删除"
  else
    fail "非空 work 被改写"
  fi
else
  fail "正向 verify_ubuntu 失败，见 $pos_work"
  find "$pos_work" -name 'result.json' -o -name '*.log' | while read -r f; do
    echo "---- $f ----"
    tail -n 30 "$f" || true
  done
fi

echo "== work/site/releases 祖先重叠与符号链接 =="
anc="$BASE/overlap-work-ancestor"
mkdir -p "$anc/site"
printf 'keep-work\n' >"$anc/KEEP_WORK"
printf 'keep-site\n' >"$anc/site/KEEP_SITE"
keep_work=$(sha256sum "$anc/KEEP_WORK" | awk '{print $1}')
keep_site=$(sha256sum "$anc/site/KEEP_SITE" | awk '{print $1}')
expect_rc "work 为 site 祖先拒绝" 1 "$VER" --site "$anc/site" --releases "$pos_rel" --work-dir "$anc"
[[ "$(sha256sum "$anc/KEEP_WORK" | awk '{print $1}')" == "$keep_work" ]] \
  && pass "祖先重叠未删除 work 哨兵" || fail "祖先重叠删除了 work 哨兵"
[[ "$(sha256sum "$anc/site/KEEP_SITE" | awk '{print $1}')" == "$keep_site" ]] \
  && pass "祖先重叠未删除 site 哨兵" || fail "祖先重叠删除了 site 哨兵"

rel_inside="$BASE/overlap-rel-in-work"
mkdir -p "$rel_inside"
cp "$pos_rel" "$rel_inside/releases.json"
printf 'keep-rel\n' >"$rel_inside/KEEP_REL"
keep_rel=$(sha256sum "$rel_inside/releases.json" | awk '{print $1}')
expect_rc "work 含 releases 拒绝" 1 "$VER" --site "$pos_site" --releases "$rel_inside/releases.json" --work-dir "$rel_inside"
[[ "$(sha256sum "$rel_inside/releases.json" | awk '{print $1}')" == "$keep_rel" ]] \
  && pass "重叠未删除 releases 输入" || fail "重叠删除了 releases"
[[ -f "$rel_inside/KEEP_REL" ]] && pass "work 含 releases 时未清空目录" || fail "work 含 releases 时目录被清空"

site_parent="$BASE/overlap-site-parent"
cp -a "$pos_site" "$site_parent"
mkdir -p "$site_parent/evidence"
printf 'keep-nested\n' >"$site_parent/state.json.keep"
keep_state=$(sha256sum "$site_parent/state.json" | awk '{print $1}')
expect_rc "site 为 work 祖先拒绝" 1 "$VER" --site "$site_parent" --releases "$pos_rel" --work-dir "$site_parent/evidence"
[[ "$(sha256sum "$site_parent/state.json" | awk '{print $1}')" == "$keep_state" ]] \
  && pass "site 祖先重叠未改 state" || fail "site 祖先重叠改写了 state"

mkdir -p "$BASE/symlink-target"
ln -s "$BASE/symlink-target" "$BASE/symlink-work"
expect_rc "work 祖先含符号链接拒绝" 1 "$VER" --site "$pos_site" --releases "$pos_rel" --work-dir "$BASE/symlink-work/child"

echo "== 依赖不可解 =="
dep_site="$BASE/site-dep"
dep_work="$BASE/verify-dep"
build_site "$dep_site" "$GPGHOME" "noble" "libc6" "apt-hub-no-such-package-xyz"
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
if jq -e 'any(.results[]; .failure_class=="network")' "$dep_work/summary.json" >/dev/null; then
  fail "把依赖失败误标成 network"
else
  pass "依赖失败未标成 network"
fi

echo "== 网络/抓取失败不是依赖 =="
net_site="$BASE/site-net"
net_work="$BASE/verify-net"
build_site "$net_site" "$GPGHOME" "noble" "libc6" "libc6"
# 把 state/releases 改成官方源上不存在的 suite，update 必 404
jq '.packages[].ubuntu_series=["nosuchsuite"]' "$net_site/state.json" >"$net_site/state.json.tmp"
mv "$net_site/state.json.tmp" "$net_site/state.json"
mkdir -p "$net_site/dists/nosuchsuite/main/binary-amd64" "$net_site/dists/nosuchsuite/main/binary-arm64"
for arch in amd64 arm64; do
  cp "$net_site/dists/noble/main/binary-${arch}/Packages" "$net_site/dists/nosuchsuite/main/binary-${arch}/Packages"
  cp "$net_site/dists/noble/main/binary-${arch}/Packages.gz" "$net_site/dists/nosuchsuite/main/binary-${arch}/Packages.gz"
done
cp "$net_site/dists/noble/Release" "$net_site/dists/nosuchsuite/Release"
sed -i 's/noble/nosuchsuite/g' "$net_site/dists/nosuchsuite/Release"
sign_release "$GPGHOME" "$net_site/dists/nosuchsuite"
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
net_log="$net_work/nosuchsuite-amd64/update.log"
if [[ -f "$net_log" ]] && grep -Eqi 'Failed to fetch|404[[:space:]]+Not Found|Some index files failed|does not have a Release file' "$net_log"; then
  pass "中文 locale 下 update 日志仍为 C locale 英文"
else
  fail "中文 locale 下 update 日志缺少英文网络错误"
fi
if [[ -f "$net_log" ]] && grep -Eq '无法获取|无法下载|找不到 Release' "$net_log"; then
  fail "update 日志被翻译，分类依赖英文会不稳"
else
  pass "update 日志未被翻译"
fi

echo "== 签名篡改拒绝 =="
sig_site="$BASE/site-sig"
sig_work="$BASE/verify-sig"
build_site "$sig_site" "$GPGHOME" "noble" "libc6" "libc6"
echo 'tampered' >>"$sig_site/dists/noble/InRelease"
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

sys_after=$(snap_system)
if [[ "$sys_before" == "$sys_after" ]]; then
  pass "系统 APT/dpkg/keyring 未被修改"
else
  fail "系统 APT 状态在测试后发生变化"
fi

echo "== workflow 约束 =="
pub=".github/workflows/ubuntu-publish.yml"
tst=".github/workflows/ubuntu-test.yml"
wf_ok=true
for sha in \
  'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' \
  'actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9' \
  'actions/deploy-pages@368f82528645a54fb793d4d04e342629a3f51346'; do
  if grep -Fq "$sha" "$pub" "$tst"; then
    pass "workflow 固定 SHA $sha"
  else
    fail "workflow 缺少 SHA $sha"
    wf_ok=false
  fi
done
grep -Fq 'cancel-in-progress: false' "$pub" && pass "发布 concurrency 不取消在途" || { fail "发布 concurrency"; wf_ok=false; }
if grep -Eq 'GIT_AUTHOR_NAME:[[:space:]]*github-actions|github-actions\[bot\]' "$pub"; then
  fail "publish 使用 github-actions bot 身份"
  wf_ok=false
else
  pass "publish 无 github-actions bot 身份"
fi
grep -Fq 'APT_HUB_GIT_NAME' "$pub" && pass "提交身份来自用户 vars" || { fail "缺少 GIT_NAME vars"; wf_ok=false; }
if grep -Eq 'git[[:space:]]+push[[:space:]].*(--force|-f )|push[[:space:]]+--force' "$pub"; then
  fail "publish 含 force-push"
  wf_ok=false
else
  pass "publish 无 force-push"
fi
if awk '
  /pull_request:/ { pr=1 }
  /secrets\./ { if (pr && FILENAME ~ /ubuntu-test/) bad=1 }
  END { exit bad+0 }
' "$tst"; then
  pass "PR 测试工作流不引用 secrets"
else
  fail "PR 测试工作流引用了 secrets"
fi
if grep -A20 '^  update_readme:' "$pub" | grep -q 'build_verify' \
  && grep -A20 '^  update_readme:' "$pub" | grep -q 'deploy_pages'; then
  pass "README 回写同时 needs build_verify 与 deploy_pages"
else
  fail "README 回写未同时绑定 build 与 deploy"
fi
grep -Fq 'apt_data_sha' "$pub" && pass "build 输出已保存 apt-data SHA" || fail "缺少 apt_data_sha 输出"
if grep -A80 '用已部署 state 更新 README' "$pub" | grep -Fq 'git archive "$SHA"'; then
  pass "README 从指定 SHA 取 state"
else
  fail "README 未从指定 SHA 取 state"
fi
if grep -A80 '用已部署 state 更新 README' "$pub" | grep -q 'git archive origin/apt-data'; then
  fail "README 仍 archive 当时最新 apt-data"
else
  pass "README 不取 apt-data 最新 tip"
fi
if grep -Fq 'git add -A' "$pub"; then
  fail "apt-data 保存仍 git add -A"
else
  pass "apt-data 保存无 git add -A"
fi
if awk '/copy_site\(\)/,/^          \}$/ { if ($0 ~ /by-hash/) found=1 } END { exit found+0 }' "$pub"; then
  pass "copy_site 白名单无根级 by-hash"
else
  fail "copy_site 仍含根级 by-hash"
fi
if grep -Fq 'names=(pool dists apt-hub.gpg state.json index.html)' "$pub"; then
  pass "apt-data 白名单为 A 根布局"
else
  fail "apt-data 白名单不是 pool/dists/gpg/state/index.html"
fi
if grep -q 'export LC_ALL=C' "$VER" && grep -q 'export LANG=C' "$VER" && grep -q 'export LANGUAGE=C' "$VER"; then
  pass "verify_ubuntu 固定 LC_ALL/LANG/LANGUAGE=C"
else
  fail "verify_ubuntu 未固定 C locale"
fi
if grep -Fq 'env LC_ALL=C LANG=C LANGUAGE=C apt-get' "$VER"; then
  pass "apt-get 调用固定 C locale"
else
  fail "apt-get 未固定 C locale"
fi
grep -Fq '104857600' "$pub" && pass "workflow 含 Git 100MiB 单文件上限" || fail "缺少 Git 100MiB 上限"
if grep -Fq 'gpg-preset-passphrase' "$pub" || grep -Fq 'allow-preset-passphrase' "$pub"; then
  fail "仍使用 gpg-preset-passphrase"
else
  pass "无 gpg-preset-passphrase"
fi
if grep -qE 'passfile=|GNUPGHOME/passphrase' "$pub"; then
  fail "仍把口令落到磁盘"
else
  pass "口令不落盘"
fi
if sed -n '/^on:/,/^permissions:/p' "$pub" | grep -q 'workflow_dispatch:' \
  && sed -n '/^on:/,/^permissions:/p' "$pub" | grep -q 'schedule:' \
  && ! sed -n '/^on:/,/^permissions:/p' "$pub" | grep -q 'pull_request:' \
  && ! sed -n '/^on:/,/^permissions:/p' "$pub" | grep -q 'push:'; then
  pass "发布仅 schedule/dispatch"
else
  fail "发布触发条件不是仅 schedule/dispatch"
fi
if grep -Fq "awk -F: '/^fpr:/{print toupper(\$10); exit}'" "$pub"; then
  fail "仍取密钥列表首条指纹"
else
  pass "不取多密钥首条指纹"
fi
grep -Fq -- '--list-secret-keys --with-fingerprint -- "$want"' "$pub" \
  && pass "按完整指纹核验指定私钥" || fail "未按指定指纹核验私钥"
grep -Fq 'GPG_PASSPHRASE' "$pub" && pass "构建步向 sync 传 GPG_PASSPHRASE" || fail "构建步未传 GPG_PASSPHRASE"
if grep -Fq 'checkout -B apt-data origin/apt-data' "$pub"; then
  fail "保存时仍 checkout 最新 apt-data tip"
else
  pass "保存基于恢复时的基线 SHA"
fi
grep -Fq '1073741824' "$pub" && pass "Pages 1GB 上限检查" || fail "缺少 1GB 上限"
grep -Fq 'tmp/gnupg' "$pub" && pass "私钥仅临时 gnupg" || fail "未限制 gnupg 目录"
grep -Fq 'gpgconf --kill gpg-agent' "$pub" && pass "退出清理 gpg-agent" || fail "未清理 gpg-agent"
if grep -q 'if \[\[ -f tests/sync_test.sh \]\]' "$tst" || grep -q 'if \[\[ -f tests/render_test.sh \]\]' "$tst"; then
  fail "ubuntu-test 仍用文件存在才跑 A/B"
else
  pass "ubuntu-test 不按文件存在跳过 A/B"
fi
grep -Fq 'tests/sync_test.sh' "$tst" && grep -Fq 'tests/render_test.sh' "$tst" \
  && pass "ubuntu-test 强制跑 A/B 测试" || fail "ubuntu-test 未强制跑 A/B"
if grep -qE 'permissions:[[:space:]]*$' "$tst" && grep -A1 'permissions:' "$tst" | grep -q '{}'; then
  pass "test 工作流默认无权限"
else
  fail "test 工作流 permissions 未收口"
fi
grep -Fq 'contents: read' "$tst" && pass "PR/push 测试只读 contents" || fail "测试 job 权限"
if grep -A6 'name: 部署 GitHub Pages' "$pub" | grep -q 'pages: write' && \
   grep -A20 'name: 构建校验并保存候选' "$pub" | grep -q 'contents: write' && \
   ! grep -A20 'name: 构建校验并保存候选' "$pub" | grep -q 'pages: write'; then
  pass "权限按 job 拆分"
else
  fail "job 权限拆分不符合契约"
fi

echo "== 真实站点布局 copy/site 与隔离 Git 保存 =="
GIT_NAME='yerikokay'
GIT_EMAIL='129245892+yerikokay@users.noreply.github.com'

extract_workflow_fn() {
  local name="$1"
  awk -v name="$name" '
    index($0, "          " name "() {") == 1 {grab=1}
    grab { print }
    grab && $0 == "          }" {exit}
  ' "$ROOT/.github/workflows/ubuntu-publish.yml" | sed 's/^          //'
}

extract_gate_run() {
  awk '
    /id: gate/ {on=1}
    on && $0 == "        run: |" {run=1; next}
    run && /^      - name:/ {exit}
    run { print }
  ' "$ROOT/.github/workflows/ubuntu-publish.yml" | sed 's/^          //'
}

make_git_site() {
  local site="$1" token="${2:-v1}"
  local f h
  rm -rf "$site"
  mkdir -p "$site/pool/main/t/sample" \
    "$site/dists/jammy/main/binary-amd64/by-hash/SHA256" \
    "$site/dists/jammy/main/binary-arm64/by-hash/SHA256"
  printf 'deb-%s\n' "$token" >"$site/pool/main/t/sample/sample_1.0_amd64.deb"
  printf 'Packages-%s\n' "$token" >"$site/dists/jammy/main/binary-amd64/Packages"
  printf 'Packages-%s\n' "$token" >"$site/dists/jammy/main/binary-arm64/Packages"
  gzip -n -9 -c "$site/dists/jammy/main/binary-amd64/Packages" \
    >"$site/dists/jammy/main/binary-amd64/Packages.gz"
  gzip -n -9 -c "$site/dists/jammy/main/binary-arm64/Packages" \
    >"$site/dists/jammy/main/binary-arm64/Packages.gz"
  for f in \
    "$site/dists/jammy/main/binary-amd64/Packages" \
    "$site/dists/jammy/main/binary-amd64/Packages.gz" \
    "$site/dists/jammy/main/binary-arm64/Packages" \
    "$site/dists/jammy/main/binary-arm64/Packages.gz"
  do
    h=$(sha256sum "$f" | awk '{print $1}')
    cp "$f" "$(dirname "$f")/by-hash/SHA256/$h"
  done
  printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'fixture' >"$site/apt-hub.gpg"
  jq -n --arg t "$token" '{schema_version:1,packages:[{id:"sample",token:$t}]}' >"$site/state.json"
  printf '<html>%s</html>\n' "$token" >"$site/index.html"
}

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
gate_fn=$(extract_gate_run)
if [[ "$copy_fn" == copy_site* ]] && grep -q 'git -C "$work" add --' <<<"$copy_fn"; then
  pass "从 workflow 提取到真实 copy_site"
else
  fail "未能提取 copy_site"
fi
if [[ "$refuse_fn" == refuse_non_whitelist* ]]; then
  pass "从 workflow 提取到 refuse_non_whitelist"
else
  fail "未能提取 refuse_non_whitelist"
fi
if grep -q 'git_file_limit=104857600' <<<"$gate_fn"; then
  pass "从 workflow 提取到 100MiB 门禁"
else
  fail "未能提取 100MiB 门禁"
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
[[ ! -e "$sandbox/tmp/site/by-hash" ]] && pass "构造站点无根级 by-hash" || fail "构造站点出现根级 by-hash"
[[ -d "$sandbox/tmp/site/dists/jammy/main/binary-amd64/by-hash/SHA256" ]] \
  && pass "构造站点含 dists 内 by-hash" || fail "构造站点缺少嵌套 by-hash"

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
author=$(git --git-dir="$origin" log -1 --format='%an <%ae>' "$sha1" 2>/dev/null || true)
if [[ "$author" == "$GIT_NAME <$GIT_EMAIL>" ]]; then
  pass "提交身份 $author"
else
  fail "提交身份错误: $author"
fi
if git --git-dir="$origin" ls-tree --name-only "$sha1" 2>/dev/null | grep -qx by-hash; then
  fail "数据分支根含 by-hash"
else
  pass "数据分支根无 by-hash"
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
if git --git-dir="$origin" cat-file -e "${dirty_sha}:unknown.txt" \
  && git --git-dir="$origin" cat-file -e "${dirty_sha}:secring.gpg"; then
  pass "拒绝时未删除历史脏文件"
else
  fail "历史脏文件被删除"
fi
after_dirty=$(git --git-dir="$origin" rev-parse apt-data)
if [[ "$after_dirty" == "$dirty_sha" ]]; then
  pass "脏历史拒绝后未改写远端"
else
  fail "脏历史拒绝后远端被改写"
fi

echo "== 100MiB Git 单文件门禁 =="
gate_root="$BASE/gate"
rm -rf "$gate_root"
mkdir -p "$gate_root"
make_git_site "$gate_root/tmp/site" gateok
set +e
(
  cd "$gate_root"
  export GITHUB_OUTPUT="$gate_root/github.out"
  eval "$gate_fn"
)
gate_ok_rc=$?
set -e
if [[ "$gate_ok_rc" -eq 0 ]] && grep -Fq 'site_ok=true' "$gate_root/github.out"; then
  pass "普通站点通过大小门禁"
else
  fail "普通站点被大小门禁误拒 rc=$gate_ok_rc"
fi
big="$gate_root/tmp/site/pool/main/t/sample/too-big.deb"
truncate -s 104857601 "$big"
set +e
(
  cd "$gate_root"
  export GITHUB_OUTPUT="$gate_root/github.big.out"
  eval "$gate_fn"
) >"$gate_root/gate.big.log" 2>&1
gate_big_rc=$?
set -e
if [[ "$gate_big_rc" -ne 0 ]] && grep -F 'too-big.deb' "$gate_root/gate.big.log" \
  && grep -Fq '100MiB' "$gate_root/gate.big.log"; then
  pass "超过 100MiB 单文件被拒绝并指出文件名"
else
  fail "100MiB 门禁未拒绝或未指出文件 rc=$gate_big_rc log=$(cat "$gate_root/gate.big.log" 2>/dev/null || true)"
fi
if grep -Fq 'GitHub Pages 1GB' "$gate_root/gate.big.log"; then
  fail "把 Git 单文件超限误报成 Pages 整站限额"
else
  pass "Git 100MiB 与 Pages 1GB 分报"
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
