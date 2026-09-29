#!/usr/bin/env bash
# stack.sh: lifecycle of a throwaway docker compose test stack: up | status | diagnostics | down | leak-check.
#
# One script for every caller: the CI workflow steps (through .github/actions/compose-stack), build-tool
# tasks and developers run the same commands against the same files, so a laptop reproduces CI exactly.
# Keep it next to the compose files (test-infra/compose/ by default). Portable to bash 3.2 (macOS).
# `stack.sh --help` documents the interface; the exit codes are at the end of it.
# (Template of the skill gha-ephemeral-test-envs.)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: stack.sh <command> [options]

Commands
  up [--project <id>] [--stack <name>]... [--file <compose file>]... [--app-service <name>] [--local]
      Merge base.yml, the stack files <name>.yml (--project looks the names up in stacks.yml),
      test-runner.yml and every --file (for example the compose file of the app under test, whose
      image is ${APP_IMAGE}). Then: pull --quiet the stack services, up --wait them, run
      STACK_SEED_CMD, and up --wait everything else (the --file services).
      Records the stack in .state/<project name>.env and, in CI, appends COMPOSE_PROJECT_NAME,
      COMPOSE_FILE, COMPOSE_ENV_FILES and the generated values to $GITHUB_ENV, so later steps run a
      plain `docker compose run --rm test-runner <command>` on the stack network.
      --app-service <name>: in CI that service publishes no port (a `ports: !reset []` override).
      --local: developer mode; adds each <name>.local.yml (ports on 127.0.0.1) and keeps app ports.
  status
      Print the project's containers; exit 0 only when every container is running and not unhealthy
      (one-shot containers that exited 0 count as fine).
  diagnostics <dir>
      Write compose-ps.txt, <service>.log, state-<service>.json (exit code, OOMKilled, health log)
      and stats.txt into <dir>. Never fails because the stack is broken or gone.
  down
      down -v --remove-orphans --timeout STACK_DOWN_TIMEOUT, then remove every container, volume and
      network that still carries the stack's labels, and the state file. Exit 0 only when nothing
      is left.
  leak-check [--warn-only]
      List containers, volumes and networks that carry the stack's labels; exit 1 if any remain
      (--warn-only: report and exit 0). Appends the result to $GITHUB_STEP_SUMMARY in CI.

  status, diagnostics, down and leak-check find the stack through COMPOSE_PROJECT_NAME, else
  --project <id>, else the only state file in .state/.

Project name
  COMPOSE_PROJECT_NAME when set; else ci-<CI_RUN_ID>-<CI_RUN_ATTEMPT> in CI; else local-<project
  id as a slug> (local-stack without --project).

Labels
  Every service, named volume and network in the compose files carries <CI_LABEL_PREFIX>.run and
  <CI_LABEL_PREFIX>.attempt (an x-ci-labels anchor in each file); compose adds
  com.docker.compose.project. down prunes and leak-check reports what carries the project label,
  and with STACK_SCOPE=run also the run label (anything else this run started on the machine).

