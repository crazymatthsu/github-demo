#!/usr/bin/env bash
# run-compose.sh — the one entry point for a connector's compose stack (D6 §6): local development, CI test
# stacks and the dev compose hosts of demo step 1. Never qa or prod: production runs on Kubernetes (D9, D11).
#
# This is the canonical implementation; every app's scripts/run-compose.sh is a thin wrapper that execs it
# with --app-dir <its subproject>. Run with --help for the command table. On a box of a host pool (DL-39) it
# runs from the host bundle that scripts/pool-deploy.sh synced: the nearest ancestor holding .platform-bundle
# is the root, and start / restart first ask the pool's other boxes (the pool guard, D6 §6.5).
set -euo pipefail

readonly EXIT_FAILED=1 EXIT_USAGE=2 EXIT_REFUSED=3 EXIT_CONFIG=4 EXIT_ENGINE=5 EXIT_TIMEOUT=124
readonly COMMANDS="start stop down restart config app-config printenv health status ps logs pull validate exec shell version"
readonly FLOWS="cash deriv swap"
readonly COMPOSE_ENV_ALLOWED="IMAGE_REPO IMAGE_TAG APP_ENV APP_FLOW APP_NAME APP_INSTANCE JAVA_OPTS TZ LOG_LEVEL_ROOT LOGS_DIR DATA_DIR MEM_LIMIT"
readonly SCRIPT_VARIABLES="CONFIG_DIR COMMON_DIR PLATFORM_DIR ENV_COMMON_DIR PROJECT"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

