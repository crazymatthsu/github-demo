#!/usr/bin/env bash
# pool-deploy.sh — host pools per env/flow for the bare-metal compose targets (DL-39; D9 §6.4, D5 §6.6).
#
# Every box of the `pool` in config/<env>/<flow>/workflows-config.yml (one inventory per flow) receives the flow's host
# bundle — the compose runtime plus every app, instance and layer of the flow — so any instance of the flow can run
# on any box. Each compose target runs on exactly one box, resolved as pinned (`host` in workflows-config.yml) → discovered
# (the one box it already runs on) → assigned (the box with the fewest placements); deploy-dev writes the chosen
# box back as `host` (scripts/ci/set-target-host.sh). The one implementation behind the pooled flows of
# .github/workflows/_deploy-dev.yml; transports ssh (DL-35), local (the runner plays every box: the demo, until
# the boxes exist) and dry-run. Stub-tested by scripts/test/pool-deploy-test.sh through POOL_SSH / POOL_RSYNC.
# Run with --help. Needs bash 4+, mikefarah yq v4 and jq; rsync and ssh for the transports that use them.
set -euo pipefail

readonly EXIT_FAILED=1 EXIT_USAGE=2 EXIT_REFUSED=3 EXIT_CONFIG=4 EXIT_TOOL=5 EXIT_CONFLICT=6
readonly COMMANDS="bundle plan sync discover deploy status"
readonly FLOWS="cash deriv swap"
readonly HOST_RE='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'
readonly LOGIN_RE='^[a-z_][a-z0-9_-]{0,31}$'
readonly ROOT_RE='^(/[A-Za-z0-9._-]+)+/?$'
readonly TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
readonly INSTANCE_RE='^[a-z0-9-]+/[a-z0-9-]+/[a-z0-9-]+$'
# Set by run-compose.sh itself or read from compose.env: never replaced by a validation placeholder.
PROVIDED="APP_ENV APP_FLOW APP_NAME APP_INSTANCE CONFIG_DIR COMMON_DIR PLATFORM_DIR ENV_COMMON_DIR PROJECT"
readonly PROVIDED="$PROVIDED IMAGE_REPO IMAGE_TAG APP_IMAGE"
readonly PLACEHOLDER=pool-deploy-validate-placeholder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd -P))"
readonly SCRIPT_DIR REPO_ROOT

usage() {
    cat <<'EOF'
Usage: pool-deploy.sh <env> <flow> <command> [options]

Host pools (DL-39): every box of the pool in config/<env>/<flow>/workflows-config.yml (one inventory per flow) holds the
flow's whole configuration and the compose runtime (the host bundle, under the pool's root), so any instance of
the flow can run on any box; each compose target of the flow runs on exactly one box. Instances are named
<flow>/<AppName>/<AppInstance> in the output, as deploy-dev and the write-back use them.

