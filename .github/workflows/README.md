# Workflows: what runs when

One diagram per pipeline: the trigger, the workflow file that runs, its jobs, the reusable workflows
(`_*.yml`) those jobs call, and the composite actions (`.github/actions/<name>/action.yml`) each job
uses. [`../README.md`](../README.md) has the file table, the repository settings and the first-run
bootstrap. [`../affected-map.yml`](../affected-map.yml) decides which projects a change builds and tests.

1. [Which workflow runs on which event](#which-workflow-runs-on-which-event)
2. [Push to a branch](#push-to-a-branch)
3. [Pull request to main](#pull-request-to-main)
4. [Push to main](#push-to-main)
5. [Release](#release)
6. [Tag push](#tag-push)
7. [Nightly](#nightly)
8. [Base images](#base-images)
9. [Inside the reusable workflows](#inside-the-reusable-workflows)
10. [Composite actions by pipeline](#composite-actions-by-pipeline)

Legend, the same in every diagram:

| Shape | Meaning |
|---|---|
| blue pill | a trigger: the event that starts the run, or the caller of a reusable workflow |
| grey box | a whole workflow file |
| white box | a job, or a step that runs shell commands |
| violet box with side bars | a reusable workflow `_*.yml`, or a job that calls one |
| amber hexagon | a step that uses a composite action from `.github/actions/` |
| green parallelogram | what the run produces: images, a commit, a pull request, a release |
| dotted arrow | happens only under the condition on the arrow, or an indirect effect |

In the pipeline diagrams each job lists its composite actions on its last line (`actions: ...`).
`actions: none` means the job uses only shell steps and third-party actions.

## Which workflow runs on which event

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart LR
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef wf fill:#e2e8f0,stroke:#334155,color:#0f172a

  ev1(["push to a branch<br/>except main and hotfix/**"]):::trigger
  ev2(["pull request<br/>opened, synchronize,<br/>reopened, labeled"]):::trigger
  ev3(["merge queue<br/>merge_group"]):::trigger
  ev4(["push to main<br/>a merged pull request"]):::trigger
  ev5(["push to hotfix/**"]):::trigger
  ev6(["schedule<br/>Mondays 04:23 UTC,<br/>or a manual run"]):::trigger
  ev7(["push of a tag v* or<br/>deephaven-server/v*,<br/>or a manual run"]):::trigger
  ev8(["schedule<br/>daily 03:17 UTC,<br/>or a manual run"]):::trigger

  wpr["pr.yml"]:::wf
  wcl["config-lint.yml"]:::wf
  wmain["main.yml"]:::wf
  wrp["release-please.yml"]:::wf
  wbi["base-image.yml"]:::wf
  wrel["release.yml"]:::wf
  wni["nightly.yml"]:::wf

  ev1 --> wpr
  ev2 --> wpr
  ev3 --> wpr
  ev2 -.->|"config tree, Helm chart<br/>or compose template<br/>changed"| wcl
  ev4 --> wmain
  ev5 --> wmain
  ev4 --> wrp
  ev4 -.->|"base images or<br/>the CA changed"| wbi
  ev6 --> wbi
  ev7 --> wrel
  wrp -->|"dispatches it for<br/>each new release tag"| wrel
  ev8 --> wni
```

The reusable workflows (`_*.yml`, and `config-lint.yml` when called) run only as jobs of these callers:

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart LR
  classDef wf fill:#e2e8f0,stroke:#334155,color:#0f172a
  classDef reusable fill:#ede9fe,stroke:#7c3aed,color:#0f172a

  wpr["pr.yml"]:::wf
  wmain["main.yml"]:::wf
  wrel["release.yml"]:::wf

  gb[["_gradle-build.yml"]]:::reusable
  cl[["config-lint.yml"]]:::reusable
  it[["_integration-test.yml"]]:::reusable
  kd[["_kind-deploy.yml"]]:::reusable
  dp[["_docker-publish.yml"]]:::reusable
  dd[["_deploy-dev.yml"]]:::reusable

  wpr --> gb & cl & it & kd
  wmain --> gb & cl & it & kd & dp & dd
  wrel --> dp
```

`nightly.yml`, `base-image.yml` and `release-please.yml` call no reusable workflow.

## Push to a branch

`pr.yml` on the `push` event: the fast tier, without images or containers. Its gate is reported as
`push-gate`.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef reusable fill:#ede9fe,stroke:#7c3aed,color:#0f172a

  t1(["git push to a branch<br/>except main, hotfix/**<br/>and merge-queue branches"]):::trigger

  subgraph PRPUSH ["pr.yml, event push"]
    da["detect-affected<br/>compares with the merge-base on main<br/>and maps changed paths to projects<br/>actions: affected-matrix"]
    lint["lint<br/>hadolint, ShellCheck,<br/>script tests, actionlint<br/>actions: none"]
    build[["build: calls<br/>_gradle-build.yml<br/>affected projects: build<br/>and unit tests, no images,<br/>skipped if none affected<br/>actions: registry-login,<br/>setup-build-env"]]:::reusable
    cl[["config-lint: calls<br/>config-lint.yml<br/>actions: setup-build-env,<br/>setup-kube-tools"]]:::reusable
    gate["push-gate<br/>collects every job result"]
    da --> lint & build & cl
    lint & build & cl --> gate
    da -.->|"docs-only change:<br/>every job skipped"| gate
  end

  t1 --> da
```

- `integration-test` and `kind-deploy` never run on a push event.
- A newer push to the same branch cancels the older run.
- Tag pushes do not start `pr.yml`.
- When the branch has an open pull request, the same push also starts the pull request pipeline below.
  Two `pr.yml` runs then appear, `push-gate` and `pr-gate`.

## Pull request to main

`pr.yml` on the `pull_request` and `merge_group` events, and `config-lint.yml` on its own when the
config tree, a Helm chart or a compose template changed.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef reusable fill:#ede9fe,stroke:#7c3aed,color:#0f172a

  t2(["merge queue<br/>merge_group"]):::trigger
  t1(["pull request<br/>opened, synchronize,<br/>reopened, labeled"]):::trigger

  subgraph PRRUN ["pr.yml, events pull_request and merge_group"]
    da["detect-affected<br/>compares with the base commit;<br/>every project on the merge queue<br/>or with the label ci:full<br/>actions: affected-matrix"]
    lint["lint<br/>hadolint, ShellCheck,<br/>script tests, actionlint<br/>actions: none"]
    build[["build: calls<br/>_gradle-build.yml<br/>affected projects, images<br/>pr-4-5d2c2c9 pushed to GHCR<br/>actions: registry-login,<br/>setup-build-env"]]:::reusable
    cl[["config-lint: calls<br/>config-lint.yml<br/>actions: setup-build-env,<br/>setup-kube-tools"]]:::reusable
    it[["integration-test: calls<br/>_integration-test.yml<br/>one job per affected project<br/>with integration tests<br/>actions: registry-login,<br/>setup-build-env, compose-stack"]]:::reusable
    kd[["kind-deploy: calls<br/>_kind-deploy.yml<br/>when deploy-test is set and<br/>the source-database image<br/>was pushed<br/>actions: registry-login,<br/>setup-kube-tools, kind-cluster,<br/>helm-deploy-instance"]]:::reusable
    gate["pr-gate<br/>collects every job result,<br/>the one check to require on main"]
    da --> lint & build & cl
    build --> it
    build -.->|"deploy-test"| kd
    lint ~~~ it
    cl ~~~ kd
    lint & build & cl & it & kd --> gate
  end

  t2 --> da
  t1 --> da
  t1 -.->|"config tree, Helm chart<br/>or compose template<br/>changed"| cl2[["config-lint.yml, its own run<br/>actions: setup-build-env,<br/>setup-kube-tools"]]:::reusable
```

- The merge queue runs the same jobs on the merge result, with every project selected.
- Adding the `ci:full` label starts a new run with every project selected.
- A pull request from a fork builds its images but cannot push them, so `integration-test` and
  `kind-deploy` are skipped.
- A config-only change builds no image, so `kind-deploy` is skipped. `config-lint` still renders every
  Helm release, and `main` runs the kind deploy after the merge.

## Push to main

A merge to `main` starts `main.yml` and `release-please.yml`, and `base-image.yml` when the base images
or the CA changed. A push to `hotfix/**` runs `main.yml` without `deploy-dev`.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef reusable fill:#ede9fe,stroke:#7c3aed,color:#0f172a
  classDef out fill:#dcfce7,stroke:#16a34a,color:#0f172a
  classDef wf fill:#e2e8f0,stroke:#334155,color:#0f172a

  t1(["push to main<br/>a merged pull request"]):::trigger
  t2(["push to hotfix/**"]):::trigger

  subgraph MAINRUN ["main.yml"]
    build[["build: calls<br/>_gradle-build.yml<br/>every project, images<br/>pushed to GHCR<br/>actions: registry-login,<br/>setup-build-env"]]:::reusable
    cl[["config-lint: calls<br/>config-lint.yml<br/>actions: setup-build-env,<br/>setup-kube-tools"]]:::reusable
    it[["integration-test: calls<br/>_integration-test.yml<br/>component level,<br/>one job per connector<br/>actions: registry-login,<br/>setup-build-env, compose-stack"]]:::reusable
    st[["system-test: calls<br/>_integration-test.yml<br/>system level: source-database<br/>with our deephaven-server image<br/>actions: registry-login,<br/>setup-build-env, compose-stack"]]:::reusable
    pub[["publish: calls<br/>_docker-publish.yml<br/>points every tag at<br/>the tested digests<br/>actions: registry-login"]]:::reusable
    kd[["kind-deploy: calls<br/>_kind-deploy.yml<br/>every us-dev instance of<br/>source-database in a<br/>throwaway kind cluster<br/>actions: registry-login,<br/>setup-kube-tools, kind-cluster,<br/>helm-deploy-instance"]]:::reusable
    dd[["deploy-dev: calls<br/>_deploy-dev.yml<br/>Environment dev, main only<br/>actions: setup-kube-tools,<br/>registry-login, kind-cluster,<br/>helm-deploy-instance"]]:::reusable
    build --> it --> st --> pub
    cl --> pub
    pub --> kd --> dd
  end

  t1 --> build & cl
  t2 --> build & cl
  build --> img[/"GHCR images<br/>0.1.0-rc.53, sha-1796982<br/>and main"/]:::out
  dd --> wb[/"write-back commit on main<br/>chore(config): us-dev deployed<br/>0.1.0-rc.53 [skip ci]<br/>pushed with GITHUB_TOKEN,<br/>so it starts no run"/]:::out
  t1 --> rp["release-please.yml<br/>see Release"]:::wf
  t1 -.->|"base images or<br/>the CA changed"| bi["base-image.yml<br/>see Base images"]:::wf
```

- Every job is skipped when the pusher is `github-actions[bot]`, the identity of the write-back. With
  `GITHUB_TOKEN` that push starts no run anyway (DL-36).
- `build` and `config-lint` start together. `publish` waits for the system test and config-lint, so
  nothing is deployed or released from an untested digest.
- `kind-deploy` proves the chart and the us-dev config with the published digests before `deploy-dev`.
- On `hotfix/**`, `deploy-dev` is skipped: a hotfix reaches qa and prod through a release tag on
  its branch and the us-qa bump pull request.

## Release

`release-please.yml` runs on every push to `main`. It keeps one release pull request open per version
line and creates the tag when that pull request is merged.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef out fill:#dcfce7,stroke:#16a34a,color:#0f172a
  classDef wf fill:#e2e8f0,stroke:#334155,color:#0f172a

  m1(["push to main<br/>any merged pull request"]):::trigger
  rp1["release-please.yml<br/>opens or updates the<br/>release pull request<br/>actions: none"]
  rpr[/"release pull request,<br/>one per version line<br/>connector family: vX.Y.Z<br/>deephaven-server:<br/>deephaven-server/vX.Y.Z"/]:::out
  m2(["push to main<br/>the merged release<br/>pull request"]):::trigger
  rp2["release-please.yml<br/>creates the tag and<br/>the GitHub Release<br/>actions: none"]
  mr["main.yml<br/>builds and tests the<br/>release commit and<br/>pushes its images"]:::wf
  rel["release.yml<br/>see Tag push"]:::wf

  m1 --> rp1 --> rpr
  rpr -->|"a maintainer merges it"| m2
  m2 --> rp2
  m2 --> mr
  rp2 -->|"gh workflow run<br/>release.yml --ref vX.Y.Z"| rel
  mr -.->|"release.yml waits for<br/>this run to pass, then<br/>promotes its images"| rel
```

- Tags, releases and pull requests created with `GITHUB_TOKEN` start no workflow run. That is why
  `release-please.yml` dispatches `release.yml` itself. The release pull request and the us-qa bump
  pull request start no `pr.yml` run either: close and reopen them to run `pr-gate`, until a GitHub
  App token replaces `GITHUB_TOKEN` (DL-09).
- release-please needs the repository setting "Allow GitHub Actions to create and approve pull
  requests" (Settings, Actions, General).

## Tag push

`release.yml` runs on a release tag. release-please's tags reach it through `workflow_dispatch`, and a
tag pushed by hand, the emergency route, triggers it directly. It never rebuilds: it promotes the
images that `main.yml` built and tested for the tagged commit.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef reusable fill:#ede9fe,stroke:#7c3aed,color:#0f172a
  classDef out fill:#dcfce7,stroke:#16a34a,color:#0f172a

  t1(["push of a tag by hand<br/>v* or deephaven-server/v*"]):::trigger
  t2(["workflow_dispatch on the tag<br/>from release-please.yml,<br/>or by hand to re-run"]):::trigger

  subgraph RELRUN ["release.yml"]
    res["resolve<br/>checks that ./gradlew printVersion<br/>equals the tag, waits up to 60 min<br/>for the passing main.yml run<br/>of the tagged commit, finds<br/>that run's images by sha tag<br/>actions: setup-build-env,<br/>registry-login"]
    pro[["promote: calls<br/>_docker-publish.yml<br/>adds the release tags<br/>to the tested digests<br/>actions: registry-login"]]:::reusable
    sb["sbom<br/>one job per image,<br/>anchore/sbom-action<br/>actions: none"]
    gr["github-release<br/>creates or reuses the release<br/>and attaches the SBOMs<br/>actions: none"]
    bq["bump-qa<br/>opens the config/us-qa bump<br/>pull request, connector family<br/>only; skipped while<br/>config/us-qa does not exist<br/>actions: none"]
    res --> pro --> sb --> gr --> bq
  end

  t1 --> res
  t2 --> res
  pro --> img[/"GHCR tags X.Y.Z, and<br/>X.Y, X and latest when<br/>it is the newest release"/]:::out
  bq --> qa[/"pull request: config/us-qa<br/>to X.Y.Z, its approval is<br/>the deploy intent for qa"/]:::out
```

## Nightly

`nightly.yml` runs the GHCR retention sweep and proves the teardown guarantee on a failing and on a
cancelled run.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a

  t1(["schedule<br/>daily 03:17 UTC"]):::trigger
  t2(["manual run<br/>input DRY_RUN,<br/>default true"]):::trigger

  subgraph NIRUN ["nightly.yml"]
    ret["retention<br/>GHCR sweep:<br/>scripts/ci/retention.sh,<br/>dry run unless DRY_RUN<br/>or RETENTION_DRY_RUN<br/>is false<br/>actions: none"]
    tf["teardown-drill-fail<br/>reference stack up,<br/>a test fails on purpose,<br/>teardown and leak check<br/>must still pass<br/>actions: registry-login,<br/>setup-build-env,<br/>compose-stack"]
    tc["teardown-drill-cancel<br/>starts a self-cancelling<br/>run and judges it<br/>actions: registry-login"]
    rep["teardown-drill-report<br/>red only when the<br/>teardown guarantee broke<br/>actions: none"]
    tf --> rep
    tc --> rep
  end

  subgraph NIDRILL ["second run, drill=cancel-target"]
    ct["cancel-target<br/>stack up, then cancels<br/>its own run, teardown<br/>and leak check still run<br/>actions: registry-login,<br/>setup-build-env,<br/>compose-stack"]
  end

  t1 --> ret & tf & tc
  t2 --> ret & tf & tc
  tc -->|"gh workflow run<br/>nightly.yml -f<br/>drill=cancel-target"| ct
  ct -.->|"run conclusion<br/>and step results"| tc
```

## Base images

`base-image.yml` builds, verifies and publishes the two company base images. One matrix job per image
runs the same steps.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef act fill:#fef3c7,stroke:#d97706,color:#0f172a
  classDef out fill:#dcfce7,stroke:#16a34a,color:#0f172a
  classDef wf fill:#e2e8f0,stroke:#334155,color:#0f172a

  t1(["schedule<br/>Mondays 04:23 UTC,<br/>OS and JRE patches"]):::trigger
  t2(["push to main that<br/>changes docker/base/**,<br/>test-infra/ca/** or<br/>base-image.yml"]):::trigger
  t3(["manual run<br/>optional input<br/>ca-bundle-version"]):::trigger

  subgraph BIRUN ["base-image.yml: one job each for jre21 and ci-build"]
    s1["Tag<br/>yyyymmdd-run number"]
    s2{{"registry-login"}}:::act
    s3["docker/setup-buildx-action"]
    s4["Build: docker/build-push-action<br/>docker/base/IMAGE/Dockerfile,<br/>build context test-infra/ca,<br/>loaded but not pushed"]
    s5["Verify<br/>java, the CA in both trust stores,<br/>TLS, non-root user; ci-build also<br/>git, docker CLI, buildx, user 1001"]
    s6["Push<br/>the dated tag and latest,<br/>checked to point at the same digest"]
    s1 --> s2 --> s3 --> s4 --> s5 --> s6
  end

  t1 & t2 & t3 --> s1
  s6 --> img[/"GHCR base/jre21 and<br/>base/ci-build, tags<br/>yyyymmdd-run and latest"/]:::out
  img -.->|"FROM of every app image,<br/>container of the build job"| u1["_gradle-build.yml"]:::wf
  img -.->|"image of it-runner"| u2["_integration-test.yml"]:::wf
```

- The `setup-build-env` action builds these images locally from the same Dockerfiles in two cases.
  Either GHCR has none yet, or a pull request changes `docker/base/**`, so the change is tested before
  this workflow publishes it.

## Inside the reusable workflows

Where each composite action runs inside the reusable workflows. Amber hexagons are composite actions.

### `_gradle-build.yml`

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef act fill:#fef3c7,stroke:#d97706,color:#0f172a

  caller(["called by pr.yml and main.yml<br/>inputs: projects, build-images,<br/>push-images"]):::trigger

  subgraph GB ["_gradle-build.yml"]
    probe["probe<br/>finds base/ci-build and<br/>base/jre21 in GHCR, plans<br/>the Gradle tasks from<br/>affected-map.yml"]
    gradle["gradle<br/>in the ci-build container,<br/>or on the host until it is<br/>published: build, unit tests,<br/>quality gates, version,<br/>images, push"]
    collect["image digests<br/>only when images<br/>were pushed"]
    probe --> gradle --> collect
  end

  caller --> probe
  rl{{"registry-login"}}:::act
  sbe{{"setup-build-env<br/>JDK on the host, Gradle<br/>cache, base/jre21"}}:::act
  probe --- rl
  gradle -.-|"when images<br/>are built"| rl
  collect --- rl
  gradle --- sbe
```

### `config-lint.yml`

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef act fill:#fef3c7,stroke:#d97706,color:#0f172a

  c1(["called by pr.yml and main.yml"]):::trigger
  c2(["its own pull_request run<br/>when config/**, **/helm/**<br/>or **/docker/docker-compose.yml<br/>changed"]):::trigger

  subgraph CL ["config-lint.yml, job config-lint"]
    s1{{"setup-build-env"}}:::act
    s2{{"setup-kube-tools<br/>helm, kubeconform"}}:::act
    s3["./gradlew configLint<br/>naming, identity, compose render,<br/>helm lint and helm template<br/>per instance, kubeconform"]
    s4["report in the job summary<br/>and as an artifact"]
    s1 --> s2 --> s3 --> s4
  end

  c1 --> s1
  c2 --> s1
```

### `_integration-test.yml`

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef act fill:#fef3c7,stroke:#d97706,color:#0f172a

  caller(["called by pr.yml and main.yml<br/>level component or system"]):::trigger

  subgraph IT ["_integration-test.yml, job it"]
    s1{{"registry-login"}}:::act
    s2{{"setup-build-env<br/>Gradle cache, base/ci-build for it-runner"}}:::act
    s3{{"compose-stack up<br/>pull, up --wait"}}:::act
    s4["integration tests in it-runner<br/>./gradlew project:integrationTest"]
    s5{{"compose-stack diagnostics<br/>then upload"}}:::act
    s6{{"compose-stack down and leak-check<br/>always, also after a cancel"}}:::act
    s1 --> s2 --> s3 --> s4 --> s6
    s4 -.->|"failure"| s5 --> s6
  end

  caller --> s1
```

### `_docker-publish.yml`

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart LR
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef act fill:#fef3c7,stroke:#d97706,color:#0f172a

  caller(["called by main.yml publish<br/>and release.yml promote"]):::trigger

  subgraph DP ["_docker-publish.yml, job retag"]
    s1{{"registry-login"}}:::act
    s2["Retag by digest<br/>scripts/ci/retag-image.sh,<br/>every write verified,<br/>version tags never moved"]
    s1 --> s2
  end

  caller --> s1
```

### `_kind-deploy.yml`

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef act fill:#fef3c7,stroke:#d97706,color:#0f172a

  caller(["called by pr.yml and main.yml"]):::trigger

  subgraph KD ["_kind-deploy.yml, job kind-deploy"]
    s1{{"registry-login"}}:::act
    s2{{"setup-kube-tools<br/>kind, kubectl, helm, kubeconform"}}:::act
    s3{{"kind-cluster up"}}:::act
    s4{{"kind-cluster load<br/>the image built in this run"}}:::act
    s5{{"helm-deploy-instance<br/>one release per instance: lint,<br/>upgrade --install, rollout, helm test"}}:::act
    s6["smoke diff<br/>scripts/helm-smoke-diff.sh"]
    s7{{"kind-cluster diagnostics<br/>then upload"}}:::act
    s8{{"kind-cluster down and leak-check<br/>always, also after a cancel"}}:::act
    s1 --> s2 --> s3 --> s4 --> s5 --> s6 --> s8
    s6 -.->|"failure"| s7 --> s8
  end

  caller --> s1
```

### `_deploy-dev.yml`

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  classDef default fill:#ffffff,stroke:#64748b,color:#0f172a
  classDef trigger fill:#dbeafe,stroke:#2563eb,color:#0f172a
  classDef act fill:#fef3c7,stroke:#d97706,color:#0f172a
  classDef out fill:#dcfce7,stroke:#16a34a,color:#0f172a

  caller(["called by main.yml on main only<br/>Environment dev"]):::trigger

  subgraph DD ["_deploy-dev.yml, job deploy"]
    g["Guard<br/>only *-dev envs and a valid tag"]
    rt["Resolve the targets<br/>every config/us-dev/FLOW/<br/>workflows-config.yml"]
    rd["Record the deployment: in progress"]
    cp["Deploy compose targets<br/>flow with a pool:<br/>scripts/pool-deploy.sh bundle<br/>and deploy, over ssh when<br/>DEV_DEPLOY_SSH_KEY is set,<br/>else local; flow without<br/>a pool: run-compose.sh<br/>start --dry-run"]
    hp["Plan the helm targets"]
    subgraph HK ["helm targets of cluster kind-ci"]
      h1{{"setup-kube-tools"}}:::act
      h2{{"registry-login"}}:::act
      h3{{"kind-cluster up and load"}}:::act
      h4{{"helm-deploy-instance"}}:::act
      h5{{"kind-cluster down and leak-check<br/>always"}}:::act
      h1 --> h2 --> h3 --> h4 --> h5
    end
    wb["Write back the deployed tag<br/>scripts/ci/write-back-tag.sh:<br/>IMAGE_TAG, image.tag and<br/>the host of pooled instances"]
    ff["Fail when a target failed"]
    rr["Record the deployment result"]
    g --> rt --> rd --> cp --> hp --> h1
    hp -.->|"no kind-ci target"| wb
    h5 --> wb --> ff --> rr
  end

  caller --> g
  wb --> commit[/"commit on main<br/>chore(config): us-dev<br/>deployed TAG [skip ci]"/]:::out
```

## Composite actions by pipeline

Which composite actions each pipeline uses, directly or through its reusable workflows:

| Composite action | Push to a branch | Pull request, merge queue | Push to main | Tag push, release | Nightly | Base images |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `affected-matrix` | ✓ | ✓ | | | | |
| `registry-login` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `setup-build-env` | ✓ | ✓ | ✓ | ✓ | ✓ | |
| `setup-kube-tools` | ✓ | ✓ | ✓ | | | |
| `compose-stack` | | ✓ | ✓ | | ✓ | |
| `kind-cluster` | | ✓ | ✓ | | | |
| `helm-deploy-instance` | | ✓ | ✓ | | | |

What each one does and where it is used:

| Composite action | What it does | Used by |
|---|---|---|
| [`affected-matrix`](../actions/affected-matrix/action.yml) | Runs `scripts/ci/affected.py` over `affected-map.yml`: the projects to build, the integration-test matrix, the full, docs-only and deploy-test flags | `pr.yml` detect-affected |
| [`registry-login`](../actions/registry-login/action.yml) | Logs Docker in to GHCR with `GITHUB_TOKEN`; the JFrog OIDC mode is a stub | `_gradle-build.yml` probe, gradle and image digests; `_integration-test.yml`; `_docker-publish.yml`; `_kind-deploy.yml`; `_deploy-dev.yml` for kind; `release.yml` resolve; `base-image.yml`; `nightly.yml` drills |
| [`setup-build-env`](../actions/setup-build-env/action.yml) | JDK 21 when the job is not in ci-build, Gradle wrapper validation and cache, the base images from GHCR or built locally | `_gradle-build.yml` gradle; `config-lint.yml`; `_integration-test.yml`; `release.yml` resolve; `nightly.yml` drills |
| [`setup-kube-tools`](../actions/setup-kube-tools/action.yml) | Installs the pinned kind, kubectl, helm and kubeconform, each checked against its published checksum | `config-lint.yml`; `_kind-deploy.yml`; `_deploy-dev.yml` for kind |
| [`compose-stack`](../actions/compose-stack/action.yml) | Wraps `test-infra/compose/stack.sh`: up, diagnostics, down, leak-check | `_integration-test.yml`; `nightly.yml` drills |
| [`kind-cluster`](../actions/kind-cluster/action.yml) | Wraps `test-infra/kind/kind.sh`: up, load, diagnostics, down, leak-check | `_kind-deploy.yml`; `_deploy-dev.yml` for kind |
| [`helm-deploy-instance`](../actions/helm-deploy-instance/action.yml) | Wraps `scripts/helm-deploy-instance.sh`: one Helm release per instance, then `helm test` | `_kind-deploy.yml`; `_deploy-dev.yml` for kind |

Third-party actions: `actions/checkout` in most jobs, `actions/upload-artifact` for reports,
diagnostics and SBOMs, `actions/download-artifact` for the SBOMs in `release.yml`, `actions/setup-java`
and `gradle/actions/setup-gradle` inside `setup-build-env`, `docker/login-action` inside
`registry-login`, `docker/setup-buildx-action` and `docker/build-push-action` in `base-image.yml` and
`setup-build-env`, `googleapis/release-please-action` in `release-please.yml`, and `anchore/sbom-action`
in `release.yml`.
