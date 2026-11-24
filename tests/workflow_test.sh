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
  'POST repos/example/apt-hub/pages/builds')
    if [[ -f "${FIXTURE}/post-fail.txt" ]]; then
      cat "${FIXTURE}/post-fail.txt" >&2
      exit 1
    fi
    cat "${FIXTURE}/build-request.json"
    ;;
  'GET repos/example/apt-hub/pages/builds/123'|'GET repos/example/apt-hub/pages/builds/latest')
    if [[ -s "${FIXTURE}/build-steps.jsonl" ]]; then
      IFS= read -r step <"${FIXTURE}/build-steps.jsonl"
      tail -n +2 "${FIXTURE}/build-steps.jsonl" >"${FIXTURE}/build-steps.next"
      mv "${FIXTURE}/build-steps.next" "${FIXTURE}/build-steps.jsonl"
      printf '%s\n' "${step}"
      exit 0
    fi
    if [[ -f "${FIXTURE}/build-queue-left" ]]; then
      left="$(tr -d '[:space:]' <"${FIXTURE}/build-queue-left")"
      if [[ "${left}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$((left - 1))" >"${FIXTURE}/build-queue-left"
        printf '%s\n' '{"status":"queued"}'
        exit 0
      fi
    fi
    cat "${FIXTURE}/build-result.json"
    ;;
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
[[ -n "${out}" ]] || exit 90
case "${url}" in
  https://packages.example.test/state.json) cp "${FIXTURE}/public-state.json" "${out}" ;;
  https://packages.example.test/index.html) cp "${FIXTURE}/public-index.html" "${out}" ;;
  https://packages.example.test/add_source.sh) cp "${FIXTURE}/public-add_source.sh" "${out}" ;;
  *) exit 90 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"${WORK}/bin/sleep"
chmod a+x "${WORK}/bin/"*
export FIXTURE="${WORK}" GH_TOKEN=fixture-not-a-credential
export GITHUB_REPOSITORY=example/apt-hub GITHUB_API_URL=https://api.github.com
export GITHUB_ACTOR=fixture-human GITHUB_ACTOR_ID=12345
export GITHUB_OUTPUT="${WORK}/outputs"
export PATH="${WORK}/bin:${PATH}"
export APT_HUB_PAGES_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
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
git -C "${seed}" init -b apt-hub-pages >/dev/null
: >"${seed}/.nojekyll"
git -C "${seed}" add -- .nojekyll
git -C "${seed}" -c user.name=fixture -c user.email=fixture@invalid commit -m site >/dev/null
git -C "${seed}" remote add origin "${WORK}/origin.git"
git -C "${seed}" push -q origin HEAD:refs/heads/apt-hub-pages
seed_sha="$(git -C "${seed}" rev-parse HEAD)"
export APT_HUB_PAGES_SHA="${seed_sha}"
rm -rf -- "${seed}"
printf '%s\n' '{"html_url":"http://packages.example.test/","build_type":"legacy","source":{"branch":"apt-hub-pages","path":"/"},"cname":"packages.example.test"}' >"${WORK}/pages.json"
printf '%s\n' '{"url":"https://api.github.com/repos/example/apt-hub/pages/builds/123"}' >"${WORK}/build-request.json"
printf '%s\n' "{\"status\":\"built\",\"commit\":\"${seed_sha}\"}" >"${WORK}/build-result.json"
printf '%s\n' '{"schema_version":"2","packages":[]}' >"${WORK}/tmp/site/state.json"
printf '%s\n' '<html>candidate</html>' >"${WORK}/tmp/site/index.html"
printf '%s\n' 'candidate-client' >"${WORK}/tmp/site/add_source.sh"
cp "${WORK}/tmp/site/state.json" "${WORK}/public-state.json"
cp "${WORK}/tmp/site/index.html" "${WORK}/public-index.html"
cp "${WORK}/tmp/site/add_source.sh" "${WORK}/public-add_source.sh"
run() { (cd "${WORK}" && bash scripts/publish_apt_site.sh "$@"); }
: >"${GITHUB_OUTPUT}"
expect preflight_branch 0 run preflight
if grep -Fxq 'site_url=https://packages.example.test' "${GITHUB_OUTPUT}"; then pass '同域规范化 HTTPS'; else fail 'HTTPS 输出'; fi
if grep -Fxq 'git_email=12345+fixture-human@users.noreply.github.com' "${GITHUB_OUTPUT}"; then pass '真人提交身份'; else fail '真人身份输出'; fi
cp "${WORK}/pages.json" "${WORK}/pages-good.json"
printf '%s\n' '{"html_url":"https://packages.example.test","build_type":"workflow","source":{"branch":"main","path":"/"}}' >"${WORK}/pages.json"
expect pages_wrong_source 1 run preflight
printf '%s\n' '{"html_url":null,"build_type":"legacy","source":{"branch":"apt-hub-pages","path":"/"}}' >"${WORK}/pages.json"
expect pages_null_url 1 run preflight
printf '%s\n' '{"html_url":"https://packages.example.test\nother=x","build_type":"legacy","source":{"branch":"apt-hub-pages","path":"/"}}' >"${WORK}/pages.json"
expect pages_newline_url 1 run preflight
cp "${WORK}/pages-good.json" "${WORK}/pages.json"
printf '%s\n' '{"login":"fixture-human","id":12345,"type":"Bot"}' >"${WORK}/actor.json"
expect actor_bot 1 run preflight
printf '%s\n' '{"login":"fixture-human","id":54321,"type":"User"}' >"${WORK}/actor.json"
expect actor_id_mismatch 1 run preflight
printf '%s\n' '{"login":"fixture-human","id":12345,"type":"User"}' >"${WORK}/actor.json"
if [[ "$(git --git-dir="${WORK}/origin.git" rev-parse refs/heads/apt-hub-pages)" == "${seed_sha}" ]]; then
  pass '已有 apt-hub-pages 未被 preflight 改写'
else
  fail 'preflight 改写了已有 apt-hub-pages'
fi
if grep -Fq '产物分支 apt-hub-pages 已就绪' "${WORK}/pages_wrong_source.log"; then
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
if grep -Fq '产物分支 apt-hub-pages 已就绪' "${WORK}/pages_unconfigured.log" \
  && ! grep -Fq 'state.json' <<<"$(git --git-dir="${WORK}/origin-404.git" ls-tree -r --name-only refs/heads/apt-hub-pages)" \
  && [[ "$(git --git-dir="${WORK}/origin-404.git" ls-tree -r --name-only refs/heads/apt-hub-pages)" == ".nojekyll" ]]; then
  pass '404 只准备 .nojekyll，不发假 state'
else
  fail '404 未只准备 .nojekyll'
fi
ready_sha="$(git --git-dir="${WORK}/origin-404.git" rev-parse refs/heads/apt-hub-pages)"
author="$(git --git-dir="${WORK}/origin-404.git" log -1 --format='%an <%ae>' refs/heads/apt-hub-pages)"
committer="$(git --git-dir="${WORK}/origin-404.git" log -1 --format='%cn <%ce>' refs/heads/apt-hub-pages)"
ident='fixture-human <12345+fixture-human@users.noreply.github.com>'
if [[ "${author}" == "${ident}" && "${committer}" == "${ident}" ]]; then
  pass '404 分支 author 与 committer 都是已核验发布者'
else
  fail "404 分支身份不对: author=${author} committer=${committer}"
fi
src_head="$(git -C "${WORK}" rev-parse 'HEAD^{commit}')"
ready_parents="$(git --git-dir="${WORK}/origin-404.git" log -1 --format='%P' "${ready_sha}")"
ready_names="$(git --git-dir="${WORK}/origin-404.git" ls-tree -r --name-only "${ready_sha}")"
if [[ -z "${ready_parents}" && "${ready_names}" == ".nojekyll" ]]; then
  pass '404 初始化无父且仅 .nojekyll'
else
  fail "404 初始化父或树不对 parents=${ready_parents:-<empty>} tree=${ready_names} head=${src_head}"
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
  && ! grep -Fq '产物分支 apt-hub-pages 已就绪' "${WORK}/pages_forbidden.log" \
  && [[ "$(git --git-dir="${WORK}/origin-404.git" rev-parse refs/heads/apt-hub-pages)" == "${ready_sha}" ]]; then
  pass '403 不当成未启用，且不改已有分支'
else
  fail '403 被当成未启用或改写了分支'
fi
printf '200\n' >"${WORK}/pages.status"
git -C "${WORK}" remote set-url origin "${WORK}/origin.git"

expect explicit_pages_build 0 run deploy-pages
if grep -Fxq 'POST repos/example/apt-hub/pages/builds' "${WORK}/calls.log"; then pass '显式请求分支构建'; else fail '未请求构建'; fi
if grep -Fxq 'GET repos/example/apt-hub/pages/builds/latest' "${WORK}/calls.log"; then pass '回读构建状态'; else fail '未回读构建状态'; fi
if cmp -s "${WORK}/tmp/site/state.json" "${WORK}/tmp/public-state.json" \
  && cmp -s "${WORK}/tmp/site/index.html" "${WORK}/tmp/public-index.html" \
  && cmp -s "${WORK}/tmp/site/add_source.sh" "${WORK}/tmp/public-add_source.sh"; then
  pass '公网三文件与候选一致才成功'
else
  fail '公网三文件未全部回读比对'
fi
export APT_HUB_PAGES_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
expect pages_branch_other_commit 1 run deploy-pages
export APT_HUB_PAGES_SHA="${seed_sha}"
printf '%s\n' '{"status":"built","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"${WORK}/build-result.json"
expect pages_other_commit 1 run deploy-pages
printf '%s\n' "{\"status\":\"errored\",\"commit\":\"${seed_sha}\",\"error\":{\"message\":\"fixture build failure\"}}" >"${WORK}/build-result.json"
expect pages_build_failed 1 run deploy-pages
if grep -Fq 'Pages 已部署并回读提交' "${WORK}/pages_build_failed.log"; then
  fail '构建失败仍输出部署成功'
else
  pass '构建失败不覆盖成功'
fi
printf '%s\n' "{\"status\":\"built\",\"commit\":\"${seed_sha}\"}" >"${WORK}/build-result.json"
printf '%s\n' '{"stale":true}' >"${WORK}/public-state.json"
expect pages_public_state_stale 1 run deploy-pages
cp "${WORK}/tmp/site/state.json" "${WORK}/public-state.json"
printf '%s\n' '<html>old-index</html>' >"${WORK}/public-index.html"
expect pages_public_index_stale 1 run deploy-pages
if cmp -s "${WORK}/tmp/site/state.json" "${WORK}/tmp/public-state.json" \
  && cmp -s "${WORK}/public-index.html" "${WORK}/tmp/public-index.html" \
  && ! cmp -s "${WORK}/tmp/site/index.html" "${WORK}/tmp/public-index.html" \
  && ! grep -Fq 'Pages 已部署并回读提交' "${WORK}/pages_public_index_stale.log"; then
  pass 'state 相同但 index 旧则失败'
else
  fail 'index 旧仍被当成部署成功'
fi
cp "${WORK}/tmp/site/index.html" "${WORK}/public-index.html"
printf '%s\n' 'old-client' >"${WORK}/public-add_source.sh"
expect pages_public_client_stale 1 run deploy-pages
if cmp -s "${WORK}/tmp/site/state.json" "${WORK}/tmp/public-state.json" \
  && cmp -s "${WORK}/tmp/site/index.html" "${WORK}/tmp/public-index.html" \
  && cmp -s "${WORK}/public-add_source.sh" "${WORK}/tmp/public-add_source.sh" \
  && ! cmp -s "${WORK}/tmp/site/add_source.sh" "${WORK}/tmp/public-add_source.sh" \
  && ! grep -Fq 'Pages 已部署并回读提交' "${WORK}/pages_public_client_stale.log"; then
  pass 'state 相同但客户端旧则失败'
else
  fail '客户端旧仍被当成部署成功'
fi
cp "${WORK}/tmp/site/add_source.sh" "${WORK}/public-add_source.sh"
expect pages_public_three_match 0 run deploy-pages
if cmp -s "${WORK}/tmp/site/state.json" "${WORK}/tmp/public-state.json" \
  && cmp -s "${WORK}/tmp/site/index.html" "${WORK}/tmp/public-index.html" \
  && cmp -s "${WORK}/tmp/site/add_source.sh" "${WORK}/tmp/public-add_source.sh"; then
  pass '三文件重新对齐后部署成功'
else
  fail '三文件对齐后未成功'
fi
# 不跟随 POST 返回的 .url，始终只对可信 GITHUB_REPOSITORY 轮询 builds/latest。
run_with_repo() {
  local repo_val="$1"
  shift
  GITHUB_REPOSITORY="${repo_val}" run "$@"
}
for bad_repo in '../bad/repo' 'example/apt-hub?x=1' 'onlyowner'; do
  : >"${WORK}/calls.log"
  expect pages_bad_repo_rejected 1 run_with_repo "${bad_repo}" deploy-pages
  if [[ ! -s "${WORK}/calls.log" ]] && grep -Fq 'GITHUB_REPOSITORY 非法' "${WORK}/pages_bad_repo_rejected.log"; then
    pass "非法 GITHUB_REPOSITORY(${bad_repo}) 被拒绝且不发 API 请求"
  else
    fail "非法 GITHUB_REPOSITORY(${bad_repo}) 仍发出了 API 请求"
  fi
done
for resp_body in \
  '{"status":"queued"}' \
  '{"url":"https://evil.example/repos/example/apt-hub/pages/builds/123"}' \
  '{"url":"https://api.github.com/repositories/1442432901/pages/builds/latest"}' \
  '{"url":"https://api.github.com/repositories/999999/pages/builds/123?redirect=evil"}'; do
  printf '%s\n' "${resp_body}" >"${WORK}/build-request.json"
  : >"${WORK}/calls.log"
  expect pages_ignore_response_url 0 run deploy-pages
  if grep -Fxq 'POST repos/example/apt-hub/pages/builds' "${WORK}/calls.log" \
    && grep -Fxq 'GET repos/example/apt-hub/pages/builds/latest' "${WORK}/calls.log" \
    && ! grep -Eq 'evil\.example|repositories/|builds/123' "${WORK}/calls.log"; then
    pass '忽略 POST 响应 url，固定按 GITHUB_REPOSITORY 轮询 latest'
  else
    fail "跟随了响应 url: $(cat "${WORK}/calls.log")"
  fi
done
old_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\n' \
  "{\"status\":\"built\",\"commit\":\"${old_sha}\"}" \
  '{"status":"queued"}' \
  "{\"status\":\"built\",\"commit\":\"${seed_sha}\"}" >"${WORK}/build-steps.jsonl"
printf '%s\n' '{"url":"https://api.github.com/repos/example/apt-hub/pages/builds/latest"}' >"${WORK}/build-request.json"
: >"${WORK}/calls.log"
expect pages_latest_stale_then_expected 0 run deploy-pages
if grep -Fxq 'POST repos/example/apt-hub/pages/builds' "${WORK}/calls.log" \
  && [[ "$(grep -c 'GET repos/example/apt-hub/pages/builds/latest' "${WORK}/calls.log")" -eq 3 ]] \
  && grep -Fq 'Pages 已部署并回读提交' "${WORK}/pages_latest_stale_then_expected.log" \
  && ! grep -Fq "${old_sha}" "${WORK}/pages_latest_stale_then_expected.log"; then
  pass 'latest 先回旧 built 再 queued 后才等到预期提交'
else
  fail '旧 built 被当成成功，或未等到预期提交'
fi
rm -f -- "${WORK}/build-steps.jsonl" "${WORK}/build-steps.next"
printf '%s\n' '{"url":"https://api.github.com/repositories/1442432901/pages/builds/latest"}' >"${WORK}/build-request.json"
rm -f -- "${WORK}/build-queue-left" "${WORK}/post-fail.txt"
printf '%s\n' '1' >"${WORK}/build-queue-left"
printf '%s\n' "{\"status\":\"built\",\"commit\":\"${seed_sha}\"}" >"${WORK}/build-result.json"
: >"${WORK}/calls.log"
expect pages_queued_then_built 0 run deploy-pages
if grep -Fxq 'POST repos/example/apt-hub/pages/builds' "${WORK}/calls.log" \
  && [[ "$(grep -c 'GET repos/example/apt-hub/pages/builds/latest' "${WORK}/calls.log")" -eq 2 ]] \
  && grep -Fq 'Pages 已部署并回读提交' "${WORK}/pages_queued_then_built.log"; then
  pass 'queued 后再 built 且提交一致才成功'
else
  fail 'queued 到 built 未按两次回读成功'
fi
printf '%s\n' '80' >"${WORK}/build-queue-left"
: >"${WORK}/calls.log"
expect pages_build_timeout 1 run deploy-pages
if grep -Eq '^::error::阶段=deploy-pages 命令=轮询构建状态 Pages 构建超时:' "${WORK}/pages_build_timeout.log" \
  && grep -Fxq 'POST repos/example/apt-hub/pages/builds' "${WORK}/calls.log" \
  && ! grep -Fq 'Pages 已部署并回读提交' "${WORK}/pages_build_timeout.log"; then
  pass '构建停在 queued 超时且不记成功'
else
  fail '构建超时被当成成功或错误行不可见'
fi
rm -f -- "${WORK}/build-queue-left"
cat >"${WORK}/post-fail.txt" <<'EOF'
HTTP 502
{"message":"boom","token":"fixture-not-a-credential"}
-----BEGIN PGP PRIVATE KEY BLOCK-----
secret
-----END PGP SECRET KEY BLOCK-----
EOF
: >"${WORK}/calls.log"
expect pages_post_http 1 run deploy-pages
if grep -Eq '^::error::阶段=deploy-pages 命令=gh api --method POST repos/example/apt-hub/pages/builds HTTP 502$' "${WORK}/pages_post_http.log" \
  && ! grep -Fq 'boom' "${WORK}/pages_post_http.log" \
  && ! grep -Fq 'fixture-not-a-credential' "${WORK}/pages_post_http.log" \
  && ! grep -Fq 'BEGIN PGP PRIVATE KEY' "${WORK}/pages_post_http.log" \
  && ! grep -Fq 'Pages 已部署并回读提交' "${WORK}/pages_post_http.log"; then
  pass 'POST 失败留下阶段、命令与 HTTP 状态且不掩盖成功'
else
  fail 'POST 失败不可观察或被公网文件掩盖'
fi
rm -f -- "${WORK}/post-fail.txt"

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
# 成功依赖由 GitHub Actions 执行；不得用构包、事件或手动输入门禁漏掉同版恢复。
if ! grep -Fq cleanup_release "${WF}" \
  && awk '/^  RemoveOldRelease:/{job=1;next} job && /^    if:/{bad=1} job && /^      - release$/{release=1} job && /^      - Build$/{build=1} END{exit (bad || !release || !build)}' "${WF}"; then
  pass '成功 Release/Build 后自动清理，同版本恢复不漏；前序失败按 needs 阻止清理'
else
  fail '母版清理存在事件/构包门禁或缺少成功依赖'
fi
if awk '/^  Build:/{job=1;next} /^  RemoveOldRelease:/{job=0} job && /^    if:/{bad=1} job && /^    needs: release$/{needs=1} /^      - name: /{step=($0 ~ /生成并发布 Pages/)} step && /^        if:/{bad=1} step && /run: bash scripts\/publish_apt_site.sh publish$/{publish=1} END{exit (bad || !needs || !publish)}' "${WF}"; then
  pass '有变构包与无变复用都进入 Pages/README 发布链，不被 build_packages 门禁跳过'
else
  fail 'Build 或 Pages 发布被条件跳过，或缺少 Release 成功依赖'
fi
# shellcheck disable=SC2016 # 匹配工作流原始表达式，不在测试进程展开
if grep -Fq '          EVENT_NAME: push' "${WF}" \
  && grep -Fq '          REF: refs/tags/${{ needs.release.outputs.release_tag }}' "${WF}" \
  && grep -Fq 'run: bash scripts/release_assets.sh remote-status' "${WF}"; then
  pass '清理沿用本次解析标签和生产 remove-old；复用包也校验远端来源'
else
  fail '清理标签或来源核验接线缺失'
fi
if grep -Fq 'george012/upload_github_release_assets_action@' "${WF}" && grep -Fq 'bash ./build.sh test' "${WF}"; then pass '母版构建检验与直传 assets'; else fail '母版调用链缺失'; fi
assets_run="${WORK}/assets-run.sh"
awk '
  /^      - / { step = 0; cap = 0 }
  $0 == "        id: assets" { step = 1 }
  step && $0 == "        run: |" { cap = 1; next }
  cap && substr($0, 1, 10) == "          " { print substr($0, 11); next }
  cap { exit }
' "${WF}" >"${assets_run}"
# shellcheck disable=SC2016 # 匹配工作流中的原始变量文本
if [[ -s "${assets_run}" ]] \
  && grep -Fq 'scripts/release_assets.sh prepare-archives --go-version "${GO_VERSION}" --downloads-json tmp/go-downloads.json --archive-dir tmp/go-archives || exit $?' "${assets_run}" \
  && grep -Fq 'bash ./build.sh --go-version "${GO_VERSION}" --downloads-json tmp/go-downloads.json --archive-dir tmp/go-archives && bash ./build.sh test || exit $?' "${assets_run}" \
  && grep -Fq 'local-status --asset-dir ./build/upload_tmp_dir || exit $?' "${assets_run}"; then
  pass '抽出的 assets run 含失败传播与 local-status'
else
  fail '抽出的 assets run 不符'
fi
up_n="$(grep -n "steps.assets.outputs.upload == '1'" "${WF}" | cut -d: -f1)"
pub_n="$(grep -n 'publish_apt_site.sh publish' "${WF}" | cut -d: -f1)"
if [[ -n "${up_n}" && -n "${pub_n}" && "${up_n}" -lt "${pub_n}" ]]; then pass '上传门在 Pages 之前'; else fail '上传与 Pages 次序不对'; fi
# shellcheck disable=SC2016 # 匹配工作流原始表达式，不在测试进程展开
if grep -Fq 'actions/cache@' "${WF}" \
  && grep -Fq 'path: tmp/go-archives' "${WF}" \
  && grep -Fq 'tag_name: ${{ needs.release.outputs.release_tag }}' "${WF}" \
  && grep -Fq 'TAG: ${{ needs.release.outputs.release_tag }}' "${WF}"; then
  pass '构包使用上游载荷缓存且上传/远端核验严格绑定目标 release_tag'
else
  fail '上游载荷缓存或目标 release_tag 绑定缺失'
fi
shim_assets() {
  local name="$1" brc="$2" trc="$3" lrc="$4" want="$5" d="${WORK}/shim-$1" rc=0
  rm -rf -- "${d}"
  mkdir -p -- "${d}/scripts" "${d}/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${d}/bin/curl"
  chmod 755 "${d}/bin/curl"
  cat >"${d}/build.sh" <<EOF
#!/bin/bash
printf '%s\n' "\${1:-release}" >> calls
[[ "\${1:-}" == test ]] && exit ${trc}
exit ${brc}
EOF
  cat >"${d}/scripts/release_assets.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> calls
[[ "\$1" == prepare-archives ]] && exit 0
[[ "\$1" == local-status ]] && exit ${lrc}
if [[ "\$1" == stage-upload ]]; then printf 'upload=1\\nupload_path=tmp/missing-assets/*\\n'; exit 0; fi
exit 10
EOF
  : >"${d}/gen_debs.sh"
  : >"${d}/scripts/gen_deb_golang.sh"
  chmod a+x "${d}/build.sh" "${d}/scripts/release_assets.sh" "${d}/gen_debs.sh" "${d}/scripts/gen_deb_golang.sh"
  : >"${d}/github_output"
  set +e
  (
    cd -- "${d}"
    PATH="${d}/bin:${PATH}" GITHUB_OUTPUT="${d}/github_output" REPOSITORY=example/apt-hub TAG=v0.0.2 PACKAGE_RELEASE_TAG="${SHIM_PKG_TAG:-v0.0.2}" GO_VERSION=go9.9.9 bash "${assets_run}"
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
  if [[ "${name}" == mismatch ]] && [[ -e "${d}/calls" ]]; then fail 'mismatch 仍调用了 build.sh'; fi
}
shim_assets build23 23 0 0 23
shim_assets test24 0 24 0 24
shim_assets local1 0 0 1 1
shim_assets ok 0 0 0 0
SHIM_PKG_TAG=v0.0.1 shim_assets mismatch 0 0 0 1

chain="${WORK}/version-chain"
rm -rf -- "${chain}"
mkdir -p -- "${chain}/scripts" "${chain}/data" "${chain}/tmp"
cat >"${chain}/scripts/render.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${CAPTURE:?}"
repo=""
tag=""
site=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) repo="$2"; shift 2 ;;
    --release-tag) tag="$2"; shift 2 ;;
    --site) site="$2"; shift 2 ;;
    --state|--readme) shift 2 ;;
    *) exit 2 ;;
  esac
