#!/usr/bin/env bash
# git-version.sh — the version of this commit, its kind and its image tags, derived from git tags and
# Conventional Commits. No version file: a release tag is the only input (skill gha-versioning-release).
#
# Usage: git-version.sh [options]
#   --prefix <p>          tag prefix of the version line (default v: tags v1.2.3; another line: server/v)
#                         letters, digits and . _ - / only
#   --path <pathspec>     only commits touching <pathspec> decide the bump (repeatable; any git pathspec,
#                         e.g. ':(exclude)server'); the commit count <n> always counts every commit
#   --ci | --no-ci        CI context on or off (default: on when GITHUB_ACTIONS=true)
#   --ref <ref>           the ref being built (default $GITHUB_REF); a bare name means refs/heads/<name>
#   --pr <number>         pull request number (default $PR_NUMBER, else read from a pull or merge-queue ref)
#   --main-branch <name>  trunk branch (default main); also the name of its moving image tag
#   --hotfix-prefix <p>   hotfix branch prefix (default hotfix/)
#   --ignore-head-tags    ignore the tags on HEAD, so a main build stays a pre-release after the tag appears
#   --allow-shallow       accept a shallow clone in CI (default: exit 4, the version would be wrong)
#   --override <version>  use this version (experiments only); the kind and tag rules still apply
#   --format <f>          env (default) | json | github: all facts (see Output)
#   --field <name>        print one fact only: version, kind, tags (space-separated), sha, sha7, dirty,
#                         base-tag, distance, next or bump
#   -C <dir>              repository directory (default: the current directory)
#   -h, --help            show this help
#
# Forms. <next> = the highest release tag of the line that HEAD contains, bumped by the commits since it
# (0.1.0 without a tag); <n> = commits since that tag (all commits without one); <sha7> = short HEAD sha.
#   kind     when                                     version                          image tags
#   release  HEAD carries the line's tag, clean tree  X.Y.Z                            X.Y.Z sha-<sha7>
#   pr       a PR number is known                     <next>-pr.<num>.<sha7>           pr-<num>-<sha7>
#   main     CI on refs/heads/<main-branch>           <next>-rc.<n>                    <next>-rc.<n> sha-<sha7> main
#   hotfix   CI on refs/heads/<hotfix-prefix>*        <next-patch>-rc.<n>              <next-patch>-rc.<n> sha-<sha7>
#   local    anything else                            <next>-local.<n>.<sha7>[.dirty]  local <version>
# Bump: a '<type>!:' subject or a 'BREAKING CHANGE:' / 'BREAKING-CHANGE:' footer -> major; 'feat:' or
# 'feature:' -> minor; anything else -> patch. Release tags are exactly <prefix>X.Y.Z: pre-release tags
# (v1.2.3-rc.1), other lines' tags and malformed tags never become the base. Dirty = tracked changes only.
#
# Output. env: VERSION, VERSION_KIND, IMAGE_TAGS (comma-separated), GIT_SHA, GIT_SHA7, GIT_DIRTY,
#   VERSION_BASE_TAG, VERSION_DISTANCE, VERSION_NEXT, VERSION_BUMP as KEY=value lines (for $GITHUB_ENV or
#   eval). json: one object with the same facts. github: version, kind, tags (JSON list), sha, sha7,
#   base-tag, distance, next lines (for $GITHUB_OUTPUT). --field: that value alone.
# Exit codes: 0 ok · 2 usage · 3 not a git work tree, no commit yet, or git missing · 4 shallow clone in CI
set -euo pipefail

self=${BASH_SOURCE[0]}
show_help() { sed -n '2,/^# Exit codes/s/^# \{0,1\}//p' "$self"; }
die() {
  local code=$1
  shift
  echo "git-version.sh: $*" >&2
  exit "$code"
}
usage_error() {
  echo "git-version.sh: $*" >&2
  echo "Run 'git-version.sh --help' for the options." >&2
  exit 2
}
warn() { echo "git-version.sh: warning: $*" >&2; }

# --- options ---------------------------------------------------------------------------------------------
prefix=v
paths=()
npaths=0
ci="" ref="" ref_set=false pr="" pr_set=false
main_branch=main hotfix_prefix=hotfix/
ignore_head_tags=false allow_shallow=false override="" format=env field="" dir=.

