#!/usr/bin/env bash
# write-back-tag.sh — record the image tag that deploy-dev just deployed (and the box of every pooled
# instance) in the dev config tree: one commit on the deploy branch, authored by the bot, with `[skip ci]`.
# Part of the gha-config-deploy skill; copy it to scripts/ci/write-back-tag.sh in the target repository.
#
# Usage: write-back-tag.sh [--help] <env> <tag> [<flow>/<app>/<instance>...]
#
#   For every deployed instance, under <config>/<env>/<flow>/<app>/<instance>/:
#     compose.env   <TAG_VAR>=<tag>   (the first such line is replaced, later duplicates dropped; appended
#                                      when missing)
#     values.yaml   image.tag: <tag>  (the file must already hold an `image` mapping)
#   Whichever of the two files exist are updated, so the compose and the Helm rendering of an instance always
#   record the same tag. The instances are the ones given, else every target of every
#   <config>/<env>/<flow>/<inventory> whose kind (target, else defaults, else compose) is in WRITE_BACK_KINDS.
#   WRITE_BACK_PLACEMENTS="<flow>/<app>/<instance>=<host> ..." records the box a pooled instance runs on as
#   `host:` of its target in the flow's inventory; entries for instances that were not deployed are ignored,
#   and when the inventory declares a pool the host must be one of pool.hosts.
#
#   The edits are made in a scratch worktree checked out at the current remote tip (the caller's checkout
#   stays untouched) and committed as
#       chore(config): <env> deployed <tag> [skip ci]
#   with the instances, their boxes and the run URL in the body, then pushed. When the push loses a race, the
#   worktree is reset to the new tip and the edits are applied again: no rebase, hence no conflicts, because
#   every edit sets a value. No commit when the tree already records everything (idempotent). Only dev envs
#   are accepted (WRITE_BACK_ENV_PATTERN): qa and prod change through reviewed bump pull requests.
#
# Environment [default]:
#   WRITE_BACK_BRANCH [main]              the branch to commit to
#   WRITE_BACK_REMOTE [origin]
#   WRITE_BACK_CONFIG_DIR [config]        the config tree, relative to the repository root
#   WRITE_BACK_INVENTORY [workflows-config.yml]   the per-flow deploy inventory file name
#   WRITE_BACK_KINDS [compose,helm]       kinds written back when no instance is given
#   WRITE_BACK_PLACEMENTS []              "<flow>/<app>/<instance>=<host>" entries, space or newline separated
#   WRITE_BACK_TAG_VAR [IMAGE_TAG]        the tag variable in compose.env
#   WRITE_BACK_ENV_PATTERN [^([a-z][a-z0-9]*-)?dev$]   envs this script may write (bash ERE)
#   WRITE_BACK_AUTHOR_NAME [github-actions[bot]]       author and committer of the commit
#   WRITE_BACK_AUTHOR_EMAIL [41898282+github-actions[bot]@users.noreply.github.com]
#   WRITE_BACK_PUSH [true]                false: commit in the scratch worktree, print it, push nothing
#   WRITE_BACK_ATTEMPTS [3]               push attempts when the branch moves underneath
#   WRITE_BACK_YQ [yq]                    mikefarah yq v4 (preinstalled on GitHub-hosted runners); needed only
#                                         for values.yaml, placements and reading the inventories
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID   when set, the run URL goes into the commit body
#
# Exit codes: 0 written, or nothing to write · 1 git, push or yq failure · 2 usage · 3 refused (not a dev
#   env) · 4 config tree error (no inventory and no instance given, an instance without compose.env and
#   values.yaml, a values.yaml without an image mapping, a placement without its target or outside the pool)
#
# Needs bash 3.2+, git 2.5+ and awk; runs on a laptop too (WRITE_BACK_PUSH=false for a dry run).
set -euo pipefail

