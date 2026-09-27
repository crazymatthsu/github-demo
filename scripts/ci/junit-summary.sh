#!/usr/bin/env bash
# junit-summary.sh — Markdown summary of Gradle JUnit XML results for the job summary (D7 §6.9).
#
# Usage: junit-summary.sh <title> [<search-root>...]      (default search root: .)
# Reads **/build/test-results/<task>/TEST-*.xml, appends one table row per project and task to
# $GITHUB_STEP_SUMMARY (stdout when unset) and lists the failing suites. Reporting only: exit 0 always.
# Needs bash, find, grep and sed only, so it also runs inside the ci-build container.
set -uo pipefail

title=${1:-Test results}
shift || true
roots=("$@")
[[ ${#roots[@]} -gt 0 ]] || roots=(.)
out=${GITHUB_STEP_SUMMARY:-/dev/stdout}

declare -A t_tests=() t_fail=() t_err=() t_skip=()
keys=()
failed_suites=()
all_tests=0 all_fail=0 all_err=0 all_skip=0

attr() { # attr <name> <tag-text>
  sed -n "s/.* $1=\"\([0-9][0-9]*\)\".*/\1/p" <<<"$2" | head -n 1
}

while IFS= read -r -d '' file; do
  head_tag=$(grep -m 1 -o '<testsuite [^>]*' "$file" 2>/dev/null) || continue
  task=$(basename "$(dirname "$file")")
  project=${file%%/build/test-results/*}
  project=${project#./}
  key="${project:-.} (${task})"
  tests=$(attr tests "$head_tag"); fail=$(attr failures "$head_tag")
  err=$(attr errors "$head_tag"); skip=$(attr skipped "$head_tag")
  tests=${tests:-0} fail=${fail:-0} err=${err:-0} skip=${skip:-0}
  if [[ -z ${t_tests[$key]+set} ]]; then
    keys+=("$key"); t_tests[$key]=0 t_fail[$key]=0 t_err[$key]=0 t_skip[$key]=0
  fi
  t_tests[$key]=$((t_tests[$key] + tests)); t_fail[$key]=$((t_fail[$key] + fail))
  t_err[$key]=$((t_err[$key] + err)); t_skip[$key]=$((t_skip[$key] + skip))
  all_tests=$((all_tests + tests)) all_fail=$((all_fail + fail)) all_err=$((all_err + err)) all_skip=$((all_skip + skip))
  if (( fail + err > 0 )); then
    suite=$(sed -n 's/.* name="\([^"]*\)".*/\1/p' <<<"${head_tag%% tests=*}" | head -n 1)
    failed_suites+=("${key}: ${suite:-$(basename "$file")}")
  fi
done < <(find "${roots[@]}" -path '*/build/test-results/*' -name 'TEST-*.xml' -print0 2>/dev/null)

{
  echo "### ${title}"
  echo ""
  if [[ ${#keys[@]} -eq 0 ]]; then
    echo "No JUnit results found."
  else
    status="passed"
    (( all_fail + all_err > 0 )) && status="**failed**"
    echo "${all_tests} tests, ${all_fail} failures, ${all_err} errors, ${all_skip} skipped — ${status}"
    echo ""
    echo "| project (task) | tests | failures | errors | skipped |"
    echo "|---|---:|---:|---:|---:|"
    for key in "${keys[@]}"; do
      echo "| \`${key}\` | ${t_tests[$key]} | ${t_fail[$key]} | ${t_err[$key]} | ${t_skip[$key]} |"
    done
    if [[ ${#failed_suites[@]} -gt 0 ]]; then
      echo ""
      echo "Failing suites:"
      for suite in "${failed_suites[@]}"; do echo "- \`${suite}\`"; done
    fi
  fi
  echo ""
} >> "$out"
exit 0
