#!/usr/bin/env bash
# selftest.sh: offline smoke test of this skill's scripts against stubbed docker, kind, kubectl and helm that
# record every call. No container engine, cluster or network needed. Run it after adapting the scripts.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: selftest.sh [--keep]

Copies the example compose files into a temporary directory, puts stub docker / kind / kubectl / helm first on
PATH and drives every command of stack.sh, kind.sh, helm-release.sh, smoke-diff.sh and junit-summary.sh
through its success and failure paths. It checks exit codes, the commands issued, the files written and
what lands in $GITHUB_ENV, $GITHUB_OUTPUT and $GITHUB_STEP_SUMMARY.

Environment (default: the copies in this skill's assets/scripts/)
  STACK_SH, KIND_SH, HELM_RELEASE_SH, SMOKE_DIFF_SH, JUNIT_SUMMARY_SH   the scripts under test, e.g. the
                                                                         adapted copies in your repository
Options
  --keep    keep the temporary directory and print its path
The checks use the skill's example compose files (postgres, app) and CI_LABEL_PREFIX=com.example.ci.
Needs bash, coreutils, sed, awk, grep and jq.
Exit codes: 0 every check passed · 1 a check failed · 2 usage
EOF
}

KEEP=false
case ${1:-} in
  '') ;;
  --keep) KEEP=true ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "selftest: jq is required" >&2; exit 2; }

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ASSETS=$SKILL_DIR/assets
abs() { if [[ -d $(dirname "$1") ]]; then (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); else printf '%s' "$1"; fi; }
# SUT_*: the scripts under test (STACK_SH and KIND_SH would fall to the environment scrub below).
SUT_STACK=$(abs "${STACK_SH:-$ASSETS/scripts/stack.sh}")
SUT_KIND=$(abs "${KIND_SH:-$ASSETS/scripts/kind.sh}")
SUT_HELM_RELEASE=$(abs "${HELM_RELEASE_SH:-$ASSETS/scripts/helm-release.sh}")
SUT_SMOKE_DIFF=$(abs "${SMOKE_DIFF_SH:-$ASSETS/scripts/smoke-diff.sh}")
SUT_JUNIT=$(abs "${JUNIT_SUMMARY_SH:-$ASSETS/scripts/junit-summary.sh}")
for sut in "$SUT_STACK" "$SUT_KIND" "$SUT_HELM_RELEASE" "$SUT_SMOKE_DIFF" "$SUT_JUNIT"; do
  [[ -f $sut ]] || { echo "selftest: $sut not found" >&2; exit 2; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ete-selftest.XXXXXX")
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { if $KEEP; then echo "selftest: kept $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

# Never inherit a real CI context, engine or cluster.
while IFS= read -r var; do unset "$var"; done < <(env | sed -n 's/^\(GITHUB_[A-Z_]*\|RUNNER_[A-Z_]*\|CI_[A-Z_]*\|COMPOSE_[A-Z_]*\|STACK_[A-Z_]*\|KIND_[A-Z_]*\|TEST_[A-Z_]*\|APP_[A-Z_]*\|KUBECONFIG\)=.*/\1/p')
# The example compose files carry com.example.ci labels; an adapted script may default to another prefix.
export HOME=$WORK/home CI='' CI_LABEL_PREFIX=com.example.ci
mkdir -p "$HOME" "$WORK/bin" "$WORK/state"
export STUB_LOG=$WORK/calls.log STUB_STATE=$WORK/state

# --- the stub: one script, dispatched on its name --------------------------------------------------------
cat >"$WORK/bin/stub" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
tool=$(basename "$0")
printf '%s %s\n' "$tool" "$*" >>"$STUB_LOG"
S=$STUB_STATE
touch "$S/containers" "$S/volumes" "$S/networks" "$S/clusters" "$S/images"
# rows: containers "id|name|labels|state|status", volumes "name|labels", networks "id|name|labels"
match() { # match <labels> <filter>: label=k=v or label=k
  local want=${2#label=}
  if [[ $want == *=* ]]; then [[ " $1 " == *" $want "* ]]; else [[ " $1 " == *" $want="* ]]; fi
}
fmt() { # fmt <format> id name status state
  local f=$1
  f=${f//'{{.ID}}'/$2}; f=${f//'{{.Names}}'/$3}; f=${f//'{{.Name}}'/$3}; f=${f//'{{.Status}}'/$4}; f=${f//'{{.State}}'/$5}
  printf '%s\n' "$f"
}
listing() { # listing <file> <kind> args...: docker ps / volume ls / network ls
  local file=$1 kind=$2 filter='' format='' quiet=false
  shift 2
  while [[ $# -gt 0 ]]; do
    case $1 in
      --filter) filter=$2; shift ;;
      --format) format=$2; shift ;;
      -q | -aq) quiet=true ;;
    esac
    shift
  done
  while IFS='|' read -r a b c d e; do
    [[ -n $a ]] || continue
    case $kind in
      container) labels=$c ;;
      volume) labels=$b ;;
      network) labels=$c ;;
    esac
    if [[ -n $filter ]] && ! match "$labels" "$filter"; then continue; fi
    if $quiet; then
      if [[ $kind == volume ]]; then echo "$a"; else echo "$a"; fi
    elif [[ -n $format ]]; then
      case $kind in
        container) fmt "$format" "$a" "$b" "$e" "$d" ;;
        volume) fmt "$format" "" "$a" "" "" ;;
        network) fmt "$format" "$a" "$b" "" "" ;;
      esac
    else
      echo "$a $b"
    fi
  done <"$file"
  [[ -z ${STUB_LIST_FAIL:-} ]]
}
drop() { # drop <file> <ids...>
  local file=$1 id
  shift
  [[ -z ${STUB_STICKY:-} ]] || return 1
  for id in "$@"; do grep -v "^$id|" "$file" >"$file.tmp" || true; mv "$file.tmp" "$file"; done
}
case $tool in
  docker | podman)
    case ${1:-} in
      info) [[ -z ${STUB_ENGINE_DOWN:-} ]]; exit ;;
      compose)
        shift
        args=()
        while [[ $# -gt 0 ]]; do
          if [[ $1 == --env-file ]]; then shift 2; continue; fi
          args+=("$1"); shift
        done
        case ${args[0]:-} in
          version) echo "Docker Compose version v2.40.0" ;;
          up) [[ -z ${STUB_FAIL_UP:-} ]] || exit 1 ;;
          ps) if [[ " ${args[*]} " == *" --format "* ]]; then printf '%s\n' "${STUB_COMPOSE_PS:-}"; else echo "NAME STATUS"; fi ;;
          logs) echo "stub log line of ${args[*]: -1}" ;;
          down) [[ -z ${STUB_FAIL_DOWN:-} ]] || exit 1 ;;
        esac
        exit 0
        ;;
      ps) shift; listing "$S/containers" container "$@"; exit ;;
      volume)
        case $2 in
          ls) shift 2; listing "$S/volumes" volume "$@"; exit ;;
          rm) shift 3; drop "$S/volumes" "$@"; exit ;;
        esac
        ;;
      network)
        case $2 in
          ls) shift 2; listing "$S/networks" network "$@"; exit ;;
          rm) shift 2; drop "$S/networks" "$@"; grep -v "|$1|" "$S/networks" >"$S/n.tmp" || true
              if [[ -z ${STUB_STICKY:-} ]]; then mv "$S/n.tmp" "$S/networks"; fi; exit 0 ;;
          inspect) grep -q "|$3|" "$S/networks"; exit ;;
        esac
        ;;
      rm) shift 3; drop "$S/containers" "$@"; exit ;;
      inspect)
        id=${*: -1}
        row=$(grep "^$id|" "$S/containers")
        case $3 in
          *compose.service*) sed -n 's/.*com.docker.compose.service=\([^ |]*\).*/\1/p' <<<"$row" ;;
          '{{.Name}}') echo "/$(cut -d'|' -f2 <<<"$row")" ;;
          *State*) echo '{"Status":"exited","ExitCode":1,"OOMKilled":false}' ;;
        esac
        exit 0
        ;;
      logs) echo "log of ${*: -1}"; exit 0 ;;
      stats) echo "CONTAINER CPU MEM"; exit 0 ;;
      image)
        ref=${*: -1}
        grep -qxF "$ref" "$S/images" || exit 1
        if [[ " $* " == *" --format "* ]]; then echo "sha256:1111111111111111111111111111111111111111111111111111111111111111"; fi
        exit 0
        ;;
      pull) echo "${*: -1}" >>"$S/images"; exit 0 ;;
      tag) echo "$3" >>"$S/images"; exit 0 ;;
      save) : >"$3"; exit 0 ;;
    esac
    exit 0
    ;;
  kind)
    case ${1:-} in
      version) echo "kind v0.33.0 go1.25 linux/amd64" ;;
      get) cat "$S/clusters" ;;
      create)
        name=$4 kc=''
        while [[ $# -gt 0 ]]; do if [[ $1 == --kubeconfig ]]; then kc=$2; fi; shift; done
        echo "$name" >>"$S/clusters"
        echo "c-$name|$name-control-plane|io.x-k8s.kind.cluster=$name|running|Up 1 minute" >>"$S/containers"
        grep -q '|kind|' "$S/networks" || echo "n-kind|kind|" >>"$S/networks"
        echo "apiVersion: v1" >"$kc"
        ;;
      delete)
        name=$4
        if [[ -z ${STUB_STICKY:-} ]]; then
          grep -vxF "$name" "$S/clusters" >"$S/c.tmp" || true; mv "$S/c.tmp" "$S/clusters"
          grep -v "io.x-k8s.kind.cluster=$name|" "$S/containers" >"$S/c.tmp" || true; mv "$S/c.tmp" "$S/containers"
        fi
        ;;
      export)
        if [[ $2 == kubeconfig ]]; then echo "apiVersion: v1" >"${*: -1}"; else mkdir -p "$3"; fi
        ;;
      load) ;;
    esac
    exit 0
    ;;
  kubectl)
    args=" $* "
    case $args in
      *" get pods -A "*) printf 'apps api-a-1 Running true\napps api-b-2 Pending <none>\nkube-system coredns-1 Running true\n' ;;
      *" get namespace "*) [[ -f $S/ns ]] || exit 1 ;;
      *" create namespace "*) touch "$S/ns" ;;
      *" rollout status "*) exit "${STUB_ROLLOUT_RC:-0}" ;;
      *" -o name "*) rel=$(sed -n 's/.*app.kubernetes.io\/instance=\([^ ]*\).*/\1/p' <<<"$args"); echo "deployment.apps/$rel" ;;
      *" exec "*)
        target=$(sed -n 's/.* exec \([^ ]*\) .*/\1/p' <<<"$args")
        [[ -f $S/exec-${target#*/} ]] || { echo "error: $target not found" >&2; exit 1; }
        cat "$S/exec-${target#*/}"
        ;;
      *) echo "kubectl stub output" ;;
    esac
    exit 0
    ;;
  helm)
    case ${1:-} in
      version) echo "${STUB_HELM_VERSION:-v4.3.0}" ;;
      template)
        for image in ${STUB_RENDER_IMAGES:-}; do printf -- '---\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: c\n          image: "%s"\n          imagePullPolicy: IfNotPresent\n' "$image"; done
        ;;
      list)
        if [[ " $* " != *" --no-headers "* ]]; then printf 'NAME\tNAMESPACE\tREVISION\tSTATUS\n'; fi
        printf 'api-eu-1\tapps\t1\tdeployed\n'
        ;;
      history) if [[ -n ${STUB_HELM_HISTORY:-} ]]; then echo "$STUB_HELM_HISTORY"; else echo "Error: release: not found" >&2; exit 1; fi ;;
      upgrade) exit "${STUB_HELM_UPGRADE_RC:-0}" ;;
      test) exit "${STUB_HELM_TEST_RC:-0}" ;;
    esac
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/stub"
for tool in docker kind kubectl helm; do ln -s stub "$WORK/bin/$tool"; done
export PATH="$WORK/bin:$PATH"

