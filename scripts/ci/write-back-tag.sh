#!/usr/bin/env bash
# write-back-tag.sh — record the deployed image tag in the dev config tree (D9 §6.4, D5 §6.8, DL-36).
#
# Usage: write-back-tag.sh <env> <tag> [<flow>/<AppName>/<AppInstance>...]
#   Sets the tag in both files of every deployed instance under config/<env>/<flow>/<AppName>/<AppInstance>/:
#   IMAGE_TAG=<tag> in compose.env and image.tag in values.yaml (demo step 2; skipped while an instance has
#   no values.yaml), so the two always agree (config-lint check 4) whether compose or Helm deployed it.
#   The instances are the ones given, or else every target in config/<env>/targets.yml whose effective
#   kind (target `kind`, else `defaults.kind`, else compose) is listed in WRITE_BACK_KINDS. On top of the
#   current tip of the branch it commits
#       chore(config): <env> deployed <tag> [skip ci]
#   as github-actions[bot] and pushes it to the branch. `[skip ci]` plus the actor check in main.yml
#   form the loop guard (DL-36). Idempotent: no commit when every file already carries the tag.
#   Only *-dev envs are accepted: qa and prod change through reviewed bump PRs, never through here.
#
# Environment: WRITE_BACK_BRANCH (main) · WRITE_BACK_REMOTE (origin) · WRITE_BACK_KINDS (compose,helm)
#   WRITE_BACK_PUSH (true; false commits in a scratch worktree only — for tests and dry runs)
#   WRITE_BACK_ATTEMPTS (3: re-applied on a fresh tip when the push loses a race)
#   values.yaml is edited with mikefarah yq v4 (preinstalled on GitHub-hosted runners).
# Exit codes: 0 written, or nothing to write · 1 git, push or yq failure · 2 usage · 3 refused (env is
#   not *-dev) · 4 config tree error (targets.yml or an instance's compose.env missing, or a values.yaml
#   without an image.tag to set).
#
# TODO(DL-09): the enterprise identity is a GitHub App installation token (actor <app>[bot], allowed
# to bypass the `main` ruleset); then main.yml's loop guard must name that actor instead.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bot_name="github-actions[bot]"
bot_email="41898282+github-actions[bot]@users.noreply.github.com"

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
env_name=$1
tag=$2
shift 2
branch=${WRITE_BACK_BRANCH:-main}
remote=${WRITE_BACK_REMOTE:-origin}
kinds=${WRITE_BACK_KINDS:-compose,helm}
push=${WRITE_BACK_PUSH:-true}
attempts=${WRITE_BACK_ATTEMPTS:-3}

[[ $env_name =~ ^[a-z][a-z0-9]*-dev$ ]] ||
  { echo "write-back-tag.sh: refused: '$env_name' is not a *-dev env (qa / prod change through bump PRs)" >&2; exit 3; }
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "write-back-tag.sh: invalid tag '$tag'" >&2; exit 2; }

root=$(git rev-parse --show-toplevel)
cd "$root"

