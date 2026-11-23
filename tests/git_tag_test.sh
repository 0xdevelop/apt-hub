#!/usr/bin/env bash
# 仅用本地 bare 远端验证版本、标签和失败传播。
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$(mktemp -d "${ROOT}/tmp/git-tag-test.XXXXXX")"
passes=0

fail() { printf 'FAIL %s evidence=%s\n' "$*" "$BASE" >&2; exit 1; }
pass() { passes=$((passes + 1)); printf 'PASS %s\n' "$*"; }
git_identity() { git -c user.name='0xYeah' -c user.email='wmyeah017@gmail.com' "$@"; }
new_repo() {
  local name="$1" version="$2"
  REPO="${BASE}/${name}"
  mkdir -p "${REPO}/changelog"
  git init -q -b main "$REPO"
  printf '%s\n' "$version" >"${REPO}/VERSION"
  printf '保留的历史记录\n' >"${REPO}/changelog/history.md"
  git -C "$REPO" add -- VERSION changelog/history.md
  git_identity -C "$REPO" commit -qm init
  git -C "$REPO" tag "v${version}"
  git init -q --bare "${BASE}/${name}.git"
  git -C "$REPO" remote add origin "${BASE}/${name}.git"
  git -C "$REPO" push -q origin main "v${version}"
  BEFORE="$(git -C "$REPO" rev-parse HEAD)"
}
run_tag() {
  rc=0
  (cd "$REPO" && GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0='0xYeah' GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1='wmyeah017@gmail.com' bash "${ROOT}/git_tag.sh" "$@") >"${BASE}/run.log" 2>&1 || rc=$?
  cp "${BASE}/run.log" "${BASE}/$(basename "$REPO")-${passes}.log"
}
assert_release() {
  local want="$1" current remote ref
  [[ "$rc" -eq 0 ]] || fail "发版返回 ${rc}"
  [[ "$(<"${REPO}/VERSION")" == "$want" ]] || fail 'VERSION 与期望不符'
  [[ -f "${REPO}/changelog/v${want}.md" ]] || fail '缺少对应变更记录'
  current="$(git -C "$REPO" rev-parse HEAD)"
  for ref in refs/heads/main refs/tags/latest "refs/tags/v${want}"; do
    remote="$(git -C "$REPO" ls-remote origin "$ref")"
    [[ "${remote%%$'\t'*}" == "$current" ]] || fail "远端 ${ref} 未指向发版提交"
  done
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail '成功后工作树不干净'
  [[ "$(git -C "$REPO" show HEAD:changelog/history.md)" == '保留的历史记录' ]] || fail '历史记录被删'
  [[ "$(git -C "$REPO" log -1 --format=%s)" == "Release:--: v${want}_"* ]] || fail '提交格式脱离母版'
}
assert_rejected() {
  [[ "$rc" -ne 0 ]] || fail '失败被吞掉'
  if grep -Eq 'Complated|Completed' "${BASE}/run.log"; then fail '失败后输出完成'; fi
}

# 两个发布者从同一基线交错：赢家全部 refs 不得被输家部分删除。
new_repo overlap 0.0.7
winner_repo="${REPO}"
loser_repo="${BASE}/overlap-loser"
git init -q -b main "${loser_repo}"
git -C "${loser_repo}" remote add origin "${BASE}/overlap.git"
git -C "${loser_repo}" fetch -q origin main --tags
git -C "${loser_repo}" reset -q --soft FETCH_HEAD
git -C "${loser_repo}" checkout HEAD -- .
printf 'winner\n' >"${winner_repo}/change"
git -C "${winner_repo}" add change
git_identity -C "${winner_repo}" commit -qm winner
printf 'loser\n' >"${loser_repo}/change"
git -C "${loser_repo}" add change
git_identity -C "${loser_repo}" commit -qm loser
run_tag
assert_release 0.0.8
winner_refs="$(git --git-dir="${BASE}/overlap.git" show-ref)"
REPO="${loser_repo}"
run_tag
assert_rejected
[[ "$(git --git-dir="${BASE}/overlap.git" show-ref)" == "${winner_refs}" ]] || fail '竞争失败改变赢家 refs（包括 latest）'
pass '自动/手动同版本交错失败不改变赢家任何 refs'

# 读到 latest 后发生 TOCTOU：pre-push hook 在协商后推进 bare 远端 latest。
new_repo lease-race 0.0.7
git -C "${REPO}" tag latest
git -C "${REPO}" push -q origin latest
race_remote="${BASE}/lease-race.git"
race_tree="$(git --git-dir="${race_remote}" rev-parse 'main^{tree}')"
race_commit="$(git_identity --git-dir="${race_remote}" commit-tree "${race_tree}" -p "${BEFORE}" -m rival)"
cat >"${REPO}/.git/hooks/pre-push" <<EOF
#!/usr/bin/env bash
set -euo pipefail
git --git-dir='${race_remote}' update-ref refs/tags/latest '${race_commit}'
EOF
chmod 755 "${REPO}/.git/hooks/pre-push"
run_tag
assert_rejected
[[ "$(git --git-dir="${race_remote}" rev-parse main)" == "${BEFORE}" \
  && "$(git --git-dir="${race_remote}" rev-parse refs/tags/latest)" == "${race_commit}" \
  && -z "$(git --git-dir="${race_remote}" tag -l v0.0.8)" ]] || fail 'latest TOCTOU 导致部分 ref 发布'
pass 'latest 在读取后被抢占，原子事务全部拒绝且保留竞争方值'