usage() {
    cat <<'EOF'
Usage: run-compose.sh <env> <flow> <AppName> <AppInstance> <command> [args] [options]

  <env>          local | <region>-<stage> (only local and *-dev are allowed here)
  <flow>         cash | deriv | swap
  <AppName>      the app subproject, e.g. source-database
  <AppInstance>  the pipeline, e.g. trades-db-to-amps (config/<env>/<flow>/<AppName>/<AppInstance>/)

Commands (D6 §6.4):
  start [--no-wait]     up -d --wait (--wait-timeout $START_TIMEOUT, default 180); 124 on timeout
  stop                  stop -t $STOP_TIMEOUT (default 30)
  down [--volumes]      down --remove-orphans; --volumes adds -v (on *-dev hosts also needs --force)
  restart               stop, then start (picks up compose.env, image and mount changes)
  config                the rendered compose configuration, secrets masked
  app-config [--offline]  the app's effective configuration (actuator), or --offline: run --print-config
  printenv              the resolved environment (paths, identity, engine, compose.env), secrets masked
  health                container running and /actuator/health/readiness UP; 1 otherwise
  status | ps           ps, plus drift between the desired image and the running one; 1 on drift
  logs [-f] [--since T] [--tail N]
  pull                  pre-pull the image (the only command that contacts the registry)
  validate              offline checks: names, required files, compose.env rules, variables, compose lint
  exec <svc> <cmd...>   exec in a service (arguments after <svc> belong to the command)
  shell                 exec <AppName> sh (the app's service is named after the AppName)
  version               tag, digest and OCI labels of the running image

Options (before or after the command):
  --dry-run             print the resolved paths, identity, engine and exact command lines; run nothing
  --force               allow a guarded operation (down --volumes on *-dev; start / restart past the pool
                        guard); never overrides the env allow-list
  --engine docker|podman  force the engine (default: $RUN_COMPOSE_ENGINE, else docker, then podman)
  --json                machine-readable output for health, status and version
  -q, --quiet           less informational output
  -h, --help            this text

Exit codes: 0 ok · 1 operation failed or check negative · 2 usage · 3 refused by a safety rule ·
            4 config tree error · 5 engine not found or not running · 124 timeout
Environment: CONFIG_ROOT (default <repo>/config), START_TIMEOUT, STOP_TIMEOUT, DEPS_NETWORK (join an
existing network, e.g. the one of ./gradlew devUp), RUN_COMPOSE_ENGINE, IMAGE_TAG and IMAGE_REPO (override
compose.env in every env, e.g. deploy-dev's pull / start before the write-back, D9 §6.4; every other
compose.env value always comes from the file), APP_IMAGE (local only: run this image instead of
IMAGE_REPO/APP_NAME:IMAGE_TAG);
secrets such as SPRING_DATASOURCE_PASSWORD are passed through from this shell, never from compose.env
(D2 §8.1).

Root: the nearest ancestor of this script holding a .platform-bundle marker (a host bundle synced by
scripts/pool-deploy.sh, DL-39), else the git checkout, else the script's parent directory.
Pool guard (DL-39): on a box whose .platform-bundle lists more than one pool host (POOL_HOSTS), start and
restart of an instance of that bundle's env and flow (never local) first run
  $POOL_SSH $POOL_SSH_OPTS <POOL_USER>@<peer> -- <POOL_ROOT>/<app dir>/scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> status --json
on every other box of the pool and refuse (3) when the instance runs there; a box that does not answer is
only a warning (a dead box must not block a failover). --force skips it, --dry-run prints the peer commands.
  POOL_PEER_CHECK=off   disable the guard          POOL_SELF_HOST  this box's name in POOL_HOSTS (default hostname -f)
  POOL_SSH              ssh binary (default ssh)   POOL_SSH_OPTS   default -o BatchMode=yes -o ConnectTimeout=10
                        -o StrictHostKeyChecking=yes, plus -o UserKnownHostsFile=<CONFIG_ROOT>/<env>/known_hosts when present
EOF
}

# --- output helpers ---------------------------------------------------------------------------------------

QUIET=0
info() { if [ "$QUIET" -eq 0 ]; then printf 'run-compose: %s\n' "$*" >&2; fi; }
warn() { printf 'run-compose: warning: %s\n' "$*" >&2; }
die() {
    local code="$1"
    shift
    printf 'run-compose: error: %s\n' "$*" >&2
    exit "$code"
}
contains_word() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}
# Relative to the repository root, for readable output.
rel() { case "$1" in "$REPO_ROOT"/*) printf '%s' "${1#"$REPO_ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

# Values of secret-looking names (D6 §4.3: *PASSWORD*, *SECRET*, *TOKEN*, *KEY*; plus the D2 usernames) -> ***.
mask_stream() {
    awk '
    {
        line = $0
        if (match(line, /^[[:space:]]*-?[[:space:]]*"?[A-Za-z0-9_.-]+"?[[:space:]]*[:=]/)) {
            prefix = substr(line, 1, RLENGTH)
            key = prefix
            gsub(/^[[:space:]]*-?[[:space:]]*"?/, "", key)
            gsub(/"?[[:space:]]*[:=]$/, "", key)
            lk = tolower(key)
            if (lk ~ /(password|passwd|secret|token|credential|key)/ ||
                lk ~ /^(spring_datasource_username|connector_amps_username|connector_kafka_sasl_username)$/) {
                rest = substr(line, RLENGTH + 1)
                if (rest ~ /[^[:space:]]/) {
                    print prefix (prefix ~ /=$/ ? "***" : " ***")
                    next
                }
            }
        }
        print line
    }'
}

# --- arguments --------------------------------------------------------------------------------------------

DRY_RUN=0 FORCE=0 JSON=0 NO_WAIT=0 VOLUMES=0 OFFLINE=0 FOLLOW=0
ENGINE_CHOICE="${RUN_COMPOSE_ENGINE:-}" SINCE="" TAIL="" APP_DIR_ARG=""
POSITIONAL=()
CMD_ARGS=()
OPTS_TEXT=""
AUDIT=1
ENV_NAME="" FLOW="" APP="" INSTANCE="" COMMAND=""

need_value() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$EXIT_USAGE" "option $1 needs a value (see --help)"; fi; }

while [ $# -gt 0 ]; do
    # exec <svc> <cmd...>: once the service is known, everything else belongs to the command.
    if [ "${#POSITIONAL[@]}" -eq 5 ] && [ "${POSITIONAL[4]}" = exec ] && [ "${#CMD_ARGS[@]}" -ge 1 ]; then
        CMD_ARGS+=("$@")
        break
    fi
    case "$1" in
        --dry-run) DRY_RUN=1; OPTS_TEXT="$OPTS_TEXT --dry-run" ;;
        --force) FORCE=1; OPTS_TEXT="$OPTS_TEXT --force" ;;
        --json) JSON=1; OPTS_TEXT="$OPTS_TEXT --json" ;;
        --no-wait) NO_WAIT=1; OPTS_TEXT="$OPTS_TEXT --no-wait" ;;
        --volumes) VOLUMES=1; OPTS_TEXT="$OPTS_TEXT --volumes" ;;
        --offline) OFFLINE=1; OPTS_TEXT="$OPTS_TEXT --offline" ;;
        -q | --quiet) QUIET=1 ;;
        -f | --follow) FOLLOW=1; OPTS_TEXT="$OPTS_TEXT -f" ;;
        --engine) need_value "$@"; ENGINE_CHOICE="$2"; shift ;;
        --engine=*) ENGINE_CHOICE="${1#*=}" ;;
        --since) need_value "$@"; SINCE="$2"; shift ;;
        --since=*) SINCE="${1#*=}" ;;
        --tail) need_value "$@"; TAIL="$2"; shift ;;
        --tail=*) TAIL="${1#*=}" ;;
        --app-dir) need_value "$@"; APP_DIR_ARG="$2"; shift ;;
        --app-dir=*) APP_DIR_ARG="${1#*=}" ;;
        -h | --help) AUDIT=0; usage; exit 0 ;;
        --) shift; CMD_ARGS+=("$@"); break ;;
        -*) die "$EXIT_USAGE" "unknown option $1 (see --help)" ;;
        *)
            if [ "${#POSITIONAL[@]}" -lt 5 ]; then POSITIONAL+=("$1"); else CMD_ARGS+=("$1"); fi
            ;;
    esac
    shift
done
[ -n "$ENGINE_CHOICE" ] && OPTS_TEXT="$OPTS_TEXT --engine $ENGINE_CHOICE"

# shellcheck disable=SC2329 # invoked by the EXIT trap below
audit() {
    local result="$1"
    [ "$AUDIT" -eq 1 ] || return 0
    local who line
    who="${SUDO_USER:-${USER:-$(id -un 2>/dev/null || echo unknown)}}"
    line="ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) who=$who host=$(hostname 2>/dev/null || uname -n)"
    line="$line env=$ENV_NAME flow=$FLOW app=$APP instance=$INSTANCE cmd=$COMMAND opts=\"${OPTS_TEXT# }\" result=$result"
    [ -z "${OVERRIDES:-}" ] || line="$line override=$OVERRIDES"
    if [ -n "${GITHUB_RUN_ID:-}" ]; then
        line="$line run=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/$GITHUB_RUN_ID actor=${GITHUB_ACTOR:-unknown}"
    fi
    printf 'run-compose audit: %s\n' "$line" >&2
    if command -v logger >/dev/null 2>&1; then logger -t run-compose -- "$line" 2>/dev/null || true; fi
}
trap 'audit "$?"' EXIT

if [ "${#POSITIONAL[@]}" -lt 5 ]; then
    usage >&2
    die "$EXIT_USAGE" "expected <env> <flow> <AppName> <AppInstance> <command>, got ${#POSITIONAL[@]} argument(s)"
fi
ENV_NAME="${POSITIONAL[0]}" FLOW="${POSITIONAL[1]}" APP="${POSITIONAL[2]}" INSTANCE="${POSITIONAL[3]}" COMMAND="${POSITIONAL[4]}"

# --- validation: usage (2), safety (3) --------------------------------------------------------------------

contains_word "$COMMAND" "$COMMANDS" || die "$EXIT_USAGE" "unknown command '$COMMAND' (one of: $COMMANDS)"
case "$ENV_NAME" in
    local) ;;
    [a-z][a-z]-dev | [a-z][a-z]-qa | [a-z][a-z]-prod) ;;
    *) die "$EXIT_USAGE" "env '$ENV_NAME' must be local or <region>-<stage> (e.g. us-dev)" ;;
esac
contains_word "$FLOW" "$FLOWS" || die "$EXIT_USAGE" "flow '$FLOW' must be one of: $FLOWS"
is_token() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; }
if ! is_token "$APP" || [ "${#APP}" -gt 20 ]; then
    die "$EXIT_USAGE" "AppName '$APP' must be lower-case kebab-case, at most 20 characters"
fi
if ! is_token "$INSTANCE" || [ "${#INSTANCE}" -gt 32 ] || [ "$INSTANCE" = app-common ]; then
    die "$EXIT_USAGE" "AppInstance '$INSTANCE' must be lower-case kebab-case, at most 32 characters (not app-common)"
fi
case "$INSTANCE" in *[!0-9]*) ;; *) die "$EXIT_USAGE" "AppInstance '$INSTANCE' is a business name, never a bare number" ;; esac
if [ $((${#APP} + 1 + ${#INSTANCE})) -gt 53 ]; then
    die "$EXIT_USAGE" "'$APP-$INSTANCE' exceeds the 53-character release-name budget (D5 §6.2)"
fi
case "$ENGINE_CHOICE" in "" | docker | podman) ;; *) die "$EXIT_USAGE" "--engine must be docker or podman" ;; esac
[ "$VOLUMES" -eq 0 ] || [ "$COMMAND" = down ] || die "$EXIT_USAGE" "--volumes only applies to down"
[ "$OFFLINE" -eq 0 ] || [ "$COMMAND" = app-config ] || die "$EXIT_USAGE" "--offline only applies to app-config"
[ "$NO_WAIT" -eq 0 ] || [ "$COMMAND" = start ] || [ "$COMMAND" = restart ] || die "$EXIT_USAGE" "--no-wait only applies to start and restart"
if [ "$FOLLOW" -eq 1 ] || [ -n "$SINCE" ] || [ -n "$TAIL" ]; then
    [ "$COMMAND" = logs ] || die "$EXIT_USAGE" "-f, --since and --tail only apply to logs"
fi
case "$COMMAND" in
    exec) [ "${#CMD_ARGS[@]}" -ge 2 ] || die "$EXIT_USAGE" "usage: ... exec <service> <command...>" ;;
    *) [ "${#CMD_ARGS[@]}" -eq 0 ] || die "$EXIT_USAGE" "unexpected argument(s) for $COMMAND: ${CMD_ARGS[*]}" ;;
esac

# Env allow-list (D6 §6.5): --force never overrides it.
case "$ENV_NAME" in
    local | *-dev) ;;
    *) die "$EXIT_REFUSED" "env '$ENV_NAME' refused: production operations go through Kubernetes — see D9 / D11 (run-compose.sh serves local and *-dev only)" ;;
esac
if [ "$COMMAND" = down ] && [ "$VOLUMES" -eq 1 ] && [ "$ENV_NAME" != local ] && [ "$FORCE" -eq 0 ]; then
    die "$EXIT_REFUSED" "down --volumes on a $ENV_NAME host removes data: add --force to confirm"
fi

# --- path resolution (D6 §6.2) and config-tree checks (4) -------------------------------------------------

# The nearest ancestor of $1 (itself included) that holds a .platform-bundle marker: the root of a host bundle
# that scripts/pool-deploy.sh synced to a box of a pool (DL-39).
find_bundle_root() {
    local dir="$1"
    while :; do
        if [ -f "$dir/.platform-bundle" ]; then
            printf '%s' "$dir"
            return 0
        fi
        [ "$dir" != / ] || return 1
        dir="$(dirname "$dir")"
    done
}
# One value of the bundle manifest: KEY=value lines, the value optionally in double quotes. Read, never sourced.
bundle_value() {
    [ -n "$BUNDLE_ROOT" ] || return 0
    awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/^"|"$/, "", v); print v; exit }' \
        "$BUNDLE_ROOT/.platform-bundle"
}
BUNDLE_ROOT="$(find_bundle_root "$SCRIPT_DIR" || true)"
if [ -n "$BUNDLE_ROOT" ]; then
    REPO_ROOT="$BUNDLE_ROOT"
else
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd -P))"
fi
if [ -n "$APP_DIR_ARG" ]; then
    [ -d "$APP_DIR_ARG" ] || die "$EXIT_CONFIG" "app directory not found: $APP_DIR_ARG"
    APP_DIR="$(cd "$APP_DIR_ARG" && pwd -P)"
    [ "$(basename "$APP_DIR")" = "$APP" ] ||
        die "$EXIT_USAGE" "this script belongs to $(basename "$APP_DIR"), not to '$APP'"
else
    APP_DIR=""
    for candidate in "$REPO_ROOT/$APP" "$REPO_ROOT"/*/"$APP"; do
        if [ -f "$candidate/docker/docker-compose.yml" ]; then APP_DIR="$candidate"; break; fi
    done
    [ -n "$APP_DIR" ] || die "$EXIT_CONFIG" "no subproject '$APP' with docker/docker-compose.yml under $REPO_ROOT"
fi
CONFIG_ROOT="${CONFIG_ROOT:-$REPO_ROOT/config}"
ENV_DIR="$CONFIG_ROOT/$ENV_NAME"
APP_CONFIG_DIR="$ENV_DIR/$FLOW/$APP"
COMMON_DIR="$APP_CONFIG_DIR/app-common"
CONFIG_DIR="$APP_CONFIG_DIR/$INSTANCE"
COMPOSE_FILE="$APP_DIR/docker/docker-compose.yml"
ENV_FILE="$CONFIG_DIR/compose.env"
PLATFORM_DIR=""
ENV_COMMON_DIR=""
[ -d "$CONFIG_ROOT/_common/$APP" ] && PLATFORM_DIR="$CONFIG_ROOT/_common/$APP"
[ -d "$ENV_DIR/_common" ] && ENV_COMMON_DIR="$ENV_DIR/_common"

for dir in "$ENV_DIR" "$ENV_DIR/$FLOW" "$APP_CONFIG_DIR" "$COMMON_DIR" "$CONFIG_DIR"; do
    [ -d "$dir" ] || die "$EXIT_CONFIG" "config tree: directory missing: $(rel "$dir")"
done
for file in "$COMMON_DIR/application.yml" "$CONFIG_DIR/application.yml" "$ENV_FILE" "$COMPOSE_FILE"; do
    [ -f "$file" ] || die "$EXIT_CONFIG" "config tree: required file missing: $(rel "$file")"
done

# compose.env: KEY=VALUE lines only, allowed variables only (D5 §6.3), identity equal to the path (D5 check 4).
env_value() { awk -v k="$1" -F= '$0 !~ /^[[:space:]]*#/ && $1 == k { sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit }' "$ENV_FILE"; }
ENV_KEYS=""
problems=""
while IFS= read -r raw || [ -n "$raw" ]; do
    line="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$line" in "" | "#"*) continue ;; esac
    key="${line%%=*}"
    if [ "$key" = "$line" ] || ! printf '%s' "$key" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
        problems="$problems\n  not KEY=VALUE: $line"
        continue
    fi
    ENV_KEYS="$ENV_KEYS $key"
    case "$key" in
        SPRING_* | LOGGING_* | MANAGEMENT_* | CONNECTOR_*) problems="$problems\n  $key is forbidden (YAML or shell pass-through, D5 §6.3)" ;;
        *_HOST_PORT) ;;
        *)
            if contains_word "$key" "$SCRIPT_VARIABLES"; then
                problems="$problems\n  $key is set by run-compose.sh, never in compose.env"
            elif ! contains_word "$key" "$COMPOSE_ENV_ALLOWED"; then
                problems="$problems\n  $key is not an allowed compose.env variable (D5 §6.3)"
            fi
            ;;
    esac
