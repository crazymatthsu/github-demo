# Registry retention: what to keep, what to delete

Read this when you add the scheduled cleanup of the image registry, or when someone asks why an image
vanished or why the registry keeps growing. The rules come from the reference repository's nightly
retention job (a GHCR sweep in bash with `gh api`). The skill ships it, generalised: `scripts/retention.sh`
(tests: `scripts/test-retention.sh`, against a stubbed `gh`) and the workflow `assets/workflows/retention.yml`;
sections 5 and 6 say how they work and how to install them.

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

Dry run by default: the scheduled job only reports until the repository variable `RETENTION_DELETE` is
`true`, and a manual run deletes only with its `dry-run` input unticked. The first real deletion should
follow a reviewed dry-run report.

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

`scripts/retention.sh` reads this layout in its `config_refs()`: `IMAGE_TAG=` of `compose.env` (another
variable: `RETENTION_TAG_VAR`) and `tag:` lines of `values*.yaml`, quoted or not, comments ignored, plus every
`sha256:<digest>` in those files (`image.digest`, `IMAGE_TAG=<tag>@sha256:…`). For another layout, adapt
that function; `CONFIG_DIR` moves the tree.

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

`scripts/retention.sh` implements it (flags and environment: `retention.sh --help`); `scripts/test-retention.sh`
holds its cases against a stubbed `gh`.

```text
protected := tags and digests referenced by the configuration (section 3)
for each package (image) of the repository:
  versions := list with id, digest, created_at, tags
  rc := []
  for each version:
    if no tags:                              keep  "untagged (may belong to a tagged index)"
    elif digest or any tag in protected:     keep  "in use"
    elif any tag is X.Y.Z / main / latest / X / X.Y:   keep  "release or moving tag"
    elif any tag is not pr-*, *-rc.* or sha-*:         keep  "no retention rule"
    elif a tag is pr-<n>-<sha7>:
      if PR <n> closed more than PR_GRACE_DAYS ago:     delete
      else:                                  keep  "PR open or closed recently"
    elif a tag ends in -rc.<n>:              rc += version
    else:                                    keep  "no retention rule"   (sha-<sha7> alone)
  sort rc by created_at, newest first
  for rank, version in rc:
    if rank <= RC_KEEP:                      keep
    elif age < RC_MIN_AGE_DAYS:              keep
    else:                                    delete
  if every tagged version would go:          keep the newest of them (GHCR refuses to delete the last one)
report every decision (package, version id, tags, age, decision, reason) to stdout and the job summary
exit 1 if any API call failed (after trying everything else)
```

Count API errors instead of stopping at the first one, so one unreadable package does not block the
cleanup of the others; skip (and report) a package that does not exist yet. Details the pseudo-code leaves
open:

- Ages are whole days since `created_at` / `closed_at`: a pull request closed 7 days and 1 hour ago is past a
  7-day grace, a pre-release exactly 30 days old is no longer younger than 30 days.
- An unknown tag keeps even a version that also carries a `pr-*` or `-rc.` tag: deleting the version would
  delete the tag a human put there. Released and in-use pre-releases are not ranked, so they take none of the
  `RC_KEEP` places.
- The digest of a container package version is its `.name` in the API; the script calls `gh api` without
  `--jq` and filters the raw JSON with jq, which also parses the dates (no GNU `date`).
- Each pull request is looked up once per run. A failed lookup keeps its versions and counts as an API error;
  a package that answers 404 (not pushed yet, or invisible to the token) is skipped with a warning.

## 6. The nightly job

`assets/workflows/retention.yml` runs the script every night (`41 3 * * *`) and on demand:

1. Copy `scripts/retention.sh` to `scripts/ci/` (executable), `scripts/test-retention.sh` to
   `scripts/test/retention-test.sh` and the workflow to `.github/workflows/`.
2. Packages: by default every `image: true` project of `.github/affected-map.yml` (skill gha-affected-builds),
   named as `_build.yml` names its image (the last segment of the project key). Set `IMAGE_PATH_PREFIX` in
   the workflow's `env` block when the images live below the owner (`ghcr.io/<owner>/team` → `team/`), or list
   the packages in `RETENTION_PACKAGES`. The rule parameters and `CONFIG_DIR` sit in the same block.
3. Token: `GH_TOKEN: ${{ secrets.RETENTION_TOKEN || github.token }}`; section 4 says when each one can delete.
4. Let it report first. Every run writes the decision table to `$GITHUB_STEP_SUMMARY`, the audit trail of what
   was deleted. After reviewing a few dry runs, set the repository variable `RETENTION_DELETE` to `true`:
   scheduled runs delete from then on. A manual run deletes only with the boolean input `dry-run` unticked
   (`gh workflow run retention.yml -f dry-run=false`).

The job checks out the default branch whatever ref started it, holds `contents: read`, `packages: write` and
`pull-requests: read`, runs one at a time (`concurrency: retention`) within 30 minutes, and turns red when an
API call failed (each one named in the log and the summary). A first run over a registry that grew for months
can delete thousands of versions and stop at the timeout or a rate limit; the next run continues.

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
