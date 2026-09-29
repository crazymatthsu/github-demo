#!/usr/bin/env bash
# helm-deploy-instance-test.sh — plain-bash test of helm-deploy-instance.sh on a throwaway config tree: the flag
# list it hands to helm-release.sh (values layers in order, tag from --tag or the tree, appConfig / appFiles layers
# when the chart has appConfig, namespace, kube context), the env guard (dev deploys, qa / prod only with
# DEPLOY_ALLOW_ENV, lint and template everywhere), refusals and exit codes. helm-release.sh is replaced by a stub
# that records its arguments; when the real one is found (next to the script, or in the sibling skill
# gha-ephemeral-test-envs), one more case runs it with --dry-run. No cluster, no network.
# Part of the gha-config-deploy skill.
#
# Usage: helm-deploy-instance-test.sh [--help] [<path to helm-deploy-instance.sh>]
#   Default: helm-deploy-instance.sh next to this file, else ../ci/helm-deploy-instance.sh (scripts in
#   scripts/ci/, their tests in scripts/test/, where the lint job runs scripts/test/*-test.sh).
#   Needs mikefarah yq v4 (as `yq`, or YQ=<path>).
# Exit codes: 0 every case passed · 1 a case failed · 2 usage · 5 a tool is missing
set -euo pipefail

case "${1:-}" in
  -h | --help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 0
    ;;