done <"$ENV_FILE"
for pair in "APP_ENV=$ENV_NAME" "APP_FLOW=$FLOW" "APP_NAME=$APP" "APP_INSTANCE=$INSTANCE"; do
    key="${pair%%=*}"
    actual="$(env_value "$key")"
    [ "$actual" = "${pair#*=}" ] || problems="$problems\n  $key='$actual' must restate the path ('${pair#*=}')"
done
if [ -n "$problems" ]; then
    printf 'run-compose: error: %s:%b\n' "$(rel "$ENV_FILE")" "$problems" >&2
    exit "$EXIT_CONFIG"
fi

# --- environment for the template (D6 §6.2, §6.6) ---------------------------------------------------------

PROJECT="$ENV_NAME-$FLOW-$APP-$INSTANCE"
if [ -n "${GITHUB_RUN_ID:-}" ]; then
    export CI_RUN_ID="${CI_RUN_ID:-$GITHUB_RUN_ID}" CI_RUN_ATTEMPT="${CI_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}"
    # CI test stacks (env local) get the run-scoped prefix that D10's teardown and leak check match; a *-dev
    # host keeps its stable name so that a redeploy replaces the stack instead of starting a second one.
    [ "$ENV_NAME" = local ] && PROJECT="ci-$GITHUB_RUN_ID-${GITHUB_RUN_ATTEMPT:-1}-$PROJECT"
