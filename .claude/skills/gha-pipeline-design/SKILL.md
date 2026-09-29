---
name: gha-pipeline-design
description: 'Design, generate, review or fix a complete GitHub Actions CI/CD pipeline: which workflow runs on which event (push, pull request, merge queue, main, tag, schedule), thin trigger workflows over reusable `_*.yml` workflows, composite actions and scripts, one required gate check, concurrency, least-privilege permissions, timeouts, bot loop guards, and diagrams of what runs when. Use it whenever someone asks to set up, add, restructure or review CI/CD or GitHub workflows for a repository, add PR checks or required status checks, enable a merge queue, automate build, test, release or deploy, or asks why workflows run twice, never start, or block merging, even if they never say "pipeline". It is the entry point: it decides which parts a repository needs and routes to gha-affected-builds, gha-versioning-release, gha-ephemeral-test-envs, gha-build-images and gha-config-deploy.'
---

# GitHub Actions pipeline design

## What this skill gives you

A proven shape for a GitHub Actions CI/CD pipeline and a procedure to build it for any repository: the event
model, the file layout, the one required check, concurrency and permissions, and how to validate and document
the result. Five companion skills cover the big parts in depth; this skill decides which parts a repository
needs, generates the trigger workflows and the build, and wires the rest together.

## Principles

1. **One pipeline per event family, each with a clear budget.** Branch pushes get fast feedback (affected build,
   unit tests, lint; no images, no containers). Pull requests and the merge queue get the fast tier plus images
   and integration tests of what changed. main gets everything, publishes, and deploys dev. Tags release by
   promotion. Schedules do maintenance. Why: each event carries a different risk and a different time budget;
   one workflow full of `if: github.event_name == ...` fits none of them. Table: references/event-model.md.
2. **Thin trigger workflows, logic below them.** Trigger workflows (`pr.yml`, `main.yml`, `release.yml`,
   `deploy.yml`, the scheduled ones, `base-image.yml`) only decide what runs in which order. Multi-job stages live in reusable
   workflows named `_*.yml` (the underscore says "never triggered by an event"). Step sequences that several jobs
   repeat live in composite actions. Real logic lives in `scripts/` with `--help`, documented exit codes and
   tests. Why: the same build runs from PRs and main with different inputs, laptops run the same scripts, and
   YAML stays declarative enough to review.
3. **Exactly one required status check: the gate.** A fan-in job with `if: always()` needs every job, fails on
   `failure` or `cancelled` (and when the job that decides what runs failed), and passes when work was skipped
   on purpose. Branch protection requires only `pr-gate`; the branch-push run names it `push-gate`. Why: matrix
   and reusable-job names change, and a required check that never reports blocks merging forever.
4. **Never path-filter the workflow that produces the required check.** Decide what to build inside the run
   (skill gha-affected-builds) and let the gate report every time. Why: a filtered-out workflow leaves the
   required check pending, and the PR cannot merge.
5. **Build once, test that artifact, promote its digest.** main builds each image once, tests it by digest,
   and a release adds version tags to that same digest (skill gha-versioning-release). Why: what was tested is
   byte for byte what ships; nothing is rebuilt at release time.
6. **Every test environment is throwaway and always torn down.** Unique per run and attempt, diagnostics before
   teardown, teardown and leak check in `always()` (skill gha-ephemeral-test-envs). Why: leaked stacks make the
   next run flaky, and a failure without logs costs a rerun.
7. **CI and laptops share one build environment.** The build runs inside a pinned CI image, and base images
   carry the enterprise CA (skill gha-build-images). Why: "works on my machine" and certificate errors disappear.
8. **Deploy from configuration in git.** dev deploys automatically after main passes and records what it
   deployed; qa and prod change only through reviewed pull requests (skill gha-config-deploy). Why: the git
   history is the deployment log, and approvals are code review.
9. **Least privilege.** `permissions: contents: read` at the top of every workflow; each job asks for what it
   needs (`packages: write` to push, `contents: write` to write back or release, `actions: write` to dispatch).
   Pass secrets only into the workflows that deploy. Why: a compromised dependency or action gets only its job's
   token scopes.
