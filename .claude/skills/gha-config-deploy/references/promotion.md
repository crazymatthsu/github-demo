# Promotion: dev deploys then records, qa and prod record then deploy

Read this when you wire `deploy-dev` into the main pipeline, set up the write-back identity and the rulesets, or
build the bump pull requests that promote a release to qa and prod.

## Contents

1. The model
2. dev: deploy after main passes, then write back
3. The loop guard, and why it has three parts
4. Write-back identity, rulesets and bypass
5. qa and prod: bump pull requests approved by CODEOWNERS
6. Deploying qa and prod: the promotion job
7. Promoting a config change (not an image)
8. Rollback
9. Later: a GitOps controller
10. Repository settings checklist

## 1. The model

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  merge["merge to main"] --> main["main.yml: build, test,<br/>publish the rc tag"]
  main --> dd["deploy-dev<br/>(the dev Environment)"]
  dd --> wb["write-back by the bot:<br/>IMAGE_TAG, image.tag, host,<br/>[skip ci]"]
  wb -. "loop guard:<br/>no second run" .-> main
  tag["release tag vX.Y.Z"] --> rel["release workflow:<br/>promote the tested digest"]
  rel --> pr["bump PR on<br/>config/QA-ENV/**"]
  pr --> ok{"CODEOWNERS<br/>approve"}
  ok -- merge --> qa["deploy.yml: qa, after its<br/>Environment reviewers approve"]
  qa --> prodpr["prod bump PR: what qa runs,<br/>change ticket"]
  prodpr --> prod["deploy.yml: prod,<br/>inside its window"]
