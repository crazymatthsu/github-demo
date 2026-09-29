# Event model: which workflow runs on which event

Read this when choosing triggers, filters and concurrency, or when a workflow runs twice, runs on the wrong
thing, or does not run at all.

## Contents
1. The event → workflow table
2. Trigger filters that surprise people
3. Events that start no run
4. Concurrency per event
5. Required checks and skipped work
6. Reusable workflows and composite actions: what crosses the boundary

## 1. The event → workflow table

| Event | Workflow | Runs | Required check |
|---|---|---|---|
| `push` to a branch other than main, `hotfix/**` and `gh-readonly-queue/**` | `pr.yml` | fast tier: affected build + unit tests, lint, config lint; no images, no containers | `push-gate` (informational) |
| `pull_request` opened / synchronize / reopened / labeled | `pr.yml` | fast tier + images of the affected projects + their integration tests (+ deploy test) | `pr-gate` |
| `merge_group` (merge queue) | `pr.yml` | the same on the merge result, every project | `pr-gate` |
| `push` to main | `main.yml`, `release-please.yml` (optional), `base-image.yml` (path filter) | everything, publish, deploy dev | — |
| `push` to `hotfix/**` | `main.yml` | everything except deploy dev | — |
| `push` of a tag `v*` | `release.yml` | promote the tested digests, SBOM, GitHub Release, bump PR | — |
| `push` to main changing `config/<qa or prod env>/**` | `deploy.yml` (path filter; not a required check) | deploy the promoted env behind its Environment's reviewers, open the next env's bump PR | — |
| `schedule` | `teardown-drill.yml`, `retention.yml`, `base-image.yml` (or one `nightly.yml` calling them) | teardown drill, registry retention, weekly base image rebuild | — |
| `workflow_dispatch` | any that must be startable by hand or by another workflow | same as its scheduled or tag run | — |
| `workflow_call` | `_*.yml` | only as a job of a caller | — |

Keep one trigger workflow per row family. A single workflow with many `if: github.event_name == ...` branches
becomes unreadable, and its concurrency and permissions cannot fit every event.

## 2. Trigger filters that surprise people

- **Branch filters exclude tags.** `on.push` with only `branches` or `branches-ignore` does not run for tag pushes;
  with only `tags` it does not run for branch pushes. Put tags in the release workflow's own filter.
- **Merge-queue branches are branches.** The queue pushes `gh-readonly-queue/<base>/...` branches. Exclude them
  from `on.push` (`branches-ignore`) and listen to `merge_group` instead, or every queue entry runs twice.
- **`pull_request` default types** are opened, synchronize and reopened. Add `labeled` when a label changes what
  runs (for example `ci:full`), otherwise adding the label does nothing until the next push.
- **Path filters on the workflow that produces the required check** leave the check "Expected — waiting for
  status" forever on PRs that do not match, and the PR can never merge. Decide what to run inside the workflow
  (skill gha-affected-builds) and let the gate always report.
- **Fork PRs** run with a read-only `GITHUB_TOKEN` and no secrets. Build, but do not push; skip what needs pushed
  images, and let the merge queue or main run it.
- **`schedule`** runs on the default branch's latest commit, in UTC, can start late under load, and in public
  repositories is disabled after 60 days without repository activity.

## 3. Events that start no run

- **Anything done with `GITHUB_TOKEN`**: its pushes, tags, releases and pull requests start no workflow, except
  `workflow_dispatch` and `repository_dispatch`. A bot that creates a tag must dispatch the release workflow
  itself (`gh workflow run release.yml --ref <tag>`, needs `actions: write`). A pull request a bot opens gets
  no `pr.yml` run: close and reopen it by hand, or let a GitHub App token open it.
- **`[skip ci]`** (also `[ci skip]`, `[no ci]`, `[skip actions]`, `[actions skip]`, or a `skip-checks: true`
  trailer) in the head commit message suppresses `push` and `pull_request` runs. It also suppresses a tag push
  whose tag points at that commit: tag the tested commit, not a bot's `[skip ci]` commit on top of it.
- **Disabled workflows** (Actions tab, "..." menu) start nothing, including dispatches.

## 4. Concurrency per event

| Workflow | Group | cancel-in-progress | Why |
|---|---|---|---|
| `pr.yml` | `pr-${{ github.event.pull_request.number \|\| github.ref }}` | true | a newer push supersedes the run; the PR and the branch push are different groups, so both runs report |
| `main.yml` | `main-${{ github.ref_name }}`; bot runs `main-bot-${{ github.run_id }}` | false | a cancelled deploy is worse than a late one; a bot run must never displace a queued merge |
| `release.yml` | `release-${{ github.ref }}` | false | one release per tag, never half-done |
| `deploy.yml` | `deploy-promoted` (and `deploy-<env>` per env job) | false | a deploy is never cancelled half-way |
| `base-image.yml`, scheduled workflows | the workflow name | false | scheduled maintenance must finish |

A push to a branch with an open PR therefore shows two `pr.yml` runs on the same commit: `push-gate` and `pr-gate`.
That is expected; name the gates differently so the branch run can never satisfy the PR's required check.

## 5. Required checks and skipped work

- Require one check: the gate job (`pr-gate`), which `needs:` every job and runs with `if: always()`.
- A job skipped by its `if:` reports success, so it never blocks a merge; a workflow that did not run at all
  leaves its checks pending forever. The gate turns "skipped as expected" into an explicit summary line and
  fails on `failure` or `cancelled`.
- The gate must also fail when the job that decides what to run failed (otherwise every other job is skipped and
  the gate passes vacuously).
- Jobs of reusable workflows show up as `<caller job> / <callee job>` (for example `build / build`). Do not
  require those names: they change whenever the callee changes. Require the gate.

## 6. Reusable workflows and composite actions: what crosses the boundary

| Thing | Reusable workflow (`workflow_call`) | Composite action |
|---|---|---|
| Inputs | typed `inputs:`; pass JSON as strings and `fromJSON` them | string `inputs:` |
| Secrets | only those passed explicitly, or `secrets: inherit` | none: pass values as inputs |
| `env:` of the caller | not visible: pass through inputs | visible (same job) |
| Permissions | the caller job's `permissions:`; the callee can only reduce | the job's |
| Outputs | `outputs:` mapped from jobs; empty when the job was skipped, so default them (`\|\| '{}'`) | `outputs:` from steps |
| Runs on | its own jobs and runners | inside the calling job; every `run:` step needs `shell:` |

Use a reusable workflow for a multi-job stage (build + digest collection, an integration test job, a deploy).
Use a composite action for a step sequence several jobs repeat (registry login, build environment, stack up/down).
Put the logic itself in `scripts/` so a laptop can run it.
