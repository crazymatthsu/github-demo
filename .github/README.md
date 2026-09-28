# CI/CD — GitHub Actions (demo step 1: compose; demo step 2: kind + Helm)

Implements D7 (workflow topology), D10 (containerised execution, teardown, kind), D9 (deploy-dev,
release), D11 (Helm deploy path) and D4 (versions, tags, retention). Registry: GHCR (`ghcr.io/crazymatthsu/...`) with `GITHUB_TOKEN`
as the stand-in for JFrog. Every job runs on GitHub-hosted `ubuntu-latest`.

## Workflows

| File | Trigger | What it does |
|---|---|---|
| `workflows/pr.yml` | push to any branch except `main` / `hotfix/**`; `pull_request`; `merge_group` | `detect affected` → `lint` (hadolint, ShellCheck, script tests `scripts/test/*-test.sh`, actionlint) + `build` + `config-lint`; on PRs and the merge queue also images `pr-<n>-<sha7>`, the component IT matrix and, when `deploy-test` is set and the `source-database` image was pushed, `kind-deploy`; `pr-gate` fans in |
| `workflows/main.yml` | push to `main` (and `hotfix/**`, without deploy) | build all → component ITs → system test (our images incl. `deephaven-server`) → publish → `kind-deploy` → `deploy-dev` → tag write-back |
| `workflows/release.yml` | tag `v*` / `deephaven-server/v*`; dispatched by release-please | assert `printVersion` == tag → wait for the tested `main.yml` run → retag its digests → SBOMs → GitHub Release → `us-qa` bump PR |
| `workflows/release-please.yml` | push to `main` | keeps the release PR per line; on merge tags and dispatches `release.yml` |
| `workflows/nightly.yml` | daily 03:17 UTC; `workflow_dispatch` | GHCR retention (dry run by default) and the teardown drill (failing and cancelled run) |
| `workflows/base-image.yml` | weekly; push to `main` touching `docker/base/**` or `test-infra/ca/**`; `workflow_dispatch` | builds, verifies and pushes `base/jre21` and `base/ci-build` as `<yyyymmdd>-<run>` and `latest` |
| `workflows/config-lint.yml` | `workflow_call`; PRs touching `config/**`, `**/helm/**`, `**/docker/docker-compose.yml` | `setup-kube-tools` (helm, kubeconform) → `./gradlew configLint` (checks 1–6, 9–12: compose render, `helm lint` / `helm template` per instance, kubeconform on the rendered releases) |
| `workflows/_gradle-build.yml` | reusable | probe `base/ci-build` → build in that container (host + Temurin 21 until it exists) → images → push → digests |
| `workflows/_integration-test.yml` | reusable | `stack.sh up` → `docker compose run --rm it-runner ./gradlew <project>:integrationTest -Pcompose.managed=false` → diagnostics → `down` + `leak-check` in `always()` |
| `workflows/_docker-publish.yml` | reusable | points tag sets at tested digests (`imagetools create`, verified; version tags immutable) |
| `workflows/_kind-deploy.yml` | reusable | `kind up` (`ci-<run_id>-<attempt>`) → load this run's image by digest as `<repo>:<tag>` → one Helm release per instance directory of `config/<env>/*/<app>/` (namespace with the restricted PSS labels, Secret, `helm lint`, `upgrade --install --rollback-on-failure --wait`, rollout status, `helm test`) → smoke diff across the releases → diagnostics on failure → `kind down` + `leak-check` in `always()` |
| `workflows/_deploy-dev.yml` | reusable | Environment `dev`: targets from every flow's `config/us-dev/<flow>/workflows-config.yml` (the flow prefixed to each instance); compose targets of a flow with a `pool` (DL-39) through `scripts/pool-deploy.sh deploy` — the flow's host bundle synced to every box, each instance placed pinned → discovered → assigned, `pull` → `start` → `health` on its box — over `ssh` when `DEV_DEPLOY_SSH_KEY` is set, else `local` (the runner plays every box: validate + `start --dry-run`, the ssh commands printed); job summary per box (files, sha256) and per instance (host, how, result, command); compose targets of a flow without a pool keep the placeholder (`run-compose.sh … start --dry-run` + the SSH command, `TODO(DL-35)`); helm targets of cluster `kind-ci` deployed into a kind cluster created in the job (`deploy-<run_id>-<attempt>`, deleted and leak-checked in `always()`), any other cluster fails with `TODO(Phase 3)`; write-back of `IMAGE_TAG` and `image.tag` for every deployed instance and of the box (`host`) of every pooled one; GitHub Deployment |

