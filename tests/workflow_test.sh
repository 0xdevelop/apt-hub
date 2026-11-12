#!/usr/bin/env bash
# 本地 API 夹具验证发布脚本；不代表真实 GitHub Pages 部署。
set -euo pipefail
export LC_ALL=C
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${ROOT}/tmp/workflow-test"
[[ ! -L "${BASE}" ]] || exit 1
mkdir -p "${BASE}"
WORK="$(mktemp -d "${BASE}/run.XXXXXX")"
mkdir -p "${WORK}/scripts" "${WORK}/bin" "${WORK}/tmp/site"
cp "${ROOT}/scripts/publish_apt_site.sh" "${WORK}/scripts/"
PASS=0
FAIL=0
cleanup() {
  local home
  for home in "${WORK}/key" "${WORK}/key-other" "${WORK}/key-protected" "${WORK}/tmp/gnupg"; do
    [[ ! -d "${home}" ]] || gpgconf --homedir "${home}" --kill all >/dev/null 2>&1 || true
    rm -rf -- "${home}/private-keys-v1.d" "${home}/openpgp-revocs.d"
  done
  rm -f -- "${WORK}/key.asc" "${WORK}/multi.asc" "${WORK}/protected.asc"
}
trap cleanup EXIT
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }
expect() {
  local label="$1" want="$2" rc=0
  shift 2
  "$@" >"${WORK}/${label}.log" 2>&1 || rc=$?
  if [[ "${rc}" -eq "${want}" ]]; then pass "${label}"; else fail "${label}: rc=${rc}, want=${want}"; fi
}
cat >"${WORK}/bin/gh" <<'SH'
#!/usr/bin/env bash
# 仅本地 API 夹具。
set -euo pipefail
[[ "$1" == api ]] || exit 90
shift
method=GET
if [[ "${1:-}" == --method ]]; then method="$2"; shift 2; fi
printf '%s %s\n' "${method}" "$1" >>"${FIXTURE}/calls.log"
case "${method} $1" in
  'GET repos/example/apt-hub/pages')
    status=200
    if [[ -f "${FIXTURE}/pages.status" ]]; then
      status="$(tr -d '[:space:]' <"${FIXTURE}/pages.status")"
    fi
    case "${status}" in
      200) cat "${FIXTURE}/pages.json" ;;
      404) printf '%s\n' 'gh: HTTP 404: Not Found' >&2; exit 1 ;;
      403) printf '%s\n' 'gh: HTTP 403: Forbidden' >&2; exit 1 ;;
      *) printf '%s\n' "gh: HTTP ${status}" >&2; exit 1 ;;
    esac
    ;;
  'GET users/fixture-human') cat "${FIXTURE}/actor.json" ;;
  'POST repos/example/apt-hub/pages/builds') cat "${FIXTURE}/build-request.json" ;;
  'GET repos/example/apt-hub/pages/builds/123') cat "${FIXTURE}/build-result.json" ;;
  *) exit 90 ;;
