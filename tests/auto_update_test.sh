#!/usr/bin/env bash
# 隔离 API 与本地文件验证自动更新决策；不访问生产服务。
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$(mktemp -d "${ROOT}/tmp/auto-update-test.XXXXXX")"
mkdir -p "${BASE}/bin" "${BASE}/api" "${BASE}/scripts" "${BASE}/config" "${BASE}/tmp"
cp "${ROOT}/scripts/release_assets.sh" "${BASE}/scripts/"
cp "${ROOT}/scripts/gen_deb_golang.sh" "${BASE}/scripts/"
cp "${ROOT}/config/go.json" "${ROOT}/config/packages.json" "${BASE}/config/"
cp "${ROOT}/VERSION" "${BASE}/VERSION"
cat >"${BASE}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == api ]]; then
  path="$2"
  if [[ "$path" == users/fixture ]]; then
    printf '%s\n' '{"login":"fixture","id":1,"type":"User"}'
    exit 0
  fi
  tag="${path##*/}"
  if [[ ! -f "${FIXTURE}/api/${tag}.json" ]]; then
    printf 'gh: Not Found (HTTP 404)\n' >&2
    exit 1
  fi
  cat "${FIXTURE}/api/${tag}.json"
  exit 0
fi
if [[ "$1" == release && "$2" == download ]]; then
  tag="$3"
  shift 3
  dir="" pattern=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --pattern) pattern="$2"; shift 2 ;;
      --repo) shift 2 ;;
      --clobber) shift ;;
      *) shift ;;
    esac
  done
  name="${pattern//%2B/+}"
  src="${FIXTURE}/assets-by-tag/${tag}/${name}"
  if [[ ! -f "$src" ]]; then
    src="${FIXTURE}/assets/${name}"
  fi
  [[ -f "$src" ]] || exit 22
  cp "$src" "${dir}/${name}"
  exit 0
fi
exit 90
EOF
cat >"${BASE}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  'https://go.dev/dl/?mode=json'|'https://go.dev/dl/?mode=json&include=all') src="${FIXTURE}/downloads.json" ;;
  *)
    name="${url##*/}"
    name="${name//%2B/+}"
    rest="${url%/releases/download/*}"
    tag_part="${url##*/releases/download/}"
    tag_part="${tag_part%%/*}"
    if [[ -f "${FIXTURE}/assets-by-tag/${tag_part}/${name}" ]]; then
      src="${FIXTURE}/assets-by-tag/${tag_part}/${name}"
    else
      src="${FIXTURE}/assets/${name}"
    fi
    ;;
esac
[[ -f "$src" ]] || exit 22
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
EOF
chmod 755 "${BASE}/bin/gh" "${BASE}/bin/curl"
export FIXTURE="${BASE}"
export PATH="${BASE}/bin:${PATH}"
printf '%s\n' '[{"version":"go9.9.9","stable":true,"files":[{"os":"linux","arch":"amd64","kind":"archive","filename":"go9.9.9.linux-amd64.tar.gz","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":111},{"os":"linux","arch":"arm64","kind":"archive","filename":"go9.9.9.linux-arm64.tar.gz","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":222}]}]' >"${BASE}/downloads.json"
jq '. + [{version:"go1.20",stable:true,files:[]},{version:"go1",stable:true,files:[]}]' "${BASE}/downloads.json" >"${BASE}/downloads-history.json"
mv "${BASE}/downloads-history.json" "${BASE}/downloads.json"
tag="v$(tr -d '[:space:]' <"${BASE}/VERSION")"
jq -n --arg tag "$tag" '{tag_name:$tag,html_url:("https://github.com/example/apt-hub/releases/tag/"+$tag),draft:false,prerelease:false,assets:[]}' >"${BASE}/api/${tag}.json"
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag "$tag" >"${BASE}/empty-plan.out" 2>"${BASE}/empty-plan.err" || rc=$?
if [[ "$rc" -ne 0 ]] || ! grep -Fxq 'build_packages=1' "${BASE}/empty-plan.out" || ! grep -Fxq 'bump_release=0' "${BASE}/empty-plan.out" || ! grep -Fxq 'go_version=go9.9.9' "${BASE}/empty-plan.out"; then
  printf 'FAIL 空Release未生成同标签恢复计划 rc=%s evidence=%s\n' "$rc" "$BASE"
  exit 1
fi
printf 'PASS 空Release进入同标签恢复，不盲目升版\n'