Composite actions: `setup-build-env` (JDK when not in ci-build, Gradle cache, base images: GHCR digest
or local bootstrap build), `registry-login` (GHCR token; `oidc` mode stubbed, DL-18),
`compose-stack` (wraps `test-infra/compose/stack.sh`), `affected-matrix` (runs `scripts/ci/affected.py`
over `affected-map.yml`; also reports `deploy-test`), `setup-kube-tools` (kind, kubectl, helm, kubeconform
pinned in `test-infra/kind/versions.env`, checksummed), `kind-cluster` (wraps `test-infra/kind/kind.sh`),
`helm-deploy-instance` (wraps `scripts/helm-deploy-instance.sh` for one instance or a JSON list of targets).
Scripts: `scripts/ci/` (affected detection, digest resolution, retagging, tag and placement write-back, retention,
JUnit summary); `scripts/helm-deploy-instance.sh` and `scripts/helm-smoke-diff.sh` (D11 §8.3); `scripts/pool-deploy.sh`
(host pools, DL-39: bundle, plan, sync, discover, deploy, status). Script tests: `scripts/test/*-test.sh`, plain bash
with stub `ssh` / `rsync` / `docker` (no host, registry or engine is reached), run by `pr.yml`'s lint job (step
"Script tests") and locally with `bash scripts/test/pool-deploy-test.sh` (needs mikefarah yq v4, jq, rsync, git).

## Which tests run when (D7 §5.3)

| Event | Runs |
|---|---|
| push to a branch | affected build + unit tests, lint (with the script tests), config-lint — no images, no containers; its gate is reported as `push-gate` |
| pull request | the same + images `pr-<n>-<sha7>` + component ITs of the affected projects; everything when shared inputs changed (`affected-map.yml` → `shared`) or with label **`ci:full`**; the kind deploy test when `deploy-test` matches (`**/helm/**`, `config/**`, `test-infra/kind/**`, `source-database`, the kind actions) and this run pushed the `source-database` image — a config-only PR builds no image, so there `config-lint`'s `helm lint` / `helm template` is the check and `main` runs the kind deploy; docs-only changes skip all of it |
| merge queue | everything (the actual merge result is proven) |
| `main` | everything, the system test, publish, the kind deploy test, deploy-dev (compose: host pools through `scripts/pool-deploy.sh`, transport `local` until the boxes exist; Helm into `kind-ci`) |

See what CI will pick for your branch: `python3 scripts/ci/affected.py --base origin/main`.

## Repository settings (once)

- **Branch protection / ruleset on `main`**: require a PR, require status check **`pr-gate`** — the
  only required check (matrix shapes can change freely) — CODEOWNERS review, linear history; merge
  queue when the plan offers it (`pr.yml` already listens to `merge_group`).
- The **write-back** (`scripts/ci/write-back-tag.sh`) pushes `chore(config): us-dev deployed <tag>
  [skip ci]` straight to `main` as `github-actions[bot]`. A ruleset that blocks direct pushes rejects
  it: grant a bypass to the identity that pushes — in the enterprise a GitHub App (DL-09), whose token
  then replaces `GITHUB_TOKEN` in `_deploy-dev.yml`, and whose `<app>[bot]` login replaces
  `github-actions[bot]` in `main.yml`'s loop guard.
