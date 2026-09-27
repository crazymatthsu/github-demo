#!/usr/bin/env bash
# test-infra/compose/stack.sh: lifecycle of the test-infra compose stacks (D10 §6.2; D8 §4.2, §6.2).
#
# One script, two callers: the integration-test workflow steps and Gradle's composeUp / composeDown /
# devUp / devDown Exec tasks, so a laptop and a runner execute the same commands. Portable to bash 3.2
# (macOS). Run `stack.sh --help` for the interface.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: test-infra/compose/stack.sh <command> [options]

Commands
  up --project <gradle path> [--local]
      Start the dependency stacks that stacks.yml declares for the project (base.yml, <stack>.yml...,
      it-runner.yml), plus the app's docker/docker-compose.yml when APP_IMAGE is set: pull --quiet,
      up --wait --wait-timeout 180, apply the SQL Server seed, then start the app under test.
      Exports COMPOSE_FILE, COMPOSE_PROJECT_NAME, COMPOSE_ENV_FILES and the IT_* values to
      $GITHUB_ENV in CI and records them in test-infra/compose/.state/<project>.env.
      --local also publishes 10000 / 1433 / 9092 on 127.0.0.1 (local-ports.yml). In CI the app under
      test publishes no port either (tests reach it as <AppName>:8080 on the stack network).
  diagnostics <dir>
      Write compose-ps.txt, <service>.log, health-<service>.json and stats.txt for the stack into <dir>.
  down
      down -v --remove-orphans --timeout 20, then remove every container, volume and network that
      still carries the stack's labels. Exit 0 only when nothing is left.
  leak-check [--warn-only]
      List containers, volumes and networks carrying this run's labels; exit 1 if any remain
      (--warn-only: report, exit 0). Writes a summary to $GITHUB_STEP_SUMMARY in CI.

  diagnostics, down and leak-check find the stack through COMPOSE_PROJECT_NAME, else the only state
  file under test-infra/compose/.state/. --project <gradle path> selects one when several exist.

Environment
  COMPOSE_BIN              "docker compose" or "podman compose" (default: docker when present, else podman)
  COMPOSE_PROJECT_NAME     default ci-<CI_RUN_ID>-<CI_RUN_ATTEMPT> in CI, local-<AppName> elsewhere
  CI_RUN_ID, CI_RUN_ATTEMPT  run labels (default GITHUB_RUN_ID / GITHUB_RUN_ATTEMPT, else local / 0)
  APP_IMAGE                image under test; adds <project dir>/docker/docker-compose.yml to the stack
  APP_ENV, APP_FLOW, APP_INSTANCE
                           identity of the app instance (default local, cash, and the instance named
                           by the project's test-infra/testdata manifests)
  IT_SA_PASSWORD           SQL Server sa password (generated when unset; reused on a re-run)
  IT_TABLE_PREFIX          Deephaven table prefix for the run (default it_<sha7>_)
  STACK_WAIT_TIMEOUT       seconds for each up --wait (default 180); STACK_SKIP_PULL=1 skips the pull

Exit codes
  0 success   1 compose failure, unhealthy stack or leak found   2 usage
  5 no container engine or compose, or the engine is not reachable
EOF
}

COMPOSE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
TEST_INFRA_DIR=$(dirname "$COMPOSE_DIR")
REPO_ROOT=$(dirname "$TEST_INFRA_DIR")
STATE_DIR=${STACK_STATE_DIR:-$COMPOSE_DIR/.state}
STACKS_FILE=$COMPOSE_DIR/stacks.yml
VERSIONS_ENV=$COMPOSE_DIR/versions.env
LABEL_RUN=com.example.ci.run
LABEL_PROJECT=com.docker.compose.project
WAIT_TIMEOUT=${STACK_WAIT_TIMEOUT:-180}
DOWN_TIMEOUT=20

# Recorded in the state file and, in CI, appended to $GITHUB_ENV: every later compose call on the stack
# (the workflow's `docker compose run --rm it-runner`, diagnostics, down) needs the same interpolation.
STATE_VARS="COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_PATH_SEPARATOR COMPOSE_ENV_FILES
  CI_RUN_ID CI_RUN_ATTEMPT IT_SA_PASSWORD IT_TABLE_PREFIX IT_RUNNER_UID IT_RUNNER_GID IT_WORKSPACE
  IT_GRADLE_HOME STACK_PROJECT STACK_SERVICES APP_IMAGE APP_NAME APP_ENV APP_FLOW APP_INSTANCE
  COMMON_DIR CONFIG_DIR PLATFORM_DIR ENV_COMMON_DIR PROJECT IMAGE_REPO IMAGE_TAG ACTUATOR_HOST_PORT
  SPRING_DATASOURCE_USERNAME SPRING_DATASOURCE_PASSWORD"

