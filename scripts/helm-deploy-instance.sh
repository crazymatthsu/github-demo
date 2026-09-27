#!/usr/bin/env bash
# helm-deploy-instance.sh — lint, render or deploy one AppInstance with its app's Helm chart (D11 §8.3).
# The one implementation of the Helm flag list: config-lint check 12 (--mode lint / template, D5 §6.5), the
# kind deploy test and the deploy-dev Helm adapter (--mode deploy, D9 §6.4, D10 §5.9) all call it.
# Portable bash (3.2+); run with --help for the usage.
set -euo pipefail

readonly EXIT_FAILED=1 EXIT_USAGE=2 EXIT_REFUSED=3 EXIT_CONFIG=4 EXIT_TOOL=5
readonly FLOWS="cash deriv swap"
readonly MODES="lint template deploy"
# Files of a layer directory that are not shipped as appFiles: the application.yml layer itself (appConfig),
# the Helm values and the compose variables (D5 §6.4).
readonly NOT_SHIPPED="application.yml values.yaml values.yml compose.env README.md"
readonly FIELD_MANAGER=helm-deploy-instance
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

usage() {
    cat <<'EOF'
Usage: helm-deploy-instance.sh <env> <flow> <AppName> <AppInstance> --tag <tag> [--namespace <ns>] [--chart <dir>]
           [--kubeconfig <file>] [--timeout 5m] [--secret-user <u>] [--secret-password <p>]
           [--mode lint|template|deploy] [--render-out <file>] [--dry-run]

Deploys config/<env>/<flow>/<AppName>/<AppInstance>/ as the Helm release <AppName>-<AppInstance> of the
chart deephaven-connectors/<AppName>/helm/<AppName>/ in the namespace <flow> (D11 §6.2, DL-33, DL-38).

Flag list (identical in every mode):
  -f <app-common>/values.yaml -f <instance>/values.yaml --set-string image.tag=<tag>
  --set-file appConfig.common=<app-common>/application.yml --set-file appConfig.instance=<instance>/application.yml
  --set-file appConfig.platform=config/_common/<AppName>/application.yml     (when the file exists)
  --set-file appConfig.env=config/<env>/_common/application.yml             (when the file exists)
  --set-file appFiles.<layer>.<file>=<path>   for every other file of those four layer directories
                                              (logback.xml, *.properties; "." escaped as "\.")

Modes:
  lint      helm lint <chart> <flags>
  template  helm template <release> <chart> -n <ns> <flags>, to stdout or --render-out <file>
  deploy    (default) namespace with the restricted Pod Security labels, Secret <release>-secrets,
            helm lint, helm upgrade --install --create-namespace --rollback-on-failure --wait --timeout,
            kubectl rollout status, helm test --logs; prints "deployed <flow>/<AppName>/<AppInstance>=<tag>"
            as the last line on stdout (all tool output goes to stderr)

Options:
  --tag <tag>             the image tag (required; wins over image.tag of the instance values)
  --namespace <ns>        default <flow>
  --chart <dir>           default deephaven-connectors/<AppName>/helm/<AppName>
  --kubeconfig <file>     deploy: for helm and kubectl (default: $KUBECONFIG, then ~/.kube/config)
  --timeout <duration>    deploy: helm and kubectl timeouts, Go duration syntax (default 5m)
  --secret-user <u>       deploy, with --secret-password: create or update Secret <release>-secrets with the
  --secret-password <p>   keys spring.datasource.username / spring.datasource.password (D2 §6.4); without them
                          the Secret must already exist (or come from the chart's ExternalSecret)
  --render-out <file>     template mode: write the manifests to <file>
  --dry-run               print the commands (the Secret's values masked) and run nothing
  -h, --help              this text

Failures: a release with a deployed revision is upgraded with --rollback-on-failure, and a failure after the
upgrade (rollout status, helm test) rolls it back as well, so the previous revision keeps running. A first
install has nothing to restore: it runs without --rollback-on-failure and a failed one stays in place for the
diagnostics (helm uninstall removes it). Only local and *-dev envs are deployed; lint and template accept every
env (config-lint renders qa / prod).

Exit codes: 0 ok · 1 helm / kubectl failure · 2 usage · 3 refused (deploy to an env other than local / *-dev) ·
            4 config tree (chart, values.yaml or application.yml missing) · 5 tool missing or not Helm 4
Environment: CONFIG_ROOT (default <repo>/config), HELM_BIN (default helm), KUBECTL_BIN (default kubectl),
             SPRING_DATASOURCE_USERNAME / SPRING_DATASOURCE_PASSWORD (Secret values when the flags are absent)
EOF
}

# --- output helpers ---------------------------------------------------------------------------------------

info() { printf 'helm-deploy-instance: %s\n' "$*" >&2; }
warn() { printf 'helm-deploy-instance: warning: %s\n' "$*" >&2; }
die() {
    local code="$1"
    shift
    printf 'helm-deploy-instance: error: %s\n' "$*" >&2
    exit "$code"
}
contains_word() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
is_token() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; }
# One command as a copy-pasteable line.
quote_cmd() {
    local out="" arg
    for arg in "$@"; do out="$out $(printf '%q' "$arg")"; done
    printf '%s' "${out# }"
}
abs_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }

