#!/usr/bin/env bash
# retention.sh — GHCR image retention for the demo (D4 §4.10, §6.5; D7 §7.4). Dry run by default.
#
# Usage: retention.sh [--dry-run | --delete] [--owner <owner>] [--repo <owner/repo>] [--package <name>]...
#   --package   container package, e.g. deephaven-connectors/source-database (repeatable). Default: every
#               image project in .github/affected-map.yml.
# Rules, per package version (one version = one digest with its tags):
#   pr-<n>-<sha7>   deleted once pull request #<n> has been closed (merged or not) for PR_GRACE_DAYS days
#   *-rc.<n>        the RC_KEEP newest are kept, and every one younger than RC_MIN_AGE_DAYS; the rest go
# Never deleted:
#   - a version carrying a tag that config/**/compose.env (IMAGE_TAG) or config/**/values.yaml (tag:)
#     references on this checkout — the in-use protection;
#   - a version carrying a release tag (x.y.z) or a convenience tag (main, latest, x, x.y);
#   - untagged versions: in GHCR they include the per-platform manifests of tagged indexes.
# Environment: GH_TOKEN (packages: write to delete; pull requests readable) · DRY_RUN (true|false, default
#   true; --delete / --dry-run win) · PR_GRACE_DAYS (7) · RC_KEEP (20) · RC_MIN_AGE_DAYS (30) · CONFIG_DIR
#   (config) · GITHUB_REPOSITORY (owner/repo, for PR lookups).
# Output: one line per version (package, id, tags, age, decision, reason) on stdout and, in CI, a table in
#   $GITHUB_STEP_SUMMARY. Exit codes: 0 ok · 1 an API call failed · 2 usage.
set -euo pipefail

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

dry_run=${DRY_RUN:-true}
owner=""
repo=${GITHUB_REPOSITORY:-}
packages=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry_run=true; shift ;;
    --delete) dry_run=false; shift ;;
    --owner) [[ $# -ge 2 ]] || usage; owner=$2; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || usage; repo=$2; shift 2 ;;
    --package) [[ $# -ge 2 ]] || usage; packages+=("$2"); shift 2 ;;
    -h | --help) usage ;;
    *) echo "retention.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
[[ $dry_run == true || $dry_run == false ]] || { echo "retention.sh: DRY_RUN must be true or false" >&2; exit 2; }
[[ $repo =~ ^[^/]+/[^/]+$ ]] || { echo "retention.sh: --repo owner/repo (or GITHUB_REPOSITORY) is required" >&2; exit 2; }
owner=${owner:-${repo%%/*}}
grace_days=${PR_GRACE_DAYS:-7}
rc_keep=${RC_KEEP:-20}
rc_min_age_days=${RC_MIN_AGE_DAYS:-30}
config_dir=${CONFIG_DIR:-config}
for n in "$grace_days" "$rc_keep" "$rc_min_age_days"; do
  [[ $n =~ ^[0-9]+$ ]] || { echo "retention.sh: PR_GRACE_DAYS, RC_KEEP and RC_MIN_AGE_DAYS must be integers" >&2; exit 2; }
done

if [[ ${#packages[@]} -eq 0 ]]; then
  # :deephaven-connectors:source-database → deephaven-connectors/source-database (the D1 §6.1 image path).
  mapfile -t packages < <(yq '.projects | to_entries | map(select(.value.image == true) | .key) | .[]' \
    .github/affected-map.yml | sed 's/^://; s/:/\//g')
fi

now=$(date -u +%s)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
api_errors=0 deleted=0 would_delete=0 kept=0

# --- in-use protection ------------------------------------------------------------------------------
declare -A in_use=()
if [[ -d $config_dir ]]; then
  while read -r tag; do
    [[ -n $tag ]] && in_use[$tag]=1
  done < <(
    {
      grep -rhE '^[[:space:]]*IMAGE_TAG=' "$config_dir" --include=compose.env 2>/dev/null |
        sed -E 's/^[[:space:]]*IMAGE_TAG=["'\'']?([^"'\''[:space:]#]*).*/\1/'
      grep -rhE '^[[:space:]]*tag:[[:space:]]*' "$config_dir" --include=values.yaml --include=values.yml 2>/dev/null |
        sed -E 's/^[[:space:]]*tag:[[:space:]]*["'\'']?([^"'\''[:space:]#]*).*/\1/'
    } | sort -u
  )
fi

# --- helpers ----------------------------------------------------------------------------------------
owner_type=$(gh api "users/$owner" --jq .type 2>/dev/null || echo User)
if [[ $owner_type == Organization ]]; then scope="orgs/$owner"; else scope="users/$owner"; fi

declare -A pr_state=()
pr_closed_days() { # prints the days since PR #$1 was closed, or -1 while it is open (or unknown)
  local number=$1 state closed_at
  if [[ -z ${pr_state[$number]+set} ]]; then
    pr_state[$number]=$(gh api "repos/$repo/pulls/$number" --jq '[.state, (.closed_at // "")] | @tsv' 2>/dev/null || echo "unknown")
  fi
  IFS=$'\t' read -r state closed_at <<<"${pr_state[$number]}"
  if [[ $state == closed && -n $closed_at ]]; then
    echo $(((now - $(date -u -d "$closed_at" +%s)) / 86400))
  else
    echo -1
  fi
}

record() { # record <package> <id> <tags> <age-days> <decision> <reason>
  printf '%-45s %-12s %-50s %5sd  %-12s %s\n' "$1" "$2" "$3" "$4" "$5" "$6"
  echo "| \`$1\` | $2 | \`$3\` | $4 d | $5 | $6 |" >> "$summary"
}

delete_version() { # delete_version <package> <encoded package> <id>
  if [[ $dry_run == true ]]; then
    would_delete=$((would_delete + 1))
    return 0
  fi
  if gh api --method DELETE "$scope/packages/container/$2/versions/$3" >/dev/null; then
    deleted=$((deleted + 1))
  else
    echo "retention.sh: deleting $1 version $3 failed" >&2
    api_errors=$((api_errors + 1))
  fi
}

is_protected_tag() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || $1 == main || $1 == latest || $1 =~ ^[0-9]+$ || $1 =~ ^[0-9]+\.[0-9]+$ ]]
}

