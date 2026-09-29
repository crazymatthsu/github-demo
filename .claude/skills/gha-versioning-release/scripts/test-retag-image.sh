#!/usr/bin/env bash
# test-retag-image.sh — plain-bash tests for resolve-image.sh and retag-image.sh with a stubbed `docker`.
#
# Usage: test-retag-image.sh [<directory holding resolve-image.sh and retag-image.sh>]
#   Default: the directory of this file, else ../ci (a repository with scripts/ci/ and scripts/test/).
# The stub keeps a registry in files (repository -> tags -> digests, manifests per repository) and behaves
# like `docker buildx imagetools`: create without --prefer-index=false wraps a single manifest in a new
# index (new digest), and a '{{.Manifest...}}' template prints the human-readable summary as buildx v0.31
# does. No daemon, registry or network is needed.
# Needs: bash, sha256sum.
# Exit codes: 0 all cases passed · 1 a case failed · 2 usage (scripts not found)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case ${1:-} in
  -h | --help) sed -n '2,/^# Exit codes/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
dir=${1:-}
if [[ -z $dir ]]; then
  for candidate in "$here" "$here/../ci"; do
    if [[ -f $candidate/retag-image.sh ]]; then dir=$candidate; break; fi
  done
fi
[[ -n $dir && -f $dir/retag-image.sh && -f $dir/resolve-image.sh ]] ||
  { echo "test-retag-image.sh: resolve-image.sh / retag-image.sh not found; pass their directory" >&2; exit 2; }
resolve="$dir/resolve-image.sh"
retag="$dir/retag-image.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export STUB="$tmp/registry"
mkdir -p "$tmp/bin" "$STUB"

cat >"$tmp/bin/docker" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub docker: the subset of commands resolve-image.sh and retag-image.sh use, against files in $STUB.
set -euo pipefail
echo "docker $*" >>"$STUB/calls.log"
enc() { printf '%s' "${1//\//%}"; }
split_ref() { # split_ref <ref> -> sets r_repo, r_tag, r_digest
  local ref=$1 last
  r_digest="" r_tag=""
  if [[ $ref == *@sha256:* ]]; then r_digest=${ref##*@}; ref=${ref%@*}; fi
  last=${ref##*/}
  if [[ $last == *:* ]]; then r_tag=${last##*:}; ref=${ref%:*}; fi
  r_repo=$ref
}
lookup() { # lookup <ref> -> sets r_repo and found (the digest), or fails
  split_ref "$1"
  local d
  d="$STUB/repos/$(enc "$r_repo")"
  found=""
  if [[ -n $r_digest ]]; then
    [[ -f $d/manifests/$r_digest ]] || return 1
    found=$r_digest
  else
    [[ -f $d/tags/$r_tag ]] || return 1
    found=$(cat "$d/tags/$r_tag")
  fi
}
case "$1 ${2:-} ${3:-}" in
  "buildx version "*) echo "github.com/docker/buildx v0.0.0-stub"; exit 0 ;;
  "buildx imagetools inspect")
    ref=$4 format=""
    [[ ${5:-} == --format ]] && format=${6:-}
    lookup "$ref" || { echo "ERROR: $ref: not found" >&2; exit 1; }
    digest=$found
    kind=$(cat "$STUB/repos/$(enc "$r_repo")/manifests/$digest")
    if [[ $format == '{{.Manifest'* ]]; then # buildx v0.31: any '{{.Manifest...' template prints the summary
      printf 'Name:      %s\nMediaType: application/vnd.oci.image.%s.v1+json\nDigest:    %s\n' "$ref" "$kind" "$digest"
    elif [[ $format == '{{json .Manifest}}' ]]; then
      if [[ $kind == index ]]; then
        printf '{\n  "schemaVersion": 2,\n  "mediaType": "application/vnd.oci.image.index.v1+json",\n  "digest": "%s",\n  "size": 500,\n  "manifests": [\n    {\n      "mediaType": "application/vnd.oci.image.manifest.v1+json",\n      "digest": "sha256:%s",\n      "size": 400\n    }\n  ]\n}\n' "$digest" "$(printf 'c%.0s' {1..64})"
      else
        printf '{\n  "mediaType": "application/vnd.oci.image.manifest.v1+json",\n  "digest": "%s",\n  "size": 400\n}\n' "$digest"
      fi
    else
      echo "stub: unsupported format '$format'" >&2; exit 1
    fi ;;
  "buildx imagetools create")
    shift 3
    prefer_index=true dest="" src=""
    while [[ $# -gt 0 ]]; do
      case $1 in
        --prefer-index=false) prefer_index=false; shift ;;
        --tag) dest=$2; shift 2 ;;
        *) src=$1; shift ;;
      esac
    done
    [[ ${STUB_CREATE_FAIL:-} != 1 ]] || { echo "ERROR: push denied" >&2; exit 1; }
    lookup "$src" || { echo "ERROR: $src: not found" >&2; exit 1; }
    digest=$found
    kind=$(cat "$STUB/repos/$(enc "$r_repo")/manifests/$digest")
    if [[ $prefer_index == true && $kind == manifest ]]; then # buildx wraps a single manifest in a new index
      digest="sha256:$(printf 'index-of-%s' "$digest" | sha256sum | cut -c1-64)" kind=index
    fi
    if [[ ${STUB_CREATE_CORRUPT:-} == 1 ]]; then digest="sha256:$(printf 'corrupt' | sha256sum | cut -c1-64)"; fi
    split_ref "$dest"
    d="$STUB/repos/$(enc "$r_repo")"
    mkdir -p "$d/tags" "$d/manifests"
    echo "$kind" >"$d/manifests/$digest"
    echo "$digest" >"$d/tags/$r_tag"
    echo "#1 pushing $digest to $dest" >&2 ;;
  "image inspect --format")
    ref=${5:-}
    f="$STUB/local/$(enc "$ref")"
    [[ -f $f ]] || { echo "Error: No such image: $ref" >&2; exit 1; }
    cat "$f" ;;
  *) echo "stub docker: unsupported: $*" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"

