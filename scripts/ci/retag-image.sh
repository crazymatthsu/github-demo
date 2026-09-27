#!/usr/bin/env bash
# retag-image.sh — point tags at an existing digest inside the registry, without pulling or rebuilding
# ("promote, never rebuild", D4 §4.5 demo stand-in for Artifactory promotion; D7 §5.7).
#
# Usage: retag-image.sh <repository>[:<tag>]@sha256:<digest> <tag>...
# For each tag: unchanged when it already points at the digest; created or moved otherwise. Version
# tags are immutable (D4 §6.2): moving one that points elsewhere is refused (exit 3). Only the
# convenience tags `main`, `latest`, `<major>` and `<major>.<minor>` may move.
# Every write is verified by resolving the tag again: the digest must be unchanged (exit 1 if not).
# Output: one line per tag, "<tag>\t<unchanged|created|moved>".
# Exit codes: 0 ok · 1 registry operation or verification failed · 2 usage · 3 immutable tag refused.
#
# Mechanism: `docker buildx imagetools create --prefer-index=false` writes the source manifest (or
# index) unchanged under the new tag, so the digest is preserved. (`crane tag` is the equivalent.)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
source_ref=$1
shift
[[ $source_ref =~ ^([^@]+)@(sha256:[0-9a-f]{64})$ ]] || { echo "retag-image.sh: '$source_ref' is not <repository>[:<tag>]@sha256:<digest>" >&2; exit 2; }
repo=${BASH_REMATCH[1]}
digest=${BASH_REMATCH[2]}
last_segment=${repo##*/}
if [[ $last_segment == *:* ]]; then
  repo=${repo%:*} # the digest wins; a tag in the source reference is informational only
fi

is_mutable() {
  [[ $1 == main || $1 == latest || $1 =~ ^[0-9]+$ || $1 =~ ^[0-9]+\.[0-9]+$ ]]
}

status=0
for tag in "$@"; do
  if [[ ! $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    echo "retag-image.sh: invalid tag '$tag'" >&2
    exit 2
  fi
  current=$("$here/resolve-image.sh" "$repo:$tag" 2>/dev/null || true)
  if [[ $current == "$repo@$digest" ]]; then
    printf '%s\tunchanged\n' "$tag"
    continue
  fi
  action=created
  if [[ -n $current ]]; then
    if ! is_mutable "$tag"; then
      echo "retag-image.sh: refusing to move immutable tag $repo:$tag (points at ${current#*@}, wanted $digest)" >&2
      status=3
      continue
    fi
    action=moved
  fi
  docker buildx imagetools create --prefer-index=false --tag "$repo:$tag" "$repo@$digest" >&2
  after=$("$here/resolve-image.sh" "$repo:$tag" 2>/dev/null || true)
  if [[ $after != "$repo@$digest" ]]; then
    echo "retag-image.sh: $repo:$tag resolves to '${after:-nothing}' after the write, expected $digest" >&2
    exit 1
  fi
  printf '%s\t%s\n' "$tag" "$action"
done
exit "$status"