# --- sweep --------------------------------------------------------------------------------------------
{
  echo "### Image retention ($([[ $dry_run == true ]] && echo "dry run — nothing deleted" || echo "deleting"))"
  echo ""
  echo "Rules: \`pr-*\` of PRs closed > ${grace_days} d; keep the ${rc_keep} newest \`-rc.\` and all younger than ${rc_min_age_days} d. In use in \`${config_dir}/\`: ${#in_use[@]} tag(s)."
  echo ""
  echo "| package | version | tags | age | decision | reason |"
  echo "|---|---|---|---|---|---|"
} >> "$summary"

for package in "${packages[@]}"; do
  encoded=${package//\//%2F}
  if ! versions=$(gh api --paginate "$scope/packages/container/$encoded/versions?per_page=100" \
    --jq '.[] | [.id, .created_at, ((.metadata.container.tags // []) | join(","))] | @tsv' 2>/dev/null); then
    echo "retention.sh: package $package not found or not readable — skipped"
    echo "| \`$package\` | — | — | — | skipped | package not found or not readable |" >> "$summary"
    continue
  fi
  rc_candidates=()
  while IFS=$'\t' read -r id created tags; do
    [[ -n $id ]] || continue
    age=$(((now - $(date -u -d "$created" +%s)) / 86400))
    IFS=, read -r -a tag_list <<<"$tags"
    if [[ ${#tag_list[@]} -eq 0 ]]; then
      record "$package" "$id" "-" "$age" keep "untagged (may belong to a tagged index)"; kept=$((kept + 1)); continue
    fi
    reason="" pr_number="" is_rc=false
    for tag in "${tag_list[@]}"; do
      if [[ -n ${in_use[$tag]+set} ]]; then reason="in use in $config_dir/ ($tag)"; break; fi
      if is_protected_tag "$tag"; then reason="release or convenience tag ($tag)"; break; fi
      if [[ $tag =~ ^pr-([0-9]+)-[0-9a-f]{7}$ ]]; then pr_number=${BASH_REMATCH[1]}; fi
      if [[ $tag =~ -rc\.[0-9]+$ ]]; then is_rc=true; fi
    done
    if [[ -n $reason ]]; then
      record "$package" "$id" "$tags" "$age" keep "$reason"; kept=$((kept + 1))
    elif [[ -n $pr_number ]]; then
      closed=$(pr_closed_days "$pr_number")
      if ((closed > grace_days)); then
        record "$package" "$id" "$tags" "$age" "$([[ $dry_run == true ]] && echo would-delete || echo delete)" "PR #$pr_number closed $closed d ago"
        delete_version "$package" "$encoded" "$id"
      else
        record "$package" "$id" "$tags" "$age" keep "PR #$pr_number open or closed ≤ ${grace_days} d"; kept=$((kept + 1))
      fi
    elif $is_rc; then
      rc_candidates+=("$created"$'\t'"$id"$'\t'"$tags"$'\t'"$age")
    else
      record "$package" "$id" "$tags" "$age" keep "no retention rule"; kept=$((kept + 1))
    fi
  done <<<"$versions"

  # Pre-releases, newest first: keep RC_KEEP, and anything younger than RC_MIN_AGE_DAYS.
  rank=0
  while IFS=$'\t' read -r created id tags age; do
    [[ -n $id ]] || continue
    rank=$((rank + 1))
    if ((rank <= rc_keep)); then
      record "$package" "$id" "$tags" "$age" keep "pre-release #$rank of the newest $rc_keep"; kept=$((kept + 1))
    elif ((age < rc_min_age_days)); then
      record "$package" "$id" "$tags" "$age" keep "pre-release younger than $rc_min_age_days d"; kept=$((kept + 1))
    else
      record "$package" "$id" "$tags" "$age" "$([[ $dry_run == true ]] && echo would-delete || echo delete)" "pre-release #$rank, older than $rc_min_age_days d"
      delete_version "$package" "$encoded" "$id"
    fi
  done < <(printf '%s\n' ${rc_candidates[@]+"${rc_candidates[@]}"} | sort -r)
done

result="kept $kept, $([[ $dry_run == true ]] && echo "would delete $would_delete" || echo "deleted $deleted"), API errors $api_errors"
echo "retention.sh: $result"
printf '\n%s\n' "$result" >> "$summary"
((api_errors == 0)) || exit 1
