#!/usr/bin/env bash
# 在隔离 APT 根下，用 Ubuntu 官方签名源 + 每软件 repos 元数据（mirror+file 覆盖 type:index）做精确版本依赖解析。
# 不修改候选 mirror.list/签名；不安装包；不写系统 apt/dpkg；网络失败不记成依赖不兼容。
set -euo pipefail
export LC_ALL=C
export LANG=C
export LANGUAGE=C

usage() {
  echo "用法: scripts/verify_ubuntu.sh --site <候选站点> --releases <releases.json> --work-dir <证据目录> [--verify-downloads] [--acquire-https-ca <pem>] [--github-https-proxy <http://host:port>]" >&2
  exit 2
}

die() {
  echo "verify_ubuntu: $*" >&2
  exit 1
}

UBUNTU_KEYRING='/usr/share/keyrings/ubuntu-archive-keyring.gpg'
AMD64_ARCHIVE='https://archive.ubuntu.com/ubuntu'
AMD64_SECURITY='https://security.ubuntu.com/ubuntu'
ARM64_PORTS='https://ports.ubuntu.com/ubuntu-ports'
COMPONENTS='main restricted universe multiverse'
UPDATE_TIMEOUT=300
SIMULATE_TIMEOUT=120
DOWNLOAD_TIMEOUT=600

