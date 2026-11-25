#!/bin/sh

set -eu

target_branch=${QUANT_INTEGRATION_BRANCH:-main}
lock_timeout=${QUANT_INTEGRATION_LOCK_TIMEOUT:-55}

usage() {
    cat <<'EOF'
Usage:
  scripts/codex-worktree.sh create <task-slug>
  scripts/codex-worktree.sh prepare
  scripts/codex-worktree.sh finish [--no-push]

Commands:
  create   Create a uniquely named temporary branch and worktree.
  prepare  Rebase the current managed worktree onto the latest local main.
  finish   Fast-forward and push local main under a lock, then clean up.
EOF
}

fail() {
    printf 'codex-worktree: %s\n' "$1" >&2
    exit "${2:-1}"
}

common_git_dir() {
    git rev-parse --path-format=absolute --git-common-dir 2>/dev/null ||
        fail 'run this command from a checkout of the repository'
}

branch_worktree() {
    branch_ref="refs/heads/$1"
    git worktree list --porcelain | awk -v branch_ref="$branch_ref" '
        $1 == "worktree" {
            path = substr($0, 10)
        }
        $1 == "branch" && $2 == branch_ref {
            print path
        }
    '
}

require_single_path() {
    resolved_path=$1
    description=$2

    [ -n "$resolved_path" ] || fail "no worktree has $description checked out"
    case "$resolved_path" in
        *"
"*) fail "more than one worktree reported for $description" ;;
    esac
}

require_clean() {
    checkout_path=$1
    description=$2
    checkout_status=$(git -C "$checkout_path" status --porcelain)
    [ -z "$checkout_status" ] ||
        fail "$description is not clean; existing changes were left untouched"
}

require_main_checkout() {
    main_path=$(branch_worktree "$target_branch")
    require_single_path "$main_path" "branch $target_branch"

    checked_out_branch=$(git -C "$main_path" symbolic-ref --quiet --short HEAD) ||
        fail "the integration checkout is not on branch $target_branch"
    [ "$checked_out_branch" = "$target_branch" ] ||
        fail "the integration checkout is on $checked_out_branch, not $target_branch"

    printf '%s\n' "$main_path"
}

