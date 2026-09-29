---
name: gha-ephemeral-test-envs
description: 'Build, review or fix throwaway test environments inside GitHub Actions jobs with a teardown guarantee: a docker compose stack per job (unique name per run and attempt, labels, tests in a runner container on the stack network, diagnostics, always() down plus a leak check), a kind cluster for Helm deployment tests (image loaded by digest, one release per instance, helm test, smoke diff) and a nightly teardown drill. Use it whenever integration tests need real databases, brokers or services in CI, someone mentions docker compose or Testcontainers in GitHub Actions or a kind or Helm chart test in pull requests, or asks why CI leaks containers, ports clash, stacks time out or cleanup did not run after a cancel.'
---

# gha-ephemeral-test-envs

## What this skill gives you

Throwaway environments that a CI job starts, tests against and always removes, proven to be gone: a docker
compose tier for integration tests and a kind tier for Helm deployment tests. Each tier is one wrapper
script that CI and laptops call the same way, a thin composite action, a reusable workflow, and a scheduled
drill that fails and cancels runs on purpose to prove the teardown. Tested scripts and templates included.

## Principles

1. **One wrapper script per tier, used by CI and laptops alike** (`stack.sh`, `kind.sh`); workflow steps
   only call it through a thin composite action. Why: the stack a developer debugs is the stack CI ran, and
   logic buried in YAML can neither run on a laptop nor be tested with stubs.
2. **Name every environment per run and attempt, in the job, and label every resource.** The job sets
   `COMPOSE_PROJECT_NAME` / `KIND_CLUSTER_NAME` to `ci-<run_id>-<attempt>`; every container, named volume
   and network carries run labels. Why: parallel jobs and reruns never collide, and teardown finds exactly
   this run's resources even when `up` died half-way (a name computed inside `up` would be lost with it).
3. **Teardown is layered and unconditional, and a leak check proves it.** `if: always()` down, then a prune
   by label, then the ephemeral runner, then an `always()` leak check that fails the job and writes the job
   summary. Why: each layer alone has a gap (a killed step, resources compose lost track of, a persistent
   runner); the leak check turns a silent leak into a red job.
4. **Test the image, by digest.** The build hands over `repo:tag@sha256:...`; the stack runs exactly that.
   Why: the image (entrypoint, config mounts, base) is what breaks and what ships; a tag can move between
   build and test; the tested digest is what gets promoted.
5. **No published ports in CI.** Tests run in a runner container on the stack network and reach services by
   name. Why: no port clashes between jobs or with the host, nothing exposed, the same endpoints everywhere;
   ports exist only in laptop overrides.
6. **Start on health, not on sleep.** Real health checks, `up --wait`, dependencies before the app, budgets
   that fit the wait timeout. Why: "connection refused" flakes disappear, and a stack that never gets
   healthy fails fast with the failing service's own log lines.
7. **Collect diagnostics before teardown; upload them only on failure.** Why: after `down` the evidence is
   gone; on success it is noise and storage.
8. **Pin the environment.** Images by tag and digest in one versions file, tools (kind, kubectl, helm)
   checksum-verified at pinned versions, one line per bump. Why: a red run must be reproducible, and a
   dependency bump must be a reviewable one-line diff.
9. **In kind, the node never pulls the image under test.** Load it by digest, tag it as the chart renders
   it, deploy with that tag, and check the rendered release before installing. Why: otherwise a tag mismatch
   surfaces as `ImagePullBackOff` after the full Helm timeout, or the chart runs an image that was never
   tested.
10. **One Helm release per instance, one flag list for lint, template and deploy.** First installs without
    `--rollback-on-failure`, upgrades with it; `helm test` per release; a smoke diff across releases. Why: a
    failure stays confined to one release, a failed first install keeps its pods for diagnosis, and the
    smoke diff proves each instance got its own values.
11. **Prove the guarantee on the paths nobody runs.** A scheduled drill fails a test on purpose and cancels
    a run on purpose; both must end with a successful teardown and a clean leak check. Why: every green PR
    proves the passing path only; `always()` after a cancel is exactly what breaks unnoticed.
12. **Generate throwaway secrets per stack.** Database passwords are generated, masked and recorded only in
    a mode-600 state file. Why: nothing to commit, rotate or leak.

## Procedure

