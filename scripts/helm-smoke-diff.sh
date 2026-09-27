#!/usr/bin/env bash
# helm-smoke-diff.sh — prove that two deployed AppInstances differ (brief §7 "demo step 2", D11 §6.4): their
# identity tuples in /actuator/info, and at least one value of their masked effective configuration in
# /actuator/connectorconfig (e.g. connector.source.table, connector.sink.type). Both endpoints are read inside
# the pods, so nothing is port-forwarded. Portable bash (3.2+); run with --help for the usage.
set -euo pipefail

readonly EXIT_DIFFER=0 EXIT_SAME=1 EXIT_USAGE=2

usage() {
    cat <<'EOF'
Usage: helm-smoke-diff.sh -n <namespace> [--kubeconfig <file>] <release-a> <release-b>

Reads /actuator/info and /actuator/connectorconfig of both releases with
  kubectl -n <namespace> exec deploy/<release> -- curl -fsS localhost:8080/actuator/...
and prints a two-column summary: identity, completeness, config layers and every property of the masked
configuration summary, "*" marking the rows that differ.

Passes when the identity tuples differ and at least one configuration value differs.
Exit codes: 0 the instances differ · 1 they do not, or an instance is unreachable (or kubectl / jq missing) ·
            2 usage
Environment: KUBECTL_BIN (default kubectl); KUBECONFIG as usual.
EOF
}

die() {
    local code="$1"
    shift
    printf 'helm-smoke-diff: error: %s\n' "$*" >&2
    exit "$code"
}
is_label() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' && [ "${#1}" -le 63 ]; }

NS="" KUBECONFIG_ARG=""
RELEASES=()
while [ $# -gt 0 ]; do
    case "$1" in
        -n | --namespace)
            [ $# -ge 2 ] && [ -n "$2" ] || die "$EXIT_USAGE" "$1 needs a value (see --help)"
            NS="$2"
            shift
            ;;
        --namespace=*) NS="${1#*=}" ;;
        --kubeconfig)
            [ $# -ge 2 ] && [ -n "$2" ] || die "$EXIT_USAGE" "$1 needs a value (see --help)"
            KUBECONFIG_ARG="$2"
            shift
            ;;
        --kubeconfig=*) KUBECONFIG_ARG="${1#*=}" ;;
        -h | --help) usage; exit 0 ;;
        -*) die "$EXIT_USAGE" "unknown option $1 (see --help)" ;;
        *) RELEASES+=("$1") ;;
    esac
    shift
done
[ -n "$NS" ] || { usage >&2; die "$EXIT_USAGE" "-n <namespace> is required"; }
[ "${#RELEASES[@]}" -eq 2 ] || { usage >&2; die "$EXIT_USAGE" "expected two releases, got ${#RELEASES[@]}"; }
REL_A="${RELEASES[0]}" REL_B="${RELEASES[1]}"
for name in "$NS" "$REL_A" "$REL_B"; do
    is_label "$name" || die "$EXIT_USAGE" "'$name' is not a valid Kubernetes name"
done
[ "$REL_A" != "$REL_B" ] || die "$EXIT_USAGE" "the two releases must differ"

KUBECTL="${KUBECTL_BIN:-kubectl}"
command -v "$KUBECTL" >/dev/null 2>&1 || die "$EXIT_SAME" "kubectl not found ($KUBECTL)"
command -v jq >/dev/null 2>&1 || die "$EXIT_SAME" "jq not found"
KC=("$KUBECTL")
[ -z "$KUBECONFIG_ARG" ] || KC+=(--kubeconfig "$KUBECONFIG_ARG")

TMP="$(mktemp -d)"
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# <release> <endpoint> <file>: the endpoint's JSON from inside the release's pod.
fetch() {
    if ! "${KC[@]}" -n "$NS" exec "deploy/$1" -- curl -fsS --max-time 10 "http://localhost:8080/actuator/$2" >"$3" 2>"$3.err"; then
        printf 'helm-smoke-diff: %s/%s: /actuator/%s unreachable: %s\n' "$NS" "$1" "$2" "$(tr '\n' ' ' <"$3.err")" >&2
        return 1
    fi
    jq -e . "$3" >/dev/null 2>&1 || { printf 'helm-smoke-diff: %s: /actuator/%s is not JSON\n' "$1" "$2" >&2; return 1; }
}
unreachable=0
for side in a b; do
    release="$REL_A"
    [ "$side" = a ] || release="$REL_B"
    fetch "$release" info "$TMP/info-$side.json" || unreachable=1
    fetch "$release" connectorconfig "$TMP/config-$side.json" || unreachable=1
