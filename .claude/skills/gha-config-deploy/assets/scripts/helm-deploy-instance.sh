#!/usr/bin/env bash
# helm-deploy-instance.sh — lint, render or deploy ONE instance of the config tree as its Helm release. The Helm
# deployer of _deploy-dev.yml and _deploy-env.yml, and the renderer that config lint and the kind test can share:
# the flag list is built here once and handed to helm-release.sh (skill gha-ephemeral-test-envs), so what a pull
# request lints is exactly what the deploy installs. Part of the gha-config-deploy skill; copy it to
# scripts/ci/helm-deploy-instance.sh, next to scripts/ci/helm-release.sh.
#
# Usage: helm-deploy-instance.sh <env> <flow> <app> <instance> [options]
#
#   release     <app>-<instance>, in namespace <flow> (--namespace overrides)
#   chart       HELM_CHART_DIR with every {app} replaced by <app>
#   values      -f <config>/<env>/<flow>/<app>/app-common/values.yaml   (when present)
#               -f <config>/<env>/<flow>/<app>/<instance>/values.yaml
#   tag         --tag, else image.tag of the instance values.yaml (what a bump pull request pins for qa and prod)
#   app config  when HELM_APP_CONFIG is true (auto: the chart's values.yaml has a top-level appConfig key), every
#               application.yml layer that exists (config-tree.md section 7), lowest first:
#                 --set-file appConfig.platform=<config>/_common/<app>/application.yml
#                 --set-file appConfig.env=<config>/<env>/_common/application.yml
#                 --set-file appConfig.common=<config>/<env>/<flow>/<app>/app-common/application.yml
#                 --set-file appConfig.instance=<config>/<env>/<flow>/<app>/<instance>/application.yml
#               and every other file of those four directories as --set-file appFiles.<layer>.<file>=<path>
#               (dots escaped, e.g. appFiles.instance.logback\.xml; values.yaml, compose.env, README.md skipped)
#
# Options
#   --tag <tag>             the image tag to deploy (dev: the version main.yml just published)
#   --namespace <ns>        default <flow>
#   --kube-context <name>   the context of $KUBECONFIG to deploy with (the inventory's `cluster`); default: its
#                           current context
#   --mode <mode>           deploy (default) | template | lint
#   --render-out <file>     template: write the manifests to <file>
#   --dry-run               print the commands, run nothing
#   -h, --help              this text
#
# Deploying is limited to local and dev envs (HELM_DEPLOY_ENV_PATTERN) unless DEPLOY_ALLOW_ENV equals <env>: only
# the promotion job (_deploy-env.yml) sets it, inside the GitHub Environment of that env, after its reviewers
# approved. Lint and template accept every env (config lint renders qa and prod too). An instance that records
# no tag yet renders with the tag 0.0.0-undeployed and cannot be deployed without --tag.
# Deploy prints "deployed <flow>/<app>/<instance>=<tag>" as its last stdout line; tool output goes to stderr.
# Paths are relative to the repository root (the current directory outside a git repository).
#
# Environment [default]:
#   HELM_CHART_DIR [__HELM_CHART_DIR__]        chart directory, {app} = <app>, e.g. deploy/helm/{app}
#   HELM_CONFIG_DIR [config]                   the config tree
#   HELM_APP_CONFIG [auto]                     true | false | auto (see "app config")
#   HELM_DEPLOY_ENV_PATTERN [^(local|([a-z][a-z0-9]*-)?dev)$]   envs deploy mode accepts (bash ERE)
#   DEPLOY_ALLOW_ENV []                        one more env deploy mode accepts (the promotion job's own env)
#   HELM_RELEASE_SH [helm-release.sh next to this file]
#   HELM_TIMEOUT [5m] · HELM_PSS [restricted]  passed to helm-release.sh as --timeout / --pss (deploy)
#   YQ [yq]                                    mikefarah yq v4
#   KUBECONFIG, HELM_BIN, KUBECTL_BIN          read by helm-release.sh
# Exit codes: 0 ok · 1 helm / kubectl failure · 2 usage · 3 refused (deploy to an env that is not allowed) ·
#   4 config tree error (chart, instance or tag missing) · 5 a tool is missing
set -euo pipefail