# 按原工作流的 run 段执行，不复制一份相似编排。
awk '
  /^      - / { step=0; cap=0 }
  $0=="        id: tag" { step=1 }
  step && $0=="        run: |" { cap=1; next }
  cap && substr($0,1,10)=="          " { print substr($0,11); next }
  cap { exit }
' "${ROOT}/.github/workflows/release.yml" >"${BASE}/release-run.sh"
cp "${ROOT}/git_tag.sh" "${BASE}/git_tag.sh"
cp "${ROOT}/.gitignore" "${BASE}/.gitignore"
mkdir -p "${BASE}/changelog"
git -C "${BASE}" init -q -b main
git -C "${BASE}" add -- .gitignore VERSION git_tag.sh scripts config
git -C "${BASE}" -c user.name=fixture -c user.email=fixture@invalid commit -q -m init
git -C "${BASE}" tag "$tag"
git init -q --bare "${BASE}/tmp/origin.git"
git -C "${BASE}" remote add origin "${BASE}/tmp/origin.git"
git -C "${BASE}" push -q origin main "$tag"
: >"${BASE}/github-output"
rc=0
(cd "${BASE}" && GH_TOKEN=fixture EVENT_NAME=workflow_dispatch REF=refs/heads/main REPOSITORY=example/apt-hub GITHUB_ACTOR=fixture GITHUB_ACTOR_ID=1 GITHUB_OUTPUT="${BASE}/github-output" bash "${BASE}/release-run.sh") >"${BASE}/schedule.log" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]] || ! grep -Fxq 'build_packages=1' "${BASE}/github-output"; then
  printf 'FAIL workflow_dispatch 空Release恢复失败 rc=%s evidence=%s\n' "$rc" "$BASE"
  exit 1
fi
printf 'PASS workflow_dispatch 进入缺失资产恢复\n'
# 首次 preflight 只准备 .nojekyll，尚无可读的已发布 state。
blob=$(printf '' | git -C "${BASE}" hash-object -w --stdin)
tree=$(printf '100644 blob %s\t.nojekyll\n' "$blob" | git -C "${BASE}" mktree)
site_sha=$(printf 'site\n' | git -C "${BASE}" -c user.name=fixture -c user.email=fixture@invalid commit-tree "$tree")
git -C "${BASE}" push -q origin "${site_sha}:refs/heads/apt-hub-pages"
rc=0
(cd "${BASE}" && GH_TOKEN=fixture EVENT_NAME=workflow_dispatch REF=refs/heads/main REPOSITORY=example/apt-hub GITHUB_OUTPUT="${BASE}/tmp/skeleton-output" bash "${BASE}/release-run.sh") >"${BASE}/tmp/skeleton.log" 2>&1 || rc=$?
if [[ "${rc}" -ne 0 ]] || ! grep -Fxq build_packages=1 "${BASE}/tmp/skeleton-output"; then
  printf 'FAIL 首次Pages骨架被当成已发布快照 rc=%s evidence=%s\n' "$rc" "$BASE"
  exit 1
fi
printf 'PASS 首次Pages骨架无需伪造state即可恢复构包\n'

mkdir -p "${BASE}/assets"
fixture_revision="$(jq -r '.revision' "${BASE}/config/go.json")"
fingerprint=$(cd "${BASE}" && sha256sum scripts/gen_deb_golang.sh config/go.json | sha256sum | cut -d' ' -f1)
for arch in amd64 arm64; do
  root="${BASE}/tmp/package-${arch}"
  mkdir -p "${root}/DEBIAN" "${root}/usr/share/doc/golang"
  printf 'Package: golang\nVersion: 2:9.9.9-%s\nArchitecture: %s\nMaintainer: fixture <fixture@invalid>\nDescription: isolated fixture\n' "$fixture_revision" "$arch" >"${root}/DEBIAN/control"
  printf 'fixture\n' >"${root}/usr/share/doc/golang/fixture"
  dpkg-deb --build --root-owner-group "$root" "${BASE}/assets/golang_9.9.9-${fixture_revision}_${arch}.deb" >/dev/null
  deb="${BASE}/assets/golang_9.9.9-${fixture_revision}_${arch}.deb"
  sha=$(sha256sum "$deb" | cut -d' ' -f1)
  size=$(stat -c '%s' "$deb")
  upstream_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  upstream_size=111
  if [[ "$arch" == arm64 ]]; then upstream_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; upstream_size=222; fi
  jq -nc --arg arch "$arch" --arg ver "2:9.9.9-${fixture_revision}" --arg fn "${deb##*/}" --arg sha "$sha" --arg size "$size" --arg usha "$upstream_sha" --arg usize "$upstream_size" '{package:"golang",version:$ver,architecture:$arch,filename:$fn,sha256:$sha,size:$size,upstream:{url:("https://go.dev/dl/go9.9.9.linux-"+$arch+".tar.gz"),sha256:$usha,size:$usize}}' >>"${BASE}/packages.jsonl"
