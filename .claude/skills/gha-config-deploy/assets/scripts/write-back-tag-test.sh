#!/usr/bin/env bash
# write-back-tag-test.sh — plain-bash test of write-back-tag.sh against a throwaway bare remote: tag and placement
# edits, commit message and author, idempotency, the push race (the branch moves during the push), a rejected push
# that is not a race (a protected branch), a shallow clone like actions/checkout makes, refusals and exit codes.
# Nothing outside a temporary directory is touched; no network. Part of the gha-config-deploy skill.
#
# Usage: write-back-tag-test.sh [--help] [<path to write-back-tag.sh>]   (default: next to this file)
#   Needs git and mikefarah yq v4 (as `yq`, or WRITE_BACK_YQ=<path>).
# Exit codes: 0 every case passed · 1 a case failed · 2 usage · 5 a tool is missing
set -euo pipefail

case "${1:-}" in
    -h | --help)
        sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac
[ $# -le 1 ] || { echo "usage: $0 [<path to write-back-tag.sh>]" >&2; exit 2; }
SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/write-back-tag.sh}"
[ -f "$SCRIPT" ] || { echo "write-back-tag-test: $SCRIPT not found" >&2; exit 2; }
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"
YQ="${WRITE_BACK_YQ:-yq}"
command -v git >/dev/null 2>&1 || { echo "write-back-tag-test: git is needed" >&2; exit 5; }
"$YQ" --version 2>/dev/null | grep -q mikefarah || { echo "write-back-tag-test: mikefarah yq v4 is needed (WRITE_BACK_YQ)" >&2; exit 5; }
export WRITE_BACK_YQ="$YQ"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The runner's own identity must not leak into the cases (the run URL is tested explicitly).
unset GITHUB_RUN_ID GITHUB_REPOSITORY GITHUB_SERVER_URL WRITE_BACK_PLACEMENTS WRITE_BACK_KINDS WRITE_BACK_PUSH || true
git_test() { git -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@"; }

OUT="" ERR="" RC=0
run() { # <dir> <command...>: runs the command in <dir>, capturing stdout, stderr and the exit code
    local dir="$1"
    shift
    RC=0
    (cd "$dir" && "$@") >"$WORK/out" 2>"$WORK/err" || RC=$?
    OUT="$(cat "$WORK/out")" ERR="$(cat "$WORK/err")"
}
FAILED=0 CASE=""
fail() {
    printf 'FAIL %s: %s\n  stdout: %s\n  stderr: %s\n' "$CASE" "$1" "$OUT" "$ERR"
    FAILED=$((FAILED + 1))
    return 1
}
expect_rc() { [ "$RC" -eq "$1" ] || fail "exit code $RC, expected $1"; }
expect_in() { case "$2" in *"$1"*) ;; *) fail "expected '$1' in: $2" ;; esac; }
remote_show() { git -C "$G/remote.git" show "main:$1"; }
commits() { git -C "$G/remote.git" rev-list --count main; }

# A remote with a minimal dev tree: flow f1, app app1, instance one (compose, pooled, both renderings) and
# instance two (helm only: values.yaml, no compose.env). Sets G; the clone is $G/clone.
fixture() {
    G="$WORK/$1"
    local c="$G/clone/config/dev/f1"
    git init -q --bare "$G/remote.git"
    git -C "$G/remote.git" symbolic-ref HEAD refs/heads/main
    mkdir -p "$c/app1/one" "$c/app1/two"
    cat >"$c/workflows-config.yml" <<'EOF'
env: dev
flow: f1
pool: # the boxes
  hosts:
    - box-1.example.com
    - box-2.example.com
defaults:
  kind: helm
  cluster: dev
targets:
  - instance: app1/one # compose on the pool
    kind: compose
  - instance: app1/two
EOF
    printf '# compose variables\nIMAGE_REPO=registry.example.com/team\nIMAGE_TAG=0.0.1\nAPP_ENV=dev\n' >"$c/app1/one/compose.env"
    printf 'image:\n  tag: "0.0.1" # written back\nenv:\n  APP_ENV: dev\n' >"$c/app1/one/values.yaml"
    printf 'image:\n  tag: "0.0.1"\n' >"$c/app1/two/values.yaml"
    git -C "$G/clone" init -q
    git -C "$G/clone" checkout -q -b main
    git -C "$G/clone" add -A
    git_test -C "$G/clone" commit -q -m fixture
    git -C "$G/clone" remote add origin "$G/remote.git"
    git -C "$G/clone" push -q origin main 2>/dev/null
}

