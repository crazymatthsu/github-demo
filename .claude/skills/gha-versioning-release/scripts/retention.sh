#!/usr/bin/env bash
# retention.sh — registry retention for GHCR: delete the image versions that no environment, release or
# rollback needs any more. Dry run by default. Rules and algorithm: references/retention.md of skill
# gha-versioning-release.
#
# Usage: retention.sh [--dry-run | --delete] [--owner <owner>] [--repo <owner/repo>] [--package <name>]...
#   --dry-run          report only: the default unless DRY_RUN=false
#   --delete           delete the versions the rules select
#   --owner <owner>    user or organization that owns the packages (default: the owner of --repo)
#   --repo <o/r>       repository whose pull requests the pr-* tags name (default: $GITHUB_REPOSITORY)
#   --package <name>   container package = image path below the owner, e.g. api or team/api (repeatable).
#                      Default: $RETENTION_PACKAGES (space-separated), else every `image: true` project of
#                      .github/affected-map.yml, named as _build.yml names its image: IMAGE_PATH_PREFIX plus
#                      the last segment of the project key (services/api -> api, or team/api)
#   -h, --help         show this help
# Rules. A package version is one digest with all its tags, and deleting it deletes every tag: one protected
# tag keeps the whole version. Checked in this order:
#   untagged                     keep: GHCR lists the platform manifests of multi-platform images untagged
#   digest or a tag in use       keep: referenced by the configuration (below)
#   X.Y.Z, main, latest, X, X.Y  keep: releases and moving tags
#   a tag no rule knows          keep, "no retention rule" (local, unknown patterns; sha-<sha7> rides along)
#   pr-<n>-<sha7>                delete once pull request <n> has been closed (merged or not) for PR_GRACE_DAYS
#                                full days; keep while it is open, closed more recently, or unreadable
#   *-rc.<n>                     keep the RC_KEEP newest of the package and every one younger than
#                                RC_MIN_AGE_DAYS days; delete the rest
#   When every tagged version would go, the newest stays: GHCR refuses to delete the last tagged version.
# In use: <RETENTION_TAG_VAR>= lines of CONFIG_DIR/**/compose.env and tag: lines of CONFIG_DIR/**/values*.yaml
#   or .yml (quoted or not, comments ignored; <tag>@sha256:<digest> counts both), and every sha256:<digest> in
#   those files (image.digest): the layout of skill gha-config-deploy; adapt config_refs() for another one. It
#   reads the checkout, so run the sweep on the default branch.
# Environment [default]:
#   GH_TOKEN                 gh's token: read and delete package versions (admin on the package), read PRs
#   DRY_RUN [true]           true | false; --dry-run / --delete win
#   PR_GRACE_DAYS [7], RC_KEEP [20], RC_MIN_AGE_DAYS [30]   non-negative integers
#   CONFIG_DIR [config]      the configuration tree; missing = nothing in use (a notice)
#   RETENTION_TAG_VAR [IMAGE_TAG]   the tag variable of compose.env
#   RETENTION_PACKAGES []    the packages when no --package is given (space-separated)
#   IMAGE_PATH_PREFIX []     prefix of the package names derived from the affected map, e.g. team/
#   GITHUB_REPOSITORY        owner/repo (GitHub Actions sets it)
#   GITHUB_STEP_SUMMARY      when set, the decisions are appended as a markdown table with the totals
#   RETENTION_NOW []         test hook: "now" in epoch seconds
# Output: one TAB-separated line per version on stdout: package, version id, tags (comma-separated, - for
#   none), age in days, keep | delete, reason (a dry run deletes nothing). Notices, errors and the totals go
#   to stderr (as workflow commands in GitHub Actions).
# API: gh api without --jq (raw JSON, filtered by jq): users/<owner> (.type -> orgs/ or users/ scope),
#   <scope>/packages/container/<package, / as %2F>/versions (paginated), repos/<repo>/pulls/<n> (once per
#   pull request), DELETE <scope>/packages/container/<package>/versions/<id>. A package that is not found
#   (404) is skipped with a warning; any other failed call is reported, the sweep goes on, and it exits 1.
# Needs bash 4+, gh, jq (jq parses the dates: no GNU date needed); yq (mikefarah v4 or the Python yq) only
#   to read the affected map.
# Exit codes: 0 ok · 1 an API call failed, or the configuration could not be read · 2 usage
set -euo pipefail
export TZ=UTC # jq's date functions assume UTC