done
[[ -n "${repo}" && -n "${tag}" && -n "${site}" ]] || exit 3
if [[ -n "${RACE_MAIN_SHA:-}" ]]; then
  git --git-dir="${RACE_REMOTE:?}" update-ref refs/heads/main "${RACE_MAIN_SHA}"
fi
mkdir -p -- "${site}"
printf '%s\n' '<html>capture</html>' >"${site}/index.html"
exit 0
EOF
chmod a+x "${chain}/scripts/render.sh"
cat >"${chain}/README.md" <<'EOF'
MAIN_ONLY
列表取自已发布状态。**全源加源是本轮新版功能，尚未部署到 Pages；下列统一命令须待本版部署后使用。**
<!-- APT-HUB:PACKAGES:BEGIN -->
旧列表
<!-- APT-HUB:PACKAGES:END -->
EOF
printf '%s\n' '{"schema_version":"2","packages":[]}' >"${chain}/data/published.json"
cp -- "${ROOT}/scripts/publish_apt_site.sh" "${chain}/scripts/publish_apt_site.sh"
git -C "${chain}" init -b main >/dev/null
git -C "${chain}" add -- README.md data/published.json scripts/publish_apt_site.sh
git -C "${chain}" -c user.name=fixture-publisher -c user.email=fixture-publisher@invalid commit -m 'main' >/dev/null
git init --bare "${chain}.git" >/dev/null
git -C "${chain}" remote add origin "${chain}.git"
git -C "${chain}" push -q origin main
git -C "${chain}" checkout -q --orphan apt-hub-pages
git -C "${chain}" rm -rfq . >/dev/null 2>&1 || true
printf '%s\n' '{"schema_version":"2","packages":[]}' >"${chain}/state.json"
git -C "${chain}" add -- state.json
git -C "${chain}" -c user.name=fixture-publisher -c user.email=fixture-publisher@invalid commit -m 'apt-hub-pages' >/dev/null
chain_sha="$(git -C "${chain}" rev-parse HEAD)"
git -C "${chain}" push -q origin apt-hub-pages
git -C "${chain}" checkout -q --detach main
export CAPTURE="${chain}/tmp/render.args"
rm -f -- "${CAPTURE}"
miss_rc=0
(
  cd -- "${chain}"
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    APT_HUB_GIT_NAME=fixture-publisher APT_HUB_GIT_EMAIL=fixture-publisher@invalid \
    APT_HUB_PAGES_SHA="${chain_sha}" GITHUB_REPOSITORY=example/apt-hub \
    bash scripts/publish_apt_site.sh update-readme
) >"${chain}/miss.log" 2>&1 || miss_rc=$?
if [[ "${miss_rc}" -ne 0 && ! -e "${CAPTURE}" ]]; then
  pass '回写缺标签时不调用 render'
