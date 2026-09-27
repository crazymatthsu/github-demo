#!/usr/bin/env bash
# deephaven-connectors/<AppName>/scripts/smoke.sh: post-deploy smoke test of one running instance (D8 §5.1, §6.1).
#
# Called by `run-compose.sh <env> <flow> <AppName> <AppInstance> health` once the container is ready (D6) and
# by deploy-dev (D9). The AppName is this script's subproject directory, so the three apps carry the same file
# until one adds checks of its own (target table exists, expected row count: D8 §5.1). Portable to bash 3.2.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/smoke.sh [<base-url>]
       scripts/smoke.sh <env> <flow> <AppName> <AppInstance> [<base-url>]   (as run-compose.sh health calls it)

Checks one running instance through its actuator:
  1. GET <base-url>/actuator/health/readiness answers 200 with status UP (polled for SMOKE_TIMEOUT seconds).
  2. GET <base-url>/actuator/info carries the identity APP_ENV / APP_FLOW / APP_NAME / APP_INSTANCE: its
     connector section has env, flow, app and instance set (never the "none" marker), app is this
     subproject, and each part equals the arguments, else the APP_* variable of that name when set.

<base-url> defaults to http://localhost:<port>: ACTUATOR_HOST_PORT when set, else the instance's
compose.env when the identity is given, else 18080.

Environment: SMOKE_TIMEOUT (seconds, default 60), ACTUATOR_HOST_PORT, APP_ENV, APP_FLOW, APP_NAME,
APP_INSTANCE, CONFIG_ROOT (default <repo>/config). jq is used when present.
Exit codes: 0 every check passed, 1 a check failed or the instance did not answer, 2 usage.
EOF
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
APP_DIR=$(dirname "$SCRIPT_DIR")
THIS_APP=$(basename "$APP_DIR")
REPO_ROOT=$(cd "$APP_DIR/../.." && pwd -P)
POLL_INTERVAL=3

log() { printf 'smoke: %s\n' "$*"; }
fail() {
  printf 'smoke: FAIL %s\n' "$*" >&2
  exit 1
}
usage_error() {
  printf 'smoke: error: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}
have_jq() { command -v jq >/dev/null 2>&1; }

# KEY=VALUE lookup in a compose.env file (same reading as run-compose.sh).
env_file_value() {
  awk -v k="$2" -F= '$0 !~ /^[[:space:]]*#/ && $1 == k { sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit }' "$1"
}

# --- arguments -------------------------------------------------------------------------------------------

case ${1:-} in -h | --help) usage; exit 0 ;; esac
base_url=''
want_env=${APP_ENV:-} want_flow=${APP_FLOW:-} want_app=${APP_NAME:-} want_instance=${APP_INSTANCE:-}
case $# in
  0) ;;
  1) base_url=$1 ;;
  4 | 5)
    want_env=$1 want_flow=$2 want_app=$3 want_instance=$4
    base_url=${5:-}
    ;;
  *) usage_error "expected no argument, <base-url>, or <env> <flow> <AppName> <AppInstance> [<base-url>]" ;;
esac
if [[ -n $want_app && $want_app != "$THIS_APP" ]]; then
  usage_error "this is the smoke test of $THIS_APP, not of '$want_app'"
fi
timeout=${SMOKE_TIMEOUT:-60}
[[ $timeout =~ ^[0-9]+$ ]] || usage_error "SMOKE_TIMEOUT='$timeout' is not a number of seconds"

if [[ -z $base_url ]]; then
  port=${ACTUATOR_HOST_PORT:-}
  if [[ -z $port && -n $want_env && -n $want_flow && -n $want_instance ]]; then
    env_file=${CONFIG_ROOT:-$REPO_ROOT/config}/$want_env/$want_flow/$THIS_APP/$want_instance/compose.env
    if [[ -f $env_file ]]; then port=$(env_file_value "$env_file" ACTUATOR_HOST_PORT); fi
  fi
  port=${port:-18080}
  [[ $port =~ ^[0-9]+$ ]] || usage_error "actuator port '$port' is not a number"
  base_url=http://localhost:$port
fi
base_url=${base_url%/}
[[ $base_url =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]] || usage_error "'$base_url' is not an http(s) base URL"
command -v curl >/dev/null 2>&1 || fail "curl is not installed; it is needed to call the actuator"

# --- 1. readiness ----------------------------------------------------------------------------------------

readiness_url=$base_url/actuator/health/readiness
deadline=$((SECONDS + timeout))
while :; do
  # -f: Boot answers 503 while the readiness group is not UP.
  if body=$(curl -fsS --max-time 5 "$readiness_url" 2>&1); then
    if have_jq; then
      status=$(jq -r '.status // empty' <<<"$body" 2>/dev/null || true)
    elif [[ $body == *'"status":"UP"'* ]]; then
      status=UP
    else
      status=unknown
    fi
    [[ $status == UP ]] && break
    last="status ${status:-missing}: $body"
  else
    last=$body
  fi
  if ((SECONDS >= deadline)); then fail "$readiness_url is not UP after ${timeout}s; last answer: $last"; fi
  sleep "$POLL_INTERVAL"
done
log "readiness UP ($readiness_url)"

# --- 2. identity -----------------------------------------------------------------------------------------

info_url=$base_url/actuator/info
info=$(curl -fsS --max-time 5 "$info_url" 2>&1) || fail "$info_url: $info"
if have_jq; then
  identity=$(jq -r '.connector | [.env, .flow, .app, .instance] | map(. // "") | join("/")' <<<"$info" 2>/dev/null) \
    || fail "$info_url did not answer JSON with a connector section: $info"
else
  # Compact JSON from the actuator: the connector section's "tuple" is <env>/<flow>/<app>/<instance>.
  identity=$(printf '%s' "$info" | sed -n 's/.*"tuple":"\([^"]*\)".*/\1/p')
fi
IFS=/ read -r got_env got_flow got_app got_instance got_rest <<<"$identity"
problems=''
for part in "env=$got_env" "flow=$got_flow" "app=$got_app" "instance=$got_instance"; do
  case ${part#*=} in '' | none) problems="$problems; ${part%%=*} is not set" ;; esac
done
[[ -z $got_rest ]] || problems="$problems; malformed identity '$identity'"
[[ $got_app == "$THIS_APP" ]] || problems="$problems; app is '$got_app', expected '$THIS_APP'"
for pair in "env:$got_env:$want_env" "flow:$got_flow:$want_flow" "instance:$got_instance:$want_instance"; do
  IFS=: read -r name got want <<<"$pair"
  if [[ -n $want && $got != "$want" ]]; then problems="$problems; $name is '$got', expected '$want'"; fi
done
[[ -z $problems ]] || fail "$info_url identity '${identity:-<none>}':${problems#;}"
log "identity $identity ($info_url)"
log "OK $THIS_APP at $base_url"
