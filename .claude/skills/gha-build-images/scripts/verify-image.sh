#!/usr/bin/env bash
# verify-image.sh - check a locally built base image from the outside, before it is pushed.
#
# Usage: verify-image.sh [options] <image>
#
#   --kind runtime|ci-build  check set; ci-build adds the tool checks below               (default: runtime)
#   --expect-uid <uid>       the image's USER must be this numeric UID (ci-build: the runner UID, 1001)
#   --ca-bundle <path>       CA bundle inside the image    (default: /etc/ssl/certs/company-ca-bundle.pem)
#   --os-store <path>        OS trust store inside the image  (default: /etc/ssl/certs/ca-certificates.crt)
#   --no-ca                  skip the CA checks (an image built without an enterprise CA)
#   --check '<command>'      extra shell command that must succeed inside the image (repeatable)
#   --no-default-checks      drop the kind's default tool checks (keep only --check commands)
#   --tls-url <url>          fetch <url> with curl inside the image, through its OS store (repeatable)
#   --summary <file>         append a Markdown table to <file>  (default: $GITHUB_STEP_SUMMARY when set)
#   -h, --help               show this help
#
# Checks: USER is set, numeric-or-named but not root, and equals --expect-uid when given; every
# certificate of the CA bundle is trusted by the OS store (openssl verify) and, when the image has a
# JVM, present in its default cacerts (matched by SHA-256 fingerprint, so aliases do not matter); for
# --kind ci-build: the tools git, docker, docker compose, docker buildx, helm, kubectl, kind, hadolint,
# ShellCheck, yq, jq and crane run; then every --check command and every --tls-url fetch. Each check
# runs in a fresh `run --rm` of the image, so the image needs sh, awk, openssl and grep (Debian/Ubuntu
# images have them). Engine: docker, or CONTAINER_ENGINE=podman.
#
# Examples:
#   verify-image.sh --kind runtime --tls-url https://github.com ghcr.io/acme/base/runtime-base:dev
#   verify-image.sh --kind ci-build --expect-uid 1001 ghcr.io/acme/base/ci-build:dev
#
# Exit codes: 0 every check passed; 1 at least one check failed; 2 usage error;
#             3 container engine missing or image not present locally.
set -euo pipefail

usage() { sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die_usage() {
  echo "verify-image.sh: $*" >&2
  echo "Try 'verify-image.sh --help'." >&2
  exit 2
}
need_value() { [[ $2 -ge 2 && -n ${3:-} ]] || die_usage "$1 needs a value"; }

kind=runtime
expect_uid=""
ca_bundle=/etc/ssl/certs/company-ca-bundle.pem
os_store=/etc/ssl/certs/ca-certificates.crt
check_ca=true
default_checks=true
checks=()
tls_urls=()
summary=${GITHUB_STEP_SUMMARY:-}
image=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --kind) need_value "$1" $# "${2:-}"; kind=$2; shift 2 ;;
    --expect-uid) need_value "$1" $# "${2:-}"; expect_uid=$2; shift 2 ;;
    --ca-bundle) need_value "$1" $# "${2:-}"; ca_bundle=$2; shift 2 ;;
    --os-store) need_value "$1" $# "${2:-}"; os_store=$2; shift 2 ;;
    --no-ca) check_ca=false; shift ;;
    --check) need_value "$1" $# "${2:-}"; checks+=("$2"); shift 2 ;;
    --no-default-checks) default_checks=false; shift ;;
    --tls-url) need_value "$1" $# "${2:-}"; tls_urls+=("$2"); shift 2 ;;
    --summary) need_value "$1" $# "${2:-}"; summary=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    --) shift; [[ $# -eq 1 ]] || die_usage "expected one image after --"; image=$1; shift ;;
    -*) die_usage "unknown option $1" ;;
    *) [[ -z $image ]] || die_usage "more than one image given ($image, $1)"; image=$1; shift ;;
  esac
done
[[ -n $image ]] || die_usage "no image given"
case $kind in runtime | ci-build) ;; *) die_usage "--kind must be runtime or ci-build, not '$kind'" ;; esac
[[ -z $expect_uid || $expect_uid =~ ^[0-9]+$ ]] || die_usage "--expect-uid must be numeric, not '$expect_uid'"

engine=${CONTAINER_ENGINE:-docker}
if ! command -v "$engine" >/dev/null 2>&1; then
  echo "verify-image.sh: container engine '$engine' not found (set CONTAINER_ENGINE)" >&2
  exit 3
fi
if ! "$engine" image inspect "$image" >/dev/null 2>&1; then
  echo "verify-image.sh: image $image is not present locally (build it with --load, or pull it)" >&2
  exit 3
fi

