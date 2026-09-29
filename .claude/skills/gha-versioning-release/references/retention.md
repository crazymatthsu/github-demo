# Registry retention: what to keep, what to delete

Read this when you add the scheduled cleanup of the image registry, or when someone asks why an image
vanished or why the registry keeps growing. The rules come from the reference repository's nightly
retention job (a GHCR sweep in bash with `gh api`); the algorithm below is enough to rebuild it.

Contents: 1 Rules · 2 The unit of deletion · 3 In-use protection · 4 GHCR API · 5 Algorithm ·
6 The nightly job · 7 Other registries · 8 Gotchas

## 1. Rules

| Tag class | Rule | Why |
|---|---|---|
| `pr-<n>-<sha7>` | delete once pull request `<n>` has been closed (merged or not) for `PR_GRACE_DAYS` (7) | PR images exist only for the PR's tests; the grace lets a reopened PR or a late investigation still pull them |
| `*-rc.<n>` (main and hotfix pre-releases) | keep the `RC_KEEP` (20) newest per image and every one younger than `RC_MIN_AGE_DAYS` (30); delete the rest | dev needs recent rollback targets; older pre-releases are never deployed again |
| `X.Y.Z` releases | never | a release may be redeployed or audited at any time |
| moving tags `main`, `latest`, `X`, `X.Y` | never delete (they move) | the digests they point at are current by definition |
| tags referenced by the configuration | never | deleting an image an environment runs breaks its next restart or scale-up |
| untagged versions | never (on GHCR) | GHCR lists the per-platform manifests of a multi-platform image as untagged versions; deleting them breaks the tagged index |
| anything else (`local`, unknown patterns) | keep, report "no retention rule" | an unknown tag is a question for a human, not for a sweep |

Dry run by default: the scheduled job only reports until a repository variable says otherwise, and a
manual run has a `DRY_RUN` input. The first real deletion should follow a reviewed dry-run report.

## 2. The unit of deletion

A registry package version is one digest with all its tags: deleting it deletes every tag on it. So the
sweep decides per version, and **any** protected tag keeps the whole version: `1.5.0-rc.7` that later
became `1.5.0` (same digest) is kept because of `1.5.0`; `sha-<sha7>` tags never decide anything on their
own because they always sit next to an rc or release tag.

## 3. In-use protection

Before deciding anything, collect every tag the configuration on the default branch references and treat
them as protected. In the reference layout that meant:

```bash
{
  grep -rhE '^[[:space:]]*IMAGE_TAG=' config --include=compose.env |
    sed -E 's/^[[:space:]]*IMAGE_TAG=["'\'']?([^"'\''[:space:]#]*).*/\1/'
  grep -rhE '^[[:space:]]*tag:[[:space:]]*' config --include=values.yaml --include=values.yml |
    sed -E 's/^[[:space:]]*tag:[[:space:]]*["'\'']?([^"'\''[:space:]#]*).*/\1/'
} | sort -u
```

Adapt the patterns to where your environments pin their images (skill gha-config-deploy). Pin digests
too? Then protect the digests the configuration names as well. The same query answers "which versions are
deployed where" for other tools, so keep it in a script both can call.

## 4. GHCR API

| Need | Call |
|---|---|
| owner kind | `gh api users/<owner> --jq .type` → `Organization` uses `orgs/<owner>`, `User` uses `users/<owner>` |
| list versions | `gh api --paginate "<scope>/packages/container/<package>/versions?per_page=100" --jq '.[] \| [.id, .created_at, ((.metadata.container.tags // []) \| join(","))] \| @tsv'` |
| delete a version | `gh api --method DELETE "<scope>/packages/container/<package>/versions/<id>"` |
| PR state | `gh api repos/<owner>/<repo>/pulls/<n> --jq '[.state, (.closed_at // "")] \| @tsv'` |