fi
# compose.env is the default for every variable it defines; only IMAGE_REPO and IMAGE_TAG may be overridden
# from this shell, in every allowed env (deploy-dev injects IMAGE_TAG for pull / start before its write-back
# persists it, D9 §6.4). Overrides are announced and recorded in the audit line. APP_IMAGE is local only.
OVERRIDES=""
for key in $ENV_KEYS; do
    case "$key" in IMAGE_REPO | IMAGE_TAG) ;; *) unset "$key" 2>/dev/null || true ;; esac
done
[ "$ENV_NAME" = local ] || unset APP_IMAGE
for key in IMAGE_REPO IMAGE_TAG; do
    value="${!key:-}"
    if [ -n "$value" ] && [ "$value" != "$(env_value "$key")" ]; then
        case "$key" in
            IMAGE_TAG) pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}(@sha256:[0-9a-f]{64})?$' ;;
            *) pattern='^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$' ;;
        esac
        printf '%s' "$value" | grep -Eq "$pattern" || die "$EXIT_USAGE" "$key='$value' is not a valid override"
        info "$key=$value from the environment overrides compose.env ($(env_value "$key"))"
        OVERRIDES="$OVERRIDES,$key"
        export "${key?}"
    else
        unset "$key"
    fi
done
OVERRIDES="${OVERRIDES#,}"
export APP_ENV="$ENV_NAME" APP_FLOW="$FLOW" APP_NAME="$APP" APP_INSTANCE="$INSTANCE"
export CONFIG_DIR COMMON_DIR PROJECT
if [ -n "$PLATFORM_DIR" ]; then export PLATFORM_DIR; else unset PLATFORM_DIR; fi
if [ -n "$ENV_COMMON_DIR" ]; then export ENV_COMMON_DIR; else unset ENV_COMMON_DIR; fi
if [ -n "${DEPS_NETWORK:-}" ]; then export DEPS_NETWORK DEPS_NETWORK_EXTERNAL=true; else unset DEPS_NETWORK DEPS_NETWORK_EXTERNAL; fi
SELINUX_LABEL_SHARED="" SELINUX_LABEL_PRIVATE=""
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    SELINUX_LABEL_SHARED=",z" SELINUX_LABEL_PRIVATE=",Z"
fi
export SELINUX_LABEL_SHARED SELINUX_LABEL_PRIVATE
START_TIMEOUT="${START_TIMEOUT:-180}"
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
IMAGE_REF="${IMAGE_REPO:-$(env_value IMAGE_REPO)}/$APP:${IMAGE_TAG:-$(env_value IMAGE_TAG)}"
[ -z "${APP_IMAGE:-}" ] || IMAGE_REF="$APP_IMAGE"
ACTUATOR_PORT="$(env_value ACTUATOR_HOST_PORT)"

# Required template variables (${VAR:?...}) that nobody provides: the secrets of D2 §8.1.
missing_required() {
    local var out=""
    # shellcheck disable=SC2013 # variable names never contain whitespace
    for var in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:?\?' "$COMPOSE_FILE" | sed -e 's/^\${//' -e 's/:*?$//' | sort -u); do
        if [ -z "${!var:-}" ] && ! contains_word "$var" "$ENV_KEYS"; then out="$out $var"; fi
    done
    printf '%s' "${out# }"
}
MISSING="$(missing_required)"
case "$COMMAND" in
    start | restart | validate) NEEDS_SECRETS=1 ;;
    app-config) NEEDS_SECRETS="$OFFLINE" ;;
    *) NEEDS_SECRETS=0 ;;
