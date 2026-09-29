#!/usr/bin/env bash
# helm-release.sh: lint, render or deploy ONE Helm release, with the same flag list in every mode, for the kind
# deployment test, deploys to real clusters and laptops alike. Portable to bash 3.2 (macOS); run with --help.
# (Template of the skill gha-ephemeral-test-envs.)
set -euo pipefail

readonly EXIT_FAILED=1 EXIT_USAGE=2 EXIT_CONFIG=4 EXIT_TOOL=5

usage() {
  cat <<'EOF'
Usage: helm-release.sh <release> --chart <dir> --tag <tag> [options]

Deploys (or lints / renders) the chart <dir> as <release>. The flag list is identical in every mode, so what
lint and template check is exactly what deploy installs:
  -f <values>... (in order)   --set-string <tag key>=<tag>   the --set-string / --set-file pairs given

Modes (--mode)
  deploy     (default) namespace (created when missing, Pod Security labels), helm lint, the render check
             (--loaded-images), helm upgrade --install --wait --timeout [--rollback-on-failure when a deployed
             revision exists], kubectl rollout status of the release's workloads, helm test --logs.
             The last stdout line is "deployed <release> <namespace> <tag>"; tool output goes to stderr.
  lint       helm lint <chart> <flags>
  template   helm template <release> <chart> -n <namespace> <flags>, to stdout or --render-out <file>

Options
  --chart <dir>            chart directory (required)
  --tag <tag>              image tag (required), set as --set-string <tag key>=<tag>
  --tag-key <key>          values key of the image tag (default image.tag)
  -n, --namespace <ns>     namespace (default: default)
  -f, --values <file>      values file, repeatable, applied in order
  --set-string <key=value> repeatable. Prefer it to --set, which turns an integer-looking tag (1, 20260929)
                           into a number that a string schema rejects.
  --set-file <key=path>    repeatable
  --kubeconfig <file>      deploy: kubeconfig for helm and kubectl (default: $KUBECONFIG)
  --kube-context <name>    deploy: context of that kubeconfig, for helm (--kube-context) and kubectl
                           (--context); default: its current context. How a deploy to a real cluster names
                           the target cluster of an inventory (skill gha-config-deploy).
  --timeout <duration>     deploy: helm and rollout timeout (default 5m)
  --pss <level>            deploy: Pod Security Standard labels put on the namespace: restricted (default),
                           baseline, privileged, or none (leave the namespace labels alone)
  --loaded-images "<a b>"  deploy: render first and fail unless every container image of the release is one
                           of these (a kind node cannot pull: pass kind.sh load's `loaded` list)
  --no-test                deploy: skip helm test
  --render-out <file>      template: write the manifests to <file>
  --dry-run                print the commands, run nothing
  -h, --help               this text

Failures: a release with a deployed revision is upgraded with --rollback-on-failure (Helm 4; --atomic on Helm 3),
and a failed rollout status or helm test afterwards rolls it back too, so the previous revision keeps running.
A first install runs without it: Helm would uninstall a failed first install, taking the failed pods and their
logs with it, so it stays in place for the diagnostics (helm uninstall removes it).

Exit codes: 0 ok · 1 helm / kubectl failure, or an image that was not loaded · 2 usage ·
            4 chart or values file missing · 5 helm or kubectl missing, or Helm older than 3
Environment: HELM_BIN (default helm), KUBECTL_BIN (default kubectl), KUBECONFIG
EOF
}

info() { printf 'helm-release: %s\n' "$*" >&2; }
warn() { printf 'helm-release: warning: %s\n' "$*" >&2; }
die() {
  local code=$1
  shift
  printf 'helm-release: error: %s\n' "$*" >&2
  exit "$code"
}
need_value() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$EXIT_USAGE" "option $1 needs a value (see --help)"; fi; }
quote_cmd() {
  local out='' arg
  for arg in "$@"; do out="$out $(printf '%q' "$arg")"; done
  printf '%s' "${out# }"
}

# --- arguments --------------------------------------------------------------------------------------------

RELEASE='' CHART='' TAG='' TAG_KEY=image.tag NS=default KUBECONFIG_ARG='' KUBE_CONTEXT='' TIMEOUT=5m MODE=deploy
PSS=restricted
LOADED='' RUN_TEST=1 RENDER_OUT='' DRY_RUN=0
VALUES=() SETS=()
while [ $# -gt 0 ]; do
  case $1 in
    --chart) need_value "$@"; CHART=$2; shift ;;
    --chart=*) CHART=${1#*=} ;;
    --tag) need_value "$@"; TAG=$2; shift ;;
    --tag=*) TAG=${1#*=} ;;
    --tag-key) need_value "$@"; TAG_KEY=$2; shift ;;
    --tag-key=*) TAG_KEY=${1#*=} ;;
    -n | --namespace) need_value "$@"; NS=$2; shift ;;
    --namespace=*) NS=${1#*=} ;;
    -f | --values) need_value "$@"; VALUES+=("$2"); shift ;;
    --values=*) VALUES+=("${1#*=}") ;;
    --set-string) need_value "$@"; SETS+=(--set-string "$2"); shift ;;
    --set-string=*) SETS+=(--set-string "${1#*=}") ;;
    --set-file) need_value "$@"; SETS+=(--set-file "$2"); shift ;;
    --set-file=*) SETS+=(--set-file "${1#*=}") ;;
    --kubeconfig) need_value "$@"; KUBECONFIG_ARG=$2; shift ;;
    --kubeconfig=*) KUBECONFIG_ARG=${1#*=} ;;
    --kube-context) need_value "$@"; KUBE_CONTEXT=$2; shift ;;
    --kube-context=*) KUBE_CONTEXT=${1#*=} ;;
    --timeout) need_value "$@"; TIMEOUT=$2; shift ;;
    --timeout=*) TIMEOUT=${1#*=} ;;
    --mode) need_value "$@"; MODE=$2; shift ;;
    --mode=*) MODE=${1#*=} ;;
    --pss) need_value "$@"; PSS=$2; shift ;;
    --pss=*) PSS=${1#*=} ;;
    --loaded-images) need_value "$@"; LOADED=$2; shift ;;
    --loaded-images=*) LOADED=${1#*=} ;;
    --no-test) RUN_TEST=0 ;;
    --render-out) need_value "$@"; RENDER_OUT=$2; shift ;;
    --render-out=*) RENDER_OUT=${1#*=} ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "$EXIT_USAGE" "unknown option $1 (see --help)" ;;
    *)
      [ -z "$RELEASE" ] || die "$EXIT_USAGE" "exactly one release name expected (got '$RELEASE' and '$1')"
      RELEASE=$1
      ;;
  esac
  shift