done
[ "$unreachable" -eq 0 ] || die "$EXIT_SAME" "cannot compare: an instance did not answer (is it deployed and ready?)"

# One "<key>\t<value>" row per summary entry: identity, completeness and layers, then every property.
rows() {
    local clean='def clean: tostring | gsub("[\\t\\r\\n]"; " ");'
    jq -r "$clean"'
        "identity (/actuator/info)\t\(.connector.tuple // "<missing>" | clean)",
        "identity complete\t\(.connector.complete | if . == null then "<missing>" else . end | clean)"' "$TMP/info-$1.json"
    jq -r "$clean"'
        "config layers\t\((.layers // []) | map(clean | sub("^/config/(?<l>[^/]+)/application[.]yml$"; "\(.l)")) | join(", "))",
        ((.properties // {}) | to_entries[] | "\(.key | clean)\t\(.value // "<null>" | clean)")' "$TMP/config-$1.json"
}
rows a >"$TMP/rows-a.tsv"
rows b >"$TMP/rows-b.tsv"

# Two columns over the union of keys (summary rows first, then the properties sorted); "*" marks a difference.
awk -F '\t' -v a="$REL_A" -v b="$REL_B" '
    FNR == 1 { file++ }
    {
        if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 }
        if (file == 1) va[$1] = $2; else vb[$1] = $2
    }
    END {
        width = 34
        for (i = 1; i <= n; i++) if (length(order[i]) > width) width = length(order[i])
        colw = length(a)
        for (k in va) if (length(va[k]) > colw) colw = length(va[k])
        if (colw > 60) colw = 60
        printf "%-" width "s  %-" colw "s  %s\n", "", a, b
        for (i = 1; i <= n; i++) {
            k = order[i]
            x = (k in va) ? va[k] : "<absent>"
            y = (k in vb) ? vb[k] : "<absent>"
            printf "%-" width "s  %-" colw "s  %s%s\n", k, x, y, (x == y ? "" : "   *")
        }
    }' "$TMP/rows-a.tsv" "$TMP/rows-b.tsv"

tuple_a="$(jq -r '.connector.tuple // ""' "$TMP/info-a.json")"
tuple_b="$(jq -r '.connector.tuple // ""' "$TMP/info-b.json")"
differing="$(awk -F '\t' 'NR == FNR { if ($1 != "config layers" && $1 !~ /^identity/) va[$1] = $2; next }
    $1 == "config layers" || $1 ~ /^identity/ { next }
    { seen[$1] = 1; if (!($1 in va) || va[$1] != $2) d[$1] = 1 }
    END { for (k in va) if (!(k in seen)) d[k] = 1; for (k in d) print k }' "$TMP/rows-a.tsv" "$TMP/rows-b.tsv" | sort)"

problems=""
[ -n "$tuple_a" ] && [ -n "$tuple_b" ] || problems="$problems; an identity tuple is missing from /actuator/info"
[ "$tuple_a" != "$tuple_b" ] || problems="$problems; both answer with the identity $tuple_a"
[ -n "$differing" ] || problems="$problems; no configuration value differs"
if [ -n "$problems" ]; then
    printf 'helm-smoke-diff: FAIL %s vs %s:%s\n' "$REL_A" "$REL_B" "${problems#;}" >&2
    exit "$EXIT_SAME"
fi
printf 'helm-smoke-diff: OK %s and %s differ in identity and in %s configuration value(s): %s\n' \
    "$tuple_a" "$tuple_b" "$(printf '%s\n' "$differing" | wc -l | tr -d ' ')" "$(printf '%s' "$differing" | tr '\n' ' ')"
exit "$EXIT_DIFFER"