1. **Discover** in the target repository:
   - the build tool and how one project's integration tests run (the command, where JUnit XML lands);
   - the projects with integration tests and the services each needs (database, broker, cache, other apps);
   - how the build job publishes images: the skill expects an `images` JSON object
     `{"<project>": "<repo>:<tag>@sha256:<digest>"}` (gha-pipeline-design / gha-versioning-release);
   - the registry (GHCR with `GITHUB_TOKEN` by default) and the image the tests should run in (ideally the
     CI build image of gha-build-images);
   - the runners: GitHub-hosted (one VM per job) or self-hosted sharing one engine between jobs;
   - Helm charts and their per-instance values, if any (only then add the kind tier);
   - an existing harness (Testcontainers, a hand-written compose file) and where it leaks today.
2. **Decide**, with these defaults:
   - compose tier for integration tests: one stack per job, runner container, digest-pinned images.
     Testcontainers suits a test that owns one dependency from its own code; whole stacks with your own
     images belong in compose, which laptops and CI run the same way;
   - layout `test-infra/compose/`, `test-infra/kind/`, `scripts/ci/`; label prefix: your reverse domain;
   - leak check failing from day one (`warn-only` only while cleaning up an old, leaky pipeline);
   - kind tier only for repositories that ship Helm charts; a real cluster namespace comes later;
   - the drill daily, on the default branch.
3. **Copy the templates** (table below) to their target paths and `chmod +x` the scripts. Add
   `test-infra/compose/.state/` and `test-infra/kind/.state/` to `.gitignore`.
4. **Adapt the compose tier:**
   - one `<stack>.yml` per dependency, shaped like `postgres.yml`: image from a variable, health check,
     labelled named volume on every path the image declares as `VOLUME`, `mem_limit`, no ports; an optional
     `<stack>.local.yml` with ports on 127.0.0.1;
   - `stacks.yml`: one `<project id>: [<stack>, ...]` line per project with integration tests;
   - `versions.env`: each image as `<registry>/<repo>:<tag>@sha256:<digest>` and `TEST_RUNNER_IMAGE`;
   - `test-runner.yml`: endpoints (service name + container port) and the build-tool cache variable;
   - per project with an image, a compose file for the app under test like `app.compose.yml` (service `app`,
     `image: ${APP_IMAGE}`, `depends_on` healthy, laptop ports), at the path `app-compose-file` names.
5. **Adapt the kind tier** (charts only): the pins in `test-infra/kind/versions.env`; an instances directory
   with `app-common/values.yaml` and `<instance>/values.yaml` (with gha-config-deploy: its
   `config/<dev env>/<flow>/<app>` directory, unchanged); a `helm test` Job in the chart
   (references/kind-tier.md, section 8); a probe endpoint that reports identity and effective configuration
   for the smoke diff.
6. **Fill every placeholder** (`grep -rn '__[A-Z0-9_]*__' .github test-infra` must print nothing); each
   template lists its placeholders with examples in its header.
7. **Wire the callers:** pr.yml and main.yml (gha-pipeline-design) call `_integration-test.yml` once per
   matrix entry (the matrix from gha-affected-builds) and `_kind-deploy.yml` when charts or their values
   change; both feed the single gate check. Schedule `teardown-drill.yml` once it is on the default branch.
8. **Give developers the laptop commands** in the repository README (references/compose-tier.md, section 11;
   references/kind-tier.md, section 13), or wrap them in build-tool tasks with teardown in a `finally`.
9. **Validate** (section below), then on the first real runs: read the leak-check summaries, measure memory
   with the diagnostics' `stats.txt`, adjust `mem_limit` and timeouts, and dispatch the drill once by hand.

## Templates and scripts