done

is_dns_label() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' && [ "${#1}" -le "$2" ]; }
[ -n "$RELEASE" ] || { usage >&2; die "$EXIT_USAGE" "the release name is required"; }
is_dns_label "$RELEASE" 53 || die "$EXIT_USAGE" "release '$RELEASE' must be a lower-case DNS label of at most 53 characters (Helm's limit)"
is_dns_label "$NS" 63 || die "$EXIT_USAGE" "namespace '$NS' is not a valid Kubernetes namespace name"
[ -n "$CHART" ] || die "$EXIT_USAGE" "--chart <dir> is required"
[ -n "$TAG" ] || die "$EXIT_USAGE" "--tag <tag> is required (the image tag to deploy)"
printf '%s' "$TAG" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' || die "$EXIT_USAGE" "--tag '$TAG' is not a valid image tag"
printf '%s' "$TAG_KEY" | grep -Eq '^[A-Za-z0-9_.-]+$' || die "$EXIT_USAGE" "--tag-key '$TAG_KEY' is not a values key"
printf '%s' "$TIMEOUT" | grep -Eq '^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$' || die "$EXIT_USAGE" "--timeout '$TIMEOUT' is not a duration such as 5m or 300s"
case $MODE in deploy | lint | template) ;; *) die "$EXIT_USAGE" "--mode must be deploy, lint or template" ;; esac
case $PSS in restricted | baseline | privileged | none) ;; *) die "$EXIT_USAGE" "--pss must be restricted, baseline, privileged or none" ;; esac
if [ -n "$RENDER_OUT" ] && [ "$MODE" != template ]; then die "$EXIT_USAGE" "--render-out only applies to --mode template"; fi
[ -f "$CHART/Chart.yaml" ] || die "$EXIT_CONFIG" "chart not found: $CHART/Chart.yaml"
for file in ${VALUES[@]+"${VALUES[@]}"}; do
  [ -f "$file" ] || die "$EXIT_CONFIG" "values file not found: $file"
  case $file in *,*) die "$EXIT_CONFIG" "values file $file: a comma breaks helm's --values" ;; esac