Commands:
  bundle   --out <dir> [--tag <tag>]
           build the host bundle in <dir> (absent, empty, or a previous bundle, which is replaced), write its
           .platform-bundle manifest, then run-compose.sh ... validate every compose target of the flow from
           inside it (IMAGE_TAG=<tag> when given; placeholder values for the secrets). Prints the manifest.
  plan     [--tag <tag>] [--json]
           the pool and the box of every compose target: pinned (host in workflows-config.yml) → discovered (the one
           box it runs on) → assigned (the box with the fewest placements so far, ties in pool order). JSON:
           {env, flow, tag, transport, discovery, pool: {hosts, user, root}, placements: [{instance, host, how}]}
  sync     --bundle <dir>
           the bundle to every box (rsync --delete, the box's .state/ kept), each copy verified
  discover [--json]
           run-compose.sh <env> <flow> <app> <inst> status --json on every box, for every compose target
  deploy   --tag <tag> [--bundle <dir>] [--move] [--report <file>]
           bundle (unless --bundle) → sync → plan → per placement, on its box:
             IMAGE_TAG=<tag> run-compose.sh <env> <flow> <app> <inst> pull → start → health
           A failed start or health re-runs start without the override: compose.env on the box still holds
           the previous tag (D9 §6.9); the instance counts as failed. An instance pinned to one box but running
           on another stops the deploy (6) unless --move, which stops it there first. stdout carries one line
           per deployed instance, everything else goes to stderr:
             deployed <flow>/<AppName>/<AppInstance>@<host>=<tag>
           --report <file>: a JSON record of the boxes (bundle files, sha256, verification) and the placements
           (host, how, result, commands), for the deploy-dev job summary.
  status   [--json]
           per box, the status --json of every compose target

Options:
  --transport ssh|local|dry-run   default $POOL_TRANSPORT, else ssh
      ssh      $POOL_SSH $POOL_SSH_OPTS <user>@<host> -- 'IMAGE_TAG=<tag> <root>/<app dir>/scripts/run-compose.sh
               <env> <flow> <app> <inst> <command>' and rsync -az --delete --exclude .state/ over the same
               ssh (DL-35: the deploy user's forced command on every box)
      local    the runner plays every box: <local-root>/<host><root>/ per box (rsync -a --delete); per
               placement validate + start --dry-run, and the ssh commands are printed. With
               POOL_LOCAL_EXECUTE=true, discover / status / pull / start / health run for real; the simulated
               boxes share this machine's engine, so an instance found on every one of them is placed as if
               none ran it
      dry-run  print the rsync and ssh commands; nothing runs and nothing is reported as deployed
  --local-root <dir>   local transport: the directory of the simulated boxes (default $POOL_LOCAL_ROOT)
  --dry-run            alias of --transport dry-run
  -q, --quiet          less informational output
  -h, --help           this text

Environment: CONFIG_ROOT (default <repo>/config) · POOL_SSH (ssh binary, default ssh) · POOL_RSYNC (default
  rsync) · POOL_SSH_OPTS (default -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile=<CONFIG_ROOT>/<env>/known_hosts; without that file the ssh transport refuses (5): an
  unknown host key is never accepted) · POOL_LOCAL_EXECUTE (local transport: true runs the commands for real)
Exit codes: 0 ok · 1 transport or command failure (after trying every box and instance) · 2 usage ·
  3 refused (env not local / *-dev) · 4 config tree or targets error (no workflows-config.yml or no pool for the flow,
  host not in the pool, missing files, a bundle that does not validate or changed since it was built) ·
  5 tool missing (yq v4, jq, rsync, ssh, sha256sum, known_hosts) · 6 placement conflict (an instance running on
  more than one box, or on a box other than its pin without --move)
Bundle: scripts/run-compose.sh and smoke.sh; per app with a directory under config/<env>/<flow>/ its compose
  template and wrappers; config/_common/<app>/, config/<env>/_common/, config/<env>/<flow>/<app>/,
  config/<env>/<flow>/workflows-config.yml, and config/<env>/known_hosts when present. BUNDLE_SHA256 is the sha256 of
  the sorted "<sha256>  <path>" lines of every file but .platform-bundle and .state/. A sync is verified by
  rsync's exit code and a second rsync --dry-run --itemize-changes --checksum that must list no change; a local
  box also recomputes BUNDLE_SHA256.
EOF
}

# --- output helpers ---------------------------------------------------------------------------------------

QUIET=0
info() { if [ "$QUIET" -eq 0 ]; then printf 'pool-deploy: %s\n' "$*" >&2; fi; }
warn() { printf 'pool-deploy: warning: %s\n' "$*" >&2; }
error() { printf 'pool-deploy: error: %s\n' "$*" >&2; }
die() {
    local code="$1"
    shift
    error "$*"
    exit "$code"
}
contains_word() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
rel() { case "$1" in "$REPO_ROOT"/*) printf '%s' "${1#"$REPO_ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }
# A command line as it would be typed: arguments outside [A-Za-z0-9_./:=@,+-] in single quotes.
quote_words() {
    local out="" word sq="'"
    for word in "$@"; do
        case "$word" in *[!A-Za-z0-9_./:=@,+-]*) word="$sq${word//$sq/$sq\\$sq$sq}$sq" ;; esac
        out="$out $word"
    done
    printf '%s' "${out# }"
}
json_array() { jq -cn '$ARGS.positional' --args "$@"; }
# One value of a .platform-bundle manifest (KEY=value lines, the value optionally in double quotes).
manifest_value() {
    awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/^"|"$/, "", v); print v; exit }' "$1"
}

# --- arguments --------------------------------------------------------------------------------------------

POSITIONAL=()
OUT="" TAG="" TAG_SET=0 JSON=0 BUNDLE_ARG="" MOVE=0 REPORT=""
TRANSPORT="${POOL_TRANSPORT:-ssh}" LOCAL_ROOT="${POOL_LOCAL_ROOT:-}"
OPTIONS_GIVEN=""
need_value() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$EXIT_USAGE" "option $1 needs a value (see --help)"; fi; }
while [ $# -gt 0 ]; do
    case "$1" in --out* | --tag* | --bundle* | --report* | --json | --move) OPTIONS_GIVEN="$OPTIONS_GIVEN ${1%%=*}" ;; esac
    case "$1" in
        --out) need_value "$@"; OUT="$2"; shift ;;
        --out=*) OUT="${1#*=}" ;;
        --tag) need_value "$@"; TAG="$2"; TAG_SET=1; shift ;;
        --tag=*) TAG="${1#*=}"; TAG_SET=1 ;;
        --bundle) need_value "$@"; BUNDLE_ARG="$2"; shift ;;
        --bundle=*) BUNDLE_ARG="${1#*=}" ;;
        --report) need_value "$@"; REPORT="$2"; shift ;;
        --report=*) REPORT="${1#*=}" ;;
        --transport) need_value "$@"; TRANSPORT="$2"; shift ;;
        --transport=*) TRANSPORT="${1#*=}" ;;
        --local-root) need_value "$@"; LOCAL_ROOT="$2"; shift ;;
        --local-root=*) LOCAL_ROOT="${1#*=}" ;;
        --json) JSON=1 ;;
        --move) MOVE=1 ;;
        --dry-run) TRANSPORT=dry-run ;;
        -q | --quiet) QUIET=1 ;;
        -h | --help) usage; exit 0 ;;
        -*) die "$EXIT_USAGE" "unknown option $1 (see --help)" ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done
if [ "${#POSITIONAL[@]}" -ne 3 ]; then
    usage >&2
    die "$EXIT_USAGE" "expected <env> <flow> <command>, got ${#POSITIONAL[@]} argument(s)"
fi
ENV_NAME="${POSITIONAL[0]}" FLOW="${POSITIONAL[1]}" COMMAND="${POSITIONAL[2]}"

# --- validation: usage (2), safety (3) --------------------------------------------------------------------

contains_word "$COMMAND" "$COMMANDS" || die "$EXIT_USAGE" "unknown command '$COMMAND' (one of: $COMMANDS)"
case "$ENV_NAME" in
    local | [a-z][a-z]-dev | [a-z][a-z]-qa | [a-z][a-z]-prod) ;;
    *) die "$EXIT_USAGE" "env '$ENV_NAME' must be local or <region>-<stage> (e.g. us-dev)" ;;
esac
contains_word "$FLOW" "$FLOWS" || die "$EXIT_USAGE" "flow '$FLOW' must be one of: $FLOWS"
case "$TRANSPORT" in ssh | local | dry-run) ;; *) die "$EXIT_USAGE" "--transport must be ssh, local or dry-run (was '$TRANSPORT')" ;; esac
declare -A OPTION_COMMANDS=([--out]="bundle" [--tag]="bundle plan deploy" [--bundle]="sync deploy" [--report]="deploy"
    [--json]="plan discover status" [--move]="deploy")
for option in $OPTIONS_GIVEN; do
    contains_word "$COMMAND" "${OPTION_COMMANDS[$option]}" ||
        die "$EXIT_USAGE" "$option does not apply to $COMMAND (only to: ${OPTION_COMMANDS[$option]})"
done
case "$COMMAND" in
    bundle) [ -n "$OUT" ] || die "$EXIT_USAGE" "bundle needs --out <dir>" ;;
    sync) [ -n "$BUNDLE_ARG" ] || die "$EXIT_USAGE" "sync needs --bundle <dir> (build one with: bundle --out <dir>)" ;;
    deploy) [ "$TAG_SET" -eq 1 ] || die "$EXIT_USAGE" "deploy needs --tag <tag>" ;;
esac
if [ "$TAG_SET" -eq 1 ] && ! [[ $TAG =~ $TAG_RE ]]; then die "$EXIT_USAGE" "--tag '$TAG' is not a valid image tag"; fi
case "$ENV_NAME" in
    local | *-dev) ;;
    *) die "$EXIT_REFUSED" "env '$ENV_NAME' refused: host pools serve local and *-dev only; qa and prod run on" \
        "Kubernetes (D9, D11)" ;;
esac
EXECUTE=false
[ "${POOL_LOCAL_EXECUTE:-false}" != true ] || EXECUTE=true
if [ "$TRANSPORT" = local ] && [ -z "$LOCAL_ROOT" ]; then
    case "$COMMAND" in
        sync | deploy) die "$EXIT_USAGE" "the local transport needs --local-root <dir> (or POOL_LOCAL_ROOT): one directory per box below it" ;;
        discover | status | plan) [ "$EXECUTE" = false ] || die "$EXIT_USAGE" "POOL_LOCAL_EXECUTE=true needs --local-root <dir> (or POOL_LOCAL_ROOT)" ;;
    esac
fi

# --- tools (5) --------------------------------------------------------------------------------------------

yq --version 2>/dev/null | grep -q mikefarah ||
    die "$EXIT_TOOL" "mikefarah yq v4 is needed to read workflows-config.yml (preinstalled on GitHub-hosted runners)"
command -v jq >/dev/null 2>&1 || die "$EXIT_TOOL" "jq is needed (preinstalled on GitHub-hosted runners)"
SHA256=()
if command -v sha256sum >/dev/null 2>&1; then
    SHA256=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    SHA256=(shasum -a 256)
else
    die "$EXIT_TOOL" "sha256sum (or shasum) is needed to hash the bundle"
fi
SSH_BIN="${POOL_SSH:-ssh}" RSYNC_BIN="${POOL_RSYNC:-rsync}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pool-deploy.XXXXXX")"
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- the pool and the compose targets of <env>/<flow> (4) -------------------------------------------------

CONFIG_ROOT="${CONFIG_ROOT:-$REPO_ROOT/config}"
[ -d "$CONFIG_ROOT" ] || die "$EXIT_CONFIG" "config tree not found: $CONFIG_ROOT"
CONFIG_ROOT="$(cd "$CONFIG_ROOT" && pwd -P)"
ENV_DIR="$CONFIG_ROOT/$ENV_NAME"
TARGETS_FILE="$ENV_DIR/$FLOW/workflows-config.yml"
KNOWN_HOSTS="$ENV_DIR/known_hosts"
[ -f "$TARGETS_FILE" ] || die "$EXIT_CONFIG" "$(rel "$TARGETS_FILE") not found (the flow's deploy-dev inventory, D5 §6.6)"
TARGETS_JSON="$(yq -o=json -I=0 '.' "$TARGETS_FILE" 2>&1)" || die "$EXIT_CONFIG" "$(rel "$TARGETS_FILE") does not parse: $TARGETS_JSON"
if [ "$(jq -r '.env // "" | tostring' <<<"$TARGETS_JSON")" != "$ENV_NAME" ] ||
    [ "$(jq -r '.flow // "" | tostring' <<<"$TARGETS_JSON")" != "$FLOW" ]; then
    die "$EXIT_CONFIG" "$(rel "$TARGETS_FILE"): env and flow must be $ENV_NAME and $FLOW, the ones of its path"
fi
jq -e '.pool | type == "object"' <<<"$TARGETS_JSON" >/dev/null ||
    die "$EXIT_CONFIG" "no pool in $(rel "$TARGETS_FILE"): the compose targets of $ENV_NAME/$FLOW are deployed per host, not by this script"
mapfile -t POOL_HOSTS < <(jq -r '.pool.hosts // [] | if type == "array" then .[] else empty end | tostring' <<<"$TARGETS_JSON")
POOL_USER="$(jq -r '.pool.user // "deploy" | tostring' <<<"$TARGETS_JSON")"
POOL_ROOT="$(jq -r '.pool.root // "/opt/platform" | tostring' <<<"$TARGETS_JSON")"
[ "${#POOL_HOSTS[@]}" -gt 0 ] || die "$EXIT_CONFIG" "pool.hosts is empty in $(rel "$TARGETS_FILE")"
for host in "${POOL_HOSTS[@]}"; do
    [[ $host =~ $HOST_RE ]] || die "$EXIT_CONFIG" "pool.hosts: '$host' is not a lower-case DNS name or IPv4 address"
done
[ "$(printf '%s\n' "${POOL_HOSTS[@]}" | sort | uniq -d)" = "" ] || die "$EXIT_CONFIG" "pool.hosts lists a box twice"
[[ $POOL_USER =~ $LOGIN_RE ]] || die "$EXIT_CONFIG" "pool.user '$POOL_USER' is not a valid login name"
if ! [[ $POOL_ROOT =~ $ROOT_RE ]] || [[ /$POOL_ROOT/ == */./* || /$POOL_ROOT/ == */../* ]]; then
    die "$EXIT_CONFIG" "pool.root '$POOL_ROOT' must be an absolute path of plain segments, without '.' or '..'"
fi
POOL_ROOT="${POOL_ROOT%/}"

# The subproject of an app, relative to the repository: the directory with docker/docker-compose.yml.
app_rel() {
    local candidate
    for candidate in "$REPO_ROOT/$1" "$REPO_ROOT"/*/"$1"; do
        if [ -f "$candidate/docker/docker-compose.yml" ]; then
            printf '%s' "${candidate#"$REPO_ROOT"/}"
            return 0
        fi
    done
    return 1
}

# Compose targets of the flow in workflows-config.yml order (kind from the target, else defaults, else compose — as
# deploy-dev reads it), named <flow>/<AppName>/<AppInstance> from here on; T_PIN is the recorded placement (host,
# else defaults.host), empty when there is none.
T_INSTANCE=() T_PIN=()
# shellcheck disable=SC2016 # $d is a jq variable
while IFS='|' read -r target pin; do
    [[ $FLOW/$target =~ $INSTANCE_RE ]] || die "$EXIT_CONFIG" "$(rel "$TARGETS_FILE"): '$target' is not <AppName>/<AppInstance>"
    instance="$FLOW/$target"
    [ -d "$ENV_DIR/$instance" ] || die "$EXIT_CONFIG" "$(rel "$TARGETS_FILE"): $target has no directory $(rel "$ENV_DIR/$instance")/"
    app_rel "${target%%/*}" >/dev/null ||
        die "$EXIT_CONFIG" "$(rel "$TARGETS_FILE"): $target: no subproject with docker/docker-compose.yml for its app"
    if [ -n "$pin" ] && ! contains_word "$pin" "${POOL_HOSTS[*]}"; then
        die "$EXIT_CONFIG" "$(rel "$TARGETS_FILE"): host '$pin' of $target is not a box of the pool (${POOL_HOSTS[*]})"
    fi
    T_INSTANCE+=("$instance")
    T_PIN+=("$pin")
done < <(jq -r '(.defaults // {}) as $d | (.targets // [])[]
    | select((.kind // $d.kind // "compose") == "compose")
    | [(.instance // "" | tostring), (.host // $d.host // "" | tostring)] | join("|")' <<<"$TARGETS_JSON")
[ "${#T_INSTANCE[@]}" -gt 0 ] || warn "no compose target in $(rel "$TARGETS_FILE"): nothing to place"

# --- transports -------------------------------------------------------------------------------------------

SSH_ARGS=()
if [ -n "${POOL_SSH_OPTS:-}" ]; then
    read -r -a SSH_ARGS <<<"$POOL_SSH_OPTS"
else
    SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS")
fi
# The ssh transport's prerequisites; with $1=lenient a missing one only skips discovery (plan is a preview).
DISCOVERY_NOTE=""
transport_ready() {
    local problem=""
    if [ "$TRANSPORT" = dry-run ] && [ -z "${POOL_SSH_OPTS:-}" ] && [ ! -f "$KNOWN_HOSTS" ]; then
        warn "$(rel "$KNOWN_HOSTS") is missing: the ssh transport would refuse to run these commands (exit $EXIT_TOOL)"
    fi
    [ "$TRANSPORT" = ssh ] || return 0
    if ! command -v "$SSH_BIN" >/dev/null 2>&1; then
        problem="$SSH_BIN not found: the ssh transport needs an ssh client (POOL_SSH)"
    elif [ -z "${POOL_SSH_OPTS:-}" ] && [ ! -f "$KNOWN_HOSTS" ]; then
        problem="$(rel "$KNOWN_HOSTS") is missing: the ssh transport checks every box's host key against it and"
        problem="$problem never accepts an unknown one (add the reviewed ssh-keyscan lines of the boxes)"
    fi
    [ -n "$problem" ] || return 0
    [ "${1:-strict}" = lenient ] || die "$EXIT_TOOL" "$problem"
    warn "discovery skipped: $problem"
    DISCOVERY_NOTE="skipped: $problem"
    return 1
}
rsync_ready() {
    [ "$TRANSPORT" = dry-run ] || command -v "$RSYNC_BIN" >/dev/null 2>&1 ||
        die "$EXIT_TOOL" "$RSYNC_BIN not found: syncing the bundle needs rsync (POOL_RSYNC)"
}
# rsync -e: ssh and its options as one string, split by rsync itself (single quotes keep spaces, no backslashes).
rsync_shell() {
    local out="" word
    for word in "$SSH_BIN" ${SSH_ARGS[@]+"${SSH_ARGS[@]}"}; do
        case "$word" in
            *"'"*) die "$EXIT_USAGE" "an ssh option holds a single quote, which rsync -e cannot pass: $word" ;;
            *[[:space:]]*) word="'$word'" ;;
        esac
        out="$out $word"
    done
    printf '%s' "${out# }"
}
# The command a box runs for <instance> <command> [tag] [args...], quoted with printf %q.
remote_line() {
    local instance="$1" cmd="$2" tag="$3" flow app inst words=() line
    shift 3
    IFS=/ read -r flow app inst <<<"$instance"
    [ -z "$tag" ] || words+=("IMAGE_TAG=$tag")
    words+=("$POOL_ROOT/$(app_rel "$app")/scripts/run-compose.sh" "$ENV_NAME" "$flow" "$app" "$inst" "$cmd" "$@")
    printf -v line '%q ' "${words[@]}"
    printf '%s' "${line% }"
}
SSH_CMD=()
ssh_command() { # <host> <instance> <command> <tag> [args...] -> SSH_CMD
    local host="$1"
    shift
    SSH_CMD=("$SSH_BIN" ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} "$POOL_USER@$host" -- "$(remote_line "$@")")
}
ssh_display() { ssh_command "$@"; quote_words "${SSH_CMD[@]}"; }
# The box directory's run-compose.sh, run as the box would run it (local transport): no CI run identity, no
# ambient IMAGE_* overrides, the tree resolved through its .platform-bundle marker.
local_run() { # <host> <instance> <command> <tag> [args...]
    local host="$1" instance="$2" cmd="$3" tag="$4" flow app inst dir envs=() var
    shift 4
    IFS=/ read -r flow app inst <<<"$instance"
    dir="$LOCAL_ROOT/$host$POOL_ROOT"
    [ -x "$dir/$(app_rel "$app")/scripts/run-compose.sh" ] ||
        { error "$host: $dir holds no bundle (sync first)"; return "$EXIT_CONFIG"; }
    envs=("POOL_SELF_HOST=$host")
    # pool-deploy.sh keeps the single-run rule itself; the simulated boxes share one engine.
    [ "$EXECUTE" = false ] || envs+=(POOL_PEER_CHECK=off)
    [ -z "$tag" ] || envs+=("IMAGE_TAG=$tag")
    if [ "$cmd" = validate ]; then
        while IFS= read -r var; do envs+=("$var"); done < <(validation_env "$dir/$(app_rel "$app")/docker/docker-compose.yml" \
            "$dir/config/$ENV_NAME/$instance/compose.env")
    fi
    (cd "$dir" && env -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u CONFIG_ROOT -u IMAGE_TAG -u IMAGE_REPO -u APP_IMAGE \
        "${envs[@]}" "$dir/$(app_rel "$app")/scripts/run-compose.sh" "$ENV_NAME" "$flow" "$app" "$inst" "$cmd" "$@")
}
# Placeholders for the secrets a template requires (${VAR:?...}) that neither compose.env, run-compose.sh nor this
# shell provides: `validate` checks the template, not the box's secrets (as config-lint does, D5 check 6).
validation_env() { # <compose file> <compose.env>
    local var
    [ -f "$1" ] || return 0
    # shellcheck disable=SC2013 # variable names never contain whitespace
    for var in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:?\?' "$1" | sed -e 's/^\${//' -e 's/:*?$//' | sort -u); do
        contains_word "$var" "$PROVIDED" && continue
        [ ! -f "$2" ] || ! grep -Eq "^[[:space:]]*$var=" "$2" || continue
        [ -z "${!var:-}" ] || continue
        printf '%s=%s\n' "$var" "$PLACEHOLDER"
    done
}
# run-compose.sh <command> on a box through the transport; its output goes to stderr.
on_box() { # <host> <instance> <command> <tag> [args...]
    local host="$1"
    case "$TRANSPORT" in
        ssh)
            ssh_command "$@"
            info "$host: $(quote_words "${SSH_CMD[@]}")"
            "${SSH_CMD[@]}" </dev/null >&2
            ;;
        local) local_run "$@" >&2 ;;
        dry-run) info "dry-run: $(ssh_display "$@")" ;;
    esac
}

# --- the host bundle (§2 of DL-39's contract; D6 §6.2) ----------------------------------------------------

TREE_FILES=0 TREE_SHA256=""
# "<sha256>  <path>" of every file below $1 but .platform-bundle and .state/, sorted by path (C locale).
tree_listing() {
    (cd "$1" && find . -path ./.state -prune -o -type f ! -path ./.platform-bundle -print0 | LC_ALL=C sort -z |
        xargs -0 -r "${SHA256[@]}") | sed 's|  \./|  |'
}
tree_stats() {
    local listing
    listing="$(tree_listing "$1")"
    TREE_FILES=0
    [ -z "$listing" ] || TREE_FILES="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
    TREE_SHA256="$(printf '%s\n' "$listing" | "${SHA256[@]}" | cut -d ' ' -f 1)"
}
OUT_DIR=""
copy_file() { # <path relative to the repository>
    [ -f "$REPO_ROOT/$1" ] || die "$EXIT_CONFIG" "bundle: $1 missing in the repository"
    mkdir -p "$(dirname "$OUT_DIR/$1")"
    cp -p "$REPO_ROOT/$1" "$OUT_DIR/$1"
}
copy_tree() { # <source directory> <path in the bundle>
    mkdir -p "$OUT_DIR/$2"
    cp -pR "$1/." "$OUT_DIR/$2/"
}
prepare_out() {
    local out="$1"
    if [ -e "$out" ] && [ ! -d "$out" ]; then die "$EXIT_USAGE" "--out $out exists and is not a directory"; fi
    if [ -d "$out" ] && [ -n "$(ls -A "$out")" ]; then
        [ -f "$out/.platform-bundle" ] ||
            die "$EXIT_USAGE" "--out $out is not empty and holds no .platform-bundle: refusing to replace it"
        find "$out" -mindepth 1 -delete
    fi
    mkdir -p "$out"
    OUT_DIR="$(cd "$out" && pwd -P)"
    case "$OUT_DIR/" in "$CONFIG_ROOT"/* | "$REPO_ROOT"/scripts/* | "$REPO_ROOT"/deephaven-connectors/*)
        die "$EXIT_USAGE" "--out $out lies inside a tree the bundle copies" ;;
    esac
}
build_bundle() { # <out> <tag>
    local tag="$2" dir app rel apps=() app_rels=() git_sha dirty paths i instance flow inst envs failed=0 var
    prepare_out "$1"
    [ -d "$ENV_DIR/$FLOW" ] || die "$EXIT_CONFIG" "config tree: $(rel "$ENV_DIR/$FLOW")/ missing"
    for dir in "$ENV_DIR/$FLOW"/*/; do
        [ -d "$dir" ] || continue
        app="$(basename "$dir")"
        if rel="$(app_rel "$app")"; then
            apps+=("$app")
            app_rels+=("$rel")
        else
            warn "$(rel "$dir") is not a deployable app (no <subproject>/docker/docker-compose.yml): left out of the bundle"
        fi
    done
    copy_file scripts/run-compose.sh
    copy_file scripts/smoke.sh
    for ((i = 0; i < ${#apps[@]}; i++)); do
        app="${apps[i]}" rel="${app_rels[i]}"
        copy_file "$rel/docker/docker-compose.yml"
        copy_file "$rel/scripts/run-compose.sh"
        [ ! -f "$REPO_ROOT/$rel/scripts/smoke.sh" ] || copy_file "$rel/scripts/smoke.sh"
        [ ! -d "$CONFIG_ROOT/_common/$app" ] || copy_tree "$CONFIG_ROOT/_common/$app" "config/_common/$app"
        copy_tree "$ENV_DIR/$FLOW/$app" "config/$ENV_NAME/$FLOW/$app"
    done
    [ ! -d "$ENV_DIR/_common" ] || copy_tree "$ENV_DIR/_common" "config/$ENV_NAME/_common"
    mkdir -p "$OUT_DIR/config/$ENV_NAME/$FLOW"
    cp -p "$TARGETS_FILE" "$OUT_DIR/config/$ENV_NAME/$FLOW/workflows-config.yml"
    # The pinned host keys: run-compose.sh's pool guard on a box asks the other boxes with them.
    [ ! -f "$KNOWN_HOSTS" ] || cp -p "$KNOWN_HOSTS" "$OUT_DIR/config/$ENV_NAME/known_hosts"
    find "$OUT_DIR" -mindepth 1 -type d -name .state -prune -exec rm -rf {} +

    # The commit the bundle was built from; -dirty when a bundled file differs from it.
    git_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ "$git_sha" != unknown ]; then
        paths=(scripts/run-compose.sh scripts/smoke.sh "$(rel "$ENV_DIR/$FLOW")" "$(rel "$ENV_DIR/_common")"
            "$(rel "$CONFIG_ROOT/_common")" "$(rel "$KNOWN_HOSTS")")
        for rel in ${app_rels[@]+"${app_rels[@]}"}; do paths+=("$rel/docker/docker-compose.yml" "$rel/scripts"); done
        dirty="$(git -C "$REPO_ROOT" status --porcelain -- "${paths[@]}" 2>/dev/null || true)"
        [ -z "$dirty" ] || git_sha="$git_sha-dirty"
    fi
    tree_stats "$OUT_DIR"
    {
        printf '# Host bundle of %s/%s for every box of its pool (DL-39), written by scripts/pool-deploy.sh.\n' \
            "$ENV_NAME" "$FLOW"
        printf '# KEY=value lines: shell-sourceable; run-compose.sh reads them without sourcing. BUNDLE_SHA256 is the\n'
        printf '# sha256 of the sorted "<sha256>  <path>" lines of every other file but .state/ (pool-deploy.sh --help).\n'
        printf 'BUNDLE_ENV=%s\nBUNDLE_FLOW=%s\nBUNDLE_GIT_SHA=%s\nBUNDLE_TAG=%s\n' "$ENV_NAME" "$FLOW" "$git_sha" "$tag"
        printf 'BUNDLE_CREATED=%s\nBUNDLE_FILES=%s\nBUNDLE_SHA256=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TREE_FILES" "$TREE_SHA256"
        printf 'POOL_HOSTS="%s"\nPOOL_USER=%s\nPOOL_ROOT=%s\n' "${POOL_HOSTS[*]}" "$POOL_USER" "$POOL_ROOT"
    } >"$OUT_DIR/.platform-bundle"
    info "bundle: $TREE_FILES files of $ENV_NAME/$FLOW (${apps[*]:-no app}) in $OUT_DIR, sha256 $TREE_SHA256"

    # Verify from inside the bundle, as a box runs it: the marker resolves the tree (no CONFIG_ROOT), no CI identity.
    for instance in ${T_INSTANCE[@]+"${T_INSTANCE[@]}"}; do
        IFS=/ read -r flow app inst <<<"$instance"
        rel="$(app_rel "$app")"
        if [ ! -x "$OUT_DIR/$rel/scripts/run-compose.sh" ]; then
            error "bundle: $instance: $rel/scripts/run-compose.sh is not in the bundle (no config/$ENV_NAME/$FLOW/$app/?)"
            failed=1
            continue
        fi
        envs=()
        [ -z "$tag" ] || envs+=("IMAGE_TAG=$tag")
        while IFS= read -r var; do envs+=("$var"); done < <(validation_env "$OUT_DIR/$rel/docker/docker-compose.yml" \
            "$OUT_DIR/config/$ENV_NAME/$instance/compose.env")
        if (cd "$OUT_DIR" && env -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u CONFIG_ROOT -u IMAGE_TAG -u IMAGE_REPO -u APP_IMAGE \
            ${envs[@]+"${envs[@]}"} "$OUT_DIR/$rel/scripts/run-compose.sh" "$ENV_NAME" "$flow" "$app" "$inst" validate >&2); then
            info "bundle: $instance validates from the bundle${tag:+ with IMAGE_TAG=$tag}"
        else
            error "bundle: $instance does not validate from the bundle"
            failed=1
        fi
    done
    [ "$failed" -eq 0 ] || exit "$EXIT_CONFIG"
}
BUNDLE_DIR="" BUNDLE_FILES="" BUNDLE_SHA256="" BUNDLE_TAG=""
load_bundle() { # <dir>: a bundle of this env, flow and pool, unchanged since it was built
    local manifest="$1/.platform-bundle" hosts user root
    [ -f "$manifest" ] || die "$EXIT_CONFIG" "$1 holds no .platform-bundle: build it with pool-deploy.sh $ENV_NAME $FLOW bundle --out $1"
    BUNDLE_DIR="$(cd "$1" && pwd -P)"
    if [ "$(manifest_value "$manifest" BUNDLE_ENV)" != "$ENV_NAME" ] || [ "$(manifest_value "$manifest" BUNDLE_FLOW)" != "$FLOW" ]; then
        die "$EXIT_CONFIG" "$1 is the bundle of $(manifest_value "$manifest" BUNDLE_ENV)/$(manifest_value "$manifest" BUNDLE_FLOW), not of $ENV_NAME/$FLOW"
    fi
    hosts="$(manifest_value "$manifest" POOL_HOSTS)" user="$(manifest_value "$manifest" POOL_USER)" root="$(manifest_value "$manifest" POOL_ROOT)"
    if [ "$hosts" != "${POOL_HOSTS[*]}" ] || [ "$user" != "$POOL_USER" ] || [ "$root" != "$POOL_ROOT" ]; then
        die "$EXIT_CONFIG" "$1 was built for pool '$hosts' ($user, $root), workflows-config.yml now says '${POOL_HOSTS[*]}' ($POOL_USER, $POOL_ROOT): rebuild it"
    fi
    BUNDLE_FILES="$(manifest_value "$manifest" BUNDLE_FILES)" BUNDLE_SHA256="$(manifest_value "$manifest" BUNDLE_SHA256)"
    BUNDLE_TAG="$(manifest_value "$manifest" BUNDLE_TAG)"
    tree_stats "$BUNDLE_DIR"
    [ "$TREE_SHA256" = "$BUNDLE_SHA256" ] ||
        die "$EXIT_CONFIG" "$1 changed since it was built (sha256 $TREE_SHA256, manifest $BUNDLE_SHA256): rebuild it"
    if [ -n "$TAG" ] && [ -n "$BUNDLE_TAG" ] && [ "$BUNDLE_TAG" != "$TAG" ]; then
        warn "the bundle was validated for tag $BUNDLE_TAG, deploying $TAG"
    fi
}

# --- sync -------------------------------------------------------------------------------------------------

declare -A BOX_RESULT=() BOX_FILES=() BOX_SHA=() BOX_CHECK=()
AVAILABLE=() SYNC_FAILED=()
sync_box() { # <host>
    local host="$1" dest changes rc=0 args=(-a --delete --exclude .state/) shell=()
    case "$TRANSPORT" in
        dry-run)
            info "dry-run: $(quote_words "$RSYNC_BIN" -az --delete --exclude .state/ -e "$(rsync_shell)" "$BUNDLE_DIR/" "$POOL_USER@$host:$POOL_ROOT/")"
            BOX_RESULT[$host]="dry-run" BOX_FILES[$host]="$BUNDLE_FILES" BOX_SHA[$host]="$BUNDLE_SHA256" BOX_CHECK[$host]="none (dry-run)"
            return 0
            ;;
        local)
            dest="$LOCAL_ROOT/$host$POOL_ROOT/"
            mkdir -p "$dest"
            ;;
        ssh)
            dest="$POOL_USER@$host:$POOL_ROOT/"
            args=(-az --delete --exclude .state/)
            shell=(-e "$(rsync_shell)")
            ;;
    esac
    info "$host: $(quote_words "$RSYNC_BIN" "${args[@]}" ${shell[@]+"${shell[@]}"} "$BUNDLE_DIR/" "$dest")"
    "$RSYNC_BIN" "${args[@]}" ${shell[@]+"${shell[@]}"} "$BUNDLE_DIR/" "$dest" >&2 || rc=$?
    if [ "$rc" -ne 0 ]; then
        error "$host: rsync failed (exit $rc): the box did not receive the bundle"
        BOX_RESULT[$host]="failed: rsync exit $rc"
        return 1
    fi
    # Verified: a second pass that compares content (--checksum) must find nothing left to change.
    changes="$("$RSYNC_BIN" "${args[@]}" ${shell[@]+"${shell[@]}"} --dry-run --itemize-changes --checksum --omit-dir-times \
        "$BUNDLE_DIR/" "$dest" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ] || [ -n "$changes" ]; then
        error "$host: the synced tree differs from the bundle (verification exit $rc): $(printf '%s' "$changes" | head -n 5 | tr '\n' ' ')"
        BOX_RESULT[$host]="failed: verification"
        return 1
    fi
    BOX_FILES[$host]="$BUNDLE_FILES" BOX_SHA[$host]="$BUNDLE_SHA256" BOX_CHECK[$host]="rsync --checksum"
    if [ "$TRANSPORT" = local ]; then
        tree_stats "$dest"
        BOX_FILES[$host]="$TREE_FILES" BOX_SHA[$host]="$TREE_SHA256" BOX_CHECK[$host]="rsync --checksum, sha256 recomputed"
        if [ "$TREE_SHA256" != "$BUNDLE_SHA256" ] || ! cmp -s "$BUNDLE_DIR/.platform-bundle" "$dest/.platform-bundle"; then
            error "$host: $dest does not hash to the bundle's sha256 ($TREE_SHA256 vs $BUNDLE_SHA256)"
            BOX_RESULT[$host]="failed: sha256"
            return 1
        fi
    fi
    BOX_RESULT[$host]="synced"
    info "$host: synced and verified ($BUNDLE_FILES files, sha256 $BUNDLE_SHA256)"
}
sync_all() {
    local host
    AVAILABLE=() SYNC_FAILED=()
    for host in "${POOL_HOSTS[@]}"; do
        if sync_box "$host"; then AVAILABLE+=("$host"); else SYNC_FAILED+=("$host"); fi
    done
}