esac
SH
cat >"${WORK}/bin/curl" <<'SH'
#!/usr/bin/env bash
# 仅本地站点夹具。
set -euo pipefail
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    --connect-timeout|--max-time|--proto|--proto-redir) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ "${url}" == 'https://packages.example.test/state.json' && -n "${out}" ]] || exit 90
cp "${FIXTURE}/public-state.json" "${out}"
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"${WORK}/bin/sleep"
chmod a+x "${WORK}/bin/"*
export FIXTURE="${WORK}" GH_TOKEN=fixture-not-a-credential
export GITHUB_REPOSITORY=example/apt-hub GITHUB_API_URL=https://api.github.com
export GITHUB_ACTOR=fixture-human GITHUB_ACTOR_ID=12345
export GITHUB_OUTPUT="${WORK}/outputs"
export PATH="${WORK}/bin:${PATH}"
export APT_DATA_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export SITE_URL=https://packages.example.test
printf '%s\n' '{"login":"fixture-human","id":12345,"type":"User"}' >"${WORK}/actor.json"
printf '200\n' >"${WORK}/pages.status"
git -C "${WORK}" init -b main >/dev/null
printf 'fixture\n' >"${WORK}/README.md"
git -C "${WORK}" add -- README.md scripts/publish_apt_site.sh
git -C "${WORK}" -c user.name=fixture -c user.email=fixture@invalid commit -m init >/dev/null
git init --bare "${WORK}/origin.git" >/dev/null
git -C "${WORK}" remote add origin "${WORK}/origin.git"
git -C "${WORK}" push -q origin HEAD:refs/heads/main
seed="$(mktemp -d "${WORK}/tmp/seed.XXXXXX")"
git -C "${seed}" init -b apt-data >/dev/null
: >"${seed}/.nojekyll"
git -C "${seed}" add -- .nojekyll
git -C "${seed}" -c user.name=fixture -c user.email=fixture@invalid commit -m site >/dev/null
git -C "${seed}" remote add origin "${WORK}/origin.git"
git -C "${seed}" push -q origin HEAD:refs/heads/apt-data
seed_sha="$(git -C "${seed}" rev-parse HEAD)"
rm -rf -- "${seed}"
printf '%s\n' '{"html_url":"http://packages.example.test/","build_type":"legacy","source":{"branch":"apt-data","path":"/"},"cname":"packages.example.test"}' >"${WORK}/pages.json"
printf '%s\n' '{"url":"https://api.github.com/repos/example/apt-hub/pages/builds/123"}' >"${WORK}/build-request.json"
printf '%s\n' '{"status":"built","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"${WORK}/build-result.json"
printf '%s\n' '{"schema_version":"2","packages":[]}' >"${WORK}/tmp/site/state.json"
cp "${WORK}/tmp/site/state.json" "${WORK}/public-state.json"
run() { (cd "${WORK}" && bash scripts/publish_apt_site.sh "$@"); }
: >"${GITHUB_OUTPUT}"
expect preflight_branch 0 run preflight
if grep -Fxq 'site_url=https://packages.example.test' "${GITHUB_OUTPUT}"; then pass '同域规范化 HTTPS'; else fail 'HTTPS 输出'; fi
if grep -Fxq 'git_email=12345+fixture-human@users.noreply.github.com' "${GITHUB_OUTPUT}"; then pass '真人提交身份'; else fail '真人身份输出'; fi
cp "${WORK}/pages.json" "${WORK}/pages-good.json"
printf '%s\n' '{"html_url":"https://packages.example.test","build_type":"workflow","source":{"branch":"main","path":"/"}}' >"${WORK}/pages.json"
expect pages_wrong_source 1 run preflight
printf '%s\n' '{"html_url":null,"build_type":"legacy","source":{"branch":"apt-data","path":"/"}}' >"${WORK}/pages.json"
expect pages_null_url 1 run preflight
printf '%s\n' '{"html_url":"https://packages.example.test\nother=x","build_type":"legacy","source":{"branch":"apt-data","path":"/"}}' >"${WORK}/pages.json"
expect pages_newline_url 1 run preflight
cp "${WORK}/pages-good.json" "${WORK}/pages.json"
printf '%s\n' '{"login":"fixture-human","id":12345,"type":"Bot"}' >"${WORK}/actor.json"
expect actor_bot 1 run preflight
printf '%s\n' '{"login":"fixture-human","id":54321,"type":"User"}' >"${WORK}/actor.json"
expect actor_id_mismatch 1 run preflight
printf '%s\n' '{"login":"fixture-human","id":12345,"type":"User"}' >"${WORK}/actor.json"
if [[ "$(git --git-dir="${WORK}/origin.git" rev-parse refs/heads/apt-data)" == "${seed_sha}" ]]; then
  pass '已有 apt-data 未被 preflight 改写'
else
  fail 'preflight 改写了已有 apt-data'
fi
if grep -Fq '产物分支 apt-data 已就绪' "${WORK}/pages_wrong_source.log"; then
  pass '源未选对时提示分支已就绪'
else
  fail '源未选对时未提示分支已就绪'
fi

git init --bare "${WORK}/origin-404.git" >/dev/null
git -C "${WORK}" remote set-url origin "${WORK}/origin-404.git"
git -C "${WORK}" push -q origin HEAD:refs/heads/main
printf '404\n' >"${WORK}/pages.status"
export GIT_AUTHOR_NAME=decoy GIT_AUTHOR_EMAIL=decoy@invalid
export GIT_COMMITTER_NAME=decoy GIT_COMMITTER_EMAIL=decoy@invalid
expect pages_unconfigured 1 run preflight
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
if grep -Fq '产物分支 apt-data 已就绪' "${WORK}/pages_unconfigured.log" \
  && ! grep -Fq 'state.json' <<<"$(git --git-dir="${WORK}/origin-404.git" ls-tree -r --name-only refs/heads/apt-data)" \
  && [[ "$(git --git-dir="${WORK}/origin-404.git" ls-tree -r --name-only refs/heads/apt-data)" == ".nojekyll" ]]; then
  pass '404 只准备 .nojekyll，不发假 state'
else
  fail '404 未只准备 .nojekyll'