# --- arguments --------------------------------------------------------------------------------------------

TAG="" NAMESPACE="" CHART_ARG="" KUBECONFIG_ARG="" TIMEOUT=5m MODE=deploy RENDER_OUT="" DRY_RUN=0
SECRET_USER="" SECRET_PASSWORD="" SECRET_USER_SET=0 SECRET_PASSWORD_SET=0
POSITIONAL=()

need_value() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$EXIT_USAGE" "option $1 needs a value (see --help)"; fi; }

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) need_value "$@"; TAG="$2"; shift ;;
        --tag=*) TAG="${1#*=}" ;;
        --namespace | -n) need_value "$@"; NAMESPACE="$2"; shift ;;
        --namespace=*) NAMESPACE="${1#*=}" ;;
        --chart) need_value "$@"; CHART_ARG="$2"; shift ;;
        --chart=*) CHART_ARG="${1#*=}" ;;
        --kubeconfig) need_value "$@"; KUBECONFIG_ARG="$2"; shift ;;
        --kubeconfig=*) KUBECONFIG_ARG="${1#*=}" ;;
        --timeout) need_value "$@"; TIMEOUT="$2"; shift ;;
        --timeout=*) TIMEOUT="${1#*=}" ;;
        --secret-user) need_value "$@"; SECRET_USER="$2"; SECRET_USER_SET=1; shift ;;
        --secret-user=*) SECRET_USER="${1#*=}"; SECRET_USER_SET=1 ;;
        --secret-password) need_value "$@"; SECRET_PASSWORD="$2"; SECRET_PASSWORD_SET=1; shift ;;
        --secret-password=*) SECRET_PASSWORD="${1#*=}"; SECRET_PASSWORD_SET=1 ;;
        --mode) need_value "$@"; MODE="$2"; shift ;;
        --mode=*) MODE="${1#*=}" ;;
        --render-out) need_value "$@"; RENDER_OUT="$2"; shift ;;
        --render-out=*) RENDER_OUT="${1#*=}" ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        --) shift; POSITIONAL+=("$@"); break ;;
        -*) die "$EXIT_USAGE" "unknown option $1 (see --help)" ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done

# --- validation: usage (2), safety (3) --------------------------------------------------------------------

if [ "${#POSITIONAL[@]}" -ne 4 ]; then
    usage >&2
    die "$EXIT_USAGE" "expected <env> <flow> <AppName> <AppInstance>, got ${#POSITIONAL[@]} argument(s)"
fi
ENV_NAME="${POSITIONAL[0]}" FLOW="${POSITIONAL[1]}" APP="${POSITIONAL[2]}" INSTANCE="${POSITIONAL[3]}"
case "$ENV_NAME" in
    local | [a-z][a-z]-dev | [a-z][a-z]-qa | [a-z][a-z]-prod) ;;
    *) die "$EXIT_USAGE" "env '$ENV_NAME' must be local or <region>-<stage> (e.g. us-dev)" ;;
esac
contains_word "$FLOW" "$FLOWS" || die "$EXIT_USAGE" "flow '$FLOW' must be one of: $FLOWS"
if ! is_token "$APP" || [ "${#APP}" -gt 20 ]; then
    die "$EXIT_USAGE" "AppName '$APP' must be lower-case kebab-case, at most 20 characters"
fi
if ! is_token "$INSTANCE" || [ "${#INSTANCE}" -gt 32 ] || [ "$INSTANCE" = app-common ]; then
    die "$EXIT_USAGE" "AppInstance '$INSTANCE' must be lower-case kebab-case, at most 32 characters (not app-common)"