site_arg=""
releases_arg=""
work_arg=""
verify_downloads=0
acquire_https_ca=""
github_https_proxy=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site)
      [[ $# -ge 2 ]] || usage
      site_arg="$2"
      shift 2
      ;;
    --releases)
      [[ $# -ge 2 ]] || usage
      releases_arg="$2"
      shift 2
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || usage
      work_arg="$2"
      shift 2
      ;;
    --verify-downloads)
      verify_downloads=1
      shift
      ;;
    --acquire-https-ca)
      [[ $# -ge 2 ]] || usage
      acquire_https_ca="$2"
      shift 2
      ;;
    --github-https-proxy)
      [[ $# -ge 2 ]] || usage
      github_https_proxy="$2"
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

[[ -n "$site_arg" && -n "$releases_arg" && -n "$work_arg" ]] || usage
command -v jq >/dev/null 2>&1 || die "需要 jq"
command -v apt-get >/dev/null 2>&1 || die "需要 apt-get"
command -v timeout >/dev/null 2>&1 || die "需要 timeout"
command -v gpg >/dev/null 2>&1 || die "需要 gpg"
command -v flock >/dev/null 2>&1 || die "需要 flock"
command -v find >/dev/null 2>&1 || die "需要 find"
if [[ "$verify_downloads" -eq 1 ]]; then
  command -v dpkg-deb >/dev/null 2>&1 || die "需要 dpkg-deb"
  command -v sha256sum >/dev/null 2>&1 || die "需要 sha256sum"
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "$script_dir/.." && pwd)
tmp_root=$(realpath -m -- "$root_dir/tmp")
[[ -d "$tmp_root" ]] || die "缺少项目 tmp/ 目录"

make_abs_unresolved() {
  local p="$1"
  [[ -n "$p" ]] || die "空路径"
  if [[ "$p" != /* ]]; then
    p="$root_dir/${p#./}"
  fi
  if [[ "$p" != / ]]; then
    p="${p%/}"
  fi
  printf '%s\n' "$p"
}

assert_no_symlink_components() {
  local path="$1"
  local prefix="" part
  [[ "$path" == /* ]] || die "路径必须是绝对路径: $path"
  prefix="/"
  IFS=/ read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    prefix="${prefix%/}/$part"
    if [[ -L "$prefix" ]]; then
      die "路径含符号链接: $prefix"
    fi
  done
}

under_dir() {
  local parent="$1" child="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

assert_no_overlap() {
  local a="$1" b="$2" msg="$3"
  if under_dir "$a" "$b" || under_dir "$b" "$a"; then
    die "$msg"
  fi
}

dir_is_empty() {
  local d="$1" listing="" rc=0
  [[ -d "$d" ]] || return 0
  # 显式捕获 find 成功与输出；失败不得当空目录。
  listing="$(find -- "$d" -mindepth 1 -maxdepth 1 -print -quit)" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  [[ -z "$listing" ]]
}

assert_under_tmp() {
  local label="$1" real="$2"
  case "$real" in
    "$tmp_root"/*) ;;
    *) die "$label 必须位于项目 tmp/ 内" ;;
  esac
  [[ "$real" != "$tmp_root" ]] || die "$label 不能是 tmp/ 本身"
}

resolve_existing_dir() {
  local label="$1" raw="$2"
  local abs
  abs=$(make_abs_unresolved "$raw")
  [[ -e "$abs" ]] || die "$label 不存在: $abs"
  [[ -d "$abs" ]] || die "$label 不是目录: $abs"
  [[ ! -L "$abs" ]] || die "$label 不能是符号链接: $abs"
  assert_no_symlink_components "$abs"
  abs=$(realpath -e -- "$abs")
  assert_under_tmp "$label" "$abs"
  printf '%s\n' "$abs"
}

resolve_existing_file() {
  local label="$1" raw="$2"
  local abs
  abs=$(make_abs_unresolved "$raw")
  [[ -e "$abs" ]] || die "$label 不存在: $abs"
  [[ -f "$abs" ]] || die "$label 不是文件: $abs"
  [[ ! -L "$abs" ]] || die "$label 不能是符号链接: $abs"
  assert_no_symlink_components "$abs"
  abs=$(realpath -e -- "$abs")
  assert_under_tmp "$label" "$abs"
  printf '%s\n' "$abs"
}

resolve_work_dir() {
  local raw="$1"
  local abs parent base parent_abs
  abs=$(make_abs_unresolved "$raw")
  parent=$(dirname -- "$abs")
  base=$(basename -- "$abs")
  [[ "$base" != "." && "$base" != ".." && "$base" != "/" ]] || die "work-dir 非法目录名"
  [[ -e "$parent" ]] || die "work-dir 父目录不存在: $parent"
  [[ -d "$parent" ]] || die "work-dir 父目录不是目录: $parent"
  [[ ! -L "$parent" ]] || die "work-dir 父目录不能是符号链接: $parent"
  assert_no_symlink_components "$parent"
  if [[ -L "$abs" ]]; then
    die "拒绝符号链接: --work-dir"
  fi
  if [[ -e "$abs" ]]; then
    [[ -d "$abs" ]] || die "work-dir 存在但不是目录"
    assert_no_symlink_components "$abs"
  fi
  parent_abs=$(realpath -e -- "$parent")
  abs="${parent_abs}/${base}"
  assert_under_tmp --work-dir "$abs"
  printf '%s\n' "$abs"
}

[[ -e /usr/share/keyrings/ubuntu-archive-keyring.gpg ]] || die "缺少 Ubuntu 官方 keyring: $UBUNTU_KEYRING"
[[ -f "$UBUNTU_KEYRING" && -s "$UBUNTU_KEYRING" ]] || die "Ubuntu 官方 keyring 不可读: $UBUNTU_KEYRING"
[[ ! -L "$UBUNTU_KEYRING" ]] || die "Ubuntu 官方 keyring 不能是符号链接"

site=$(resolve_existing_dir --site "$site_arg")
releases=$(resolve_existing_file --releases "$releases_arg")
work=$(resolve_work_dir "$work_arg")
if [[ -n "$acquire_https_ca" ]]; then
  acquire_https_ca=$(resolve_existing_file --acquire-https-ca "$acquire_https_ca")
fi
if [[ -n "$github_https_proxy" ]]; then
  [[ "$github_https_proxy" =~ ^https?://[^[:space:]]+$ ]] \
    || die "github-https-proxy 非法: $github_https_proxy"
fi
assert_no_overlap "$site" "$work" "site 与 work-dir 重叠"
assert_no_overlap "$work" "$releases" "work-dir 与 releases 重叠"
assert_no_overlap "$site" "$releases" "site 与 releases 重叠"

lockfile="${work}.lock"
lockdir=$(dirname -- "$lockfile")
[[ -d "$lockdir" ]] || die "work-dir 父目录不存在"
assert_no_symlink_components "$lockdir"
if [[ -L "$lockfile" ]]; then
  die "lock 不能是符号链接: $lockfile"
fi
if [[ -e "$lockfile" ]]; then
  [[ -f "$lockfile" ]] || die "lock 不是普通文件: $lockfile"
  assert_no_symlink_components "$lockfile"
fi
exec 9>>"$lockfile" || die "无法打开 lock: $lockfile"
if [[ -L "$lockfile" ]]; then
  die "lock 不能是符号链接: $lockfile"
fi
[[ -f "$lockfile" ]] || die "lock 不是普通文件: $lockfile"
[[ "$(stat -L -c '%d:%i' /proc/self/fd/9)" == "$(stat -c '%d:%i' "$lockfile")" ]] \
  || die "lock 句柄与路径不一致"
flock -n 9 || die "验证已在进行: $lockfile"

if [[ -e "$work" ]]; then
  [[ -d "$work" ]] || die "work-dir 存在但不是目录"
  [[ ! -L "$work" ]] || die "拒绝符号链接: --work-dir"
  dir_is_empty "$work" || die "拒绝已有非空或不可访问 work-dir: $work"
else
  mkdir -- "$work"
fi
dir_is_empty "$work" || die "拒绝已有非空或不可访问 work-dir: $work"
printf 'pid=%s\nstarted=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$work/.apt-hub-verify.owned"

state="$site/state.json"
keyring="$site/apt-hub.gpg"
repos_root="$site/repos"
[[ -f "$state" && ! -L "$state" ]] || die "缺少站点 state.json"
[[ -f "$keyring" && ! -L "$keyring" && -s "$keyring" ]] || die "缺少站点 apt-hub.gpg"
[[ -d "$repos_root" && ! -L "$repos_root" ]] || die "缺少站点 repos/ 目录"
if find "$site" -type l -print -quit | grep -q .; then
  die "站点含符号链接，拒绝验证"
fi
if find "$site" -name '*.deb' -print -quit | grep -q .; then
  die "候选站点含 .deb，拒绝验证"
fi

# shellcheck disable=SC2016
jq -e '(.schema_version==1 or .schema_version=="1") and (.releases|type=="array" and length>0)
  and all(.releases[]; .series and .version and .release_date and .eol_date)' \
  "$releases" >/dev/null || die "releases.json 结构无效"
# shellcheck disable=SC2016
jq -e '.schema_version=="2" and (.packages|type=="array")' "$state" >/dev/null \
  || die "state.json 须为 schema_version 字符串 \"2\""

today=$(date -u +%Y-%m-%d)
checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
supported_json=$(jq -c --arg today "$today" '
  [.releases[] | select(.release_date <= $today and .eol_date > $today) | .series]
' "$releases")
supported_count=$(jq 'length' <<<"$supported_json")
[[ "$supported_count" -gt 0 ]] || die "releases.json 无当前标准支持版本"

write_json() {
  local dest="$1"
  shift
  jq -n "$@" >"$dest"
}

classify_update() {
  local log="$1"
  if grep -Eqi 'NO_PUBKEY|EXPKEYSIG|REVKEYSIG|BADSIG|ERRSIG|NODATA|GPG error|The following signatures (were invalid|could not be verified)|not signed|Unsigned repository|Clearsigned file|invalid signature|NO_PUBKEY' "$log"; then
    printf '%s\n' signature
    return
  fi
  if grep -Eqi 'Failed to fetch|Undetermined Error|Connection failed|Connection timed out|Temporary failure resolving|Could not resolve|Network is unreachable|404[[:space:]]+Not Found| 500 | 502 | 503 |SSL|certificate|Timeout|Hash Sum mismatch|File has unexpected size|Failed to connect|Unable to connect|Connection refused|does not have a Release file|Release file|Some index files failed' "$log"; then
    printf '%s\n' network
    return
  fi
  printf '%s\n' config
}

classify_install() {
  local log="$1"
  if grep -Eqi 'Failed to fetch|Temporary failure resolving|Could not resolve|Network is unreachable|Timeout|Unable to connect|Connection refused|404[[:space:]]+Not Found' "$log"; then
    printf '%s\n' network
    return
  fi
  if grep -Eqi 'NO_PUBKEY|GPG error|not signed|Unsigned repository' "$log"; then
    printf '%s\n' signature
    return
  fi
  if grep -Eqi 'Unable to locate package|has no installation candidate|Version .* was not found|unmet dependencies|Depends:|Breaks:|Conflicts:|held broken packages|unsatisfiable|but it is not (installable|going to be installed)' "$log"; then
    printf '%s\n' dependency
    return
  fi
  printf '%s\n' config
}

write_dpkg_wrapper() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/bin/sh
real=/usr/bin/dpkg
arch=${APT_HUB_VERIFY_ARCH:-}
root=${APT_HUB_VERIFY_DPKG_ROOT:-}
for a in "$@"; do
  case "$a" in
    --print-architecture)
      [ -n "$arch" ] || exit 1
      printf '%s\n' "$arch"
      exit 0
      ;;
    --print-foreign-architectures)
      exit 0
      ;;
    --print-os)
      printf '%s\n' linux
      exit 0
      ;;
  esac
done
case "${1:-}" in
  --assert-*|--version|--help)
    exec "$real" "$@"
    ;;
  --compare-versions)
    exec "$real" "$@"
    ;;
  --install|-i|--unpack|--configure|--remove|-r|--purge|-P|--triggers-only|--update-avail|--merge-avail|--add-architecture|--remove-architecture|--set-selections)
    echo "verify_ubuntu: 拒绝 dpkg 安装/变更: $*" >&2
    exit 1
    ;;
esac
if [ -z "$root" ]; then
  echo "verify_ubuntu: 缺少隔离 dpkg 根" >&2
  exit 1
fi
exec "$real" --admindir="$root/var/lib/dpkg" "$@"
EOF
  chmod 0755 "$dest"
}

prepare_root() {
  local root="$1"
  mkdir -p -- \
    "$root/etc/apt/apt.conf.d" \
    "$root/etc/apt/sources.list.d" \
    "$root/etc/apt/preferences.d" \
    "$root/etc/apt/trusted.gpg.d" \
    "$root/etc/apt/keyrings" \
    "$root/var/lib/apt/lists/partial" \
    "$root/var/lib/apt/periodic" \
    "$root/var/cache/apt/archives/partial" \
    "$root/var/lib/dpkg/info" \
    "$root/var/lib/dpkg/updates" \
    "$root/var/lib/dpkg/triggers" \
    "$root/var/log/apt"
  : >"$root/var/lib/dpkg/status"
  : >"$root/var/lib/apt/extended_states"
  : >"$root/var/lib/dpkg/available"
  : >"$root/etc/apt/preferences"
  : >"$root/etc/apt/trusted.gpg"
}

write_ubuntu_sources() {
  local dest="$1" series="$2" arch="$3"
  local archive security
  if [[ "$arch" == "amd64" ]]; then
    archive="$AMD64_ARCHIVE"
    security="$AMD64_SECURITY"
  elif [[ "$arch" == "arm64" ]]; then
    archive="$ARM64_PORTS"
    security="$ARM64_PORTS"
  else
    die "不支持的架构: $arch"
  fi
  cat >"$dest" <<EOF
deb [arch=${arch} signed-by=${UBUNTU_KEYRING}] ${archive} ${series} ${COMPONENTS}
deb [arch=${arch} signed-by=${UBUNTU_KEYRING}] ${archive} ${series}-updates ${COMPONENTS}
deb [arch=${arch} signed-by=${UBUNTU_KEYRING}] ${security} ${series}-security ${COMPONENTS}
EOF
}

# 从候选 mirror.list 抽出 type:deb 行（TAB 分隔），不改候选文件。
extract_deb_mirror_lines() {
  local mirror_list="$1"
  local out="$2"
  : >"$out"
  local line uri meta
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue
    uri=${line%%$'\t'*}
    meta=${line#*$'\t'}
    if [[ "$uri" == "$line" ]]; then
      die "mirror.list 缺少 TAB 分隔: $mirror_list"
    fi
    if [[ "$meta" == *type:deb* ]]; then
      printf '%s\t%s\n' "$uri" "$meta" >>"$out"
    fi
  done <"$mirror_list"
  [[ -s "$out" ]] || die "mirror.list 无 type:deb 行: $mirror_list"
}

write_work_mirror_list() {
  local repo_abs="$1" candidate_mirror="$2" dest="$3"
  local deb_tmp
  deb_tmp=$(mktemp -- "$tmp_root/ubuntu-verify-deb-lines.XXXXXX")
  extract_deb_mirror_lines "$candidate_mirror" "$deb_tmp"
  {
    # type:index → 本地 repos（验签）；type:deb 原样保留候选原点（不改成 file:）。
    printf 'file:%s/\tpriority:1 type:index\n' "$repo_abs"
    cat "$deb_tmp"
  } >"$dest"
  rm -f -- "$deb_tmp"
  [[ -s "$dest" ]] || die "生成 work mirror.list 失败"
}

write_apt_conf() {
  local dest="$1" root="$2" arch="$3" wrapper="$4" user="$5"
  local ca_lines="" proxy_lines=""
  # 按 host 注入测试 CA，避免全局 CaInfo 覆盖系统信任导致 Ubuntu 官方源失败。
  if [[ -n "$acquire_https_ca" ]]; then
    ca_lines="Acquire::https::github.com::CaInfo \"${acquire_https_ca}\";
Acquire::https::127.0.0.2::CaInfo \"${acquire_https_ca}\";"
  fi
  if [[ -n "$github_https_proxy" ]]; then
    proxy_lines="Acquire::https::Proxy::github.com \"${github_https_proxy}\";
Acquire::https::Proxy::127.0.0.2 \"DIRECT\";"
  fi
  cat >"$dest" <<EOF
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
Dir::Bin::dpkg "${wrapper}";
Dir::Log "${root}/var/log/apt";
Dir::Log::Terminal "${root}/var/log/apt/term.log";
APT::Architecture "${arch}";
APT::Architectures "${arch}";
APT::Get::AllowUnauthenticated "false";
APT::Get::Install-Recommends "false";
APT::Get::Install-Suggests "false";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::AllowInsecureRepositories "false";
Acquire::AllowDowngradeToInsecureRepositories "false";
Acquire::Retries "2";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::https::Verify-Peer "true";
Acquire::https::Verify-Host "true";
${ca_lines}
${proxy_lines}
Acquire::Languages "none";
APT::Update::Error-Mode "any";
APT::Sandbox::User "${user}";
DPkg::Pre-Invoke {"true";};
DPkg::Post-Invoke {"true";};
APT::Update::Pre-Invoke {"true";};
APT::Update::Post-Invoke-Success {"true";};
EOF
}

combo_tmp=$(mktemp -- "$tmp_root/ubuntu-verify-combos.XXXXXX")
trap 'rm -f -- "$combo_tmp"' EXIT

# shellcheck disable=SC2016
# 按 asset.package×arch 展开；缺 package 时回落 row.package（普通官方 deb 兼容）。
if ! jq -c --argjson supported "$supported_json" '
  .packages as $pkgs
  | ([$pkgs[].ubuntu_series[]] | unique) as $declared_series
  | ($declared_series - $supported) as $bad
  | if ($bad | length) > 0 then
      error("state 含非当前标准支持 series: " + ($bad | join(",")))
    else
      [
        $pkgs[]
        | . as $p
        | ($p.id // empty) as $id
        | ($p.package // empty) as $row_pkg
        | ($p.version // empty) as $ver
        | if ($id == "" or $row_pkg == "" or $ver == "") then
            error("state 缺 id/package/version")
          else . end
        | if ($p.ubuntu_series | type) != "array" or ($p.architectures | type) != "array" then
            error("state ubuntu_series/architectures 必须是数组")
          else . end
        | .ubuntu_series[] as $s
        | .architectures[] as $a
        | (($p.assets // []) | map(select(.architecture==$a))) as $aa
        | if ($aa | length) == 0 then
            error("package " + $row_pkg + " 声明了 " + $a + " 但没有对应 asset")
          else
            $aa[]
            | (.package // $row_pkg) as $bin
            | (.sha256 // empty) as $sha
            | ((.size|tostring) // empty) as $sz
            | (.filename // empty) as $fn
            | if ($bin == "" or $sha == "" or $sz == "" or $fn == "") then
                error("asset 缺 package/sha256/size/filename: " + $id + "/" + $a)
              else
                {series:$s, architecture:$a, package:$bin, version:$ver, id:$id,
                 sha256:$sha, size:$sz, filename:$fn}
              end
          end
      ]
    end
' "$state" >"$combo_tmp"; then
  die "state/releases 组合无效"
fi

if jq -e 'length==0' "$combo_tmp" >/dev/null; then
  if [[ "$(jq '.packages|length' "$state")" -eq 0 ]]; then
    summary="$work/summary.json"
    # shellcheck disable=SC2016
    write_json "$summary" \
      --argjson schema_version 1 --arg checked_at "$checked_at" \
      --argjson ok true --argjson results '[]' \
      '{schema_version:$schema_version,checked_at:$checked_at,ok:$ok,results:$results}'
    echo "verify_ubuntu: 证据 $summary ok=true (无软件)"
    exit 0
  fi
  die "state 没有可验证的 suite×arch 组合"
fi

# 校验每个 id 的 repos 布局与候选 mirror.list，并记录候选 mirror 哈希（事后对照未改）。
mirror_hashes="$work/candidate-mirror.sha256"
: >"$mirror_hashes"
pkg_ids_file=$(mktemp -- "$tmp_root/ubuntu-verify-pkg-ids.XXXXXX")
jq -r '[.[].id] | unique[]' "$combo_tmp" >"$pkg_ids_file" || die "枚举 package id 失败"
mapfile -t pkg_ids <"$pkg_ids_file" || die "读取 package id 失败"
rm -f -- "$pkg_ids_file"
for pkg_id in "${pkg_ids[@]}"; do
  # 与 sync validate_catalog 同一安全路径字符集；额外拒 ..（字符集允许点）。
  [[ "$pkg_id" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$pkg_id" != *..* ]] \
    || die "非法 package id: $pkg_id"
  repo_dir="$repos_root/$pkg_id"
  [[ -d "$repo_dir" && ! -L "$repo_dir" ]] || die "缺少 repos/$pkg_id"
  candidate_mirror="$repo_dir/mirror.list"
  [[ -f "$candidate_mirror" && ! -L "$candidate_mirror" && -s "$candidate_mirror" ]] \
    || die "缺少 repos/$pkg_id/mirror.list"
  while IFS= read -r fn; do
    [[ -n "$fn" ]] || continue
    case "$fn" in
      pool/*|http://*|https://*|/*)
        die "repos/$pkg_id asset.filename 非法（禁止 pool/绝对URL）: $fn"
        ;;
    esac
  done < <(jq -r --arg id "$pkg_id" '
    .packages[] | select(.id==$id) | .assets[]?.filename // empty
  ' "$state")
  sha256sum -- "$candidate_mirror" >>"$mirror_hashes"
done

results_json='[]'
overall_ok=true
sandbox_user=$(id -un)
site_key_copy="$work/apt-hub.gpg"
dearmor_home="$work/gpg-dearmor"
mkdir -p -- "$dearmor_home"
chmod 700 "$dearmor_home"
if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$keyring"; then
  GNUPGHOME="$dearmor_home" gpg --batch --yes --dearmor <"$keyring" >"$site_key_copy"
else
  cp -f -- "$keyring" "$site_key_copy"
fi
rm -rf -- "$dearmor_home"
chmod 0644 "$site_key_copy"
[[ -s "$site_key_copy" ]] || die "站点 keyring 去装甲后为空"

groups_file=$(mktemp -- "$tmp_root/ubuntu-verify-groups.XXXXXX")
jq -r '[.[] | .series + " " + .architecture] | unique[]' "$combo_tmp" >"$groups_file" \
  || die "枚举 suite×arch 失败"
mapfile -t groups <"$groups_file" || die "读取 suite×arch 失败"
rm -f -- "$groups_file"
for group in "${groups[@]}"; do
  series=${group%% *}
  arch=${group##* }
  slot="$work/${series}-${arch}"
  root="$slot/apt-root"
  mkdir -p -- "$slot/bin" "$root" "$root/etc/apt/sources.list.d"
  wrapper="$slot/bin/dpkg"
  write_dpkg_wrapper "$wrapper"
  prepare_root "$root"
  write_ubuntu_sources "$root/etc/apt/sources.list" "$series" "$arch"
  write_apt_conf "$root/etc/apt/apt.conf" "$root" "$arch" "$wrapper" "$sandbox_user"

  result_file="$slot/result.json"
  update_log="$slot/update.log"
  simulate_log="$slot/simulate.log"
  download_log="$slot/download.log"
  upgrade_log="$slot/upgrade.log"
  : >"$update_log"
  : >"$simulate_log"
  : >"$download_log"
  : >"$upgrade_log"
  failure_class=""
  error_msg=""
  ok=true
  update_rc=0
  simulate_rc=0
  download_rc=0
  upgrade_rc=0

  # type:index→本地 repos；type:deb 保留候选原点（不物化为 file:）。
  slot_ids_file=$(mktemp -- "$tmp_root/ubuntu-verify-slot-ids.XXXXXX")
  jq -r --arg s "$series" --arg a "$arch" \
    '[.[] | select(.series==$s and .architecture==$a) | .id] | unique[]' "$combo_tmp" \
    >"$slot_ids_file" || die "枚举 suite 软件 id 失败: $series/$arch"
  mapfile -t slot_ids <"$slot_ids_file" || die "读取 suite 软件 id 失败: $series/$arch"
  rm -f -- "$slot_ids_file"

  for pkg_id in "${slot_ids[@]}"; do
    repo_abs=$(realpath -e -- "$repos_root/$pkg_id")
    candidate_mirror="$repos_root/$pkg_id/mirror.list"
    work_mirror="$slot/${pkg_id}.mirror.list"
    write_work_mirror_list "$repo_abs" "$candidate_mirror" "$work_mirror"
    dist_dir="$repo_abs/dists/$series"
    [[ -f "$dist_dir/InRelease" || -f "$dist_dir/Release" ]] \
      || die "repos/$pkg_id 缺少 dists/$series 签名元数据"
    printf 'deb [arch=%s signed-by=%s] mirror+file:%s %s main\n' \
      "$arch" "$site_key_copy" "$work_mirror" "$series" \
      >"$root/etc/apt/sources.list.d/apt-hub-${pkg_id}.list"
  done

  pkgs_file="$slot/packages.txt"
  jq -r --arg s "$series" --arg a "$arch" '
    [.[] | select(.series==$s and .architecture==$a) | .package + "=" + .version]
    | unique[]
  ' "$combo_tmp" >"$pkgs_file" || die "枚举 package=version 失败: $series/$arch"
  mapfile -t pkg_specs < "$pkgs_file" || die "读取 package=version 失败: $series/$arch"
  [[ ${#pkg_specs[@]} -gt 0 ]] || die "内部错误: 空组合 $series $arch"

  export APT_HUB_VERIFY_ARCH="$arch"
  export APT_HUB_VERIFY_DPKG_ROOT="$root"
  export APT_CONFIG="$root/etc/apt/apt.conf"

  if [[ "$ok" == true ]]; then
    set +e
    timeout --signal=TERM --kill-after=10 "$UPDATE_TIMEOUT" \
      env LC_ALL=C LANG=C LANGUAGE=C apt-get \
      -c "$root/etc/apt/apt.conf" \
      -o Debug::NoLocking=true \
      update >"$update_log" 2>&1
    update_rc=$?
    set -e

    if [[ "$update_rc" -eq 0 ]] && grep -Eqi 'Failed to fetch|Some index files failed' "$update_log"; then
      update_rc=1
    fi
    if [[ "$update_rc" -ne 0 ]]; then
      ok=false
      if [[ "$update_rc" -eq 124 || "$update_rc" -eq 137 ]]; then
        failure_class=network
        error_msg="apt-get update 超时 exit=$update_rc"
      else
        failure_class=$(classify_update "$update_log")
        error_msg="apt-get update 失败 exit=$update_rc class=$failure_class"
      fi
    else
      set +e
      timeout --signal=TERM --kill-after=10 "$SIMULATE_TIMEOUT" \
        env LC_ALL=C LANG=C LANGUAGE=C apt-get \
        -c "$root/etc/apt/apt.conf" \
        -o Debug::NoLocking=true \
        -o APT::Get::Simulate=true \
        --simulate \
        -y \
        --no-install-recommends \
        install "${pkg_specs[@]}" >"$simulate_log" 2>&1
      simulate_rc=$?
      set -e
      if [[ "$simulate_rc" -ne 0 ]]; then
        ok=false
        if [[ "$simulate_rc" -eq 124 || "$simulate_rc" -eq 137 ]]; then
          failure_class=network
          error_msg="apt-get install -s 超时 exit=$simulate_rc"
        else
          failure_class=$(classify_install "$simulate_log")
          error_msg="apt-get install -s 失败 exit=$simulate_rc class=$failure_class"
        fi
      fi
    fi
  fi

  if [[ "$ok" == true && "$verify_downloads" -eq 1 ]]; then
    archives_dir="$root/var/cache/apt/archives"
    mkdir -p -- "$archives_dir/partial"
    # 真实 APT：type:deb 候选原点 apt-get download（不物化 file:）。
    set +e
    (
      cd -- "$archives_dir" || exit 1
      timeout --signal=TERM --kill-after=10 "$DOWNLOAD_TIMEOUT" \
        env LC_ALL=C LANG=C LANGUAGE=C apt-get \
        -c "$root/etc/apt/apt.conf" \
        -o Debug::NoLocking=true \
        download "${pkg_specs[@]}"
    ) >"$download_log" 2>&1
    download_rc=$?
    set -e
    if [[ "$download_rc" -ne 0 ]]; then
      ok=false
      failure_class=network
      error_msg="apt-get download 失败 exit=$download_rc"
    else
      assets_tsv="$slot/assets.tsv"
      jq -r --arg s "$series" --arg a "$arch" '
        .[] | select(.series==$s and .architecture==$a)
        | [.package,.version,.id,.sha256,.size,.filename] | @tsv
      ' "$combo_tmp" >"$assets_tsv" || die "枚举下载资产失败: $series/$arch"
      while IFS=$'\t' read -r pkg_name pkg_ver pkg_id expected_sha expected_size expected_fn; do
        [[ -n "$pkg_name" ]] || continue
        [[ "$expected_sha" =~ ^[a-f0-9]{64}$ ]] || die "state 缺少资产 sha256: $pkg_id $pkg_name $arch"
        found_deb=""
        find_list="$slot/archives-debs.list"
        find -- "$archives_dir" -maxdepth 1 -type f -name '*.deb' -print >"$find_list" \
          || die "枚举 archives deb 失败"
        while IFS= read -r cand; do
          [[ -f "$cand" && ! -L "$cand" ]] || continue
          got_sha="$(sha256sum -- "$cand" | awk '{print $1}')"
          if [[ "$got_sha" == "$expected_sha" ]]; then
            found_deb="$cand"
            break
          fi
        done <"$find_list"
        if [[ -z "$found_deb" ]]; then
          ok=false
          failure_class=dependency
          error_msg="APT archives 无匹配 sha256 的 deb: $pkg_id/$pkg_name"
          break
        fi
        got_size="$(stat -c '%s' -- "$found_deb")"
        if [[ "$got_size" != "$expected_size" ]]; then
          ok=false
          failure_class=dependency
          error_msg="APT 下载 size 不符: $pkg_id/$pkg_name"
          break
        fi
        deb_pkg="$(dpkg-deb -f -- "$found_deb" Package)"
        deb_ver="$(dpkg-deb -f -- "$found_deb" Version)"
        deb_arch="$(dpkg-deb -f -- "$found_deb" Architecture)"
        if [[ "$deb_pkg" != "$pkg_name" || "$deb_ver" != "$pkg_ver" || "$deb_arch" != "$arch" ]]; then
          ok=false
          failure_class=dependency
          error_msg="APT 下载 control 不符: $pkg_id/$pkg_name"
          break
        fi
        packages_file="$repos_root/$pkg_id/dists/$series/main/binary-$arch/Packages"
        [[ -f "$packages_file" && ! -L "$packages_file" ]] || {
          ok=false
          failure_class=dependency
          error_msg="缺少 Packages: $pkg_id $series/$arch"
          break
        }
        pkg_fn="$(awk -v want="$expected_sha" '
          BEGIN { RS=""; FS="\n" }
          {
            sha=""
            for (i=1;i<=NF;i++) if ($i ~ /^SHA256: /){split($i,a," "); sha=tolower(a[2])}
            if (sha==want) {
              for (i=1;i<=NF;i++) if ($i ~ /^Filename: /){sub(/^Filename: /,"",$i); print $i; exit}
            }
          }
        ' "$packages_file")"
        if [[ "$pkg_fn" != "$expected_fn" ]]; then
          ok=false
          failure_class=dependency
          error_msg="Packages Filename 与 state 不符: $pkg_id/$pkg_name"
          break
        fi
        printf 'apt-archive %s package=%s sha256=%s size=%s\n' \
          "$found_deb" "$pkg_name" "$expected_sha" "$got_size" >>"$download_log"
      done <"$assets_tsv"
    fi

    if [[ "$ok" == true ]]; then
      # 真 upgrade 计划：旧状态 → 目标完整 Version；每包 Inst 且无 Remv。
      status_file="$root/var/lib/dpkg/status"
      : >"$status_file"
      upgrade_pkgs_tsv="$slot/upgrade-pkgs.tsv"
      jq -r --arg s "$series" --arg a "$arch" '
        [.[] | select(.series==$s and .architecture==$a) | [.package,.version] | @tsv]
        | unique[]
      ' "$combo_tmp" >"$upgrade_pkgs_tsv" || die "枚举 upgrade 包失败"
      while IFS=$'\t' read -r pkg_name pkg_ver; do
        [[ -n "$pkg_name" ]] || continue
        case "$pkg_name" in
          golang|golang-go) old_ver='2:1.22~2build1' ;;
          *) old_ver='0.0.1-1' ;;
        esac
        cat >>"$status_file" <<EOF
Package: ${pkg_name}
Status: install ok installed
Priority: optional
Section: misc
Installed-Size: 1
Maintainer: apt-hub-verify-fixture <invalid>
Architecture: ${arch}
Version: ${old_ver}
Description: offline older-version fixture for apt-get --simulate upgrade

EOF
      done <"$upgrade_pkgs_tsv"
      set +e
      timeout --signal=TERM --kill-after=10 "$SIMULATE_TIMEOUT" \
        env LC_ALL=C LANG=C LANGUAGE=C apt-get \
        -c "$root/etc/apt/apt.conf" \
        -o Debug::NoLocking=true \
        -o APT::Get::Simulate=true \
        --simulate \
        --with-new-pkgs \
        -y \
        --no-install-recommends \
        upgrade >"$upgrade_log" 2>&1
      upgrade_rc=$?
      set -e
      if [[ "$upgrade_rc" -ne 0 ]]; then
        ok=false
        failure_class=dependency
        error_msg="apt-get --simulate upgrade 失败 exit=$upgrade_rc"
      else
        if grep -Eq '^Remv ' "$upgrade_log"; then
          ok=false
          failure_class=dependency
          error_msg="upgrade 计划含 Remv"
        else
          while IFS=$'\t' read -r pkg_name pkg_ver; do
            [[ -n "$pkg_name" ]] || continue
            case "$pkg_name" in
              golang|golang-go) old_ver='2:1.22~2build1' ;;
              *) old_ver='0.0.1-1' ;;
            esac
            if ! grep -Eq "^Inst ${pkg_name}( |\\[)" "$upgrade_log"; then
              ok=false
              failure_class=dependency
              error_msg="upgrade 未 Inst 目标包: $pkg_name"
              break
            fi
            if ! grep -E "^Inst ${pkg_name}" "$upgrade_log" | grep -Fq "[${old_ver}]"; then
              ok=false
              failure_class=dependency
              error_msg="upgrade 未体现旧版 ${old_ver}→新版: $pkg_name"
              break
            fi
            if ! grep -E "^Inst ${pkg_name}" "$upgrade_log" | grep -Fq "(${pkg_ver}"; then
              ok=false
              failure_class=dependency
              error_msg="upgrade 未指向目标 Version ${pkg_ver}: $pkg_name"
              break
            fi
          done <"$upgrade_pkgs_tsv"
        fi
      fi
    fi
  fi

  if [[ "$ok" != true ]]; then
    overall_ok=false
  fi

  # shellcheck disable=SC2016
  write_json "$result_file" \
    --arg series "$series" --arg architecture "$arch" \
    --argjson ok "$( [[ "$ok" == true ]] && echo true || echo false )" \
    --arg failure_class "$failure_class" --arg error "$error_msg" \
    --argjson update_exit "$update_rc" --argjson simulate_exit "$simulate_rc" \
    --argjson download_exit "$download_rc" --argjson upgrade_exit "$upgrade_rc" \
    --argjson verify_downloads "$( [[ "$verify_downloads" -eq 1 ]] && echo true || echo false )" \
    --argjson packages "$(jq -c --arg s "$series" --arg a "$arch" \
      '[.[] | select(.series==$s and .architecture==$a) | {id,package,version}]' "$combo_tmp")" \
    '{series:$series,architecture:$architecture,ok:$ok,failure_class:(if $failure_class=="" then null else $failure_class end),error:(if $error=="" then null else $error end),update_exit:$update_exit,simulate_exit:$simulate_exit,download_exit:$download_exit,upgrade_exit:$upgrade_exit,verify_downloads:$verify_downloads,packages:$packages}'

  results_json=$(jq -c --slurpfile r "$result_file" '. + $r' <<<"$results_json")
  unset APT_CONFIG
done

# 候选 mirror.list 字节不得被验证过程改写。
while IFS= read -r expected_hash path; do
  [[ -n "${expected_hash:-}" && -n "${path:-}" ]] || continue
  path=${path#\*}
  actual_hash=$(sha256sum -- "$path" | awk '{print $1}')
  [[ "$actual_hash" == "$expected_hash" ]] || die "候选 mirror.list 被改写: $path"
done <"$mirror_hashes"

summary="$work/summary.json"
# shellcheck disable=SC2016
write_json "$summary" \
  --argjson schema_version 1 --arg checked_at "$checked_at" \
  --argjson ok "$( [[ "$overall_ok" == true ]] && echo true || echo false )" \
  --argjson results "$results_json" \
  '{schema_version:$schema_version,checked_at:$checked_at,ok:$ok,results:$results}'

echo "verify_ubuntu: 证据 $summary ok=$(jq -r .ok "$summary")"
if [[ "$overall_ok" != true ]]; then
  jq -r '.results[] | select(.ok==false) | "  FAIL " + .series + "/" + .architecture + " class=" + (.failure_class // "?") + " " + (.error // "")' "$summary" >&2
  exit 1
fi
exit 0