readonly EXIT_FAILED=1 EXIT_USAGE=2 EXIT_REFUSED=3 EXIT_CONFIG=4
readonly TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
readonly INSTANCE_RE='^[a-z0-9-]+/[a-z0-9-]+/[a-z0-9-]+$'
readonly HOST_RE='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'
readonly VAR_RE='^[A-Za-z_][A-Za-z0-9_]*$'

usage() {
    cat <<'EOF'
Usage: write-back-tag.sh [--help] <env> <tag> [<flow>/<app>/<instance>...]

Records <tag> in compose.env (<TAG_VAR>=<tag>) and values.yaml (image.tag) of every deployed instance under
<config>/<env>/<flow>/<app>/<instance>/, and the box of every pooled instance (WRITE_BACK_PLACEMENTS) as `host`
of its target in <config>/<env>/<flow>/<inventory>; commits "chore(config): <env> deployed <tag> [skip ci]" as
the bot on top of the remote tip of the branch and pushes it, re-applying the edits on a fresh tip when the
push loses a race. Without instances: every target of the env's inventories whose kind is in WRITE_BACK_KINDS.

Environment: WRITE_BACK_BRANCH (main), WRITE_BACK_REMOTE (origin), WRITE_BACK_CONFIG_DIR (config),
  WRITE_BACK_INVENTORY (workflows-config.yml), WRITE_BACK_KINDS (compose,helm), WRITE_BACK_PLACEMENTS,
  WRITE_BACK_TAG_VAR (IMAGE_TAG), WRITE_BACK_ENV_PATTERN (^([a-z][a-z0-9]*-)?dev$),
  WRITE_BACK_AUTHOR_NAME / WRITE_BACK_AUTHOR_EMAIL (github-actions[bot]), WRITE_BACK_PUSH (true; false = dry
  run), WRITE_BACK_ATTEMPTS (3), WRITE_BACK_YQ (yq: mikefarah yq v4).

Exit codes: 0 written or nothing to write · 1 git / push / yq failure · 2 usage · 3 refused (not a dev env) ·
  4 config tree error
EOF
}

say() { printf 'write-back-tag: %s\n' "$*"; }
err() { printf 'write-back-tag: %s\n' "$*" >&2; }
die() {
    local code="$1"
    shift
    err "$*"
    exit "$code"
}

case "${1:-}" in -h | --help) usage; exit 0 ;; esac
if [ $# -lt 2 ]; then
    usage >&2
    exit "$EXIT_USAGE"
fi
env_name="$1"
tag="$2"
shift 2

branch="${WRITE_BACK_BRANCH:-main}"
remote="${WRITE_BACK_REMOTE:-origin}"
config_dir="${WRITE_BACK_CONFIG_DIR:-config}"
config_dir="${config_dir%/}"
inventory="${WRITE_BACK_INVENTORY:-workflows-config.yml}"
kinds="${WRITE_BACK_KINDS:-compose,helm}"
tag_var="${WRITE_BACK_TAG_VAR:-IMAGE_TAG}"
env_pattern="${WRITE_BACK_ENV_PATTERN:-^([a-z][a-z0-9]*-)?dev$}"
author_name="${WRITE_BACK_AUTHOR_NAME:-github-actions[bot]}"
author_email="${WRITE_BACK_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
push="${WRITE_BACK_PUSH:-true}"
attempts="${WRITE_BACK_ATTEMPTS:-3}"
yq_bin="${WRITE_BACK_YQ:-yq}"

[[ $env_name =~ $env_pattern ]] ||
    die "$EXIT_REFUSED" "refused: '$env_name' is not a dev env (WRITE_BACK_ENV_PATTERN $env_pattern); qa and prod change through reviewed bump pull requests"
[[ $tag =~ $TAG_RE ]] || die "$EXIT_USAGE" "'$tag' is not a valid image tag"
[[ $tag_var =~ $VAR_RE ]] || die "$EXIT_USAGE" "WRITE_BACK_TAG_VAR '$tag_var' is not a variable name"
[[ $attempts =~ ^[1-9][0-9]*$ ]] || die "$EXIT_USAGE" "WRITE_BACK_ATTEMPTS '$attempts' is not a positive number"
case "$push" in true | false) ;; *) die "$EXIT_USAGE" "WRITE_BACK_PUSH must be true or false" ;; esac

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "$EXIT_FAILED" "not inside a git repository"
cd "$root"