readonly EXIT_USAGE=2 EXIT_REFUSED=3 EXIT_CONFIG=4 EXIT_TOOL=5
readonly TOKEN_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
info() { printf 'helm-deploy-instance: %s\n' "$*" >&2; }
die() {
  local code=$1
  shift
  printf 'helm-deploy-instance: error: %s\n' "$*" >&2
  exit "$code"
}
need_value() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$EXIT_USAGE" "option $1 needs a value (see --help)"; fi; }

POSITIONAL=() TAG='' NS='' CONTEXT='' MODE=deploy RENDER_OUT='' DRY_RUN=0
while [ $# -gt 0 ]; do
  case $1 in
    --tag) need_value "$@"; TAG=$2; shift ;;
    --tag=*) TAG=${1#*=} ;;
    --namespace) need_value "$@"; NS=$2; shift ;;
    --namespace=*) NS=${1#*=} ;;
    --kube-context) need_value "$@"; CONTEXT=$2; shift ;;
    --kube-context=*) CONTEXT=${1#*=} ;;
    --mode) need_value "$@"; MODE=$2; shift ;;
    --mode=*) MODE=${1#*=} ;;
    --render-out) need_value "$@"; RENDER_OUT=$2; shift ;;
    --render-out=*) RENDER_OUT=${1#*=} ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "$EXIT_USAGE" "unknown option $1 (see --help)" ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done

[ "${#POSITIONAL[@]}" -eq 4 ] || die "$EXIT_USAGE" "expected <env> <flow> <app> <instance> (see --help)"
ENV_NAME=${POSITIONAL[0]} FLOW=${POSITIONAL[1]} APP=${POSITIONAL[2]} INSTANCE=${POSITIONAL[3]}
for token in "$ENV_NAME" "$FLOW" "$APP" "$INSTANCE"; do
  [[ $token =~ $TOKEN_RE ]] || die "$EXIT_USAGE" "'$token' is not a lower-case kebab token"
done
case $INSTANCE in app-common | _*) die "$EXIT_USAGE" "'$INSTANCE' is a layer, not an instance" ;; esac
case $MODE in deploy | template | lint) ;; *) die "$EXIT_USAGE" "--mode must be deploy, template or lint" ;; esac
if [ -n "$RENDER_OUT" ] && [ "$MODE" != template ]; then die "$EXIT_USAGE" "--render-out only applies to --mode template"; fi

ENV_PATTERN=${HELM_DEPLOY_ENV_PATTERN:-'^(local|([a-z][a-z0-9]*-)?dev)$'}
if [ "$MODE" = deploy ] && ! [[ $ENV_NAME =~ $ENV_PATTERN ]] && [ "${DEPLOY_ALLOW_ENV:-}" != "$ENV_NAME" ]; then
  die "$EXIT_REFUSED" "refused to deploy $ENV_NAME: only local and dev envs deploy from here; qa and prod deploy from the promotion job (_deploy-env.yml, which sets DEPLOY_ALLOW_ENV inside the env's GitHub Environment)"
fi

HELM_RELEASE=${HELM_RELEASE_SH:-$SCRIPT_DIR/helm-release.sh}
[ -f "$HELM_RELEASE" ] || die "$EXIT_TOOL" "helm-release.sh not found at $HELM_RELEASE (skill gha-ephemeral-test-envs; HELM_RELEASE_SH)"
YQ_BIN=${YQ:-yq}
"$YQ_BIN" --version 2>/dev/null | grep -q mikefarah || die "$EXIT_TOOL" "mikefarah yq v4 is needed as '$YQ_BIN' (YQ)"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
cd "$ROOT"