while [[ $# -gt 0 ]]; do
  case $1 in
    -h | --help) show_help; exit 0 ;;
    --ci) ci=true; shift; continue ;;
    --no-ci) ci=false; shift; continue ;;
    --ignore-head-tags) ignore_head_tags=true; shift; continue ;;
    --allow-shallow) allow_shallow=true; shift; continue ;;
    --prefix | --path | --ref | --pr | --main-branch | --hotfix-prefix | --override | --format | --field | -C)
      [[ $# -ge 2 ]] || usage_error "$1 needs a value" ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  case $1 in
    --prefix) prefix=$2 ;;
    --path) paths+=("$2"); npaths=$((npaths + 1)) ;;
    --ref) ref=$2; ref_set=true ;;
    --pr) pr=$2; pr_set=true ;;
    --main-branch) main_branch=$2 ;;
    --hotfix-prefix) hotfix_prefix=$2 ;;
    --override) override=$2 ;;
    --format) format=$2 ;;
    --field) field=$2 ;;
    -C) dir=$2 ;;
  esac
  shift 2
done

case $format in env | json | github) ;; *) usage_error "unknown --format '$format'" ;; esac
case $field in
  "" | version | kind | tags | sha | sha7 | dirty | base-tag | distance | next | bump) ;;
  *) usage_error "unknown --field '$field'" ;;
esac
[[ $prefix =~ ^[A-Za-z0-9._/-]*$ ]] || usage_error "--prefix '$prefix' may only contain letters, digits and . _ - /"
[[ -n $main_branch && -n $hotfix_prefix ]] || usage_error "--main-branch and --hotfix-prefix must not be empty"
[[ $override != *[[:space:]]* ]] || usage_error "--override must not contain white space"

