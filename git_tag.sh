#!/bin/bash

set -e

cd -- "$(git rev-parse --show-toplevel)"
VersionFile=./VERSION
[[ -f "$VersionFile" && ! -L "$VersionFile" ]] || { echo "缺少 VERSION" >&2; exit 1; }
CURRENT_VERSION=$(tr -d '[:space:]' <"$VersionFile")
[[ "$CURRENT_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] \
    || { echo "VERSION 非法: ${CURRENT_VERSION}" >&2; exit 1; }

NEXT_VERSION=""

function to_run() {
    if [ -z "$1" ] || [ "$1" == "auto" ]; then
        baseStr=$(echo "${CURRENT_VERSION}" | cut -d'.' -f1)     # Get the base version (v0)
        base=${baseStr//v/}                                       # Get the base version (0)
        major=$(echo "${CURRENT_VERSION}" | cut -d'.' -f2)       # Get the major version (0)
        minor=$(echo "${CURRENT_VERSION}" | cut -d'.' -f3)       # Get the minor version (1)

        minor=$((minor+1))                          # Increment the minor version
        if ((minor==1000)); then                     # Check if minor version is 100
            minor=0                                 # Reset minor version to 0
            major=$((major+1))                      # Increment major version
        fi

        if ((major==1000)); then                     # Check if major version is 100
            major=0                                 # Reset major version to 0
            base=$((base+1))                        # Increment base version
        fi

        NEXT_VERSION="v${base}.${major}.${minor}"
        return 0
    else
        return 1
    fi
}

function get_pre_del_version_no {
    local v_str=$1
    baseStr=$(echo "$v_str" | cut -d'.' -f1)     # Get the base version (v0)
    base=${baseStr//v/}                                       # Get the base version (0)
    major=$(echo "$v_str" | cut -d'.' -f2)       # Get the major version (0)
    minor=$(echo "$v_str" | cut -d'.' -f3)       # Get the minor version (1)

    if ((minor>0)); then                      # Check if minor version is more than 0
        minor=$((minor-1))                     # Decrement the minor version
    else
        minor=999                              # Reset minor version to 99
        if ((major>0)); then                   # Check if major version is more than 0
            major=$((major-1))                 # Decrement major version
        else
            major=999                           # Reset major version to 99
            if ((base>0)); then                # Check if base version is more than 0
                base=$((base-1))               # Decrement base version
            else
                echo "Error: Version cannot be decremented."
                exit 1
            fi
        fi
    fi

    pre_v_no="${base}.${major}.${minor}"
    echo "$pre_v_no"
}

function git_handle_ready() {
    echo "Current Version With ${CURRENT_VERSION}"
    echo "Next Version With ${NEXT_VERSION}"

    [[ -z "$(git status --porcelain)" ]] || { echo "工作区不干净，拒绝" >&2; return 1; }
    [[ -n "$(git config --get user.name)" && -n "$(git config --get user.email)" ]] \
        || { echo "缺少 Git 提交身份" >&2; return 1; }
    if git show-ref --verify --quiet "refs/tags/${NEXT_VERSION}"; then
        echo "标签已存在: ${NEXT_VERSION}" >&2
        return 1
    fi
    printf '%s\n' "${NEXT_VERSION#v}" >"$VersionFile"
}

function find_prev_release_commit() {
    git log --fixed-strings --grep='Release:--:' --format='%H' -n 1 HEAD || true
}

function gen_changelog_if_possible() {
    local out_dir out_file prev_release_sha range_end range
    out_dir="changelog"
    mkdir -p "${out_dir}" || return

    out_file="${out_dir}/${NEXT_VERSION}.md"

    prev_release_sha="$(find_prev_release_commit)"
    range_end="HEAD"

    if [ -z "${prev_release_sha}" ]; then
        prev_release_sha="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
        range="${prev_release_sha}..${range_end}"
        echo "[changelog] no previous Release marker found, use range ${range}"
    else
        range="${prev_release_sha}..${range_end}"
        echo "[changelog] previous Release marker: ${prev_release_sha}"
    fi

    local commit_count
    commit_count="$(git rev-list --count "${range}" 2>/dev/null || echo 0)"

    {
        echo "## ${NEXT_VERSION} ChangeLog"
        echo
        echo "- Release:--: ${NEXT_VERSION}_$(date -u +"%Y-%m-%d_%H:%M:%S")_UTC"
        echo "- Range: ${range}"
        echo "- Commits: ${commit_count}"
        echo

        echo "###  commit infos"
        echo
        if [[ "${commit_count}" == "0" ]]; then
            echo "- (no commits between releases)"
            echo "- (no file changes)"
        else
            local shortstat
            shortstat="$(git diff --shortstat "${range}" 2>/dev/null || true)"
            if [ -n "${shortstat}" ]; then
                echo "- ${shortstat}"
            else
                echo "- (no file changes)"
            fi
            echo
            echo '```'
            git diff --stat "${range}" 2>/dev/null || true
            echo '```'
        fi
        echo

        echo "### commit messages"
        echo
        if [[ "${commit_count}" == "0" ]]; then
            echo "- (no commits between releases)"
        else
            git log --reverse --date=short --pretty=format:"- %ad %h %s" "${range}" || true
        fi
        echo
    } > "${out_file}" || return

    echo "[changelog] wrote ${out_file}"
}

function git_handle_push() {
    local current_version_no=${CURRENT_VERSION//v/}
    local next_version_no=${NEXT_VERSION//v/}
    local pre_del_version_no="" branch_ref remote_latest remote_latest_sha
    branch_ref=$(git symbolic-ref --quiet HEAD) || { echo "拒绝 detached HEAD 发版" >&2; return 1; }
    if [[ "$current_version_no" != "0.0.0" ]]; then
        pre_del_version_no=$(get_pre_del_version_no "$current_version_no") || return
    fi
    echo "Pre Del Version With v${pre_del_version_no}"

    gen_changelog_if_possible \
    && git add -- "${VersionFile}" "changelog/${NEXT_VERSION}.md" \
    && git commit -m "Release:--: v${next_version_no}_$(date -u +"%Y-%m-%d_%H:%M:%S")_UTC" \
    && git tag "v${next_version_no}" \
    && git tag -f latest "v${next_version_no}" \
    || return

    for remote in $(git remote)
    do
        echo "Pushing to ${remote}..."
        remote_latest=$(git ls-remote --exit-code "$remote" refs/tags/latest) || {
            local rc=$?
            [[ "$rc" -eq 2 ]] || return "$rc"
        }
        remote_latest_sha="${remote_latest%%$'\t'*}"
        # 原子更新三个 refs；latest 仅允许替换刚读到的旧值，新版本 tag 仅允许创建。
        # 分支仍受普通 fast-forward 保护；服务不支持 atomic 或任一 ref 竞争则全部失败，不降级拆推。
        git push --atomic \
            --force-with-lease="refs/tags/latest:${remote_latest_sha}" \
            --force-with-lease="refs/tags/v${next_version_no}:" \
            "$remote" "HEAD:${branch_ref}" \
            refs/tags/latest:refs/tags/latest \
            "refs/tags/v${next_version_no}:refs/tags/v${next_version_no}" \
            || return
    done
    if [[ -n "$pre_del_version_no" ]] && git show-ref --verify --quiet "refs/tags/v${pre_del_version_no}"; then
        git tag -d "v${pre_del_version_no}" || return
    fi
}

handle_input(){
    local mode="${1:-}"
    if [[ $# -gt 1 ]]; then
        echo "只接受无参数、auto 或 -get_pre_del_tag_name" >&2
        return 1
    fi
    if [[ "$mode" == "--help" || "$mode" == "-h" ]]; then
        echo "用法: git_tag.sh [auto|-get_pre_del_tag_name]；无参数等价 auto" >&2
        return 2
    elif [[ "$mode" == "-get_pre_del_tag_name" ]]; then
        pre_tag=$(get_pre_del_version_no "${CURRENT_VERSION}")
        echo "Pre Del Tag With " "$pre_tag"
    elif [ -z "$mode" ] || [ "$mode" == "auto" ]; then

        if to_run "$mode"; then
            git_handle_ready || return
            git_handle_push || return
            echo "Complated"
        else
            echo "Invalid argument normal"
            return 1
        fi
    else
        echo "Invalid argument: ${mode}" >&2
        return 1
    fi
}

handle_input "$@"
