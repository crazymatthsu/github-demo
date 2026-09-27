#!/usr/bin/env bash
# resolve-image.sh — resolve an image reference to <repository>@<digest> without pulling it.
#
# Usage: resolve-image.sh <image-ref>
#   <image-ref>  repo:tag, repo@sha256:..., or repo:tag@sha256:...
# Prints the digest-pinned reference (D4 §6.2: digests, not tags, flow between CI jobs).
# Exit codes: 0 resolved · 1 image missing or not accessible · 2 usage.
#
# Order of methods: registry query through `docker buildx imagetools inspect` (no pull; works for
# single manifests and indexes), then the local image store's RepoDigests (after a push or pull).
# Needs only the docker CLI (+ buildx plugin); no jq, so it also runs inside the ci-build container.
set -euo pipefail

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[[ $# -eq 1 && -n $1 && $1 != -* ]] || usage
ref=$1

# Repository = the reference without "@digest" and without ":tag" (a ':' after the last '/').
repo=${ref%%@*}
last_segment=${repo##*/}
if [[ $last_segment == *:* ]]; then
  repo=${repo%:*}
fi

# A digest wins over a tag: query repo@digest (this also proves the digest exists in the registry).
query=$ref
if [[ $ref == *@sha256:* ]]; then
  query="${repo}@${ref##*@}"
fi

digest=""
if docker buildx version >/dev/null 2>&1; then
  digest=$(docker buildx imagetools inspect "$query" --format '{{.Manifest.Digest}}' 2>/dev/null || true)
fi
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$query" 2>/dev/null |
    sed -n "s|^${repo}@\(sha256:[0-9a-f]\{64\}\)$|\1|p" | head -n 1 || true)
fi
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "resolve-image.sh: ${ref} not found (or not accessible with the current registry login)" >&2
  exit 1
fi
echo "${repo}@${digest}"