self=${BASH_SOURCE[0]}
show_help() { sed -n '2,/^# Exit codes/s/^# \{0,1\}//p' "$self"; }
usage_error() {
  echo "retention.sh: $*" >&2
  echo "Run 'retention.sh --help' for usage." >&2
  exit 2
}
annotate() { # annotate <notice|warning|error> <message>: to stderr, as a workflow command in GitHub Actions
  local message="retention.sh: $2"
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    message=${message//'%'/%25}
    message=${message//$'\r'/%0D}
    message=${message//$'\n'/%0A}
    echo "::$1::$message" >&2
  else
    echo "retention.sh: $1: $2" >&2
  fi
}
if ((BASH_VERSINFO[0] < 4)); then
  echo "retention.sh: needs bash 4 or newer (macOS: brew install bash)" >&2
  exit 2
fi

# --- options -----------------------------------------------------------------------------------------------
dry_run=${DRY_RUN:-true}
owner="" repo=${GITHUB_REPOSITORY:-}
packages=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -h | --help) show_help; exit 0 ;;
    --dry-run) dry_run=true; shift ;;
    --delete) dry_run=false; shift ;;
    --owner | --repo | --package)
      [[ $# -ge 2 && -n $2 ]] || usage_error "$1 needs a value"
      case $1 in
        --owner) owner=$2 ;;
        --repo) repo=$2 ;;
        *) packages+=("$2") ;;
      esac
      shift 2 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done
[[ $dry_run == true || $dry_run == false ]] || usage_error "DRY_RUN must be true or false, not '$dry_run'"
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_error "--repo <owner/repo> (or GITHUB_REPOSITORY) is required"
owner=${owner:-${repo%%/*}}
[[ $owner =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || usage_error "invalid owner '$owner'"
grace_days=${PR_GRACE_DAYS:-7} rc_keep=${RC_KEEP:-20} rc_min_age=${RC_MIN_AGE_DAYS:-30} now=${RETENTION_NOW:-$(date +%s)}
for value in "$grace_days" "$rc_keep" "$rc_min_age" "$now"; do
  [[ $value =~ ^[0-9]+$ ]] ||
    usage_error "PR_GRACE_DAYS, RC_KEEP, RC_MIN_AGE_DAYS and RETENTION_NOW take non-negative integers, not '$value'"
done
grace_days=$((10#$grace_days)) rc_keep=$((10#$rc_keep)) rc_min_age=$((10#$rc_min_age)) now=$((10#$now))
config_dir=${CONFIG_DIR:-config}
tag_var=${RETENTION_TAG_VAR:-IMAGE_TAG}
[[ $tag_var =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || usage_error "RETENTION_TAG_VAR must be a variable name, not '$tag_var'"
path_prefix=${IMAGE_PATH_PREFIX:-}
if [[ -n $path_prefix && $path_prefix != */ ]]; then path_prefix+=/; fi
command -v jq >/dev/null 2>&1 || usage_error "jq is required"
command -v gh >/dev/null 2>&1 || usage_error "gh (GitHub CLI) is required"

