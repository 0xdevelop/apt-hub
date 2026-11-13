#!/usr/bin/env bash
# 用已发布 state 渲染 README 固定标记区与候选站点 index.html。
# 校验失败不改 README/页面；不访问网络。
set -euo pipefail

BEGIN_MARK='<!-- APT-HUB:PACKAGES:BEGIN -->'
END_MARK='<!-- APT-HUB:PACKAGES:END -->'
HTML_PLACEHOLDER='__APT_HUB_PACKAGE_BODY__'

usage() {
  echo "用法: scripts/render.sh --state <state.json> --readme <README副本> --site <已有候选站点目录> [--repository <owner/repo> --release-tag <vX.Y.Z>]" >&2
  exit 2
}

die() {
  echo "$*" >&2
  exit 1
}

state_arg=""
readme_arg=""
site_arg=""
repository_arg=""
release_tag_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)
      [[ $# -ge 2 ]] || usage
      state_arg="$2"
      shift 2
      ;;
    --readme)
      [[ $# -ge 2 ]] || usage
      readme_arg="$2"
      shift 2
      ;;
    --site)
      [[ $# -ge 2 ]] || usage
      site_arg="$2"
      shift 2
      ;;
    --repository)
      [[ $# -ge 2 ]] || usage
      repository_arg="$2"
      shift 2
      ;;
    --release-tag)
      [[ $# -ge 2 ]] || usage
      release_tag_arg="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      ;;
  esac
done

[[ -n "$state_arg" && -n "$readme_arg" && -n "$site_arg" ]] || usage
if [[ -n "$repository_arg" || -n "$release_tag_arg" ]]; then
  if [[ -z "$repository_arg" || -z "$release_tag_arg" ]]; then
    die "repository 与 release-tag 必须成对给出"
  fi
  if [[ ! "$repository_arg" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*\/[A-Za-z0-9_][A-Za-z0-9._-]*$ || "$repository_arg" == *..* ]]; then
    die "repository 必须是 owner/name"
  fi
  if [[ ! "$release_tag_arg" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "release-tag 必须是严格 vX.Y.Z"
  fi
fi
command -v jq >/dev/null 2>&1 || die "需要 jq"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "$script_dir/.." && pwd)
template_dir="$root_dir/templates"
readme_header="$template_dir/readme_packages.md"
readme_empty="$template_dir/readme_empty.md"
html_template="$template_dir/index.html"
[[ -f "$readme_header" && -f "$readme_empty" && -f "$html_template" ]] || die "缺少 templates/ 下的渲染模板"

# 检查未解析原始路径的每一段；-L 在 dangling symlink 上为真，-e 为假。
path_has_symlink_component() {
  local input="$1"
  local candidate part
  if [[ "$input" == /* ]]; then
    candidate="/"
    input="${input#/}"
  else
    candidate="."
  fi
  while [[ -n "$input" ]]; do
    part="${input%%/*}"
    if [[ "$input" == */* ]]; then
      input="${input#*/}"
    else
      input=""
    fi
    [[ -n "$part" ]] || continue
    if [[ "$part" == "." ]]; then
      continue
    fi
    if [[ "$part" == ".." ]]; then
      if [[ "$candidate" == "/" || "$candidate" == "." ]]; then
        continue
      fi
      candidate=$(dirname -- "$candidate")
      continue
    fi
    if [[ "$candidate" == "/" ]]; then
      candidate="/$part"
    else
      candidate="$candidate/$part"
    fi
    if [[ -L "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

reject_unresolved_symlinks() {
  local label="$1"
  local raw="$2"
  if path_has_symlink_component "$raw"; then
    die "拒绝符号链接: $label"
  fi
}

reject_unresolved_symlinks "--state" "$state_arg"
reject_unresolved_symlinks "--readme" "$readme_arg"
reject_unresolved_symlinks "--site" "$site_arg"
reject_unresolved_symlinks "site/index.html" "$site_arg/index.html"

[[ -e "$state_arg" ]] || die "state 不存在: $state_arg"
[[ -e "$readme_arg" ]] || die "readme 不存在: $readme_arg"
[[ -e "$site_arg" ]] || die "site 不存在: $site_arg"

state=$(readlink -f -- "$state_arg")
readme=$(readlink -f -- "$readme_arg")
site=$(readlink -f -- "$site_arg")
[[ -f "$state" ]] || die "state 不是文件: $state_arg"
[[ -f "$readme" ]] || die "readme 不是文件: $readme_arg"
[[ -d "$site" ]] || die "site 不是目录: $site_arg"
html_dst="$site/index.html"
if [[ -L "$html_dst" ]]; then
  die "拒绝覆盖符号链接: $html_dst"
fi
if [[ -e "$html_dst" && ! -f "$html_dst" ]]; then
  die "site/index.html 不是普通文件"
fi

# shellcheck disable=SC2016 # jq 程序字面量，故意单引号不插值
validate_jq='
def fail($m): error($m);
def need_string($path):
  if type != "string" or . == "" then fail($path + " 必须是非空字符串") else . end;
def need_https($path):
  need_string($path)
  | if (test("^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+$") | not) then
      fail($path + " 必须是不含空白与括号的 https URL")
    else . end;
def need_utc($path):
  need_string($path)
  | if (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not) then
      fail($path + " 必须是 UTC 时间 YYYY-MM-DDTHH:MM:SSZ")
    else . end;
def need_sha256($path):
  need_string($path)
  | if (test("^[0-9a-fA-F]{64}$") | not) then fail($path + " 必须是 64 位 hex") else . end;
def need_decimal_size($path):
  need_string($path)
  | if (test("^(0|[1-9][0-9]*)$") | not) then
      fail($path + " 必须是十进制非负整数字符串")
    else . end;
def need_string_list($path):
  if type != "array" or length == 0 then fail($path + " 必须是非空数组") else . end
  | if (map(type == "string" and . != "") | all | not) then fail($path + " 元素必须是非空字符串") else . end
  | if (unique | length) != length then fail($path + " 不能重复") else . end;
def need_official_filename($path):
  need_string($path)
  | if test("^https?://") then fail($path + " 不能是绝对 URL") else . end
  | if test("^pool/") or test("/pool/") then fail($path + " 不能是 pool 路径") else . end
  | if test("(^|/|\\\\)\\.\\.(/|$|\\\\)") then fail($path + " 不能含父目录段") else . end
  | if test("[[:space:]]") then fail($path + " 不能含空白") else . end
  | .;
def need_apt_source_uri($path; $id):
  need_string($path)
  | . as $uri
  | ("/repos/" + $id + "/mirror.list") as $suffix
  | if (test("^mirror\\+(https|http)://") | not) or (endswith($suffix) | not) then
      fail($path + " 必须是 mirror+https|http://站点/repos/" + $id + "/mirror.list")
    else . end
  | (sub("^mirror\\+"; "") | rtrimstr($suffix)) as $site
  | if ($site | test("^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?(/[A-Za-z0-9._~/-]+)?$") | not) then
      fail($path + " 站点根必须是无用户信息、查询、片段与编码字符的安全 URL")
    else . end
  | ($site | sub("^https?://[^/]+"; "")) as $site_path
  | if ($site_path | test("(^|/)\\.\\.?(/|$)|//") or endswith("/")) then
      fail($path + " 站点根不能含点目录或空路径段")
    else . end
  | if ($site | startswith("http://"))
       and ($site | test("^http://(127\\.0\\.0\\.1|localhost)(:[0-9]+)?(/|$)") | not) then
      fail($path + " HTTP 仅允许本地隔离夹具")
    else $uri end;
def need_asset($prefix):
  if type != "object" then fail($prefix + " 必须是对象") else . end
  | (.architecture | need_string($prefix + ".architecture")) as $_a
  | (.filename | need_official_filename($prefix + ".filename")) as $_f
  | (.sha256 | need_sha256($prefix + ".sha256")) as $_h
  | (.size | need_decimal_size($prefix + ".size")) as $_s
  | (.url | need_https($prefix + ".url")) as $_u
  | .;
def need_package($i):
  ("packages[" + ($i | tostring) + "]") as $p
  | if type != "object" then fail($p + " 必须是对象") else . end
  | (.id | need_string($p + ".id")
      | if (test("^[A-Za-z0-9][A-Za-z0-9_.-]*$") | not) or contains("..") then
          fail($p + ".id 不是安全源 id")
        else . end) as $id
  | (.package | need_string($p + ".package")) as $_pkg
  | (.repository | need_string($p + ".repository")
      | if (test("^[^/[:space:]]+/[^/[:space:]]+$") | not) then
          fail($p + ".repository 必须是 owner/name")
        else . end) as $_repo
  | (if (.description | type) != "string" then fail($p + ".description 必须是字符串") else . end) as $_d
  | (.version | need_string($p + ".version")) as $_v
  | (.release_url | need_https($p + ".release_url")) as $_r
  | (.source_url | need_https($p + ".source_url")) as $_src
  | (if (.license | type) != "string" or .license == "" then fail($p + ".license 必须是非空字符串") else . end) as $_lic
  | (.updated_at | need_utc($p + ".updated_at")) as $_u
  | (.ubuntu_series | need_string_list($p + ".ubuntu_series")
      | if (map(test("^[a-z][a-z0-9]*$")) | all | not) then
          fail($p + ".ubuntu_series 必须是安全 Ubuntu 代号")
        else . end) as $_s
  | (.architectures | need_string_list($p + ".architectures")) as $_arch
  | (.apt_source_uri | need_apt_source_uri($p + ".apt_source_uri"; $id)) as $_asu
  | if (.assets | type) != "array" then fail($p + ".assets 必须是数组") else . end
  | (.assets | to_entries | map(. as $e | $e.value | need_asset($p + ".assets[" + ($e.key | tostring) + "]"))) as $_assets
  | .;
if type != "object" then fail("state 必须是对象") else . end
| if .schema_version != "2" then fail("schema_version 必须为字符串 2") else . end
| if (.packages | type) != "array" then fail("packages 必须是数组") else . end
| if ((.packages | map(select(type == "object") | .id) | unique | length)
      != (.packages | map(select(type == "object") | .id) | length)) then
    fail("packages.id 不能重复")
  else . end
| (.packages | to_entries | map(. as $e | $e.value | need_package($e.key))) as $_pkgs
| true
'

# shellcheck disable=SC2016 # jq 程序字面量，故意单引号不插值
site_cmd_jq='
def site:
  . as $p
  | ($p.apt_source_uri | sub("^mirror\\+"; "") | rtrimstr("/repos/" + $p.id + "/mirror.list"));
if (.packages | length) == 0 then ""
else
  ([.packages[] | site] | unique) as $roots
  | if ($roots | length) != 1 then error("混站根，拒绝渲染")
    elif ($roots[0] | startswith("https://") | not) then ""
    else
      "curl -fsSL --proto '\''=https'\'' --proto-redir '\''=https'\'' -o add_source.sh '\''"
      + $roots[0] + "/add_source.sh'\'' && chmod a+x ./add_source.sh && sudo ./add_source.sh --site-url '\''"
      + $roots[0] + "'\''"
    end
end
'

# shellcheck disable=SC2016 # jq 程序字面量，故意单引号不插值
md_jq='
def md_cell:
  tostring
  | gsub("\r"; "")
  | gsub("\n"; " ")
  | gsub("&"; "&amp;")
  | gsub("<"; "&lt;")
  | gsub(">"; "&gt;")
  | gsub("\""; "&quot;")
  | gsub("'\''"; "&#39;")
  | gsub("\\\\"; "\\\\")
  | gsub("\\|"; "\\|")
  | gsub("\\["; "\\[")
  | gsub("\\]"; "\\]")
  | gsub("`"; "\\`")
  | gsub("\\*"; "\\*")
  | gsub("_"; "\\_");
def support:
  (.ubuntu_series | join(", ")) + " · " + (.architectures | join(", "));
if (.packages | length) == 0 then empty
else
  .packages[]
  | "| [\(.package | md_cell)](\(.release_url)) | \(.version | md_cell) | \(support | md_cell) | \(.description | md_cell) |"
end
'

# shellcheck disable=SC2016 # jq 程序字面量，故意单引号不插值
site_base_jq='
def site:
  . as $p
  | ($p.apt_source_uri | sub("^mirror\\+"; "") | rtrimstr("/repos/" + $p.id + "/mirror.list"));
if (.packages | length) == 0 then ""
else
  ([.packages[] | site] | unique) as $roots
  | if ($roots | length) != 1 then error("混站根，拒绝渲染")
    elif ($roots[0] | startswith("https://") | not) then ""
    else $roots[0]
    end
end
'

# shellcheck disable=SC2016 # jq 程序字面量，故意单引号不插值
html_jq='
def html_escape:
  tostring
  | gsub("&"; "&amp;")
  | gsub("<"; "&lt;")
  | gsub(">"; "&gt;")
  | gsub("\""; "&quot;")
  | gsub("'\''"; "&#39;");
def support:
  (.ubuntu_series | join(", ")) + " · " + (.architectures | join(", "));
def row:
  "<tr><td><a href=\"\(.release_url | html_escape)\">\(.package | html_escape)</a></td><td>\(.version | html_escape)</td><td>\(support | html_escape)</td><td>\(.description | html_escape)</td></tr>";
def legacy:
  if (.packages | length) == 0 then
    "<p>" + ($empty | sub("\n+$";"") | html_escape) + "</p>"
  else
    (
      (if $cmd != "" then
        ["<a id=\"apt-hub-add-source\"></a>", "<pre><code>" + ($cmd | html_escape) + "</code></pre>"]
      else [] end)
      + [
        "<table>",
        "<thead><tr><th>软件</th><th>版本</th><th>支持环境</th><th>说明</th></tr></thead>",
        "<tbody>"
      ]
      + [.packages[] | row]
      + ["</tbody>", "</table>"]
    ) | join("\n")
  end;
def gh($suffix): "https://github.com/" + $repo + $suffix;
def pkgs: [.packages[].package] | join(" ");
def versioned:
  (
    ["<h2>维护版本</h2>",
      "<p>站点版本 <a href=\"" + (gh("/releases/tag/" + $tag) | html_escape) + "\">" + ($tag | html_escape) + "</a>，不是下表软件版本。"
      + (if $base != "" then " 固定站点根 <code>" + ($base | html_escape) + "</code>。" else "" end)
      + " <a href=\"" + (gh("/releases/latest") | html_escape) + "\">最新发行版</a>"
      + " <a href=\"" + (gh("/blob/" + $tag + "/changelog/" + $tag + ".md") | html_escape) + "\">变更记录</a>"
      + " <a href=\"" + (gh("") | html_escape) + "\">源码</a></p>"]
    + (if $cmd != "" then
        ["<h2>一键加源</h2>",
          "<p>成功后脚本自删，不安装软件。</p>",
          "<a id=\"apt-hub-add-source\"></a>",
          "<pre><code>" + ($cmd | html_escape) + "</code></pre>",
          "<h2>安装</h2>",
          "<pre><code>" + (("sudo apt update && sudo apt install " + pkgs) | html_escape) + "</code></pre>",
          "<h2>更新</h2>",
          "<pre><code>" + ("sudo apt update && sudo apt upgrade" | html_escape) + "</code></pre>"]
      else [] end)
    + (if (.packages | length) == 0 then
        ["<p>" + ($empty | sub("\n+$";"") | html_escape) + "</p>"]
      else
        ["<div class=\"table-scroll\">",
          "<table>",
          "<thead><tr><th>软件</th><th>版本</th><th>支持环境</th><th>说明</th></tr></thead>",
          "<tbody>"]
        + [.packages[] | row]
        + ["</tbody>", "</table>", "</div>"]
      end)
    + ["<p>官方 deb 从官方获取；Go 转换包从本仓 Release 获取。</p>"]
  ) | join("\n");
if $repo == "" then legacy else versioned end
'

marker_lines() {
  local file="$1" mark="$2"
  grep -n -x -F -- "$mark" "$file" | cut -d: -f1 || true
}

mapfile -t begin_lines < <(marker_lines "$readme" "$BEGIN_MARK")
mapfile -t end_lines < <(marker_lines "$readme" "$END_MARK")
if [[ ${#begin_lines[@]} -ne 1 ]]; then
  die "README 标记 BEGIN 必须独占一行且恰好出现一次"
fi
if [[ ${#end_lines[@]} -ne 1 ]]; then
  die "README 标记 END 必须独占一行且恰好出现一次"
fi
begin_line=${begin_lines[0]}
end_line=${end_lines[0]}
if [[ "$end_line" -le "$begin_line" ]]; then
  die "README 标记必须 BEGIN 在 END 之前"
fi

if ! jq -e "$validate_jq" "$state" >/dev/null; then
  die "state.json 校验失败"
fi
if ! repo_cmd=$(jq -r "$site_cmd_jq" "$state"); then
  die "混站根，拒绝渲染"
fi
repo_base=""
if [[ -n "$repository_arg" ]]; then
  if ! jq -e '[.packages[].package | test("^[a-z0-9][a-z0-9+.-]+$")] | all' "$state" >/dev/null; then
    die "package 不是 Debian 包名"
  fi
  if ! repo_base=$(jq -r "$site_base_jq" "$state"); then
    die "混站根，拒绝渲染"
  fi
fi

work=""
tmp_html=""
tmp_readme=""
html_bak=""
cleanup() {
  [[ -n "${work:-}" && -d "$work" ]] && rm -rf -- "$work"
}
trap cleanup EXIT

work="$site/.apt-hub-render.$$"
mkdir -m 700 -- "$work"
tmp_html="$work/index.html"
tmp_readme="$work/README.md"
section_md="$work/section.md"
rows_md="$work/rows.md"
body_html="$work/body.html"

jq -r "$md_jq" "$state" >"$rows_md"
jq -r --rawfile empty "$readme_empty" --arg cmd "$repo_cmd" --arg repo "$repository_arg" --arg tag "$release_tag_arg" --arg base "$repo_base" "$html_jq" "$state" >"$body_html"

if [[ ! -s "$rows_md" ]]; then
  cat -- "$readme_empty" >"$section_md"
else
  {
    if [[ -n "$repo_cmd" ]]; then
      # shellcheck disable=SC2016 # Markdown 围栏字面量反引号
      printf '<a id="apt-hub-add-source"></a>\n\n```bash\n%s\n```\n\n' "$repo_cmd"
    fi
    cat -- "$readme_header"
    cat -- "$rows_md"
  } >"$section_md"
  if [[ $(tail -c 1 "$section_md" | wc -l) -eq 0 ]]; then
    printf '\n' >>"$section_md"
  fi
fi
[[ -s "$section_md" ]] || die "README 列表渲染结果为空"
if grep -F -q -- "$BEGIN_MARK" "$section_md" || grep -F -q -- "$END_MARK" "$section_md"; then
  die "渲染结果含 README 标记，拒绝写入"
fi
if grep -F -q -- "$HTML_PLACEHOLDER" "$body_html"; then
  die "HTML 正文含模板占位符，拒绝写入"
fi

if ! jq -n -r --rawfile tmpl "$html_template" --rawfile body "$body_html" --arg ph "$HTML_PLACEHOLDER" '
  ($tmpl | split($ph)) as $p
  | if ($p | length) != 2 then error("HTML 模板占位符必须恰好出现一次") else $p[0] + $body + $p[1] end
' >"$tmp_html"; then
  die "HTML 模板渲染失败"
fi
[[ -s "$tmp_html" ]] || die "HTML 渲染结果为空"
if grep -F -q -- "<script" "$tmp_html"; then
  die "HTML 含 script，拒绝写入"
fi

{
  head -n "$begin_line" -- "$readme"
  cat -- "$section_md"
  tail -n "+$end_line" -- "$readme"
} >"$tmp_readme"
[[ -s "$tmp_readme" ]] || die "README 拼接结果为空"

mapfile -t begin_chk < <(marker_lines "$tmp_readme" "$BEGIN_MARK")
mapfile -t end_chk < <(marker_lines "$tmp_readme" "$END_MARK")
if [[ ${#begin_chk[@]} -ne 1 || ${#end_chk[@]} -ne 1 || "${end_chk[0]}" -le "${begin_chk[0]}" ]]; then
  die "README 拼接后标记无效"
fi

html_bak="$work/index.html.bak"
wrote_html=0
if [[ -f "$html_dst" ]]; then
  cp -f -- "$html_dst" "$html_bak"
fi
if ! mv -f -- "$tmp_html" "$html_dst"; then
  die "写入 site/index.html 失败"
fi
wrote_html=1
tmp_html=""
if ! mv -f -- "$tmp_readme" "$readme"; then
  if [[ -f "$html_bak" ]]; then
    mv -f -- "$html_bak" "$html_dst"
  elif [[ "$wrote_html" -eq 1 ]]; then
    rm -f -- "$html_dst"
  fi
  die "写入 README 失败，已还原页面"
fi
tmp_readme=""
rm -rf -- "$work"
work=""
trap - EXIT