else
  fail "回写缺标签仍渲染 rc=${miss_rc}"
fi
rm -f -- "${CAPTURE}"
ok_rc=0
(
  cd -- "${chain}"
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    APT_HUB_GIT_NAME=fixture-publisher APT_HUB_GIT_EMAIL=fixture-publisher@invalid \
    APT_HUB_PAGES_SHA="${chain_sha}" GITHUB_REPOSITORY=example/apt-hub RELEASE_TAG=v7.7.7 \
    bash scripts/publish_apt_site.sh update-readme
) >"${chain}/ok.log" 2>&1 || ok_rc=$?
ok_args="$(cat "${CAPTURE}" 2>/dev/null || true)"
if [[ "${ok_rc}" -eq 0 \
  && "${ok_args}" == *"--repository example/apt-hub"* \
  && "${ok_args}" == *"--release-tag v7.7.7"* \
  && "$(git --git-dir="${chain}.git" show main:README.md)" != *'尚未部署到 Pages'* ]]; then
  pass '回写传版本并移除未部署提示'
else
  fail "回写未清理未部署提示 rc=${ok_rc} args=${ok_args} log=$(tr '\n' ' ' <"${chain}/ok.log")"
fi
main_sha="$(git --git-dir="${chain}.git" rev-parse refs/heads/main)"
again_rc=0
again_note=1
(
  cd -- "${chain}"
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    APT_HUB_GIT_NAME=fixture-publisher APT_HUB_GIT_EMAIL=fixture-publisher@invalid \
    APT_HUB_PAGES_SHA="${chain_sha}" GITHUB_REPOSITORY=example/apt-hub RELEASE_TAG=v7.7.7 \
    bash scripts/publish_apt_site.sh update-readme
) >"${chain}/again.log" 2>&1 || again_rc=$?
grep -Fq 'README 与已发布状态已一致' "${chain}/again.log" && again_note=0
again_readme="$(git --git-dir="${chain}.git" show main:README.md)"
if [[ "${again_rc}" -eq 0 \
  && "$(git --git-dir="${chain}.git" rev-parse refs/heads/main)" == "${main_sha}" \
  && "${again_note}" -eq 0 \
  && "${again_readme}" != *'尚未部署到 Pages'* ]]; then
  pass '原源码重跑接受精确自动回写后继，重复回写幂等'