# --- CI context ------------------------------------------------------------------------------------------
if [[ -z $ci ]]; then
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then ci=true; else ci=false; fi
fi
$ref_set || ref=${GITHUB_REF:-}
if [[ -n $ref && $ref != refs/* ]]; then ref=refs/heads/$ref; fi
if ! $pr_set; then
  pr=${PR_NUMBER:-}
  pull_re='^refs/pull/([0-9]+)/'
  queue_re='^refs/heads/gh-readonly-queue/.+/pr-([0-9]+)-[0-9a-f]+$'
  if [[ -z $pr && $ref =~ $pull_re ]]; then pr=${BASH_REMATCH[1]}; fi
  if [[ -z $pr && $ref =~ $queue_re ]]; then pr=${BASH_REMATCH[1]}; fi
fi
[[ -z $pr || $pr =~ ^[0-9]+$ ]] || usage_error "pull request number '$pr' is not a number"

# --- facts from git --------------------------------------------------------------------------------------
command -v git >/dev/null 2>&1 || die 3 "git not found"
g() { git -C "$dir" "$@"; }
[[ $(g rev-parse --is-inside-work-tree 2>/dev/null || true) == true ]] || die 3 "'$dir' is not inside a git work tree"
sha=$(g rev-parse --verify -q HEAD) || die 3 "the repository has no commit yet"
sha7=${sha:0:7}

if [[ $(g rev-parse --is-shallow-repository) == true ]]; then
  if $ci && ! $allow_shallow; then
    die 4 "shallow clone: tags and commit counts are missing, so the version would be wrong. Check out with 'fetch-depth: 0' (actions/checkout) or pass --allow-shallow."
  fi
  warn "shallow clone: tags and commit counts may be missing (fetch-depth: 0 gives the right version)"
fi

dirty=false
[[ -z $(git -C "$dir" --no-optional-locks status --porcelain --untracked-files=no) ]] || dirty=true

ignored=" "
if $ignore_head_tags; then
  while IFS= read -r t; do ignored="$ignored$t "; done < <(g tag --points-at HEAD)
fi

# Base = the highest <prefix>X.Y.Z tag that HEAD contains (same result as `git describe --tags --abbrev=0
# --match '<prefix>[0-9]*.[0-9]*.[0-9]*' --exclude '<prefix>*-*'` on a linear history).
num='(0|[1-9][0-9]*)'
prefix_re=$(printf '%s' "$prefix" | sed 's/[.]/\\./g')
tag_re="^${prefix_re}${num}\\.${num}\\.${num}\$"
base_tag="" bM=-1 bm=-1 bp=-1
while IFS= read -r t; do
  [[ -n $t && $ignored != *" $t "* && $t =~ $tag_re ]] || continue
  M=${BASH_REMATCH[1]} m=${BASH_REMATCH[2]} p=${BASH_REMATCH[3]}
  if ((M > bM || (M == bM && (m > bm || (m == bm && p > bp))))); then
    base_tag=$t bM=$M bm=$m bp=$p
  fi
done < <(g tag --merged HEAD --list "${prefix}*")

if [[ -n $base_tag ]]; then range="refs/tags/$base_tag..HEAD"; else range=HEAD; fi
distance=$(g rev-list --count "$range")
pathspec=()
if ((npaths > 0)); then pathspec=(-- "${paths[@]}"); fi
subjects=$(g log --no-show-signature --format=%s "$range" ${pathspec[@]+"${pathspec[@]}"})
messages=$(g log --no-show-signature --format=%B "$range" ${pathspec[@]+"${pathspec[@]}"})

re_breaking_subject='^[A-Za-z]+(\([^)]*\))?!:'
re_breaking_footer='^BREAKING[ -]CHANGE:'
re_feat='^(feat|feature)(\([^)]*\))?:'
bump="patch"
if grep -Eq "$re_breaking_subject" <<<"$subjects" || grep -Eq "$re_breaking_footer" <<<"$messages"; then
  bump=major
elif grep -Eq "$re_feat" <<<"$subjects"; then
  bump=minor
fi
if [[ -z $base_tag ]]; then
  next=0.1.0 bump=initial
else
  case $bump in
    major) next="$((bM + 1)).0.0" ;;
    minor) next="$bM.$((bm + 1)).0" ;;
    *) next="$bM.$bm.$((bp + 1))" ;;
  esac
fi

# --- kind, version, image tags ---------------------------------------------------------------------------
if [[ -n $base_tag && $distance -eq 0 && $dirty == false ]]; then
  kind=release
elif [[ -n $pr ]]; then
  kind="pr"
elif $ci && [[ $ref == "refs/heads/$main_branch" ]]; then
  kind=main
elif $ci && [[ $ref == "refs/heads/$hotfix_prefix"* ]]; then
  kind=hotfix
else
  kind=local
fi

case $kind in
  release) next="$bM.$bm.$bp" bump=none version=$next ;;
  main) version="$next-rc.$distance" ;;
  hotfix)
    # A hotfix only ever bumps the patch, whatever its commits say.
    if [[ -n $base_tag ]]; then next="$bM.$bm.$((bp + 1))" bump=patch; fi
    version="$next-rc.$distance" ;;
  pr) version="$next-pr.$pr.$sha7" ;;
  local)
    version="$next-local.$distance.$sha7"
    if $dirty; then version="$version.dirty"; fi ;;
esac
[[ -z $override ]] || version=$override

case $kind in
  release | hotfix) raw=("$version" "sha-$sha7") ;;
  main) raw=("$version" "sha-$sha7" "$main_branch") ;;
  pr) raw=("pr-$pr-$sha7") ;;
  local) raw=(local "$version") ;;
esac
# Docker tag grammar: [A-Za-z0-9_.-], at most 128 characters, not starting with '.' or '-'.
tags=()
for t in "${raw[@]}"; do
  t=${t//[^A-Za-z0-9_.-]/-}
  while [[ $t == [.-]* ]]; do t=${t:1}; done
  t=${t:0:128}
  [[ -n $t ]] || continue
  dup=false
  for u in ${tags[@]+"${tags[@]}"}; do [[ $u != "$t" ]] || dup=true; done
  $dup || tags+=("$t")
done

# --- output ----------------------------------------------------------------------------------------------
json_string() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}
json_tags() {
  local sep="" t
  printf '['
  for t in "${tags[@]}"; do
    printf '%s' "$sep"
    json_string "$t"
    sep=,
  done
  printf ']'
}
tags_csv=$(IFS=,; printf '%s' "${tags[*]}")

case $field in
  version) printf '%s\n' "$version" ;;
  kind) printf '%s\n' "$kind" ;;
  tags) printf '%s\n' "${tags[*]}" ;;
  sha) printf '%s\n' "$sha" ;;
  sha7) printf '%s\n' "$sha7" ;;
  dirty) printf '%s\n' "$dirty" ;;
  base-tag) printf '%s\n' "$base_tag" ;;
  distance) printf '%s\n' "$distance" ;;
  next) printf '%s\n' "$next" ;;
  bump) printf '%s\n' "$bump" ;;
esac
[[ -z $field ]] || exit 0

case $format in
  env)
    printf '%s\n' "VERSION=$version" "VERSION_KIND=$kind" "IMAGE_TAGS=$tags_csv" "GIT_SHA=$sha" \
      "GIT_SHA7=$sha7" "GIT_DIRTY=$dirty" "VERSION_BASE_TAG=$base_tag" "VERSION_DISTANCE=$distance" \
      "VERSION_NEXT=$next" "VERSION_BUMP=$bump" ;;
  github)
    printf '%s\n' "version=$version" "kind=$kind" "tags=$(json_tags)" "sha=$sha" "sha7=$sha7" \
      "base-tag=$base_tag" "distance=$distance" "next=$next" ;;
  json)
    printf '{"version":%s,"kind":%s,"tags":%s,"sha":%s,"sha7":%s,"dirty":%s,"base_tag":%s,"distance":%s,"next":%s,"bump":%s}\n' \
      "$(json_string "$version")" "$(json_string "$kind")" "$(json_tags)" "$(json_string "$sha")" \
      "$(json_string "$sha7")" "$dirty" "$(json_string "$base_tag")" "$distance" "$(json_string "$next")" \
      "$(json_string "$bump")" ;;
esac