Environment
  STACK_DIR               directory of the compose files (default: this script's directory)
  COMPOSE_BIN             "docker compose" or "podman compose" (default: docker when present)
  COMPOSE_PROJECT_NAME    see above
  CI_RUN_ID, CI_RUN_ATTEMPT  run identity (default GITHUB_RUN_ID / GITHUB_RUN_ATTEMPT, else local / 0)
  CI_LABEL_PREFIX         label key prefix (default com.example.ci), equal to the compose files
  STACK_SCOPE             run (default in CI) or project (default elsewhere); use project, with a
                          job-unique COMPOSE_PROJECT_NAME, on runners where jobs share one engine
  APP_IMAGE               image under test for the --file services (checked when set)
  TEST_RUNNER_UID/GID     user of the test-runner container (default: the caller's id -u / id -g)
  TEST_WORKSPACE          host directory mounted at /workspace (default: GITHUB_WORKSPACE, else the
                          git top level of STACK_DIR)
  TEST_CACHE_DIR          host build cache mounted at /cache (default $HOME/.cache/test-runner)
  STACK_WAIT_TIMEOUT      seconds for each up --wait (default 180)
  STACK_DOWN_TIMEOUT      stop grace period of down, in seconds (default 20)
  STACK_SKIP_PULL=1       skip the pull (offline laptop)
  STACK_SEED_CMD          command run with bash -c after the stack services are healthy and before
                          the --file services start (COMPOSE_* are exported: `docker compose exec -T
                          <service> ...` works)
  STACK_EXPORT_VARS       extra variable names to record in the state file and export to $GITHUB_ENV
  Variables named in an `x-stack-secrets: [NAME, ...]` line of a compose file are generated when
  unset (random, reused from the state file on a re-run), masked in CI and recorded.

Exit codes
  0 success   1 compose failure, unhealthy stack or leak found   2 usage
  5 no container engine or compose, or the engine is not reachable
EOF
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
STACK_DIR=${STACK_DIR:-$SCRIPT_DIR}
LABEL_PREFIX=${CI_LABEL_PREFIX:-com.example.ci}
LABEL_RUN=$LABEL_PREFIX.run
LABEL_PROJECT=com.docker.compose.project
WAIT_TIMEOUT=${STACK_WAIT_TIMEOUT:-180}
DOWN_TIMEOUT=${STACK_DOWN_TIMEOUT:-20}
# Recorded in the state file and, in CI, appended to $GITHUB_ENV: every later compose call on the stack
# (the workflow's `docker compose run`, diagnostics, down) needs the same files and interpolation values.
BASE_STATE_VARS="COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_PATH_SEPARATOR COMPOSE_ENV_FILES CI_RUN_ID
  CI_RUN_ATTEMPT STACK_SCOPE STACK_PROJECT STACK_NAMES STACK_SECRET_NAMES APP_IMAGE TEST_RUNNER_UID
  TEST_RUNNER_GID TEST_WORKSPACE TEST_CACHE_DIR"

COMPOSE_CMD=()
ENGINE=
ENV_FILES=()
STATE_DIR=
STATE_FILE=
STACKS_FILE=
VERSIONS_ENV=
SCOPE=

log() { printf '[stack] %s\n' "$*"; }
warn() { printf '[stack] warning: %s\n' "$*" >&2; }
die() {
  local code=$1
  shift
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then printf '::error title=stack.sh::%s\n' "$*" >&2; fi
  printf '[stack] error: %s\n' "$*" >&2
  exit "$code"
}
usage_error() {
  printf '[stack] error: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}
need_arg() { [[ $# -ge 2 && -n $2 ]] || usage_error "$1 needs a value"; }
rel() { printf '%s' "${1#"$PWD"/}"; }
with_timeout() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"; else "$@"; fi
}
slug() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^[-_]+//; s/-+$//')
  printf '%s' "${s:-stack}"
}

# --- setup -------------------------------------------------------------------------------------------

resolve_dirs() {
  [[ -d $STACK_DIR ]] || usage_error "STACK_DIR '$STACK_DIR' is not a directory"
  STACK_DIR=$(cd "$STACK_DIR" && pwd -P)
  STATE_DIR=${STACK_STATE_DIR:-$STACK_DIR/.state}
  STACKS_FILE=$STACK_DIR/stacks.yml
  VERSIONS_ENV=$STACK_DIR/versions.env
  local re='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' num='^[0-9]+$'
  [[ $LABEL_PREFIX =~ $re ]] || usage_error "CI_LABEL_PREFIX '$LABEL_PREFIX' must be lower-case letters, digits, '.' and '-'"
  [[ $WAIT_TIMEOUT =~ $num && $DOWN_TIMEOUT =~ $num ]] \
    || usage_error "STACK_WAIT_TIMEOUT and STACK_DOWN_TIMEOUT are seconds (got '$WAIT_TIMEOUT', '$DOWN_TIMEOUT')"
}

detect_engine() {
  if [[ -n ${COMPOSE_BIN:-} ]]; then
    read -r -a COMPOSE_CMD <<<"$COMPOSE_BIN"
    [[ ${#COMPOSE_CMD[@]} -gt 0 ]] || die 5 "COMPOSE_BIN is blank; use \"docker compose\" or \"podman compose\"."
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(podman compose)
  else
    die 5 "no container engine with compose found: install Docker with the compose plugin, or Podman with a compose provider, or set COMPOSE_BIN."
  fi
  ENGINE=${COMPOSE_CMD[0]%-compose} # docker, podman (also for docker-compose / podman-compose)
  command -v "${COMPOSE_CMD[0]}" >/dev/null 2>&1 || die 5 "'${COMPOSE_CMD[0]}' (COMPOSE_BIN) is not on PATH."
  command -v "$ENGINE" >/dev/null 2>&1 || die 5 "container engine '$ENGINE' is not on PATH."
  "${COMPOSE_CMD[@]}" version >/dev/null 2>&1 || die 5 "'${COMPOSE_CMD[*]} version' failed: compose is not installed or not working."
  with_timeout 30 "$ENGINE" info >/dev/null 2>&1 \
    || die 5 "cannot reach the $ENGINE engine ('$ENGINE info' failed). Start Docker (or 'podman machine start')."
}

compose() {
  local args=() f
  for f in ${ENV_FILES[@]+"${ENV_FILES[@]}"}; do args+=(--env-file "$f"); done
  "${COMPOSE_CMD[@]}" ${args[@]+"${args[@]}"} "$@"
}

init_run_identity() {
  CI_RUN_ID=${CI_RUN_ID:-${GITHUB_RUN_ID:-local}}
  CI_RUN_ATTEMPT=${CI_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-0}}
  export CI_RUN_ID CI_RUN_ATTEMPT
}

in_ci() { [[ $CI_RUN_ID != local ]]; }

init_scope() {
  SCOPE=${STACK_SCOPE:-}
  if [[ -z $SCOPE ]]; then
    if in_ci; then SCOPE=run; else SCOPE=project; fi
  fi
  case $SCOPE in
    run | project) ;;
    *) usage_error "STACK_SCOPE must be run or project (got '$SCOPE')" ;;
  esac
  export STACK_SCOPE=$SCOPE
}

project_name_for() {
  if [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    printf '%s' "$COMPOSE_PROJECT_NAME"
  elif in_ci; then
    printf 'ci-%s-%s' "$CI_RUN_ID" "$CI_RUN_ATTEMPT"
  else
    printf 'local-%s' "$(slug "${1:-stack}")"
  fi
}

validate_project_name() {
  local re='^[a-z0-9][a-z0-9_-]*$'
  [[ $COMPOSE_PROJECT_NAME =~ $re ]] \
    || usage_error "'$COMPOSE_PROJECT_NAME' is not a valid compose project name (lower-case letters, digits, '-' and '_')"
}

state_file_for() { printf '%s/%s.env' "$STATE_DIR" "$1"; }

# The stack names stacks.yml declares for a project id: one flow-style line per project, `<id>: [a, b]`
# (the id may be quoted). Read without yq on purpose.
declared_stacks() {
  [[ -f $STACKS_FILE ]] || return 1
  awk -v key="$1" '
    /^[[:space:]]*(#|$)/ { next }
    {
      i = index($0, "[")
      if (i == 0) next
      k = substr($0, 1, i - 1)
      sub(/[[:space:]]*:[[:space:]]*$/, "", k)
      gsub(/^["\047]|["\047]$/, "", k)
      if (k != key) next
      v = substr($0, i + 1)
      sub(/\].*$/, "", v)
      gsub(/,/, " ", v)
      print v
      found = 1
      exit
    }
    END { exit !found }
  ' "$STACKS_FILE"
}

# Names from `x-stack-secrets: [A, B]` lines of the given compose files.
declared_secrets() {
  local f line names=''
  for f in "$@"; do
    [[ -f $f ]] || continue
    while IFS= read -r line; do
      line=${line#*[}
      line=${line%%]*}
      names+=" ${line//,/ }"
    done < <(grep -E '^x-stack-secrets:[[:space:]]*\[' "$f" || true)
  done
  # shellcheck disable=SC2086 # word splitting trims and joins the names
  echo $names
}

generate_secret() {
  local random
  if command -v openssl >/dev/null 2>&1; then
    random=$(openssl rand -hex 16)
  else
    random=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  fi
  # Upper and lower case, a digit and a symbol: passes common password policies.
  printf 'Aa1-%s' "$random"
}

# For status / diagnostics / down / leak-check: find the stack by COMPOSE_PROJECT_NAME, --project (or the
# CI default name), else the only state file; then load what `up` recorded (files, env files, values).
load_context() {
  local project=${1:-} f name
  local candidates=()
  if [[ -z ${COMPOSE_PROJECT_NAME:-} ]]; then
    if in_ci || [[ -n $project ]]; then
      COMPOSE_PROJECT_NAME=$(project_name_for "$project")
    else
      for f in "$STATE_DIR"/*.env; do
        if [[ -f $f ]]; then candidates+=("$f"); fi
      done
      if [[ ${#candidates[@]} -eq 1 ]]; then
        name=${candidates[0]##*/}
        COMPOSE_PROJECT_NAME=${name%.env}
      elif [[ ${#candidates[@]} -gt 1 ]]; then
        usage_error "several stacks are recorded in $(rel "$STATE_DIR"); set COMPOSE_PROJECT_NAME or pass --project <id>"
      fi
    fi
  fi
  if [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    export COMPOSE_PROJECT_NAME
    validate_project_name
    STATE_FILE=$(state_file_for "$COMPOSE_PROJECT_NAME")
    if [[ -f $STATE_FILE ]]; then
      set -a
      # shellcheck source=/dev/null
      . "$STATE_FILE"
      set +a
    fi
  fi
  ENV_FILES=()
  if [[ -n ${COMPOSE_ENV_FILES:-} ]]; then
    local IFS=,
    # shellcheck disable=SC2206 # split the comma-separated list on purpose
    ENV_FILES=($COMPOSE_ENV_FILES)
  fi
  init_scope
}

# A value recorded by an earlier `up` of the same project (keeps a running database's password).
previous_value() {
  [[ -n $STATE_FILE && -f $STATE_FILE ]] || return 0
  (
    # shellcheck source=/dev/null
    . "$STATE_FILE" >/dev/null 2>&1
    printf '%s' "${!1:-}"
  )
}

state_vars() { printf '%s %s %s' "$BASE_STATE_VARS" "${STACK_SECRET_NAMES:-}" "${STACK_EXPORT_VARS:-}"; }

write_state() {
  local var tmp=$STATE_FILE.tmp
  (
    umask 077
    {
      printf '# Written by stack.sh up (%s); may contain throwaway test passwords.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '# To run compose against this stack: set -a; . %s; set +a\n' "$(rel "$STATE_FILE")"
      for var in $(state_vars); do
        if [[ -n ${!var:-} ]]; then printf '%s=%q\n' "$var" "${!var}"; fi
      done
    } >"$tmp"
  )
  mv "$tmp" "$STATE_FILE"
}

export_github_env() {
  [[ -n ${GITHUB_ENV:-} ]] || return 0
  local var
  for var in ${STACK_SECRET_NAMES:-}; do printf '::add-mask::%s\n' "${!var}"; done
  for var in $(state_vars); do
    [[ -n ${!var:-} ]] || continue
    [[ ${!var} != *$'\n'* ]] || die 2 "$var contains a newline; it cannot be exported to GITHUB_ENV"
    printf '%s=%s\n' "$var" "${!var}" >>"$GITHUB_ENV"
  done
}

# In CI the app under test publishes no port: this override, merged last, empties the service's port
# list (`!reset`, Docker Compose 2.24+), so a compose file that also serves laptops stays unchanged.
write_no_ports() {
  (
    umask 077
    printf '# Written by stack.sh up: no published port in CI.\nservices:\n  %s:\n    ports: !reset []\n' "$2" >"$1"
  )
}

# --- labels, prune, leftovers ------------------------------------------------------------------------

# Filters for what this stack created, one per line (each is queried on its own; results are merged).
label_filters() {
  if [[ $SCOPE == run ]] && in_ci; then printf 'label=%s=%s\n' "$LABEL_RUN" "$CI_RUN_ID"; fi
  if [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    printf 'label=%s=%s\n' "$LABEL_PROJECT" "$COMPOSE_PROJECT_NAME"
  elif ! in_ci; then
    printf 'label=%s=local\n' "$LABEL_RUN"
  fi
}

filters_text() { label_filters | sed 's/^label=//' | paste -s -d ' ' - | sed 's/ / or /g'; }

prune_by_labels() {
  local filter ids
  while IFS= read -r filter; do
    [[ -n $filter ]] || continue
    ids=$("$ENGINE" ps -aq --filter "$filter" 2>/dev/null || true)
    if [[ -n $ids ]]; then
      log "removing containers with $filter"
      # shellcheck disable=SC2086 # one argument per id
      "$ENGINE" rm -f -v $ids >/dev/null || warn "could not remove every container with $filter"
    fi
    ids=$("$ENGINE" volume ls -q --filter "$filter" 2>/dev/null || true)
    if [[ -n $ids ]]; then
      log "removing volumes with $filter"
      # shellcheck disable=SC2086
      "$ENGINE" volume rm -f $ids >/dev/null || warn "could not remove every volume with $filter"
    fi
    ids=$("$ENGINE" network ls -q --filter "$filter" 2>/dev/null || true)
    if [[ -n $ids ]]; then
      log "removing networks with $filter"
      # shellcheck disable=SC2086
      "$ENGINE" network rm $ids >/dev/null || warn "could not remove every network with $filter"
    fi
  done <<<"$(label_filters)"
}

# One line per resource that still carries a label of this stack: "<kind> <id or name> [details]".
# A failing engine query is an error, never "nothing found".
list_leftovers() {
  local filter out lines=''
  while IFS= read -r filter; do
    [[ -n $filter ]] || continue
    out=$("$ENGINE" ps -a --filter "$filter" --format 'container {{.ID}} {{.Names}} ({{.Status}})') \
      || die 1 "cannot list containers ('$ENGINE ps' failed)"
    lines+=$out$'\n'
    out=$("$ENGINE" volume ls --filter "$filter" --format 'volume {{.Name}}') \
      || die 1 "cannot list volumes ('$ENGINE volume ls' failed)"
    lines+=$out$'\n'
    out=$("$ENGINE" network ls --filter "$filter" --format 'network {{.ID}} {{.Name}}') \
      || die 1 "cannot list networks ('$ENGINE network ls' failed)"
    lines+=$out$'\n'
  done <<<"$(label_filters)"
  printf '%s' "$lines" | sed '/^$/d' | sort -u
}

# --- commands ----------------------------------------------------------------------------------------

cmd_up() {
  local project='' local_mode=false app_service='' names=() extra=() n f
  while [[ $# -gt 0 ]]; do
    case $1 in
      --project) need_arg "$@"; project=$2; shift 2 ;;
      --project=*) project=${1#*=}; shift ;;
      --stack) need_arg "$@"; names+=("$2"); shift 2 ;;
      --stack=*) names+=("${1#*=}"); shift ;;
      --file) need_arg "$@"; extra+=("$2"); shift 2 ;;
      --file=*) extra+=("${1#*=}"); shift ;;
      --app-service) need_arg "$@"; app_service=$2; shift 2 ;;
      --app-service=*) app_service=${1#*=}; shift ;;
      --local) local_mode=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "up: unknown argument '$1'" ;;
    esac
  done
  resolve_dirs
  if [[ -n $project ]]; then
    local declared
    declared=$(declared_stacks "$project") || usage_error "up: $(rel "$STACKS_FILE") declares no stacks for '$project'"
    # shellcheck disable=SC2206 # the declared list is split on purpose
    names=($declared ${names[@]+"${names[@]}"})
  fi
  # Unique names, in order; each is <name>.yml whose main service is <name>.
  local unique=() seen=' '
  for n in ${names[@]+"${names[@]}"}; do
    [[ $n =~ ^[a-z0-9][a-z0-9._-]*$ ]] || usage_error "up: invalid stack name '$n'"
    [[ -f $STACK_DIR/$n.yml ]] || usage_error "up: stack '$n' has no file $(rel "$STACK_DIR/$n.yml")"
    if [[ $seen != *" $n "* ]]; then unique+=("$n"); seen+="$n "; fi
  done
  names=(${unique[@]+"${unique[@]}"})
  local files_extra=()
  for f in ${extra[@]+"${extra[@]}"}; do
    [[ -f $f ]] || usage_error "up: --file $f does not exist"
    files_extra+=("$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")")
  done
  [[ ${#names[@]} -gt 0 || ${#files_extra[@]} -gt 0 ]] || usage_error "up: nothing to start (give --project, --stack or --file)"
  if [[ -n $app_service ]]; then
    [[ ${#files_extra[@]} -gt 0 ]] || usage_error "up: --app-service needs the --file that defines it"
    [[ $app_service =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage_error "up: invalid service name '$app_service'"
  fi
  if [[ -n ${APP_IMAGE:-} ]]; then
    local re='^[^/@[:space:]]+(/[^/@[:space:]]+)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(@sha256:[0-9a-f]{64})?$'
    [[ $APP_IMAGE =~ $re && ( ${APP_IMAGE##*/} == *:* || $APP_IMAGE == *@* ) ]] \
      || usage_error "up: APP_IMAGE '$APP_IMAGE' must be <repo>:<tag>, <repo>@sha256:<digest> or both"
  fi

  detect_engine
  init_run_identity
  COMPOSE_PROJECT_NAME=$(project_name_for "$project")
  export COMPOSE_PROJECT_NAME
  validate_project_name
  init_scope
  STATE_FILE=$(state_file_for "$COMPOSE_PROJECT_NAME")
  (umask 077 && mkdir -p "$STATE_DIR")

  local files=()
  if [[ -f $STACK_DIR/base.yml ]]; then files+=("$STACK_DIR/base.yml"); fi
  for n in ${names[@]+"${names[@]}"}; do files+=("$STACK_DIR/$n.yml"); done
  if [[ -f $STACK_DIR/test-runner.yml ]]; then files+=("$STACK_DIR/test-runner.yml"); fi
  files+=(${files_extra[@]+"${files_extra[@]}"})
  if [[ -n $app_service ]] && ! $local_mode; then
    write_no_ports "${STATE_FILE%.env}.no-ports.yml" "$app_service"
    files+=("${STATE_FILE%.env}.no-ports.yml")
  fi
  if $local_mode; then
    for n in ${names[@]+"${names[@]}"}; do
      if [[ -f $STACK_DIR/$n.local.yml ]]; then files+=("$STACK_DIR/$n.local.yml"); fi
    done
  fi
  for f in "${files[@]}"; do [[ $f != *:* ]] || usage_error "up: compose file paths cannot contain ':' ($f)"; done

  # Test-only secrets the compose files declare: generated per stack, reused by a re-run of the same project.
  local name value
  STACK_SECRET_NAMES=$(declared_secrets "${files[@]}")
  for name in $STACK_SECRET_NAMES; do
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || usage_error "up: x-stack-secrets names an invalid variable '$name'"
    if [[ -z ${!name:-} ]]; then
      value=$(previous_value "$name")
      [[ -n $value ]] || value=$(generate_secret)
      printf -v "$name" '%s' "$value"
    fi
    export "${name?}"
  done
  for name in ${STACK_EXPORT_VARS:-}; do
    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || usage_error "up: STACK_EXPORT_VARS names an invalid variable '$name'"
  done
  export TEST_RUNNER_UID=${TEST_RUNNER_UID:-$(id -u)} TEST_RUNNER_GID=${TEST_RUNNER_GID:-$(id -g)}
  export TEST_WORKSPACE=${TEST_WORKSPACE:-${GITHUB_WORKSPACE:-$(git -C "$STACK_DIR" rev-parse --show-toplevel 2>/dev/null || pwd -P)}}
  export TEST_CACHE_DIR=${TEST_CACHE_DIR:-$HOME/.cache/test-runner}
  mkdir -p "$TEST_CACHE_DIR" # created by the caller, not by the engine as root
  export STACK_PROJECT=$project STACK_NAMES="${names[*]+${names[*]}}" STACK_SECRET_NAMES

  ENV_FILES=()
  unset COMPOSE_ENV_FILES
  if [[ -f $VERSIONS_ENV ]]; then
    ENV_FILES+=("$VERSIONS_ENV")
    export COMPOSE_ENV_FILES=$VERSIONS_ENV
  fi
  COMPOSE_FILE=$(IFS=:; printf '%s' "${files[*]}")
  export COMPOSE_FILE COMPOSE_PATH_SEPARATOR=:
  write_state
  export_github_env

  log "project $COMPOSE_PROJECT_NAME: stacks [${names[*]+${names[*]}}]${APP_IMAGE:+, image under test $APP_IMAGE}"
  log "compose files: $(for f in "${files[@]}"; do printf '%s ' "$(rel "$f")"; done)"
  if [[ ${#names[@]} -gt 0 ]]; then
    if [[ ${STACK_SKIP_PULL:-0} != 1 ]]; then
      log "pulling the stack images"
      # Only the stacks: the image under test may exist only locally (a laptop build); up pulls it if missing.
      compose pull --quiet --include-deps "${names[@]}" || up_failed "pulling the stack images failed"
    fi
    log "starting ${names[*]} (up --wait, ${WAIT_TIMEOUT}s)"
    compose up --wait --wait-timeout "$WAIT_TIMEOUT" "${names[@]}" || up_failed "the stack services did not become healthy"
  fi
  if [[ -n ${STACK_SEED_CMD:-} ]]; then
    log "seeding: STACK_SEED_CMD"
    bash -c "$STACK_SEED_CMD" || up_failed "STACK_SEED_CMD failed"
  fi
  if [[ ${#files_extra[@]} -gt 0 ]]; then
    log "starting the remaining services (up --wait, ${WAIT_TIMEOUT}s)"
    compose up --wait --wait-timeout "$WAIT_TIMEOUT" --quiet-pull || up_failed "the remaining services did not become healthy"
  fi
  log "up: $COMPOSE_PROJECT_NAME is healthy"
  log "  state: $(rel "$STATE_FILE")   (set -a; . <state file>; set +a; then plain docker compose works)"
  log "  network: ${COMPOSE_PROJECT_NAME}_default   tests: docker compose run --rm test-runner <command>"
  if $local_mode; then compose ps || true; fi
}

up_failed() {
  warn "$1. Stack state follows; 'stack.sh diagnostics <dir>' collects the full bundle."
  compose ps -a >&2 || true
  compose logs --no-color --timestamps --tail 50 >&2 || true
  # The interleaved tail is dominated by chatty services: show each failed container's own last lines.
  local service state health
  while read -r service state health; do
    [[ -n $service ]] || continue
    if [[ $state != running || $health == unhealthy ]]; then
      warn "last output of $service ($state${health:+, $health}):"
      compose logs --no-color --no-log-prefix --tail 40 "$service" >&2 || true
    fi
  done < <(compose ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null || true)
  die 1 "up failed for $COMPOSE_PROJECT_NAME: $1 (tear down with: stack.sh down)"
}

# Parses the options shared by status / down: [--project <id>].
parse_project_only() {
  PROJECT_ARG=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --project) need_arg "$@"; PROJECT_ARG=$2; shift 2 ;;
      --project=*) PROJECT_ARG=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "$COMMAND: unknown argument '$1'" ;;
    esac
  done
}

cmd_status() {
  parse_project_only "$@"
  resolve_dirs
  detect_engine
  init_run_identity
  load_context "$PROJECT_ARG"
  [[ -n ${COMPOSE_PROJECT_NAME:-} ]] || die 1 "status: no stack recorded; set COMPOSE_PROJECT_NAME or pass --project <id>"
  local lines name state status bad=0
  lines=$("$ENGINE" ps -a --filter "label=$LABEL_PROJECT=$COMPOSE_PROJECT_NAME" --format '{{.Names}}|{{.State}}|{{.Status}}') \
    || die 1 "cannot list containers ('$ENGINE ps' failed)"
  [[ -n $lines ]] || die 1 "status: no container of project $COMPOSE_PROJECT_NAME"
  printf '%-44s %-10s %s\n' CONTAINER STATE STATUS
  while IFS='|' read -r name state status; do
    printf '%-44s %-10s %s\n' "$name" "$state" "$status"
    case $state in
      running) if [[ $status == *unhealthy* || $status == *'health: starting'* ]]; then bad=1; fi ;;
      exited) if [[ $status != 'Exited (0)'* ]]; then bad=1; fi ;;
      *) bad=1 ;;
    esac
  done <<<"$lines"
  [[ $bad -eq 0 ]] || die 1 "status: not every container of $COMPOSE_PROJECT_NAME is running and healthy"
  log "status: $COMPOSE_PROJECT_NAME is up"
}

cmd_diagnostics() {
  local dir='' project=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --project) need_arg "$@"; project=$2; shift 2 ;;
      --project=*) project=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) usage_error "diagnostics: unknown option '$1'" ;;
      *)
        [[ -z $dir ]] || usage_error "diagnostics: exactly one directory expected"
        dir=$1
        shift
        ;;
    esac
  done
  [[ -n $dir ]] || usage_error "diagnostics: <dir> is required"
  resolve_dirs
  detect_engine
  init_run_identity
  load_context "$project"
  [[ -n ${COMPOSE_PROJECT_NAME:-} ]] || usage_error "diagnostics: no stack recorded; set COMPOSE_PROJECT_NAME or pass --project <id>"
  mkdir -p "$dir"
  log "diagnostics for $(filters_text) into $dir"

  # compose-ps.txt: the compose view when up recorded the files, then the engine view by label.
  if [[ -n ${COMPOSE_FILE:-} ]]; then
    compose ps -a >"$dir/compose-ps.txt" 2>&1 || true
  else
    : >"$dir/compose-ps.txt"
  fi
  local filter ids=''
  while IFS= read -r filter; do
    [[ -n $filter ]] || continue
    "$ENGINE" ps -a --filter "$filter" >>"$dir/compose-ps.txt" 2>&1 || true
    ids+=" $("$ENGINE" ps -aq --filter "$filter" 2>/dev/null || true)"
  done <<<"$(label_filters)"
  # shellcheck disable=SC2086 # one line per id
  ids=$(printf '%s\n' $ids | sed '/^$/d' | sort -u | paste -s -d ' ' -)

  local id service name base
  for id in $ids; do
    service=$("$ENGINE" inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null || true)
    [[ $service != '<no value>' ]] || service=
    name=$("$ENGINE" inspect --format '{{.Name}}' "$id" 2>/dev/null || true)
    name=${name#/}
    base=${service:-${name:-$id}}
    [[ ! -e $dir/$base.log ]] || base=${name:-$id}
    "$ENGINE" logs --timestamps "$id" >"$dir/$base.log" 2>&1 || true
    "$ENGINE" inspect --format '{{json .State}}' "$id" >"$dir/state-$base.json" 2>/dev/null || true
  done
  if [[ -n $ids ]]; then
    # shellcheck disable=SC2086
    "$ENGINE" stats --no-stream $ids >"$dir/stats.txt" 2>&1 || true
  else
    printf 'no containers match %s\n' "$(filters_text)" >"$dir/stats.txt"
  fi
  log "wrote $(cd "$dir" && printf '%s ' *)"
}

cmd_down() {
  parse_project_only "$@"
  resolve_dirs
  detect_engine
  init_run_identity
  load_context "$PROJECT_ARG"
  if [[ -z ${COMPOSE_PROJECT_NAME:-} ]]; then
    log "down: no stack recorded (no COMPOSE_PROJECT_NAME, nothing in $(rel "$STATE_DIR")); nothing to do"
    return 0
  fi
  if [[ -n ${COMPOSE_FILE:-} ]]; then
    # compose parses the files again, so every variable they require must be set; none matters here.
    local name
    for name in ${STACK_SECRET_NAMES:-}; do
      if [[ -z ${!name:-} ]]; then printf -v "$name" '%s' not-needed-for-down; fi
      export "${name?}"
    done
    log "down: project $COMPOSE_PROJECT_NAME (down -v --remove-orphans --timeout $DOWN_TIMEOUT)"
    compose down -v --remove-orphans --timeout "$DOWN_TIMEOUT" || warn "compose down failed; removing by label instead"
  else
    log "down: no compose files recorded for $COMPOSE_PROJECT_NAME; removing by label"
  fi
  prune_by_labels
  if [[ -n ${STATE_FILE:-} ]]; then rm -f "$STATE_FILE" "${STATE_FILE%.env}.no-ports.yml"; fi

  local leftovers
  leftovers=$(list_leftovers)
  if [[ -n $leftovers ]]; then
    printf '%s\n' "$leftovers" >&2
    die 1 "down: resources with $(filters_text) remain"
  fi
  log "down: nothing with $(filters_text) remains"
}

cmd_leak_check() {
  local warn_only=false project=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --warn-only) warn_only=true; shift ;;
      --project) need_arg "$@"; project=$2; shift 2 ;;
      --project=*) project=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "leak-check: unknown argument '$1'" ;;
    esac
  done
  resolve_dirs
  detect_engine
  init_run_identity
  load_context "$project"

  local leftovers what count
  what=$(filters_text)
  [[ -n $what ]] || usage_error "leak-check: no stack to check; set COMPOSE_PROJECT_NAME or pass --project <id>"
  leftovers=$(list_leftovers)
  if [[ -z $leftovers ]]; then
    log "leak-check: no container, volume or network carries $what"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
      # shellcheck disable=SC2016 # Markdown backticks
      printf '### Leak check: clean\n\nNo container, volume or network carries `%s`.\n\n' "$what" >>"$GITHUB_STEP_SUMMARY"
    fi
    return 0
  fi
  count=$(printf '%s\n' "$leftovers" | wc -l | tr -d ' ')
  printf '[stack] leak-check: %s resource(s) carry %s:\n' "$count" "$what" >&2
  printf '%s\n' "$leftovers" | sed 's/^/  /' >&2
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      # shellcheck disable=SC2016 # Markdown backticks
      printf '### Leak check: %s resource(s) left\n\nFilter: `%s`\n\n| Kind | Resource |\n|---|---|\n' "$count" "$what"
      # shellcheck disable=SC2016
      printf '%s\n' "$leftovers" | sed -E 's/^([a-z]+) (.*)$/| \1 | `\2` |/'
      printf '\n'
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  if $warn_only; then
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then printf '::warning title=leak-check::%s resource(s) carry %s\n' "$count" "$what"; fi
    log "leak-check: --warn-only, not failing"
    return 0
  fi
  die 1 "leak-check: $count resource(s) carry $what"
}

main() {
  [[ $# -gt 0 ]] || usage_error "missing command"
  COMMAND=$1
  shift
  case $COMMAND in
    up) cmd_up "$@" ;;
    status) cmd_status "$@" ;;
    diagnostics) cmd_diagnostics "$@" ;;
    down) cmd_down "$@" ;;
    leak-check) cmd_leak_check "$@" ;;
    -h | --help | help) usage ;;
    *) usage_error "unknown command '$COMMAND'" ;;
  esac
}

main "$@"