# --- discovery and placement ------------------------------------------------------------------------------

declare -A RUNNING_ON=() UNKNOWN_ON=()
STATUS_JSON=""
# Asks one box for the status of one instance. 0: STATUS_JSON holds run-compose.sh's status JSON · 1: no answer
# from run-compose.sh · 2: the box is unreachable (ssh exit 255) · 3: not asked (dry-run, local without execute).
box_status() { # <host> <instance>
    local host="$1" instance="$2" out rc=0
    STATUS_JSON=""
    case "$TRANSPORT" in
        dry-run)
            info "dry-run: $(ssh_display "$host" "$instance" status "" --json)"
            return 3
            ;;
        local)
            [ "$EXECUTE" = true ] || return 3
            out="$(local_run "$host" "$instance" status "" --json 2>"$WORK/status.err")" || rc=$?
            ;;
        ssh)
            ssh_command "$host" "$instance" status "" --json
            out="$("${SSH_CMD[@]}" </dev/null 2>"$WORK/status.err")" || rc=$?
            ;;
    esac
    STATUS_JSON="$(printf '%s\n' "$out" | grep '^{' | tail -n 1 || true)"
    if [ -n "$STATUS_JSON" ] && jq -e 'has("running")' <<<"$STATUS_JSON" >/dev/null 2>&1; then return 0; fi
    STATUS_JSON=""
    if [ "$TRANSPORT" = ssh ] && [ "$rc" -eq 255 ]; then return 2; fi
    warn "$host: no status of $instance (exit $rc): $(grep -v '^[[:space:]]*$' "$WORK/status.err" 2>/dev/null | tail -n 1 || true)"
    return 1
}
discover_all() {
    local host instance other rc boxes=() silent=()
    RUNNING_ON=() UNKNOWN_ON=()
    for host in ${AVAILABLE[@]+"${AVAILABLE[@]}"}; do
        for instance in ${T_INSTANCE[@]+"${T_INSTANCE[@]}"}; do
            rc=0
            box_status "$host" "$instance" || rc=$?
            case "$rc" in
                0) [ "$(jq -r '.running' <<<"$STATUS_JSON")" != true ] || RUNNING_ON[$instance]="${RUNNING_ON[$instance]:-} $host" ;;
                2)
                    warn "$host does not answer (ssh exit 255): placements treat it as running nothing"
                    for other in "${T_INSTANCE[@]}"; do UNKNOWN_ON[$other]="${UNKNOWN_ON[$other]:-} $host"; done
                    silent+=("$host")
                    break
                    ;;
                3) ;;
                *) UNKNOWN_ON[$instance]="${UNKNOWN_ON[$instance]:-} $host" ;;
            esac
        done
    done
    # POOL_LOCAL_EXECUTE: every simulated box asks the same engine, so an instance running here shows up on all
    # of them — that says nothing about a box.
    if [ "$TRANSPORT" = local ] && [ "$EXECUTE" = true ] && [ "${#AVAILABLE[@]}" -gt 1 ]; then
        for instance in ${T_INSTANCE[@]+"${T_INSTANCE[@]}"}; do
            read -r -a boxes <<<"${RUNNING_ON[$instance]:-}"
            if [ "${#boxes[@]}" -eq "${#AVAILABLE[@]}" ]; then
                info "$instance runs on this machine, which plays every box: no box is discovered for it"
                RUNNING_ON[$instance]=""
            fi
        done
    fi
    case "$TRANSPORT:$EXECUTE" in
        ssh:*) DISCOVERY_NOTE="asked ${#AVAILABLE[@]} box(es)${silent[*]:+; no answer from ${silent[*]}}" ;;
        local:true) DISCOVERY_NOTE="asked ${#AVAILABLE[@]} simulated box(es)" ;;
        *) DISCOVERY_NOTE="none (transport $TRANSPORT)" ;;
    esac
}
PLACE_HOST=() PLACE_HOW=() PLACE_FROM=() CONFLICTS=()
plan_placements() {
    local i n="${#T_INSTANCE[@]}" instance pin host best running=()
    declare -A load=()
    PLACE_HOST=() PLACE_HOW=() PLACE_FROM=() CONFLICTS=()
    for host in ${AVAILABLE[@]+"${AVAILABLE[@]}"}; do load[$host]=0; done
    # Pass 1: pinned and discovered placements count first, so the assignments balance around them.
    for ((i = 0; i < n; i++)); do
        instance="${T_INSTANCE[i]}" pin="${T_PIN[i]}"
        read -r -a running <<<"${RUNNING_ON[$instance]:-}"
        PLACE_HOST[i]="" PLACE_HOW[i]="" PLACE_FROM[i]=""
        if [ "${#running[@]}" -gt 1 ]; then
            CONFLICTS+=("$instance is running on more than one box: ${running[*]} — stop all but one (run-compose.sh ... stop)")
            PLACE_HOW[i]=conflict
            continue
        fi
        if [ -n "$pin" ]; then
            PLACE_HOST[i]="$pin" PLACE_HOW[i]=pinned
            if [ "${#running[@]}" -eq 1 ] && [ "${running[0]}" != "$pin" ]; then
                if [ "$MOVE" -eq 1 ]; then
                    PLACE_FROM[i]="${running[0]}"
                else
                    CONFLICTS+=("$instance is pinned to $pin but running on ${running[0]}: deploy --move stops it there first, or record ${running[0]} as its host in workflows-config.yml")
                    PLACE_HOW[i]=conflict
                fi
            fi
        elif [ "${#running[@]}" -eq 1 ]; then
            PLACE_HOST[i]="${running[0]}" PLACE_HOW[i]=discovered
        fi
        if [ -n "${PLACE_HOST[i]}" ] && [ -n "${load[${PLACE_HOST[i]}]+set}" ]; then
            load[${PLACE_HOST[i]}]=$((load[${PLACE_HOST[i]}] + 1))
        fi
    done
    # Pass 2: every other instance goes to the box with the fewest placements so far (ties: pool order).
    for ((i = 0; i < n; i++)); do
        [ -z "${PLACE_HOW[i]}" ] || continue
        best=""
        for host in ${AVAILABLE[@]+"${AVAILABLE[@]}"}; do
            if [ -z "$best" ] || [ "${load[$host]}" -lt "${load[$best]}" ]; then best="$host"; fi
        done
        if [ -z "$best" ]; then
            PLACE_HOW[i]=unplaced
            continue
        fi
        PLACE_HOST[i]="$best" PLACE_HOW[i]=assigned
        load[$best]=$((load[$best] + 1))
    done
}
report_conflicts() {
    local conflict
    [ "${#CONFLICTS[@]}" -gt 0 ] || return 0
    for conflict in "${CONFLICTS[@]}"; do error "placement conflict: $conflict"; done
    return 1
}
placements_json() {
    local i
    for ((i = 0; i < ${#T_INSTANCE[@]}; i++)); do
        jq -cn --arg instance "${T_INSTANCE[i]}" --arg host "${PLACE_HOST[i]:-}" --arg how "${PLACE_HOW[i]:-}" \
            --arg from "${PLACE_FROM[i]:-}" --arg result "${P_RESULT[i]:-}" --arg commands "${P_COMMANDS[i]:-}" \
            '{instance: $instance, host: (if $host == "" then null else $host end), how: $how}
             + (if $from == "" then {} else {movedFrom: $from} end)
             + (if $result == "" then {} else {result: $result, commands: ($commands | split("\n") | map(select(. != "")))} end)'
    done | jq -cs .
}
pool_header() { printf 'pool %s/%s: %s (user %s, root %s)\n' "$ENV_NAME" "$FLOW" "${POOL_HOSTS[*]}" "$POOL_USER" "$POOL_ROOT"; }

# --- deploy -----------------------------------------------------------------------------------------------

P_RESULT=() P_COMMANDS=()
FAILED=()
deployed_line() { printf 'deployed %s@%s=%s\n' "$1" "$2" "$TAG"; }
deploy_one() { # <index>
    local i="$1" instance="${T_INSTANCE[$1]}" host="${PLACE_HOST[$1]}" from="${PLACE_FROM[$1]}" cmd step lines=""
    if [ -n "$host" ]; then
        [ -z "$from" ] || lines="$(ssh_display "$from" "$instance" stop "")"$'\n'
        for cmd in pull start health; do lines="$lines$(ssh_display "$host" "$instance" "$cmd" "$TAG")"$'\n'; done
    fi
    P_COMMANDS[i]="$lines"
    if [ -z "$host" ]; then
        P_RESULT[i]="failed: no box of the pool of $ENV_NAME/$FLOW received the bundle"
        return 1
    fi
    if ! contains_word "$host" "${AVAILABLE[*]}"; then
        P_RESULT[i]="failed: $host did not receive the bundle"
        error "$instance: its box $host did not receive the bundle: not deployed"
        return 1
    fi
    case "$TRANSPORT" in
        dry-run)
            [ -z "$from" ] || on_box "$from" "$instance" stop ""
            for cmd in pull start health; do on_box "$host" "$instance" "$cmd" "$TAG"; done
            P_RESULT[i]="dry-run"
            return 0
            ;;
        local)
            if [ "$EXECUTE" = false ]; then
                # The runner plays the box: validate and start --dry-run there (the pool guard prints the peers).
                if ! local_run "$host" "$instance" validate "$TAG" >&2; then
                    P_RESULT[i]="failed: validate on $host"
                    return 1
                fi
                if ! local_run "$host" "$instance" start "$TAG" --dry-run >&2; then
                    P_RESULT[i]="failed: start --dry-run on $host"
                    return 1
                fi
                info "$instance validated on $host ($(rel "$LOCAL_ROOT")/$host$POOL_ROOT); the ssh transport would run:"
                printf '%s' "$lines" | sed 's/^/    /' >&2
                P_RESULT[i]="validated"
                deployed_line "$instance" "$host"
                return 0
            fi
            ;;
    esac
    if [ -n "$from" ]; then
        info "$instance: pinned to $host, running on $from: stopping it there first (--move)"
        if ! on_box "$from" "$instance" stop ""; then
            P_RESULT[i]="failed: stop on $from (--move)"
            return 1
        fi
    fi
    if ! on_box "$host" "$instance" pull "$TAG"; then
        P_RESULT[i]="failed: pull (nothing changed)"
        return 1
    fi
    step=start
    if on_box "$host" "$instance" start "$TAG"; then
        step=health
        if on_box "$host" "$instance" health "$TAG"; then
            P_RESULT[i]="deployed"
            deployed_line "$instance" "$host"
            return 0
        fi
    fi
    warn "$instance on $host: $step failed — starting it again without the override (compose.env on the box still holds the previous tag, D9 §6.9)"
    if on_box "$host" "$instance" start ""; then
        P_RESULT[i]="failed: $step (previous tag started again)"
    else
        P_RESULT[i]="failed: $step (starting the previous tag failed too)"
    fi
    return 1
}
write_report() {
    local host boxes
    [ -n "$REPORT" ] || return 0
    boxes="$(for host in "${POOL_HOSTS[@]}"; do
        jq -cn --arg host "$host" --arg result "${BOX_RESULT[$host]:-not synced}" --arg files "${BOX_FILES[$host]:-}" \
            --arg sha "${BOX_SHA[$host]:-}" --arg verified "${BOX_CHECK[$host]:-}" \
            '{host: $host, result: $result, files: (if $files == "" then null else ($files | tonumber) end),
              sha256: (if $sha == "" then null else $sha end), verified: $verified}'
    done | jq -cs .)"
    jq -n --arg env "$ENV_NAME" --arg flow "$FLOW" --arg tag "$TAG" --arg transport "$TRANSPORT" \
        --arg files "${BUNDLE_FILES:-0}" --arg sha "$BUNDLE_SHA256" --arg discovery "$DISCOVERY_NOTE" \
        --arg user "$POOL_USER" --arg root "$POOL_ROOT" --argjson hosts "$(json_array "${POOL_HOSTS[@]}")" \
        --argjson boxes "$boxes" --argjson placements "$(placements_json)" \
        '{env: $env, flow: $flow, tag: $tag, transport: $transport, discovery: $discovery,
          pool: {hosts: $hosts, user: $user, root: $root},
          bundle: {files: ($files | tonumber), sha256: $sha}, boxes: $boxes, placements: $placements}' >"$REPORT"
}