CHART_TEMPLATE=${HELM_CHART_DIR:-__HELM_CHART_DIR__}
case $CHART_TEMPLATE in *__[A-Z]*) die "$EXIT_USAGE" "set HELM_CHART_DIR (e.g. deploy/helm/{app}) or replace the placeholder in this script" ;; esac
CHART=${CHART_TEMPLATE//\{app\}/$APP}
[ -f "$CHART/Chart.yaml" ] || die "$EXIT_CONFIG" "no chart for app $APP: $CHART/Chart.yaml"
CFG=${HELM_CONFIG_DIR:-config}
DIR=$CFG/$ENV_NAME/$FLOW/$APP
[ -f "$DIR/$INSTANCE/values.yaml" ] || die "$EXIT_CONFIG" "no instance $ENV_NAME/$FLOW/$APP/$INSTANCE: $DIR/$INSTANCE/values.yaml is missing"

if [ -z "$TAG" ]; then
  TAG=$("$YQ_BIN" '.image.tag // ""' "$DIR/$INSTANCE/values.yaml") || die "$EXIT_CONFIG" "$DIR/$INSTANCE/values.yaml does not parse"
  if [ -z "$TAG" ]; then
    [ "$MODE" != deploy ] || die "$EXIT_CONFIG" "$ENV_NAME/$FLOW/$APP/$INSTANCE records no image.tag (never deployed) and no --tag was given"
    TAG=0.0.0-undeployed
  fi
fi

ARGS=("$APP-$INSTANCE" --chart "$CHART" --namespace "${NS:-$FLOW}" --tag "$TAG" --mode "$MODE")
if [ -f "$DIR/app-common/values.yaml" ]; then ARGS+=(-f "$DIR/app-common/values.yaml"); fi
ARGS+=(-f "$DIR/$INSTANCE/values.yaml")

APP_CONFIG=${HELM_APP_CONFIG:-auto}
case $APP_CONFIG in
  auto)
    APP_CONFIG=false
    if [ -f "$CHART/values.yaml" ] && [ "$("$YQ_BIN" 'has("appConfig")' "$CHART/values.yaml" 2>/dev/null)" = true ]; then APP_CONFIG=true; fi
    ;;
  true | false) ;;
  *) die "$EXIT_USAGE" "HELM_APP_CONFIG must be true, false or auto" ;;
esac
add_layer() { # <layer> <dir>: the layer's application.yml as appConfig.<layer>, its other files as appFiles
  local layer=$1 dir=$2 file name
  [ -d "$dir" ] || return 0
  for file in "$dir"/*; do
    [ -f "$file" ] || continue
    name=${file##*/}
    case $name in
      application.yml) ARGS+=(--set-file "appConfig.$layer=$file") ;;
      values.yaml | values.yml | compose.env | README.md) ;;
      *) ARGS+=(--set-file "appFiles.$layer.$(printf '%s' "$name" | sed 's/\./\\./g')=$file") ;;
    esac
  done
}
if [ "$APP_CONFIG" = true ]; then
  add_layer platform "$CFG/_common/$APP"
  add_layer env "$CFG/$ENV_NAME/_common"
  add_layer common "$DIR/app-common"
  add_layer instance "$DIR/$INSTANCE"
fi

if [ "$MODE" = deploy ]; then ARGS+=(--timeout "${HELM_TIMEOUT:-5m}" --pss "${HELM_PSS:-restricted}"); fi
if [ -n "$CONTEXT" ]; then ARGS+=(--kube-context "$CONTEXT"); fi
if [ -n "$RENDER_OUT" ]; then ARGS+=(--render-out "$RENDER_OUT"); fi
if [ "$DRY_RUN" -eq 1 ]; then ARGS+=(--dry-run); fi

info "$MODE $ENV_NAME/$FLOW/$APP/$INSTANCE as release $APP-$INSTANCE in namespace ${NS:-$FLOW}, tag $TAG${CONTEXT:+, context $CONTEXT}"
if [ "$MODE" = deploy ]; then
  # helm-release.sh's own result line goes to stderr: stdout carries only this script's line.
  bash "$HELM_RELEASE" "${ARGS[@]}" >&2
  if [ "$DRY_RUN" -eq 0 ]; then printf 'deployed %s/%s/%s=%s\n' "$FLOW" "$APP" "$INSTANCE" "$TAG"; fi
else
  bash "$HELM_RELEASE" "${ARGS[@]}"
fi