failed=0
rows=()
record() { # record <check> <ok|FAILED> <detail>
  local detail=${3//|/\\|}
  detail=${detail//$'\n'/ }
  rows+=("| $1 | $2 | \`${detail:0:160}\` |")
  printf '%-7s %s: %s\n' "$2" "$1" "${3//$'\n'/ }"
  if [[ $2 != ok ]]; then failed=1; fi
}
run_check() { # run_check <check> <command...>: the command runs on the host (usually `$engine run ...`)
  local name=$1 out rc
  shift
  if out=$("$@" 2>&1); then
    record "$name" ok "$(head -n 1 <<<"$out")"
  else
    rc=$?
    record "$name" FAILED "$(if [[ -n $out ]]; then tail -n 3 <<<"$out"; else echo "exit status $rc, no output"; fi)"
  fi
}
in_image() { # in_image <shell command>: runs it with sh inside a fresh container of the image
  "$engine" run --rm --entrypoint sh "$image" -c "$1"
}

# 1. The user the image runs as (a job container, a pod with runAsNonRoot).
user=$("$engine" image inspect --format '{{.Config.User}}' "$image" 2>/dev/null || true)
uid=${user%%:*}
if [[ -z $user || $uid == root || $uid == 0 ]]; then
  record "non-root USER" FAILED "USER is '${user:-unset}'; end the Dockerfile with a numeric non-root USER"
elif [[ -n $expect_uid && $uid != "$expect_uid" ]]; then
  record "USER is UID $expect_uid" FAILED "USER is '$user' (a job container must run as the runner UID)"
else
  record "non-root USER${expect_uid:+ (UID $expect_uid)}" ok "USER $user"
fi

# 2. The CA: every certificate of the bundle in the OS store and, with a JVM, in the default cacerts.
# shellcheck disable=SC2016 # expanded by sh inside the image, not here
ca_script='set -eu
[ -s "$CA_BUNDLE" ] || { echo "no CA bundle at $CA_BUNDLE"; exit 1; }
if grep -q "PRIVATE KEY" "$CA_BUNDLE"; then echo "$CA_BUNDLE contains a private key"; exit 1; fi
dir=$(mktemp -d)
awk -v dir="$dir" "/-----BEGIN CERTIFICATE-----/ { n++; out = sprintf(\"%s/%02d.pem\", dir, n) } out { print > out } /-----END CERTIFICATE-----/ { close(out); out = \"\" }" "$CA_BUNDLE"
jvm=""
if command -v keytool >/dev/null 2>&1; then
  jvm=$(keytool -list -cacerts -storepass changeit 2>/dev/null | tr -d ":" | tr "[:lower:]" "[:upper:]")
  [ -n "$jvm" ] || { echo "keytool -list -cacerts printed nothing"; exit 1; }
elif command -v java >/dev/null 2>&1; then
  echo "java without keytool: the JVM trust store cannot be checked"; exit 1
fi
count=0
for crt in "$dir"/*.pem; do
  [ -s "$crt" ] || continue
  count=$((count + 1))
  subject=$(openssl x509 -noout -subject -in "$crt")
  openssl verify -CAfile "$OS_STORE" "$crt" >/dev/null 2>&1 || { echo "OS store does not trust $subject"; exit 1; }
  if [ -n "$jvm" ]; then
    fp=$(openssl x509 -noout -fingerprint -sha256 -in "$crt" | sed "s/^.*=//" | tr -d ":" | tr "[:lower:]" "[:upper:]")
    printf "%s\n" "$jvm" | grep -q "$fp" || { echo "JVM cacerts lacks $subject"; exit 1; }
  fi
done
rm -rf "$dir"
[ "$count" -gt 0 ] || { echo "no certificate in $CA_BUNDLE"; exit 1; }
if [ -n "$jvm" ]; then echo "$count certificate(s) in the OS store and the JVM cacerts"; else echo "$count certificate(s) in the OS store (no JVM)"; fi'
if [[ $check_ca == true ]]; then
  run_check "CA bundle in the trust stores" \
    "$engine" run --rm --entrypoint sh -e CA_BUNDLE="$ca_bundle" -e OS_STORE="$os_store" "$image" -c "$ca_script"
fi

# 3. Tools (ci-build) and extra commands.
tool_checks=()
if [[ $kind == ci-build && $default_checks == true ]]; then
  tool_checks=("git --version" "docker --version" "docker compose version" "docker buildx version"
    "helm version --short" "kubectl version --client" "kind version" "hadolint --version"
    "shellcheck --version" "yq --version" "jq --version" "crane version")
fi
for command in ${tool_checks[@]+"${tool_checks[@]}"} ${checks[@]+"${checks[@]}"}; do
  run_check "$command" in_image "$command"
done

# 4. TLS through the image's OS store (an internal endpoint proves the enterprise CA; a public one
#    proves the public roots survived).
for url in ${tls_urls[@]+"${tls_urls[@]}"}; do
  # shellcheck disable=SC2016 # expanded by sh inside the image
  run_check "TLS $url" "$engine" run --rm --entrypoint sh -e TLS_URL="$url" "$image" \
    -c 'curl -fsS -o /dev/null -w "HTTP %{http_code}" "$TLS_URL"'
done

if [[ -n $summary ]]; then
  {
    echo "### verify-image: \`$image\`"
    echo ""
    echo "| check | result | output |"
    echo "|---|---|---|"
    printf '%s\n' "${rows[@]}"
    echo ""
  } >>"$summary"
fi
if [[ $failed -ne 0 ]]; then
  echo "verify-image.sh: $image failed at least one check" >&2
  exit 1
fi
echo "verify-image.sh: $image passed every check"