# --- commands ---------------------------------------------------------------------------------------------

cmd_bundle() {
    build_bundle "$OUT" "$TAG"
    cat "$OUT_DIR/.platform-bundle"
}

cmd_plan() {
    local i
    AVAILABLE=("${POOL_HOSTS[@]}")
    if transport_ready lenient; then discover_all; fi
    plan_placements
    report_conflicts || exit "$EXIT_CONFLICT"
    if [ "$JSON" -eq 1 ]; then
        jq -n --arg env "$ENV_NAME" --arg flow "$FLOW" --arg tag "$TAG" --arg transport "$TRANSPORT" \
            --arg discovery "$DISCOVERY_NOTE" --arg user "$POOL_USER" --arg root "$POOL_ROOT" \
            --argjson hosts "$(json_array "${POOL_HOSTS[@]}")" --argjson placements "$(placements_json)" \
            '{env: $env, flow: $flow, tag: (if $tag == "" then null else $tag end), transport: $transport,
              discovery: $discovery, pool: {hosts: $hosts, user: $user, root: $root}, placements: $placements}'
        return 0
    fi
    pool_header
    [ -z "$TAG" ] || printf 'tag %s\n' "$TAG"
    printf 'discovery: %s\n' "$DISCOVERY_NOTE"
    printf '%-44s %-36s %s\n' INSTANCE HOST HOW
    for ((i = 0; i < ${#T_INSTANCE[@]}; i++)); do
        printf '%-44s %-36s %s\n' "${T_INSTANCE[i]}" "${PLACE_HOST[i]:--}" "${PLACE_HOW[i]}"
    done
}

cmd_sync() {
    rsync_ready
    transport_ready
    load_bundle "$BUNDLE_ARG"
    sync_all
    [ "${#SYNC_FAILED[@]}" -eq 0 ] || die "$EXIT_FAILED" "not synced: ${SYNC_FAILED[*]}"
    info "every box of the pool of $ENV_NAME/$FLOW holds the bundle ($BUNDLE_FILES files, sha256 $BUNDLE_SHA256)"
}

cmd_discover() {
    local instance rows=() conflict=0 running=()
    transport_ready
    AVAILABLE=("${POOL_HOSTS[@]}")
    discover_all
    for instance in ${T_INSTANCE[@]+"${T_INSTANCE[@]}"}; do
        read -r -a running <<<"${RUNNING_ON[$instance]:-}"
        if [ "${#running[@]}" -gt 1 ]; then
            error "placement conflict: $instance is running on more than one box: ${running[*]}"
            conflict=1
        fi
        rows+=("$(jq -cn --arg instance "$instance" --arg running "${RUNNING_ON[$instance]:-}" --arg unknown "${UNKNOWN_ON[$instance]:-}" \
            '{instance: $instance, running: ($running | split(" ") | map(select(. != ""))),
              unknown: ($unknown | split(" ") | map(select(. != "")))}')")
    done
    if [ "$JSON" -eq 1 ]; then
        printf '%s\n' ${rows[@]+"${rows[@]}"} | jq -cs '.' | jq .
    else
        pool_header
        printf 'discovery: %s\n' "$DISCOVERY_NOTE"
        printf '%-44s %s\n' INSTANCE "RUNNING ON"
        printf '%s\n' ${rows[@]+"${rows[@]}"} | jq -r '"\(.instance)\t\(if (.running | length) == 0 then "-" else (.running | join(" ")) end)\(if (.unknown | length) > 0 then " (no answer: " + (.unknown | join(" ")) + ")" else "" end)"' |
            while IFS=$'\t' read -r instance where; do printf '%-44s %s\n' "$instance" "$where"; done
    fi
    [ "$conflict" -eq 0 ] || exit "$EXIT_CONFLICT"
}

cmd_status() {
    local host instance rc rows=() failed=0 skip
    transport_ready
    for host in "${POOL_HOSTS[@]}"; do
        skip=""
        for instance in ${T_INSTANCE[@]+"${T_INSTANCE[@]}"}; do
            rc=0
            if [ -n "$skip" ]; then
                rc=2
            else
                box_status "$host" "$instance" || rc=$?
            fi
            case "$rc" in
                0) rows+=("$(jq -cn --arg host "$host" --arg instance "$instance" --argjson status "$STATUS_JSON" \
                    '{host: $host, instance: $instance, answer: "ok", status: $status}')") ;;
                2) skip=1 failed=1
                    rows+=("$(jq -cn --arg host "$host" --arg instance "$instance" '{host: $host, instance: $instance, answer: "unreachable", status: null}')") ;;
                3) rows+=("$(jq -cn --arg host "$host" --arg instance "$instance" --arg t "$TRANSPORT" \
                    '{host: $host, instance: $instance, answer: ("not asked (transport " + $t + ")"), status: null}')") ;;
                *) failed=1
                    rows+=("$(jq -cn --arg host "$host" --arg instance "$instance" '{host: $host, instance: $instance, answer: "no status", status: null}')") ;;
            esac
        done
    done
    if [ "$JSON" -eq 1 ]; then
        printf '%s\n' ${rows[@]+"${rows[@]}"} | jq -s .
    else
        pool_header
        printf '%-36s %-44s %-8s %-8s %s\n' HOST INSTANCE RUNNING DRIFT IMAGE
        printf '%s\n' ${rows[@]+"${rows[@]}"} | jq -r 'if .status == null
            then [.host, .instance, "-", "-", .answer]
            else [.host, .instance, (.status.running | tostring), (.status.drift | tostring),
                  (if .status.runningImage == "" then .status.desired + " (desired)" else .status.runningImage end)] end | @tsv' |
            while IFS=$'\t' read -r host instance running drift image; do
                printf '%-36s %-44s %-8s %-8s %s\n' "$host" "$instance" "$running" "$drift" "$image"
            done
    fi
    [ "$failed" -eq 0 ] || exit "$EXIT_FAILED"
}