esac
if [ -n "$MISSING" ]; then
    if [ "$NEEDS_SECRETS" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        die "$EXIT_FAILED" "set $MISSING in this shell first (secrets pass through, never from compose.env — D2 §8.1)"
    fi
    # ps, logs, stop, down, pull ... never use the values: placeholders keep the template interpolating.
    for var in $MISSING; do export "$var=unset-for-$COMMAND"; done
    [ "$DRY_RUN" -eq 0 ] || info "not set in this shell: $MISSING (start, restart, validate and app-config --offline need them)"
fi

# --- pool guard (DL-39, D6 §6.5): one running copy of an instance across the boxes of its pool ------------

POOL_PEERS=()   # the other boxes of the pool when the guard applies
POOL_SSH_ARGS=()
POOL_GUARD_NOTE="" # why the guard does not apply to this start / restart (shown by --dry-run)
setup_pool_guard() {
    local hosts=() host self short matches=() user root
    case "$COMMAND" in start | restart) ;; *) return 0 ;; esac
    [ -n "$BUNDLE_ROOT" ] && [ "$ENV_NAME" != local ] || return 0
    [ "$(bundle_value BUNDLE_ENV)" = "$ENV_NAME" ] && [ "$(bundle_value BUNDLE_FLOW)" = "$FLOW" ] || return 0
    read -r -a hosts <<<"$(bundle_value POOL_HOSTS)"
    [ "${#hosts[@]}" -gt 1 ] || return 0
    user="$(bundle_value POOL_USER)"
    root="$(bundle_value POOL_ROOT)"
    for host in "${hosts[@]}"; do
        printf '%s' "$host" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' ||
            die "$EXIT_CONFIG" "$(rel "$BUNDLE_ROOT/.platform-bundle"): POOL_HOSTS entry '$host' is not a host name"
    done
    printf '%s' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' ||
        die "$EXIT_CONFIG" "$(rel "$BUNDLE_ROOT/.platform-bundle"): POOL_USER '$user' is not a login name"
    printf '%s' "$root" | grep -Eq '^(/[A-Za-z0-9._-]+)+/?$' ||
        die "$EXIT_CONFIG" "$(rel "$BUNDLE_ROOT/.platform-bundle"): POOL_ROOT '$root' is not an absolute path"
    if [ "${POOL_PEER_CHECK:-on}" = off ]; then
        POOL_GUARD_NOTE="off (POOL_PEER_CHECK=off)"
        return 0
    fi
    if [ "$FORCE" -eq 1 ]; then
        POOL_GUARD_NOTE="skipped (--force)"
        return 0
    fi
    # This box: POOL_SELF_HOST as given, else its FQDN — or the one pool host whose first label is its short name.
    self="${POOL_SELF_HOST:-}"
    if [ -z "$self" ]; then
        self="$(hostname -f 2>/dev/null || true)"
        [ -n "$self" ] || self="$(hostname 2>/dev/null || uname -n)"
        self="$(printf '%s' "$self" | tr '[:upper:]' '[:lower:]')"
        if ! contains_word "$self" "${hosts[*]}"; then
            short="${self%%.*}"
            for host in "${hosts[@]}"; do [ "${host%%.*}" != "$short" ] || matches+=("$host"); done
            [ "${#matches[@]}" -ne 1 ] || self="${matches[0]}"
        fi
    fi
    contains_word "$self" "${hosts[*]}" ||
        warn "this machine ($self) is not one of POOL_HOSTS: asking every box of the pool (set POOL_SELF_HOST to its name there)"
    for host in "${hosts[@]}"; do [ "$host" = "$self" ] || POOL_PEERS+=("$host"); done
    if [ -n "${POOL_SSH_OPTS:-}" ]; then
        read -r -a POOL_SSH_ARGS <<<"$POOL_SSH_OPTS"
    else
        # Never trust an unknown host key: the reviewed known_hosts of the env when the bundle carries it, else
        # the deploy user's own.
        POOL_SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes)
        [ ! -f "$ENV_DIR/known_hosts" ] || POOL_SSH_ARGS+=(-o "UserKnownHostsFile=$ENV_DIR/known_hosts")
    fi
    POOL_USER_NAME="$user" POOL_ROOT_DIR="${root%/}"
}
# The peer's copy of this command (the same app directory under the pool's root) as an argument vector.
PEER_CMD=()
peer_command() {
    local app_rel="${APP_DIR#"$REPO_ROOT"/}" remote
    [ "$app_rel" != "$APP_DIR" ] || app_rel="deephaven-connectors/$APP"
    remote="$(printf '%q ' "$POOL_ROOT_DIR/$app_rel/scripts/run-compose.sh" "$ENV_NAME" "$FLOW" "$APP" "$INSTANCE" status --json)"
    PEER_CMD=("${POOL_SSH:-ssh}" "${POOL_SSH_ARGS[@]+"${POOL_SSH_ARGS[@]}"}" "$POOL_USER_NAME@$1" -- "${remote% }")
}
# For --dry-run: a command line as it would be typed (arguments with spaces in single quotes).
quote_words() {
    local out="" word sq="'"
    for word in "$@"; do
        case "$word" in *[!A-Za-z0-9_./:=@,+-]*) word="$sq${word//$sq/$sq\\$sq$sq}$sq" ;; esac
        out="$out $word"
    done
    printf '%s' "${out# }"
}
run_pool_guard() {
    local peer out rc running last
    [ "${#POOL_PEERS[@]}" -gt 0 ] && [ "$DRY_RUN" -eq 0 ] || return 0
    if ! command -v "${POOL_SSH:-ssh}" >/dev/null 2>&1; then
        warn "pool guard: ${POOL_SSH:-ssh} not found, so the other boxes (${POOL_PEERS[*]}) cannot be asked; continuing"
        return 0
    fi
    for peer in "${POOL_PEERS[@]}"; do
        peer_command "$peer"
        rc=0
        if command -v timeout >/dev/null 2>&1; then
            out="$(timeout 60 "${PEER_CMD[@]}" 2>&1 </dev/null)" || rc=$?
        else
            out="$("${PEER_CMD[@]}" 2>&1 </dev/null)" || rc=$?
        fi
        running="$(printf '%s\n' "$out" | grep '^{' | tail -n 1 | sed -nE 's/.*"running":(true|false).*/\1/p' || true)"
        case "$running" in
            true) die "$EXIT_REFUSED" "$INSTANCE is already running on $peer; stop it there first, or --force" ;;
            false) info "pool guard: $INSTANCE is not running on $peer" ;;
            *)
                last="$(printf '%s\n' "$out" | grep -v -e '^{' -e '^[[:space:]]*$' | tail -n 1 || true)"
                warn "pool guard: could not ask $peer whether $INSTANCE runs there (exit $rc${last:+: $last}); continuing — a box that does not answer must not block a failover"
                ;;
        esac
    done
}
POOL_USER_NAME="" POOL_ROOT_DIR=""
setup_pool_guard
run_pool_guard