else
  fail "重复回写不幂等 rc=${again_rc}"
fi
# 旧维护运行在 Pages 后，新发版推进 main：旧 run 不得在新源码上追加 README。
git -C "${chain}" checkout -q main
git -C "${chain}" fetch -q origin main
git -C "${chain}" merge -q --ff-only FETCH_HEAD
printf 'new business release\n' >"${chain}/new-business"
git -C "${chain}" add new-business
git -C "${chain}" -c user.name=fixture-publisher -c user.email=fixture-publisher@invalid commit -qm 'new release source'
new_release_sha="$(git -C "${chain}" rev-parse HEAD)"
git -C "${chain}" push -q origin main
git -C "${chain}" checkout -q --detach "${main_sha}"
stale_rc=0
(cd -- "${chain}"; APT_HUB_GIT_NAME=fixture-publisher APT_HUB_GIT_EMAIL=fixture-publisher@invalid \
 APT_HUB_PAGES_SHA="${chain_sha}" GITHUB_REPOSITORY=example/apt-hub RELEASE_TAG=v7.7.7 \
 bash scripts/publish_apt_site.sh update-readme) >"${chain}/stale-source.log" 2>&1 || stale_rc=$?
if [[ "${stale_rc}" -ne 0 && "$(git --git-dir="${chain}.git" rev-parse main)" == "${new_release_sha}" ]]; then
  pass '旧维护遇新源码安全失败，不在新发版上追加回写；失败传播阻止 cleanup'