have_yq() { "$yq_bin" --version 2>/dev/null | grep -q mikefarah; }
need_yq() {
    have_yq || { err "$1 needs mikefarah yq v4 as '$yq_bin' (WRITE_BACK_YQ); it is preinstalled on GitHub-hosted runners"; return "$EXIT_FAILED"; }
}

# --- the deployed instances ---------------------------------------------------------------------------------

instances=("$@")
if [ "${#instances[@]}" -eq 0 ]; then
    inventories=()
    for file in "$config_dir/$env_name"/*/"$inventory"; do
        [ -f "$file" ] || continue
        case "$file" in "$config_dir/$env_name/_common/"*) continue ;; esac
        inventories+=("$file")
    done
    [ "${#inventories[@]}" -gt 0 ] ||
        die "$EXIT_CONFIG" "no instance given and no $config_dir/$env_name/<flow>/$inventory to read them from"
    need_yq "reading $inventory" || exit "$EXIT_FAILED"
    # shellcheck disable=SC2016 # $d is a yq variable, not a shell one
    query='(.defaults.kind // "compose") as $d | (.targets // [])[] | (.instance // "") + "|" + (.kind // $d)'
    for file in "${inventories[@]}"; do
        flow="$(basename "$(dirname "$file")")"
        lines="$("$yq_bin" "$query" "$file")" || die "$EXIT_FAILED" "$file: yq failed"
        while IFS='|' read -r instance kind; do
            [ -n "$instance" ] || continue
            case ",$kinds," in *",$kind,"*) instances+=("$flow/$instance") ;; esac
        done <<<"$lines"
    done
fi
if [ "${#instances[@]}" -eq 0 ]; then
    say "no deployed instance of kind '$kinds' in $env_name: nothing to write back"
    exit 0
fi
for instance in "${instances[@]}"; do
    [[ $instance =~ $INSTANCE_RE ]] || die "$EXIT_USAGE" "'$instance' is not <flow>/<app>/<instance>"
    case "$instance" in */app-common) die "$EXIT_USAGE" "'$instance' is the app's shared layer, not an instance" ;; esac
done

# --- the boxes of the pooled instances ("<instance>=<host>" lines; no associative arrays, so bash 3.2 works) --

placements=""
read -r -a entries <<<"$(printf '%s' "${WRITE_BACK_PLACEMENTS:-}" | tr '\n' ' ')"
for entry in ${entries[@]+"${entries[@]}"}; do
    case "$entry" in *=*) ;; *) die "$EXIT_USAGE" "WRITE_BACK_PLACEMENTS entry '$entry' is not <flow>/<app>/<instance>=<host>" ;; esac
    instance="${entry%%=*}" host="${entry#*=}"
    [[ $instance =~ $INSTANCE_RE && $host =~ $HOST_RE ]] ||
        die "$EXIT_USAGE" "WRITE_BACK_PLACEMENTS entry '$entry' is not <flow>/<app>/<instance>=<host>"
    case " ${instances[*]} " in
        *" $instance "*) placements="$placements$instance=$host"$'\n' ;;
        *) err "warning: $instance was not deployed: its placement ($entry) is not recorded" ;;
    esac
done
placement_of() { # <instance> -> the last host recorded for it, or nothing
    printf '%s' "$placements" | awk -F= -v i="$1" '$1 == i { h = $2 } END { if (h != "") print h }'
}

# --- the edits (run inside the scratch worktree; each prints the files whose content changed) ---------------
# apply() runs in a command substitution, where bash does not inherit `set -e`: every step checks its status.