fi
case "$INSTANCE" in *[!0-9]*) ;; *) die "$EXIT_USAGE" "AppInstance '$INSTANCE' is a business name, never a bare number" ;; esac
RELEASE="$APP-$INSTANCE"
[ "${#RELEASE}" -le 53 ] || die "$EXIT_USAGE" "release '$RELEASE' exceeds Helm's 53-character limit (D5 §6.2)"
contains_word "$MODE" "$MODES" || die "$EXIT_USAGE" "--mode must be one of: $MODES"
[ -n "$TAG" ] || die "$EXIT_USAGE" "--tag <tag> is required (the image tag to deploy)"
printf '%s' "$TAG" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}(@sha256:[0-9a-f]{64})?$' ||
    die "$EXIT_USAGE" "--tag '$TAG' is not a valid image tag"
NS="${NAMESPACE:-$FLOW}"
if ! printf '%s' "$NS" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' || [ "${#NS}" -gt 63 ]; then
    die "$EXIT_USAGE" "namespace '$NS' is not a valid Kubernetes namespace name"
fi
printf '%s' "$TIMEOUT" | grep -Eq '^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$' ||
    die "$EXIT_USAGE" "--timeout '$TIMEOUT' is not a duration such as 5m, 300s or 1m30s"
if [ -n "$RENDER_OUT" ] && [ "$MODE" != template ]; then die "$EXIT_USAGE" "--render-out only applies to --mode template"; fi
# --kubeconfig and the Secret's values only matter to deploy; lint and template ignore them (callers may pass them
# to every mode). The Secret's values: both flags, else both SPRING_DATASOURCE_* variables (the compose
# pass-through names, D2 §8.1).
if [ "$MODE" = deploy ]; then
    if [ "$SECRET_USER_SET" -eq 0 ] && [ "$SECRET_PASSWORD_SET" -eq 0 ]; then
        SECRET_USER="${SPRING_DATASOURCE_USERNAME:-}" SECRET_PASSWORD="${SPRING_DATASOURCE_PASSWORD:-}"
    fi
    if { [ -n "$SECRET_USER" ] && [ -z "$SECRET_PASSWORD" ]; } || { [ -z "$SECRET_USER" ] && [ -n "$SECRET_PASSWORD" ]; }; then
        die "$EXIT_USAGE" "give both --secret-user and --secret-password (or neither: the Secret must exist)"
    fi
else
    SECRET_USER="" SECRET_PASSWORD="" KUBECONFIG_ARG=""
fi
# Env allow-list (D6 §6.5, D9 §6.4): qa and prod are never deployed from here; rendering them is fine.
if [ "$MODE" = deploy ]; then
    case "$ENV_NAME" in
        local | *-dev) ;;
        *) die "$EXIT_REFUSED" "env '$ENV_NAME' refused: qa and prod are deployed by their controller from reviewed config (D9, D11), never by this script" ;;
    esac
fi