# --- engine (D6 §6.6) -------------------------------------------------------------------------------------

ENGINE="" COMPOSE_KIND=""
COMPOSE=()
detect_engine() {
    if { [ -z "$ENGINE_CHOICE" ] || [ "$ENGINE_CHOICE" = docker ]; } &&
        command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ENGINE=docker COMPOSE_KIND=plugin
        COMPOSE=(docker compose)
        return 0
    fi
    if [ -z "$ENGINE_CHOICE" ] || [ "$ENGINE_CHOICE" = podman ]; then
        if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
            ENGINE=podman COMPOSE_KIND=plugin
            COMPOSE=(podman compose)
            return 0
        fi
        if command -v podman-compose >/dev/null 2>&1; then
            ENGINE=podman COMPOSE_KIND=python
            COMPOSE=(podman-compose)
            return 0
        fi
    fi
    return 1
}
case "$COMMAND" in
    printenv) NEEDS_CLI=0 NEEDS_DAEMON=0 ;;
    config) NEEDS_CLI=1 NEEDS_DAEMON=0 ;;
    validate) NEEDS_CLI=0 NEEDS_DAEMON=0 ;;
    app-config) NEEDS_CLI="$OFFLINE" NEEDS_DAEMON="$OFFLINE" ;;
    *) NEEDS_CLI=1 NEEDS_DAEMON=1 ;;
esac
if ! detect_engine; then
    if [ "$DRY_RUN" -eq 1 ] || [ "$NEEDS_CLI" -eq 0 ]; then
        ENGINE="${ENGINE_CHOICE:-docker}" COMPOSE_KIND=none
        COMPOSE=("$ENGINE" compose)
        [ "$NEEDS_CLI" -eq 0 ] || warn "no compose CLI found (docker compose, podman compose, podman-compose); showing '${COMPOSE[*]}'"
    else
        die "$EXIT_ENGINE" "no compose CLI found: install Docker with the compose plugin, or Podman with podman compose / podman-compose"
    fi