rel_path() { printf '%s' "${1#"$worktree"/}"; }

replace_if_changed() { # <file> <candidate>: the candidate's content replaces the file's (mode kept) when it differs
    if cmp -s "$1" "$2"; then
        rm -f "$2"
        return 0
    fi
    cat "$2" >"$1" || { rm -f "$2"; err "cannot write $(rel_path "$1")"; return "$EXIT_FAILED"; }
    rm -f "$2"
    printf '%s\n' "$1"
}

set_env_tag() { # <compose.env>
    local file="$1" tmp
    tmp="$(mktemp)" || return "$EXIT_FAILED"
    awk -v var="$tag_var" -v tag="$tag" '
        index($0, var "=") == 1 { if (!done) { print var "=" tag; done = 1 }; next }
        { print }
        END { if (!done) print var "=" tag }
    ' "$file" >"$tmp" || { rm -f "$tmp"; err "cannot rewrite $(rel_path "$file")"; return "$EXIT_FAILED"; }
    replace_if_changed "$file" "$tmp"
}

set_values_tag() { # <values.yaml>
    local file="$1" kind tmp
    kind="$("$yq_bin" '.image | tag' "$file")" || { err "$(rel_path "$file") does not parse"; return "$EXIT_FAILED"; }
    [ "$kind" = '!!map' ] ||
        { err "$(rel_path "$file") has no image mapping: add 'image: {tag: \"...\"}' so the tag can be recorded"; return "$EXIT_CONFIG"; }
    tmp="$(mktemp)" || return "$EXIT_FAILED"
    if ! { cp "$file" "$tmp" && TAG="$tag" "$yq_bin" -i '.image.tag = strenv(TAG)' "$tmp"; }; then
        rm -f "$tmp"
        err "cannot set image.tag in $(rel_path "$file")"
        return "$EXIT_FAILED"
    fi
    replace_if_changed "$file" "$tmp"
}

set_target_host() { # <inventory> <app>/<instance> <host>
    local file="$1" target="$2" host="$3" count pool in_pool current tmp
    [ -f "$file" ] || { err "$(rel_path "$file") not found: cannot record the box of $target"; return "$EXIT_CONFIG"; }
    count="$(TARGET="$target" "$yq_bin" '[(.targets // [])[] | select(.instance == strenv(TARGET))] | length' "$file")" ||
        { err "$(rel_path "$file") does not parse"; return "$EXIT_FAILED"; }
    [ "$count" = 1 ] || { err "$(rel_path "$file") has $count target(s) for $target, expected one"; return "$EXIT_CONFIG"; }
    pool="$("$yq_bin" '.pool | tag' "$file")" || return "$EXIT_FAILED"
    if [ "$pool" = '!!map' ]; then
        in_pool="$(HOST="$host" "$yq_bin" '(.pool.hosts // []) | any_c(. == strenv(HOST))' "$file")" || return "$EXIT_FAILED"
        [ "$in_pool" = true ] || { err "$host is not a box of the pool in $(rel_path "$file")"; return "$EXIT_CONFIG"; }
    fi
    current="$(TARGET="$target" "$yq_bin" '.targets[] | select(.instance == strenv(TARGET)) | .host // ""' "$file")" ||
        return "$EXIT_FAILED"
    [ "$current" != "$host" ] || return 0
    tmp="$(mktemp)" || return "$EXIT_FAILED"
    if ! { cp "$file" "$tmp" &&
        TARGET="$target" HOST="$host" "$yq_bin" -i '(.targets[] | select(.instance == strenv(TARGET))).host = strenv(HOST)' "$tmp"; }; then
        rm -f "$tmp"
        err "cannot set the host of $target in $(rel_path "$file")"
        return "$EXIT_FAILED"
    fi
    replace_if_changed "$file" "$tmp"
}

