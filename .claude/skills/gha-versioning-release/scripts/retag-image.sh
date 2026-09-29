#!/usr/bin/env bash
# retag-image.sh — point tags at a digest that already exists in the registry: no pull, no rebuild.
# "Promote, never rebuild": the tested manifest is written unchanged under each new tag.
#
# Usage: retag-image.sh [--to <repository>] <repository>[:<tag>]@sha256:<digest> <tag>...
#   --to <repository>  write the tags into another repository (a promotion path such as <registry>/qa/app,
#                      or another registry); the manifest and its blobs are copied, the digest stays the same
# For each tag: "unchanged" when it already points at the digest, else "created" or "moved".
# Version tags are immutable: a tag that points at another digest is refused (exit 3, after the other tags
# are done) unless it matches RETAG_MUTABLE_REGEX, default '^(main|latest|[0-9]+|[0-9]+\.[0-9]+)$' (the
# moving tags main, latest, X and X.Y). A trunk with another name needs its name in that regex.
# Every write is verified by resolving the tag again: it must give the source digest (exit 1 otherwise).
# Output: one "<tag><TAB><unchanged|created|moved>" line per tag written or confirmed; refusals and
# registry progress go to stderr.
# Mechanism: `docker buildx imagetools create --prefer-index=false` (without the flag a single-platform
# manifest is wrapped in a new index with a new digest); `crane tag` / `crane copy` are equivalents.
# Needs: the docker CLI with buildx, a registry login with push rights, resolve-image.sh next to this file.
# Exit codes: 0 ok · 1 a registry operation or a verification failed · 2 usage · 3 an immutable tag refused
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
show_help() { sed -n '2,/^# Exit codes/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }
usage_error() {
  echo "retag-image.sh: $*" >&2
  echo "Run 'retag-image.sh --help' for usage." >&2
  exit 2
}

case ${1:-} in
  -h | --help) show_help; exit 0 ;;
esac
target=""
if [[ ${1:-} == --to ]]; then
  [[ $# -ge 2 ]] || usage_error "--to needs a repository"
  target=$2
  shift 2
fi
[[ $# -ge 2 ]] || usage_error "expected a source reference and at least one tag"
source_ref=$1
shift
[[ $source_ref =~ ^([^@]+)@(sha256:[0-9a-f]{64})$ ]] ||
  usage_error "'$source_ref' is not <repository>[:<tag>]@sha256:<digest>"
repo=${BASH_REMATCH[1]}
digest=${BASH_REMATCH[2]}
last_segment=${repo##*/}
if [[ $last_segment == *:* ]]; then repo=${repo%:*}; fi # the digest wins; a tag in the source is informational
target=${target:-$repo}
[[ -n $target && $target != *@* && ${target##*/} != *:* ]] || usage_error "--to takes a repository, without tag or digest"
for tag in "$@"; do
  [[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || usage_error "invalid tag '$tag'"
done
default_mutable='^(main|latest|[0-9]+|[0-9]+\.[0-9]+)$'
mutable_re=${RETAG_MUTABLE_REGEX:-$default_mutable}

status=0
for tag in "$@"; do
  current=$("$here/resolve-image.sh" "$target:$tag" 2>/dev/null || true)
  if [[ $current == "$target@$digest" ]]; then
    printf '%s\tunchanged\n' "$tag"
    continue
  fi
  action=created
  if [[ -n $current ]]; then
    if [[ ! $tag =~ $mutable_re ]]; then
      echo "retag-image.sh: refusing to move immutable tag $target:$tag (points at ${current#*@}, wanted $digest)" >&2
      status=3
      continue
    fi
    action=moved
  fi
  if ! docker buildx imagetools create --prefer-index=false --tag "$target:$tag" "$repo@$digest" >&2; then
    echo "retag-image.sh: writing $target:$tag failed" >&2
    exit 1
  fi
  after=$("$here/resolve-image.sh" "$target:$tag" 2>/dev/null || true)
  if [[ $after != "$target@$digest" ]]; then
    echo "retag-image.sh: $target:$tag resolves to '${after:-nothing}' after the write, expected $digest" >&2
    exit 1
  fi
  printf '%s\t%s\n' "$tag" "$action"
done
exit "$status"