done

FLAGS=()
for file in ${VALUES[@]+"${VALUES[@]}"}; do FLAGS+=(-f "$file"); done
FLAGS+=(--set-string "$TAG_KEY=$TAG" ${SETS[@]+"${SETS[@]}"})

# --- tools --------------------------------------------------------------------------------------------------

HELM=${HELM_BIN:-helm}
KUBECTL=${KUBECTL_BIN:-kubectl}
HK=()
KK=()
if [ -n "$KUBECONFIG_ARG" ] && [ "$MODE" = deploy ]; then
  [ "$DRY_RUN" -eq 1 ] || [ -f "$KUBECONFIG_ARG" ] || die "$EXIT_USAGE" "--kubeconfig $KUBECONFIG_ARG: file not found"
  HK=(--kubeconfig "$KUBECONFIG_ARG")
  KK=(--kubeconfig "$KUBECONFIG_ARG")
fi
if [ -n "$KUBE_CONTEXT" ] && [ "$MODE" = deploy ]; then
  HK+=(--kube-context "$KUBE_CONTEXT")
  KK+=(--context "$KUBE_CONTEXT")
fi
ROLLBACK_FLAG=--rollback-on-failure
check_tools() {
  local version
  command -v "$HELM" >/dev/null 2>&1 || die "$EXIT_TOOL" "helm not found ($HELM)"
  version=$("$HELM" version --template '{{.Version}}' 2>/dev/null) || die "$EXIT_TOOL" "'$HELM version' failed: is it Helm?"
  case $version in
    v4.*) ROLLBACK_FLAG=--rollback-on-failure ;;
    v3.*)
      ROLLBACK_FLAG=--atomic
      warn "Helm $version: using --atomic (Helm 4 renamed it --rollback-on-failure); pin Helm 4 to match CI"
      ;;
    *) die "$EXIT_TOOL" "Helm $version found: this script needs Helm 3 or 4" ;;
  esac
  if [ "$MODE" = deploy ]; then
    command -v "$KUBECTL" >/dev/null 2>&1 || die "$EXIT_TOOL" "kubectl not found ($KUBECTL)"
  fi
}
[ "$DRY_RUN" -eq 1 ] || check_tools

# Runs (or, with --dry-run, prints) one command; in deploy mode tool output goes to stderr.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s\n' "$(quote_cmd "$@")"
    return 0
  fi
  info "$(quote_cmd "$@")"
  if [ "$MODE" = deploy ]; then "$@" >&2; else "$@"; fi
}

# --- deploy helpers -----------------------------------------------------------------------------------------