else
  fail "旧维护未拒绝新源码 rc=${stale_rc}"
fi
# 后继新 run 检出新发版：现有已一致状态应正常完成，不被旧回写产生的提交挡住。
git -C "${chain}" checkout -q --detach "${new_release_sha}"
new_rc=0
(cd -- "${chain}"; APT_HUB_GIT_NAME=fixture-publisher APT_HUB_GIT_EMAIL=fixture-publisher@invalid \
 APT_HUB_PAGES_SHA="${chain_sha}" GITHUB_REPOSITORY=example/apt-hub RELEASE_TAG=v7.7.7 \
 bash scripts/publish_apt_site.sh update-readme) >"${chain}/new-source.log" 2>&1 || new_rc=$?
if [[ "${new_rc}" -eq 0 && "$(git --git-dir="${chain}.git" rev-parse main)" == "${new_release_sha}" ]]; then
  pass '较新源码的后继运行正常幂等，不受旧维护影响'
else
  fail "后继新源码运行失败 rc=${new_rc}"
fi

# fetch 到生成结果之间 main 又推进，即便本次无文件可写，也必须失败而非进入 cleanup。
race_tree="$(git -C "${chain}" rev-parse 'HEAD^{tree}')"
race_main_sha="$(git -C "${chain}" -c user.name=fixture-publisher -c user.email=fixture-publisher@invalid commit-tree "${race_tree}" -p "${new_release_sha}" -m 'concurrent source successor')"
git -C "${chain}" push -q origin "${race_main_sha}:refs/fixture/race-source"
race_rc=0
(cd -- "${chain}"; RACE_MAIN_SHA="${race_main_sha}" RACE_REMOTE="${chain}.git" \
 APT_HUB_GIT_NAME=fixture-publisher APT_HUB_GIT_EMAIL=fixture-publisher@invalid \
 APT_HUB_PAGES_SHA="${chain_sha}" GITHUB_REPOSITORY=example/apt-hub RELEASE_TAG=v7.7.7 \
 bash scripts/publish_apt_site.sh update-readme) >"${chain}/race-source.log" 2>&1 || race_rc=$?