CASE=help
run "$WORK" "$SCRIPT" --help
expect_rc 0 && expect_in "Usage: write-back-tag.sh" "$OUT" && echo "ok   $CASE"

CASE=usage
run "$WORK" "$SCRIPT" dev
expect_rc 2 && echo "ok   $CASE"

fixture main-case
CASE=refuses-qa-and-prod
run "$G/clone" "$SCRIPT" us-qa 1.0.0 f1/app1/one && expect_rc 3 &&
    run "$G/clone" "$SCRIPT" prod 1.0.0 f1/app1/one && expect_rc 3 && expect_in "bump pull requests" "$ERR" && echo "ok   $CASE"

CASE=invalid-tag
run "$G/clone" "$SCRIPT" dev 'not a tag' f1/app1/one
expect_rc 2 && echo "ok   $CASE"

CASE=writes-tag-and-placement
before="$(commits)"
run "$G/clone" env WRITE_BACK_PLACEMENTS="f1/app1/one=box-2.example.com f1/app1/gone=box-1.example.com" \
    "$SCRIPT" dev 1.2.3 f1/app1/one f1/app1/two
{
    expect_rc 0 &&
        expect_in "f1/app1/gone was not deployed" "$ERR" &&
        expect_in "IMAGE_TAG=1.2.3" "$(remote_show config/dev/f1/app1/one/compose.env)" &&
        [ "$("$YQ" '.image.tag' <<<"$(remote_show config/dev/f1/app1/one/values.yaml)")" = 1.2.3 ] &&
        [ "$("$YQ" '.image.tag' <<<"$(remote_show config/dev/f1/app1/two/values.yaml)")" = 1.2.3 ] &&
        [ "$("$YQ" '.targets[0].host' <<<"$(remote_show config/dev/f1/workflows-config.yml)")" = box-2.example.com ] &&
        [ "$(commits)" -eq $((before + 1)) ] &&
        # every edit is a one-line change (yq keeps the comments and the layout of a file already in its layout)
        [ "$(git -C "$G/remote.git" diff main~1 main | grep -c '^[-+][^-+]')" -eq 7 ] &&
        expect_in "chore(config): dev deployed 1.2.3 [skip ci]" "$(git -C "$G/remote.git" log -1 --format=%s main)" &&
        expect_in "- dev/f1/app1/one on box-2.example.com" "$(git -C "$G/remote.git" log -1 --format=%b main)" &&
        expect_in "github-actions[bot]" "$(git -C "$G/remote.git" log -1 --format='%an %cn' main)" &&
        expect_in "# written back" "$(remote_show config/dev/f1/app1/one/values.yaml)" &&
        # the caller's checkout is not touched: the edits were made in a scratch worktree
        [ -z "$(git -C "$G/clone" status --porcelain)" ] &&
        expect_in "IMAGE_TAG=0.0.1" "$(cat "$G/clone/config/dev/f1/app1/one/compose.env")" &&
        echo "ok   $CASE"
} || true

CASE=idempotent
before="$(commits)"
run "$G/clone" env WRITE_BACK_PLACEMENTS="f1/app1/one=box-2.example.com" "$SCRIPT" dev 1.2.3 f1/app1/one f1/app1/two
expect_rc 0 && expect_in "nothing to write back" "$OUT" && { [ "$(commits)" -eq "$before" ] || fail "committed again"; } &&
    echo "ok   $CASE"

CASE=run-url-in-body
run "$G/clone" env GITHUB_RUN_ID=42 GITHUB_REPOSITORY=org/repo GITHUB_SERVER_URL=https://github.example.com \
    "$SCRIPT" dev 1.2.4 f1/app1/one
expect_rc 0 && expect_in "Run: https://github.example.com/org/repo/actions/runs/42" \
    "$(git -C "$G/remote.git" log -1 --format=%b main)" && echo "ok   $CASE"