esac
[ $# -le 1 ] || { echo "usage: $0 [<path to helm-deploy-instance.sh>]" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
if [ $# -eq 1 ]; then
  SUT=$1
elif [ -f "$HERE/helm-deploy-instance.sh" ]; then
  SUT=$HERE/helm-deploy-instance.sh
else
  SUT=$HERE/../ci/helm-deploy-instance.sh
fi
[ -f "$SUT" ] || { echo "helm-deploy-instance-test: $SUT not found (pass its path)" >&2; exit 2; }
SUT=$(cd "$(dirname "$SUT")" && pwd)/$(basename "$SUT")
yq_bin=${YQ:-yq}
"$yq_bin" --version 2>/dev/null | grep -q mikefarah || { echo "helm-deploy-instance-test: mikefarah yq v4 is needed (YQ)" >&2; exit 5; }
unset DEPLOY_ALLOW_ENV HELM_DEPLOY_ENV_PATTERN HELM_APP_CONFIG HELM_CONFIG_DIR HELM_TIMEOUT HELM_PSS || true

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
T=$WORK/tree # not a git repository: paths are relative to it
ARGS_LOG=$WORK/helm-release.args

# The stub records its arguments (one line, space-separated) and answers like helm-release.sh.
cat >"$WORK/helm-release-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s ' "$@" >"$STUB_ARGS"
mode=deploy dry=0
while [ $# -gt 0 ]; do
  case $1 in --mode) mode=$2; shift ;; --dry-run) dry=1 ;; esac
  shift
done
if [ "$mode" = deploy ] && [ "$dry" -eq 0 ]; then echo "deployed stub"; fi
exit "${STUB_RC:-0}"
STUB
export STUB_ARGS=$ARGS_LOG HELM_RELEASE_SH=$WORK/helm-release-stub.sh HELM_CHART_DIR='deploy/helm/{app}' YQ=$yq_bin

mkfile() { mkdir -p "$(dirname "$T/$1")"; printf '%b' "$2" >"$T/$1"; }
mkfile deploy/helm/api/Chart.yaml 'apiVersion: v2\nname: api\nversion: 0.1.0\n'
mkfile deploy/helm/api/values.yaml 'image:\n  repository: ghcr.io/acme/api\n  tag: ""\nappConfig: {}\nappFiles: {}\n'
mkfile deploy/helm/worker/Chart.yaml 'apiVersion: v2\nname: worker\nversion: 0.1.0\n'
mkfile deploy/helm/worker/values.yaml 'image:\n  repository: ghcr.io/acme/worker\n  tag: ""\n'
mkfile config/_common/api/application.yml 'poll: 5s\n'
mkfile config/dev/_common/application.yml 'log: json\n'
mkfile config/dev/payments/api/app-common/values.yaml 'resources: {}\n'
mkfile config/dev/payments/api/app-common/application.yml 'endpoint: x\n'
mkfile config/dev/payments/api/app-common/logback.xml '<configuration/>\n'
mkfile config/dev/payments/api/ledger/values.yaml 'image:\n  tag: "1.2.0-rc.3"\n'
mkfile config/dev/payments/api/ledger/application.yml 'table: ledger\n'
mkfile config/dev/payments/api/ledger/compose.env 'IMAGE_TAG=1.2.0-rc.3\n'
mkfile config/dev/payments/worker/main/values.yaml 'image:\n  tag: ""\n'
mkfile config/prod/payments/api/ledger/values.yaml 'image:\n  tag: "1.1.0"\n  digest: sha256:abc\n'

FAILED=0 PASSED=0
pass() { PASSED=$((PASSED + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
OUT='' ERR='' RC=0 ARGS=''
run() {
  RC=0
  rm -f "$ARGS_LOG"
  (cd "$T" && "$@") >"$WORK/out" 2>"$WORK/err" || RC=$?
  OUT=$(cat "$WORK/out") ERR=$(cat "$WORK/err")
  ARGS=$(cat "$ARGS_LOG" 2>/dev/null || true)
}
expect_rc() { if [ "$RC" -eq "$2" ]; then return 0; fi; fail "$1" "exit $RC, expected $2 (stderr: $ERR)"; return 1; }
has() { # <case> <text>: the recorded arguments contain <text>
  case " $ARGS" in *" $2"*) return 0 ;; esac
  fail "$1" "missing '$2' in: $ARGS"
  return 1
}
lacks() {
  case " $ARGS" in *" $2"*) fail "$1" "unexpected '$2' in: $ARGS"; return 1 ;; esac
  return 0
}

# --- cases --------------------------------------------------------------------------------------------------

run bash "$SUT" dev payments api ledger --tag 1.2.0-rc.4 --kube-context dev-eu
if expect_rc dev-deploy 0 &&
  has dev-deploy "api-ledger --chart deploy/helm/api --namespace payments --tag 1.2.0-rc.4 --mode deploy -f config/dev/payments/api/app-common/values.yaml -f config/dev/payments/api/ledger/values.yaml " &&
  has dev-deploy "--set-file appConfig.platform=config/_common/api/application.yml --set-file appConfig.env=config/dev/_common/application.yml" &&
  has dev-deploy "--set-file appConfig.common=config/dev/payments/api/app-common/application.yml" &&
  has dev-deploy "--set-file appFiles.common.logback\\.xml=config/dev/payments/api/app-common/logback.xml" &&
  has dev-deploy "--set-file appConfig.instance=config/dev/payments/api/ledger/application.yml" &&
  has dev-deploy "--timeout 5m --pss restricted --kube-context dev-eu " &&
  lacks dev-deploy "compose.env" && lacks dev-deploy "values.yaml=" ; then
  if [ "$(printf '%s\n' "$OUT" | tail -n 1)" = "deployed payments/api/ledger=1.2.0-rc.4" ]; then pass dev-deploy
  else fail dev-deploy "last stdout line: $OUT"; fi
fi

run bash "$SUT" dev payments api ledger --namespace apps
expect_rc tag-from-tree 0 && has tag-from-tree "--namespace apps --tag 1.2.0-rc.3 " && pass tag-from-tree

run env HELM_APP_CONFIG=false bash "$SUT" dev payments api ledger
expect_rc app-config-off 0 && lacks app-config-off "--set-file" && pass app-config-off

run bash "$SUT" dev payments worker main --mode template --render-out build/worker.yaml
expect_rc template-no-app-config 0 && lacks template-no-app-config "--set-file" &&
  has template-no-app-config "--tag 0.0.0-undeployed --mode template" &&
  has template-no-app-config "--render-out build/worker.yaml" && lacks template-no-app-config "--timeout" &&
  pass template-no-app-config

run bash "$SUT" dev payments worker main
expect_rc deploy-without-tag 4 && pass deploy-without-tag

run bash "$SUT" prod payments api ledger
expect_rc prod-refused 3 && [ -z "$ARGS" ] && pass prod-refused

run env DEPLOY_ALLOW_ENV=prod bash "$SUT" prod payments api ledger
expect_rc prod-allowed 0 && has prod-allowed "--tag 1.1.0 --mode deploy" && pass prod-allowed

run env DEPLOY_ALLOW_ENV=qa bash "$SUT" prod payments api ledger
expect_rc prod-other-allow 3 && pass prod-other-allow

run bash "$SUT" prod payments api ledger --mode lint
expect_rc prod-lint 0 && has prod-lint "--mode lint" && pass prod-lint

run env STUB_RC=1 bash "$SUT" dev payments api ledger
if expect_rc deploy-failure 1; then
  case $OUT in *deployed*) fail deploy-failure "a failed deploy printed a result line" ;; *) pass deploy-failure ;; esac