if [[ "${race_rc}" -ne 0 && "$(git --git-dir="${chain}.git" rev-parse main)" == "${race_main_sha}" ]]; then
  pass 'main在fetch后推进，即使无变化回写也重新核对并安全失败'
else
  fail "main在幂等核验中变化未拒绝 rc=${race_rc}"
fi

mismatch_site_rc=0
(
  cd -- "${chain}"
  mkdir -p tmp/gnupg tmp/previous
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' >tmp/bad-update-marker
  env GITHUB_TOKEN=fixture APT_HUB_FINGERPRINT=0123456789ABCDEF0123456789ABCDEF01234567 \
    SITE_URL=https://example.github.io/apt-hub PACKAGE_REPOSITORY=example/apt-hub \
    RELEASE_TAG=v7.7.7 PACKAGE_RELEASE_TAG=v7.7.6 \
    bash scripts/publish_apt_site.sh build-site
) >"${chain}/pkg-tag-mismatch.log" 2>&1 || mismatch_site_rc=$?
if [[ "${mismatch_site_rc}" -ne 0 ]] && grep -Fq '必须与 RELEASE_TAG' "${chain}/pkg-tag-mismatch.log"; then
  pass 'build-site 拒绝 PACKAGE_RELEASE_TAG 与 RELEASE_TAG 不一致'
else
  fail "build-site 未拒绝标签不一致 rc=${mismatch_site_rc}"
fi

cleanup
printf 'RESULT pass=%s fail=%s evidence=%s\n' "${PASS}" "${FAIL}" "${WORK}"
[[ "${FAIL}" -eq 0 ]]