fi
if [ "$ENGINE" = podman ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/podman/podman.sock" ]; then
    export DOCKER_HOST="${DOCKER_HOST:-unix://$XDG_RUNTIME_DIR/podman/podman.sock}"
fi
if [ "$NEEDS_DAEMON" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && ! "$ENGINE" info >/dev/null 2>&1; then
    if [ "$ENGINE" = podman ]; then
        die "$EXIT_ENGINE" "podman is not usable: try 'systemctl --user start podman.socket' (rootless) or 'podman machine start'"
    fi
    die "$EXIT_ENGINE" "the Docker daemon is not running or not reachable (docker info failed)"
fi

# --- execution helpers ------------------------------------------------------------------------------------

compose_line() { printf '%s -p %s --env-file %s -f %s' "${COMPOSE[*]}" "$PROJECT" "$ENV_FILE" "$COMPOSE_FILE"; }
show_plan() {
    [ "$DRY_RUN" -eq 1 ] || return 0
    printf 'run-compose.sh --dry-run: %s %s %s %s %s (nothing is executed)\n' "$ENV_NAME" "$FLOW" "$APP" "$INSTANCE" "$COMMAND"
    printf '  %-13s %s\n' "repo root" "$REPO_ROOT" "app dir" "$(rel "$APP_DIR")" "config root" "$(rel "$CONFIG_ROOT")" \
        "platform dir" "$(rel "${PLATFORM_DIR:--}")" "env dir" "$(rel "${ENV_COMMON_DIR:--}")" \
        "common dir" "$(rel "$COMMON_DIR")" "config dir" "$(rel "$CONFIG_DIR")" \
        "compose file" "$(rel "$COMPOSE_FILE")" "env file" "$(rel "$ENV_FILE")" "project" "$PROJECT" \
        "identity" "APP_ENV=$APP_ENV APP_FLOW=$APP_FLOW APP_NAME=$APP_NAME APP_INSTANCE=$APP_INSTANCE" \
        "image" "$IMAGE_REF" "engine" "$ENGINE (${COMPOSE[*]})" "deps network" "${DEPS_NETWORK:--}"
    if [ -n "$BUNDLE_ROOT" ]; then
        printf '  %-13s %s/%s, tag %s, %s files, sha256 %.12s…, pool %s\n' "host bundle" "$(bundle_value BUNDLE_ENV)" \
            "$(bundle_value BUNDLE_FLOW)" "$(bundle_value BUNDLE_TAG)" "$(bundle_value BUNDLE_FILES)" \
            "$(bundle_value BUNDLE_SHA256)" "$(bundle_value POOL_HOSTS)"
    fi
    if [ -n "$POOL_GUARD_NOTE" ]; then
        printf '  %-13s %s\n' "peer check" "$POOL_GUARD_NOTE"
    else
        local peer
        for peer in ${POOL_PEERS[@]+"${POOL_PEERS[@]}"}; do
            peer_command "$peer"
            printf '  %-13s %s\n' "peer check" "$(quote_words "${PEER_CMD[@]}")"
        done
    fi
}
# Runs (or, with --dry-run, prints) one compose command; returns its exit code.
compose() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  %-13s %s %s\n' "command" "$(compose_line)" "$*"
        return 0
    fi
    info "$(compose_line) $*"
    "${COMPOSE[@]}" -p "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}
plan_step() { [ "$DRY_RUN" -eq 0 ] || printf '  %-13s %s\n' "then" "$*"; }
readiness_url() { printf 'http://127.0.0.1:%s/actuator/health/readiness' "$ACTUATOR_PORT"; }
app_container() { "${COMPOSE[@]}" -p "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps -q "$APP" 2>/dev/null | head -n 1; }
http_get() { curl -fsS --max-time 5 "$1"; }

wait_ready() {
    # podman-compose (python) has no `up --wait`: poll the readiness probe instead.
    local deadline=$(($(date +%s) + START_TIMEOUT))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if http_get "$(readiness_url)" >/dev/null 2>&1; then return 0; fi
        sleep 3
    done
    return "$EXIT_TIMEOUT"
}

cmd_start() {
    local rc=0 started
    started="$(date +%s)"
    if [ "$NO_WAIT" -eq 1 ]; then
        compose up -d || rc=$?
    elif [ "$COMPOSE_KIND" = python ]; then
        compose up -d || rc=$?
        plan_step "poll $(readiness_url) for up to ${START_TIMEOUT}s"
        if [ "$rc" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then wait_ready || rc=$?; fi
    else
        compose up -d --wait --wait-timeout "$START_TIMEOUT" || rc=$?
        if [ "$rc" -ne 0 ] && [ $(($(date +%s) - started)) -ge "$START_TIMEOUT" ]; then rc="$EXIT_TIMEOUT"; fi
    fi
    if [ "$rc" -ne 0 ]; then
        warn "start failed (exit $rc); last log lines:"
        "${COMPOSE[@]}" -p "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs --tail 50 >&2 2>&1 || true
        [ "$rc" -eq "$EXIT_TIMEOUT" ] && return "$EXIT_TIMEOUT"
        return "$EXIT_FAILED"
    fi
    [ "$DRY_RUN" -eq 1 ] || info "$PROJECT is up$([ "$NO_WAIT" -eq 1 ] && echo ' (not waiting for health)' || echo ' and healthy')"
}

cmd_health() {
    local cid="" body="" status="DOWN" running=false rc=0
    if [ "$DRY_RUN" -eq 1 ]; then
        compose ps -q "$APP"
        plan_step "curl -fsS $(readiness_url)"
        [ -x "$APP_DIR/scripts/smoke.sh" ] && plan_step "$(rel "$APP_DIR/scripts/smoke.sh")"
        return 0
    fi
    cid="$(app_container)"
    if [ -n "$cid" ]; then
        running=true
        if body="$(http_get "$(readiness_url)" 2>/dev/null)" && printf '%s' "$body" | grep -q '"status":"UP"'; then
            status=UP
        fi
    fi
    if [ "$status" = UP ] && [ -x "$APP_DIR/scripts/smoke.sh" ]; then
        CONFIG_ROOT="$CONFIG_ROOT" "$APP_DIR/scripts/smoke.sh" "$ENV_NAME" "$FLOW" "$APP" "$INSTANCE" >&2 ||
            { status=SMOKE_FAILED; rc="$EXIT_FAILED"; }
    fi
    [ "$status" = UP ] || rc="$EXIT_FAILED"
    if [ "$JSON" -eq 1 ]; then
        printf '{"project":%s,"running":%s,"readiness":%s,"url":%s}\n' "$(json_str "$PROJECT")" "$running" \
            "$(json_str "$status")" "$(json_str "$(readiness_url)")"
    else
        printf '%s: %s (container %s)\n' "$PROJECT" "$status" "$([ "$running" = true ] && echo running || echo 'not running')"
    fi
    return "$rc"
}

cmd_status() {
    local cid running_ref="" running_id="" desired_id="" drift=false rc=0
    compose ps
    if [ "$DRY_RUN" -eq 1 ]; then
        plan_step "$ENGINE inspect <app container>  vs  $ENGINE image inspect $IMAGE_REF"
        return 0
    fi
    cid="$(app_container)"
    if [ -z "$cid" ]; then
        rc="$EXIT_FAILED"
        drift=unknown
    else
        running_ref="$("$ENGINE" inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
        running_id="$("$ENGINE" inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)"
        desired_id="$("$ENGINE" image inspect --format '{{.Id}}' "$IMAGE_REF" 2>/dev/null || true)"
        if [ "$running_ref" != "$IMAGE_REF" ] || [ -z "$desired_id" ] || [ "$running_id" != "$desired_id" ]; then
            drift=true
            rc="$EXIT_FAILED"
        fi
    fi
    if [ "$JSON" -eq 1 ]; then
        printf '{"project":%s,"running":%s,"desired":%s,"runningImage":%s,"runningId":%s,"desiredId":%s,"drift":%s}\n' \
            "$(json_str "$PROJECT")" "$([ -n "$cid" ] && echo true || echo false)" "$(json_str "$IMAGE_REF")" \
            "$(json_str "$running_ref")" "$(json_str "$running_id")" "$(json_str "$desired_id")" "$(json_str "$drift")"
    else
        printf 'desired %s; running %s; drift: %s\n' "$IMAGE_REF" "${running_ref:-(not running)}" "$drift"
    fi
    return "$rc"
}

image_label() { "$ENGINE" image inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true; }

cmd_version() {
    local cid image_id image digest
    if [ "$DRY_RUN" -eq 1 ]; then
        compose ps -q "$APP"
        plan_step "$ENGINE inspect <app container>; $ENGINE image inspect <image> (tag, digest, OCI labels)"
        return 0
    fi
    cid="$(app_container)"
    [ -n "$cid" ] || { warn "$PROJECT is not running"; return "$EXIT_FAILED"; }
    image="$("$ENGINE" inspect --format '{{.Config.Image}}' "$cid")"
    image_id="$("$ENGINE" inspect --format '{{.Image}}' "$cid")"
    digest="$("$ENGINE" image inspect --format '{{join .RepoDigests ","}}' "$image_id" 2>/dev/null || true)"
    if [ "$JSON" -eq 1 ]; then
        printf '{"image":%s,"digest":%s,"version":%s,"revision":%s,"source":%s,"created":%s,"buildUrl":%s}\n' \
            "$(json_str "$image")" "$(json_str "$digest")" \
            "$(json_str "$(image_label "$image_id" org.opencontainers.image.version)")" \
            "$(json_str "$(image_label "$image_id" org.opencontainers.image.revision)")" \
            "$(json_str "$(image_label "$image_id" org.opencontainers.image.source)")" \
            "$(json_str "$(image_label "$image_id" org.opencontainers.image.created)")" \
            "$(json_str "$(image_label "$image_id" com.example.build-url)")"
    else
        printf 'image     %s\ndigest    %s\nversion   %s\nrevision  %s\nsource    %s\ncreated   %s\nbuild-url %s\n' \
            "$image" "$digest" "$(image_label "$image_id" org.opencontainers.image.version)" \
            "$(image_label "$image_id" org.opencontainers.image.revision)" \
            "$(image_label "$image_id" org.opencontainers.image.source)" \
            "$(image_label "$image_id" org.opencontainers.image.created)" \
            "$(image_label "$image_id" com.example.build-url)"
    fi
}

cmd_printenv() {
    {
        printf 'REPO_ROOT=%s\nAPP_DIR=%s\nCONFIG_ROOT=%s\nCONFIG_DIR=%s\nCOMMON_DIR=%s\nPLATFORM_DIR=%s\nENV_COMMON_DIR=%s\n' \
            "$REPO_ROOT" "$APP_DIR" "$CONFIG_ROOT" "$CONFIG_DIR" "$COMMON_DIR" "${PLATFORM_DIR:-}" "${ENV_COMMON_DIR:-}"
        printf 'COMPOSE_FILE=%s\nENV_FILE=%s\nPROJECT=%s\nENGINE=%s\nCOMPOSE=%s\n' \
            "$COMPOSE_FILE" "$ENV_FILE" "$PROJECT" "$ENGINE" "${COMPOSE[*]}"
        printf 'APP_ENV=%s\nAPP_FLOW=%s\nAPP_NAME=%s\nAPP_INSTANCE=%s\nDEPS_NETWORK=%s\nSELINUX_LABEL_SHARED=%s\n' \
            "$APP_ENV" "$APP_FLOW" "$APP_NAME" "$APP_INSTANCE" "${DEPS_NETWORK:-}" "$SELINUX_LABEL_SHARED"
        printf '# compose.env (%s)\n' "$(rel "$ENV_FILE")"
        grep -Ev '^[[:space:]]*(#|$)' "$ENV_FILE"
        printf '# passed through from this shell\n'
        # shellcheck disable=SC2013 # variable names never contain whitespace
        for var in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:?\?' "$COMPOSE_FILE" | sed -e 's/^\${//' -e 's/:*?$//' | sort -u); do
            if ! contains_word "$var" "$ENV_KEYS" && ! contains_word "$var" "$SCRIPT_VARIABLES APP_ENV APP_FLOW APP_NAME APP_INSTANCE"; then
                if contains_word "$var" "$MISSING"; then printf '%s=<unset>\n' "$var"; else printf '%s=%s\n' "$var" "${!var}"; fi
            fi
        done
    } | mask_stream
}

cmd_validate() {
    local rc=0 var used
    # Every ${VAR} of the template is defined by compose.env, the identity / script set, or this shell.
    used="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' "$COMPOSE_FILE" | sed 's/^\${//' | sort -u)"
    for var in $used; do
        if ! contains_word "$var" "$ENV_KEYS" && [ -z "${!var+set}" ] &&
            ! grep -Eq "\\$\\{$var:?-" "$COMPOSE_FILE"; then
            warn "template variable $var has no value and no default"
            rc="$EXIT_FAILED"
        fi
    done
    if [ "$COMPOSE_KIND" = none ]; then
        warn "no compose CLI: skipped the 'config --quiet' lint"
    else
        compose config --quiet || rc="$EXIT_FAILED"
    fi
    [ "$rc" -ne 0 ] || [ "$DRY_RUN" -eq 1 ] || info "$ENV_NAME/$FLOW/$APP/$INSTANCE is valid ($(rel "$CONFIG_DIR"))"
    return "$rc"
}

cmd_app_config() {
    if [ "$OFFLINE" -eq 1 ]; then
        compose run --rm --no-deps -T "$APP" --print-config | mask_stream
        return "${PIPESTATUS[0]}"
    fi
    local url="http://127.0.0.1:$ACTUATOR_PORT/actuator/connectorconfig"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  %-13s curl -fsS %s\n' "command" "$url"
        return 0
    fi
    http_get "$url" | mask_stream || { warn "$url did not answer: is the stack up? (or use --offline)"; return "$EXIT_FAILED"; }
    printf '\n'
}

# --- dispatch (D6 §6.4) -----------------------------------------------------------------------------------

show_plan
rc=0
case "$COMMAND" in
    start) cmd_start || rc=$? ;;
    stop) compose stop -t "$STOP_TIMEOUT" || rc="$EXIT_FAILED" ;;
    down)
        if [ "$VOLUMES" -eq 1 ]; then compose down --remove-orphans -v || rc="$EXIT_FAILED"; else compose down --remove-orphans || rc="$EXIT_FAILED"; fi
        ;;
    restart)
        compose stop -t "$STOP_TIMEOUT" || rc="$EXIT_FAILED"
        if [ "$rc" -eq 0 ]; then cmd_start || rc=$?; fi
        ;;
    config)
        if [ "$DRY_RUN" -eq 1 ]; then compose config; else compose config | mask_stream || rc="$EXIT_FAILED"; fi
        ;;
    app-config) cmd_app_config || rc=$? ;;
    printenv) if [ "$DRY_RUN" -eq 1 ]; then plan_step "print the resolved environment"; else cmd_printenv; fi ;;
    health) cmd_health || rc=$? ;;
    status | ps) cmd_status || rc=$? ;;
    logs)
        args=(logs)
        [ "$FOLLOW" -eq 1 ] && args+=(-f)
        [ -n "$SINCE" ] && args+=(--since "$SINCE")
        [ -n "$TAIL" ] && args+=(--tail "$TAIL")
        compose "${args[@]}" || rc="$EXIT_FAILED"
        ;;
    pull) compose pull || rc="$EXIT_FAILED" ;;
    validate) cmd_validate || rc=$? ;;
    exec)
        tty_flag=()
        [ -t 0 ] || tty_flag=(-T)
        compose exec "${tty_flag[@]+"${tty_flag[@]}"}" "${CMD_ARGS[@]}" || rc=$?
        ;;
    shell)
        tty_flag=()
        [ -t 0 ] || tty_flag=(-T)
        compose exec "${tty_flag[@]+"${tty_flag[@]}"}" "$APP" sh || rc=$?
        ;;
    version) cmd_version || rc=$? ;;
esac
exit "$rc"