fi

run bash "$SUT" dev payments api ledger --dry-run
if expect_rc dry-run 0 && has dry-run "--dry-run"; then
  case $OUT in *deployed*) fail dry-run "a dry run printed a result line" ;; *) pass dry-run ;; esac
fi

run bash "$SUT" dev payments api
expect_rc usage-positionals 2 && pass usage-positionals
run bash "$SUT" dev payments api app-common
expect_rc usage-layer 2 && pass usage-layer
run bash "$SUT" dev Payments api ledger
expect_rc usage-token 2 && pass usage-token
run bash "$SUT" dev payments api ledger --mode apply
expect_rc usage-mode 2 && pass usage-mode
run bash "$SUT" dev payments api ledger --render-out x.yaml
expect_rc usage-render-out 2 && pass usage-render-out
run bash "$SUT" dev payments nochart ledger
expect_rc missing-chart 4 && pass missing-chart
run bash "$SUT" dev payments api nosuch
expect_rc missing-instance 4 && pass missing-instance
run env HELM_CHART_DIR='__HELM_''CHART_DIR__' bash "$SUT" dev payments api ledger
expect_rc placeholder-chart-dir 2 && pass placeholder-chart-dir
run env HELM_RELEASE_SH="$WORK/nosuch.sh" bash "$SUT" dev payments api ledger
expect_rc missing-helm-release 5 && pass missing-helm-release

# With the real helm-release.sh (no helm needed with --dry-run): the upgrade it would run.
real=''
for candidate in "$(dirname "$SUT")/helm-release.sh" "$HERE/../../../gha-ephemeral-test-envs/assets/scripts/helm-release.sh"; do
  if [ -f "$candidate" ]; then real=$candidate; break; fi
done
if [ -n "$real" ]; then
  run env HELM_RELEASE_SH="$real" bash "$SUT" dev payments api ledger --tag 1.2.0-rc.4 --kube-context dev-eu --dry-run
  if expect_rc real-helm-release 0; then
    case $ERR in
      *"+ helm upgrade --install api-ledger deploy/helm/api -n payments --create-namespace -f config/dev/payments/api/app-common/values.yaml -f config/dev/payments/api/ledger/values.yaml --set-string image.tag=1.2.0-rc.4"*"--kube-context dev-eu"*)
        pass real-helm-release ;;
      *) fail real-helm-release "no matching upgrade in: $ERR" ;;
    esac
  fi
else
  echo "skip real-helm-release (helm-release.sh not found next to the script)"
fi

echo "helm-deploy-instance-test: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