marker_name() {
    printf '%s\n' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

marker_path() {
    marker_directory=$(common_git_dir)/quant-codex-worktrees
    printf '%s/%s\n' "$marker_directory" "$(marker_name "$1")"
}

require_managed_worker() {
    worker_path=$(git rev-parse --show-toplevel 2>/dev/null) ||
        fail 'run this command from the managed worktree'
    worker_branch=$(git symbolic-ref --quiet --short HEAD) ||
        fail 'detached HEAD is not allowed; use the create command'

    case "$worker_branch" in
        codex/*) ;;
        *) fail "branch $worker_branch is not a managed Codex worktree branch" ;;
    esac

    worker_marker=$(marker_path "$worker_branch")
    [ -f "$worker_marker" ] ||
        fail "branch $worker_branch has no managed-worktree marker"

    marked_path=$(sed -n '1p' "$worker_marker")
    marked_branch=$(sed -n '2p' "$worker_marker")
    marked_target=$(sed -n '3p' "$worker_marker")

    [ "$marked_path" = "$worker_path" ] ||
        fail 'managed-worktree marker does not match the current path'
    [ "$marked_branch" = "$worker_branch" ] ||
        fail 'managed-worktree marker does not match the current branch'
    [ "$marked_target" = "$target_branch" ] ||
        fail "managed worktree targets $marked_target, not $target_branch"
}

require_one_commit_on_main() {
    commit_count=$(git -C "$worker_path" rev-list --count \
        "$target_branch..$worker_branch")
    [ "$commit_count" -eq 1 ] ||
        fail "expected exactly one commit for this worktree, found $commit_count"

    git -C "$worker_path" merge-base --is-ancestor \
        "$target_branch" "$worker_branch" ||
        fail "branch $worker_branch is not based on current $target_branch; run prepare again" 75
}

create_worktree() {
    [ "$#" -eq 1 ] || {
        usage >&2
        exit 64
    }

    task_slug=$1
    case "$task_slug" in
        ''|*[!a-z0-9-]*|-*|*-) fail 'task slug must use lowercase letters, numbers, and internal hyphens' 64 ;;
    esac

    main_path=$(require_main_checkout)
    require_clean "$main_path" "primary $target_branch checkout"

    base_commit=$(git -C "$main_path" rev-parse "$target_branch")
    worktree_root=${QUANT_WORKTREE_ROOT:-${TMPDIR:-/tmp}/quant-codex-worktrees}
    [ -n "$worktree_root" ] || fail 'worktree root must not be empty'
    [ "$worktree_root" != / ] || fail 'worktree root must not be the filesystem root'
    mkdir -p "$worktree_root"
    worktree_root=$(CDPATH= cd -- "$worktree_root" && pwd -P)

    repository_name=$(basename "$main_path")
    repository_name=$(printf '%s' "$repository_name" | tr -c 'A-Za-z0-9._-' '-')
    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    attempt=0

    while :; do
        unique_id="$task_slug-$timestamp-$$"
        [ "$attempt" -eq 0 ] || unique_id="$unique_id-$attempt"
        worker_branch="codex/$unique_id"
        worker_path="$worktree_root/$repository_name-$unique_id"

        if ! git show-ref --verify --quiet "refs/heads/$worker_branch" &&
            [ ! -e "$worker_path" ]; then
            break
        fi
        attempt=$((attempt + 1))
    done

    git -C "$main_path" worktree add -b "$worker_branch" \
        "$worker_path" "$target_branch"

    worker_marker=$(marker_path "$worker_branch")
    mkdir -p "$(dirname "$worker_marker")"
    marker_temporary="$worker_marker.tmp.$$"
    printf '%s\n%s\n%s\n' \
        "$worker_path" "$worker_branch" "$target_branch" >"$marker_temporary"
    mv "$marker_temporary" "$worker_marker"

    printf 'Created isolated Codex worktree.\n'
    printf 'WORKTREE_PATH=%s\n' "$worker_path"
    printf 'WORKTREE_BRANCH=%s\n' "$worker_branch"
    printf 'BASE_COMMIT=%s\n' "$base_commit"
}

prepare_worktree() {
    require_managed_worker
    main_path=$(require_main_checkout)
    [ "$worker_path" != "$main_path" ] ||
        fail 'prepare must run from the isolated worker checkout'

    require_clean "$main_path" "primary $target_branch checkout"
    require_clean "$worker_path" 'worker checkout'

    git -C "$worker_path" rebase "$target_branch"
    require_clean "$worker_path" 'rebased worker checkout'
    require_one_commit_on_main

    printf 'Prepared worktree on current %s. Run the relevant tests before finish.\n' \
        "$target_branch"
    printf 'MAIN_COMMIT=%s\n' "$(git -C "$main_path" rev-parse "$target_branch")"
    printf 'WORKER_COMMIT=%s\n' "$(git -C "$worker_path" rev-parse "$worker_branch")"
}

push_main_locked() {
    push_main_path=$1
    push_target_branch=$2
    push_mode=$3

    if [ "$push_mode" = disabled ]; then
        printf 'PUSH_STATUS=disabled\n'
        return
    fi

    push_remote=$(git -C "$push_main_path" config --get \
        "branch.$push_target_branch.remote" || true)
    push_ref=$(git -C "$push_main_path" config --get \
        "branch.$push_target_branch.merge" || true)

    if [ -z "$push_remote" ]; then
        if git -C "$push_main_path" remote get-url --push origin \
            >/dev/null 2>&1; then
            push_remote=origin
            push_ref="refs/heads/$push_target_branch"
        else
            printf 'PUSH_STATUS=skipped-no-remote\n'
            return
        fi
    fi

    if [ "$push_remote" = . ]; then
        printf 'PUSH_STATUS=skipped-local-upstream\n'
        return
    fi

    [ -n "$push_ref" ] || push_ref="refs/heads/$push_target_branch"

    if GIT_TERMINAL_PROMPT=0 git -C "$push_main_path" push \
        "$push_remote" "$push_target_branch:$push_ref"; then
        printf 'PUSH_STATUS=pushed\n'
        printf 'PUSH_REMOTE=%s\n' "$push_remote"
        printf 'PUSH_REF=%s\n' "$push_ref"
    else
        printf 'codex-worktree: push to %s failed; commit remains on local %s\n' \
            "$push_remote" "$push_target_branch" >&2
        printf 'PUSH_STATUS=failed\n'
        printf 'PUSH_REMOTE=%s\n' "$push_remote"
        printf 'PUSH_REF=%s\n' "$push_ref"
    fi
}

fast_forward_locked() {
    [ "$#" -eq 6 ] || fail 'invalid internal fast-forward invocation' 64

    locked_main_path=$1
    locked_worker_path=$2
    locked_worker_branch=$3
    expected_worker_head=$4
    locked_target_branch=$5
    push_mode=$6

    current_main_branch=$(git -C "$locked_main_path" \
        symbolic-ref --quiet --short HEAD) ||
        fail 'integration checkout became detached'
    [ "$current_main_branch" = "$locked_target_branch" ] ||
        fail "integration checkout left branch $locked_target_branch"

    require_clean "$locked_main_path" "primary $locked_target_branch checkout"
    require_clean "$locked_worker_path" 'worker checkout'

    current_worker_head=$(git -C "$locked_worker_path" \
        rev-parse "$locked_worker_branch")
    [ "$current_worker_head" = "$expected_worker_head" ] ||
        fail 'worker branch changed while waiting for the integration lock' 75

    current_main_head=$(git -C "$locked_main_path" \
        rev-parse "$locked_target_branch")
    worker_parent=$(git -C "$locked_worker_path" rev-parse "$expected_worker_head^")
    [ "$worker_parent" = "$current_main_head" ] ||
        fail "$locked_target_branch advanced; run prepare and tests again" 75

    git -C "$locked_main_path" merge --ff-only "$locked_worker_branch"
    integrated_head=$(git -C "$locked_main_path" rev-parse "$locked_target_branch")
    [ "$integrated_head" = "$expected_worker_head" ] ||
        fail 'fast-forward did not produce the expected integration commit'

    push_main_locked "$locked_main_path" "$locked_target_branch" "$push_mode"
}

run_with_lock() {
    lock_file=$1
    shift

    if [ -x /usr/bin/lockf ]; then
        /usr/bin/lockf -k -t "$lock_timeout" "$lock_file" "$@"
        return
    fi

    if command -v flock >/dev/null 2>&1; then
        flock -w "$lock_timeout" "$lock_file" "$@"
        return
    fi

    fail 'neither lockf nor flock is available for safe integration'
}

finish_worktree() {
    push_mode=enabled
    case "$#" in
        0) ;;
        1)
            [ "$1" = --no-push ] || fail 'finish only accepts --no-push' 64
            push_mode=disabled
            ;;
        *) fail 'finish only accepts --no-push' 64 ;;
    esac

    require_managed_worker
    main_path=$(require_main_checkout)
    [ "$worker_path" != "$main_path" ] ||
        fail 'finish must run from the isolated worker checkout'

    require_clean "$worker_path" 'worker checkout'
    require_one_commit_on_main
    worker_head=$(git -C "$worker_path" rev-parse "$worker_branch")

    script_path=$(CDPATH= cd -- "$(dirname "$0")" && pwd)/$(basename "$0")
    lock_file=$(common_git_dir)/quant-main-integration.lock

    run_with_lock "$lock_file" "$script_path" __fast-forward \
        "$main_path" "$worker_path" "$worker_branch" "$worker_head" \
        "$target_branch" "$push_mode" || {
            result=$?
            [ "$result" -ne 75 ] ||
                printf '%s\n' \
                    'codex-worktree: integration changed or stayed busy; run prepare, tests, and finish again' >&2
            exit "$result"
        }

    cd "$main_path"
    git merge-base --is-ancestor "$worker_head" "$target_branch" ||
        fail "integrated commit is no longer reachable from $target_branch"

    git worktree remove "$worker_path"
    git branch -d "$worker_branch"
    rm -f "$worker_marker"

    printf 'Integrated and removed isolated Codex worktree.\n'
    printf 'MAIN_COMMIT=%s\n' "$worker_head"
    printf 'REMOVED_WORKTREE=%s\n' "$worker_path"
    printf 'DELETED_BRANCH=%s\n' "$worker_branch"
}

command_name=${1:-}
[ "$#" -gt 0 ] && shift

case "$command_name" in
    create) create_worktree "$@" ;;
    prepare)
        [ "$#" -eq 0 ] || fail 'prepare takes no arguments' 64
        prepare_worktree
        ;;
    finish)
        finish_worktree "$@"
        ;;
    __fast-forward) fast_forward_locked "$@" ;;
    -h|--help|help) usage ;;
    *)
        usage >&2
        exit 64
        ;;
esac