done
jq -n --arg hash "$fingerprint" --arg rev "$fixture_revision" --slurpfile pkgs "${BASE}/packages.jsonl" '{schema_version:"1",build_inputs_sha256:$hash,upstream:{version:"go9.9.9",version_debian:"9.9.9",epoch:"2",revision:$rev},packages:$pkgs}' >"${BASE}/assets/golang.provenance.json"
(cd "${BASE}/assets" && sha256sum golang_*.deb golang.provenance.json >SHA256SUMS)
release_from_assets() {
  local release_tag="$1" file
  : >"${BASE}/asset-rows.jsonl"
  for file in "${BASE}/assets/"*; do
    jq -nc --arg name "${file##*/}" --arg sha "sha256:$(sha256sum "$file" | cut -d' ' -f1)" --argjson size "$(stat -c '%s' "$file")" --arg tag "$release_tag" '{name:$name,size:$size,digest:$sha,state:"uploaded",browser_download_url:("https://github.com/example/apt-hub/releases/download/"+$tag+"/"+($name|@uri))}' >>"${BASE}/asset-rows.jsonl"
  done
  jq -n --arg tag "$release_tag" --slurpfile rows "${BASE}/asset-rows.jsonl" '{tag_name:$tag,html_url:("https://github.com/example/apt-hub/releases/tag/"+$tag),draft:false,assets:$rows}' >"${BASE}/api/${release_tag}.json"
}
release_from_assets "$tag"
cp "${BASE}/api/${tag}.json" "${BASE}/url-valid.json"
for bad_url in \
  "https://github.com/other/apt-hub/releases/download/${tag}/golang.deb" \
  "https://github.com/example/apt-hub/releases/download/v99.0.0/golang.deb" \
  "https://github.com/example/apt-hub/releases/download/${tag}/golang_9.9.9-1%252B0.0.8_amd64.deb" \
  "https://github.com/example/apt-hub/releases/download/${tag}/golang%2Famd64.deb"; do
  jq --arg url "$bad_url" '(.assets[] | select(.name|endswith(".deb")) | .browser_download_url)=$url' "${BASE}/url-valid.json" >"${BASE}/api/${tag}.json"
  rc=0
  GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag "$tag" >"${BASE}/bad-url.out" 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] && grep -Fq 'Release 资产身份、摘要或名称非法' "${BASE}/bad-url.out"
done
cp "${BASE}/url-valid.json" "${BASE}/api/${tag}.json"
rm -- "${BASE}/url-valid.json"
printf 'PASS URL编码兼容不放宽仓库、标签、资产名或路径身份\n'
for round in 1 2; do
  GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag "$tag" >"${BASE}/repeat-${round}.out"
  grep -Fxq build_packages=0 "${BASE}/repeat-${round}.out"
  grep -Fxq bump_release=0 "${BASE}/repeat-${round}.out"
done
printf 'PASS 连续两轮未变化均不重构、不升版\n'
mkdir -p "${BASE}/assets-by-tag/${tag}"
cp -a "${BASE}/assets/." "${BASE}/assets-by-tag/${tag}/"
jq --arg tag "$tag" --arg ver "2:9.9.9-${fixture_revision}" '{schema_version:"2",packages:[{id:"golang",release_tag:$tag,package_repository:"example/apt-hub",version:$ver}]}' <<<null >"${BASE}/previous-state.json"
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag v8.0.0 --previous-state "${BASE}/previous-state.json" >"${BASE}/new-target.out"
grep -Fxq build_packages=0 "${BASE}/new-target.out"
grep -Fxq bump_release=0 "${BASE}/new-target.out"
grep -Fxq package_release_tag=v8.0.0 "${BASE}/new-target.out"
grep -Fxq go_version=go9.9.9 "${BASE}/new-target.out"
grep -Fxq "reuse_from_tag=${tag}" "${BASE}/new-target.out"
printf 'PASS 同输入不同release tag进入跨版本复用计划，不重新打包/涨revision\n'

