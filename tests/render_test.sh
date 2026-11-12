#!/usr/bin/env bash
# 渲染脚本与 git_tag.sh 正反路径。证据只写本项目 tmp/metadata-B；不改主 README。
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EVIDENCE="$ROOT/tmp/metadata-B"
RENDER="$ROOT/scripts/render.sh"
GIT_TAG="$ROOT/git_tag.sh"
BEGIN='<!-- APT-HUB:PACKAGES:BEGIN -->'
END='<!-- APT-HUB:PACKAGES:END -->'

rm -rf -- "$EVIDENCE"
mkdir -p -- "$EVIDENCE"

fails=0
passes=0
log() { printf '%s\n' "$*" | tee -a "$EVIDENCE/test.log"; }
pass() { passes=$((passes + 1)); log "PASS: $*"; }
fail() { fails=$((fails + 1)); log "FAIL: $*"; }

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name: got='$got' want='$want'"
  fi
}

assert_file_has() {
  local name="$1" file="$2" needle="$3"
  if grep -F -q -- "$needle" "$file"; then
    pass "$name"
  else
    fail "$name: 未在 $file 找到: $needle"
  fi
}

assert_file_lacks() {
  local name="$1" file="$2" needle="$3"
  if grep -F -q -- "$needle" "$file"; then
    fail "$name: $file 不应含: $needle"
  else
    pass "$name"
  fi
}

hash_file() {
  sha256sum -- "$1" | awk '{print $1}'
}

assert_same_hash() {
  local name="$1" file="$2" want="$3"
  local got
  got=$(hash_file "$file")
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name: hash changed got=$got want=$want"
  fi
}

