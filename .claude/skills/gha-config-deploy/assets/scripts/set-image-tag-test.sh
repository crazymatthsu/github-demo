#!/usr/bin/env bash
# set-image-tag-test.sh — plain-bash test of set-image-tag.sh on a throwaway config tree: tag and digest per
# instance of the released apps only, compose.env, idempotency, string tags, image keys matched by their last
# segment, stale digests, copying from another env (--from), refusals and exit codes. No network, no git.
# Part of the gha-config-deploy skill.
#
# Usage: set-image-tag-test.sh [--help] [<path to set-image-tag.sh>]
#   Default: set-image-tag.sh next to this file, else ../ci/set-image-tag.sh (scripts in scripts/ci/, their
#   tests in scripts/test/, where the lint job runs scripts/test/*-test.sh).
#   Needs jq and mikefarah yq v4 (as `yq`, or SET_IMAGE_TAG_YQ=<path>).
# Exit codes: 0 every case passed · 1 a case failed · 2 usage · 5 a tool is missing
set -euo pipefail

case "${1:-}" in
  -h | --help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 0
    ;;
esac
[ $# -le 1 ] || { echo "usage: $0 [<path to set-image-tag.sh>]" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
if [ $# -eq 1 ]; then
  SUT=$1
elif [ -f "$HERE/set-image-tag.sh" ]; then
  SUT=$HERE/set-image-tag.sh
else
  SUT=$HERE/../ci/set-image-tag.sh
fi
[ -f "$SUT" ] || { echo "set-image-tag-test: $SUT not found (pass its path)" >&2; exit 2; }
SUT=$(cd "$(dirname "$SUT")" && pwd)/$(basename "$SUT")
YQ=${SET_IMAGE_TAG_YQ:-yq}
"$YQ" --version 2>/dev/null | grep -q mikefarah || { echo "set-image-tag-test: mikefarah yq v4 is needed (SET_IMAGE_TAG_YQ)" >&2; exit 5; }
command -v jq >/dev/null 2>&1 || { echo "set-image-tag-test: jq is needed" >&2; exit 5; }
export SET_IMAGE_TAG_YQ=$YQ
unset IMAGE_DIGESTS SET_IMAGE_TAG_VAR || true

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
D1=sha256:$(printf 'b%.0s' $(seq 64))
D2=sha256:$(printf 'c%.0s' $(seq 64))
D0=sha256:$(printf 'a%.0s' $(seq 64))

FAILED=0 PASSED=0
pass() { PASSED=$((PASSED + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }
OUT='' ERR='' RC=0
run() { # <command...> in $WORK/tree
  RC=0
  (cd "$WORK/tree" && "$@") >"$WORK/out" 2>"$WORK/err" || RC=$?
  OUT=$(cat "$WORK/out") ERR=$(cat "$WORK/err")
}
expect_rc() { if [ "$RC" -eq "$2" ]; then return 0; fi; fail "$1" "exit $RC, expected $2 (stderr: $ERR)"; return 1; }
value() { "$YQ" "$2" "$WORK/tree/$1"; }

instance() { # <dir> <tag> [<digest>]: an instance values.yaml in yq layout
  mkdir -p "$WORK/tree/$1"
  {
    echo "image:"
    echo "  repository: ghcr.io/acme/app"
    echo "  tag: \"$2\""
    if [ -n "${3:-}" ]; then echo "  digest: $3"; fi
    echo "identity:"
    echo "  instance: ${1##*/}"
  } >"$WORK/tree/$1/values.yaml"
}
fixture() {
  rm -rf "$WORK/tree"
  instance config/qa/payments/api/ledger 1.0.0
  printf 'APP_NAME=api\nIMAGE_TAG=1.0.0\nJAVA_OPTS=-Xmx512m\n' >"$WORK/tree/config/qa/payments/api/ledger/compose.env"
  instance config/qa/payments/api/refunds 1.0.0
  mkdir -p "$WORK/tree/config/qa/payments/api/app-common"
  printf 'image:\n  repository: ghcr.io/acme/api\nresources: {}\n' >"$WORK/tree/config/qa/payments/api/app-common/values.yaml"
  instance config/qa/payments/worker/main 0.9.0
  mkdir -p "$WORK/tree/config/qa/_common"
  echo "log: json" >"$WORK/tree/config/qa/_common/application.yml"
  instance config/prod/payments/api/ledger 0.9.0 "$D0"
  instance config/prod/payments/api/refunds 0.9.0 "$D0"
  instance config/prod/payments/worker/main 0.8.0
}

# --- cases --------------------------------------------------------------------------------------------------

fixture
run env IMAGE_DIGESTS="{\"api\": \"ghcr.io/acme/api:sha-1a2b3c4@$D1\"}" bash "$SUT" config/qa 1.1.0 api
if expect_rc release 0; then
  expected="config/qa/payments/api/ledger/values.yaml
config/qa/payments/api/ledger/compose.env
config/qa/payments/api/refunds/values.yaml"
  if [ "$OUT" != "$expected" ]; then fail release "changed files: $OUT"
  elif [ "$(value config/qa/payments/api/ledger/values.yaml '.image.tag + " " + .image.digest')" != "1.1.0 $D1" ]; then fail release "ledger values not pinned"
  elif ! grep -qx 'IMAGE_TAG=1.1.0' "$WORK/tree/config/qa/payments/api/ledger/compose.env"; then fail release "compose.env not set"
  elif ! grep -qx 'JAVA_OPTS=-Xmx512m' "$WORK/tree/config/qa/payments/api/ledger/compose.env"; then fail release "compose.env lost a line"
  elif [ "$(value config/qa/payments/worker/main/values.yaml .image.tag)" != 0.9.0 ]; then fail release "another app was changed"
  elif [ "$(value config/qa/payments/api/app-common/values.yaml '.image.tag // "none"')" != none ]; then fail release "app-common was changed"
  else pass release; fi
fi

run env IMAGE_DIGESTS="{\"api\": \"ghcr.io/acme/api:sha-1a2b3c4@$D1\"}" bash "$SUT" config/qa 1.1.0 api
if expect_rc idempotent 0; then
  if [ -n "$OUT" ]; then fail idempotent "a second run changed: $OUT"; else pass idempotent; fi
fi

run bash "$SUT" config/qa 1.10 worker
if expect_rc string-tag 0; then
  if grep -q 'tag: "1.10"' "$WORK/tree/config/qa/payments/worker/main/values.yaml"; then pass string-tag
  else fail string-tag "1.10 is not a quoted string: $(cat "$WORK/tree/config/qa/payments/worker/main/values.yaml")"; fi
fi

run env IMAGE_DIGESTS="{\"team/worker\": \"ghcr.io/acme/team/worker:sha-1a2b3c4@$D2\"}" bash "$SUT" config/qa 1.11.0 worker
if expect_rc image-key-last-segment 0; then
  if [ "$(value config/qa/payments/worker/main/values.yaml .image.digest)" = "$D2" ]; then pass image-key-last-segment
  else fail image-key-last-segment "digest not set from team/worker"; fi
fi

run bash "$SUT" config/prod 1.2.0 worker api
if expect_rc stale-digest-removed 0; then
  if [ "$(value config/prod/payments/api/ledger/values.yaml '.image.tag + " " + (.image.digest // "none")')" = "1.2.0 none" ]; then
    pass stale-digest-removed
  else fail stale-digest-removed "prod ledger: $(value config/prod/payments/api/ledger/values.yaml .image)"; fi
fi

run bash "$SUT" --from config/qa config/prod api
if expect_rc from 0; then
  if [ "$(value config/prod/payments/api/refunds/values.yaml '.image.tag + " " + .image.digest')" != "1.1.0 $D1" ]; then fail from "prod refunds not copied from qa"
  elif [ "$(value config/prod/payments/worker/main/values.yaml .image.tag)" != 1.2.0 ]; then fail from "an app that was not named changed"
  elif ! printf '%s\n' "$OUT" | grep -qx 'config/prod/payments/api/ledger/values.yaml'; then fail from "changed files: $OUT"
  else pass from; fi
fi

fixture
run env IMAGE_DIGESTS="{\"api\": \"ghcr.io/acme/api:sha-1a2b3c4@$D1\", \"worker\": \"ghcr.io/acme/worker:sha-1a2b3c4@$D2\"}" \
  bash "$SUT" --apps "api worker" config/qa 1.3.0
if expect_rc apps-option 0; then
  if [ "$(value config/qa/payments/worker/main/values.yaml '.image.tag + " " + .image.digest')" = "1.3.0 $D2" ] &&
    [ "$(value config/qa/payments/api/refunds/values.yaml '.image.tag + " " + .image.digest')" = "1.3.0 $D1" ]; then pass apps-option
  else fail apps-option "not every app of --apps was pinned: $OUT"; fi
fi
run bash "$SUT" --apps "" config/qa 1.3.0
expect_rc apps-option-empty 2 && pass apps-option-empty

fixture
run bash "$SUT" config/qa 2.0.0
if expect_rc all-apps 0; then
  if [ "$(printf '%s\n' "$OUT" | grep -c 'values.yaml$')" -eq 3 ]; then pass all-apps; else fail all-apps "changed: $OUT"; fi
fi

fixture
instance config/qa/payments/api/refunds 1.0.5
run bash "$SUT" --from config/qa config/prod api
if expect_rc from-disagreement 1; then
  case $ERR in *"two releases of api"*) pass from-disagreement ;; *) fail from-disagreement "stderr: $ERR" ;; esac
fi

fixture
instance config/qa/payments/worker/main ""
run bash "$SUT" --from config/qa config/prod worker
if expect_rc from-nothing-recorded 0; then
  case $ERR in *"records no release of worker"*) pass from-nothing-recorded ;; *) fail from-nothing-recorded "stderr: $ERR" ;; esac