# 真实生产函数：prepare-reuse + local-status + stage-upload + remote-status（新 tag 完整四资产，deb 原字节一致，provenance 区分原构建与复用）
jq -n '{tag_name:"v8.0.0",html_url:"https://github.com/example/apt-hub/releases/tag/v8.0.0",draft:false,prerelease:false,assets:[]}' >"${BASE}/api/v8.0.0.json"
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" prepare-reuse \
  --repository example/apt-hub --source-tag "$tag" --tag v8.0.0 \
  --downloads-json "${BASE}/downloads.json" --asset-dir "${BASE}/tmp/reuse-v800"
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" local-status \
  --repository example/apt-hub --tag v8.0.0 --asset-dir "${BASE}/tmp/reuse-v800"
cmp -s "${BASE}/assets/golang_9.9.9-${fixture_revision}_amd64.deb" "${BASE}/tmp/reuse-v800/golang_9.9.9-${fixture_revision}_amd64.deb"
cmp -s "${BASE}/assets/golang_9.9.9-${fixture_revision}_arm64.deb" "${BASE}/tmp/reuse-v800/golang_9.9.9-${fixture_revision}_arm64.deb"
src_prov_sha="$(sha256sum "${BASE}/assets/golang.provenance.json" | cut -d' ' -f1)"
jq -e --arg orig "$tag" --arg src "$tag" --arg tgt v8.0.0 --arg psha "$src_prov_sha" --arg rev "$fixture_revision" '
  .schema_version=="1"
  and .upstream.version=="go9.9.9"
  and .upstream.revision==$rev
  and .reused_from.repository=="example/apt-hub"
  and .reused_from.origin_release_tag==$orig
  and .reused_from.source_release_tag==$src
  and .reused_from.source_provenance_sha256==$psha
  and .reused_from.target_release_tag==$tgt
' "${BASE}/tmp/reuse-v800/golang.provenance.json" >/dev/null
(cd "${BASE}/tmp/reuse-v800" && sha256sum -c -- SHA256SUMS >/dev/null)
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" stage-upload \
  --repository example/apt-hub --tag v8.0.0 --asset-dir "${BASE}/tmp/reuse-v800" --output-dir "${BASE}/tmp/reuse-upload-v800" >"${BASE}/tmp/reuse-stage.out"
grep -Fxq 'upload=1' "${BASE}/tmp/reuse-stage.out"
[[ "$(find "${BASE}/tmp/reuse-upload-v800" -maxdepth 1 -type f | wc -l)" -eq 4 ]]
mkdir -p "${BASE}/assets-by-tag/v8.0.0"
cp -a "${BASE}/tmp/reuse-upload-v800/." "${BASE}/assets-by-tag/v8.0.0/"
: >"${BASE}/asset-rows.jsonl"
for file in "${BASE}/assets-by-tag/v8.0.0/"*; do
  jq -nc --arg name "${file##*/}" --arg sha "sha256:$(sha256sum "$file" | cut -d' ' -f1)" --argjson size "$(stat -c '%s' "$file")" '{name:$name,size:$size,digest:$sha,state:"uploaded",browser_download_url:("https://github.com/example/apt-hub/releases/download/v8.0.0/"+($name|@uri))}' >>"${BASE}/asset-rows.jsonl"
done
jq -n --slurpfile rows "${BASE}/asset-rows.jsonl" '{tag_name:"v8.0.0",html_url:"https://github.com/example/apt-hub/releases/tag/v8.0.0",draft:false,prerelease:false,assets:$rows}' >"${BASE}/api/v8.0.0.json"
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" remote-status --repository example/apt-hub --tag v8.0.0 --source-tag >/dev/null
printf 'PASS 同输入跨tag复用四资产完整上传并校验通过，deb字节与Version完全一致\n'

# 链式复用 v8.0.0 -> v8.0.1：origin_release_tag 保持原构建 tag，source_release_tag 记本次来源 v8.0.0
jq -n '{tag_name:"v8.0.1",html_url:"https://github.com/example/apt-hub/releases/tag/v8.0.1",draft:false,prerelease:false,assets:[]}' >"${BASE}/api/v8.0.1.json"
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" prepare-reuse \
  --repository example/apt-hub --source-tag v8.0.0 --tag v8.0.1 \
  --downloads-json "${BASE}/downloads.json" --asset-dir "${BASE}/tmp/reuse-v801"
