#!/usr/bin/env bash
# junit-summary.sh: Markdown summary of JUnit XML results for the GitHub job summary.
#
# Usage: junit-summary.sh <title> [<search root>...]        (default root: .)
# Finds the files matching JUNIT_GLOB (default 'TEST-*.xml': Gradle, Maven surefire / failsafe; use '*.xml'
# for pytest --junitxml, jest-junit, gotestsum) under the roots, sums tests / failures / errors / skipped per
# directory, lists the failing suites and appends it all to $GITHUB_STEP_SUMMARY (stdout when unset).
# Reporting only: exit 0 always (the test step owns the verdict), 2 on usage errors.
# Needs bash 3.2+, find, grep, sed and awk only, so it also runs inside a minimal build container.
# (Template of the skill gha-ephemeral-test-envs.)
set -uo pipefail

if [[ $# -lt 1 || $1 == -h || $1 == --help ]]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  [[ $# -ge 1 ]] && exit 0
  exit 2
fi
title=$1
shift
roots=("$@")
[[ ${#roots[@]} -gt 0 ]] || roots=(.)
out=${GITHUB_STEP_SUMMARY:-/dev/stdout}
glob=${JUNIT_GLOB:-TEST-*.xml}

attr() { # attr <name> <tag text>: the numeric attribute, 0 when absent
  local v
  v=$(sed -n "s/.* $1=\"\([0-9][0-9]*\)\".*/\1/p" <<<"$2" | head -n 1)
  printf '%s' "${v:-0}"
}

# One row per <testsuite> element: dir <TAB> tests <TAB> failures <TAB> errors <TAB> skipped <TAB> suite name
rows=$(
  find "${roots[@]}" -type f -name "$glob" -not -path '*/node_modules/*' -print 2>/dev/null | sort | while IFS= read -r file; do
    dir=$(dirname "$file")
    dir=${dir#./}
    grep -o '<testsuite [^>]*' "$file" 2>/dev/null | while IFS= read -r tag; do
      name=$(sed -n 's/.* name="\([^"]*\)".*/\1/p' <<<"$tag" | head -n 1)
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$dir" "$(attr tests "$tag")" "$(attr failures "$tag")" \
        "$(attr errors "$tag")" "$(attr skipped "$tag")" "${name:-$(basename "$file")}"
    done
  done
)

{
  echo "### ${title}"
  echo ""
  if [[ -z $rows ]]; then
    echo "No JUnit results found (${glob} under ${roots[*]})."
  else
    awk -F '\t' '
      {
        if (!($1 in tests)) order[++n] = $1
        tests[$1] += $2; fail[$1] += $3; err[$1] += $4; skip[$1] += $5
        t += $2; f += $3; e += $4; s += $5
        if ($3 + $4 > 0) bad[++nb] = $1 ": " $6
      }
      END {
        printf "%d tests, %d failures, %d errors, %d skipped: %s\n\n", t, f, e, s, (f + e > 0 ? "**failed**" : "passed")
        print "| results directory | tests | failures | errors | skipped |"
        print "|---|---:|---:|---:|---:|"
        for (i = 1; i <= n; i++) {
          d = order[i]
          printf "| `%s` | %d | %d | %d | %d |\n", d, tests[d], fail[d], err[d], skip[d]
        }
        if (nb > 0) {
          print ""
          print "Failing suites:"
          for (i = 1; i <= nb; i++) printf "- `%s`\n", bad[i]
        }
      }' <<<"$rows"
  fi
  echo ""
} >>"$out"
exit 0