- `<package>` is the image path below the owner with `/` URL-encoded as `%2F` (`team%2Fapi`).
- Permissions: the job needs `packages: write` (deletion) and `pull-requests: read`. `GITHUB_TOKEN` can
  delete only versions of packages that grant this repository the admin role (Package settings → Manage
  Actions access); otherwise use a token with `read:packages` + `delete:packages` stored as a secret
  (the reference named it `RETENTION_TOKEN`). A missing grant shows up as 403.

## 5. Algorithm

```text
protected := tags referenced by the configuration (section 3)
for each package (image) of the repository:
  versions := list with id, created_at, tags
  rc := []
  for each version:
    if no tags:                              keep  "untagged (may belong to a tagged index)"
    elif any tag in protected:               keep  "in use"
    elif any tag is X.Y.Z / main / latest / X / X.Y:   keep  "release or moving tag"
    elif a tag is pr-<n>-<sha7>:
      if PR <n> closed more than PR_GRACE_DAYS ago:     delete
      else:                                  keep  "PR open or closed recently"
    elif a tag ends in -rc.<n>:              rc += version
    else:                                    keep  "no retention rule"
  sort rc by created_at, newest first
  for rank, version in rc:
    if rank <= RC_KEEP:                      keep
    elif age < RC_MIN_AGE_DAYS:              keep
    else:                                    delete
report every decision (package, version id, tags, age, decision, reason) to stdout and the job summary
exit 1 if any API call failed (after trying everything else)
```

Count API errors instead of stopping at the first one, so one unreadable package does not block the
cleanup of the others; skip (and report) a package that does not exist yet.

## 6. The nightly job

```yaml
  retention:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    permissions:
      contents: read       # the configuration for the in-use query
      packages: write      # delete package versions
      pull-requests: read  # closed_at of PRs
    steps:
      - uses: actions/checkout@v7
      - name: Sweep the registry
        env:
          GH_TOKEN: ${{ secrets.RETENTION_TOKEN || github.token }}
          # Scheduled runs only report unless the repository variable RETENTION_DRY_RUN is 'false'.
          DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && format('{0}', inputs.DRY_RUN) || vars.RETENTION_DRY_RUN || 'true' }}
        run: scripts/ci/retention.sh     # your implementation of section 5
```

Trigger it from the nightly schedule (`cron`) with a `workflow_dispatch` input `DRY_RUN` (boolean, default
true). Put the decision table into `$GITHUB_STEP_SUMMARY`: it is the audit trail of what was deleted.

## 7. Other registries

| Registry | Native policy covers | Still needs a job for |
|---|---|---|
| JFrog Artifactory | cleanup policies by age / count per repository; AQL search (`jf rt search`, `jf rt delete`) for patterns | the in-use protection; never run any cleanup against the prod repository |
| Amazon ECR | lifecycle policies: `tagPrefixList` / `tagPatternList` with `countMoreThan` or `sinceImagePushed`, untagged expiry | in-use protection (lifecycle rules cannot read git); keep release tags out of every rule |
| Docker Hub, Harbor, others | varies (Harbor has tag retention rules and immutable tag rules) | the same in-use query |

Promotion repositories (qa, prod) are never cleaned by rule; they only receive promoted releases.

## 8. Gotchas

- Deleting untagged GHCR versions breaks multi-platform images: their per-platform manifests are listed
  untagged. Leave untagged versions alone unless you check they belong to no tagged index.
- 403 on delete with `GITHUB_TOKEN`: the package does not grant this repository admin access; grant it or
  use a dedicated token.
- The sweep must read the configuration of the default branch: run it on a checkout of that branch, not
  of whatever ref dispatched it.
- A deleted `pr-*` image can still be referenced by a re-run of an old PR workflow; the grace period covers
  the usual cases, and a re-run of the whole PR pipeline rebuilds it.
- Retention also applies to caches and artifacts: set `retention-days` on uploads, and let a weekly job
  delete Actions caches of closed PR branches (`gh cache list` / `gh cache delete`).