# --- which instances were deployed ------------------------------------------------------------
instances=("$@")
if [[ ${#instances[@]} -eq 0 ]]; then
  targets="config/$env_name/targets.yml"
  [[ -f $targets ]] || { echo "write-back-tag.sh: $targets not found and no instances given" >&2; exit 4; }
  # shellcheck disable=SC2016 # $d is a yq variable
  query='(.defaults.kind // "compose") as $d | .targets[] | [.instance, (.kind // $d)] | @tsv'
  while IFS=$'\t' read -r instance kind; do
    [[ -n $instance ]] || continue
    if [[ ",$kinds," == *",$kind,"* ]]; then
      instances+=("$instance")
    fi
  done < <(yq "$query" "$targets")
fi
if [[ ${#instances[@]} -eq 0 ]]; then
  echo "write-back-tag.sh: no deployed instances of kind '$kinds' in $env_name — nothing to write back"
  exit 0
fi
for instance in "${instances[@]}"; do
  [[ $instance =~ ^[a-z0-9-]+/[a-z0-9-]+/[a-z0-9-]+$ ]] ||
    { echo "write-back-tag.sh: '$instance' is not <flow>/<AppName>/<AppInstance>" >&2; exit 2; }
done

# --- apply on the current tip, in a scratch worktree (the caller's checkout stays untouched) -----
worktree=$(mktemp -d)
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { git worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf "$worktree"; }
trap cleanup EXIT

fetch_tip() {
  local depth=()
  [[ $(git rev-parse --is-shallow-repository) == true ]] && depth=(--depth=1)
  git fetch --quiet "${depth[@]}" "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch"
}

apply() { # prints the changed files
  local files=() values=() instance dir file
  for instance in "${instances[@]}"; do
    dir="$worktree/config/$env_name/$instance"
    [[ -f $dir/compose.env ]] || { echo "write-back-tag.sh: config/$env_name/$instance/compose.env not found on $branch" >&2; return 4; }
    files+=("$dir/compose.env")
    if [[ -f $dir/values.yaml ]]; then
      files+=("$dir/values.yaml")
      values+=("$dir/values.yaml")
    fi
  done
  if [[ ${#values[@]} -gt 0 ]] && ! yq --version 2>/dev/null | grep -q mikefarah; then
    echo "write-back-tag.sh: updating values.yaml needs mikefarah yq v4 on PATH (as on GitHub-hosted runners)" >&2
    return 1
  fi
  "$here/set-image-tag.sh" "$tag" "${files[@]}" || return
  # set-image-tag.sh edits image.tag only under an existing `image:` mapping; both files must now agree.
  for file in ${values[@]+"${values[@]}"}; do
    if [[ $(yq '.image.tag // ""' "$file") != "$tag" ]]; then
      echo "write-back-tag.sh: ${file#"$worktree"/} has no image.tag to set (add image: {tag: ...}, D11 §6.2)" >&2
      return 4
    fi
  done
}

subject="chore(config): $env_name deployed $tag [skip ci]"
body="Deployed instances:"
for instance in "${instances[@]}"; do body+=$'\n'"- $env_name/$instance"; done
if [[ -n ${GITHUB_RUN_ID:-} ]]; then
  body+=$'\n\n'"Run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}"
fi

fetch_tip
git worktree add --quiet --detach "$worktree" "$remote/$branch"
for ((attempt = 1; attempt <= attempts; attempt++)); do
  status=0
  changed=$(apply) || status=$?
  [[ $status -eq 0 ]] || exit "$status"
  if [[ -z $changed ]]; then
    echo "write-back-tag.sh: $env_name already records $tag for every deployed instance — nothing to write back"
    exit 0
  fi
  git -C "$worktree" add -- "config/$env_name"
  git -C "$worktree" -c user.name="$bot_name" -c user.email="$bot_email" commit --quiet -m "$subject" -m "$body"
  commit=$(git -C "$worktree" rev-parse HEAD)
  if [[ $push != true ]]; then
    echo "write-back-tag.sh: committed $commit (WRITE_BACK_PUSH=$push, not pushed):"
    git -C "$worktree" show --stat --format='  %s' HEAD | sed 's/^/  /'
    exit 0
  fi
  if git -C "$worktree" push --quiet "$remote" "HEAD:refs/heads/$branch"; then
    echo "write-back-tag.sh: pushed $commit to $branch — $subject"
    exit 0
  fi
  echo "write-back-tag.sh: push rejected (attempt $attempt/$attempts); re-applying on the new tip" >&2
  fetch_tip
  git -C "$worktree" reset --quiet --hard "$remote/$branch"
done
echo "write-back-tag.sh: could not push to $branch after $attempts attempts. If the branch is protected," \
  "allow this identity to bypass the rule (see .github/README.md, 'Repository settings')." >&2
exit 1
