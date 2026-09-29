#!/usr/bin/env bash
# test-retention.sh — plain-bash tests for retention.sh against a stubbed `gh`: no GitHub, no network.
#
# Usage: test-retention.sh [<path to retention.sh>]
#   Default: retention.sh next to this file, else ../ci/retention.sh (the layout of a repository that keeps
#   scripts in scripts/ci/ and tests in scripts/test/).
# The stub answers `gh api [--paginate] [--method M] <path>` from JSON files in a temp directory (owner type,
# package versions in pages, pull requests), fails where a case leaves a <path>.fail file, and logs every
# call, so the cases see which calls went out and that DELETE hit exactly the delete decisions. "Now" is
# fixed through RETENTION_NOW, and the script runs with an empty environment plus what a case sets.
# The affected-map cases need yq (mikefarah v4 or the Python yq; YQ=<path> picks one) and are skipped
# without it.
# Needs: bash 4+, jq.
# Exit codes: 0 all cases passed · 1 a case failed · 2 usage (retention.sh not found, jq missing)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case ${1:-} in
  -h | --help) sed -n '2,/^# Exit codes/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
script=${1:-}
if [[ -z $script ]]; then
  for candidate in "$here/retention.sh" "$here/../ci/retention.sh"; do
    if [[ -f $candidate ]]; then script=$candidate; break; fi
  done
fi
[[ -n $script && -f $script ]] || { echo "test-retention.sh: retention.sh not found; pass its path" >&2; exit 2; }
((BASH_VERSINFO[0] >= 4)) || { echo "test-retention.sh: needs bash 4 or newer" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "test-retention.sh: jq is required" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export STUB="$tmp/stub"
mkdir -p "$tmp/bin" "$STUB/api"

cat >"$tmp/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub gh: `gh api [--paginate] [--method M] <path>`, answered from $STUB/api/<path without ?query>.json: one
# JSON value, or pages (JSON arrays one after another; without --paginate only the first page). A file
# <path>.fail makes the call fail with its content as gh's message; a missing file is a 404. DELETE succeeds
# for an id of the listing it belongs to. Every call is logged to $STUB/calls.log as "<METHOD> <path>[ paginate]".
set -euo pipefail
[[ ${1:-} == api ]] || { echo "stub gh: unsupported command: $*" >&2; exit 1; }
shift
method=GET paginate="" path=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --paginate) paginate=" paginate"; shift ;;
    --method | -X) method=$2; shift 2 ;;
    -*) echo "stub gh: unsupported option $1 (the script filters raw JSON with jq)" >&2; exit 1 ;;
    *) path=$1; shift ;;
  esac