fi
ready_sha="$(git --git-dir="${WORK}/origin-404.git" rev-parse refs/heads/apt-data)"
author="$(git --git-dir="${WORK}/origin-404.git" log -1 --format='%an <%ae>' refs/heads/apt-data)"
committer="$(git --git-dir="${WORK}/origin-404.git" log -1 --format='%cn <%ce>' refs/heads/apt-data)"
ident='fixture-human <12345+fixture-human@users.noreply.github.com>'
if [[ "${author}" == "${ident}" && "${committer}" == "${ident}" ]]; then
  pass '404 分支 author 与 committer 都是已核验发布者'
else
  fail "404 分支身份不对: author=${author} committer=${committer}"
fi
common="$(git -C "${WORK}" rev-parse --path-format=absolute --git-common-dir)"
if git --git-dir="${common}" cat-file -e "${ready_sha}^{commit}" \
  && [[ "$(git -C "${WORK}" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]]; then
  pass '骨架提交在原仓共同 gitdir，临时 worktree 已移除'
else
  fail '骨架提交不在原仓或 worktree 未移除'
fi
printf '403\n' >"${WORK}/pages.status"
expect pages_forbidden 1 run preflight
if grep -Fq '读取 Pages 失败（权限或网络），不能当作未启用' "${WORK}/pages_forbidden.log" \
  && ! grep -Fq '产物分支 apt-data 已就绪' "${WORK}/pages_forbidden.log" \
  && [[ "$(git --git-dir="${WORK}/origin-404.git" rev-parse refs/heads/apt-data)" == "${ready_sha}" ]]; then
  pass '403 不当成未启用，且不改已有分支'
else
  fail '403 被当成未启用或改写了分支'
fi
printf '200\n' >"${WORK}/pages.status"
git -C "${WORK}" remote set-url origin "${WORK}/origin.git"

expect explicit_pages_build 0 run deploy-pages
if grep -Fxq 'POST repos/example/apt-hub/pages/builds' "${WORK}/calls.log"; then pass '显式请求分支构建'; else fail '未请求构建'; fi
printf '%s\n' '{"status":"built","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"${WORK}/build-result.json"
expect pages_other_commit 1 run deploy-pages
printf '%s\n' '{"status":"errored","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","error":{"message":"fixture build failure"}}' >"${WORK}/build-result.json"
expect pages_build_failed 1 run deploy-pages
printf '%s\n' '{"status":"built","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"${WORK}/build-result.json"
printf '%s\n' '{"stale":true}' >"${WORK}/public-state.json"
expect pages_public_state_stale 1 run deploy-pages
cp "${WORK}/tmp/site/state.json" "${WORK}/public-state.json"

for item in key key-other key-protected; do mkdir -p "${WORK}/${item}"; chmod 700 "${WORK}/${item}"; done
gpg --homedir "${WORK}/key" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'Workflow fixture <workflow@invalid>' ed25519 sign 1d >"${WORK}/keygen.log" 2>&1
gpg --homedir "${WORK}/key-other" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'Other fixture <other@invalid>' ed25519 sign 1d >>"${WORK}/keygen.log" 2>&1
gpg --homedir "${WORK}/key-protected" --batch --pinentry-mode loopback --passphrase 'fixture-only-protection' --quick-generate-key 'Protected fixture <protected@invalid>' ed25519 sign 1d >>"${WORK}/keygen.log" 2>&1
gpg --homedir "${WORK}/key" --batch --armor --export-secret-keys >"${WORK}/key.asc"
cp "${WORK}/key.asc" "${WORK}/multi.asc"
gpg --homedir "${WORK}/key-other" --batch --armor --export-secret-keys >>"${WORK}/multi.asc"
gpg --homedir "${WORK}/key-protected" --batch --pinentry-mode loopback --passphrase 'fixture-only-protection' --armor --export-secret-keys >"${WORK}/protected.asc"
run_import() {
  local file="$1"
  [[ ! -d "${WORK}/tmp/gnupg" ]] || gpgconf --homedir "${WORK}/tmp/gnupg" --kill all >/dev/null 2>&1 || true
  rm -rf -- "${WORK}/tmp/gnupg"
  (export APT_HUB_GPG_PRIVATE_KEY; APT_HUB_GPG_PRIVATE_KEY="$(<"${file}")"; run import-key)
}
expect key_unprotected 0 run_import "${WORK}/key.asc"
expect key_multiple 1 run_import "${WORK}/multi.asc"
expect key_protected 1 run_import "${WORK}/protected.asc"
if grep -Eq '^fingerprint=[A-F0-9]{40}$' "${GITHUB_OUTPUT}"; then pass '私钥派生公开指纹'; else fail '未输出派生指纹'; fi

WF="${ROOT}/.github/workflows/release.yml"
if [[ ! -e "${ROOT}/.github/workflows/ubuntu-publish.yml" && ! -e "${ROOT}/.github/workflows/ubuntu-test.yml" ]]; then pass '无影子工作流'; else fail '仍有额外工作流'; fi
if ! grep -Eq 'upload-pages-artifact|deploy-pages@|upload-artifact|download-artifact|id-token:' "${WF}"; then pass '无 Actions Artifact 与 OIDC 部署链'; else fail 'Artifact 影子链残留'; fi
if grep -q '^  release:' "${WF}" && grep -q '^  Build:' "${WF}" && grep -q '^  RemoveOldRelease:' "${WF}"; then pass '母版三段保留'; else fail '三段缺失'; fi
if grep -Fq 'george012/upload_github_release_assets_action@' "${WF}" && grep -Fq 'bash ./build.sh test' "${WF}"; then pass '母版构建检验与直传 assets'; else fail '母版调用链缺失'; fi
assets_run="${WORK}/assets-run.sh"
awk '
  /^      - / { step = 0; cap = 0 }
  $0 == "        id: assets" { step = 1 }
  step && $0 == "        run: |" { cap = 1; next }
  cap && substr($0, 1, 10) == "          " { print substr($0, 11); next }
  cap { exit }
' "${WF}" >"${assets_run}"
if [[ -s "${assets_run}" ]] \
  && grep -Fq 'bash ./build.sh && bash ./build.sh test || exit $?' "${assets_run}" \
  && grep -Fq 'local-status --asset-dir ./build/upload_tmp_dir || exit $?' "${assets_run}"; then
  pass '抽出的 assets run 含失败传播与 local-status'
else
  fail '抽出的 assets run 不符'
fi
up_n="$(grep -n "steps.assets.outputs.upload == '1'" "${WF}" | cut -d: -f1)"
pub_n="$(grep -n 'publish_apt_site.sh publish' "${WF}" | cut -d: -f1)"
if [[ -n "${up_n}" && -n "${pub_n}" && "${up_n}" -lt "${pub_n}" ]]; then pass '上传门在 Pages 之前'; else fail '上传与 Pages 次序不对'; fi
shim_assets() {
  local name="$1" brc="$2" trc="$3" lrc="$4" want="$5" d="${WORK}/shim-$1" rc=0
  rm -rf -- "${d}"
  mkdir -p -- "${d}/scripts"
  cat >"${d}/build.sh" <<EOF
#!/bin/bash
printf '%s\n' "\${1:-release}" >> calls
[[ "\${1:-}" == test ]] && exit ${trc}
exit ${brc}
EOF
  cat >"${d}/scripts/release_assets.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> calls
[[ "\$1" == local-status ]] && exit ${lrc}
exit 10
EOF
  : >"${d}/gen_debs.sh"
  : >"${d}/scripts/gen_deb_golang.sh"
  chmod a+x "${d}/build.sh" "${d}/scripts/release_assets.sh" "${d}/gen_debs.sh" "${d}/scripts/gen_deb_golang.sh"
  : >"${d}/github_output"
  set +e
  (
    cd -- "${d}"
    GITHUB_OUTPUT="${d}/github_output" REPOSITORY=example/apt-hub TAG=v0.0.2 bash "${assets_run}"
  ) >"${d}.log" 2>&1
  rc=$?
  set -e
  if [[ "${rc}" -eq "${want}" ]]; then pass "run ${name}"; else fail "run ${name} rc=${rc}"; fi
  if [[ "${want}" -eq 0 ]]; then
    if grep -Fxq 'upload=1' "${d}/github_output"; then
      pass "${name} 写 upload=1"
    else
      fail "${name} 未写 upload=1"
    fi
  elif grep -Fxq 'upload=1' "${d}/github_output"; then
    fail "${name} 写了 upload=1"
  else
    pass "${name} 未写 upload=1"
  fi
  if [[ "${name}" == build23 || "${name}" == test24 ]] && grep -qx local-status "${d}/calls"; then
    fail "${name} 调用了 local-status"
  fi
  if [[ "${name}" == build23 ]] && grep -qx test "${d}/calls"; then fail 'build23 仍跑了 test'; fi
}
shim_assets build23 23 0 0 23
shim_assets test24 0 24 0 24
shim_assets local1 0 0 1 1
shim_assets ok 0 0 0 0
cleanup
printf 'RESULT pass=%s fail=%s evidence=%s\n' "${PASS}" "${FAIL}" "${WORK}"
[[ "${FAIL}" -eq 0 ]]
