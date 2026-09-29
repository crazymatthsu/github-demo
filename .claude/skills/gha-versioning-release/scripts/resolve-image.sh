#!/usr/bin/env bash
# resolve-image.sh — resolve an image reference to <repository>@sha256:<digest> without pulling it.
#
# Usage: resolve-image.sh <image-ref>
#   <image-ref>  repository:tag, repository@sha256:<digest> or repository:tag@sha256:<digest>
# Prints <repository>@sha256:<digest>. Pass digests, not tags, between CI jobs: a tag can move, a digest
# cannot. A digest in the reference wins over its tag; the registry is still asked, which proves it exists.
# Methods, in order: the registry through `docker buildx imagetools inspect` (no pull, no daemon; single
# manifests and multi-platform indexes alike), then the RepoDigests of the local image store (after a push
# or pull on this machine).
# Needs: the docker CLI with the buildx plugin, logged in to the registry. No jq.
# Exit codes: 0 resolved · 1 not found or not accessible · 2 usage
set -euo pipefail

show_help() { sed -n '2,/^# Exit codes/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }
case ${1:-} in
  -h | --help) show_help; exit 0 ;;
esac
if [[ $# -ne 1 || -z $1 || $1 == -* ]]; then
  echo "resolve-image.sh: expected exactly one image reference" >&2
  echo "Run 'resolve-image.sh --help' for usage." >&2
  exit 2
fi
ref=$1

# The repository is the reference without "@digest" and without ":tag" (a ':' after the last '/'), so a
# registry port such as localhost:5000/app stays part of it.
repo=${ref%%@*}
last_segment=${repo##*/}
if [[ $last_segment == *:* ]]; then repo=${repo%:*}; fi
query=$ref
if [[ $ref == *@sha256:* ]]; then query="$repo@${ref##*@}"; fi

digest_re='^sha256:[0-9a-f]{64}$'
digest=""
if docker buildx version >/dev/null 2>&1; then
  # '{{json .Manifest}}', not '{{.Manifest.Digest}}': some buildx versions (v0.31.1 seen) print their
  # human-readable summary for any template that starts with '{{.Manifest'. The first "digest" key of the
  # JSON is the top-level one (for an index, the platform manifests' digests come after it).
  digest=$(docker buildx imagetools inspect "$query" --format '{{json .Manifest}}' 2>/dev/null |
    grep -o '"digest":[[:space:]]*"sha256:[0-9a-f]\{64\}"' | head -n 1 | grep -o 'sha256:[0-9a-f]\{64\}' || true)
fi
if [[ ! $digest =~ $digest_re ]]; then
  repo_re=${repo//./\\.}
  digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$query" 2>/dev/null |
    sed -n "s|^${repo_re}@\(sha256:[0-9a-f]\{64\}\)\$|\1|p" | head -n 1 || true)
fi
if [[ ! $digest =~ $digest_re ]]; then
  echo "resolve-image.sh: $ref not found (or not accessible with the current registry login)" >&2
  exit 1
fi
echo "$repo@$digest"