done
echo "$method $path$paginate" >>"$STUB/calls.log"
file="$STUB/api/${path%%\?*}"
not_found() { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [[ -f $file.fail ]]; then echo '{"message":"stubbed failure"}'; cat "$file.fail" >&2; exit 1; fi
case $method in
  GET)
    [[ -f $file.json ]] || not_found
    if [[ -n $paginate ]]; then cat "$file.json"; else jq -cn input "$file.json"; fi ;;
  DELETE)
    { [[ -f ${file%/*}.json ]] &&
      jq -en --argjson id "${file##*/}" 'any(inputs[]; .id == $id)' "${file%/*}.json" >/dev/null; } || not_found ;;
  *) echo "stub gh: unsupported method $method" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/bin/gh"

have_yq=false
yq_bin=${YQ:-$(command -v yq || true)}
if [[ -n $yq_bin && -x $yq_bin ]]; then
  ln -sf "$yq_bin" "$tmp/bin/yq"
  printf 'projects:\n  "a/b": { image: true }\n' >"$tmp/probe.yml"
  if { "$tmp/bin/yq" -o=json '.projects' "$tmp/probe.yml" 2>/dev/null || "$tmp/bin/yq" '.projects' "$tmp/probe.yml"; } |
    jq -e '.["a/b"].image == true' >/dev/null 2>&1; then
    have_yq=true
  else
    rm -f "$tmp/bin/yq"
  fi
fi

pass=0 fail=0
expect() { # expect <case> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    printf 'ok    %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
  fi
}
contains() { if [[ $1 == *"$2"* ]]; then echo yes; else echo "no: $1"; fi; } # contains <text> <part>

# --- fixtures: GitHub as the stub sees it ---------------------------------------------------------------------
NOW=$(jq -n '"2026-09-29T12:00:00Z" | fromdateiso8601')
ago() { jq -rn --argjson t $((NOW - $1 * 86400 - ${2:-0})) '$t | todate'; } # ago <days> [<more seconds>]
fake_digest() { printf 'sha256:%064x' "$1"; }
version() { # version <id> <age in days> [<tags, comma-separated> [<more seconds>]]: one package version object
  jq -cn --argjson id "$1" --arg name "$(fake_digest "$1")" --arg created "$(ago "$2" "${4:-0}")" --arg tags "${3:-}" \
    '{id: $id, name: $name, created_at: $created, updated_at: $created,
      metadata: {package_type: "container", container: {tags: ($tags | if . == "" then [] else split(",") end)}}}'
}
listing() { # listing <api path> <page>...: what GET <api path> answers; a page = version objects, one per line
  local file="$STUB/api/$1.json" page
  shift
  mkdir -p "$(dirname "$file")"
  : >"$file"
  for page in "$@"; do jq -cs . <<<"$page" >>"$file"; done
}
answer() { mkdir -p "$(dirname "$STUB/api/$1")"; printf '%s\n' "$2" >"$STUB/api/$1.json"; } # answer <path> <json>
fail_on() { mkdir -p "$(dirname "$STUB/api/$1")"; printf '%s\n' "$2" >"$STUB/api/$1.fail"; } # fail_on <path> <message>
pr() { # pr <n> open | pr <n> closed <days ago> [<more seconds>]
  if [[ $2 == open ]]; then
    answer "repos/acme/app/pulls/$1" "{\"number\": $1, \"state\": \"open\", \"closed_at\": null}"
  else
    answer "repos/acme/app/pulls/$1" "$(jq -cn --argjson n "$1" --arg at "$(ago "$3" "${4:-0}")" \
      '{number: $n, state: "closed", closed_at: $at, merged_at: $at}')"
  fi
}

answer users/acme '{"login": "acme", "type": "Organization"}'
answer users/alice '{"login": "alice", "type": "User"}'
pr 10 closed 10
pr 11 closed 7 3600  # 7 d 1 h: past the 7-day grace
pr 12 closed 6 82800 # 6 d 23 h: within it
pr 13 open
pr 16 closed 30
listing orgs/acme/packages/container/api/versions "$(
  version 208 0 1.6.0-rc.21,main,sha-2000008
  version 201 1 1.6.0-rc.20,sha-2000001
  version 202 2 1.6.0-rc.19
  version 203 3 1.6.0-rc.18
  version 104 5 pr-13-ddddddd
  version 103 8 pr-12-ccccccc
  version 102 9 pr-11-bbbbbbb
  version 105 19 pr-10-eeeeeee
  version 101 20 pr-10-aaaaaaa
  version 204 29 1.6.0-rc.17 82800
  version 205 30 1.6.0-rc.16
  version 206 60 1.6.0-rc.15
)" "$(
  version 207 100 1.5.0-rc.9,1.5.0,sha-2000007
  version 210 200 1.2.0-rc.5,1.2
  version 211 201 1.1.0-rc.5,1
  version 212 202 1.0.0-rc.5,latest
  version 214 300
  version 215 300 experiment-x
  version 216 300 1.0.0-rc.1,debug
  version 217 300 sha-2000017
  version 218 300 1.3.0-rc.4
  version 219 300 1.3.0-rc.3
  version 220 300 1.3.0-rc.2
  version 221 300 1.3.0-rc.1
  version 222 300 1.2.9-rc.1
  version 223 300 1.2.9-rc.2
  version 224 300 1.2.8-rc.1
  version 225 40 pr-16-abcdef0
  version 228 300 1.2.6-rc.1
)"
listing orgs/acme/packages/container/worker/versions "$(
  version 305 89 2.0.0-rc.10,2.0.0
  version 301 90 2.0.0-rc.9
  version 302 91 2.0.0-rc.8
)" "$(
  version 303 92 2.0.0-rc.7
  version 304 93 2.0.0-rc.6
)"
listing orgs/acme/packages/container/lonely/versions "$(
  version 403 12
  version 402 12 pr-10-2222222
  version 401 15 pr-10-1111111
)"

# --- fixtures: the checkout the script runs in (config tree of skill gha-config-deploy) -------------------
W="$tmp/repo"
mkdir -p "$W/config/dev/f1/api/one" "$W/config/dev/f1/api/two" "$W/config/qa/f1/api/one" "$W/config/dev/f2/web/one"
cat >"$W/config/dev/f1/api/one/compose.env" <<'EOF'
# compose variables
IMAGE_REPO=ghcr.io/acme
IMAGE_TAG=1.3.0-rc.4
APP_TAG=1.2.6-rc.1
EOF
cat >"$W/config/dev/f1/api/one/values.yaml" <<'EOF'
image:
  tag: "1.3.0-rc.3"
EOF
cat >"$W/config/dev/f1/api/two/values.yaml" <<'EOF'
image:
  tag: 1.3.0-rc.2   # pinned by hand
  # tag: 1.2.8-rc.1 (a comment protects nothing)
EOF
printf "IMAGE_TAG='1.3.0-rc.1' # quoted, CRLF\r\n" >"$W/config/dev/f1/api/two/compose.env"
cat >"$W/config/qa/f1/api/one/values.yaml" <<EOF
image:
  tag: "9.9.9"
  digest: "$(fake_digest 222)"
EOF
echo "IMAGE_TAG=9.9.9@$(fake_digest 223)" >"$W/config/qa/f1/api/one/compose.env"
echo "IMAGE_TAG=pr-16-abcdef0" >"$W/config/dev/f2/web/one/compose.env"

# rt [VAR=value...] [-- <arguments>...]: run retention.sh in ${RUN_DIR:-$W} with an empty environment plus
# the given variables; stdout in $out, stderr in $err, exit code in $rc, the stub's calls in $STUB/calls.log.
rt() {
  local envs=()
  while [[ $# -gt 0 && $1 != -- ]]; do envs+=("$1"); shift; done
  if [[ $# -gt 0 ]]; then shift; fi
  : >"$STUB/calls.log"
  rc=0
  out=$(cd "${RUN_DIR:-$W}" && env -i PATH="$tmp/bin:$PATH" HOME="$tmp" STUB="$STUB" RETENTION_NOW="$NOW" \
    GITHUB_REPOSITORY=acme/app ${envs[@]+"${envs[@]}"} "$BASH" "$script" "$@" 2>"$tmp/stderr") || rc=$?
  err=$(cat "$tmp/stderr")
}
col() { awk -F'\t' -v id="$1" -v c="$2" '$2 == id { print $c }' <<<"$out"; } # col <version id> <column>
decision() { col "$1" 5; }
reason() { col "$1" 6; }
decisions() { # decisions <id>...: their decisions, space-separated
  local id list=()
  for id in "$@"; do list+=("$(decision "$id")"); done
  echo "${list[*]}"
}
delete_decisions() { awk -F'\t' '$5 == "delete" { print $2 }' <<<"$out" | sort -n | paste -sd' ' -; }
deleted_ids() { sed -n 's|^DELETE .*/versions/\([0-9]*\)$|\1|p' "$STUB/calls.log" | sort -n | paste -sd' ' -; }
calls() { grep -cF -- "$1" "$STUB/calls.log" || true; } # calls <text>: how many logged calls contain it

echo "# dry run (RC_KEEP=3; PR_GRACE_DAYS and RC_MIN_AGE_DAYS at their defaults 7 and 30)"
rt RC_KEEP=3 -- --package api --package worker --package lonely
expect "exit 0" 0 "$rc"
expect "one line per version, both pages of each listing" 37 "$(grep -c . <<<"$out")"
expect "a line: package, id, tags, age in days, decision, reason" \
  $'api\t101\tpr-10-aaaaaaa\t20\tdelete\tPR #10 closed 10 d ago (grace 7 d)' "$(awk -F'\t' '$2 == 101' <<<"$out")"
expect "PR closed beyond the grace: delete" delete "$(decision 101)"
expect "PR closed 7 d 1 h ago (grace 7 d): delete" delete "$(decision 102)"
expect "PR closed 6 d 23 h ago: keep, within the grace" "keep:PR #12 closed 6 d ago, within the 7 d grace" \
  "$(decision 103):$(reason 103)"
expect "PR open: keep" "keep:PR #13 open" "$(decision 104):$(reason 104)"
expect "every image of a closed PR goes; the PR is looked up once" "delete:1" "$(decision 105):$(calls 'GET repos/acme/app/pulls/10')"
expect "pre-releases among the RC_KEEP newest: keep" "keep keep keep" "$(decisions 201 202 203)"
expect "rank and reason of a newest pre-release" "pre-release #2, among the 3 newest" "$(reason 202)"
expect "pre-release beyond RC_KEEP but 29 d 23 h old: keep, young" "keep:pre-release #4, younger than 30 d" \
  "$(decision 204):$(reason 204)"
expect "pre-release beyond RC_KEEP and exactly 30 d old: delete" \
  "delete:pre-release #5, beyond the 3 newest and 30 d or older" "$(decision 205):$(reason 205)"
expect "pre-release beyond RC_KEEP and 60 d old: delete" delete "$(decision 206)"
expect "old pre-releases that are the newest of their package: keep" "keep keep keep" "$(decisions 301 302 303)"
expect "the next old one of that package: delete" delete "$(decision 304)"
expect "a released pre-release does not take one of the RC_KEEP places" "keep:release tag 2.0.0" \
  "$(decision 305):$(reason 305)"
expect "release tag protects, also next to an rc tag" "keep:release tag 1.5.0" "$(decision 207):$(reason 207)"
expect "moving tags protect: main, X.Y, X, latest" "keep keep keep keep" "$(decisions 208 210 211 212)"
expect "moving tag reasons" "moving tag main|moving tag 1.2|moving tag 1|moving tag latest" \
  "$(reason 208)|$(reason 210)|$(reason 211)|$(reason 212)"
expect "untagged: keep" "-|keep|untagged (may belong to a tagged multi-platform index)" \
  "$(col 214 3)|$(decision 214)|$(reason 214)"
expect "unknown tag: keep, no retention rule" "keep:no retention rule for experiment-x" "$(decision 215):$(reason 215)"
expect "an unknown tag keeps an old pre-release" "keep:no retention rule for debug" "$(decision 216):$(reason 216)"
expect "sha-<sha7> alone: keep, no retention rule" "keep:no retention rule" "$(decision 217):$(reason 217)"
expect "in use: IMAGE_TAG= in compose.env" "keep:in use: 1.3.0-rc.4 in config/" "$(decision 218):$(reason 218)"
expect "in use: tag: \"...\" in values.yaml (quoted)" keep "$(decision 219)"
expect "in use: tag: ... # comment in values.yaml (unquoted)" keep "$(decision 220)"
expect "in use: IMAGE_TAG='...' # comment with CRLF" keep "$(decision 221)"
expect "in use: digest: in values.yaml" "keep:in use: digest in config/" "$(decision 222):$(reason 222)"
expect "in use: IMAGE_TAG=<tag>@sha256:<digest>" "keep:in use: digest in config/" "$(decision 223):$(reason 223)"
expect "in use beats the PR rule" "keep:in use: pr-16-abcdef0 in config/" "$(decision 225):$(reason 225)"
expect "a commented-out tag: line protects nothing" delete "$(decision 224)"
expect "another variable than IMAGE_TAG protects nothing" delete "$(decision 228)"
expect "the last tagged version of a package stays" \
  "delete keep keep:the last tagged version of the package (GHCR refuses to delete it)" \
  "$(decisions 401 402 403):$(reason 402)"
expect "age column in whole days" "20 29 0" "$(col 101 4) $(col 204 4) $(col 208 4)"
expect "the delete decisions" "101 102 105 205 206 224 228 304 401" "$(delete_decisions)"
expect "dry run: no DELETE call" 0 "$(calls DELETE)"
expect "org owner: orgs/<owner> scope, paginated listing" 1 \
  "$(calls 'GET orgs/acme/packages/container/api/versions?per_page=100 paginate')"
expect "dry run is announced" yes "$(contains "$err" "dry run, nothing is deleted")"
expect "totals on stderr" yes \
  "$(contains "$err" "28 kept, 9 to delete (dry run: nothing deleted), 0 package(s) not found, 0 failed API call(s)")"

echo "# --delete"
rt RC_KEEP=3 -- --package api --package worker --package lonely --delete
expect "exit 0" 0 "$rc"
expect "DELETE for exactly the delete decisions" "$(delete_decisions)" "$(deleted_ids)"
expect "the delete decisions did not change" "101 102 105 205 206 224 228 304 401" "$(delete_decisions)"
expect "DELETE path: scope, package, version id" 1 "$(calls 'DELETE orgs/acme/packages/container/worker/versions/304')"
expect "totals count the deletions" yes "$(contains "$err" "28 kept, 9 of 9 deleted")"
rt DRY_RUN=false RC_KEEP=3 -- --package worker
expect "DRY_RUN=false deletes" 304 "$(deleted_ids)"
rt DRY_RUN=false RC_KEEP=3 -- --package worker --dry-run
expect "--dry-run wins over DRY_RUN=false" "0:delete" "$(calls DELETE):$(decision 304)"
rt RC_KEEP=3 -- --package worker --delete --dry-run
expect "the last of --delete / --dry-run wins" 0 "$(calls DELETE)"

echo "# rule parameters"
rt PR_GRACE_DAYS=10 RC_KEEP=3 -- --package api
expect "PR_GRACE_DAYS=10: closed 10 d ago goes, closed 7 d ago stays" "delete keep" "$(decisions 101 102)"
rt RC_KEEP=3 RC_MIN_AGE_DAYS=61 -- --package api
expect "RC_MIN_AGE_DAYS=61: 60 d old stays" "keep delete" "$(decisions 206 224)"
page=""
for n in $(seq 1 22); do page+="$(version $((800 + n)) $((30 + n)) "3.0.0-rc.$n")"$'\n'; done
listing orgs/acme/packages/container/many/versions "$page"
rt -- --package many
expect "default RC_KEEP=20: the 21st and 22nd newest old pre-releases go" "821 822" "$(delete_decisions)"
rt RETENTION_TAG_VAR=APP_TAG RC_KEEP=3 -- --package api
expect "RETENTION_TAG_VAR=APP_TAG: APP_TAG= protects, IMAGE_TAG= no longer" "keep delete" "$(decisions 228 218)"

echo "# configuration directory"
rt CONFIG_DIR=nowhere RC_KEEP=3 -- --package api
expect "missing config dir: exit 0" 0 "$rc"
expect "missing config dir: a notice" yes "$(contains "$err" "notice: no nowhere/ directory here")"
expect "missing config dir: nothing is in use" "delete delete" "$(decisions 218 222)"
mkdir -p "$tmp/elsewhere"
RUN_DIR="$tmp/elsewhere" rt CONFIG_DIR="$W/config" RC_KEEP=3 -- --package api
expect "CONFIG_DIR from another working directory" "keep keep" "$(decisions 218 222)"

echo "# owner scope and packages"
listing users/alice/packages/container/tool/versions "$(version 501 1 0.1.0-rc.1)"
rt GITHUB_REPOSITORY=alice/tool -- --package tool
expect "user owner: users/<owner> scope" "0:1" "$rc:$(calls 'GET users/alice/packages/container/tool/versions?per_page=100 paginate')"
rt -- --owner alice --package tool
expect "--owner: packages of that owner, pull requests of --repo" "1:alice" \
  "$(calls 'GET users/alice/packages/container/tool/versions'):$(sed -n 's|^GET users/\([a-z]*\)$|\1|p' "$STUB/calls.log")"
rt RETENTION_PACKAGES=$'worker\nlonely  ' --
expect "RETENTION_PACKAGES: whitespace-separated list" "1 1" \
  "$(calls 'container/worker/versions') $(calls 'container/lonely/versions')"
rt RETENTION_PACKAGES="worker lonely" -- --package worker
expect "--package wins over RETENTION_PACKAGES" "1 0" "$(calls 'container/worker/versions') $(calls 'container/lonely/versions')"
rt -- --package worker --package worker
expect "a package given twice is swept once" 1 "$(calls 'container/worker/versions')"
if $have_yq; then
  M="$tmp/mapped"
  mkdir -p "$M/.github"
  cat >"$M/.github/affected-map.yml" <<'EOF'
schema: 1
projects:
  "libs/common": { image: false, it: false }
  "services/api": { image: true, it: true } # an image
  services/web:
    image: true
    it: false
  "tools/cli": { it: true }
docs:
  - "docs/**"
EOF
  listing orgs/acme/packages/container/team%2Fapi/versions "$(version 603 1 1.6.0-rc.2; version 601 40 pr-10-6000001)"
  listing orgs/acme/packages/container/team%2Fweb/versions "$(version 602 1 1.6.0-rc.1)"
  RUN_DIR=$M rt IMAGE_PATH_PREFIX=team/ --
  expect "affected map: exit 0" 0 "$rc"
  listed="GET orgs/acme/packages/container/team%2Fapi/versions?per_page=100 paginate"
  listed+="|GET orgs/acme/packages/container/team%2Fweb/versions?per_page=100 paginate"
  expect "affected map: image: true projects, last segment, prefix, / as %2F" "$listed" \
    "$(grep /packages/ "$STUB/calls.log" | paste -sd'|' -)"
  expect "affected map: the package column is the path below the owner" "team/api:delete team/web:keep" \
    "$(col 601 1):$(decision 601) $(col 602 1):$(decision 602)"
  RUN_DIR=$M rt IMAGE_PATH_PREFIX=team --
  expect "IMAGE_PATH_PREFIX without the trailing slash" "1 1" "$(calls 'container/team%2Fapi/') $(calls 'container/team%2Fweb/')"
  RUN_DIR=$M rt --
  expect "no prefix: api and web below the owner (web not pushed yet: skipped)" "0:1:1" \
    "$rc:$(calls 'container/api/versions'):$(calls 'container/web/versions')"
  expect "a package that is not found is reported" yes "$(contains "$err" "package web not found under acme")"
else
  echo "skip  affected-map cases (no yq: set YQ=<path to yq>)"
fi

echo "# API failures"
fail_on orgs/acme/packages/container/broken/versions "gh: Server Error (HTTP 500)"
rt RC_KEEP=3 -- --package broken --package api
expect "a listing fails: exit 1" 1 "$rc"
expect "the failed call is named with gh's message" yes \
  "$(contains "$err" "GET orgs/acme/packages/container/broken/versions failed: gh: Server Error (HTTP 500)")"
expect "the other packages are still swept" delete "$(decision 101)"
rt -- --package nothere
expect "a package that does not exist yet: skipped, exit 0" "0:yes" "$rc:$(contains "$err" "package nothere not found under acme")"
listing orgs/acme/packages/container/flaky/versions "$(version 701 30 pr-14-7000001)"
fail_on repos/acme/app/pulls/14 "gh: Bad credentials (HTTP 401)"
rt -- --package flaky
expect "a PR lookup fails: keep the version, exit 1" "1:keep:PR #14 unreadable (API error)" "$rc:$(decision 701):$(reason 701)"
expect "the failed PR lookup is reported" yes "$(contains "$err" "GET repos/acme/app/pulls/14 failed: gh: Bad credentials (HTTP 401)")"
fail_on orgs/acme/packages/container/api/versions/101 "gh: Forbidden (HTTP 403)"
rt RC_KEEP=3 -- --package api --delete
expect "a DELETE fails: exit 1, the other deletions still go out" "1:1" "$rc:$(calls 'versions/102')"
expect "the failed DELETE is reported" yes "$(contains "$err" \
  "DELETE orgs/acme/packages/container/api/versions/101 (api pr-10-aaaaaaa) failed: gh: Forbidden (HTTP 403)")"
expect "totals count it" yes "$(contains "$err" "6 of 7 deleted, 0 package(s) not found, 1 failed API call(s)")"
rm "$STUB/api/orgs/acme/packages/container/api/versions/101.fail"
fail_on users/ghost "gh: Server Error (HTTP 502)"
rt -- --owner ghost --package api
expect "the owner lookup fails: exit 1 before any listing" "1:0" "$rc:$(calls /packages/)"
answer orgs/acme/packages/container/garbled/versions 'not json'
rt -- --package garbled
expect "a listing that is not JSON: exit 1" "1:yes" \
  "$rc:$(contains "$err" "GET orgs/acme/packages/container/garbled/versions: unexpected response")"
answer orgs/acme/packages/container/odd/versions "[$(version 901 1 1.0.0-rc.1),
  {\"id\": \"../../x\", \"name\": \"-\", \"created_at\": \"$(ago 99)\", \"metadata\": {\"container\": {\"tags\": [\"pr-10-0000009\"]}}}]"
rt -- --package odd --delete
expect "a version id that is not a number: reported and skipped, never deleted" "1:0:keep" \
  "$rc:$(calls DELETE):$(decision 901)"
fail_on orgs/acme/packages/container/team%2Fbroken/versions "gh: Server Error (HTTP 500)"
rt GITHUB_ACTIONS=true -- --package team/broken
expect "in GitHub Actions: an error annotation, % escaped" yes \
  "$(contains "$err" "::error::retention.sh: GET orgs/acme/packages/container/team%252Fbroken/versions failed")"

echo "# job summary"
rt GITHUB_STEP_SUMMARY="$tmp/summary.md" RC_KEEP=3 -- --package api
summary=$(cat "$tmp/summary.md")
expect "summary: heading with the mode" yes "$(contains "$summary" "### Registry retention: dry run, nothing is deleted")"
expect "summary: table header" yes "$(contains "$summary" "| package | version | tags | age | decision | reason |")"
expect "summary: a row per version" 29 "$(grep -c "^| \`api\` |" <<<"$summary")"
expect "summary: the row of a deletion" yes \
  "$(contains "$summary" "| \`api\` | 101 | \`pr-10-aaaaaaa\` | 20 d | delete | PR #10 closed 10 d ago (grace 7 d) |")"
expect "summary: totals" yes "$(contains "$summary" "**Totals:** 22 kept, 7 to delete (dry run: nothing deleted)")"

echo "# usage"
rt -- --help
expect "--help: exit 0 and usage" "0:1" "$rc:$(grep -c '^Usage: retention.sh' <<<"$out")"
rt -- --bogus
expect "unknown argument: exit 2" 2 "$rc"
rt -- --package
expect "--package without a value: exit 2" 2 "$rc"
rt DRY_RUN=maybe -- --package api
expect "DRY_RUN not true/false: exit 2" 2 "$rc"
rt RC_KEEP=ten -- --package api
expect "RC_KEEP not a number: exit 2" 2 "$rc"
rt PR_GRACE_DAYS=-1 -- --package api
expect "negative PR_GRACE_DAYS: exit 2" 2 "$rc"
rt GITHUB_REPOSITORY= -- --package api
expect "no repository: exit 2" 2 "$rc"
rt -- --package Team/API
expect "invalid package name: exit 2" 2 "$rc"
rt -- --package ../api
expect "package path escaping the owner: exit 2" 2 "$rc"
rt RETENTION_TAG_VAR='A B' -- --package api
expect "RETENTION_TAG_VAR not a variable name: exit 2" 2 "$rc"
rt --
expect "no package and no affected map: exit 2, no API call" "2:0" "$rc:$(grep -c . "$STUB/calls.log" || true)"

echo
echo "passed $pass, failed $fail"
((fail == 0))
