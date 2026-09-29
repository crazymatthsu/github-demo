#!/usr/bin/env bash
# lint-pipeline.sh — run the pipeline linters locally, the same set the PR lint job runs.
#
# Usage: lint-pipeline.sh [--install] [--strict] [--repo <dir>]
#   --install   create a venv with the pinned linters (hadolint-bin, shellcheck-py, actionlint-py) under
#               ${LINT_VENV:-${TMPDIR:-/tmp}/lint-pipeline-venv} and put it first on PATH
#   --strict    a missing linter is an error (exit 3) instead of a skipped check
#   --repo      repository root to lint (default: the git top level of the current directory)
#
# Checks, each skipped with a notice when its tool is missing (unless --strict):
#   actionlint   .github/workflows/*.yml, with ShellCheck on every run: block
#   ShellCheck   every tracked *.sh at severity warning
#   hadolint     every tracked Dockerfile / *.Dockerfile
#   yaml         every tracked .github/**/*.yml and *.yaml parses (python3 + PyYAML, or yq v4)
#   tests        every scripts/test/*-test.sh runs green
#
# Exit codes: 0 clean · 1 findings · 2 usage · 3 a linter is missing and --strict was given.
set -euo pipefail

install=false strict=false repo=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --install) install=true ;;
    --strict) strict=true ;;
    --repo) repo=${2:?--repo needs a directory}; shift ;;
    -h | --help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "lint-pipeline.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z $repo ]]; then
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "lint-pipeline.sh: not in a git repository (use --repo)" >&2; exit 2; }
fi
cd "$repo"

if $install; then
  venv=${LINT_VENV:-${TMPDIR:-/tmp}/lint-pipeline-venv}
  if [[ ! -x $venv/bin/actionlint ]]; then
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet --disable-pip-version-check \
      hadolint-bin==2.15.1 shellcheck-py==0.11.0.1 actionlint-py==1.7.12.25
  fi
  PATH="$venv/bin:$PATH"
fi

status=0 missing=0
section() { printf '\n== %s\n' "$1"; }
skip() {
  echo "skipped: $1 not found${2:+ ($2)}"
  missing=1
}
fail() {
  status=1
}

section actionlint
if [[ -d .github/workflows ]]; then
  if command -v actionlint >/dev/null 2>&1; then
    actionlint -no-color || fail
  else
    skip actionlint "pip install actionlint-py, or run with --install"
  fi
else
  echo "no .github/workflows directory"
fi

section shellcheck
mapfile -t scripts < <(git ls-files -- '*.sh')
if [[ ${#scripts[@]} -eq 0 ]]; then
  echo "no shell scripts"
elif command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning "${scripts[@]}" || fail
else
  skip shellcheck "pip install shellcheck-py, or run with --install"
fi

section hadolint
mapfile -t dockerfiles < <(git ls-files -- 'Dockerfile' '**/Dockerfile' '*.Dockerfile' '**/*.Dockerfile')
if [[ ${#dockerfiles[@]} -eq 0 ]]; then
  echo "no Dockerfiles"
elif command -v hadolint >/dev/null 2>&1; then
  config=()
  [[ -f .hadolint.yaml ]] && config=(--config .hadolint.yaml)
  hadolint "${config[@]}" "${dockerfiles[@]}" || fail
else
  skip hadolint "pip install hadolint-bin, or run with --install"
fi

section yaml
mapfile -t yamls < <(git ls-files -- '.github/*.yml' '.github/*.yaml' '.github/**/*.yml' '.github/**/*.yaml')
if [[ ${#yamls[@]} -eq 0 ]]; then
  echo "no YAML under .github"
elif python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 - "${yamls[@]}" <<'PY' || fail
import sys, yaml
bad = 0
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            list(yaml.safe_load_all(fh))
    except yaml.YAMLError as err:
        bad = 1
        print(f"{path}: {err}")
print(f"{len(sys.argv) - 1} files parsed" if not bad else "YAML errors found")
sys.exit(bad)
PY
elif command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q 'mikefarah'; then
  for file in "${yamls[@]}"; do
    yq eval 'true' "$file" >/dev/null || { echo "$file: does not parse"; fail; }
  done
else
  skip "PyYAML or yq v4" "pip install pyyaml"
fi

section tests
shopt -s nullglob
tests=(scripts/test/*-test.sh)
if [[ ${#tests[@]} -eq 0 ]]; then
  echo "no scripts/test/*-test.sh"
else
  for test in "${tests[@]}"; do
    echo "-- $test"
    bash "$test" || fail
  done
fi

echo
if [[ $missing -eq 1 && $strict == true ]]; then
  echo "lint-pipeline.sh: a linter is missing (--strict)"
  exit 3
fi
if [[ $status -ne 0 ]]; then
  echo "lint-pipeline.sh: findings above"
  exit 1
fi
echo "lint-pipeline.sh: clean"