assert_no_workdir() {
  local name="$1" dir="$2"
  local leftovers
  shopt -s nullglob
  leftovers=("$dir"/.apt-hub-render.*)
  shopt -u nullglob
  if [[ ${#leftovers[@]} -gt 0 ]]; then
    fail "$name: 留下 work 目录 ${leftovers[*]}"
  else
    pass "$name"
  fi
}

# 标记行及其以外字节；不含 BEGIN 与 END 之间的列表正文。
readme_outside_hash() {
  local file="$1"
  local begin end
  begin=$(grep -n -x -F -- "$BEGIN" "$file" | cut -d: -f1)
  end=$(grep -n -x -F -- "$END" "$file" | cut -d: -f1)
  {
    head -n "$begin" -- "$file"
    tail -n "+$end" -- "$file"
  } | sha256sum | awk '{print $1}'
}

run_expect() {
  local name="$1" want="$2"
  shift 2
  local out rc
  set +e
  out=$("$@" 2>"$EVIDENCE/${name}.err")
  rc=$?
  set -e
  printf '%s\n' "$out" >"$EVIDENCE/${name}.out"
  echo "$rc" >"$EVIDENCE/${name}.rc"
  if [[ "$rc" -eq "$want" ]]; then
    pass "$name exit=$rc"
  else
    fail "$name exit=$rc want=$want stderr=$(tr '\n' ' ' <"$EVIDENCE/${name}.err")"
  fi
}

MAIN_README_SUM=$(sha256sum -- "$ROOT/README.md" | awk '{print $1}')
PUBLISHED_SUM=$(sha256sum -- "$ROOT/data/published.json" | awk '{print $1}')
VERSION_SUM=$(sha256sum -- "$ROOT/VERSION" | awk '{print $1}')
GIT_TAG_SUM=$(sha256sum -- "$ROOT/git_tag.sh" | awk '{print $1}')
mapfile -t MAIN_TAGS_BEFORE < <(git -C "$ROOT" tag -l | sort)

log "ROOT=$ROOT"
log "main README sha256=$MAIN_README_SUM"
log "bash -n"

if bash -n "$RENDER" && bash -n "$GIT_TAG" && bash -n "$ROOT/tests/render_test.sh"; then
  pass "bash -n render.sh git_tag.sh render_test.sh"
else
  fail "bash -n"
fi

if command -v shellcheck >/dev/null 2>&1; then
  set +e
  shellcheck -s bash "$RENDER" "$GIT_TAG" "$ROOT/tests/render_test.sh"
  sc_rc=$?
  set -e
  echo "$sc_rc" >"$EVIDENCE/shellcheck.rc"
  if [[ "$sc_rc" -eq 0 ]]; then
    pass "shellcheck"
  else
    fail "shellcheck exit=$sc_rc"
  fi
else
  log "NOTE: 本机无 shellcheck，未运行静态检查，不擅自安装"
fi

run_expect "usage_no_args" 2 "$RENDER"
run_expect "git_tag_help" 2 "$GIT_TAG" --help

make_readme() {
  local dest="$1"
  cat >"$dest" <<EOF
前缀保留
$BEGIN
旧列表
$END
后缀保留
EOF
}

two_state="$EVIDENCE/state_two.json"
cat >"$two_state" <<'EOF'
{
  "schema_version": "2",
  "packages": [
    {
      "id": "alpha-app",
      "package": "alpha-app",
      "repository": "example/alpha-app",
      "description": "测试软件甲",
      "version": "1.0.0",
      "release_url": "https://github.com/example/alpha-app/releases/tag/1.0.0",
      "source_url": "https://github.com/example/alpha-app/tree/1.0.0",
      "license": "MIT",
      "updated_at": "2026-11-02T00:00:00Z",
      "ubuntu_series": ["jammy", "noble"],
      "architectures": ["amd64", "arm64"],
      "apt_source_uri": "mirror+https://apt.example.test/repos/alpha-app/mirror.list",
      "assets": [
        {
          "architecture": "amd64",
          "filename": "example/alpha-app/releases/download/1.0.0/alpha-app_1.0.0_amd64.deb",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "size": "10",
          "url": "https://github.com/example/alpha-app/releases/download/1.0.0/alpha-app_1.0.0_amd64.deb"
        },
        {
          "architecture": "arm64",
          "filename": "example/alpha-app/releases/download/1.0.0/alpha-app_1.0.0_arm64.deb",
          "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "size": "11",
          "url": "https://github.com/example/alpha-app/releases/download/1.0.0/alpha-app_1.0.0_arm64.deb"
        }
      ]
    },
    {
      "id": "beta-tool",
      "package": "beta-tool",
      "repository": "example/beta-tool",
      "description": "测试软件乙",
      "version": "2.1.3",
      "release_url": "https://github.com/example/beta-tool/releases/tag/2.1.3",
      "source_url": "https://github.com/example/beta-tool/tree/2.1.3",
      "license": "Apache-2.0",
      "updated_at": "2026-10-01T12:34:56Z",
      "ubuntu_series": ["noble"],
      "architectures": ["amd64"],
      "apt_source_uri": "mirror+https://apt.example.test/repos/beta-tool/mirror.list",
      "assets": [
        {
          "architecture": "amd64",
          "filename": "example/beta-tool/releases/download/2.1.3/beta-tool_2.1.3_amd64.deb",
          "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "size": "12",
          "url": "https://github.com/example/beta-tool/releases/download/2.1.3/beta-tool_2.1.3_amd64.deb"
        }
      ]
    }
  ]
}
EOF

empty_site="$EVIDENCE/site-empty"
empty_readme="$EVIDENCE/README.empty.md"
mkdir -p -- "$empty_site/extra"
printf 'keep\n' >"$empty_site/extra/keep.txt"
printf 'OLDHTML\n' >"$empty_site/index.html"
make_readme "$empty_readme"
cp -f -- "$ROOT/data/published.json" "$EVIDENCE/published.empty.json"
empty_state_hash=$(hash_file "$EVIDENCE/published.empty.json")
empty_outside_before=$(readme_outside_hash "$empty_readme")

run_expect "render_empty" 0 "$RENDER" --state "$EVIDENCE/published.empty.json" --readme "$empty_readme" --site "$empty_site"
assert_same_hash "empty 不改 state 输入" "$EVIDENCE/published.empty.json" "$empty_state_hash"
assert_file_has "empty readme message" "$empty_readme" "尚未完成首次发布"
assert_file_lacks "empty readme no fake version" "$empty_readme" "1.5.0"
assert_file_lacks "empty readme no https" "$empty_readme" "https://"
assert_file_lacks "empty readme no http" "$empty_readme" "http://"
assert_file_lacks "empty readme no mirror+" "$empty_readme" "mirror+"
assert_file_has "empty html message" "$empty_site/index.html" "尚未完成首次发布"
assert_file_lacks "empty html no table row" "$empty_site/index.html" "<tbody>"
assert_file_lacks "empty html no https" "$empty_site/index.html" "https://"
assert_file_lacks "empty html no http" "$empty_site/index.html" "http://"
assert_file_lacks "empty html no mirror+" "$empty_site/index.html" "mirror+"
assert_file_lacks "empty html no fake version" "$empty_site/index.html" "1.5.0"
if head -n 1 -- "$empty_site/index.html" | grep -qx '<!DOCTYPE html>'; then
  pass "empty html starts with doctype"
else
  fail "empty html 不是原始 HTML：$(head -n 1 "$empty_site/index.html")"
fi
assert_file_has "empty keeps prefix" "$empty_readme" "前缀保留"
assert_file_has "empty keeps suffix" "$empty_readme" "后缀保留"
assert_file_lacks "empty removed old list" "$empty_readme" "旧列表"
assert_eq "empty README 标记外字节" "$(readme_outside_hash "$empty_readme")" "$empty_outside_before"
assert_eq "empty did not touch extra" "$(cat "$empty_site/extra/keep.txt")" "keep"
assert_file_lacks "empty html no js" "$empty_site/index.html" "<script"
assert_file_lacks "empty html no form" "$empty_site/index.html" "<form"
assert_file_lacks "empty html no button" "$empty_site/index.html" "<button"
assert_no_workdir "empty 无 work 目录" "$empty_site"

site_two="$EVIDENCE/site-two"
readme_two="$EVIDENCE/README.two.md"
mkdir -p -- "$site_two"
make_readme "$readme_two"
two_outside_before=$(readme_outside_hash "$readme_two")
two_state_hash=$(hash_file "$two_state")
run_expect "render_two_packages" 0 "$RENDER" --state "$two_state" --readme "$readme_two" --site "$site_two"
assert_same_hash "two 不改 state 输入" "$two_state" "$two_state_hash"
assert_eq "two README 标记外字节" "$(readme_outside_hash "$readme_two")" "$two_outside_before"

assert_file_has "two md alpha" "$readme_two" "alpha-app"
assert_file_has "two md beta" "$readme_two" "beta-tool"
assert_file_has "two md alpha version" "$readme_two" "1.0.0"
assert_file_has "two md beta version" "$readme_two" "2.1.3"
assert_file_has "two md jammy noble" "$readme_two" "jammy, noble"
assert_file_has "two md amd64 arm64" "$readme_two" "amd64, arm64"
assert_file_has "two md updated" "$readme_two" "2026-11-02T00:00:00Z"
assert_file_has "two md desc" "$readme_two" "测试软件甲"
assert_file_has "two md release link" "$readme_two" "https://github.com/example/alpha-app/releases/tag/1.0.0"
assert_file_has "two md alpha jammy sources" "$readme_two" "https://apt.example.test/repos/alpha-app/jammy.sources"
assert_file_has "two md alpha noble sources" "$readme_two" "https://apt.example.test/repos/alpha-app/noble.sources"
assert_file_has "two md beta noble sources" "$readme_two" "https://apt.example.test/repos/beta-tool/noble.sources"
assert_file_has "two md sources header" "$readme_two" "添加源配置"
assert_file_has "two md one-click header" "$readme_two" "一键加源"
alpha_command="curl -fsSL --proto '=https' --proto-redir '=https' -o add_source.sh 'https://apt.example.test/add_source.sh' && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url 'https://apt.example.test' --software 'alpha-app'"
alpha_code="<code>${alpha_command//&/\&amp;}</code>"
alpha_code=${alpha_code//\'/\&#39;}
assert_file_has "two md 可复制安全命令" "$readme_two" "\`$alpha_command\`"
assert_file_has "two html 可复制安全命令" "$site_two/index.html" "$alpha_code"
# shellcheck disable=SC2016 # Markdown 代码跨度的字面量反引号
assert_eq "two md 每软件恰一命令" "$(grep -o '`curl -fsSL ' "$readme_two" | wc -l)" "2"
assert_eq "two html 每软件恰一命令" "$(grep -o '<code>curl -fsSL ' "$site_two/index.html" | wc -l)" "2"
assert_file_lacks "two md 不管道提权" "$readme_two" "| sudo"
assert_file_lacks "two html 不管道提权" "$site_two/index.html" "| sudo"
assert_file_lacks "two md no pool path" "$readme_two" "pool/"
assert_file_lacks "two md no mirror.list" "$readme_two" "mirror.list"
assert_file_lacks "two md no fake rustdesk" "$readme_two" "1.5.0"
assert_file_has "two html alpha" "$site_two/index.html" "alpha-app"
assert_file_has "two html beta" "$site_two/index.html" "beta-tool"
assert_file_has "two html arch" "$site_two/index.html" "amd64, arm64"
assert_file_has "two html sources header" "$site_two/index.html" "添加源配置"
assert_file_has "two html alpha jammy sources" "$site_two/index.html" "https://apt.example.test/repos/alpha-app/jammy.sources"
assert_file_has "two html alpha noble sources" "$site_two/index.html" "https://apt.example.test/repos/alpha-app/noble.sources"
assert_file_has "two html beta noble sources" "$site_two/index.html" "https://apt.example.test/repos/beta-tool/noble.sources"
assert_file_has "two html no js" "$site_two/index.html" "静态展示"
assert_file_lacks "two html no script" "$site_two/index.html" "<script"
assert_file_lacks "two html no form" "$site_two/index.html" "<form"
assert_file_lacks "two html no button" "$site_two/index.html" "<button"
assert_file_lacks "two html no pool path" "$site_two/index.html" "pool/"
assert_file_lacks "two html no mirror.list" "$site_two/index.html" "mirror.list"
assert_file_lacks "two html no fake rustdesk" "$site_two/index.html" "1.5.0"
if find "$site_two" -name '*.deb' -print -quit | grep -q .; then
  fail "two site 含 deb"
else
  pass "two site 无 deb"
fi
if head -n 1 -- "$site_two/index.html" | grep -qx '<!DOCTYPE html>'; then
  pass "html starts with doctype"
else
  fail "html 不是原始 HTML：$(head -n 1 "$site_two/index.html")"
fi
if grep -q '^<html lang="zh-CN">$' "$site_two/index.html"; then
  pass "html 为多行静态页"
else
  fail "html 未按行展开"
fi
if [[ -f "$readme_two" && -f "$site_two/index.html" ]]; then
  cp -f -- "$readme_two" "$EVIDENCE/README.two.first.md"
  cp -f -- "$site_two/index.html" "$EVIDENCE/index.two.first.html"
else
  fail "two 产物缺失，跳过幂等基准拷贝"
  : >"$EVIDENCE/README.two.first.md"
  : >"$EVIDENCE/index.two.first.html"
fi
run_expect "render_two_idempotent" 0 "$RENDER" --state "$two_state" --readme "$readme_two" --site "$site_two"
if cmp -s -- "$readme_two" "$EVIDENCE/README.two.first.md"; then
  pass "readme idempotent"
else
  fail "readme 重跑后字节变化"
fi
if cmp -s -- "$site_two/index.html" "$EVIDENCE/index.two.first.html"; then
  pass "html idempotent"
else
  fail "html 重跑后字节变化"
fi
assert_eq "idempotent README 标记外字节" "$(readme_outside_hash "$readme_two")" "$two_outside_before"

http_state="$EVIDENCE/state_http_mirror.json"
jq '.packages |= [.[0] | .apt_source_uri="mirror+http://127.0.0.1:9/repos/alpha-app/mirror.list"]' \
  "$two_state" >"$http_state"
http_site="$EVIDENCE/site-http"
http_readme="$EVIDENCE/README.http.md"
mkdir -p -- "$http_site"
make_readme "$http_readme"
run_expect "render_http_mirror" 0 "$RENDER" --state "$http_state" --readme "$http_readme" --site "$http_site"
assert_file_has "http md jammy sources" "$http_readme" "http://127.0.0.1:9/repos/alpha-app/jammy.sources"
assert_file_has "http html jammy sources" "$http_site/index.html" "http://127.0.0.1:9/repos/alpha-app/jammy.sources"
assert_file_lacks "http md 无 mirror+" "$http_readme" "mirror+"
assert_file_lacks "http html 无 mirror+" "$http_site/index.html" "mirror+"
assert_file_has "http md 不支持一键" "$http_readme" "HTTP 夹具不支持一键加源"
assert_file_has "http html 不支持一键" "$http_site/index.html" "HTTP 夹具不支持一键加源"
assert_file_lacks "http md 不生成命令" "$http_readme" "curl -fsSL"
assert_file_lacks "http html 不生成命令" "$http_site/index.html" "curl -fsSL"

path_state="$EVIDENCE/state_site_path.json"
jq '.packages |= [.[0] | .id="my_app.v1" | .apt_source_uri="mirror+https://apt.example.test:8443/team/site_v2/repos/my_app.v1/mirror.list"]' \
  "$two_state" >"$path_state"
path_site="$EVIDENCE/site-path"
path_readme="$EVIDENCE/README.path.md"
mkdir -p -- "$path_site"
make_readme "$path_readme"
run_expect "render_site_path" 0 "$RENDER" --state "$path_state" --readme "$path_readme" --site "$path_site"
assert_file_has "path md 精确站点根下载" "$path_readme" "https://apt.example.test:8443/team/site_v2/add_source.sh"
assert_file_has "path html 安全还原根与 id" "$path_site/index.html" "--site-url &#39;https://apt.example.test:8443/team/site_v2&#39; --software &#39;my_app.v1&#39;"
assert_file_has "path md 保留手动源链接" "$path_readme" "https://apt.example.test:8443/team/site_v2/repos/my_app.v1/jammy.sources"

slash_state="$EVIDENCE/state_slash_filename.json"
jq '.packages[0].assets[0].filename="/example/alpha-app/releases/download/1.0.0/alpha-app_1.0.0_amd64.deb"' \
  "$two_state" >"$slash_state"
slash_site="$EVIDENCE/site-slash"
slash_readme="$EVIDENCE/README.slash.md"
mkdir -p -- "$slash_site"
make_readme "$slash_readme"
run_expect "render_leading_slash_filename" 0 "$RENDER" --state "$slash_state" --readme "$slash_readme" --site "$slash_site"
assert_file_has "slash filename 仍渲染版本" "$slash_readme" "1.0.0"

inject_state="$EVIDENCE/state_inject.json"
jq --arg desc '</td><script>alert(1)</script> <img src=x onerror=alert(1)> | [x](https://evil.example) & "quotes" `code` *bold* _em_' \
  --arg pkg 'alpha<app>' \
  '.packages[0].description=$desc | .packages[0].package=$pkg' \
  "$two_state" >"$inject_state"
inject_site="$EVIDENCE/site-inject"
inject_readme="$EVIDENCE/README.inject.md"
mkdir -p -- "$inject_site"
make_readme "$inject_readme"
run_expect "render_inject" 0 "$RENDER" --state "$inject_state" --readme "$inject_readme" --site "$inject_site"
assert_file_lacks "inject html raw script" "$inject_site/index.html" "<script"
assert_file_lacks "inject html raw img" "$inject_site/index.html" "<img"
assert_file_has "inject html escaped lt" "$inject_site/index.html" "&lt;script&gt;"
assert_file_has "inject html escaped img" "$inject_site/index.html" "&lt;img src=x onerror=alert(1)&gt;"
assert_file_has "inject html escaped amp" "$inject_site/index.html" "&amp;"
assert_file_has "inject html escaped package" "$inject_site/index.html" "alpha&lt;app&gt;"
assert_file_has "inject html escaped quote" "$inject_site/index.html" "&quot;quotes&quot;"
# shellcheck disable=SC2016 # fixture 字面量，故意单引号
assert_file_has "inject html literal tick" "$inject_site/index.html" '`code`'
assert_file_has "inject html literal star" "$inject_site/index.html" '*bold*'
assert_file_has "inject html sources still linked" "$inject_site/index.html" "https://apt.example.test/repos/alpha-app/jammy.sources"
assert_file_lacks "inject md raw script" "$inject_readme" "<script"
assert_file_lacks "inject md raw img" "$inject_readme" "<img"
assert_file_lacks "inject md raw lt-app" "$inject_readme" "alpha<app>"
assert_file_has "inject md escaped script" "$inject_readme" "&lt;script&gt;"
assert_file_has "inject md escaped img" "$inject_readme" "&lt;img src=x onerror=alert(1)&gt;"
assert_file_has "inject md escaped amp" "$inject_readme" "&amp;"
assert_file_has "inject md escaped package" "$inject_readme" "alpha&lt;app&gt;"
assert_file_has "inject md escaped pipe" "$inject_readme" "\|"
# shellcheck disable=SC2016 # fixture 字面量，故意单引号
assert_file_has "inject md escaped tick" "$inject_readme" '\`code\`'
assert_file_has "inject md escaped star" "$inject_readme" '\*bold\*'
assert_file_has "inject md escaped under" "$inject_readme" '\_em\_'
assert_file_has "inject md escaped quote" "$inject_readme" "&quot;quotes&quot;"
inject_row=$(grep -F 'alpha&lt;app&gt;' "$inject_readme" || true)
inject_plain=${inject_row//\\|/}
inject_pipe_chars=${inject_plain//[!|]/}
assert_eq "inject md 表行列数" "${#inject_pipe_chars}" "9"

# 失败不得覆盖已有 README/页面；哨兵为原始目标 sha256。
bad_site="$EVIDENCE/site-bad"
bad_readme="$EVIDENCE/README.bad.md"
mkdir -p -- "$bad_site"
printf 'OLDHTML\n' >"$bad_site/index.html"
make_readme "$bad_readme"
bad_readme_hash=$(hash_file "$bad_readme")
bad_html_hash=$(hash_file "$bad_site/index.html")

printf '{"schema_version":1,"packages":[]}\n' >"$EVIDENCE/state_schema1_empty.json"
schema1_empty_hash=$(hash_file "$EVIDENCE/state_schema1_empty.json")
run_expect "reject_schema1_empty" 1 "$RENDER" --state "$EVIDENCE/state_schema1_empty.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "schema1 empty 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "schema1 empty 未改 html" "$bad_site/index.html" "$bad_html_hash"
assert_same_hash "schema1 empty 未改输入" "$EVIDENCE/state_schema1_empty.json" "$schema1_empty_hash"
assert_no_workdir "schema1 empty 无 work 目录" "$bad_site"

printf '{"schema_version":2,"packages":[]}\n' >"$EVIDENCE/state_schema_number2.json"
run_expect "reject_schema_number_2" 1 "$RENDER" --state "$EVIDENCE/state_schema_number2.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "number schema 2 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "number schema 2 未改 html" "$bad_site/index.html" "$bad_html_hash"
assert_no_workdir "number schema 2 无 work 目录" "$bad_site"

old_nonempty="$EVIDENCE/state_old_nonempty.json"
cat >"$old_nonempty" <<'EOF'
{
  "schema_version": 1,
  "packages": [
    {
      "id": "alpha-app",
      "package": "alpha-app",
      "repository": "example/alpha-app",
      "description": "旧镜像条目",
      "version": "1.0.0",
      "release_url": "https://github.com/example/alpha-app/releases/tag/1.0.0",
      "source_url": "https://github.com/example/alpha-app/tree/1.0.0",
      "license": "MIT",
      "updated_at": "2026-11-02T00:00:00Z",
      "ubuntu_series": ["jammy"],
      "architectures": ["amd64"],
      "assets": [
        {
          "architecture": "amd64",
          "filename": "pool/main/a/alpha-app/alpha-app_1.0.0_amd64.deb",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "size": 10,
          "url": "https://github.com/example/alpha-app/releases/download/1.0.0/alpha-app_1.0.0_amd64.deb"
        }
      ]
    }
  ]
}
EOF
old_nonempty_hash=$(hash_file "$old_nonempty")
run_expect "reject_old_nonempty_schema" 1 "$RENDER" --state "$old_nonempty" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "旧非空 schema 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "旧非空 schema 未改 html" "$bad_site/index.html" "$bad_html_hash"
assert_same_hash "旧非空 schema 未改输入" "$old_nonempty" "$old_nonempty_hash"
assert_file_lacks "旧非空 schema 未写入 pool" "$bad_readme" "pool/"
assert_no_workdir "旧非空 schema 无 work 目录" "$bad_site"

jq '.packages[0].assets[0].filename="pool/main/a/alpha-app/alpha-app_1.0.0_amd64.deb"' \
  "$two_state" >"$EVIDENCE/state_pool_filename.json"
pool_filename_hash=$(hash_file "$EVIDENCE/state_pool_filename.json")
run_expect "reject_pool_filename" 1 "$RENDER" --state "$EVIDENCE/state_pool_filename.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "pool filename 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "pool filename 未改 html" "$bad_site/index.html" "$bad_html_hash"
assert_same_hash "pool filename 未改输入" "$EVIDENCE/state_pool_filename.json" "$pool_filename_hash"

jq '.packages[0].assets[0].filename="https://github.com/example/alpha-app/releases/download/1.0.0/alpha-app_1.0.0_amd64.deb"' \
  "$two_state" >"$EVIDENCE/state_abs_url_filename.json"
run_expect "reject_absolute_url_filename" 1 "$RENDER" --state "$EVIDENCE/state_abs_url_filename.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "绝对 URL filename 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "绝对 URL filename 未改 html" "$bad_site/index.html" "$bad_html_hash"

jq '.packages[0].assets[0].filename="example/alpha-app/releases/download/1.0.0/../../../etc/os-release"' \
  "$two_state" >"$EVIDENCE/state_dotdot_filename.json"
run_expect "reject_dotdot_filename" 1 "$RENDER" --state "$EVIDENCE/state_dotdot_filename.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "dotdot filename 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "dotdot filename 未改 html" "$bad_site/index.html" "$bad_html_hash"

jq '.packages[0].assets[0].size=10' "$two_state" >"$EVIDENCE/state_numeric_size.json"
run_expect "reject_numeric_size" 1 "$RENDER" --state "$EVIDENCE/state_numeric_size.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "数字 size 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "数字 size 未改 html" "$bad_site/index.html" "$bad_html_hash"

jq 'del(.packages[0].apt_source_uri)' "$two_state" >"$EVIDENCE/state_missing_uri.json"
run_expect "reject_missing_apt_source_uri" 1 "$RENDER" --state "$EVIDENCE/state_missing_uri.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "缺 apt_source_uri 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "缺 apt_source_uri 未改 html" "$bad_site/index.html" "$bad_html_hash"

jq '.packages[0].apt_source_uri="mirror+file:///work/repos/alpha-app/mirror.list"' \
  "$two_state" >"$EVIDENCE/state_file_uri.json"
file_uri_hash=$(hash_file "$EVIDENCE/state_file_uri.json")
run_expect "reject_mirror_file_uri" 1 "$RENDER" --state "$EVIDENCE/state_file_uri.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "mirror+file 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "mirror+file 未改 html" "$bad_site/index.html" "$bad_html_hash"
assert_same_hash "mirror+file 未改输入" "$EVIDENCE/state_file_uri.json" "$file_uri_hash"
assert_file_lacks "mirror+file 未写入页面" "$bad_site/index.html" "file://"

jq '.packages[0].apt_source_uri="mirror+https://apt.example.test/repos/wrong-id/mirror.list"' \
  "$two_state" >"$EVIDENCE/state_id_mismatch.json"
run_expect "reject_uri_id_mismatch" 1 "$RENDER" --state "$EVIDENCE/state_id_mismatch.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "id 不匹配 URI 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "id 不匹配 URI 未改 html" "$bad_site/index.html" "$bad_html_hash"

# 命令只接受与 sync 路径契约一致的 id、规范站点根与 Ubuntu 代号。
# 每例均走真实 render，且失败不能触碰既有产物。
while IFS='|' read -r case_name bad_id bad_uri; do
  bad_command_state="$EVIDENCE/state_command_${case_name}.json"
  jq --arg id "$bad_id" --arg uri "$bad_uri" \
    '.packages |= [.[0] | .id=$id | .apt_source_uri=$uri]' \
    "$two_state" >"$bad_command_state"
  run_expect "reject_command_${case_name}" 1 "$RENDER" --state "$bad_command_state" --readme "$bad_readme" --site "$bad_site"
  assert_same_hash "$case_name 未改 README" "$bad_readme" "$bad_readme_hash"
  assert_same_hash "$case_name 未改 html" "$bad_site/index.html" "$bad_html_hash"
done <<'EOF'
id_shell|alpha;id|mirror+https://apt.example.test/repos/alpha;id/mirror.list
id_dotdot|a..b|mirror+https://apt.example.test/repos/a..b/mirror.list
id_regex|alpha.app|mirror+https://apt.example.test/repos/alphaXapp/mirror.list
uri_userinfo|alpha-app|mirror+https://user@apt.example.test/repos/alpha-app/mirror.list
uri_query|alpha-app|mirror+https://apt.example.test/?x=/repos/alpha-app/mirror.list
uri_fragment|alpha-app|mirror+https://apt.example.test/#x/repos/alpha-app/mirror.list
uri_encoded|alpha-app|mirror+https://apt.example.test/%27/repos/alpha-app/mirror.list
uri_dotdot|alpha-app|mirror+https://apt.example.test/a/../repos/alpha-app/mirror.list
uri_dot|alpha-app|mirror+https://apt.example.test/./repos/alpha-app/mirror.list
uri_empty_segment|alpha-app|mirror+https://apt.example.test/a//b/repos/alpha-app/mirror.list
uri_http_public|alpha-app|mirror+http://apt.example.test/repos/alpha-app/mirror.list
EOF

jq '.packages[0].ubuntu_series=["noble](https://evil.example)"]' "$two_state" >"$EVIDENCE/state_bad_series_link.json"
run_expect "reject_bad_series_link" 1 "$RENDER" --state "$EVIDENCE/state_bad_series_link.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "series 链接注入未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "series 链接注入未改 html" "$bad_site/index.html" "$bad_html_hash"

missing_end="$EVIDENCE/README.missing-end.md"
cat >"$missing_end" <<EOF
$BEGIN
无结束
EOF
missing_end_hash=$(hash_file "$missing_end")
run_expect "reject_missing_end" 1 "$RENDER" --state "$two_state" --readme "$missing_end" --site "$bad_site"
assert_same_hash "缺 END 未改 README" "$missing_end" "$missing_end_hash"
assert_same_hash "缺 END 未改 html" "$bad_site/index.html" "$bad_html_hash"
assert_no_workdir "缺 END 无 work 目录" "$bad_site"

dup="$EVIDENCE/README.dup.md"
cat >"$dup" <<EOF
$BEGIN
x
$BEGIN
$END
EOF
dup_readme_hash=$(hash_file "$dup")
run_expect "reject_dup_begin" 1 "$RENDER" --state "$two_state" --readme "$dup" --site "$bad_site"
assert_same_hash "重复 BEGIN 未改 README" "$dup" "$dup_readme_hash"
assert_same_hash "重复 BEGIN 未改 html" "$bad_site/index.html" "$bad_html_hash"
assert_no_workdir "重复 BEGIN 无 work 目录" "$bad_site"

rev="$EVIDENCE/README.rev.md"
cat >"$rev" <<EOF
$END
x
$BEGIN
EOF
rev_readme_hash=$(hash_file "$rev")
run_expect "reject_reversed_markers" 1 "$RENDER" --state "$two_state" --readme "$rev" --site "$bad_site"
assert_same_hash "标记倒序 未改 README" "$rev" "$rev_readme_hash"
assert_same_hash "标记倒序 未改 html" "$bad_site/index.html" "$bad_html_hash"

jq '.packages[0].release_url="http://example.com/x"' "$two_state" >"$EVIDENCE/state_http.json"
run_expect "reject_http_url" 1 "$RENDER" --state "$EVIDENCE/state_http.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "http URL 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "http URL 未改 html" "$bad_site/index.html" "$bad_html_hash"

jq '.packages[0].updated_at="2026-11-02"' "$two_state" >"$EVIDENCE/state_bad_time.json"
run_expect "reject_bad_time" 1 "$RENDER" --state "$EVIDENCE/state_bad_time.json" --readme "$bad_readme" --site "$bad_site"
assert_same_hash "时间格式错 未改 README" "$bad_readme" "$bad_readme_hash"
assert_same_hash "时间格式错 未改 html" "$bad_site/index.html" "$bad_html_hash"

ln -s -- "$two_state" "$EVIDENCE/state.link"
two_readme_hash=$(hash_file "$readme_two")
two_html_hash=$(hash_file "$site_two/index.html")
run_expect "reject_state_symlink" 1 "$RENDER" --state "$EVIDENCE/state.link" --readme "$readme_two" --site "$site_two"
assert_same_hash "state symlink 未改 README" "$readme_two" "$two_readme_hash"
assert_same_hash "state symlink 未改 html" "$site_two/index.html" "$two_html_hash"

ln -s -- "$readme_two" "$EVIDENCE/readme.link"
run_expect "reject_readme_symlink" 1 "$RENDER" --state "$two_state" --readme "$EVIDENCE/readme.link" --site "$site_two"
assert_same_hash "readme symlink 未改 README" "$readme_two" "$two_readme_hash"
assert_same_hash "readme symlink 未改 html" "$site_two/index.html" "$two_html_hash"

ln -s -- "$site_two" "$EVIDENCE/site.link"
run_expect "reject_site_symlink" 1 "$RENDER" --state "$two_state" --readme "$readme_two" --site "$EVIDENCE/site.link"
assert_same_hash "site symlink 未改 README" "$readme_two" "$two_readme_hash"
assert_same_hash "site symlink 未改 html" "$site_two/index.html" "$two_html_hash"

anc="$EVIDENCE/anc"
mkdir -p -- "$anc/real/site"
make_readme "$anc/real/README.md"
printf 'HTML-SENTINEL\n' >"$anc/real/site/index.html"
cp -f -- "$two_state" "$anc/real/state.json"
ln -s -- "$anc/real" "$anc/via"
anc_readme_hash=$(hash_file "$anc/real/README.md")
anc_html_hash=$(hash_file "$anc/real/site/index.html")
run_expect "reject_readme_ancestor_symlink" 1 "$RENDER" --state "$anc/real/state.json" --readme "$anc/via/README.md" --site "$anc/real/site"
assert_same_hash "readme 祖先 symlink 未改 README" "$anc/real/README.md" "$anc_readme_hash"
assert_same_hash "readme 祖先 symlink 未改 html" "$anc/real/site/index.html" "$anc_html_hash"
assert_no_workdir "readme 祖先 symlink 无 work 目录" "$anc/real/site"

run_expect "reject_site_ancestor_symlink" 1 "$RENDER" --state "$anc/real/state.json" --readme "$anc/real/README.md" --site "$anc/via/site"
assert_same_hash "site 祖先 symlink 未改 README" "$anc/real/README.md" "$anc_readme_hash"
assert_same_hash "site 祖先 symlink 未改 html" "$anc/real/site/index.html" "$anc_html_hash"
assert_no_workdir "site 祖先 symlink 无 work 目录" "$anc/real/site"

run_expect "reject_state_ancestor_symlink" 1 "$RENDER" --state "$anc/via/state.json" --readme "$anc/real/README.md" --site "$anc/real/site"
assert_same_hash "state 祖先 symlink 未改 README" "$anc/real/README.md" "$anc_readme_hash"
assert_same_hash "state 祖先 symlink 未改 html" "$anc/real/site/index.html" "$anc_html_hash"
assert_no_workdir "state 祖先 symlink 无 work 目录" "$anc/real/site"

dangle_site="$EVIDENCE/site-dangle"
dangle_readme="$EVIDENCE/README.dangle.md"
mkdir -p -- "$dangle_site"
make_readme "$dangle_readme"
ln -s -- "$EVIDENCE/missing-index.html" "$dangle_site/index.html"
dangle_target=$(readlink -- "$dangle_site/index.html")
dangle_readme_hash=$(hash_file "$dangle_readme")
run_expect "reject_dangling_index_html" 1 "$RENDER" --state "$two_state" --readme "$dangle_readme" --site "$dangle_site"
assert_same_hash "dangling index 未改 README" "$dangle_readme" "$dangle_readme_hash"
if [[ -L "$dangle_site/index.html" && "$(readlink -- "$dangle_site/index.html")" == "$dangle_target" ]]; then
  pass "dangling index.html 仍为原符号链接"
else
  fail "dangling index.html 被替换或改写"
fi
if [[ -f "$dangle_site/index.html" ]]; then
  fail "dangling index.html 变成了普通文件"
else
  pass "dangling index.html 未变成普通文件"
fi
assert_no_workdir "dangling index 无 work 目录" "$dangle_site"

# git_tag.sh：手动入口一律拒绝；auto/push 见 release_test。
tag_repo="$EVIDENCE/tag-repo"
mkdir -p -- "$tag_repo"
git init --quiet "$tag_repo"
printf '0.1.0\n' >"$tag_repo/VERSION"
git -C "$tag_repo" add VERSION
git -C "$tag_repo" -c user.name='apt-hub-render-test' -c user.email='apt-hub-render-test@invalid' commit --quiet -m 'test version'
run_expect "git_tag_version_refuse" 1 bash -c "cd \"$tag_repo\" && \"$GIT_TAG\" --version 0.1.0"
run_expect "git_tag_custom_refuse" 1 bash -c "cd \"$tag_repo\" && \"$GIT_TAG\" custom"
assert_eq "git_tag 拒绝后 VERSION 未改" "$(tr -d '[:space:]' <"$tag_repo/VERSION")" "0.1.0"
if git -C "$tag_repo" rev-parse -q --verify refs/tags/v0.1.0 >/dev/null; then
  fail "手动入口仍创建了标签"
else
  pass "手动入口未创建标签"
fi
printf 'dirty\n' >"$tag_repo/dirty.txt"
run_expect "git_tag_dirty" 1 bash -c "cd \"$tag_repo\" && \"$GIT_TAG\" auto"
rm -f -- "$tag_repo/dirty.txt"
run_expect "git_tag_force_flag" 1 bash -c "cd \"$tag_repo\" && \"$GIT_TAG\" --version 0.1.0 --force"
run_expect "git_tag_unknown" 1 bash -c "cd \"$tag_repo\" && \"$GIT_TAG\" bogus-mode"

if grep -E -q -- 'tag[[:space:]]+-f[[:space:]]+latest|git[[:space:]]+push[[:space:]].*--delete|[[:space:]]git[[:space:]]+add[[:space:]]+-A'; then
  fail "git_tag.sh 仍含 latest 强移/删远端/add -A"
else
  pass "git_tag.sh 无 latest 强移与 add -A"
fi
if grep -E -q -- 'git[[:space:]]+push|git[[:space:]]+add --' "$GIT_TAG"; then
  pass "git_tag.sh 含受控 push/精确 add（新契约）"
else
  fail "git_tag.sh 缺少 push/精确 add"
fi

mapfile -t MAIN_TAGS_AFTER < <(git -C "$ROOT" tag -l | sort)
if [[ "$(printf '%s\n' "${MAIN_TAGS_BEFORE[@]-}")" == "$(printf '%s\n' "${MAIN_TAGS_AFTER[@]-}")" ]]; then
  pass "本仓标签列表未变"
else
  fail "本仓标签被改动"
fi

after_readme=$(sha256sum -- "$ROOT/README.md" | awk '{print $1}')
after_published=$(sha256sum -- "$ROOT/data/published.json" | awk '{print $1}')
after_version=$(sha256sum -- "$ROOT/VERSION" | awk '{print $1}')
after_git_tag=$(sha256sum -- "$ROOT/git_tag.sh" | awk '{print $1}')
assert_eq "主 README 未被测试改写" "$after_readme" "$MAIN_README_SUM"
assert_eq "data/published.json 仍为空状态原文" "$after_published" "$PUBLISHED_SUM"
assert_eq "VERSION 未被 git_tag 测试改写" "$after_version" "$VERSION_SUM"
assert_eq "git_tag.sh 字节未变" "$after_git_tag" "$GIT_TAG_SUM"

if jq -e '.schema_version=="2" and .packages==[]' "$ROOT/data/published.json" >/dev/null; then
  pass "published.json schema2 空 packages"
else
  fail "published.json 不是 schema2 空 packages"
fi
if grep -F -q -- '1.5.0' "$ROOT/data/published.json"; then
  fail "published.json 含候选 1.5.0"
else
  pass "published.json 不含候选 1.5.0"
fi

log "结果: pass=$passes fail=$fails"
echo "$passes" >"$EVIDENCE/passes"
echo "$fails" >"$EVIDENCE/fails"
if [[ "$fails" -ne 0 ]]; then
  exit 1
fi
exit 0