```

- dev is deployed first and recorded afterwards: every merge to `main` that passed CI deploys, and the bot
  writes the deployed tag back into the tree. Fast feedback, no human in the loop, git still says what runs.
- qa and prod are recorded first and deployed afterwards: a pull request changes the tag in
  `config/<env>/**`, CODEOWNERS approve it, and the merge is the deploy intent. Git is the deployment record
  in every env, and a rollback is always a revert.
- Nothing is rebuilt after `main`: the qa and prod bump PRs carry the tag of the digest that main tested (see
  gha-versioning-release for tags and promotion by digest).

## 2. dev: deploy after main passes, then write back

The last job of `main.yml` calls the reusable `_deploy-dev.yml` (the skill's template), only on `main` and never
for the bot:

```yaml
concurrency:
  # One queue per branch, never cancelled; runs started by the bot get a group of their own.
  group: ${{ github.actor == '__BOT_LOGIN__' && format('main-bot-{0}', github.run_id) || format('main-{0}', github.ref_name) }}
  cancel-in-progress: false

jobs:
  # build, tests, publish ... (gha-pipeline-design)
  deploy-dev:
    needs: [build, publish]
    if: github.ref == 'refs/heads/main' && github.actor != '__BOT_LOGIN__'
    uses: ./.github/workflows/_deploy-dev.yml
    permissions:
      contents: write     # the write-back commit
      deployments: write  # the GitHub Deployment record
      packages: read
    with:
      tag: ${{ needs.build.outputs.version }}
      images: ${{ needs.build.outputs.images }}
      # env: defaults to the dev env set in _deploy-dev.yml; pass it to deploy another dev env
    secrets: inherit
```

This is the `deploy-dev` job of gha-pipeline-design's `main.yml` template. `__BOT_LOGIN__` is the login of the
identity that pushes the write-back: `github-actions[bot]` with `GITHUB_TOKEN`, `<app-slug>[bot]` with a GitHub
App.

- Deploy only what passed: `deploy-dev` needs the job that published the tested digest. A config-only merge still
  runs the pipeline and deploys (the affected-builds map may skip the build and deploy the last published tag).
- Environment `dev`: deployment branches limited to `main`, no reviewers, the deploy secrets. A job on another
  branch that references it fails ("not allowed to deploy to dev due to environment protection rules"), which is
  why the job condition also checks the ref (a `hotfix/**` run of `main.yml` skips `deploy-dev`).
- `environment.deployment: false` in `_deploy-dev.yml` keeps the Environment's rules and secrets without the
  automatic deployment object, because the job creates its own Deployment with a payload (env, tag, images,
  targets) and statuses `in_progress`, then `success` / `failure` with the run URL.
- The write-back commits `IMAGE_TAG` in `compose.env`, `image.tag` in `values.yaml` of every instance that
  deployed (never a failed one) and the `host` of every pooled instance, as one commit per run:
  `chore(config): <env> deployed <tag> [skip ci]`, body listing the instances, boxes and run URL.
- Never tag or release the write-back commit: it has no main run of its own (it carries `[skip ci]`), and
  `[skip ci]` in a tagged commit also suppresses the tag's workflows. Release the merge commit main tested.

## 3. The loop guard, and why it has three parts

Config lives in the repository that deploys it, so the write-back is a push to `main`, and a push to `main`
starts `main.yml`. Three guards, each covering what the others miss:

| Guard | Stops | Why the others do not cover it |
|---|---|---|
| `[skip ci]` in the write-back message | any `push` / `pull_request` run for the write-back (no minutes, no lint of a bot edit) | it depends on the message: a replay without the marker runs, and a human who copies the marker skips CI by accident (warn in PR lint) |
| `if: github.actor != '<bot>'` on the jobs | the jobs of a run the bot's push started anyway | it needs a stable bot identity (an App's `<slug>[bot]`), and the run still enters the concurrency queue |
| a concurrency group of its own for bot runs | a bot run displacing a human's queued run | GitHub keeps one pending run per group and a newer pending run cancels the older pending one: a bot run in the shared group would cancel a human's queued deploy before the actor check skipped its jobs |

Do not use `paths-ignore: config/**` on `main.yml` as a guard: a human config-only merge must still deploy. With
`GITHUB_TOKEN` the write-back push starts no workflow in the first place (events created by `GITHUB_TOKEN` never
do, except `workflow_dispatch` and `repository_dispatch`); the guards matter from the day an App token pushes.

## 4. Write-back identity, rulesets and bypass

- `GITHUB_TOKEN` (the default of the template) pushes as `github-actions[bot]`, starts no run, and needs
  `contents: write`. It is enough while `main` accepts direct pushes from workflows.
- A ruleset (or classic branch protection) that requires pull requests on `main` rejects the push
  (`GH013: Repository rule violations found`; `GH006: Protected branch update failed` with classic protection).
  Grant a bypass to the pushing identity: a GitHub App installed on the repository with `contents: write`, added
  to the ruleset's bypass list. The template switches to it when the repository variable `WRITE_BACK_APP_ID` and
  the secret `WRITE_BACK_APP_PRIVATE_KEY` exist (`actions/create-github-app-token`), commits as `<slug>[bot]`,
  and `main.yml`'s guard must then name that login.
- The alternative, a write-back pull request with auto-merge, keeps the ruleset without a bypass but needs the
  App token too (a PR opened with `GITHUB_TOKEN` runs no checks, so it never becomes mergeable) and adds a merge
  delay per deploy.
- Never a personal access token: it ties deploys to a person, outlives them and is broader than one repository.
- The bot writes to dev paths and opens PRs; it can never approve (CODEOWNERS and required reviews still apply).
- `write-back-tag.sh` distinguishes a lost race (the branch moved: it re-applies the edits on the new tip and
  pushes again, no rebase) from a rejection (the branch did not move: it stops at once and prints the bypass hint).

The reference's write-back pushed with `GITHUB_TOKEN` to a `main` without a blocking ruleset and planned the App
for when one arrives; the App path of the template is therefore unproven there.

## 5. qa and prod: bump pull requests approved by CODEOWNERS

The release workflow (triggered by the release tag, see gha-versioning-release) promotes the tested digest in the
registry and then opens the bump PR for the first promoted env, changing only `config/<qa env>/**`. Its bump job
takes the edit as a command; with this tree that is the skill's `set-image-tag.sh`:

```yaml
# release.yml (gha-versioning-release), env of the bump job and its __BUMP_COMMAND__
    env:
      BUMP_ENV: qa            # the first promoted env
      BUMP_DIR: config/qa
# __BUMP_COMMAND__ (VERSION, APPS and IMAGES come from the resolve job):
#   IMAGE_DIGESTS="$IMAGES" bash scripts/ci/set-image-tag.sh --apps "$APPS" "$BUMP_DIR" "$VERSION"
```

`set-image-tag.sh` sets `image.tag` and `image.digest` in `values.yaml` (and `IMAGE_TAG` in `compose.env`) of every
instance of the released apps, never in `app-common/`, prints the changed files and nothing when the env already
runs the release; the bump job turns them into one PR per release tag (`release-bump/<env>/<tag>`). The next env
gets its PR from the promotion job (section 6) with `set-image-tag.sh --from config/<qa env>`: exactly the tag and
digest qa runs, never recomputed.

- CODEOWNERS on `config/*-qa/**` and `config/*-prod/**` (and the ruleset's "Require review from Code Owners")
  make the approval of the owning team the deploy intent. One owner line needs one approval from any listed
  owner; for two distinct approvals on prod add required reviewers on the promotion job's Environment
  (`<region>-prod`) or raise the ruleset's required approvals.
- Extend the PR body with the images by digest, the release link and the main run that tested them (the
  snippet keeps it short); the prod PR also carries a `Change-Ticket:` trailer that a PR lint checks.
- qa and prod values should pin the digest next to the tag (`image.digest: sha256:...`, or
  `IMAGE_TAG=1.5.0@sha256:...`); config lint's tag policy (check 10) rejects floating tags there.
- `gh pr create` with `GITHUB_TOKEN` needs the repository setting "Allow GitHub Actions to create and approve pull
  requests"; without it the call fails with "GitHub Actions is not permitted to create or approve pull requests".
  The PR it creates starts no workflow, so its required checks never report: a human closes and reopens it (the
  reopen event is theirs), or the job uses an App token. The reference used `GITHUB_TOKEN` with the close/reopen
  note in the PR body, and its qa bump job only printed a notice because no qa tree existed.
- The prod PR copies the tag (and digest) proven in qa, opened by the promotion job after the qa deploy (or by
  ops with `set-image-tag.sh --from`), never computed again.

## 6. Deploying qa and prod: the promotion job

The merged bump PR is the deploy intent; `deploy.yml` (template) applies it:

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  push["push to main changing<br/>config/QA-ENV or config/PROD-ENV"] --> plan["plan: promoted envs,<br/>stage order"]
  disp["workflow_dispatch:<br/>env, instances"] --> plan
  plan --> dep["_deploy-env.yml per env,<br/>one at a time"]
  dep --> env{"Environment reviewers<br/>approve"}
  env --> helm["helm-deploy-instance.sh per instance:<br/>tag and digest from the tree"]
  helm --> next["bump PR for NEXT_ENV:<br/>set-image-tag.sh --from"]
```

- **Trigger**: a push to `main` that changed `config/**`; only envs matching `PROMOTED_ENV_PATTERN` deploy (dev
  paths are ignored, `deploy-dev` owns dev). Not a required check, so its path filter blocks nothing. A dispatch
  (`gh workflow run deploy.yml -f env=prod`) re-applies what `main` records, optionally for a few instances.
- **Plan from the last successful deploy**: each deploy job records a GitHub Deployment (with its commit) in the
  env's Environment, and the plan diffs `config/<env>/` from the newest successful one (from the push's own base
  for an env never deployed this way). GitHub keeps one pending run per concurrency group, so a newer run can
  replace a pending one; a failed or rejected deploy leaves its change undeployed too. Either way the next run
  still finds the change and deploys it: nothing a skipped run carried is lost. A rejected deploy is therefore
  requested again by the next run; revert the bump PR to withdraw it.
- **Order**: one env at a time in `STAGE_ORDER` (qa, staging, prod); a failure stops the later envs.
- **Approval before credentials**: each env's job runs in the GitHub Environment named like the env. Its required
  reviewers approve before any step runs, its deployment branch rule admits only `main`, and its secret
  `DEPLOY_KUBECONFIG` exists nowhere else. `helm-deploy-instance.sh` refuses a promoted env unless the job names it
  in `DEPLOY_ALLOW_ENV`, so a dev job or a PR job cannot deploy prod even by mistake.
- **What is deployed**: every instance of the env, each as release `<app>-<instance>` in namespace `<flow>`, with
  the tag and digest its `values.yaml` pins; instances that record no tag yet are skipped. Every instance, not
  only the changed ones, so a run also repairs drift a lost run left behind. Unchanged releases get a new Helm
  revision without a rollout.
- **Next env**: after a successful deploy, `NEXT_ENV` (`{"qa": "prod"}`) opens or updates the rolling PR
  `release-bump/<next>/from-<env>` with exactly what the env now runs. Its CODEOWNERS (and a change ticket for
  prod) approve it; the merge starts this workflow again.
- **Failure**: Helm rolled the failed instance back (a first install stays for diagnostics); git still names the
  new tag, so the job fails with that note. Re-run it after a fix, or revert the bump PR to go back.
- **Not covered**: compose hosts in qa or prod (add a step like `_deploy-dev.yml`'s compose step with the
  Environment's SSH key); deployment windows (an Environment wait timer or a custom protection rule; a GitOps
  controller's sync windows); deleting a removed instance's release (the plan reports it; uninstall by hand).

## 7. Promoting a config change (not an image)

One PR per env, changing only `config/<env>/**`, reviewed under that env's CODEOWNERS; the parity check (config
lint check 8) reports keys that exist in dev but not in the next env. Never copy directories between envs (`us-dev/`
over `us-qa/`): it drags dev-only values along and bypasses review. Promotion tooling may pre-fill the PR; a
human approves it.

## 8. Rollback

| Env | Mechanism |
|---|---|
| dev | revert the offending change on `main`: the pipeline builds, deploys and writes back again. A failed deploy already left the previous version running (compose restarts the previous tag, Helm rolls back) and wrote nothing back for it |
| qa, prod | revert the bump PR (same gates, expedited approvals); the promotion job deploys the previous tag, still in the registry (retention never deletes a tag the tree references) |
| emergency | `helm rollback` or the controller's rollback, with its auto-sync paused until the revert merges, otherwise self-heal re-applies the bad version |

## 9. Later: a GitOps controller

When clusters outgrow CI push, let a controller pull from the tree:

- Argo CD: an ApplicationSet per env with a git directory generator over `config/<env>/*/*/*` (excluding
  `app-common` and `_common`) in a matrix with a cluster generator; one Application `<app>-<instance>` per
  instance, `valueFiles` and `fileParameters` pointing at the layers, destination namespace the flow. Sync windows
  on an AppProject per env/flow enforce deployment windows in the cluster. Per-cluster installs for prod keep
  prod credentials out of GitHub entirely.
- Flux: a `HelmRelease` per instance (generated), real Helm history; windows only by suspending on a schedule.
- `deploy-dev` then shrinks to: wait for the Application's health, smoke test, write back. The inventory's helm
  part retires (config lint check 11 becomes the ApplicationSet dry run, check 13). Image-updater bots are fine
  for dev only; an automation that picks prod images contradicts the approval gate.

## 10. Repository settings checklist

- Ruleset on the default branch: pull request required, the single gate check required, "Require review from Code
  Owners", no force pushes; bypass for the write-back App when it pushes directly.
- `.github/CODEOWNERS` from `assets/CODEOWNERS.example`: flows own `config/*/<flow>/`, ops own qa and prod.
- Environment named like the dev env (`dev`): deployment branches `main`; secrets `DEV_DEPLOY_SSH_KEY`,
  `DEV_KUBECONFIG`.
- One Environment per promoted env (`qa`, `prod`, `eu-prod`, ...) for the promotion job: required reviewers (two
  for prod, "prevent self-review"), deployment branches `main`, secret `DEPLOY_KUBECONFIG`, optional variable
  `KUBE_CONTEXT`.
- Actions > General: "Allow GitHub Actions to create and approve pull requests" (bump PRs with `GITHUB_TOKEN`).
- Optional: variable `WRITE_BACK_APP_ID` and secret `WRITE_BACK_APP_PRIVATE_KEY` for the App write-back.
- Registry packages grant this repository Actions access (pushes and promotions otherwise fail with 403).