ensure_namespace() {
  local kc=("$KUBECTL" ${KK[@]+"${KK[@]}"})
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s || %s\n' "$(quote_cmd "${kc[@]}" get namespace "$NS")" "$(quote_cmd "${kc[@]}" create namespace "$NS")"
  elif ! "${kc[@]}" get namespace "$NS" >/dev/null 2>&1; then
    # Another deploy may create it at the same moment: the second get settles the race.
    run "${kc[@]}" create namespace "$NS" || "${kc[@]}" get namespace "$NS" >/dev/null
  fi
  [ "$PSS" != none ] || return 0
  run "${kc[@]}" label --overwrite namespace "$NS" "pod-security.kubernetes.io/enforce=$PSS" \
    pod-security.kubernetes.io/enforce-version=latest "pod-security.kubernetes.io/warn=$PSS" \
    "pod-security.kubernetes.io/audit=$PSS"
}

# The node cannot pull: every container image the release would run must be one that was loaded.
# Reads the `image:` lines of the rendered manifests (containers, initContainers, test hooks).
check_loaded_images() {
  local render images image missing=''
  [ -n "$LOADED" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s | <every image: must be one of: %s>\n' "$(quote_cmd "$HELM" template "$RELEASE" "$CHART" -n "$NS" "${FLAGS[@]}")" "$LOADED"
    return 0
  fi
  render=$("$HELM" template "$RELEASE" "$CHART" -n "$NS" "${FLAGS[@]}") || die "$EXIT_FAILED" "helm template failed for $RELEASE"
  images=$(printf '%s\n' "$render" | sed -n -E 's/^[[:space:]]*(- )?image:[[:space:]]*["'\'']?([^"'\''[:space:]]+)["'\'']?[[:space:]]*$/\2/p' | sort -u)
  [ -n "$images" ] || die "$EXIT_FAILED" "the rendered release $RELEASE has no container image"
  for image in $images; do
    case " $LOADED " in *" $image "*) ;; *) missing="$missing $image" ;; esac
  done
  [ -z "$missing" ] || die "$EXIT_FAILED" "release $RELEASE would run${missing}, which is not on the nodes (loaded: $LOADED). Deploy with the tag the image was loaded with and keep the chart's image repository equal to the loaded one."
  info "render check: every image of $RELEASE is on the nodes ($(printf '%s' "$images" | tr '\n' ' '))"
}

diagnose() {
  local kc=("$KUBECTL" ${KK[@]+"${KK[@]}"} -n "$NS") selector="app.kubernetes.io/instance=$RELEASE"
  warn "diagnostics for release $RELEASE in namespace $NS:"
  "$HELM" status "$RELEASE" -n "$NS" ${HK[@]+"${HK[@]}"} >&2 2>&1 || true
  "${kc[@]}" get deployments,statefulsets,daemonsets,replicasets,pods,jobs -l "$selector" -o wide >&2 2>&1 || true
  "${kc[@]}" describe pods -l "$selector" >&2 2>&1 || true
  "${kc[@]}" logs -l "$selector" --all-containers --prefix --tail=100 >&2 2>&1 || true
  "${kc[@]}" get events --sort-by=.lastTimestamp 2>&1 | tail -n 30 >&2 || true
}

# Workloads carrying the Helm-standard instance label; charts from `helm create` set it.
rollout_status() {
  local kc=("$KUBECTL" ${KK[@]+"${KK[@]}"} -n "$NS") workloads workload
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s | %s\n' "$(quote_cmd "${kc[@]}" get deployments,statefulsets,daemonsets -l "app.kubernetes.io/instance=$RELEASE" -o name)" \
      "$(quote_cmd "${kc[@]}" rollout status '<each>' "--timeout=$TIMEOUT")"
    return 0
  fi
  workloads=$("${kc[@]}" get deployments,statefulsets,daemonsets -l "app.kubernetes.io/instance=$RELEASE" -o name) || return 1
  if [ -z "$workloads" ]; then
    warn "no workload labelled app.kubernetes.io/instance=$RELEASE: rollout status skipped (helm --wait still applied)"
    return 0
  fi
  for workload in $workloads; do
    run "${kc[@]}" rollout status "$workload" "--timeout=$TIMEOUT" || return 1
  done
}