# --- harness -----------------------------------------------------------------------------------------------
PASS=0 FAIL=0
OUT=$WORK/out.txt
ok() { PASS=$((PASS + 1)); printf 'ok     %s\n' "$1"; }
not_ok() { # not_ok <description> [file to show, default $OUT]
  FAIL=$((FAIL + 1))
  printf 'NOT OK %s\n' "$1"
  if [[ -f ${2:-$OUT} ]]; then sed 's/^/       | /' "${2:-$OUT}" | tail -n 25; fi
}
# check <description> <expected exit> <command...>: runs it with output in $OUT
check() {
  local what=$1 want=$2 got=0
  shift 2
  "$@" >"$OUT" 2>&1 || got=$?
  if [[ $got -eq $want ]]; then ok "$what (exit $got)"; else echo "(expected exit $want, got $got)" >>"$OUT"; not_ok "$what"; fi
}
# expect <description> <grep -E pattern> <file>
SHOW=$WORK/show.txt
expect() {
  if grep -Eq -- "$2" "$3"; then ok "$1"; else { cat "$3" 2>/dev/null; echo "(no line matches: $2)"; } >"$SHOW"; not_ok "$1" "$SHOW"; fi
}
refute() { if ! grep -Eq -- "$2" "$3"; then ok "$1"; else grep -E -- "$2" "$3" >"$SHOW"; not_ok "$1" "$SHOW"; fi; }
EF='(--env-file [^ ]+ )*' # compose calls carry --env-file versions.env
reset_state() { rm -f "$STUB_STATE"/* "$STUB_LOG"; touch "$STUB_LOG"; }
ci_env() { # a fresh GitHub Actions context
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=2 GITHUB_WORKSPACE=$WORK/repo
  export GITHUB_ENV=$WORK/github_env GITHUB_OUTPUT=$WORK/github_output GITHUB_STEP_SUMMARY=$WORK/summary.md
  : >"$GITHUB_ENV"; : >"$GITHUB_OUTPUT"; : >"$GITHUB_STEP_SUMMARY"
}
laptop_env() { unset GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_WORKSPACE GITHUB_ENV GITHUB_OUTPUT GITHUB_STEP_SUMMARY COMPOSE_PROJECT_NAME CI_RUN_ID CI_RUN_ATTEMPT STACK_SCOPE KIND_CLUSTER_NAME; }
# Loads what `up` appended to $GITHUB_ENV, as the runner does for the next step.
load_github_env() { set -a; # shellcheck source=/dev/null
  . "$GITHUB_ENV"; set +a; }

# --- stack.sh -----------------------------------------------------------------------------------------------
REPO=$WORK/repo
mkdir -p "$REPO/test-infra/compose" "$REPO/services/api"
cp "$SUT_STACK" "$REPO/test-infra/compose/stack.sh"
cp "$ASSETS"/compose/{base.yml,test-runner.yml,postgres.yml,postgres.local.yml} "$REPO/test-infra/compose/"
cp "$ASSETS/compose/app.compose.yml" "$REPO/services/api/compose.test.yml"
sed -e 's#__PROJECT_ID__#services/api#' "$ASSETS/compose/stacks.yml" >"$REPO/test-infra/compose/stacks.yml"
printf '"%s": [postgres]\n' ':app:worker' >>"$REPO/test-infra/compose/stacks.yml"
sed -e 's#__POSTGRES_IMAGE__#docker.io/library/postgres:17@sha256:2222222222222222222222222222222222222222222222222222222222222222#' \
  -e 's#__TEST_RUNNER_IMAGE__#docker.io/library/eclipse-temurin:21-jdk#' "$ASSETS/compose/versions.env" >"$REPO/test-infra/compose/versions.env"
STACK=$REPO/test-infra/compose/stack.sh
DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
cd "$REPO"

echo "# stack.sh"
reset_state
laptop_env
check "stack.sh --help" 0 bash "$STACK" --help
check "stack.sh without a command is a usage error" 2 bash "$STACK"
check "stack.sh up: undeclared project" 2 bash "$STACK" up --project services/unknown
check "stack.sh up: missing COMPOSE_BIN engine" 5 env COMPOSE_BIN="no-such-engine compose" bash "$STACK" up --stack postgres
check "stack.sh up: unreachable engine" 5 env STUB_ENGINE_DOWN=1 bash "$STACK" up --stack postgres
check "stack.sh up: APP_IMAGE without tag or digest" 2 env APP_IMAGE=ghcr.io/o/api bash "$STACK" up --project services/api --file services/api/compose.test.yml

ci_env
export COMPOSE_PROJECT_NAME=ci-4242-2 CI_RUN_ID=4242 CI_RUN_ATTEMPT=2 APP_IMAGE=ghcr.io/o/api:pr-7-abc1234@$DIGEST
check "stack.sh up (CI): project stacks + app under test" 0 bash "$STACK" up --project services/api --file services/api/compose.test.yml --app-service app
expect "up pulls only the stack services" "^docker compose ${EF}pull --quiet --include-deps postgres\$" "$STUB_LOG"
expect "up waits for the stack services first" "^docker compose ${EF}up --wait --wait-timeout 180 postgres\$" "$STUB_LOG"
expect "up then waits for the app" "^docker compose ${EF}up --wait --wait-timeout 180 --quiet-pull\$" "$STUB_LOG"
expect "GITHUB_ENV gets the project name" '^COMPOSE_PROJECT_NAME=ci-4242-2$' "$GITHUB_ENV"
expect "GITHUB_ENV gets the merged files, no-ports override last" '^COMPOSE_FILE=.*/base.yml:.*/postgres.yml:.*/test-runner.yml:.*/compose.test.yml:.*/ci-4242-2.no-ports.yml$' "$GITHUB_ENV"
expect "GITHUB_ENV gets the generated secret" '^DB_PASSWORD=Aa1-[0-9a-f]{32}$' "$GITHUB_ENV"
expect "the secret is masked" '^::add-mask::Aa1-[0-9a-f]{32}$' "$OUT"
expect "the no-ports override resets the app's ports" 'ports: !reset \[\]' "$REPO/test-infra/compose/.state/ci-4242-2.no-ports.yml"
state_mode=$(stat -c %a "$REPO/test-infra/compose/.state/ci-4242-2.env" 2>/dev/null || stat -f %Lp "$REPO/test-infra/compose/.state/ci-4242-2.env")
if [[ $state_mode == 600 ]]; then ok "the state file is private (600)"; else echo "mode $state_mode" >"$OUT"; not_ok "the state file is private (600)"; fi
first_password=$(sed -n 's/^DB_PASSWORD=//p' "$GITHUB_ENV")
: >"$GITHUB_ENV"
check "stack.sh up again (re-run of the same project)" 0 bash "$STACK" up --project services/api --file services/api/compose.test.yml --app-service app
expect "a re-run reuses the stack's password" "^DB_PASSWORD=$first_password\$" "$GITHUB_ENV"
load_github_env

check "stack.sh up: failing health check" 1 env STUB_FAIL_UP=1 STUB_COMPOSE_PS="postgres exited unhealthy" bash "$STACK" up --project services/api
expect "a failed up prints the failed service's own log" 'last output of postgres \(exited, unhealthy\)' "$OUT"

printf '%s\n' "c1|ci-4242-2-postgres-1|com.example.ci.run=4242 com.docker.compose.project=ci-4242-2 com.docker.compose.service=postgres|running|Up 2 minutes (healthy)" \
  "c2|ci-4242-2-app-1|com.example.ci.run=4242 com.docker.compose.project=ci-4242-2 com.docker.compose.service=app|running|Up 1 minute (healthy)" >"$STUB_STATE/containers"
echo "ci-4242-2_postgres-data|com.example.ci.run=4242 com.docker.compose.project=ci-4242-2" >"$STUB_STATE/volumes"
echo "n1|ci-4242-2_default|com.example.ci.run=4242 com.docker.compose.project=ci-4242-2" >"$STUB_STATE/networks"
check "stack.sh status: every container healthy" 0 bash "$STACK" status
sed -i.bak 's/Up 1 minute (healthy)/Up 1 minute (unhealthy)/' "$STUB_STATE/containers"
check "stack.sh status: an unhealthy container" 1 bash "$STACK" status
check "stack.sh diagnostics" 0 bash "$STACK" diagnostics "$WORK/diag"
for f in compose-ps.txt postgres.log app.log state-postgres.json state-app.json stats.txt; do
  if [[ -s $WORK/diag/$f ]]; then ok "diagnostics wrote $f"; else ls -la "$WORK/diag" >"$OUT" 2>&1; not_ok "diagnostics wrote $f"; fi
done
check "stack.sh leak-check before down finds the stack" 1 bash "$STACK" leak-check
# shellcheck disable=SC2016 # Markdown backticks in the pattern, not a command substitution
expect "the leak summary lists the resources" '^\| volume \| `ci-4242-2_postgres-data` \|$' "$GITHUB_STEP_SUMMARY"
check "stack.sh leak-check --warn-only reports without failing" 0 bash "$STACK" leak-check --warn-only
expect "--warn-only raises a warning annotation" '^::warning title=leak-check::' "$OUT"
check "stack.sh down: nothing left sticks" 1 env STUB_STICKY=1 bash "$STACK" down
cp "$WORK/github_env" "$WORK/github_env.saved"
load_github_env
: >"$STUB_LOG"
check "stack.sh down" 0 bash "$STACK" down
expect "down runs compose down with volumes and orphans" "^docker compose ${EF}down -v --remove-orphans --timeout 20\$" "$STUB_LOG"
expect "down prunes by the run label" '^docker ps -aq --filter label=com.example.ci.run=4242$' "$STUB_LOG"
expect "down prunes by the project label" '^docker ps -aq --filter label=com.docker.compose.project=ci-4242-2$' "$STUB_LOG"
if [[ ! -e $REPO/test-infra/compose/.state/ci-4242-2.env ]]; then ok "down removes the state file"; else not_ok "down removes the state file"; fi
check "stack.sh leak-check after down" 0 bash "$STACK" leak-check
expect "the clean leak check lands in the job summary" '^### Leak check: clean$' "$GITHUB_STEP_SUMMARY"
check "stack.sh down when up never ran (teardown after an early failure)" 0 bash "$STACK" down
check "stack.sh leak-check: a failing engine query is an error" 1 env STUB_LIST_FAIL=1 bash "$STACK" leak-check
: >"$STUB_LOG"
check "stack.sh leak-check with STACK_SCOPE=project" 0 env STACK_SCOPE=project bash "$STACK" leak-check
refute "project scope never queries the run label" 'label=com.example.ci.run=' "$STUB_LOG"

reset_state
laptop_env
unset APP_IMAGE
check "stack.sh up --local (laptop), quoted Gradle-path key" 0 bash "$STACK" up --project :app:worker --local
expect "a laptop stack is named local-<project>" 'project local-app-worker' "$OUT"
if [[ -f $REPO/test-infra/compose/.state/local-app-worker.env ]]; then ok "the laptop state file exists"; else not_ok "the laptop state file exists"; fi
expect "--local adds the published ports" 'COMPOSE_FILE=.*/postgres.local.yml' "$REPO/test-infra/compose/.state/local-app-worker.env"
check "stack.sh down on a laptop finds the only state file" 0 bash "$STACK" down
expect "laptop down targets the recorded project" '^docker ps -aq --filter label=com.docker.compose.project=local-app-worker$' "$STUB_LOG"
check "stack.sh down with nothing recorded" 0 bash "$STACK" down

# --- kind.sh ------------------------------------------------------------------------------------------------
echo "# kind.sh"
mkdir -p "$REPO/test-infra/kind"
cp "$SUT_KIND" "$REPO/test-infra/kind/kind.sh"
cp "$ASSETS/kind/cluster.yaml" "$ASSETS/kind/versions.env" "$REPO/test-infra/kind/"
KIND=$REPO/test-infra/kind/kind.sh
reset_state
laptop_env
check "kind.sh --help" 0 bash "$KIND" --help
check "kind.sh up: invalid cluster name" 2 bash "$KIND" up --name Bad_Name
check "kind.sh up: cluster name above 50 characters" 2 bash "$KIND" up --name "c-$(printf 'x%.0s' $(seq 1 50))"
check "kind.sh load: digest without a tag" 2 bash "$KIND" load "ghcr.io/o/api@$DIGEST"

ci_env
export KIND_CLUSTER_NAME=ci-4242-2 CI_RUN_ID=4242 CI_RUN_ATTEMPT=2
check "kind.sh up (CI)" 0 bash "$KIND" up
expect "up exports the cluster name to GITHUB_ENV" '^KIND_CLUSTER_NAME=ci-4242-2$' "$GITHUB_ENV"
expect "up exports the private kubeconfig" '^KUBECONFIG=.*/test-infra/kind/.state/ci-4242-2.kubeconfig$' "$GITHUB_ENV"
expect "up creates the cluster with its own kubeconfig" '^kind create cluster --name ci-4242-2 --config .*cluster.yaml --wait 120s --kubeconfig .*ci-4242-2.kubeconfig$' "$STUB_LOG"
expect "up labels the nodes with the run" 'label nodes --all --overwrite com.example.ci.run=4242 com.example.ci.attempt=2' "$STUB_LOG"
expect "up waits for cluster DNS" 'rollout status deployment/coredns' "$STUB_LOG"
check "kind.sh load: digest reference re-tagged for the chart" 0 bash "$KIND" load --tag 1.4.0-rc.3 "ghcr.io/o/api:pr-7-abc1234@$DIGEST"
expect "load pulls by digest" "^docker pull --quiet ghcr.io/o/api@$DIGEST\$" "$STUB_LOG"
expect "load tags the pulled image ID with the deploy tag" '^docker tag sha256:1{64} ghcr.io/o/api:1.4.0-rc.3$' "$STUB_LOG"
expect "load puts it on the nodes" '^kind load docker-image --name ci-4242-2 ghcr.io/o/api:1.4.0-rc.3$' "$STUB_LOG"
expect "load returns the loaded names" '^loaded=ghcr.io/o/api:1.4.0-rc.3$' "$GITHUB_OUTPUT"
check "kind.sh diagnostics" 0 bash "$KIND" diagnostics "$WORK/kind-logs"
for f in nodes.txt get-all.txt events.txt describe-apps.api-b-2.txt logs-apps.api-a-1.log helm-list.txt helm-apps.api-eu-1.txt; do
  if [[ -s $WORK/kind-logs/$f ]]; then ok "kind diagnostics wrote $f"; else ls -la "$WORK/kind-logs" >"$OUT" 2>&1; not_ok "kind diagnostics wrote $f"; fi
done
check "kind.sh leak-check before down finds the cluster" 1 bash "$KIND" leak-check
check "kind.sh down" 0 bash "$KIND" down
expect "down deletes the cluster with its kubeconfig" '^kind delete cluster --name ci-4242-2 --kubeconfig ' "$STUB_LOG"
expect "down removes the idle shared kind network in CI" '^docker network rm kind$' "$STUB_LOG"
if [[ ! -e $REPO/test-infra/kind/.state/ci-4242-2.kubeconfig ]]; then ok "down removes the kubeconfig"; else not_ok "down removes the kubeconfig"; fi
check "kind.sh leak-check after down" 0 bash "$KIND" leak-check
expect "the kind leak check lands in the job summary" '^### Leak check \(kind\): clean$' "$GITHUB_STEP_SUMMARY"
check "kind.sh up again" 0 bash "$KIND" up
check "kind.sh down: a cluster that will not go" 1 env STUB_STICKY=1 bash "$KIND" down
laptop_env

# --- helm-release.sh ----------------------------------------------------------------------------------------
echo "# helm-release.sh"
HR=$SUT_HELM_RELEASE
CHART=$WORK/chart
mkdir -p "$CHART" "$WORK/values"
printf 'apiVersion: v2\nname: api\nversion: 0.1.0\n' >"$CHART/Chart.yaml"
echo "replicaCount: 1" >"$WORK/values/common.yaml"
echo "instance: eu-1" >"$WORK/values/eu-1.yaml"
reset_state
touch "$STUB_STATE/ns"
LOADED="ghcr.io/o/api:1.4.0-rc.3"
common=(api-eu-1 --chart "$CHART" --namespace apps --tag 1.4.0-rc.3 -f "$WORK/values/common.yaml" -f "$WORK/values/eu-1.yaml" --set-string image.repository=ghcr.io/o/api)
check "helm-release.sh --help" 0 bash "$HR" --help
check "helm-release.sh: missing chart" 4 bash "$HR" api-eu-1 --chart "$WORK/nochart" --tag 1
check "helm-release.sh: release name that is not a DNS label" 2 bash "$HR" Api_1 --chart "$CHART" --tag 1
check "helm-release.sh: invalid tag" 2 bash "$HR" api-eu-1 --chart "$CHART" --tag 'bad tag'
check "helm-release.sh: Helm 2 is refused" 5 env STUB_HELM_VERSION=v2.17.0 bash "$HR" "${common[@]}"
check "helm-release.sh deploy: first install" 0 env STUB_RENDER_IMAGES="$LOADED" bash "$HR" "${common[@]}" --loaded-images "$LOADED"
expect "the tag is set as a string" 'upgrade --install api-eu-1 .* --set-string image.tag=1.4.0-rc.3 --set-string image.repository=ghcr.io/o/api' "$STUB_LOG"
refute "a first install runs without rollback" 'upgrade .*--rollback-on-failure' "$STUB_LOG"
expect "the namespace gets the restricted Pod Security labels" 'label --overwrite namespace apps pod-security.kubernetes.io/enforce=restricted' "$STUB_LOG"
expect "rollout status of the release's deployment" 'rollout status deployment.apps/api-eu-1 --timeout=5m' "$STUB_LOG"
expect "helm test with logs" '^helm test api-eu-1 -n apps --logs --timeout 5m$' "$STUB_LOG"
expect "the last stdout line names the deployment" '^deployed api-eu-1 apps 1.4.0-rc.3$' "$OUT"
: >"$STUB_LOG"
check "helm-release.sh deploy: upgrade of a deployed release" 0 env STUB_HELM_HISTORY='[{"revision":1,"status":"deployed"}]' bash "$HR" "${common[@]}"
expect "an upgrade rolls back on failure (Helm 4)" 'upgrade --install api-eu-1 .*--rollback-on-failure --wait --timeout 5m' "$STUB_LOG"
: >"$STUB_LOG"
check "helm-release.sh deploy: Helm 3 uses --atomic" 0 env STUB_HELM_VERSION=v3.19.0 STUB_HELM_HISTORY='[{"status":"deployed"}]' bash "$HR" "${common[@]}"
expect "Helm 3 upgrade uses --atomic" 'upgrade --install api-eu-1 .*--atomic --wait' "$STUB_LOG"
: >"$STUB_LOG"
check "helm-release.sh deploy: an image that was not loaded" 1 env STUB_RENDER_IMAGES="ghcr.io/o/api:latest docker.io/library/busybox:1.37" bash "$HR" "${common[@]}" --loaded-images "$LOADED"
expect "the render check names every missing image" 'would run docker.io/library/busybox:1.37 ghcr.io/o/api:latest,' "$OUT"
refute "nothing is installed after a failed render check" '^helm upgrade' "$STUB_LOG"
: >"$STUB_LOG"
check "helm-release.sh deploy: helm test fails after an upgrade" 1 env STUB_HELM_TEST_RC=1 STUB_HELM_HISTORY='[{"status":"deployed"}]' bash "$HR" "${common[@]}"
expect "a failed helm test rolls the upgrade back" '^helm rollback api-eu-1 -n apps --wait --timeout 5m$' "$STUB_LOG"
: >"$STUB_LOG"
check "helm-release.sh deploy: a failed first install stays for diagnostics" 1 env STUB_HELM_UPGRADE_RC=1 bash "$HR" "${common[@]}"
refute "a failed first install is not rolled back" '^helm rollback' "$STUB_LOG"
check "helm-release.sh --dry-run" 0 bash "$HR" "${common[@]}" --dry-run --loaded-images "$LOADED"
expect "--dry-run prints the upgrade" '^\+ helm upgrade --install api-eu-1 ' "$OUT"
: >"$STUB_LOG"
check "helm-release.sh deploy: --kube-context" 0 env STUB_HELM_HISTORY='[{"status":"deployed"}]' bash "$HR" "${common[@]}" --kube-context dev-eu
expect "helm gets --kube-context" '^helm upgrade --install api-eu-1 .* --kube-context dev-eu$' "$STUB_LOG"
expect "kubectl gets --context" '^kubectl --context dev-eu -n apps rollout status deployment.apps/api-eu-1' "$STUB_LOG"
expect "helm test runs in that context" '^helm test api-eu-1 -n apps --logs --timeout 5m --kube-context dev-eu$' "$STUB_LOG"
check "helm-release.sh --mode template --render-out" 0 env STUB_RENDER_IMAGES="$LOADED" bash "$HR" "${common[@]}" --mode template --render-out "$WORK/render/api-eu-1.yaml"
expect "template mode writes the manifests" 'image: "ghcr.io/o/api:1.4.0-rc.3"' "$WORK/render/api-eu-1.yaml"

# --- smoke-diff.sh ------------------------------------------------------------------------------------------
echo "# smoke-diff.sh"
SD=$SUT_SMOKE_DIFF
reset_state
echo '{"instance":"eu-1","config":{"table":"a"},"uptime":12}' >"$STUB_STATE/exec-api-eu-1"
echo '{"instance":"us-1","config":{"table":"b"},"uptime":40}' >"$STUB_STATE/exec-api-us-1"
echo '{"instance":"eu-1","config":{"table":"a"},"uptime":99}' >"$STUB_STATE/exec-api-eu-1-copy"
check "smoke-diff.sh --help" 0 bash "$SD" --help
check "smoke-diff.sh: probe missing" 2 bash "$SD" -n apps api-eu-1 api-us-1
check "smoke-diff.sh: the instances differ" 0 bash "$SD" -n apps api-eu-1 api-us-1 -- curl -fsS localhost:8080/info
expect "the probe runs inside the release's pod" 'exec deploy/api-eu-1 -- curl -fsS localhost:8080/info' "$STUB_LOG"
check "smoke-diff.sh: only a volatile field differs (--jq drops it)" 1 bash "$SD" -n apps --jq '{instance, config}' api-eu-1 api-eu-1-copy -- curl -fsS localhost:8080/info
check "smoke-diff.sh: a release that does not answer" 1 bash "$SD" -n apps api-eu-1 api-missing -- curl -fsS localhost:8080/info

# --- junit-summary.sh ---------------------------------------------------------------------------------------
echo "# junit-summary.sh"
JS=$SUT_JUNIT
mkdir -p "$WORK/junit/svc-a/build/test-results/it" "$WORK/junit/svc-b/build/test-results/it"
echo '<?xml version="1.0"?><testsuite name="a.DbIT" tests="3" skipped="1" failures="0" errors="0"></testsuite>' >"$WORK/junit/svc-a/build/test-results/it/TEST-a.DbIT.xml"
echo '<?xml version="1.0"?><testsuite name="b.ApiIT" tests="2" skipped="0" failures="1" errors="0"></testsuite>' >"$WORK/junit/svc-b/build/test-results/it/TEST-b.ApiIT.xml"
check "junit-summary.sh --help" 0 bash "$JS" --help
check "junit-summary.sh without a title" 2 bash "$JS"
check "junit-summary.sh" 0 env GITHUB_STEP_SUMMARY="$WORK/junit.md" bash "$JS" "Integration tests" "$WORK/junit"
expect "the summary totals every suite" '^5 tests, 1 failures, 0 errors, 1 skipped: \*\*failed\*\*$' "$WORK/junit.md"
expect "the summary lists the failing suite" 'b.ApiIT' "$WORK/junit.md"
check "junit-summary.sh with no results" 0 env GITHUB_STEP_SUMMARY="$WORK/none.md" bash "$JS" "Nothing" "$WORK/home"
expect "no results is reported, not an error" '^No JUnit results found' "$WORK/none.md"

echo
echo "selftest: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
