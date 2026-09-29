#!/usr/bin/env bash
# check-pins.sh - fail when a version pinned in a Dockerfile differs from the same pin in a versions file.
#
# Usage: check-pins.sh [--quiet] <Dockerfile> <versions-file> [KEY ...]
#
#   <Dockerfile>     read `ARG KEY=value` defaults (one ARG per line; surrounding quotes are dropped)
#   <versions-file>  read `KEY=value` lines (comments and blank lines ignored; surrounding quotes dropped)
#   KEY ...          the pins to compare; each must be defined in both files. Default: every key
#                    defined in both files (there must be at least one).
#   --quiet          print mismatches only
#   -h, --help       show this help
#
# Why: the CI build image and the host jobs (setup-kube-tools, laptops) must run the same tool
# versions. Both files carry the pins; this check, in the pull-request lint job, makes a bump that
# touches only one of them fail, so both move in one change.
#
# Example:
#   check-pins.sh docker/base/ci-build.Dockerfile ci/versions.env HELM_VERSION KUBECTL_VERSION KIND_VERSION
#
# Exit codes: 0 every compared pin is equal; 1 a pin differs, or a named KEY is missing from a file;
#             2 usage error, unreadable file, or nothing to compare.
set -euo pipefail

usage() { sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die_usage() {
  echo "check-pins.sh: $*" >&2
  echo "Try 'check-pins.sh --help'." >&2
  exit 2
}

quiet=false
args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -h | --help) usage; exit 0 ;;
    --quiet) quiet=true; shift ;;
    --) shift; args+=("$@"); break ;;
    -*) die_usage "unknown option $1" ;;
    *) args+=("$1"); shift ;;
  esac
done
[[ ${#args[@]} -ge 2 ]] || die_usage "need a Dockerfile and a versions file"
dockerfile=${args[0]}
versions=${args[1]}
keys=("${args[@]:2}")
for f in "$dockerfile" "$versions"; do
  [[ -f $f && -r $f ]] || die_usage "cannot read $f"
done
for key in ${keys[@]+"${keys[@]}"}; do
  [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die_usage "not a variable name: $key"
done

unquote() { # strip one pair of surrounding double or single quotes
  local v=$1
  if [[ $v =~ ^\"(.*)\"$ || $v =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
  printf '%s' "$v"
}

# KEY<TAB>value per definition, in file order (a Dockerfile may declare a key in several stages).
declare -A from_docker=() from_versions=()
while IFS=$'\t' read -r key value; do
  value=$(unquote "$value")
  if [[ -n ${from_docker[$key]+set} && ${from_docker[$key]} != "$value" ]]; then
    from_docker[$key]="${from_docker[$key]} | $value" # conflicting defaults are reported as a mismatch
  else
    from_docker[$key]=$value
  fi
done < <(sed -n 's/^[[:space:]]*ARG[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\)=\([^[:space:]]*\)[[:space:]]*$/\1\t\2/p' "$dockerfile")
while IFS=$'\t' read -r key value; do
  from_versions[$key]=$(unquote "$value") # the last definition wins, as for an env file
done < <(sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=\([^[:space:]]*\)[[:space:]]*$/\1\t\2/p' "$versions")

if [[ ${#keys[@]} -eq 0 ]]; then
  for key in "${!from_docker[@]}"; do
    if [[ -n ${from_versions[$key]+set} ]]; then keys+=("$key"); fi
  done
  [[ ${#keys[@]} -gt 0 ]] || die_usage "no key is defined in both $dockerfile and $versions"
  mapfile -t keys < <(printf '%s\n' "${keys[@]}" | sort)
fi

status=0
for key in "${keys[@]}"; do
  in_docker=${from_docker[$key]-}
  in_versions=${from_versions[$key]-}
  if [[ -z ${from_docker[$key]+set} ]]; then
    echo "MISSING  $key: no 'ARG $key=...' in $dockerfile" >&2
    status=1
  elif [[ -z ${from_versions[$key]+set} ]]; then
    echo "MISSING  $key: no '$key=...' in $versions" >&2
    status=1
  elif [[ $in_docker != "$in_versions" ]]; then
    echo "DIFFERS  $key: $dockerfile has '$in_docker', $versions has '$in_versions'" >&2
    status=1
  elif [[ $quiet != true ]]; then
    echo "ok       $key=$in_docker"
  fi
done
if [[ $status -ne 0 ]]; then
  echo "check-pins.sh: bump both files in the same change" >&2
fi
exit "$status"