| File (copy to) | Purpose | What to adapt |
|---|---|---|
| `assets/scripts/stack.sh` (`test-infra/compose/stack.sh`) | compose lifecycle: `up`, `status`, `diagnostics`, `down`, `leak-check`; exit 0 ok, 1 failure or leak, 2 usage, 5 no engine | nothing; env: `CI_LABEL_PREFIX`, `STACK_WAIT_TIMEOUT`, `STACK_SEED_CMD`, `STACK_SCOPE` (see `--help`) |
| `assets/compose/base.yml`, `test-runner.yml` | first file (labels, network); the runner service (profile `tools`, runner UID, cache at /cache) | label prefix; runner endpoints and cache variable |
| `assets/compose/postgres.yml`, `postgres.local.yml` | example dependency stack and its laptop ports | one pair per real dependency |
| `assets/compose/stacks.yml`, `versions.env` | project -> stacks map; digest-pinned images | `__PROJECT_ID__`; `__POSTGRES_IMAGE__`, `__TEST_RUNNER_IMAGE__` |
| `assets/compose/app.compose.yml` (`<project>/compose.test.yml`) | the app under test from `APP_IMAGE` | environment, health probe, port |
| `assets/actions/compose-stack/action.yml` (`.github/actions/compose-stack/`) | thin wrapper; requires `COMPOSE_PROJECT_NAME` from the job | `script` input if stack.sh lives elsewhere |
| `assets/workflows/_integration-test.yml` (`.github/workflows/`) | reusable IT job for one project: login, optional build-tool cache, stack up, tests in the runner, diagnostics, `always()` down + leak check, JUnit summary and upload | `__REGISTRY__`, `__APP_COMPOSE_FILE__`, `__TEST_COMMAND__` (the default of input `test-command`), `__TEST_RESULTS__`; inputs `cache` (`none`, `gradle`, `restore`) and, for several toolchains, `test-command` / `test-runner-image` per project (references/compose-tier.md section 12) |
| `assets/scripts/junit-summary.sh` (`scripts/ci/`) | JUnit XML totals and failing suites into the job summary | `JUNIT_GLOB` for non-`TEST-*.xml` names |
| `assets/scripts/kind.sh` (`test-infra/kind/kind.sh`) | kind lifecycle: `up`, `load` (digest in, tag on the node), `diagnostics`, `down`, `leak-check` | nothing; env: `KIND_WAIT`, `KIND_NODE_IMAGE` |
| `assets/kind/cluster.yaml`, `versions.env` (`test-infra/kind/`) | one-node cluster, no port mappings; tool pins | bump the pins to current releases |
| `assets/actions/kind-cluster/action.yml` (`.github/actions/kind-cluster/`) | thin wrapper; requires `KIND_CLUSTER_NAME` from the job; returns `loaded` | `script` input |
| `assets/actions/setup-kube-tools/action.yml` (`.github/actions/setup-kube-tools/`) | pinned, checksum-verified kind / kubectl / helm / kubeconform | nothing; identical to gha-build-images' copy: keep one |
| `assets/scripts/helm-release.sh` (`scripts/ci/`) | one release: `lint`, `template`, `deploy` (PSS namespace, lint, render check, upgrade --install, rollout, helm test, rollback rules) | `--tag-key` if the chart's tag key is not `image.tag` |
| `assets/scripts/smoke-diff.sh` (`scripts/ci/`) | two releases answer a probe differently | the probe and `--jq` filter |
| `assets/workflows/_kind-deploy.yml` (`.github/workflows/`) | reusable deployment test: tools, kind up, load, one release per instance, smoke diff, diagnostics, `always()` down + leak check | `__REGISTRY__`, `__APP_PROJECT__`, `__CHART_DIR__`, `__INSTANCES_DIR__`, `__RELEASE_PREFIX__`, `__NAMESPACE__`, `__SMOKE_PROBE__` |
| `assets/workflows/teardown-drill.yml` (`.github/workflows/`) | scheduled drill: failing run, self-cancelled run, verdict | `__DRILL_PROJECT__`, `__REGISTRY__`, the cron |
| `scripts/selftest.sh` (stays in the skill) | offline test of all five scripts with stubbed docker / kind / kubectl / helm (124 checks) | point `STACK_SH`, `KIND_SH`, ... at the adapted copies |

**Interface of the reusable workflows** (the pr.yml / main.yml templates of gha-pipeline-design call them
unchanged; keep these file names and the action paths `./.github/actions/compose-stack` and
`./.github/actions/kind-cluster`):

- `_integration-test.yml`: `project` (string, required: one matrix entry, the key of `images` and of
  `stacks.yml`), `images` (string, required: JSON object project -> image pinned by digest, e.g.
  `{"services/api":"ghcr.io/o/api:pr-4-abc1234@sha256:..."}`), `retention-days` (number, default 7);
  optional `image-required`, `app-compose-file`, `app-service`, `test-runner-image`, `timeout-minutes`,
  `name-suffix`. Output `diagnostics-artifact`.
- `_kind-deploy.yml`: `images` (string, required, same shape), `retention-days` (number, default 7);
  optional `project`, `chart`, `instances-dir`, `release-prefix`, `namespace`, `tag`, `smoke-probe`,
  `timeout`. Output `releases`.
- Callers grant `permissions: contents: read, packages: read`.

Third-party actions are pinned to the major versions that ran green in the reference (`actions/checkout@v7`,
`actions/upload-artifact@v7`, `docker/login-action@v4`, `gradle/actions/setup-gradle@v6`): update to the
current major when adopting. Other registries: replace the login step (JFrog through an OIDC token
exchange, ECR through `aws-actions/amazon-ecr-login`) and point `versions.env` at the mirror, keeping digests.

## Gotchas

Compose tier:

- Cleanup did not run after a cancel or timeout -> the step had no condition or `if: failure()` ->
  `if: always()` on `down` and `leak-check` (they run on success, failure, cancel and timeout); prove it
  with the drill. In the reference's self-cancelled run, teardown began 15 s after the cancel and succeeded.