jq -e --arg orig "$tag" '
  .reused_from.origin_release_tag==$orig
  and .reused_from.source_release_tag=="v8.0.0"
  and .reused_from.target_release_tag=="v8.0.1"
' "${BASE}/tmp/reuse-v801/golang.provenance.json" >/dev/null
printf 'PASS 链式复用区分原构建来源与本次复用来源\n'

# 构建输入改动 -> build_inputs_sha256 改变，plan 拒绝复用旧产物且 prepare-reuse 失败
cp "${BASE}/scripts/gen_deb_golang.sh" "${BASE}/scripts/gen_deb_golang.sh.bak"
printf '\n# input change fixture\n' >>"${BASE}/scripts/gen_deb_golang.sh"
jq -n '{tag_name:"v8.0.2",html_url:"https://github.com/example/apt-hub/releases/tag/v8.0.2",draft:false,prerelease:false,assets:[]}' >"${BASE}/api/v8.0.2.json"
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag v8.0.2 --previous-state "${BASE}/previous-state.json" >"${BASE}/changed-input.out"
grep -Fxq build_packages=1 "${BASE}/changed-input.out"
grep -Fxq reuse_from_tag= "${BASE}/changed-input.out"
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" prepare-reuse \
  --repository example/apt-hub --source-tag "$tag" --tag v8.0.2 \
  --downloads-json "${BASE}/downloads.json" --asset-dir "${BASE}/tmp/reuse-bad-input" >"${BASE}/changed-input-reuse.err" 2>&1 || rc=$?
[[ "$rc" -eq 1 && ! -e "${BASE}/tmp/reuse-bad-input" ]]
mv "${BASE}/scripts/gen_deb_golang.sh.bak" "${BASE}/scripts/gen_deb_golang.sh"
cp "${BASE}/config/go.json" "${BASE}/config/go.json.bak"
jq '.description += " (input-change)"' "${BASE}/config/go.json.bak" >"${BASE}/config/go.json"
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag v8.0.2 --previous-state "${BASE}/previous-state.json" >"${BASE}/changed-gocfg.out"
grep -Fxq build_packages=1 "${BASE}/changed-gocfg.out"
grep -Fxq reuse_from_tag= "${BASE}/changed-gocfg.out"
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" prepare-reuse \
  --repository example/apt-hub --source-tag "$tag" --tag v8.0.2 \
  --downloads-json "${BASE}/downloads.json" --asset-dir "${BASE}/tmp/reuse-bad-gocfg" >"${BASE}/changed-gocfg-reuse.err" 2>&1 || rc=$?
[[ "$rc" -eq 1 && ! -e "${BASE}/tmp/reuse-bad-gocfg" ]]
mv "${BASE}/config/go.json.bak" "${BASE}/config/go.json"
printf 'PASS 构建输入改动(gen_deb_golang.sh与config/go.json)后fingerprint变化并拒绝旧产物复用\n'

# 缺失或损坏旧资产不能静默通过（plan 与 prepare-reuse 均拒绝）
cp "${BASE}/api/${tag}.json" "${BASE}/api/${tag}.json.ok"
jq '.assets=[.assets[]|select(.name!="golang_9.9.9-'"${fixture_revision}"'_arm64.deb")]' "${BASE}/api/${tag}.json.ok" >"${BASE}/api/${tag}.json"
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag v8.0.2 --previous-state "${BASE}/previous-state.json" >"${BASE}/missing-old-plan.err" 2>&1 || rc=$?
[[ "$rc" -eq 1 ]]
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" prepare-reuse --repository example/apt-hub --source-tag "$tag" --tag v8.0.2 --downloads-json "${BASE}/downloads.json" --asset-dir "${BASE}/tmp/reuse-missing-old" >"${BASE}/missing-old-reuse.err" 2>&1 || rc=$?
[[ "$rc" -eq 1 && ! -e "${BASE}/tmp/reuse-missing-old" ]]
cp "${BASE}/api/${tag}.json.ok" "${BASE}/api/${tag}.json"
printf 'corrupt\n' >"${BASE}/assets-by-tag/${tag}/golang_9.9.9-${fixture_revision}_amd64.deb"
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag v8.0.2 --previous-state "${BASE}/previous-state.json" >"${BASE}/corrupt-old-plan.err" 2>&1 || rc=$?
[[ "$rc" -eq 1 ]]
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" prepare-reuse --repository example/apt-hub --source-tag "$tag" --tag v8.0.2 --downloads-json "${BASE}/downloads.json" --asset-dir "${BASE}/tmp/reuse-corrupt-old" >"${BASE}/corrupt-old-reuse.err" 2>&1 || rc=$?
[[ "$rc" -eq 1 && ! -e "${BASE}/tmp/reuse-corrupt-old" ]]
cp -a "${BASE}/assets/." "${BASE}/assets-by-tag/${tag}/"
rm -f -- "${BASE}/api/${tag}.json.ok"
printf 'PASS 缺失或损坏旧资产在plan与prepare-reuse均被拒绝\n'