# --- paths (4) --------------------------------------------------------------------------------------------

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd -P))"
CONFIG_ROOT_ABS="$(abs_path "${CONFIG_ROOT:-$REPO_ROOT/config}")"
CHART_ABS="$(abs_path "${CHART_ARG:-$REPO_ROOT/deephaven-connectors/$APP/helm/$APP}")"
[ -z "$KUBECONFIG_ARG" ] || KUBECONFIG_ARG="$(abs_path "$KUBECONFIG_ARG")"
[ -z "$RENDER_OUT" ] || RENDER_OUT="$(abs_path "$RENDER_OUT")"
cd "$REPO_ROOT"
# Paths below the repository are used relative to it (readable, copy-pasteable commands from the root).
rel() { case "$1" in "$REPO_ROOT"/*) printf '%s' "${1#"$REPO_ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }
CHART="$(rel "$CHART_ABS")"
CONFIG_ROOT_REL="$(rel "$CONFIG_ROOT_ABS")"
PLATFORM_DIR="$CONFIG_ROOT_REL/_common/$APP"
ENV_COMMON_DIR="$CONFIG_ROOT_REL/$ENV_NAME/_common"
COMMON="$CONFIG_ROOT_REL/$ENV_NAME/$FLOW/$APP/app-common"
INST="$CONFIG_ROOT_REL/$ENV_NAME/$FLOW/$APP/$INSTANCE"

# --values and --set-file split their arguments on ",": every path below derives from these two and from
# validated names, so only they are checked.
case "$CONFIG_ROOT_REL$CHART" in *,*) die "$EXIT_CONFIG" "a comma in CONFIG_ROOT or --chart breaks helm's --values / --set-file" ;; esac
[ -f "$CHART/Chart.yaml" ] || die "$EXIT_CONFIG" "chart not found: $CHART/Chart.yaml"
for dir in "$COMMON" "$INST"; do
    [ -d "$dir" ] || die "$EXIT_CONFIG" "config tree: directory missing: $dir"
done
for file in "$COMMON/values.yaml" "$INST/values.yaml" "$COMMON/application.yml" "$INST/application.yml"; do
    [ -f "$file" ] || die "$EXIT_CONFIG" "config tree: required file missing: $file"
done

# --- the flag list (D11 §8.3) -----------------------------------------------------------------------------

FLAGS=(-f "$COMMON/values.yaml" -f "$INST/values.yaml" --set-string "image.tag=$TAG"
    --set-file "appConfig.common=$COMMON/application.yml" --set-file "appConfig.instance=$INST/application.yml")
LAYERS_PRESENT="common instance"
if [ -f "$PLATFORM_DIR/application.yml" ]; then
    FLAGS+=(--set-file "appConfig.platform=$PLATFORM_DIR/application.yml")
    LAYERS_PRESENT="platform $LAYERS_PRESENT"
fi
if [ -f "$ENV_COMMON_DIR/application.yml" ]; then
    FLAGS+=(--set-file "appConfig.env=$ENV_COMMON_DIR/application.yml")
    LAYERS_PRESENT="${LAYERS_PRESENT%common instance}env common instance"
fi
# Every other file of a layer directory ships to /config/<layer>/<file> (D5 §6.4). --set-file splits its key
# on ".": the file name is escaped ("\."), and restricted to what a ConfigMap key allows.
add_layer_files() {
    local layer="$1" dir="$2" path name
    [ -d "$dir" ] || return 0
    for path in "$dir"/*; do
        [ -f "$path" ] || continue
        name="$(basename "$path")"
        contains_word "$name" "$NOT_SHIPPED" && continue
        printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' ||
            die "$EXIT_CONFIG" "config tree: $path: file names must match [A-Za-z0-9][A-Za-z0-9._-]* to become ConfigMap keys"
        FLAGS+=(--set-file "appFiles.$layer.${name//./\\.}=$path")
    done
}
add_layer_files platform "$PLATFORM_DIR"
add_layer_files env "$ENV_COMMON_DIR"
add_layer_files common "$COMMON"
add_layer_files instance "$INST"

# --- tools (5) --------------------------------------------------------------------------------------------

HELM="${HELM_BIN:-helm}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
HELM_KUBE=()
KUBECTL_KUBE=()
if [ -n "$KUBECONFIG_ARG" ]; then
    [ "$DRY_RUN" -eq 1 ] || [ -f "$KUBECONFIG_ARG" ] || die "$EXIT_USAGE" "--kubeconfig $KUBECONFIG_ARG: file not found"
    HELM_KUBE=(--kubeconfig "$KUBECONFIG_ARG")
    KUBECTL_KUBE=(--kubeconfig "$KUBECONFIG_ARG")
fi
check_tools() {
    local version
    command -v "$HELM" >/dev/null 2>&1 ||
        die "$EXIT_TOOL" "helm not found ($HELM): install Helm 4 (pinned in test-infra/kind/versions.env)"
    version="$("$HELM" version --template '{{.Version}}' 2>/dev/null)" ||
        die "$EXIT_TOOL" "'$HELM version' failed: is it Helm?"
    case "$version" in
        v4.*) ;;
        *) die "$EXIT_TOOL" "Helm $version found: this script needs Helm 4 (--rollback-on-failure, watcher waits, hook output logs)" ;;
    esac
    if [ "$MODE" = deploy ]; then
        command -v "$KUBECTL" >/dev/null 2>&1 || die "$EXIT_TOOL" "kubectl not found ($KUBECTL)"
    fi
}
[ "$DRY_RUN" -eq 1 ] || check_tools

# --- execution helpers ------------------------------------------------------------------------------------

show_plan() {
    [ "$DRY_RUN" -eq 1 ] || return 0
    printf 'helm-deploy-instance.sh --dry-run: %s %s %s %s --tag %s (mode %s; nothing is executed)\n' \
        "$ENV_NAME" "$FLOW" "$APP" "$INSTANCE" "$TAG" "$MODE"
    printf '  %-10s %s\n' "release" "$RELEASE" "namespace" "$NS" "chart" "$CHART" \
        "values" "$COMMON/values.yaml $INST/values.yaml" "layers" "$LAYERS_PRESENT"
}
# Runs (or, with --dry-run, prints) one command; tool output goes to stderr in deploy mode.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ %s\n' "$(quote_cmd "$@")"
        return 0
    fi
    info "$(quote_cmd "$@")"
    if [ "$MODE" = deploy ]; then "$@" >&2; else "$@"; fi
}
LABELS=("app.kubernetes.io/name=$APP" "app.kubernetes.io/instance=$RELEASE" "app.kubernetes.io/managed-by=$FIELD_MANAGER"
    "platform.example.com/env=$ENV_NAME" "platform.example.com/flow=$FLOW" "platform.example.com/app=$APP"
    "platform.example.com/instance=$INSTANCE")
PSS_LABELS=(pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
    pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted)

# The namespace with the restricted Pod Security Standard labels (D6 §6.11), created when missing.
ensure_namespace() {
    local kc=("$KUBECTL" ${KUBECTL_KUBE[@]+"${KUBECTL_KUBE[@]}"})
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ %s || %s\n' "$(quote_cmd "${kc[@]}" get namespace "$NS")" "$(quote_cmd "${kc[@]}" create namespace "$NS")"
    elif ! "${kc[@]}" get namespace "$NS" >/dev/null 2>&1; then
        # Another deploy may create it at the same moment: the second get settles the race.
        run "${kc[@]}" create namespace "$NS" || "${kc[@]}" get namespace "$NS" >/dev/null
    fi
    run "${kc[@]}" label --overwrite namespace "$NS" "${PSS_LABELS[@]}"
}

# Secret <release>-secrets, keys = Spring property names (D2 §6.4, §8.1); the chart only mounts it (D11 R4).
ensure_secret() {
    local kc=("$KUBECTL" ${KUBECTL_KUBE[@]+"${KUBECTL_KUBE[@]}"}) name="$RELEASE-secrets"
    if [ -z "$SECRET_USER" ]; then
        info "no --secret-user / --secret-password: Secret $NS/$name must exist already (or come from the chart's ExternalSecret)"
        return 0
    fi
    # Both values are masked in the printed command, like every other D2 secret property (D6 §4.3).
    local create=("${kc[@]}" -n "$NS" create secret generic "$name")
    local masked=("${create[@]}" "--from-literal=spring.datasource.username=***"
        "--from-literal=spring.datasource.password=***" --dry-run=client -o yaml)
    create+=("--from-literal=spring.datasource.username=$SECRET_USER"
        "--from-literal=spring.datasource.password=$SECRET_PASSWORD" --dry-run=client -o yaml)
    local label=("${kc[@]}" label --local -f - -o yaml --overwrite "${LABELS[@]}")
    local apply=("${kc[@]}" apply --server-side "--field-manager=$FIELD_MANAGER" -f -)
    local shown
    shown="$(quote_cmd "${masked[@]}") | $(quote_cmd "${label[@]}") | $(quote_cmd "${apply[@]}")"
    shown="${shown//'\*\*\*'/***}"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ %s\n' "$shown"
        return 0
    fi
    info "$shown"
    "${create[@]}" | "${label[@]}" | "${apply[@]}" >&2
}

diagnose() {
    local kc=("$KUBECTL" ${KUBECTL_KUBE[@]+"${KUBECTL_KUBE[@]}"} -n "$NS") selector="app.kubernetes.io/instance=$RELEASE"
    warn "diagnostics for release $RELEASE in namespace $NS:"
    "$HELM" status "$RELEASE" -n "$NS" ${HELM_KUBE[@]+"${HELM_KUBE[@]}"} >&2 2>&1 || true
    "${kc[@]}" get deployments,replicasets,pods,jobs -l "$selector" -o wide >&2 2>&1 || true
    "${kc[@]}" describe pods -l "$selector" >&2 2>&1 || true
    "${kc[@]}" logs -l "$selector" --all-containers --prefix --tail=100 >&2 2>&1 || true
    "${kc[@]}" get events --sort-by=.lastTimestamp 2>&1 | tail -n 30 >&2 || true
}

# --- modes ------------------------------------------------------------------------------------------------

cmd_lint() {
    run "$HELM" lint "$CHART" "${FLAGS[@]}"
}

cmd_template() {
    local cmd=("$HELM" template "$RELEASE" "$CHART" -n "$NS" "${FLAGS[@]}")
    if [ -z "$RENDER_OUT" ]; then
        run "${cmd[@]}"
    elif [ "$DRY_RUN" -eq 1 ]; then
        printf '+ %s > %s\n' "$(quote_cmd "${cmd[@]}")" "$(printf '%q' "$(rel "$RENDER_OUT")")"
    else
        mkdir -p "$(dirname "$RENDER_OUT")"
        info "$(quote_cmd "${cmd[@]}") > $(rel "$RENDER_OUT")"
        "${cmd[@]}" >"$RENDER_OUT"
    fi
}

cmd_deploy() {
    local hk=(${HELM_KUBE[@]+"${HELM_KUBE[@]}"}) had_release=0 rollback=(--rollback-on-failure)
    ensure_namespace || die "$EXIT_FAILED" "could not prepare namespace $NS"
    ensure_secret || die "$EXIT_FAILED" "could not create or update Secret $NS/$RELEASE-secrets"
    run "$HELM" lint "$CHART" "${FLAGS[@]}" || die "$EXIT_FAILED" "helm lint failed"
    # A release with a deployed revision is upgraded atomically: on failure Helm restores that revision.
    # A first install has nothing to restore: it runs without --rollback-on-failure so that its failed pods
    # stay for the diagnostics (Helm 4 upgrades over a failed-only history next time).
    if [ "$DRY_RUN" -eq 0 ]; then
        local history
        history="$("$HELM" history "$RELEASE" -n "$NS" ${hk[@]+"${hk[@]}"} --max 256 -o json 2>/dev/null || true)"
        case "$history" in
            *'"status":"deployed"'* | *'"status":"superseded"'*) had_release=1 ;;
            *)
                rollback=()
                info "first install of $RELEASE in $NS (no deployed revision): a failure leaves it in place for diagnostics"
                ;;
        esac
    fi
    if ! run "$HELM" upgrade --install "$RELEASE" "$CHART" -n "$NS" --create-namespace "${FLAGS[@]}" \
        ${rollback[@]+"${rollback[@]}"} --wait --timeout "$TIMEOUT" ${hk[@]+"${hk[@]}"}; then
        diagnose
        if [ "$had_release" -eq 1 ]; then
            die "$EXIT_FAILED" "helm upgrade failed: the previous revision of $RELEASE was restored"
        fi
        die "$EXIT_FAILED" "helm upgrade --install failed (first install kept for diagnostics: helm uninstall $RELEASE -n $NS removes it)"
    fi
    local failed=""
    run "$KUBECTL" ${KUBECTL_KUBE[@]+"${KUBECTL_KUBE[@]}"} -n "$NS" rollout status "deployment/$RELEASE" "--timeout=$TIMEOUT" ||
        failed="rollout status"
    if [ -z "$failed" ]; then
        run "$HELM" test "$RELEASE" -n "$NS" --logs --timeout "$TIMEOUT" ${hk[@]+"${hk[@]}"} || failed="helm test"
    fi
    if [ -n "$failed" ]; then
        diagnose
        if [ "$had_release" -eq 1 ]; then
            warn "$failed failed: rolling $RELEASE back to its previous revision"
            "$HELM" rollback "$RELEASE" -n "$NS" --wait --timeout "$TIMEOUT" ${hk[@]+"${hk[@]}"} >&2 ||
                warn "helm rollback failed: see helm history $RELEASE -n $NS"
        fi
        die "$EXIT_FAILED" "$failed failed for $RELEASE in $NS"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry run: nothing was deployed"
    else
        printf 'deployed %s/%s/%s=%s\n' "$FLOW" "$APP" "$INSTANCE" "$TAG"
    fi
}

show_plan
case "$MODE" in
    lint) cmd_lint || die "$EXIT_FAILED" "helm lint failed for $ENV_NAME/$FLOW/$APP/$INSTANCE" ;;
    template) cmd_template || die "$EXIT_FAILED" "helm template failed for $ENV_NAME/$FLOW/$APP/$INSTANCE" ;;
    deploy) cmd_deploy ;;
esac