COMPOSE_CMD=()
ENGINE=
ENV_FILES=()
STATE_FILE=

log()  { printf '[stack] %s\n' "$*"; }
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
rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }
has_word() {
  local word=$1 w
  shift
  for w in "$@"; do [[ $w == "$word" ]] && return 0; done
  return 1
}
with_timeout() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"; else "$@"; fi
}

# --- arguments ---------------------------------------------------------------------------------------

validate_gradle_path() {
  local re='^(:[a-z0-9][a-z0-9-]*)+$'
  [[ $1 =~ $re ]] || usage_error "invalid Gradle project path '$1' (expected e.g. :deephaven-connectors:source-database)"
}

# Prints the stacks stacks.yml declares for a project name (one flow-style line per project).
declared_stacks() {
  local line
  line=$(grep -m 1 -E "^$1:[[:space:]]*\[" "$STACKS_FILE") || return 1
  line=${line#*\[}
  line=${line%%\]*}
  line=${line//,/ }
  # shellcheck disable=SC2086 # word splitting trims the list
  echo $line
}

# --- engine ------------------------------------------------------------------------------------------

detect_engine() {
  if [[ -n ${COMPOSE_BIN:-} ]]; then
    read -r -a COMPOSE_CMD <<<"$COMPOSE_BIN"
    [[ ${#COMPOSE_CMD[@]} -gt 0 ]] || die 5 "COMPOSE_BIN is blank; use \"docker compose\" or \"podman compose\"."
  elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(podman compose)
  else
    die 5 "no container engine with compose found. Install Docker with the compose plugin, or Podman with a compose provider, or set COMPOSE_BIN=\"docker compose\" | \"podman compose\"."
  fi
  ENGINE=${COMPOSE_CMD[0]%-compose} # docker, podman (also for docker-compose / podman-compose)
  command -v "${COMPOSE_CMD[0]}" >/dev/null 2>&1 || die 5 "'${COMPOSE_CMD[0]}' (COMPOSE_BIN) is not on PATH."
  command -v "$ENGINE" >/dev/null 2>&1 || die 5 "container engine '$ENGINE' is not on PATH."
  "${COMPOSE_CMD[@]}" version >/dev/null 2>&1 \
    || die 5 "'${COMPOSE_CMD[*]} version' failed: compose is not installed or not working."
  with_timeout 30 "$ENGINE" info >/dev/null 2>&1 \
    || die 5 "cannot reach the $ENGINE engine ('$ENGINE info' failed). Start Docker, or for Podman run 'podman machine start' or 'systemctl --user start podman.socket'; COMPOSE_BIN selects the engine."
}

compose() {
  local args=() f
  for f in ${ENV_FILES[@]+"${ENV_FILES[@]}"}; do args+=(--env-file "$f"); done
  "${COMPOSE_CMD[@]}" ${args[@]+"${args[@]}"} "$@"
}

# --- run identity and stack context --------------------------------------------------------------------

init_run_identity() {
  CI_RUN_ID=${CI_RUN_ID:-${GITHUB_RUN_ID:-local}}
  CI_RUN_ATTEMPT=${CI_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-0}}
  export CI_RUN_ID CI_RUN_ATTEMPT
}

in_ci() { [[ $CI_RUN_ID != local ]]; }

# D10 §6.1: ci-<run_id>-<attempt> in CI, local-<AppName> on a laptop; COMPOSE_PROJECT_NAME wins.
project_name_for() {
  if [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    printf '%s' "$COMPOSE_PROJECT_NAME"
  elif in_ci; then
    printf 'ci-%s-%s' "$CI_RUN_ID" "$CI_RUN_ATTEMPT"
  else
    printf 'local-%s' "$1"
  fi
}

validate_project_name() {
  local re='^[a-z0-9][a-z0-9_-]*$'
  [[ $COMPOSE_PROJECT_NAME =~ $re ]] \
    || usage_error "'$COMPOSE_PROJECT_NAME' is not a valid compose project name (lower-case letters, digits, '-' and '_')"
}

state_file_for() { printf '%s/%s.env' "$STATE_DIR" "$1"; }

# For diagnostics / down / leak-check: find the stack by COMPOSE_PROJECT_NAME, --project or the only
# state file, then load what `up` recorded (compose files, env files, interpolation values).
load_context() {
  local gradle_path=${1:-} f name
  local candidates=()
  if [[ -z ${COMPOSE_PROJECT_NAME:-} && -n $gradle_path ]]; then
    COMPOSE_PROJECT_NAME=$(project_name_for "${gradle_path##*:}")
  fi
  if [[ -z ${COMPOSE_PROJECT_NAME:-} ]]; then
    for f in "$STATE_DIR"/*.env; do
      if [[ -f $f ]]; then candidates+=("$f"); fi
    done
    if [[ ${#candidates[@]} -eq 1 ]]; then
      name=${candidates[0]##*/}
      COMPOSE_PROJECT_NAME=${name%.env}
    elif [[ ${#candidates[@]} -gt 1 ]]; then
      usage_error "several stacks are recorded in $(rel "$STATE_DIR"); set COMPOSE_PROJECT_NAME or pass --project <gradle path>"
    fi
  fi
  [[ -n ${COMPOSE_PROJECT_NAME:-} ]] || return 0
  export COMPOSE_PROJECT_NAME
  STATE_FILE=$(state_file_for "$COMPOSE_PROJECT_NAME")
  if [[ -f $STATE_FILE ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$STATE_FILE"
    set +a
  fi
  ENV_FILES=()
  if [[ -n ${COMPOSE_ENV_FILES:-} ]]; then
    local IFS=,
    # shellcheck disable=SC2206 # split the comma-separated list on purpose
    ENV_FILES=($COMPOSE_ENV_FILES)
  fi
}

# A value recorded by an earlier `up` of the same project (keeps the running SQL Server's password).
previous_value() {
  [[ -f $STATE_FILE ]] || return 0
  (
    # shellcheck source=/dev/null
    . "$STATE_FILE" >/dev/null 2>&1
    printf '%s' "${!1:-}"
  )
}

write_state() {
  local var tmp=$STATE_FILE.tmp
  mkdir -p "$STATE_DIR"
  (
    umask 077
    {
      printf '# Written by test-infra/compose/stack.sh up (%s). Contains a throwaway test password.\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '# To run compose against this stack: set -a; . %s; set +a\n' "$(rel "$STATE_FILE")"
      for var in $STATE_VARS; do
        if [[ -n ${!var:-} ]]; then printf '%s=%q\n' "$var" "${!var}"; fi
      done
    } >"$tmp"
  )
  mv "$tmp" "$STATE_FILE"
}

export_github_env() {
  [[ -n ${GITHUB_ENV:-} ]] || return 0
  local var
  printf '::add-mask::%s\n' "$IT_SA_PASSWORD"
  for var in $STATE_VARS; do
    if [[ -n ${!var:-} ]]; then printf '%s=%s\n' "$var" "${!var}" >>"$GITHUB_ENV"; fi
  done
}

generate_password() {
  local random
  if command -v openssl >/dev/null 2>&1; then
    random=$(openssl rand -hex 16)
  else
    random=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  fi
  # Upper case, lower case, digits and a symbol: meets the SQL Server password policy.
  printf 'It-%s-Aa1' "$random"
}

short_sha() {
  local sha=${GITHUB_SHA:-}
  [[ -n $sha ]] || sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
  if [[ -n $sha ]]; then printf '%s' "${sha:0:7}"; else printf 'local'; fi
}

# The AppInstance the project's test cases run against (manifest key `instance`), when they agree.
# The instance directories of config/<env>/<flow>/<app>: everything but the app-common layer, one per line.
instance_dirs() {
  local d name
  for d in "$1"/*/; do
    [[ -d $d ]] || continue
    name=$(basename "$d")
    [[ $name == app-common || $name == _* || $name == .* ]] && continue
    printf '%s\n' "$name"
  done
}

manifest_instance() {
  local f instance found=''
  for f in "$TEST_INFRA_DIR/testdata/$1"/*/manifest.yml; do
    [[ -f $f ]] || continue
    instance=$(sed -n '/^instance:/{s/^instance:[[:space:]]*\([a-z0-9-]*\).*/\1/p;q;}' "$f")
    [[ -n $instance ]] || continue
    if [[ -z $found ]]; then
      found=$instance
    elif [[ $found != "$instance" ]]; then
      return 0
    fi
  done
  printf '%s' "$found"
}

# Interpolation values for the app's compose template when it joins the stack, mirroring what
# run-compose.sh exports (D6 §6.2): identity, config directories, compose.env, the image under test.
prepare_app() {
  local app=$1 base config_root=${CONFIG_ROOT:-$REPO_ROOT/config} compose_env=''
  # Absolute, or compose would read a relative layer path such as config/_common/<app> as a volume name.
  if [[ -d $config_root ]]; then config_root=$(cd "$config_root" && pwd -P); fi
  export APP_NAME=${APP_NAME:-$app} APP_ENV=${APP_ENV:-local} APP_FLOW=${APP_FLOW:-cash}
  base=$config_root/$APP_ENV/$APP_FLOW/$APP_NAME
  # The instance whose config the app under test runs with (D8 §5.1): APP_INSTANCE, else the instance the
  # app's test-case manifest names, else the app's only instance directory under config/<env>/<flow>/<app>
  # (the hello-world apps have no test case yet). The app template requires it (${APP_INSTANCE:?}), so a
  # missing instance fails here, with the remedy, rather than as a compose interpolation error.
  if [[ -z ${APP_INSTANCE:-} ]]; then
    APP_INSTANCE=$(manifest_instance "$app")
  fi
  if [[ -z $APP_INSTANCE ]]; then
    local candidates
    candidates=$(instance_dirs "$base")
    case $(wc -w <<<"$candidates") in
      0) usage_error "up: no instance for $app: $(rel "$base") has no instance directory. Add one (D5), set APP_INSTANCE, or add a test-infra/testdata/$app/<case>/manifest.yml that names one" ;;
      1) APP_INSTANCE=$candidates ;;
      *) usage_error "up: $app has several instances under $(rel "$base") ($(printf '%s' "$candidates" | tr '\n' ' ')); set APP_INSTANCE or add a test-infra/testdata/$app/<case>/manifest.yml that names one" ;;
    esac
  fi
  export APP_INSTANCE
  export COMMON_DIR=${COMMON_DIR:-$base/app-common} CONFIG_DIR=${CONFIG_DIR:-$base/$APP_INSTANCE}
  [[ -d $CONFIG_DIR ]] || usage_error "up: the instance config $(rel "$CONFIG_DIR") does not exist (APP_INSTANCE=$APP_INSTANCE)"
  if [[ -f $CONFIG_DIR/compose.env ]]; then
    compose_env=$CONFIG_DIR/compose.env
    ENV_FILES+=("$compose_env")
  else
    warn "$(rel "$CONFIG_DIR")/compose.env not found; the app template gets no instance compose.env"
  fi
  # The optional layers exactly as run-compose.sh mounts them (D5 §6.1, D6 §6.2): set when the directory
  # exists, unset otherwise (the template then mounts the empty-layer volume).
  unset PLATFORM_DIR ENV_COMMON_DIR
  if [[ -d $config_root/_common/$APP_NAME ]]; then export PLATFORM_DIR=$config_root/_common/$APP_NAME; fi
  if [[ -d $config_root/$APP_ENV/_common ]]; then export ENV_COMMON_DIR=$config_root/$APP_ENV/_common; fi
  # The template publishes 127.0.0.1:${ACTUATOR_HOST_PORT:?...}, which compose interpolates even when the CI
  # override drops the port. Default it only when compose.env does not set it: the shell beats --env-file.
  if [[ -z ${ACTUATOR_HOST_PORT:-} ]] \
    && ! { [[ -n $compose_env ]] && grep -Eq '^[[:space:]]*ACTUATOR_HOST_PORT=' "$compose_env"; }; then
    export ACTUATOR_HOST_PORT=18080
  fi
  export PROJECT=$COMPOSE_PROJECT_NAME

  # A template written as ${IMAGE_REPO}/${APP_NAME}:${IMAGE_TAG} must run APP_IMAGE and not the tag in
  # compose.env, so both are derived from it (the environment beats compose.env). A digest-only
  # reference gets the placeholder tag `by-digest`: with name:tag@digest, Docker and Podman pull by
  # digest and ignore the tag.
  local ref=$APP_IMAGE digest='' last
  if [[ $ref == *@* ]]; then
    digest=${ref#*@}
    ref=${ref%%@*}
  fi
  last=${ref##*/}
  if [[ $last == *:* ]]; then
    export IMAGE_REPO=${ref%/*} IMAGE_TAG=${last#*:}${digest:+@$digest}
  else
    export IMAGE_REPO=${ref%/*} IMAGE_TAG=by-digest@$digest
  fi
  [[ ${last%%:*} == "$APP_NAME" ]] || warn "APP_IMAGE names '${last%%:*}', not '$APP_NAME'"
  export SPRING_DATASOURCE_USERNAME=${SPRING_DATASOURCE_USERNAME:-sa}
  export SPRING_DATASOURCE_PASSWORD=${SPRING_DATASOURCE_PASSWORD:-$IT_SA_PASSWORD}
}

# Compose rejects an override for a service the stack does not define, so --local gets local-ports.yml
# filtered to the stack's services (one two-space-indented "<service>:" block each, see the file).
write_local_ports() {
  local out=$1
  shift
  (
    umask 077
    awk -v keep=" $* " '
      /^services:[[:space:]]*$/          { print; next }
      /^  [A-Za-z0-9._-]+:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); on = index(keep, " " svc " ") > 0 }
      /^[^[:space:]#]/                   { on = 0 }
      on                                 { print }
    ' "$COMPOSE_DIR/local-ports.yml" >"$out"
  )
  if [[ $(wc -l <"$out") -le 1 ]]; then printf 'services: {}\n' >"$out"; fi
}

# D10 §5.6: nothing publishes a port in CI. The app template publishes its actuator on 127.0.0.1; this
# override, merged after it, empties that list (compose `!reset`, Docker Compose 2.24+), so the template
# stays as it is. Tests reach the app as <AppName>:8080 on the stack network.
write_app_no_ports() {
  local out=$1 service=$2
  (
    umask 077
    printf '# Written by stack.sh up in CI: the app under test publishes no port (D10 §5.6).\n' >"$out"
    printf 'services:\n  %s:\n    ports: !reset []\n' "$service" >>"$out"
  )
}

# --- labels, prune, leftovers ------------------------------------------------------------------------

# Filters that identify what this run created (D10 §6.4). In CI: the run label, which also covers
# run-compose.sh stacks of the same run, plus the project label. On a laptop every stack shares the
# run label "local", so only the project label is used; without a project, all local stacks.
label_filters() {
  if in_ci; then
    printf 'label=%s=%s\n' "$LABEL_RUN" "$CI_RUN_ID"
    if [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then printf 'label=%s=%s\n' "$LABEL_PROJECT" "$COMPOSE_PROJECT_NAME"; fi
  elif [[ -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    printf 'label=%s=%s\n' "$LABEL_PROJECT" "$COMPOSE_PROJECT_NAME"
  else
    printf 'label=%s=local\n' "$LABEL_RUN"
  fi
}

filters_text() { label_filters | sed 's/^label=//' | paste -s -d ' ' - | sed 's/ / or /g'; }

prune_by_labels() {
  local filter ids
  while IFS= read -r filter; do
    [[ -n $filter ]] || continue
    ids=$("$ENGINE" ps -aq --filter "$filter")
    if [[ -n $ids ]]; then
      log "removing containers with $filter"
      # shellcheck disable=SC2086 # one argument per id
      "$ENGINE" rm -f -v $ids >/dev/null || warn "could not remove every container with $filter"
    fi
    ids=$("$ENGINE" volume ls -q --filter "$filter")
    if [[ -n $ids ]]; then
      log "removing volumes with $filter"
      # shellcheck disable=SC2086
      "$ENGINE" volume rm -f $ids >/dev/null || warn "could not remove every volume with $filter"
    fi
    ids=$("$ENGINE" network ls -q --filter "$filter")
    if [[ -n $ids ]]; then
      log "removing networks with $filter"
      # shellcheck disable=SC2086
      "$ENGINE" network rm $ids >/dev/null || warn "could not remove every network with $filter"
    fi
  done <<<"$(label_filters)"
}

# One line per resource still carrying a label of this run: "<kind> <id or name> [details]".
list_leftovers() {
  local filter
  {
    while IFS= read -r filter; do
      [[ -n $filter ]] || continue
      "$ENGINE" ps -a --filter "$filter" --format 'container {{.ID}} {{.Names}} ({{.Status}})'
      "$ENGINE" volume ls --filter "$filter" --format 'volume {{.Name}}'
      "$ENGINE" network ls --filter "$filter" --format 'network {{.ID}} {{.Name}}'
    done <<<"$(label_filters)"
  } | sort -u
}

# --- commands ----------------------------------------------------------------------------------------

cmd_up() {
  local gradle_path='' local_ports=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --project)
        [[ $# -ge 2 ]] || usage_error "up: --project needs a Gradle project path"
        gradle_path=$2
        shift 2
        ;;
      --project=*) gradle_path=${1#*=}; shift ;;
      --local) local_ports=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "up: unknown argument '$1'" ;;
    esac
  done
  [[ -n $gradle_path ]] || usage_error "up: --project <gradle path> is required"
  validate_gradle_path "$gradle_path"
  local app=${gradle_path##*:} project_dir=${gradle_path#:} stacks stack app_file=''
  project_dir=${project_dir//://}
  stacks=$(declared_stacks "$app") || usage_error "up: stacks.yml declares no stacks for '$app' ($gradle_path)"
  [[ -n $stacks ]] || usage_error "up: the stack list for '$app' in stacks.yml is empty"
  for stack in $stacks; do
    [[ -f $COMPOSE_DIR/$stack.yml ]] || usage_error "up: stacks.yml names '$stack' but test-infra/compose/$stack.yml does not exist"
  done
  if [[ -n ${APP_IMAGE:-} ]]; then
    local re='^[^/@[:space:]]+(/[^/@[:space:]]+)+(:[A-Za-z0-9_][A-Za-z0-9_.-]*)?(@sha256:[0-9a-f]{64})?$'
    [[ $APP_IMAGE =~ $re && ( ${APP_IMAGE##*/} == *:* || $APP_IMAGE == *@* ) ]] \
      || usage_error "up: APP_IMAGE '$APP_IMAGE' must be <registry>/<path>/<AppName>:<tag>, <...>@sha256:<digest>, or both"
    app_file=$REPO_ROOT/$project_dir/docker/docker-compose.yml
    [[ -f $app_file ]] || usage_error "up: APP_IMAGE is set but $project_dir/docker/docker-compose.yml does not exist"
  fi

  detect_engine
  init_run_identity
  COMPOSE_PROJECT_NAME=$(project_name_for "$app")
  export COMPOSE_PROJECT_NAME
  validate_project_name
  STATE_FILE=$(state_file_for "$COMPOSE_PROJECT_NAME")

  # Test-only settings (D2 §6.4, D10 §5.3, §6.3).
  if [[ -z ${IT_SA_PASSWORD:-} ]]; then
    IT_SA_PASSWORD=$(previous_value IT_SA_PASSWORD)
    [[ -n $IT_SA_PASSWORD ]] || IT_SA_PASSWORD=$(generate_password)
  fi
  export IT_SA_PASSWORD
  export IT_TABLE_PREFIX=${IT_TABLE_PREFIX:-it_$(short_sha)_}
  export IT_RUNNER_UID=${IT_RUNNER_UID:-$(id -u)} IT_RUNNER_GID=${IT_RUNNER_GID:-$(id -g)}
  export IT_WORKSPACE=${IT_WORKSPACE:-$REPO_ROOT}
  export IT_GRADLE_HOME=${IT_GRADLE_HOME:-${GRADLE_USER_HOME:-$HOME/.gradle}}
  mkdir -p "$IT_GRADLE_HOME" # created by the caller, not by the engine as root
  export STACK_PROJECT=$gradle_path STACK_SERVICES=${stacks// /,}

  ENV_FILES=("$VERSIONS_ENV")
  local files=("$COMPOSE_DIR/base.yml")
  for stack in $stacks; do files+=("$COMPOSE_DIR/$stack.yml"); done
  files+=("$COMPOSE_DIR/it-runner.yml")
  mkdir -p "$STATE_DIR"
  if [[ -n $app_file ]]; then
    files+=("$app_file")
    prepare_app "$app"
    if in_ci; then
      local no_ports_file=${STATE_FILE%.env}.app-no-ports.yml
      write_app_no_ports "$no_ports_file" "$app"
      files+=("$no_ports_file")
    fi
  fi
  if $local_ports; then
    local ports_file=${STATE_FILE%.env}.local-ports.yml
    # shellcheck disable=SC2086 # one argument per service
    write_local_ports "$ports_file" $stacks
    files+=("$ports_file")
  fi
  COMPOSE_FILE=$(IFS=:; printf '%s' "${files[*]}")
  COMPOSE_ENV_FILES=$(IFS=,; printf '%s' "${ENV_FILES[*]}")
  export COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PATH_SEPARATOR=:
  write_state
  export_github_env

  log "project $COMPOSE_PROJECT_NAME ($gradle_path): $stacks${APP_IMAGE:+ + ${APP_NAME:-app} ($APP_IMAGE)}"
  log "compose files: $(for f in "${files[@]}"; do printf '%s ' "$(rel "$f")"; done)"
  if [[ ${STACK_SKIP_PULL:-0} != 1 ]]; then
    log "pulling dependency images"
    # Only the dependencies: the app image may exist only locally (Gradle buildImage, tag `local`);
    # up pulls it when it is missing.
    # shellcheck disable=SC2086
    compose pull --quiet $stacks || up_failed "pulling the dependency images failed"
  fi
  log "starting $stacks (up --wait, ${WAIT_TIMEOUT}s)"
  # shellcheck disable=SC2086
  compose up --wait --wait-timeout "$WAIT_TIMEOUT" $stacks || up_failed "the dependencies did not become healthy"
  # shellcheck disable=SC2086
  if has_word sqlserver $stacks; then
    log "seeding SQL Server (test-infra/seed/sqlserver)"
    compose exec -T sqlserver bash /seed/apply.sh || up_failed "seeding SQL Server failed"
  fi
  if [[ -n $app_file ]]; then
    log "starting the app under test (up --wait, ${WAIT_TIMEOUT}s)"
    compose up --wait --wait-timeout "$WAIT_TIMEOUT" --quiet-pull || up_failed "the app under test did not become healthy"
  fi

  log "up: $COMPOSE_PROJECT_NAME is healthy"
  log "  state file: $(rel "$STATE_FILE")  (set -a; . <file>; set +a  to run compose against the stack)"
  log "  network for run-compose.sh: DEPS_NETWORK=${COMPOSE_PROJECT_NAME}_default"
  if $local_ports; then
    local endpoints=''
    # shellcheck disable=SC2086
    if has_word deephaven $stacks; then endpoints+=", deephaven 127.0.0.1:${DEEPHAVEN_HOST_PORT:-10000}"; fi
    # shellcheck disable=SC2086
    if has_word sqlserver $stacks; then endpoints+=", sqlserver 127.0.0.1:${SQLSERVER_HOST_PORT:-1433} (user sa, password IT_SA_PASSWORD in the state file)"; fi
    # shellcheck disable=SC2086
    if has_word kafka $stacks; then endpoints+=", kafka 127.0.0.1:${KAFKA_HOST_PORT:-9092}"; fi
    log "  endpoints:${endpoints#,}"
  fi
}

up_failed() {
  warn "$1. Stack state follows; 'stack.sh diagnostics <dir>' collects the full bundle."
  compose ps -a >&2 || true
  compose logs --no-color --timestamps --tail 50 >&2 || true
  die 1 "up failed for $COMPOSE_PROJECT_NAME: $1 (tear down with: test-infra/compose/stack.sh down)"
}

cmd_diagnostics() {
  local dir='' gradle_path=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --project)
        [[ $# -ge 2 ]] || usage_error "diagnostics: --project needs a Gradle project path"
        gradle_path=$2
        shift 2
        ;;
      --project=*) gradle_path=${1#*=}; shift ;;
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
  [[ -z $gradle_path ]] || validate_gradle_path "$gradle_path"
  detect_engine
  init_run_identity
  load_context "$gradle_path"
  if [[ -z ${COMPOSE_PROJECT_NAME:-} ]] && ! in_ci; then
    usage_error "diagnostics: no stack recorded; set COMPOSE_PROJECT_NAME or pass --project <gradle path>"
  fi
  mkdir -p "$dir"
  log "diagnostics for $(filters_text) into $dir"

  # compose-ps.txt: the compose view when up recorded the files, the engine view otherwise.
  if [[ -n ${COMPOSE_FILE:-} && -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    export IT_SA_PASSWORD=${IT_SA_PASSWORD:-not-needed-for-diagnostics}
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
  ids=$(printf '%s\n' $ids | sort -u | paste -s -d ' ' -)

  local id service name base
  for id in $ids; do
    service=$("$ENGINE" inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null || true)
    [[ $service != '<no value>' ]] || service=
    name=$("$ENGINE" inspect --format '{{.Name}}' "$id" 2>/dev/null || true)
    name=${name#/}
    base=${service:-${name:-$id}}
    [[ ! -e $dir/$base.log ]] || base=${name:-$id}
    "$ENGINE" logs --timestamps "$id" >"$dir/$base.log" 2>&1 || true
    "$ENGINE" inspect --format '{{json .State.Health}}' "$id" >"$dir/health-$base.json" 2>/dev/null || true
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
  local gradle_path=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --project)
        [[ $# -ge 2 ]] || usage_error "down: --project needs a Gradle project path"
        gradle_path=$2
        shift 2
        ;;
      --project=*) gradle_path=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "down: unknown argument '$1'" ;;
    esac
  done
  [[ -z $gradle_path ]] || validate_gradle_path "$gradle_path"
  detect_engine
  init_run_identity
  load_context "$gradle_path"
  if [[ -z ${COMPOSE_PROJECT_NAME:-} ]] && ! in_ci; then
    log "down: no stack recorded (no COMPOSE_PROJECT_NAME, nothing in $(rel "$STATE_DIR")); nothing to do"
    return 0
  fi

  if [[ -n ${COMPOSE_FILE:-} && -n ${COMPOSE_PROJECT_NAME:-} ]]; then
    # The files are parsed again, so every variable they require must be set; none of them matters
    # for removal.
    export IT_SA_PASSWORD=${IT_SA_PASSWORD:-not-needed-for-down}
    log "down: project $COMPOSE_PROJECT_NAME (down -v --remove-orphans --timeout $DOWN_TIMEOUT)"
    compose down -v --remove-orphans --timeout "$DOWN_TIMEOUT" \
      || warn "compose down failed; removing by label instead"
  else
    log "down: no compose files recorded for ${COMPOSE_PROJECT_NAME:-this run}; removing by label"
  fi
  prune_by_labels
  if [[ -n ${STATE_FILE:-} ]]; then
    rm -f "$STATE_FILE" "${STATE_FILE%.env}.local-ports.yml" "${STATE_FILE%.env}.app-no-ports.yml"
  fi

  local leftovers
  leftovers=$(list_leftovers)
  if [[ -n $leftovers ]]; then
    printf '%s\n' "$leftovers" >&2
    die 1 "down: resources with $(filters_text) remain"
  fi
  log "down: nothing with $(filters_text) remains"
}

cmd_leak_check() {
  local warn_only=false gradle_path=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --warn-only) warn_only=true; shift ;;
      --project)
        [[ $# -ge 2 ]] || usage_error "leak-check: --project needs a Gradle project path"
        gradle_path=$2
        shift 2
        ;;
      --project=*) gradle_path=${1#*=}; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage_error "leak-check: unknown argument '$1'" ;;
    esac
  done
  [[ -z $gradle_path ]] || validate_gradle_path "$gradle_path"
  detect_engine
  init_run_identity
  load_context "$gradle_path"

  local leftovers what
  what=$(filters_text)
  leftovers=$(list_leftovers)
  if [[ -z $leftovers ]]; then
    log "leak-check: no container, volume or network carries $what"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
      # shellcheck disable=SC2016 # Markdown backticks
      printf '### Leak check: clean\n\nNo container, volume or network carries `%s`.\n' "$what" >>"$GITHUB_STEP_SUMMARY"
    fi
    return 0
  fi
  local count
  count=$(printf '%s\n' "$leftovers" | wc -l | tr -d ' ')
  printf '[stack] leak-check: %s resource(s) carry %s:\n' "$count" "$what" >&2
  printf '%s\n' "$leftovers" | sed 's/^/  /' >&2
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      # shellcheck disable=SC2016 # Markdown backticks
      printf '### Leak check: %s resource(s) left\n\nFilter: `%s`\n\n| Kind | Resource |\n|---|---|\n' "$count" "$what"
      # shellcheck disable=SC2016
      printf '%s\n' "$leftovers" | sed -E 's/^([a-z]+) (.*)$/| \1 | `\2` |/'
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
  local command=$1
  shift
  case $command in
    up) cmd_up "$@" ;;
    diagnostics) cmd_diagnostics "$@" ;;
    down) cmd_down "$@" ;;
    leak-check) cmd_leak_check "$@" ;;
    -h | --help | help) usage ;;
    *) usage_error "unknown command '$command'" ;;
  esac
}

main "$@"
