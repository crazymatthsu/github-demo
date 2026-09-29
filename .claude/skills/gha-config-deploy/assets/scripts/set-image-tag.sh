#!/usr/bin/env bash
# set-image-tag.sh — the edit of a bump pull request: pin a release (tag and digest) on every instance of the
# released apps in ONE env of the config tree, or copy what another env runs. Prints each changed file, one per
# line, and nothing when the env already runs it (idempotent). Part of the gha-config-deploy skill; copy it to
# scripts/ci/set-image-tag.sh. release.yml's bump job (skill gha-versioning-release) and deploy.yml's next-env
# bump call it.
#
# Usage:
#   set-image-tag.sh [--apps "<app> ..."] <env dir> <tag> [<app>...]
#       Every instance of each <app> (every app of the env when none is given), <env dir>/<flow>/<app>/<instance>/:
#         values.yaml   image.tag: "<tag>", and image.digest: sha256:... when IMAGE_DIGESTS names the app (a
#                       digest left from an earlier release is removed when it does not); the file must already
#                       hold an `image` mapping
#         compose.env   <TAG_VAR>=<tag>, when the file exists
#   set-image-tag.sh --from <source env dir> [--apps "<app> ..."] <env dir> [<app>...]
#       Each app's image.tag and image.digest as <source env dir> records them (every instance of the app there
#       must agree; an app that records no tag there is skipped), set the same way in <env dir>: the next env gets
#       exactly what the previous one runs, never recomputed.
#   <env dir> is <config>/<env>, e.g. config/prod. <app> is the <app> directory level of the tree, named like the
#   last path segment of its image (ghcr.io/acme/api -> <env dir>/<flow>/api/). app-common/ and `_*` / `.*`
#   directories are layers, never instances. An app without an instance in <env dir> is skipped (stderr note).
#   --apps takes the apps as one space-separated argument (release.yml's APPS), in addition to the positional ones.
#
# The chart must render `<repository>:<tag>@<digest>` when image.digest is set (config-tree.md section 8).
#
# Environment [default]:
#   IMAGE_DIGESTS []            JSON object image -> reference pinned by digest, e.g. release.yml's `images` output
#                               {"api": "ghcr.io/acme/api:sha-1a2b3c4@sha256:<64 hex>"}; keys match an app by their
#                               last path segment
#   SET_IMAGE_TAG_VAR [IMAGE_TAG]   the tag variable in compose.env
#   SET_IMAGE_TAG_YQ [yq]       mikefarah yq v4 (preinstalled on GitHub-hosted runners)
#
# Exit codes: 0 done (changed or not) · 1 yq failure, or the source env runs two versions of one app · 2 usage ·
#   4 config tree error (a missing env dir, an instance values.yaml without an `image` mapping)
# Needs bash 3.2+, awk, jq (for IMAGE_DIGESTS) and mikefarah yq v4.
set -euo pipefail

readonly EXIT_FAILED=1 EXIT_USAGE=2 EXIT_CONFIG=4
readonly TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
readonly TOKEN_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
note() { printf 'set-image-tag: %s\n' "$*" >&2; }
die() {
  local code=$1
  shift
  printf 'set-image-tag: error: %s\n' "$*" >&2
  exit "$code"
}

YQ=${SET_IMAGE_TAG_YQ:-yq}
TAG_VAR=${SET_IMAGE_TAG_VAR:-IMAGE_TAG}

source_dir='' apps_opt=''
while [ $# -gt 0 ]; do
  case $1 in
    -h | --help) usage; exit 0 ;;
    --from | --apps)
      if [ $# -lt 2 ] || [ -z "$2" ]; then die "$EXIT_USAGE" "$1 needs a value (see --help)"; fi
      if [ "$1" = --from ]; then source_dir=${2%/}; else apps_opt=$2; fi
      shift 2
      ;;
    --) shift; break ;;
    -*) die "$EXIT_USAGE" "unknown option $1 (see --help)" ;;
    *) break ;;
  esac