digest_of() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -c1-64)"; }
seed() { # seed <repository> <tag> <digest> [manifest|index]: put a manifest and a tag into the stub registry
  local d="$STUB/repos/${1//\//%}"
  mkdir -p "$d/tags" "$d/manifests"
  echo "${4:-manifest}" >"$d/manifests/$3"
  echo "$3" >"$d/tags/$2"
}
tag_digest() { cat "$STUB/repos/${1//\//%}/tags/$2" 2>/dev/null || echo none; } # tag_digest <repository> <tag>

pass=0 fail=0
expect() { # expect <case> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    printf 'ok    %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
  fi
}
run() { # run <script> <args...>: stdout in $out, exit code in $rc, stderr in $tmp/stderr
  rc=0
  out=$("$@" 2>"$tmp/stderr") || rc=$?
}

repo=registry.example.com/team/app
A=$(digest_of a) B=$(digest_of b) I=$(digest_of index)
seed "$repo" sha-aaaaaaa "$A"
seed "$repo" sha-bbbbbbb "$B"
seed "$repo" 1.4.0 "$B"
seed "$repo" latest "$B"
seed "$repo" 1 "$B"
seed "$repo" multi "$I" index
seed localhost:5000/team/app 2.0 "$A"

echo "# resolve-image.sh"
run "$resolve" --help
expect "--help: exit 0 and usage" "0:1" "$rc:$(grep -c '^Usage: resolve-image.sh' <<<"$out")"
run "$resolve"
expect "no argument: exit 2" 2 "$rc"
run "$resolve" a b
expect "two arguments: exit 2" 2 "$rc"
run "$resolve" "$repo:sha-aaaaaaa"
expect "tag -> repository@digest" "0:$repo@$A" "$rc:$out"
run "$resolve" "$repo@$A"
expect "digest reference is checked and kept" "0:$repo@$A" "$rc:$out"
run "$resolve" "$repo:sha-bbbbbbb@$A"
expect "a digest wins over the tag next to it" "$repo@$A" "$out"
run "$resolve" "$repo:multi"
expect "an index resolves to its own digest, not a platform manifest's" "$repo@$I" "$out"
run "$resolve" localhost:5000/team/app:2.0
expect "a registry port stays in the repository" "localhost:5000/team/app@$A" "$out"
run "$resolve" "$repo:missing"
expect "unknown tag: exit 1" 1 "$rc"
run "$resolve" "$repo@$(digest_of nothing)"
expect "unknown digest: exit 1" 1 "$rc"
mkdir -p "$STUB/local"
printf '%s@%s\n' "$repo" "$(digest_of local)" >"$STUB/local/${repo//\//%}:local-only"
run "$resolve" "$repo:local-only"
expect "falls back to the local image store's RepoDigests" "$repo@$(digest_of local)" "$out"