# 假改名拒绝：只改 deb 文件名并重算 SHA256SUMS，不改包内 control/provenance，local-status 必须拒绝
cp -a "${BASE}/assets" "${BASE}/tmp/assets-fake-rename"
mv "${BASE}/tmp/assets-fake-rename/golang_9.9.9-${fixture_revision}_amd64.deb" "${BASE}/tmp/assets-fake-rename/golang_9.9.9-1+8.0.0_amd64.deb"
(cd "${BASE}/tmp/assets-fake-rename" && sha256sum golang_*.deb golang.provenance.json >SHA256SUMS)
rc=0
bash "${BASE}/scripts/release_assets.sh" local-status --asset-dir "${BASE}/tmp/assets-fake-rename" >"${BASE}/fake-rename.out" 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] && grep -Eq '来源列出的 deb 不在资产中|来源文件名非法|来源与 deb 字节不一致' "${BASE}/fake-rename.out"
# 即使连 provenance.packages[].filename 也伪造改名，但 deb 内部 DEBIAN/control Version 仍为旧版，也必须拒绝
jq --arg fn "golang_9.9.9-1+8.0.0_amd64.deb" '(.packages[] | select(.architecture=="amd64") | .filename)=$fn | (.packages[] | select(.architecture=="amd64") | .version)="2:9.9.9-1+8.0.0"' "${BASE}/tmp/assets-fake-rename/golang.provenance.json" >"${BASE}/tmp/assets-fake-rename/golang.provenance.json.tmp"
mv "${BASE}/tmp/assets-fake-rename/golang.provenance.json.tmp" "${BASE}/tmp/assets-fake-rename/golang.provenance.json"
(cd "${BASE}/tmp/assets-fake-rename" && sha256sum golang_*.deb golang.provenance.json >SHA256SUMS)
rc=0
bash "${BASE}/scripts/release_assets.sh" local-status --asset-dir "${BASE}/tmp/assets-fake-rename" >"${BASE}/fake-rename2.out" 2>&1 || rc=$?
[[ "$rc" -eq 1 ]]
# stage-upload 用不匹配 config/go.json revision 的资产目录上传也必须拒绝
jq -n '{tag_name:"v8.0.0",html_url:"https://github.com/example/apt-hub/releases/tag/v8.0.0",draft:false,prerelease:false,assets:[]}' >"${BASE}/api/v8.0.0.json"
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" stage-upload --repository example/apt-hub --tag v8.0.0 --asset-dir "${BASE}/tmp/assets-fake-rename" --output-dir "${BASE}/tmp/upload-wrong-rev" >"${BASE}/wrong-rev-upload.out" 2>&1 || rc=$?
[[ "$rc" -eq 1 && ! -e "${BASE}/tmp/upload-wrong-rev" ]]
printf 'PASS 假改名、包内control不匹配及修订不符 staged上传均被拒绝\n' 

jq '.assets=[.assets[]|select(.name=="golang.provenance.json")]' "${BASE}/api/${tag}.json" >"${BASE}/partial.json"
cp "${BASE}/api/${tag}.json" "${BASE}/complete.json"
cp "${BASE}/partial.json" "${BASE}/api/${tag}.json"
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" stage-upload --repository example/apt-hub --tag "$tag" --asset-dir "${BASE}/assets" --output-dir "${BASE}/tmp/upload-missing" >"${BASE}/partial-upload.out"
[[ "$(find "${BASE}/tmp/upload-missing" -maxdepth 1 -type f | wc -l)" -eq 3 ]]
[[ ! -e "${BASE}/tmp/upload-missing/golang.provenance.json" ]]
printf 'PASS 部分上传只补缺失文件，不覆盖同名\n'
cp "${BASE}/complete.json" "${BASE}/api/${tag}.json"
jq '(.assets[0].digest)="sha256:0000000000000000000000000000000000000000000000000000000000000000"' "${BASE}/complete.json" >"${BASE}/api/${tag}.json"
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" stage-upload --repository example/apt-hub --tag "$tag" --asset-dir "${BASE}/assets" --output-dir "${BASE}/tmp/upload-conflict" >"${BASE}/conflict.out" 2>&1 || rc=$?
[[ "$rc" -eq 1 && ! -e "${BASE}/tmp/upload-conflict" ]]
printf 'PASS 同名资产冲突拒绝且不准备上传\n'
cp "${BASE}/complete.json" "${BASE}/api/${tag}.json"