10. **Every job has `timeout-minutes`; concurrency matches the event.** PR runs cancel superseded ones; main
    queues and never cancels; bot runs get their own group. Why: hung jobs burn runner hours, and a cancelled
    deploy is worse than a late one.
11. **Pin what runs.** Actions at a major version (update deliberately), tools at exact versions in one file with
    checksum-verified downloads, base images resolved to a digest once per run and passed to every job. Why:
    reproducible runs, and every update is a reviewed one-line change.
12. **The pipeline is code.** actionlint (with ShellCheck on `run:` blocks), ShellCheck on scripts, hadolint on
    Dockerfiles and plain-bash script tests run in the PR lint job; a README with one diagram per trigger explains
    it. Why: workflow bugs surface in the PR that introduces them, not on main at release time.

## Procedure

### 1. Discover from the repository first

Read before asking. Find:
- the build tool and its build + unit-test command (Gradle `./gradlew build`, Maven `./mvnw -B verify`,
  npm/pnpm `pnpm -r build test`, Go `go build ./... && go test ./...`, Python `uv run pytest`);
- the projects or modules, and which produce deployables (container images, packages, Helm charts);
- tests that need services (databases, brokers) or a cluster;
- environments, deploy targets, the registry, existing workflows (keep what works; note their triggers and
  required checks), the branch model (trunk + short-lived branches, `hotfix/**`), merge queue availability;
- constraints: self-hosted runners, an enterprise CA or proxy, a mandated registry (GHCR, JFrog, ECR), OIDC.

Ask the user only what the repository cannot tell: usually which environments exist and who approves prod.

### 2. Choose the parts

| Question | Default | Skill |
|---|---|---|
| More than one module or deployable? | affected detection with a path map; unmapped paths build everything | gha-affected-builds |
| Produces container images? | git-derived versions; build once on main; promote by digest | gha-versioning-release |
| How are releases cut? | annotated tag `vX.Y.Z` on a tested main commit; release-please optional | gha-versioning-release |
| Integration tests need services? | a docker compose stack per run with guaranteed teardown | gha-ephemeral-test-envs |
| Ships Helm charts? | a kind deploy test in PRs and main | gha-ephemeral-test-envs |
| Complex toolchain, enterprise CA or proxy? | a pinned CI build image and a runtime base image | gha-build-images |
| Deploys? | config tree in git; deploy dev on main with write-back; bump PRs for qa and prod | gha-config-deploy |

A single small project may need only `pr.yml`, `main.yml` and `_build.yml` from this skill.

### 3. Lay out the files

```text
.github/
  workflows/
    pr.yml                 push to branches, pull_request, merge_group         (this skill)
    main.yml               push to main and hotfix/**                          (this skill)
    _build.yml             reusable: build, unit tests, images                 (this skill)
    _integration-test.yml  reusable: compose stack per project                 (gha-ephemeral-test-envs)
    _kind-deploy.yml       reusable: Helm releases in a kind cluster           (gha-ephemeral-test-envs)
    _promote.yml           reusable: point tags at tested digests              (gha-versioning-release)
    release.yml            release tags                                        (gha-versioning-release)
    _deploy-dev.yml        reusable: deploy the dev environment                (gha-config-deploy)
    deploy.yml             qa / prod: deploy merged bump PRs, per env          (gha-config-deploy)
    _deploy-env.yml        reusable: one promoted env, behind its Environment  (gha-config-deploy)
    base-image.yml         CI and runtime base images                          (gha-build-images)
    teardown-drill.yml     scheduled: teardown and leak check still work       (gha-ephemeral-test-envs)
    retention.yml          scheduled: registry cleanup, dry run first          (gha-versioning-release)
    README.md              diagrams: what runs when                            (this skill)
  actions/<name>/action.yml  composite actions: affected-matrix, registry-login, setup-build-env, compose-stack, ...
  affected-map.yml           path map and project registry                     (gha-affected-builds)
  CODEOWNERS
scripts/ci/                  logic the workflows call; scripts/test/*-test.sh tests it
```