CASE=instances-from-inventory-by-kind
run "$G/clone" env WRITE_BACK_KINDS=compose "$SCRIPT" dev 1.2.5
expect_rc 0 && expect_in "IMAGE_TAG=1.2.5" "$(remote_show config/dev/f1/app1/one/compose.env)" &&
    { [ "$("$YQ" '.image.tag' <<<"$(remote_show config/dev/f1/app1/two/values.yaml)")" = 1.2.3 ] || fail "the helm target was written"; } &&
    echo "ok   $CASE"

CASE=dry-run
before="$(commits)"
run "$G/clone" env WRITE_BACK_PUSH=false "$SCRIPT" dev 9.9.9 f1/app1/one
expect_rc 0 && expect_in "not pushed" "$OUT" && { [ "$(commits)" -eq "$before" ] || fail "pushed"; } && echo "ok   $CASE"

CASE=host-outside-pool
run "$G/clone" env WRITE_BACK_PLACEMENTS="f1/app1/one=elsewhere.example.com" "$SCRIPT" dev 1.2.6 f1/app1/one
expect_rc 4 && expect_in "not a box of the pool" "$ERR" && echo "ok   $CASE"

CASE=instance-without-files
run "$G/clone" "$SCRIPT" dev 1.2.6 f1/app1/missing
expect_rc 4 && echo "ok   $CASE"

CASE=race-reapplies-on-new-tip
# A pre-push hook lets another clone move main once, after the script fetched and before its push lands.
git clone -q "$G/remote.git" "$G/other" 2>/dev/null
cat >"$G/clone/.git/hooks/pre-push" <<EOF
#!/usr/bin/env bash
[ -f "$G/raced" ] && exit 0
touch "$G/raced"
cd "$G/other" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR bash -c '
  git pull -q --ff-only origin main && echo concurrent >README.md && git add README.md &&
  git -c user.name=human -c user.email=human@example.com -c commit.gpgsign=false commit -q -m "docs: concurrent" &&
  git push -q origin HEAD:main' >/dev/null 2>&1
EOF
chmod +x "$G/clone/.git/hooks/pre-push"
run "$G/clone" "$SCRIPT" dev 1.2.7 f1/app1/one
rm -f "$G/clone/.git/hooks/pre-push"
expect_rc 0 && expect_in "moved (attempt 1/3)" "$ERR" &&
    expect_in "docs: concurrent" "$(git -C "$G/remote.git" log -1 --format=%s main~1)" &&
    expect_in "IMAGE_TAG=1.2.7" "$(remote_show config/dev/f1/app1/one/compose.env)" && echo "ok   $CASE"

CASE=rejected-push-is-not-retried
printf '#!/bin/sh\necho "protected branch: pushes need a pull request" >&2\nexit 1\n' >"$G/remote.git/hooks/pre-receive"
chmod +x "$G/remote.git/hooks/pre-receive"
run "$G/clone" "$SCRIPT" dev 1.2.8 f1/app1/one
rm -f "$G/remote.git/hooks/pre-receive"
expect_rc 1 && expect_in "not a race" "$ERR" && expect_in "bypass" "$ERR" && expect_in "protected branch" "$ERR" &&
    echo "ok   $CASE"

CASE=shallow-clone
git clone -q --depth 1 "file://$G/remote.git" "$G/shallow" 2>/dev/null
run "$G/shallow" "$SCRIPT" dev 1.2.9 f1/app1/one
expect_rc 0 && expect_in "IMAGE_TAG=1.2.9" "$(remote_show config/dev/f1/app1/one/compose.env)" && echo "ok   $CASE"

CASE=values-without-image-mapping
(cd "$G/other" && git pull -q --ff-only origin main 2>/dev/null &&
    printf 'env:\n  APP_ENV: dev\n' >config/dev/f1/app1/two/values.yaml &&
    git add -A && git_test commit -q -m "no image" && git push -q origin HEAD:main 2>/dev/null)
run "$G/clone" "$SCRIPT" dev 2.0.0 f1/app1/two
expect_rc 4 && expect_in "no image mapping" "$ERR" && echo "ok   $CASE"

if [ "$FAILED" -gt 0 ]; then
    echo "write-back-tag-test: $FAILED case(s) failed"
    exit 1
fi
echo "write-back-tag-test: every case passed"