cmd_deploy() {
    local i failed=0
    rsync_ready
    transport_ready
    if [ -z "$BUNDLE_ARG" ]; then
        build_bundle "$WORK/bundle" "$TAG" >&2
        BUNDLE_ARG="$WORK/bundle"
    fi
    load_bundle "$BUNDLE_ARG"
    info "deploying $TAG to the pool of $ENV_NAME/$FLOW (${POOL_HOSTS[*]}), transport $TRANSPORT"
    sync_all
    if [ "${#AVAILABLE[@]}" -eq 0 ]; then
        write_report
        die "$EXIT_FAILED" "no box of the pool of $ENV_NAME/$FLOW received the bundle: nothing deployed"
    fi
    discover_all
    plan_placements
    if ! report_conflicts; then
        write_report
        exit "$EXIT_CONFLICT"
    fi
    for ((i = 0; i < ${#T_INSTANCE[@]}; i++)); do
        info "${T_INSTANCE[i]}: ${PLACE_HOW[i]} → ${PLACE_HOST[i]:-no box}${PLACE_FROM[i]:+ (moving from ${PLACE_FROM[i]})}"
        if ! deploy_one "$i"; then
            FAILED+=("${T_INSTANCE[i]}")
            error "${T_INSTANCE[i]}: ${P_RESULT[i]}"
        fi
    done
    write_report
    [ "${#FAILED[@]}" -eq 0 ] || failed=1
    [ "${#SYNC_FAILED[@]}" -eq 0 ] || { error "not synced: ${SYNC_FAILED[*]}"; failed=1; }
    [ "$failed" -eq 0 ] || die "$EXIT_FAILED" "deploy of $TAG to the pool of $ENV_NAME/$FLOW incomplete${FAILED[*]:+ — failed: ${FAILED[*]}}"
    case "$TRANSPORT" in
        dry-run) info "dry-run: nothing deployed (${#T_INSTANCE[@]} instance(s) of $ENV_NAME/$FLOW planned)" ;;
        local)
            if [ "$EXECUTE" = true ]; then
                info "deployed $TAG: ${#T_INSTANCE[@]} instance(s) of $ENV_NAME/$FLOW (local transport)"
            else
                info "validated $TAG: ${#T_INSTANCE[@]} instance(s) of $ENV_NAME/$FLOW on the simulated boxes under $LOCAL_ROOT"
            fi
            ;;
        *) info "deployed $TAG: ${#T_INSTANCE[@]} instance(s) of $ENV_NAME/$FLOW" ;;
    esac
}

case "$COMMAND" in
    bundle) cmd_bundle ;;
    plan) cmd_plan ;;
    sync) cmd_sync ;;
    discover) cmd_discover ;;
    deploy) cmd_deploy ;;
    status) cmd_status ;;
esac