### 4. Generate from the templates

1. Copy `assets/workflows/pr.yml`, `main.yml` and `_build.yml` into `.github/workflows/`.
2. Replace every `__TOKEN__` (each template lists its tokens in its header). Keep the file names: the templates
   call each other by path.
3. Delete optional jobs you do not adopt, and remove them from the gate's `needs` and from `main.yml`'s chain.
   Without gha-affected-builds, drop `detect-affected` and pass `projects: all`.
4. Take the companion templates from the other skills and adapt them the same way.
5. Keep job names stable (`build`, `integration-test`, `publish`, `deploy-dev`, gate `pr-gate`): diagrams,
   summaries and branch protection refer to them.

### 5. Validate, then prove it on a branch

- Run `bash <this skill>/scripts/lint-pipeline.sh --install --repo <target repository>`: actionlint,
  ShellCheck, hadolint, YAML parsing and `scripts/test/*-test.sh`, on committed and new (not yet staged) files.
  Nothing in it is repository-specific; also copy it to the target's `scripts/ci/` so contributors run what
  the lint job runs.
- Push a branch and expect `push-gate` green. Open a PR and expect `pr-gate` green, with the jobs you expect
  skipped. Read each job summary, not only the colour.
- Merge and watch the first main run end to end; the first release and the first deploy each deserve a watched run.

### 6. Protect main and set the repository settings

- Ruleset on main: pull request required, status check `pr-gate` required (only that one), CODEOWNERS review,
  merge queue when the plan offers it (`pr.yml` already listens to `merge_group`).
- Settings → Actions → General: allow GitHub Actions to create and approve pull requests if a bot opens PRs
  (release-please, bump PRs).
- Packages: give the repository Actions access to each container package, or pushes and retags fail with 403.
- Environments (`dev`, `qa`, `prod`): deployment branch rules and reviewers; deploy secrets live there.
- If main forbids direct pushes, grant a bypass to the identity that writes deployed tags back.
- Create the labels the pipeline reads (`ci:full`).

### 7. Document it

Write `.github/workflows/README.md` with one diagram per trigger, per references/documenting-pipelines.md, and
check it with `scripts/render-mermaid.cjs`. GitHub renders it below the workflow file list.

## Templates and scripts

| File | Purpose | Adapt |
|---|---|---|
| `assets/workflows/pr.yml` | push / pull_request / merge_group pipeline: detect-affected, lint, build, integration-test, deploy-test (kind), gate | `__APP_PROJECT__` (deploy-test); drop optional jobs (and their gate `needs` and env lines); lint versions |
| `assets/workflows/main.yml` | main and hotfix pipeline: build all, integration tests, deploy-test (kind), publish, deploy-dev, loop guard | `__BOT_LOGIN__`, `__APP_PROJECT__` (deploy-test); drop optional jobs; add a system test if the repo has one |
| `assets/workflows/_build.yml` | reusable build: plan from the project registry, build + unit tests, version, images, digests | `__BUILD_COMMAND__`, `__IMAGE_NAMESPACE__`, `__VERSION_SCRIPT__`; container build per gha-build-images |
| `scripts/lint-pipeline.sh` | run the lint job's checks locally (`--install` fetches pinned linters) | none |
| `scripts/render-mermaid.cjs` | parse and render the README's Mermaid diagrams in headless Chromium; `--parse-only` checks the syntax in Node on jsdom when no browser can be installed | none |
| `references/event-model.md` | triggers, filters, events that start nothing, concurrency, required checks, reusable-workflow boundaries | — |
| `references/gotchas.md` | symptom → cause → fix catalogue | — |
| `references/documenting-pipelines.md` | page structure, legend, Mermaid layout rules, validation | — |

Interfaces the templates rely on (the companion skills implement them):
- `_build.yml` outputs `version`, `images` (JSON project → `repo:tag@sha256:…`), `image-tags` (JSON project →
  tags), `it-projects` (JSON list), `all` (`'true'` when every project was selected); it reads the project
  registry `projects:` from `.github/affected-map.yml`.