# --- modes --------------------------------------------------------------------------------------------------

cmd_deploy() {
  local had_release=0 rollback=("$ROLLBACK_FLAG") history failed=''
  ensure_namespace || die "$EXIT_FAILED" "could not prepare namespace $NS"
  run "$HELM" lint "$CHART" "${FLAGS[@]}" || die "$EXIT_FAILED" "helm lint failed for $RELEASE"
  check_loaded_images
  if [ "$DRY_RUN" -eq 0 ]; then
    history=$("$HELM" history "$RELEASE" -n "$NS" ${HK[@]+"${HK[@]}"} --max 256 -o json 2>/dev/null || true)
    case $history in
      *'"status":"deployed"'* | *'"status":"superseded"'*) had_release=1 ;;
      *)
        rollback=()
        info "first install of $RELEASE in $NS: no rollback flag, a failure stays in place for the diagnostics"
        ;;
    esac
  fi
  if ! run "$HELM" upgrade --install "$RELEASE" "$CHART" -n "$NS" --create-namespace "${FLAGS[@]}" \
    ${rollback[@]+"${rollback[@]}"} --wait --timeout "$TIMEOUT" ${HK[@]+"${HK[@]}"}; then
    diagnose
    if [ "$had_release" -eq 1 ]; then die "$EXIT_FAILED" "helm upgrade failed: the previous revision of $RELEASE was restored"; fi
    die "$EXIT_FAILED" "helm upgrade --install failed (first install kept for diagnostics; helm uninstall $RELEASE -n $NS removes it)"
  fi
  rollout_status || failed="rollout status"
  if [ -z "$failed" ] && [ "$RUN_TEST" -eq 1 ]; then
    run "$HELM" test "$RELEASE" -n "$NS" --logs --timeout "$TIMEOUT" ${HK[@]+"${HK[@]}"} || failed="helm test"
  fi
  if [ -n "$failed" ]; then
    diagnose
    if [ "$had_release" -eq 1 ]; then
      warn "$failed failed: rolling $RELEASE back to its previous revision"
      "$HELM" rollback "$RELEASE" -n "$NS" --wait --timeout "$TIMEOUT" ${HK[@]+"${HK[@]}"} >&2 \
        || warn "helm rollback failed: see helm history $RELEASE -n $NS"
    fi
    die "$EXIT_FAILED" "$failed failed for $RELEASE in $NS"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then info "dry run: nothing was deployed"; else printf 'deployed %s %s %s\n' "$RELEASE" "$NS" "$TAG"; fi
}

case $MODE in
  lint) run "$HELM" lint "$CHART" "${FLAGS[@]}" || die "$EXIT_FAILED" "helm lint failed for $RELEASE" ;;
  template)
    if [ -z "$RENDER_OUT" ]; then
      run "$HELM" template "$RELEASE" "$CHART" -n "$NS" "${FLAGS[@]}" || die "$EXIT_FAILED" "helm template failed for $RELEASE"
    elif [ "$DRY_RUN" -eq 1 ]; then
      printf '+ %s > %s\n' "$(quote_cmd "$HELM" template "$RELEASE" "$CHART" -n "$NS" "${FLAGS[@]}")" "$(printf '%q' "$RENDER_OUT")"
    else
      mkdir -p "$(dirname "$RENDER_OUT")"
      info "$(quote_cmd "$HELM" template "$RELEASE" "$CHART" -n "$NS" "${FLAGS[@]}") > $RENDER_OUT"
      "$HELM" template "$RELEASE" "$CHART" -n "$NS" "${FLAGS[@]}" >"$RENDER_OUT" || die "$EXIT_FAILED" "helm template failed for $RELEASE"
    fi
    ;;
  deploy) cmd_deploy ;;
esac