cp "${BASE}/downloads.json" "${BASE}/downloads-original.json"
jq '.[0].version="go10.0.0" | .[0].files |= map(.filename|="go10.0.0"+.[9:])' "${BASE}/downloads-original.json" >"${BASE}/downloads.json"
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag "$tag" >"${BASE}/upstream-change.out"
grep -Fxq build_packages=1 "${BASE}/upstream-change.out"
grep -Fxq bump_release=1 "${BASE}/upstream-change.out"
printf 'PASS 上游更新生成一次升版计划\n'
# 缺失来源文件时，SHA256SUMS 也足以固定已有包的上游版本。
jq '.assets=[.assets[]|select(.name=="SHA256SUMS")]' "${BASE}/complete.json" >"${BASE}/api/${tag}.json"
rc=0
GH_TOKEN=fixture bash "${BASE}/scripts/release_assets.sh" plan --repository example/apt-hub --tag "$tag" >"${BASE}/sum-only.out" 2>"${BASE}/sum-only.err" || rc=$?
if [[ "${rc}" -ne 0 ]] || ! grep -Fxq 'go_version=go9.9.9' "${BASE}/sum-only.out"; then
  printf 'FAIL 仅上传摘要清单后不能恢复原版本 rc=%s evidence=%s\n' "$rc" "$BASE"
  exit 1
fi
printf 'PASS 仅有SHA256SUMS也固定原包版本恢复\n'
cp "${BASE}/complete.json" "${BASE}/api/${tag}.json"
# 原版本入口要求工作树干净，夹具和结果留在 Git 忽略区。
mkdir -p "${BASE}/tmp/fixture"
for entry in bin api assets assets-by-tag downloads.json downloads-original.json packages.jsonl asset-rows.jsonl previous-state.json release-run.sh; do
  if [[ -e "${BASE}/${entry}" ]]; then mv "${BASE}/${entry}" "${BASE}/tmp/fixture/"; fi
done
for entry in "${BASE}/"*.out "${BASE}/"*.err "${BASE}/"*.log "${BASE}/github-output" "${BASE}/partial.json" "${BASE}/complete.json"; do
  [[ ! -e "${entry}" ]] || mv "${entry}" "${BASE}/tmp/fixture/"