- Teardown after a failed `up` removed nothing -> the name was computed inside `up` and lost -> set
  `COMPOSE_PROJECT_NAME` / `KIND_CLUSTER_NAME` in the job's `env`; the actions refuse to run without it.
- Parallel matrix jobs or reruns clash -> same name, or runners sharing one engine -> `ci-<run_id>-<attempt>`;
  on shared engines pass `name-suffix`, which also switches `STACK_SCOPE` to `project`, so a job never prunes
  its siblings by the shared run label.
- "port is already allocated", or tests pass locally only -> published host ports -> tests in the runner
  container on the stack network; ports only in `<stack>.local.yml` and on 127.0.0.1.
- The leak check is green but volumes pile up -> an image-declared `VOLUME` got an anonymous volume without
  labels -> mount a named, labelled volume on every declared path; prune with `rm -f -v`.
- A non-root service fails to initialise its data directory (AccessDenied) -> a tmpfs mounted over the
  image's `VOLUME` path is root-owned -> use a named volume, which takes the image directory's ownership.
- A relative bind mount in the app's compose file points to the wrong place -> compose resolves every
  merged file's relative paths against the first file's directory (`base.yml`) -> use `${TEST_WORKSPACE}/...`.
- Later steps cannot delete or upload the reports -> the runner container ran as root -> `user:
  ${TEST_RUNNER_UID}:${TEST_RUNNER_GID}` (1001 on GitHub-hosted runners); `stack.sh` exports the caller's ids.
- `up --wait` gives up while the service would have become healthy -> `start_period + retries x interval`
  exceeds `--wait-timeout`, or the probe binary is missing from the image -> do the budget sum, check the
  binary, or probe with bash `/dev/tcp`.
- The failing service's error is missing from the log -> the interleaved tail is dominated by chatty
  services -> print each failed container's own tail (`stack.sh up` does).
- `down` fails with "required variable ... is missing" -> compose parses the files again -> record every
  interpolation value (state file, `$GITHUB_ENV`); `stack.sh` fills dummies and falls back to the label prune.
- A dependency bump in `versions.env` did not take effect -> a variable of the same name in the job or step
  environment wins (the shell beats `--env-file`), or a persistent runner reused a cached image for a bare
  tag -> override only on purpose (`APP_IMAGE`, `TEST_RUNNER_IMAGE`), and pin tag plus digest.

Kind tier:

- `ImagePullBackOff`, or the chart runs another image -> the node has no registry credentials, or the tag
  differs from the loaded one -> `kind.sh load --tag <tag> <repo>:<tag>@sha256:...`, deploy with the same tag
  and repository, `--loaded-images` fails before installing (test hook images included).
- `kind load docker-image` fails under Podman -> it always calls `docker` -> `podman save` +
  `kind load image-archive` (`kind.sh` does it with `KIND_EXPERIMENTAL_PROVIDER=podman`).
- The leak check finds a network `kind` -> kind creates the shared bridge without a cluster label and never
  removes it -> in CI `kind.sh down` removes it once no kind node is left.
- The cluster name is rejected -> more than 50 characters or characters outside `a-z 0-9 . -` (the node
  hostname `<cluster>-control-plane` must fit 64) -> keep `ci-<run_id>-<attempt>`.
- A failed first install left nothing to debug -> `--rollback-on-failure` (`--atomic`) uninstalls a failed
  first install with its pods and events -> first install without it; upgrades with it.
- Helm 4 reports success while pods crash-loop -> without `--wait` Helm 4 waits for hooks only (`hookOnly`)
  -> always pass `--wait` (`--rollback-on-failure` defaults it to `watcher`). `--atomic` is a deprecated
  alias of `--rollback-on-failure`.
- `helm test --logs` shows nothing for a Job hook -> Helm 4 prints test pods only -> annotate the Job
  `helm.sh/hook-output-log-policy: hook-succeeded,hook-failed`.
- The schema rejects image tag `1` or `20260929` -> `--set` types integer-looking values -> `--set-string`.
- The Service sends traffic to the test pod -> the test Job's pod carries the Service's selector labels ->
  give it distinct labels (`app.kubernetes.io/component: smoke-test`, no `app.kubernetes.io/name`).
- The smoke diff passes although both releases got the same values -> the probe's answer differs only by
  uptime or pod name -> probe identity and effective configuration; drop volatile fields with `--jq`.

Drill:

- The dispatched run never starts or waits forever -> it shares the concurrency group of the run waiting
  for it -> a per-run group for `drill=cancel-target` runs (the template does it).
