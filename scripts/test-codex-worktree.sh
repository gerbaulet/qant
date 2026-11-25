#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
source_script=$script_directory/codex-worktree.sh
test_root=$(mktemp -d "${TMPDIR:-/tmp}/quant-codex-worktree-test.XXXXXX")

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'test-codex-worktree: %s\n' "$1" >&2
    exit 1
}

value_from_output() {
    key=$1
    printf '%s\n' "$2" | sed -n "s/^$key=//p"
}

run_script() {
    checkout=$1
    shift
    (
        cd "$checkout"
        ./scripts/codex-worktree.sh "$@"
    )
}

assert_file_contains() {
    expected=$1
    file=$2
    grep -F "$expected" "$file" >/dev/null ||
        fail "$file does not contain expected text: $expected"
}

repository=$test_root/repository
worktree_root=$test_root/worktrees
mkdir -p "$repository/scripts"
cp "$source_script" "$repository/scripts/codex-worktree.sh"
chmod +x "$repository/scripts/codex-worktree.sh"

git -C "$repository" init -b main >/dev/null
git -C "$repository" config user.name 'Codex Worktree Test'
git -C "$repository" config user.email 'codex-worktree-test@example.invalid'
printf 'base\n' >"$repository/base.txt"
git -C "$repository" add base.txt scripts/codex-worktree.sh
git -C "$repository" commit -m 'Initial commit' >/dev/null

export QUANT_WORKTREE_ROOT=$worktree_root

create_one=$(run_script "$repository" create first-change)
worktree_one=$(value_from_output WORKTREE_PATH "$create_one")
branch_one=$(value_from_output WORKTREE_BRANCH "$create_one")
[ -d "$worktree_one" ] || fail 'first worktree was not created'

printf 'first\n' >"$worktree_one/first.txt"
git -C "$worktree_one" add first.txt
git -C "$worktree_one" commit -m 'Add first file' >/dev/null
run_script "$worktree_one" prepare >/dev/null
run_script "$worktree_one" finish >/dev/null

[ ! -e "$worktree_one" ] || fail 'first worktree was not removed'
git -C "$repository" show-ref --verify --quiet "refs/heads/$branch_one" &&
    fail 'first temporary branch was not deleted'
assert_file_contains first "$repository/first.txt"

create_two=$(run_script "$repository" create second-change)
create_three=$(run_script "$repository" create third-change)
worktree_two=$(value_from_output WORKTREE_PATH "$create_two")
worktree_three=$(value_from_output WORKTREE_PATH "$create_three")
branch_three=$(value_from_output WORKTREE_BRANCH "$create_three")

printf 'second\n' >"$worktree_two/second.txt"
git -C "$worktree_two" add second.txt
git -C "$worktree_two" commit -m 'Add second file' >/dev/null
printf 'third\n' >"$worktree_three/third.txt"
git -C "$worktree_three" add third.txt
git -C "$worktree_three" commit -m 'Add third file' >/dev/null

run_script "$worktree_two" prepare >/dev/null
run_script "$worktree_three" prepare >/dev/null
run_script "$worktree_two" finish >/dev/null

set +e
run_script "$worktree_three" finish >/dev/null 2>&1
stale_result=$?
set -e
[ "$stale_result" -eq 75 ] ||
    fail "stale integration returned $stale_result instead of 75"
[ -d "$worktree_three" ] || fail 'stale worktree was removed'
git -C "$repository" show-ref --verify --quiet "refs/heads/$branch_three" ||
    fail 'stale branch was deleted'
[ ! -e "$repository/third.txt" ] ||
    fail 'stale branch unexpectedly changed main'

run_script "$worktree_three" prepare >/dev/null
run_script "$worktree_three" finish >/dev/null
assert_file_contains second "$repository/second.txt"
assert_file_contains third "$repository/third.txt"

create_four=$(run_script "$repository" create dirty-main)
worktree_four=$(value_from_output WORKTREE_PATH "$create_four")
branch_four=$(value_from_output WORKTREE_BRANCH "$create_four")
printf 'fourth\n' >"$worktree_four/fourth.txt"
git -C "$worktree_four" add fourth.txt
git -C "$worktree_four" commit -m 'Add fourth file' >/dev/null
run_script "$worktree_four" prepare >/dev/null

printf 'local user change\n' >>"$repository/base.txt"
set +e
run_script "$worktree_four" finish >/dev/null 2>&1
dirty_result=$?
set -e
[ "$dirty_result" -ne 0 ] || fail 'integration accepted a dirty main checkout'
[ -d "$worktree_four" ] || fail 'dirty-main failure removed the worktree'
git -C "$repository" show-ref --verify --quiet "refs/heads/$branch_four" ||
    fail 'dirty-main failure deleted the branch'
assert_file_contains 'local user change' "$repository/base.txt"
[ ! -e "$repository/fourth.txt" ] ||
    fail 'dirty-main failure unexpectedly changed main'

git -C "$repository" restore base.txt
run_script "$worktree_four" finish >/dev/null
assert_file_contains fourth "$repository/fourth.txt"

create_five=$(run_script "$repository" create lock-contention)
worktree_five=$(value_from_output WORKTREE_PATH "$create_five")
branch_five=$(value_from_output WORKTREE_BRANCH "$create_five")
printf 'fifth\n' >"$worktree_five/fifth.txt"
git -C "$worktree_five" add fifth.txt
git -C "$worktree_five" commit -m 'Add fifth file' >/dev/null
run_script "$worktree_five" prepare >/dev/null

common_directory=$(git -C "$repository" rev-parse \
    --path-format=absolute --git-common-dir)
lock_file=$common_directory/quant-main-integration.lock
lock_ready=$test_root/lock-ready

if [ -x /usr/bin/lockf ]; then
    /usr/bin/lockf -k "$lock_file" sh -c \
        'touch "$1"; sleep 2' sh "$lock_ready" &
    lock_process=$!
elif command -v flock >/dev/null 2>&1; then
    flock "$lock_file" sh -c \
        'touch "$1"; sleep 2' sh "$lock_ready" &
    lock_process=$!
else
    fail 'neither lockf nor flock is available for the contention test'
fi

while [ ! -e "$lock_ready" ]; do
    sleep 0.05
done

set +e
(
    export QUANT_INTEGRATION_LOCK_TIMEOUT=0
    run_script "$worktree_five" finish >/dev/null 2>&1
)
locked_result=$?
set -e
[ "$locked_result" -eq 75 ] ||
    fail "locked integration returned $locked_result instead of 75"
[ -d "$worktree_five" ] || fail 'locked integration removed the worktree'
git -C "$repository" show-ref --verify --quiet "refs/heads/$branch_five" ||
    fail 'locked integration deleted the branch'
[ ! -e "$repository/fifth.txt" ] ||
    fail 'locked integration unexpectedly changed main'

wait "$lock_process"
run_script "$worktree_five" finish >/dev/null
assert_file_contains fifth "$repository/fifth.txt"

[ -z "$(git -C "$repository" status --porcelain)" ] ||
    fail 'main checkout is not clean after integration tests'
[ "$(git -C "$repository" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] ||
    fail 'temporary worktrees remain after integration tests'

printf 'Codex worktree integration tests passed.\n'