fi

fixture
printf 'replicas: 1\n' >"$WORK/tree/config/qa/payments/api/refunds/values.yaml"
run bash "$SUT" config/qa 1.1.0 api
expect_rc values-without-image 4 && pass values-without-image

fixture
run bash "$SUT" config/qa 1.1.0 nosuch
if expect_rc app-without-instances 0; then
  if [ -z "$OUT" ] && case $ERR in *"no instance of nosuch"*) true ;; *) false ;; esac; then pass app-without-instances
  else fail app-without-instances "out: $OUT, err: $ERR"; fi
fi

run bash "$SUT"
expect_rc usage-no-args 2 && pass usage-no-args
run bash "$SUT" config/qa 'bad tag' api
expect_rc usage-bad-tag 2 && pass usage-bad-tag
run bash "$SUT" config/qa 1.0.0 Api
expect_rc usage-bad-app 2 && pass usage-bad-app
run env IMAGE_DIGESTS='{"api": "ghcr.io/acme/api:1.0.0"}' bash "$SUT" config/qa 1.0.0 api
expect_rc usage-digest-not-pinned 2 && pass usage-digest-not-pinned
run bash "$SUT" config/nosuch 1.0.0
expect_rc missing-env-dir 4 && pass missing-env-dir
run bash "$SUT" --help
expect_rc help 0 && pass help

echo "set-image-tag-test: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
