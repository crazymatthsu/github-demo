#!/usr/bin/env bash
# test-git-version.sh — plain-bash tests for git-version.sh against throwaway git repositories.
#
# Usage: test-git-version.sh [<path to git-version.sh>]
#   Default: git-version.sh next to this file, else ../ci/git-version.sh (the layout of a repository that
#   keeps scripts in scripts/ci/ and tests in scripts/test/).
# Every case builds its own repository in a temp directory with an isolated git configuration and runs the
# script with an empty environment plus the variables the case sets, so the GITHUB_* variables of a CI
# runner never leak into a case.
# Needs: bash, git; python3 for the JSON case (skipped without it).
# Exit codes: 0 all cases passed · 1 a case failed · 2 usage (git-version.sh not found)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case ${1:-} in
  -h | --help) sed -n '2,/^# Exit codes/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
script=${1:-}
if [[ -z $script ]]; then
  for candidate in "$here/git-version.sh" "$here/../ci/git-version.sh"; do
    if [[ -f $candidate ]]; then script=$candidate; break; fi
  done
fi
[[ -n $script && -f $script ]] || { echo "test-git-version.sh: git-version.sh not found; pass its path" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"
# An isolated git: no user or system configuration (commit.gpgsign, tag.gpgSign, hooks...) reaches the cases.
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset GIT_DIR GIT_WORK_TREE

pass=0 fail=0
expect() { # expect <case> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    printf 'ok    %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
  fi
}
field() { sed -n "s/^$1=//p" <<<"$2"; } # field <KEY> <env output>

# gv [VAR=value...] -- [args...]: run git-version.sh with only PATH, HOME and the given variables set.
gv() {
  local envs=()
  while [[ $# -gt 0 && $1 != -- ]]; do envs+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  env -i PATH="$PATH" HOME="$HOME" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$tmp" \
    ${envs[@]+"${envs[@]}"} bash "$script" "$@"
}
main_ci=(GITHUB_ACTIONS=true GITHUB_REF=refs/heads/main)
rc_of() { # rc_of <gv arguments...>: the exit code only
  local rc=0
  gv "$@" >/dev/null 2>"$tmp/stderr" || rc=$?
  echo "$rc"
}

counter=0
R=""
new_repo() { # new_repo <name>: an empty repository on branch main, path in $R
  R="$tmp/$1"
  git init -q "$R"
  git -C "$R" symbolic-ref HEAD refs/heads/main
}
commit() { # commit <message> [file]: a real change to <file> (default a.txt) in $R
  local file=${2:-a.txt}
  counter=$((counter + 1))
  mkdir -p "$(dirname "$R/$file")"
  echo "$counter" >>"$R/$file"
  git -C "$R" add -A
  git -C "$R" commit -q -m "$1"
}
atag() { git -C "$R" tag -a "$1" -m "release $1"; } # annotated tag on HEAD
short() { git -C "$R" rev-parse HEAD | cut -c1-7; }

echo "# no tag yet"
new_repo notag
commit "feat: first"
commit "fix: second"
s=$(short)
out=$(gv -- -C "$R")
expect "no tag, laptop: version" "0.1.0-local.2.$s" "$(field VERSION "$out")"
expect "no tag, laptop: kind" local "$(field VERSION_KIND "$out")"
expect "no tag, laptop: image tags" "local,0.1.0-local.2.$s" "$(field IMAGE_TAGS "$out")"
expect "no tag, laptop: base and bump" ":initial" "$(field VERSION_BASE_TAG "$out"):$(field VERSION_BUMP "$out")"
out=$(gv "${main_ci[@]}" -- -C "$R")
expect "no tag, main: version" "0.1.0-rc.2" "$(field VERSION "$out")"
expect "no tag, main: image tags" "0.1.0-rc.2,sha-$s,main" "$(field IMAGE_TAGS "$out")"

echo "# release tag on HEAD"
new_repo tagged
commit "feat: one"
atag v1.4.2
s=$(short)
out=$(gv "${main_ci[@]}" -- -C "$R")
expect "tag at HEAD, main: version" "1.4.2" "$(field VERSION "$out")"
expect "tag at HEAD, main: kind" release "$(field VERSION_KIND "$out")"
expect "tag at HEAD, main: image tags" "1.4.2,sha-$s" "$(field IMAGE_TAGS "$out")"
expect "tag at HEAD, laptop: kind" release "$(gv -- -C "$R" --field kind)"
expect "tag at HEAD, tag ref (release workflow): version" "1.4.2" \
  "$(gv GITHUB_ACTIONS=true GITHUB_REF=refs/tags/v1.4.2 -- -C "$R" --field version)"
echo change >>"$R/a.txt"
out=$(gv -- -C "$R")
expect "tag at HEAD, dirty tree, laptop: version" "1.4.3-local.0.$s.dirty" "$(field VERSION "$out")"
expect "tag at HEAD, dirty tree: GIT_DIRTY" true "$(field GIT_DIRTY "$out")"
expect "tag at HEAD, dirty tree, laptop: image tags" "local,1.4.3-local.0.$s.dirty" "$(field IMAGE_TAGS "$out")"
expect "tag at HEAD, dirty tree, main: version" "1.4.3-rc.0" "$(gv "${main_ci[@]}" -- -C "$R" --field version)"
git -C "$R" checkout -q -- a.txt
touch "$R/untracked.txt"
expect "tag at HEAD, untracked file only: still the release" "1.4.2" "$(gv -- -C "$R" --field version)"
rm "$R/untracked.txt"
new_repo lightweight
commit "fix: x"
git -C "$R" tag v2.0.0
expect "lightweight tag at HEAD (release-please creates those): version" "2.0.0" "$(gv -- -C "$R" --field version)"

echo "# bump rules (Conventional Commits since the last tag, main context)"
bump_case() { # bump_case <case> <base tag> <expected version> <message>...
  local name=$1 base=$2 expected=$3
  shift 3
  new_repo "bump-$counter"
  commit "chore: base"
  atag "$base"
  local m
  for m in "$@"; do commit "$m"; done
  expect "$name" "$expected" "$(gv "${main_ci[@]}" -- -C "$R" --field version)"
}
bump_case "fix + chore -> patch" v1.4.1 1.4.2-rc.2 "fix: a" "chore: b"
bump_case "feat(scope) -> minor" v1.4.1 1.5.0-rc.3 "fix: a" "feat(source-kafka): b" "chore: c"
bump_case "feature: -> minor (as release-please)" v1.4.1 1.5.0-rc.1 "feature: x"
bump_case "feat! -> major" v1.4.1 2.0.0-rc.2 "fix: a" "feat!: drop the v1 API"
bump_case "type(scope)! -> major" v1.4.1 2.0.0-rc.1 "refactor(core)!: rename the keys"
bump_case "BREAKING CHANGE footer -> major" v1.4.1 2.0.0-rc.1 $'refactor(core): x\n\nBREAKING CHANGE: renamed keys'
bump_case "BREAKING-CHANGE footer -> major" v1.4.1 2.0.0-rc.1 $'fix: y\n\nBREAKING-CHANGE: z'
bump_case "BREAKING CHANGE inside a line is no footer -> patch" v1.4.1 1.4.2-rc.1 $'fix: y\n\nsee BREAKING CHANGE: in the docs'
bump_case "types are case-sensitive: Feat: -> patch" v1.4.1 1.4.2-rc.1 "Feat: capital"
bump_case "non-conventional subject -> patch" v1.4.1 1.4.2-rc.1 "Merge pull request #5 from someone/branch"
bump_case "breaking before 1.0 -> 1.0.0" v0.3.0 1.0.0-rc.1 "feat!: first stable API"
out=$(gv "${main_ci[@]}" -- -C "$R")
expect "VERSION_NEXT and VERSION_BUMP are reported" "1.0.0:major:v0.3.0:1" \
  "$(field VERSION_NEXT "$out"):$(field VERSION_BUMP "$out"):$(field VERSION_BASE_TAG "$out"):$(field VERSION_DISTANCE "$out")"

echo "# pull requests and merge queue"
new_repo prs
commit "chore: base"
atag v1.4.1
commit "feat: b"
s=$(short)
out=$(gv GITHUB_ACTIONS=true GITHUB_REF=refs/pull/123/merge -- -C "$R")
expect "pull request ref: version" "1.5.0-pr.123.$s" "$(field VERSION "$out")"
expect "pull request ref: kind" pr "$(field VERSION_KIND "$out")"
expect "pull request ref: image tags" "pr-123-$s" "$(field IMAGE_TAGS "$out")"
expect "PR_NUMBER wins over a branch ref (pull_request_target)" "1.5.0-pr.45.$s" \
  "$(gv GITHUB_ACTIONS=true GITHUB_REF=refs/heads/main PR_NUMBER=45 -- -C "$R" --field version)"
queue_sha=0123456789abcdef0123456789abcdef01234567
expect "merge queue ref is a PR build" "pr-77-$s" \
  "$(gv GITHUB_ACTIONS=true GITHUB_REF="refs/heads/gh-readonly-queue/main/pr-77-$queue_sha" -- -C "$R" --field tags)"
expect "merge queue ref with a slashed base branch" "pr-78-$s" \
  "$(gv GITHUB_ACTIONS=true GITHUB_REF="refs/heads/gh-readonly-queue/release/2.x/pr-78-$queue_sha" -- -C "$R" --field tags)"
expect "--pr on a laptop" "pr-9-$s" "$(gv -- -C "$R" --no-ci --pr 9 --field tags)"
expect "CI push to a feature branch is a local build" local \
  "$(gv GITHUB_ACTIONS=true GITHUB_REF=refs/heads/feature/x -- -C "$R" --field kind)"

echo "# hotfix branch"
new_repo hotfix
commit "feat: a"
atag v1.5.0
commit "feat: next on main"
git -C "$R" checkout -q -b hotfix/1.5.x v1.5.0
commit "feat: sneaky" h.txt
commit "fix: the bug" h.txt
s=$(short)
out=$(gv GITHUB_ACTIONS=true GITHUB_REF=refs/heads/hotfix/1.5.x -- -C "$R")
expect "hotfix: patch bump whatever the commits say" "1.5.1-rc.2" "$(field VERSION "$out")"
expect "hotfix: kind" hotfix "$(field VERSION_KIND "$out")"
expect "hotfix: image tags (no moving tag)" "1.5.1-rc.2,sha-$s" "$(field IMAGE_TAGS "$out")"
expect "--hotfix-prefix release/" hotfix \
  "$(gv GITHUB_ACTIONS=true GITHUB_REF=refs/heads/release/1.5 -- -C "$R" --hotfix-prefix release/ --field kind)"
git -C "$R" checkout -q main
expect "main after the hotfix branch point: minor" "1.6.0-rc.1" "$(gv "${main_ci[@]}" -- -C "$R" --field version)"

echo "# pre-release and malformed tags are never the base"
new_repo prerelease
commit "chore: base"
atag v1.4.2
commit "feat: a"
atag v1.5.0-rc.3
commit "fix: b"
for bad in v1.6 v01.2.3 v1.2.3foo v9.9.9.9 x3.0.0; do git -C "$R" tag "$bad"; done
out=$(gv "${main_ci[@]}" -- -C "$R")
expect "pre-release tag ignored: version" "1.5.0-rc.2" "$(field VERSION "$out")"
expect "pre-release tag ignored: base" v1.4.2 "$(field VERSION_BASE_TAG "$out")"
atag v1.5.0-rc.4
expect "a pre-release tag on HEAD is no release" "main:1.5.0-rc.2" \
  "$(gv "${main_ci[@]}" -- -C "$R" --field kind):$(gv "${main_ci[@]}" -- -C "$R" --field version)"

echo "# two version lines"
new_repo lines
commit "feat: app" app/x.txt
commit "feat: server" server/y.txt
atag v1.0.0
atag server/v0.3.0
commit "fix(app): y" app/x.txt
commit "feat(server): z" server/y.txt
commit "chore: readme" README.md
s=$(short)
expect "default line counts every commit: feat(server) -> minor" "1.1.0-rc.3" \
  "$(gv "${main_ci[@]}" -- -C "$R" --field version)"
expect "default line without the server path: patch, same <n>" "1.0.1-rc.3" \
  "$(gv "${main_ci[@]}" -- -C "$R" --path . --path ':(exclude)server' --field version)"
out=$(gv "${main_ci[@]}" -- -C "$R" --prefix server/v --path server)
expect "server line: own base and bump, <n> counts every commit" "0.4.0-rc.3:server/v0.3.0" \
  "$(field VERSION "$out"):$(field VERSION_BASE_TAG "$out")"
atag server/v0.4.0
out=$(gv "${main_ci[@]}" -- -C "$R" --prefix server/v --path server)
expect "server line released on HEAD" "release:0.4.0:0.4.0,sha-$s" \
  "$(field VERSION_KIND "$out"):$(field VERSION "$out"):$(field IMAGE_TAGS "$out")"
expect "default line unaffected by the server tag" "1.1.0-rc.3" "$(gv "${main_ci[@]}" -- -C "$R" --field version)"
atag my-server/v2.1.0
expect "a prefix with a dash finds its tags (describe --exclude '*-*' would not)" "2.1.0" \
  "$(gv "${main_ci[@]}" -- -C "$R" --prefix my-server/v --field version)"

echo "# main build of a commit that already carries its release tag"
new_repo ignore
commit "chore: base"
atag v1.4.2
commit "feat: x"
commit "fix: y"
atag v1.5.0
s=$(short)
expect "without --ignore-head-tags: the release form" "1.5.0" "$(gv "${main_ci[@]}" -- -C "$R" --field version)"
out=$(gv "${main_ci[@]}" -- -C "$R" --ignore-head-tags)
expect "--ignore-head-tags: the pre-release main built before the tag" "1.5.0-rc.2:1.5.0-rc.2,sha-$s,main:v1.4.2" \
  "$(field VERSION "$out"):$(field IMAGE_TAGS "$out"):$(field VERSION_BASE_TAG "$out")"

echo "# the highest release tag wins after an older hotfix line is merged back"
new_repo merged
commit "feat: a"
atag v1.4.2
commit "feat: b"
atag v1.5.0
git -C "$R" checkout -q -b hotfix/1.4.x v1.4.2
commit "fix: h" h.txt
atag v1.4.3
git -C "$R" checkout -q main
git -C "$R" merge -q --no-ff -m "Merge branch 'hotfix/1.4.x'" hotfix/1.4.x
out=$(gv "${main_ci[@]}" -- -C "$R")
expect "merged older hotfix: base and version" "v1.5.0:1.5.1-rc.2" \
  "$(field VERSION_BASE_TAG "$out"):$(field VERSION "$out")"

echo "# shallow clones, not a repository"
git clone -q --depth 1 "file://$tmp/tagged" "$tmp/shallow"
expect "shallow clone in CI: exit 4" 4 "$(rc_of "${main_ci[@]}" -- -C "$tmp/shallow")"
expect "shallow clone in CI with --allow-shallow: exit 0" 0 "$(rc_of "${main_ci[@]}" -- -C "$tmp/shallow" --allow-shallow)"
expect "shallow clone on a laptop: exit 0" 0 "$(rc_of -- -C "$tmp/shallow")"
expect "shallow clone on a laptop: a warning" 1 "$(grep -c 'shallow clone' "$tmp/stderr" || true)"
mkdir "$tmp/plain"
expect "not a git work tree: exit 3" 3 "$(rc_of -- -C "$tmp/plain")"
git init -q "$tmp/empty"
expect "no commit yet: exit 3" 3 "$(rc_of -- -C "$tmp/empty")"

echo "# usage"
R="$tmp/tagged"
expect "unknown option: exit 2" 2 "$(rc_of -- -C "$R" --bogus)"
expect "--pr not a number: exit 2" 2 "$(rc_of -- -C "$R" --pr abc)"
expect "PR_NUMBER not a number: exit 2" 2 "$(rc_of PR_NUMBER=abc -- -C "$R")"
expect "unknown --format: exit 2" 2 "$(rc_of -- -C "$R" --format xml)"
expect "unknown --field: exit 2" 2 "$(rc_of -- -C "$R" --field nope)"
expect "--prefix with a glob character: exit 2" 2 "$(rc_of -- -C "$R" --prefix 'v*')"
expect "--prefix without a value: exit 2" 2 "$(rc_of -- -C "$R" --prefix)"
expect "--help: exit 0" 0 "$(rc_of -- --help)"
expect "--help prints the usage" 1 "$(gv -- --help | grep -c '^Usage: git-version.sh')"

echo "# output formats"
R="$tmp/ignore"
s=$(short)
out=$(gv "${main_ci[@]}" -- -C "$R" --ignore-head-tags --format github)
expect "github: version line" "version=1.5.0-rc.2" "$(grep '^version=' <<<"$out")"
expect "github: tags as a JSON list" "tags=[\"1.5.0-rc.2\",\"sha-$s\",\"main\"]" "$(grep '^tags=' <<<"$out")"
expect "github: kind, sha7, base-tag, distance, next" "kind=main sha7=$s base-tag=v1.4.2 distance=2 next=1.5.0" \
  "$(grep -E '^(kind|sha7|base-tag|distance|next)=' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
expect "--field tags: one line, space-separated" "1.5.0-rc.2 sha-$s main" \
  "$(gv "${main_ci[@]}" -- -C "$R" --ignore-head-tags --field tags)"
expect "--field distance" 2 "$(gv "${main_ci[@]}" -- -C "$R" --ignore-head-tags --field distance)"
if command -v python3 >/dev/null 2>&1; then
  json=$(gv "${main_ci[@]}" -- -C "$R" --ignore-head-tags --format json)
  expect "json: parses, typed fields" "1.5.0-rc.2|main|['1.5.0-rc.2', 'sha-$s', 'main']|False|2|v1.4.2|minor" \
    "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print("|".join(str(d[k]) for k in ("version","kind","tags","dirty","distance","base_tag","bump")))' <<<"$json")"
else
  echo "skip  json output (python3 not found)"
fi

echo "# override, tag sanitising, branch names"
out=$(gv "${main_ci[@]}" -- -C "$R" --ignore-head-tags --override 9.9.9)
expect "--override keeps the kind and the tag rules" "9.9.9:main:9.9.9,sha-$s,main" \
  "$(field VERSION "$out"):$(field VERSION_KIND "$out"):$(field IMAGE_TAGS "$out")"
expect "tags follow the Docker grammar (+ becomes -)" "local 1.0.0-build.7" \
  "$(gv -- -C "$R" --ignore-head-tags --override '1.0.0+build.7' --field tags)"
expect "tags never start with . or -" "local x.1" "$(gv -- -C "$R" --ignore-head-tags --override '-.x.1' --field tags)"
expect "--ref accepts a bare branch name" main "$(gv -- -C "$R" --ignore-head-tags --ci --ref main --field kind)"
expect "--main-branch trunk: kind main, moving tag trunk" "1.5.0-rc.2 sha-$s trunk" \
  "$(gv -- -C "$R" --ignore-head-tags --ci --ref trunk --main-branch trunk --field tags)"

echo
echo "passed $pass, failed $fail"
((fail == 0))