apply() {
    local instance dir found host status
    for instance in "${instances[@]}"; do
        dir="$worktree/$config_dir/$env_name/$instance"
        found=0 status=0
        if [ -f "$dir/compose.env" ]; then
            found=1
            set_env_tag "$dir/compose.env" || return "$?"
        fi
        if [ -f "$dir/values.yaml" ]; then
            found=1
            need_yq "updating values.yaml" || return "$EXIT_FAILED"
            set_values_tag "$dir/values.yaml" || return "$?"
        fi
        [ "$found" -eq 1 ] ||
            { err "$config_dir/$env_name/$instance/ has neither compose.env nor values.yaml on $remote/$branch"; return "$EXIT_CONFIG"; }
        host="$(placement_of "$instance")"
        [ -n "$host" ] || continue
        need_yq "recording placements" || return "$EXIT_FAILED"
        set_target_host "$worktree/$config_dir/$env_name/${instance%%/*}/$inventory" "${instance#*/}" "$host" || status=$?
        [ "$status" -eq 0 ] || return "$status"
    done
}

# --- commit on the remote tip and push -----------------------------------------------------------------------

subject="chore(config): $env_name deployed $tag [skip ci]"
body="Deployed instances:"
for instance in "${instances[@]}"; do
    host="$(placement_of "$instance")"
    body="$body"$'\n'"- $env_name/$instance${host:+ on $host}"
done
if [ -n "${GITHUB_RUN_ID:-}" ]; then
    body="$body"$'\n\n'"Run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
fi

worktree="$(mktemp -d)"
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { git worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf "$worktree"; }
trap cleanup EXIT

fetch_tip() {
    local depth=()
    [ "$(git rev-parse --is-shallow-repository)" != true ] || depth=(--depth=1)
    git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" ||
        die "$EXIT_FAILED" "git fetch $remote $branch failed"
}

fetch_tip
git worktree add --quiet --detach "$worktree" "$remote/$branch" >/dev/null ||
    die "$EXIT_FAILED" "git worktree add failed"
attempt=1
while :; do
    status=0
    changed="$(apply)" || status=$?
    [ "$status" -eq 0 ] || exit "$status"
    if [ -z "$changed" ]; then
        say "$env_name already records $tag (and the boxes) for every deployed instance: nothing to write back"
        exit 0
    fi
    git -C "$worktree" add -- "$config_dir/$env_name"
    git -C "$worktree" -c user.name="$author_name" -c user.email="$author_email" -c commit.gpgsign=false \
        commit --quiet -m "$subject" -m "$body" || die "$EXIT_FAILED" "git commit failed"
    commit="$(git -C "$worktree" rev-parse HEAD)"
    if [ "$push" = false ]; then
        say "committed $commit (WRITE_BACK_PUSH=false, not pushed):"
        git -C "$worktree" show --stat --format='  %s' HEAD | sed 's/^/  /'
        exit 0
    fi
    tip="$(git rev-parse "refs/remotes/$remote/$branch")"
    if push_out="$(git -C "$worktree" push --quiet "$remote" "HEAD:refs/heads/$branch" 2>&1)"; then
        say "pushed $commit to $branch: $subject"
        exit 0
    fi
    fetch_tip
    if [ "$(git rev-parse "refs/remotes/$remote/$branch")" = "$tip" ]; then
        err "push to $branch rejected, and $branch did not move, so this is not a race:"
        printf '%s\n' "$push_out" | sed 's/^/  /' >&2
        die "$EXIT_FAILED" "if a ruleset or branch protection blocks direct pushes, grant this identity a bypass (a GitHub App) or write back through a pull request"
    fi
    if [ "$attempt" -ge "$attempts" ]; then
        die "$EXIT_FAILED" "could not push to $branch after $attempts attempts: it keeps moving"
    fi
    err "push rejected: $branch moved (attempt $attempt/$attempts); applying the edits again on the new tip"
    attempt=$((attempt + 1))
    git -C "$worktree" reset --quiet --hard "$remote/$branch"
done
