#!/usr/bin/env bash
# smoke-diff.sh: prove that two deployed releases of the same chart are really different instances. Runs one
# probe inside a pod of each release and passes when both answer and the answers differ. Nothing is
# port-forwarded. Portable to bash 3.2 (macOS); run with --help. (Template of the skill gha-ephemeral-test-envs.)
set -euo pipefail

readonly EXIT_DIFFER=0 EXIT_SAME=1 EXIT_USAGE=2

usage() {
  cat <<'EOF'
Usage: smoke-diff.sh -n <namespace> [--kubeconfig <file>] [--target deploy] [--jq <filter>] [--ignore <regex>]...
                     <release-a> <release-b> -- <probe command...>

Runs `kubectl -n <namespace> exec <target>/<release> -- <probe command...>` for both releases, prints both
answers as a unified diff and passes when both answered and the answers differ.

Pick a probe whose answer is deterministic per instance: its identity and its effective configuration (for
example `curl -fsS localhost:8080/info` of an app that reports both). Then the check proves that each release
got its own values, not only that two pods start.

Options
  -n, --namespace <ns>   namespace of both releases (required)
  --kubeconfig <file>    kubeconfig (default: $KUBECONFIG)
  --target <kind>        resource kind whose pod runs the probe (default deploy; statefulset, ...)
  --jq <filter>          apply this jq filter to each answer before comparing (needs jq), e.g.
                         '{identity: .instance, config: .config}' to drop volatile fields
  --ignore <regex>       drop answer lines matching this extended regex before comparing (repeatable)
  -h, --help             this text

Exit codes: 0 both answered and differ · 1 identical, empty or unreachable (or kubectl / jq missing) · 2 usage
Environment: KUBECTL_BIN (default kubectl)
EOF
}

die() {
  local code=$1
  shift
  printf 'smoke-diff: error: %s\n' "$*" >&2
  exit "$code"
}
is_name() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' && [ "${#1}" -le 253 ]; }

NS='' KUBECONFIG_ARG='' TARGET=deploy JQ_FILTER=''
IGNORES=() RELEASES=() PROBE=()
while [ $# -gt 0 ]; do
  case $1 in
    -n | --namespace) [ $# -ge 2 ] && [ -n "$2" ] || die "$EXIT_USAGE" "$1 needs a value"; NS=$2; shift ;;
    --namespace=*) NS=${1#*=} ;;
    --kubeconfig) [ $# -ge 2 ] && [ -n "$2" ] || die "$EXIT_USAGE" "$1 needs a value"; KUBECONFIG_ARG=$2; shift ;;
    --kubeconfig=*) KUBECONFIG_ARG=${1#*=} ;;
    --target) [ $# -ge 2 ] && [ -n "$2" ] || die "$EXIT_USAGE" "$1 needs a value"; TARGET=$2; shift ;;
    --target=*) TARGET=${1#*=} ;;
    --jq) [ $# -ge 2 ] && [ -n "$2" ] || die "$EXIT_USAGE" "$1 needs a value"; JQ_FILTER=$2; shift ;;
    --jq=*) JQ_FILTER=${1#*=} ;;
    --ignore) [ $# -ge 2 ] && [ -n "$2" ] || die "$EXIT_USAGE" "$1 needs a value"; IGNORES+=("$2"); shift ;;
    --ignore=*) IGNORES+=("${1#*=}") ;;
    -h | --help) usage; exit 0 ;;
    --) shift; PROBE=("$@"); break ;;
    -*) die "$EXIT_USAGE" "unknown option $1 (see --help)" ;;
    *) RELEASES+=("$1") ;;
  esac
  shift
done
[ -n "$NS" ] || { usage >&2; die "$EXIT_USAGE" "-n <namespace> is required"; }
[ "${#RELEASES[@]}" -eq 2 ] || { usage >&2; die "$EXIT_USAGE" "expected two releases, got ${#RELEASES[@]}"; }
[ "${#PROBE[@]}" -gt 0 ] || { usage >&2; die "$EXIT_USAGE" "the probe command is missing (after --)"; }
REL_A=${RELEASES[0]} REL_B=${RELEASES[1]}
for name in "$NS" "$REL_A" "$REL_B" "$TARGET"; do
  is_name "$name" || die "$EXIT_USAGE" "'$name' is not a valid Kubernetes name"
done
[ "$REL_A" != "$REL_B" ] || die "$EXIT_USAGE" "the two releases must differ"

KUBECTL=${KUBECTL_BIN:-kubectl}
command -v "$KUBECTL" >/dev/null 2>&1 || die "$EXIT_SAME" "kubectl not found ($KUBECTL)"
if [ -n "$JQ_FILTER" ]; then command -v jq >/dev/null 2>&1 || die "$EXIT_SAME" "jq not found (--jq)"; fi
KC=("$KUBECTL")
[ -z "$KUBECONFIG_ARG" ] || KC+=(--kubeconfig "$KUBECONFIG_ARG")

TMP=$(mktemp -d)
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# <release> <file>: the normalised answer of the probe inside the release's pod.
answer() {
  local raw=$TMP/$1.raw re
  if ! "${KC[@]}" -n "$NS" exec "$TARGET/$1" -- "${PROBE[@]}" >"$raw" 2>"$raw.err"; then
    printf 'smoke-diff: %s/%s/%s: the probe failed: %s\n' "$NS" "$TARGET" "$1" "$(tr '\n' ' ' <"$raw.err")" >&2
    return 1
  fi
  if [ -n "$JQ_FILTER" ]; then
    jq -S "$JQ_FILTER" "$raw" >"$raw.jq" 2>"$raw.err" || { printf 'smoke-diff: %s: the answer is not JSON for --jq: %s\n' "$1" "$(tr '\n' ' ' <"$raw.err")" >&2; return 1; }
    mv "$raw.jq" "$raw"
  fi
  for re in ${IGNORES[@]+"${IGNORES[@]}"}; do
    grep -Ev -e "$re" "$raw" >"$raw.f" || true
    mv "$raw.f" "$raw"
  done
  [ -s "$raw" ] || { printf 'smoke-diff: %s: the probe answered nothing\n' "$1" >&2; return 1; }
  cp "$raw" "$2"
}

unreachable=0
answer "$REL_A" "$TMP/a" || unreachable=1
answer "$REL_B" "$TMP/b" || unreachable=1
[ "$unreachable" -eq 0 ] || die "$EXIT_SAME" "cannot compare: a release did not answer (is it deployed and ready?)"

if diff -u -L "$REL_A" -L "$REL_B" "$TMP/a" "$TMP/b"; then
  printf 'smoke-diff: FAIL %s and %s give the same answer: the instances are not told apart\n' "$REL_A" "$REL_B" >&2
  exit "$EXIT_SAME"
fi
printf 'smoke-diff: OK %s and %s answer differently (diff above)\n' "$REL_A" "$REL_B"
exit "$EXIT_DIFFER"
