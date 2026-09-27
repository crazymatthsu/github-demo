#!/usr/bin/env bash
# set-target-host.sh — record the box an instance runs on in its flow's inventory (DL-39; D5 §6.6, D9 §6.4).
#
# Usage: set-target-host.sh <config/<env>/<flow>/targets.yml> <AppName>/<AppInstance> <host>
#   Sets `host: <host>` on the targets[] entry whose instance is <AppName>/<AppInstance> (mikefarah yq v4): the
#   entry's other keys and the file's comments stay, and in yq's own layout the edit is one line. When the file
#   declares a pool, <host> must be one of its boxes. Prints the file when its content changed, as
#   set-image-tag.sh does, and nothing when it already records that host (idempotent). write-back-tag.sh calls it
#   with the placements scripts/pool-deploy.sh resolved (WRITE_BACK_PLACEMENTS).
# Exit codes: 0 ok (also when nothing changed) · 1 yq missing or failed · 2 usage · 4 file missing, no single entry
#   for the instance, or a host outside the file's pool.
set -euo pipefail

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
file=$1
instance=$2
host=$3
[[ $instance =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] ||
  { echo "set-target-host.sh: '$instance' is not <AppName>/<AppInstance> (the flow is the file's)" >&2; exit 2; }
[[ $host =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
  { echo "set-target-host.sh: '$host' is not a lower-case DNS name or IPv4 address" >&2; exit 2; }
[[ -f $file ]] || { echo "set-target-host.sh: $file not found" >&2; exit 4; }
yq --version 2>/dev/null | grep -q mikefarah ||
  { echo "set-target-host.sh: needs mikefarah yq v4 on PATH (as on GitHub-hosted runners)" >&2; exit 1; }

export INSTANCE=$instance HOST=$host
count=$(yq '[(.targets // [])[] | select(.instance == strenv(INSTANCE))] | length' "$file")
[[ $count -eq 1 ]] || { echo "set-target-host.sh: $file has $count target(s) for $instance, expected one" >&2; exit 4; }
if [[ $(yq '.pool | type' "$file") == '!!map' && $(yq '(.pool.hosts // []) | any_c(. == strenv(HOST))' "$file") != true ]]; then
  echo "set-target-host.sh: $host is not a box of the pool in $file" >&2
  exit 4
fi
[[ $(yq '.targets[] | select(.instance == strenv(INSTANCE)) | .host // ""' "$file") != "$host" ]] || exit 0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cp "$file" "$tmp"
yq -i '(.targets[] | select(.instance == strenv(INSTANCE))).host = strenv(HOST)' "$tmp"
cat "$tmp" > "$file" # keeps the file's mode and ownership
echo "$file"