new_repo no-atomic 0.0.7
git --git-dir="${BASE}/no-atomic.git" config receive.advertiseAtomic false
before_refs="$(git --git-dir="${BASE}/no-atomic.git" show-ref)"
run_tag
assert_rejected
[[ "$(git --git-dir="${BASE}/no-atomic.git" show-ref)" == "${before_refs}" ]] || fail '不支持 atomic 时降级或部分推送'
pass '远端不支持 atomic 则明确失败，绝不降级拆分推送'

new_repo query 0.0.7
run_tag -get_pre_del_tag_name
[[ "$rc" -eq 0 ]] || fail '缺少母版 -get_pre_del_tag_name 入口'
grep -Eq 'Pre Del Tag With[[:space:]]+0\.0\.6$' "${BASE}/run.log" || fail '旧标签查询不符母版'
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$BEFORE" && -z "$(git -C "$REPO" status --porcelain)" ]] || fail '查询修改了仓库'
pass '母版旧标签查询无写入'

for name in to_run get_pre_del_version_no git_handle_ready find_prev_release_commit gen_changelog_if_possible git_handle_push handle_input; do
  grep -Eq "^(function )?${name}[[:space:]]*(\\(\\))?[[:space:]]*\\{" "${ROOT}/git_tag.sh" || fail "母版函数 ${name} 被替换"
done
pass '保留母版函数结构'

new_repo noargs 0.0.7
run_tag
assert_release 0.0.8
[[ "$(git -C "$REPO" rev-parse v0.0.7)" == "$BEFORE" ]] || fail '旧版本标签被移动'
pass '无参数自动递增并推送分支、latest 和版本标签'

new_repo auto 0.0.7
run_tag auto
assert_release 0.0.8
pass 'auto 与无参数等价'

new_repo existing-latest 0.0.7
git -C "$REPO" tag latest
git -C "$REPO" tag v0.0.6
git -C "$REPO" push -q origin latest v0.0.6
run_tag
assert_release 0.0.8
[[ -z "$(git -C "$REPO" tag -l v0.0.6)" ]] || fail '未执行母版本地旧标签清理'
remote="$(git -C "$REPO" ls-remote origin refs/tags/v0.0.6)"
[[ "${remote%%$'\t'*}" == "$BEFORE" ]] || fail '脚本擅自删除远端版本历史'
pass '更新既有 latest，仅清理本地旧标签，保留历史文档和远端版本'

for pair in '0.0.999 0.1.0' '0.999.999 1.0.0' '0.0.0 0.0.1'; do
  read -r old next <<<"$pair"
  new_repo "carry-${old}" "$old"
  run_tag
  assert_release "$next"
  pass "自动进位 ${old} -> ${next}"
done

new_repo reject 0.0.7
for mode in custom --version bogus-mode; do
  run_tag "$mode"
  assert_rejected
  [[ "$(<"${REPO}/VERSION")" == 0.0.7 && "$(git -C "$REPO" rev-parse HEAD)" == "$BEFORE" ]] || fail '拒绝入口仍修改版本'
done
run_tag --help
[[ "$rc" -eq 2 ]] || fail 'help 退出码改变'
printf 'dirty\n' >"${REPO}/dirty.txt"
run_tag
assert_rejected
[[ "$(<"${REPO}/VERSION")" == 0.0.7 ]] || fail '脏工作树仍改版本'
pass '手动、未知入口和脏工作树均拒绝，帮助不发版'

new_repo tag-exists 0.0.7
git -C "$REPO" tag v0.0.8
run_tag
assert_rejected
[[ "$(<"${REPO}/VERSION")" == 0.0.7 ]] || fail '版本标签冲突仍改版本'
pass '已有版本标签不被覆盖'

new_repo changelog-failure 0.0.7
mkdir "${REPO}/changelog/v0.0.8.md"
printf '保留\n' >"${REPO}/changelog/v0.0.8.md/marker"
git -C "$REPO" add -- changelog/v0.0.8.md/marker
git_identity -C "$REPO" commit -qm 'test blocked changelog'
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
run_tag
assert_rejected
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$BEFORE" && -z "$(git -C "$REPO" tag -l latest)" ]] || fail '变更记录写入失败仍提交'
[[ "$(<"${REPO}/changelog/v0.0.8.md/marker")" == '保留' ]] || fail '失败破坏已有路径'
pass '变更记录写入失败停止且保留已有路径'

new_repo commit-failure 0.0.7
printf '#!/bin/sh\nexit 1\n' >"${REPO}/.git/hooks/pre-commit"
chmod 755 "${REPO}/.git/hooks/pre-commit"
run_tag
assert_rejected
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$BEFORE" && -z "$(git -C "$REPO" tag -l latest)" ]] || fail 'commit 失败后仍打标签'
pass 'commit 失败停止且不假报完成'

for target in refs/heads/main refs/tags/latest refs/tags/v0.0.8; do
  new_repo "push-${passes}" 0.0.7
  # shellcheck disable=SC2016
  printf '#!/bin/sh\n[ "$1" != "%s" ]\n' "$target" >"${BASE}/$(basename "$REPO").git/hooks/update"
  chmod 755 "${BASE}/$(basename "$REPO").git/hooks/update"
  run_tag
  assert_rejected
  remote="$(git -C "$REPO" ls-remote origin refs/tags/v0.0.8)"
  [[ -z "$remote" ]] || fail '前置 push 失败仍发布版本标签'
  if [[ "$target" == refs/heads/main ]]; then
    remote="$(git -C "$REPO" ls-remote origin refs/heads/main)"
    [[ "${remote%%$'\t'*}" == "$BEFORE" ]] || fail '拒绝分支推送仍变更远端'
  fi
  pass "${target} 推送失败真实返回非零"
done

printf 'RESULT pass=%s fail=0 evidence=%s\n' "$passes" "$BASE"