- `gh workflow run` fails or no run appears -> dispatch needs the workflow on the default branch and
  `actions: write`; `gh workflow run` returns no run id -> find the run by its unique `run-name`.
- The verdict says `missing` -> a step was renamed -> `drill-cancel` matches `Teardown (always)` and
  `Leak check (always)` by name.
- The drill job shows red every night -> by design: `continue-on-error: true` keeps the run green, and the
  `report` job carries the verdict from the step outcomes.
- The drill ran hours after its cron -> scheduled runs can start late (the reference's 03:17 UTC schedule
  started around 09:50 UTC) -> never chain workflows by clock time.

## Validation

Run before handing the pipeline over (paths as in the table above):

```bash
# every placeholder filled
grep -rn '__[A-Z0-9_]*__' .github test-infra scripts/ci && echo "placeholders left" || echo ok
# scripts: static analysis, then the offline behaviour test with stubs (no engine needed)
shellcheck --severity=style test-infra/compose/stack.sh test-infra/kind/kind.sh scripts/ci/*.sh
STACK_SH=test-infra/compose/stack.sh KIND_SH=test-infra/kind/kind.sh \
  HELM_RELEASE_SH=scripts/ci/helm-release.sh SMOKE_DIFF_SH=scripts/ci/smoke-diff.sh \
  JUNIT_SUMMARY_SH=scripts/ci/junit-summary.sh bash .claude/skills/gha-ephemeral-test-envs/scripts/selftest.sh
for s in test-infra/compose/stack.sh test-infra/kind/kind.sh scripts/ci/*.sh; do
  bash "$s" --help >/dev/null || echo "FAIL $s"; done
# workflows (actionlint runs shellcheck on run: blocks) and composite actions (YAML)
actionlint .github/workflows/*.yml
python3 -c 'import sys,yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/actions/*/action.yml
# every project's merged stack parses (dummy values for what stack.sh would generate)
cd test-infra/compose && DB_PASSWORD=x TEST_WORKSPACE=/w TEST_CACHE_DIR=/c APP_IMAGE=r/a:t \
  docker compose --env-file versions.env -f base.yml -f postgres.yml -f test-runner.yml config -q; cd -
# charts: lint and render every instance, validate the schemas
scripts/ci/helm-release.sh api-eu-1 --chart <chart> --tag 1.0.0 -f <instances>/app-common/values.yaml \
  -f <instances>/eu-1/values.yaml --mode template --render-out build/render/api-eu-1.yaml
kubeconform -strict -summary build/render/*.yaml
```

Then, on the default branch: dispatch `teardown-drill` once (`gh workflow run teardown-drill.yml`) and check
its summary (failing run: test failure, teardown success, leak check success; cancelled run: conclusion
cancelled, teardown and leak check success). What only real runs prove: health-check budgets, memory
limits, image pulls, the kind load, and teardown timing after a cancel.

## Related skills

- **gha-pipeline-design**: the entry point; its pr.yml / main.yml call `_integration-test.yml` and
  `_kind-deploy.yml`, feed the single gate check, and set concurrency and permissions.
- **gha-affected-builds**: produces the integration-test matrix (the `project` values) and the flag that
  decides when the kind test runs.
- **gha-build-images**: the CI build image used as `TEST_RUNNER_IMAGE`; ships the same `setup-kube-tools`
  action (keep one copy) and checks tool pins against the image.
- **gha-versioning-release**: the `images` digests; the tested digest is the one promoted, never rebuilt.
- **gha-config-deploy**: deploys to long-lived clusters and hosts; its Helm deployer can call
  `helm-release.sh` so the kind test and the real deploy share one flag list.

If a related skill is not installed, the interface above is all this skill needs: an `images` JSON object
and a list of project ids.

## Provenance

Distilled from the reference repository crazymatthsu/github-demo, where these pieces ran green on
GitHub-hosted runners in September 2026: `test-infra/compose/stack.sh` and its compose files,
`.github/actions/compose-stack`, `.github/workflows/_integration-test.yml` (component and system levels),
`test-infra/kind/kind.sh`, `.github/actions/{kind-cluster,setup-kube-tools,helm-deploy-instance}`,
`scripts/helm-deploy-instance.sh`, `scripts/helm-smoke-diff.sh`, `.github/workflows/_kind-deploy.yml`, the
teardown drill of `.github/workflows/nightly.yml`, docs 08, 10 and 11 and ADRs DL-15, DL-24, DL-25, DL-27
and DL-32. The scripts here are generic rewrites (no project names, config-tree layout or Gradle paths); the
skill does not depend on that repository.