- **Actions → General**: allow GitHub Actions to create pull requests (release-please, the qa bump PR).
- **Environment `dev`**: deployment branches `main`; no reviewers (D9 §6.2). The SSH deploy key of
  DL-35 lives here as `DEV_DEPLOY_SSH_KEY` (the private key of the boxes' `deploy` user): it is the switch
  for the host pools of DL-39. Without it deploy-dev runs `scripts/pool-deploy.sh` with the `local` transport
  (the runner plays every box); with it, the `ssh` transport — the key goes into the compose step's
  `ssh-agent` only, and the reviewed `config/<env>/known_hosts` (`ssh-keyscan` of every box, committed) must
  exist, or the deploy stops (exit 5): an unknown host key is never accepted. The boxes' forced command must
  accept `run-compose.sh ... pull|start|stop|health|status` and the bundle's `rsync --server` into the pool's
  `root`. The kubeconfig of a persistent dev cluster (Phase 3) will live here as `DEV_KUBECONFIG_<CLUSTER>` —
  until then the flows' `workflows-config.yml` name cluster `kind-ci`, a kind cluster inside the job.
- **Packages**: images are created by the workflows and linked to this repository through the
  `org.opencontainers.image.source` label. If a package does not grant this repository access
  (Package settings → Manage Actions access), pushes and retention deletes fail with 403.
- Optional: repository variable `RETENTION_DRY_RUN=false` lets the scheduled retention delete;
  secret `RETENTION_TOKEN` (read:packages, delete:packages) when `GITHUB_TOKEN` may not delete.
- Label **`ci:full`** (create it once).

## First run (bootstrap)

The app images build `FROM ghcr.io/crazymatthsu/base/jre21` and the build job runs in
`ghcr.io/crazymatthsu/base/ci-build`, which `base-image.yml` publishes. Until then:

1. `_gradle-build.yml`'s probe finds no `base/ci-build:latest`, so the build job runs on the runner
   host with Temurin 21 (`setup-java`).
2. `setup-build-env` builds `base/jre21` (and, in the IT jobs, `base/ci-build` for `it-runner`) locally
   from `docker/base/*/Dockerfile` with a GitHub Actions layer cache, tags it
   `…:bootstrap-<run_id>-<attempt>` (never pushed) and hands it to Gradle as `BASE_IMAGE`.
3. Run **base-image.yml** once (Actions → base-image → Run workflow). From then on every job uses the
   published images, pinned by digest for the whole run.

A PR that changes `docker/base/**` rebuilds the base images locally the same way, so the change is
tested before `base-image.yml` publishes it on merge.

## Versions, tags and releases

- Versions come from git only (`buildlogic.git-version`): PR `<next>-pr.<n>.<sha7>` → image
  `pr-<n>-<sha7>`; `main` `<next>-rc.<n>` → images `<next>-rc.<n>`, `sha-<sha7>`, `main`; release tag
  `vX.Y.Z` → `X.Y.Z` (+ `X.Y`, `X`, `latest` when it is the newest), `sha-<sha7>`.
- `main.yml` always builds the pre-release form (it ignores a release tag that release-please may
  already have put on the commit); `release.yml` then promotes those tested digests — nothing is
  rebuilt, so a released image's labels still carry its `-rc` version.
- Release PRs come from release-please (`release-please-config.json`: `.` = connector family, tags
  `vX.Y.Z`; `deephaven-server`, tags `deephaven-server/vX.Y.Z`). `.release-please-manifest.json` is
  release-please's bookkeeping only — the build never reads it. Emergency route: push an annotated tag
  by hand on a commit `main.yml` has tested.
- Tags and PRs created with `GITHUB_TOKEN` start no workflow: release-please.yml therefore dispatches
  `release.yml`, and a bump PR opened by `release.yml` needs a close / reopen to run `pr-gate`
  (a GitHub App token removes both work-arounds, DL-09).

## Loop guard (DL-36)

The write-back commit carries `[skip ci]`, and `main.yml` skips every job when the actor is
`github-actions[bot]` (such runs also get their own concurrency group, so they can never displace a
queued merge). With `GITHUB_TOKEN` the push starts no run at all; the guards matter once an App token
pushes. A human config-only merge still runs the full pipeline and deploys.

## Teardown guarantee (DL-27)

Every IT job: labelled compose project `ci-<run_id>-<attempt>`, `always()` `stack.sh down` and
`stack.sh leak-check`, `timeout-minutes` on every job, ephemeral runner. Every kind job: cluster
`ci-<run_id>-<attempt>` (`deploy-<run_id>-<attempt>` in deploy-dev), `always()` `kind.sh down` and
`kind.sh leak-check` (no cluster, node container or `kind` network left). `nightly.yml` proves it on a
failing run (`teardown-drill-fail`) and on a cancelled run (`teardown-drill-cancel` dispatches a run
that cancels itself with its stack up, then checks that run's teardown and leak-check steps).

## Only provable on GitHub

A container job with an empty image running on the host; socket access from the ci-build job
container through `--group-add <docker GID>` as user 1001; `environment.deployment: false`; GHCR
package permissions for push, retag and delete with `GITHUB_TOKEN`; `imagetools create
--prefer-index=false` preserving digests (every write is verified, so a mismatch fails loudly);
release-please's tags, release and output names; the write-back push under the chosen branch
protection; the `ssh` transport of the host pools against real boxes (forced command, `rsync` over it, the
pinned host keys, the pool guard between boxes) once the boxes and `DEV_DEPLOY_SSH_KEY` exist; `always()` steps after a cancel (the nightly drill checks it); runner memory for
Deephaven + SQL Server + it-runner; merge queue availability on the plan; kind creating its cluster
within `--wait 120s` and pulling `kindest/node`, `kind load` into containerd, rollout, `helm test`
and the smoke diff, kubeconform's schema download, the pinned tool downloads with their checksums.