done
if [ -n "$source_dir" ]; then
  [ $# -ge 1 ] || die "$EXIT_USAGE" "the env dir is required (see --help)"
  env_dir=${1%/}
  shift
  tag=''
else
  [ $# -ge 2 ] || die "$EXIT_USAGE" "expected <env dir> <tag> [<app>...] (see --help)"
  env_dir=${1%/}
  tag=$2
  shift 2
  [[ $tag =~ $TAG_RE ]] || die "$EXIT_USAGE" "'$tag' is not a valid image tag"
fi
set -f # --apps is a space-separated list: split it, never glob it
# shellcheck disable=SC2086
set -- "$@" $apps_opt
set +f
for app in "$@"; do
  [[ $app =~ $TOKEN_RE ]] || die "$EXIT_USAGE" "'$app' is not an app name (lower-case kebab)"
done
[[ $TAG_VAR =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$EXIT_USAGE" "SET_IMAGE_TAG_VAR '$TAG_VAR' is not a variable name"
[ -d "$env_dir" ] || die "$EXIT_CONFIG" "env dir $env_dir not found"
if [ -n "$source_dir" ]; then
  [ -d "$source_dir" ] || die "$EXIT_CONFIG" "source env dir $source_dir not found"
  [ "$source_dir" != "$env_dir" ] || die "$EXIT_USAGE" "source and target are the same env dir"
fi
"$YQ" --version 2>/dev/null | grep -q mikefarah || die "$EXIT_FAILED" "mikefarah yq v4 is needed as '$YQ' (SET_IMAGE_TAG_YQ)"

# The instance directories of <app> in <dir>, one per line (flows and instances that are layers are skipped).
instances_of() { # <dir> <app>
  local dir=$1 app=$2 path flow inst
  for path in "$dir"/*/"$app"/*/; do
    [ -d "$path" ] || continue
    path=${path%/}
    inst=${path##*/}
    flow=${path%/*/*}
    flow=${flow##*/}
    case $inst in app-common | _* | .*) continue ;; esac
    case $flow in _* | .*) continue ;; esac
    printf '%s\n' "$path"
  done
}

# Every app that has at least one instance in <dir>.
apps_of() { # <dir>
  local path app
  for path in "$1"/*/*/; do
    [ -d "$path" ] || continue
    path=${path%/}
    app=${path##*/}
    case ${path%/*} in */_* | */.*) continue ;; esac
    [ -n "$(instances_of "$1" "$app")" ] && printf '%s\n' "$app"
  done | sort -u
}

# IMAGE_DIGESTS as app -> sha256:..., validated.
digest_for() { # <app>: prints the digest or nothing
  [ -n "${IMAGE_DIGESTS:-}" ] || return 0
  jq -r --arg app "$1" 'to_entries[] | select((.key | split("/") | last) == $app) | .value' <<<"$IMAGE_DIGESTS" |
    head -n 1 | sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\)$/\1/p'
}
if [ -n "${IMAGE_DIGESTS:-}" ]; then
  command -v jq >/dev/null 2>&1 || die "$EXIT_FAILED" "jq is needed to read IMAGE_DIGESTS"
  jq -e 'type == "object" and all(.[]; type == "string" and test("@sha256:[0-9a-f]{64}$"))' <<<"$IMAGE_DIGESTS" >/dev/null 2>&1 ||
    die "$EXIT_USAGE" "IMAGE_DIGESTS must be a JSON object image -> <reference>@sha256:<64 hex>"
fi

# What <dir> records for <app>: "<tag> <digest>" (digest '-' when none); fails when the instances disagree.
recorded_release() { # <dir> <app>
  local path values seen='' current
  while IFS= read -r path; do
    values=$path/values.yaml
    [ -f "$values" ] || continue
    current=$("$YQ" '(.image.tag // "") + " " + (.image.digest // "-")' "$values") ||
      die "$EXIT_FAILED" "$values does not parse"
    case $current in " "*) continue ;; esac # no tag recorded: never deployed there
    if [ -z "$seen" ]; then
      seen=$current
    elif [ "$seen" != "$current" ]; then
      die "$EXIT_FAILED" "$1 runs two releases of $2 ('$seen' and '$current' in $values): align them first"
    fi
  done <<EOF
$(instances_of "$1" "$2")
EOF
  printf '%s' "$seen"
}

# Sets tag (and digest, or removes a stale one) in one instance directory; prints the files that changed.
set_instance() { # <instance dir> <tag> <digest or empty>
  local dir=$1 want_tag=$2 want_digest=$3 values=$1/values.yaml env_file=$1/compose.env tmp current
  if [ -f "$values" ]; then
    [ "$("$YQ" '.image | tag' "$values")" = '!!map' ] ||
      die "$EXIT_CONFIG" "$values has no image mapping (add image: {repository: ..., tag: \"\"})"
    current=$("$YQ" '(.image.tag // "") + " " + (.image.digest // "")' "$values")
    if [ "$current" != "$want_tag $want_digest" ]; then
      TAG=$want_tag "$YQ" -i '.image.tag = strenv(TAG)' "$values"
      if [ -n "$want_digest" ]; then
        DIGEST=$want_digest "$YQ" -i '.image.digest = strenv(DIGEST)' "$values"
      else
        "$YQ" -i 'del(.image.digest)' "$values"
      fi
      printf '%s\n' "$values"
    fi
  fi
  if [ -f "$env_file" ]; then
    tmp=$(mktemp)
    awk -v var="$TAG_VAR" -v tag="$want_tag" '
      index($0, var "=") == 1 { if (!done) { print var "=" tag; done = 1 }; next }
      { print }
      END { if (!done) print var "=" tag }
    ' "$env_file" >"$tmp"
    if cmp -s "$env_file" "$tmp"; then
      rm -f "$tmp"
    else
      cat "$tmp" >"$env_file" # keeps the file's mode
      rm -f "$tmp"
      printf '%s\n' "$env_file"
    fi
  fi
}

if [ $# -gt 0 ]; then
  apps=$(printf '%s\n' "$@" | sort -u)
elif [ -n "$source_dir" ]; then
  apps=$(apps_of "$source_dir")
else
  apps=$(apps_of "$env_dir")
fi

for app in $apps; do
  targets=$(instances_of "$env_dir" "$app")
  if [ -z "$targets" ]; then
    note "$env_dir has no instance of $app: skipped"
    continue
  fi
  if [ -n "$source_dir" ]; then
    release=$(recorded_release "$source_dir" "$app")
    if [ -z "$release" ]; then
      note "$source_dir records no release of $app: skipped"
      continue
    fi
    app_tag=${release%% *}
    app_digest=${release#* }
    [ "$app_digest" != - ] || app_digest=''
    [[ $app_tag =~ $TAG_RE ]] || die "$EXIT_CONFIG" "$source_dir records the invalid tag '$app_tag' for $app"
  else
    app_tag=$tag
    app_digest=$(digest_for "$app")
  fi
  if [ -n "$app_digest" ] && [[ ! $app_digest =~ $DIGEST_RE ]]; then
    die "$EXIT_CONFIG" "invalid digest '$app_digest' for $app"
  fi
  while IFS= read -r dir; do
    set_instance "$dir" "$app_tag" "$app_digest"
  done <<EOF
$targets
EOF
done