echo "# retag-image.sh"
run "$retag" --help
expect "--help: exit 0 and usage" "0:1" "$rc:$(grep -c '^Usage: retag-image.sh' <<<"$out")"
run "$retag" "$repo@$A"
expect "no tag given: exit 2" 2 "$rc"
run "$retag" "$repo:sha-aaaaaaa" 1.5.0
expect "source without digest: exit 2" 2 "$rc"
: >"$STUB/calls.log"
run "$retag" "$repo@$A" 1.5.0 'bad tag'
expect "an invalid tag: exit 2 before anything is written" "2:0" "$rc:$(grep -c 'imagetools create' "$STUB/calls.log" || true)"
run "$retag" "$repo:sha-aaaaaaa@$A" 1.5.0 sha-aaaaaaa 1.5 latest
expect "new, already there, new, moved" $'1.5.0\tcreated\nsha-aaaaaaa\tunchanged\n1.5\tcreated\nlatest\tmoved' "$out"
expect "exit 0" 0 "$rc"
expect "the tags point at the source digest" "$A $A $A" "$(tag_digest "$repo" 1.5.0) $(tag_digest "$repo" 1.5) $(tag_digest "$repo" latest)"
expect "--prefer-index=false on every write" 3 "$(grep -c 'imagetools create --prefer-index=false' "$STUB/calls.log")"
: >"$STUB/calls.log"
run "$retag" "$repo@$A" 1.5.0 1.5
expect "second run: unchanged, nothing written" $'1.5.0\tunchanged\n1.5\tunchanged:0' "$out:$(grep -c 'imagetools create' "$STUB/calls.log" || true)"
run "$retag" "$repo@$A" 1.4.0 2.0.0 1
expect "immutable 1.4.0 refused, the other tags still written" $'2.0.0\tcreated\n1\tmoved' "$out"
expect "refusal: exit 3, 1.4.0 unchanged" "3:$B" "$rc:$(tag_digest "$repo" 1.4.0)"
expect "refusal is explained on stderr" 1 "$(grep -c 'refusing to move immutable tag' "$tmp/stderr")"
seed "$repo" stable "$B"
seed "$repo" 1.6 "$B"
RETAG_MUTABLE_REGEX='^(main|stable)$' run "$retag" "$repo@$A" stable 1.6
expect "RETAG_MUTABLE_REGEX: stable moves, 1.6 is now immutable" $'3:stable\tmoved' "$rc:$out"
run "$retag" --to registry.example.com/qa/app "$repo@$A" 1.5.0
expect "--to: written into the target repository" $'0:1.5.0\tcreated' "$rc:$out"
expect "--to: same digest in the target, source untouched" "$A $A" \
  "$(tag_digest registry.example.com/qa/app 1.5.0) $(tag_digest "$repo" 1.5.0)"
run "$retag" --to "registry.example.com/qa/app:x" "$repo@$A" 1.5.0
expect "--to with a tag: exit 2" 2 "$rc"
run "$retag" "$repo@$I" 3.0.0
expect "an index keeps its digest" "0:$I" "$rc:$(tag_digest "$repo" 3.0.0)"
STUB_CREATE_CORRUPT=1 run "$retag" "$repo@$A" 4.0.0
expect "verification after the write catches a wrong digest: exit 1" 1 "$rc"
STUB_CREATE_FAIL=1 run "$retag" "$repo@$A" 4.0.1
expect "a failed registry write: exit 1" 1 "$rc"
run "$retag" "$repo@$(digest_of nothing)" 4.0.2
expect "a source digest the registry does not have: exit 1" 1 "$rc"

echo
echo "passed $pass, failed $fail"
((fail == 0))