- `_integration-test.yml` inputs `project`, `images`, `retention-days`. `_kind-deploy.yml` inputs `images`,
  `retention-days` (the chart, instances and project default to its placeholders).
- `_promote.yml` inputs `images`, `tags`. `_deploy-dev.yml` inputs `tag`, `images` (and `env`).
- `.github/actions/affected-matrix` outputs `projects`, `matrix`, `docs-only`, `deploy-test`, `reason`.

## The gate job

```yaml
  gate:
    name: ${{ github.event_name == 'push' && 'push-gate' || 'pr-gate' }}
    if: always()
    needs: [detect-affected, lint, build, integration-test, deploy-test]   # every job of the workflow
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Evaluate
        env:
          NEEDS: ${{ toJSON(needs) }}
        run: |
          set -euo pipefail
          jq -r 'to_entries[] | "| \(.key) | \(.value.result) |"' <<<"$NEEDS" >> "$GITHUB_STEP_SUMMARY"
          [[ $(jq -r '."detect-affected".result' <<<"$NEEDS") == success ]] || { echo "::error::detector failed"; exit 1; }
          bad=$(jq -r '[to_entries[] | select(.value.result == "failure" or .value.result == "cancelled") | .key] | join(", ")' <<<"$NEEDS")
          [[ -z $bad ]] || { echo "::error::failed or cancelled: $bad"; exit 1; }
```

The template's gate also fails the merge queue when integration tests or the deploy test were skipped for
lack of pushed images, and explains fork-PR, config-only and docs-only skips in the job summary.

## Gotchas

The five that bite first (full catalogue: references/gotchas.md):
- A push to a branch with an open PR starts two `pr.yml` runs. That is expected: separate concurrency groups,
  and gates named `push-gate` and `pr-gate`.
- `GITHUB_TOKEN` pushes, tags and PRs start no workflow (except `workflow_dispatch` / `repository_dispatch`):
  bots dispatch the next workflow explicitly, and bot-opened PRs need a close/reopen or an App token.
- `[skip ci]` on a commit also suppresses the tag-push workflow of a tag on that commit.
- A job `container:` runs `run:` steps with `sh` unless `defaults.run.shell: bash` is set.
- A script test that reads files a bot writes back (deployed tags, placements) breaks after the first deploy:
  tests build fixtures with the bot-managed fields reset.

## Validation

```bash
bash <skill>/scripts/lint-pipeline.sh --install --repo .   # actionlint, ShellCheck, hadolint, YAML, script tests
grep -rnE '__[A-Z0-9_]+__' .github/ scripts/ config/ || echo "no placeholders left"
NODE_PATH=... node <skill>/scripts/render-mermaid.cjs .github/workflows/README.md   # references/documenting-pipelines.md
```

Then the branch run (`push-gate`), the PR run (`pr-gate`), and the first main run, each read in full.

## Related skills

- **gha-affected-builds**: the path map, `affected.py` and the `affected-matrix` action behind `detect-affected`.
- **gha-versioning-release**: versions from git, image tags, `_promote.yml`, `release.yml`, release-please.
- **gha-ephemeral-test-envs**: `_integration-test.yml`, `_kind-deploy.yml`, compose and kind wrappers, the drill.
- **gha-build-images**: the CI build image, runtime base images, `base-image.yml`, `setup-build-env`.
- **gha-config-deploy**: the config tree, config lint, `_deploy-dev.yml`, write-back, bump PRs, host pools.

If a companion skill is not installed, keep the corresponding job out and say which skill would add it.

## Provenance

Distilled from the reference repository crazymatthsu/github-demo, where this shape ran green end to end
(`.github/workflows/pr.yml`, `main.yml`, `_gradle-build.yml`, `release.yml`, `nightly.yml`, `base-image.yml`,
`.github/workflows/README.md`, `.github/README.md`, design documents D7 and D10). The templates are generalised
from those files; nothing here depends on that repository.