# --- packages ----------------------------------------------------------------------------------------------
if [[ ${#packages[@]} -eq 0 && -n ${RETENTION_PACKAGES:-} ]]; then
  read -r -d '' -a packages <<<"$RETENTION_PACKAGES" || true
fi
if [[ ${#packages[@]} -eq 0 ]]; then
  map=.github/affected-map.yml
  [[ -f $map ]] || usage_error "no package given: pass --package, set RETENTION_PACKAGES, or run where $map exists"
  # mikefarah yq v4 needs -o=json; the Python yq (a jq wrapper) prints JSON anyway.
  projects=$(yq -o=json '.projects' "$map" 2>/dev/null || yq '.projects' "$map" 2>/dev/null) ||
    usage_error "cannot read $map (needs yq: mikefarah v4 or the Python yq)"
  keys=$(jq -r '(. // {}) | to_entries[] | select(.value.image == true) | .key' <<<"$projects" 2>/dev/null) ||
    usage_error "cannot read the projects of $map"
  while IFS= read -r key; do
    if [[ -n $key ]]; then packages+=("$path_prefix${key##*/}"); fi # _build.yml: <namespace>/<last segment>
  done <<<"$keys"
  [[ ${#packages[@]} -gt 0 ]] || usage_error "$map lists no project with image: true; pass --package"
fi
declare -A seen=()
unique=()
for package in "${packages[@]}"; do
  [[ $package =~ ^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*$ ]] ||
    usage_error "invalid package '$package' (the lowercase image path below the owner, e.g. api or team/api)"
  if [[ -z ${seen[$package]+set} ]]; then seen[$package]=1 unique+=("$package"); fi
done
packages=("${unique[@]}")

# --- in-use protection -------------------------------------------------------------------------------------
# config_refs prints "tag <tag>" and "digest <digest>" for every image reference of the configuration tree
# and fails when a file cannot be read. Adapt it when your environments pin their images elsewhere.
config_refs() {
  local lines digests line value rc=0
  local includes=(--include=compose.env --include='values*.yaml' --include='values*.yml')
  local ref_re="^[[:space:]]*(-[[:space:]]+)?(${tag_var}=|tag:[[:space:]]*)[\"']?([^\"'[:space:]#]+)"
  lines=$(grep -rhE "${includes[@]}" "^[[:space:]]*(-[[:space:]]+)?(${tag_var}=|tag:)" "$config_dir") || rc=$?
  ((rc <= 1)) || return 1 # 1 = no match
  digests=$(grep -rhoE "${includes[@]}" 'sha256:[0-9a-f]{64}' "$config_dir") || rc=$?
  ((rc <= 1)) || return 1
  while IFS= read -r line; do
    if [[ $line =~ $ref_re ]]; then
      value=${BASH_REMATCH[3]}
      echo "tag ${value%%@*}" # <tag>@sha256:<digest>: the digest is collected below
    fi
  done <<<"$lines"
  while IFS= read -r line; do
    if [[ -n $line ]]; then echo "digest $line"; fi
  done <<<"$digests"
}
declare -A in_use_tag=() in_use_digest=()
if [[ -d $config_dir ]]; then
  if ! refs=$(config_refs); then
    annotate error "cannot read the configuration under $config_dir/: nothing is deleted"
    exit 1
  fi
  while read -r kind value; do
    case $kind in
      tag) if [[ -n $value ]]; then in_use_tag[$value]=1; fi ;;
      digest) in_use_digest[$value]=1 ;;
    esac
  done <<<"$refs"
else
  annotate notice "no $config_dir/ directory here: no tag or digest is protected as in use"
fi

# --- GitHub API ----------------------------------------------------------------------------------------------
errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT
summary=${GITHUB_STEP_SUMMARY:-}
md() { if [[ -n $summary ]]; then printf '%s\n' "$@" >>"$summary"; fi; }
failures=()
api_error() { # api_error <message>: one failed call, reported now and counted for exit code 1
  failures+=("$1")
  annotate error "$1"
}
gh_body="" gh_error=""
gh_call() { # gh_call <gh api arguments>...: the response in gh_body; on failure gh's message in gh_error
  gh_error=""
  if gh_body=$(gh api "$@" </dev/null 2>"$errfile"); then return 0; fi
  gh_error=$(tr -s '\r\n' '  ' <"$errfile" | sed 's/[[:space:]]*$//')
  if [[ -z $gh_error ]]; then gh_error="gh api $* failed without a message"; fi
  return 1
}

owner_type=""
if gh_call "users/$owner"; then
  owner_type=$(jq -r '.type // empty' <<<"$gh_body" 2>/dev/null) || owner_type=""
  gh_error="unexpected answer (type '$owner_type')"
fi
case $owner_type in
  Organization) scope=orgs/$owner ;;
  User) scope=users/$owner ;;
  *) # without the scope no package can be read: stop here
    api_error "GET users/$owner failed: $gh_error"
    md "### Registry retention: failed" "" "\`GET users/$owner\` failed: $gh_error"
    exit 1 ;;
esac

declare -A pr_state=() pr_days=()
pr_filter='[(.state // "unknown"),
  ((.closed_at // "") | if . == "" then -1 else sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | floor end)] | @tsv'
pr_status() { # pr_status <n>: looks pull request <n> up once; pr_state[n] open|closed|unknown|error, pr_days[n]
  local n=$1 info state closed
  if [[ -n ${pr_state[$n]+set} ]]; then return 0; fi
  pr_state[$n]=error pr_days[$n]=-1
  if ! gh_call "repos/$repo/pulls/$n"; then
    api_error "GET repos/$repo/pulls/$n failed: $gh_error"
    return 0
  fi
  if ! info=$(jq -r "$pr_filter" <<<"$gh_body" 2>/dev/null) || [[ -z $info ]]; then
    api_error "GET repos/$repo/pulls/$n: unexpected response"
    return 0
  fi
  IFS=$'\t' read -r state closed <<<"$info"
  pr_state[$n]=unknown
  if [[ $state == open ]]; then
    pr_state[$n]=open
  elif [[ $state == closed ]] && ((closed >= 0)); then
    pr_state[$n]=closed pr_days[$n]=$(((now - closed) / 86400))
  fi
}

# classify <tags, comma-separated or -> <digest>: sets decision (keep, delete, or rc = ranked later) and reason
classify() {
  local tag n list=() prs=() rc=false unknown=""
  decision=keep reason=""
  if [[ $1 == - ]]; then reason="untagged (may belong to a tagged multi-platform index)"; return 0; fi
  if [[ -n ${in_use_digest[$2]+set} ]]; then reason="in use: digest in $config_dir/"; return 0; fi
  IFS=, read -r -a list <<<"$1"
  for tag in "${list[@]}"; do
    if [[ -n ${in_use_tag[$tag]+set} ]]; then reason="in use: $tag in $config_dir/"; return 0; fi
  done
  for tag in "${list[@]}"; do
    if [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then reason="release tag $tag"; return 0; fi
    if [[ $tag == main || $tag == latest || $tag =~ ^[0-9]+(\.[0-9]+)?$ ]]; then reason="moving tag $tag"; return 0; fi
  done
  for tag in "${list[@]}"; do
    if [[ $tag =~ ^pr-([0-9]+)-[0-9a-f]{7}$ ]]; then
      prs+=("${BASH_REMATCH[1]}")
    elif [[ $tag =~ -rc\.[0-9]+$ ]]; then
      rc=true
    elif [[ ! $tag =~ ^sha-[0-9a-f]{7}$ ]]; then
      unknown=$tag
    fi
  done
  if [[ -n $unknown ]]; then reason="no retention rule for $unknown"; return 0; fi
  if [[ ${#prs[@]} -eq 0 && $rc == false ]]; then reason="no retention rule"; return 0; fi
  for n in ${prs[@]+"${prs[@]}"}; do
    pr_status "$n"
    case ${pr_state[$n]} in
      open) reason="PR #$n open"; return 0 ;;
      error) reason="PR #$n unreadable (API error)"; return 0 ;;
      unknown) reason="PR #$n state unknown"; return 0 ;;
    esac
    if ((pr_days[$n] < grace_days)); then
      reason="PR #$n closed ${pr_days[$n]} d ago, within the $grace_days d grace"
      return 0
    fi
    reason="PR #$n closed ${pr_days[$n]} d ago (grace $grace_days d)"
  done
  if [[ $rc == true ]]; then decision=rc; else decision=delete; fi
}

rows=0 max_rows=2000 # a job summary holds 1 MiB; the log keeps every line
record() { # record <package> <id> <tags> <age> <decision> <reason>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
  rows=$((rows + 1))
  if ((rows <= max_rows)); then md "| \`$1\` | $2 | \`$3\` | $4 d | $5 | $6 |"; fi
}

# --- sweep -----------------------------------------------------------------------------------------------------
if [[ $dry_run == true ]]; then mode="dry run, nothing is deleted"; else mode="deleting"; fi
echo "retention.sh: $mode; owner $owner ($scope), pull requests of $repo; packages: ${packages[*]};" \
  "in use in $config_dir/: ${#in_use_tag[@]} tag(s), ${#in_use_digest[@]} digest(s)" >&2
rules="\`pr-*\` once the pull request has been closed $grace_days d; \`-rc.\` beyond the $rc_keep newest and"
rules+=" $rc_min_age d or older; never releases, moving tags, untagged versions, unknown tags or what"
rules+=" \`$config_dir/\` references (${#in_use_tag[@]} tags, ${#in_use_digest[@]} digests)"
md "### Registry retention: $mode" "" "Owner \`$owner\` (\`$scope\`), pull requests of \`$repo\`. Rules: $rules." \
  "" "| package | version | tags | age | decision | reason |" "|---|---|---|---|---|---|"

versions_filter='.[] | [(.id | tostring), (.name // "" | if . == "" then "-" else . end),
  (.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | floor | tostring),
  ((.metadata.container.tags // []) | if length == 0 then "-" else join(",") end)] | @tsv'
kept=0 to_delete=0 deleted=0 skipped=0
for package in "${packages[@]}"; do
  base="$scope/packages/container/${package//\//%2F}/versions"
  if ! gh_call --paginate "$base?per_page=100"; then
    if [[ $gh_error == *"(HTTP 404)"* ]]; then
      skipped=$((skipped + 1))
      annotate warning "package $package not found under $owner (not pushed yet, or not visible to this token): skipped"
      md "| \`$package\` | - | - | - | skipped | package not found |"
    else
      api_error "GET $base failed: $gh_error"
      md "| \`$package\` | - | - | - | skipped | listing failed |"
    fi
    continue
  fi
  # Pages arrive as one array or as consecutive arrays; jq reads either.
  if ! listing=$(jq -r "$versions_filter" <<<"$gh_body" 2>"$errfile"); then
    api_error "GET $base: unexpected response: $(head -n 1 "$errfile")"
    md "| \`$package\` | - | - | - | skipped | unexpected response |"
    continue
  fi

  ids=() tag_sets=() ages=() created=() decisions=() reasons=() candidates=()
  while IFS=$'\t' read -r id digest created_epoch tags; do
    if [[ -z $id ]]; then continue; fi
    if [[ ! $id =~ ^[0-9]+$ || ! $created_epoch =~ ^-?[0-9]+$ ]]; then # never let odd data reach a DELETE path
      api_error "GET $base: unexpected version id '$id' or date: skipped"
      continue
    fi
    age=$(((now - created_epoch) / 86400))
    if ((age < 0)); then age=0; fi
    classify "$tags" "$digest"
    if [[ $decision == rc ]]; then candidates+=("$created_epoch"$'\t'"$id"$'\t'"${#ids[@]}"); fi
    ids+=("$id") tag_sets+=("$tags") ages+=("$age") created+=("$created_epoch")
    decisions+=("$decision") reasons+=("$reason")
  done <<<"$listing"

  # Pre-releases, newest first (ties: the higher id): keep RC_KEEP, and every one younger than RC_MIN_AGE_DAYS.
  rank=0
  while IFS=$'\t' read -r _ _ i; do
    if [[ -z $i ]]; then continue; fi
    rank=$((rank + 1))
    if ((rank <= rc_keep)); then
      decisions[i]=keep reasons[i]="pre-release #$rank, among the $rc_keep newest"
    elif ((ages[i] < rc_min_age)); then
      decisions[i]=keep reasons[i]="pre-release #$rank, younger than $rc_min_age d"
    else
      decisions[i]=delete reasons[i]="pre-release #$rank, beyond the $rc_keep newest and $rc_min_age d or older"
    fi
  done < <(printf '%s\n' ${candidates[@]+"${candidates[@]}"} | sort -t $'\t' -k1,1nr -k2,2nr)

  # GHCR refuses to delete the last tagged version of a package: keep the newest one of those to delete.
  last=-1 tagged_kept=0
  for ((i = 0; i < ${#ids[@]}; i++)); do
    if [[ ${tag_sets[i]} == - ]]; then continue; fi
    if [[ ${decisions[i]} == keep ]]; then
      tagged_kept=$((tagged_kept + 1))
    elif ((last < 0 || created[i] > created[last] || (created[i] == created[last] && ids[i] > ids[last]))); then
      last=$i
    fi
  done
  if ((tagged_kept == 0 && last >= 0)); then
    decisions[last]=keep reasons[last]="the last tagged version of the package (GHCR refuses to delete it)"
  fi

  for ((i = 0; i < ${#ids[@]}; i++)); do
    if [[ ${decisions[i]} == delete ]]; then
      to_delete=$((to_delete + 1))
      if [[ $dry_run == false ]]; then
        if gh_call --method DELETE "$base/${ids[i]}"; then
          deleted=$((deleted + 1))
        else
          api_error "DELETE $base/${ids[i]} ($package ${tag_sets[i]}) failed: $gh_error"
          reasons[i]+="; the DELETE failed"
        fi
      fi
    else
      kept=$((kept + 1))
    fi
    record "$package" "${ids[i]}" "${tag_sets[i]}" "${ages[i]}" "${decisions[i]}" "${reasons[i]}"
  done
done

if [[ $dry_run == true ]]; then
  totals="$kept kept, $to_delete to delete (dry run: nothing deleted)"
else
  totals="$kept kept, $deleted of $to_delete deleted"
fi
totals+=", $skipped package(s) not found, ${#failures[@]} failed API call(s)"
echo "retention.sh: $totals" >&2
if ((rows > max_rows)); then
  md "" "The table shows the first $max_rows of $rows versions; the job log lists every one."
fi
md "" "**Totals:** $totals"
if [[ ${#failures[@]} -gt 0 ]]; then
  md "" "**Failed API calls:**"
  for failure in "${failures[@]}"; do
    echo "retention.sh: failed: $failure" >&2
    md "- $failure"
  done
  exit 1
fi