done
export FIXTURE="${BASE}/tmp/fixture"
export PATH="${FIXTURE}/bin:${PATH}"
rc=0
(cd "${BASE}" && GH_TOKEN=fixture EVENT_NAME=workflow_dispatch REF=refs/heads/main REPOSITORY=example/apt-hub GITHUB_ACTOR=fixture GITHUB_ACTOR_ID=1 GITHUB_OUTPUT="${BASE}/tmp/version-output" bash "${FIXTURE}/release-run.sh") >"${BASE}/tmp/auto-version.log" 2>&1 || rc=$?
if [[ "${rc}" -ne 0 ]]; then printf 'FAIL workflow_dispatch 解析 vtag 失败 rc=%s evidence=%s\n' "$rc" "$BASE"; exit 1; fi
still_tag="v$(tr -d '[:space:]' <"${BASE}/VERSION")"
[[ "${still_tag}" == "${tag}" ]]
grep -Fxq "release_tag=${tag}" "${BASE}/tmp/version-output"
printf 'PASS workflow_dispatch 不调用 git_tag.sh，维护版本保持不变\n'
# 自动升版改由 scripts/auto_check.sh 在本地调用 git_tag.sh。
rc=0
(cd "${BASE}" && GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=fixture GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=fixture@invalid bash git_tag.sh) >"${BASE}/tmp/auto-check-tag.log" 2>&1 || rc=$?
if [[ "${rc}" -ne 0 ]]; then printf 'FAIL 本地 git_tag.sh 自动发版 rc=%s evidence=%s\n' "$rc" "$BASE"; exit 1; fi
new_tag="v$(tr -d '[:space:]' <"${BASE}/VERSION")"
[[ "${new_tag}" != "${tag}" ]]
remote_main=$(git -C "${BASE}" ls-remote origin refs/heads/main)
remote_new_tag=$(git -C "${BASE}" ls-remote origin "refs/tags/${new_tag}")
[[ "${remote_main%%$'\t'*}" == "${remote_new_tag%%$'\t'*}" && "${remote_main%%$'\t'*}" == "$(git -C "${BASE}" rev-parse HEAD)" ]]
printf 'PASS 本地 git_tag.sh 推进维护分支、标签和准确构包SHA\n'
# 版本标签被远端 hook 拒绝：新的 atomic 发布必须全部拒绝，不留下半发布。
cat >"${BASE}/tmp/origin.git/hooks/update" <<'EOF'
#!/usr/bin/env bash
case "$1" in refs/tags/v*) exit 1 ;; esac
EOF
chmod 755 "${BASE}/tmp/origin.git/hooks/update"
rc=0
(cd "${BASE}" && GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=fixture GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=fixture@invalid bash git_tag.sh) >"${BASE}/tmp/tag-interrupted.log" 2>&1 || rc=$?
[[ "${rc}" -ne 0 ]]
recover_tag="v$(tr -d '[:space:]' <"${BASE}/VERSION")"
recover_sha=$(git -C "${BASE}" rev-parse HEAD)
interrupted_main=$(git -C "${BASE}" ls-remote origin refs/heads/main)
interrupted_latest=$(git -C "${BASE}" ls-remote origin refs/tags/latest)
[[ "${interrupted_main%%$'\t'*}" == "${remote_main%%$'\t'*}" && "${interrupted_latest%%$'\t'*}" == "${remote_main%%$'\t'*}" ]]
[[ -z "$(git -C "${BASE}" ls-remote origin "refs/tags/${recover_tag}")" ]]
printf 'PASS 远端拒绝版本标签时分支与latest也原子保留，不制造半发布\n'
# 仍保留旧版非原子发布遗留状态的恢复覆盖；只在本机 bare 夹具中构造历史状态。
git --git-dir="${BASE}/tmp/origin.git" update-ref refs/heads/main "${recover_sha}" "${remote_main%%$'\t'*}"
git --git-dir="${BASE}/tmp/origin.git" update-ref refs/tags/latest "${recover_sha}" "${remote_main%%$'\t'*}"
printf '#!/usr/bin/env bash\nexit 0\n' >"${BASE}/tmp/origin.git/hooks/update"
git clone -q -b main "${BASE}/tmp/origin.git" "${BASE}/tmp/recovery"
: >"${BASE}/tmp/recovery-output"
(cd "${BASE}/tmp/recovery" && GH_TOKEN=fixture EVENT_NAME=workflow_dispatch REF=refs/heads/main REPOSITORY=example/apt-hub GITHUB_OUTPUT="${BASE}/tmp/recovery-output" bash "${FIXTURE}/release-run.sh") >"${BASE}/tmp/recovery.log" 2>&1
recovered=$(git -C "${BASE}" ls-remote origin "refs/tags/${recover_tag}")
[[ "${recovered%%$'\t'*}" == "${recover_sha}" ]]
grep -Fxq "release_tag=${recover_tag}" "${BASE}/tmp/recovery-output"
grep -Fxq "source_sha=${recover_sha}" "${BASE}/tmp/recovery-output"
printf 'PASS 分支已推标签中断后仅恢复原标签，不二次升版\n'
# 重跑旧标签不能回退页面或包。
git -C "${BASE}/tmp/recovery" checkout -q --detach "${tag}"
: >"${BASE}/tmp/stale-output"
rc=0
(cd "${BASE}/tmp/recovery" && GH_TOKEN=fixture EVENT_NAME=push REF="refs/tags/${tag}" REPOSITORY=example/apt-hub GITHUB_OUTPUT="${BASE}/tmp/stale-output" bash "${FIXTURE}/release-run.sh") >"${BASE}/tmp/stale.log" 2>&1 || rc=$?
[[ "${rc}" -ne 0 && ! -s "${BASE}/tmp/stale-output" ]]
grep -Fq '拒绝过时运行' "${BASE}/tmp/stale.log"
printf 'PASS 过时tag事件拒绝且无发布成功输出\n'
printf 'RESULT pass=14 fail=0 evidence=%s\n' "$BASE"
