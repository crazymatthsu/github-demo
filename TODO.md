# TODO — Architecture Design Brief: Deephaven Platform & Connectors

> **Status:** DRAFT v0.5 (v0.2 restructured the v0.1 question list; v0.3 added containerised CI
> execution with an ephemeral Deephaven server; v0.4 set **production on Kubernetes / EKS**,
> compose for tests only, and the demo simplifications; v0.5 decides **one Gradle monorepo, no git
> submodules**; see §10).
> **Purpose:** requirements-and-questions brief for two deliverables: (A) a set of architecture
> design documents and (B) a demo skeleton project that proves the conventions end to end.
> **Not in this file:** the design itself, code, or final decisions. Every row in §6 stays `open`
> until a design document recommends an answer and the team confirms it.

---

## 0. How to read this document

| Section | What it is for |
|---|---|
| §1 | The request in one paragraph, and the order of work |
| §2 | Context, constraints, target repository layout and per-subproject conventions |
| §3 | Deliverable A — design documents to produce, with diagram requirements |
| §4 | Deliverable B — demo skeleton project scope (in / out) |
| §5 | Topics: for each one the original ask, what a good answer must cover, options to evaluate, tasks |
| §6 | Decision log — every open decision in one table |
| §7 | Acceptance criteria for both deliverables |
| §8 | Open questions and assumptions to confirm with platform / infra / security teams |
| §9 | Glossary |
| §10 | Change log of this brief |
| Appendix A | Traceability: every question from v0.1 → where it is covered now |

Checkbox items (`- [ ]`) are actionable tasks for whoever produces the design docs and the skeleton.

---

## 1. Request summary

Produce a design plan, as `.md` documents with diagrams, for the architecture topics in §5, and then
build a demo project in this repository: a working "hello world" skeleton that implements the
repository layout, Gradle multi-project build, Docker images, docker-compose templates,
`run-compose.sh`, the configuration hierarchy, Vault integration, versioning, and GitHub Actions
CI/CD — with **no business logic**.

CI must build, unit-test and integration-test **inside containers on GitHub runners**, with a
**Deephaven server container running** during the integration tests and **everything torn down**
after every run, whether it passed, failed or was cancelled (§5.11).

**Order of work**

1. Finalise this brief: answer the §8 questions that gate decisions.
2. Write the design documents (§3). Each document records a recommendation for its §6 rows.
3. Review; mark §6 rows `decided` (one ADR per decision, see §5.13).
4. Build the demo skeleton (§4) against the decided conventions only.
5. Verify against the acceptance criteria (§7).

Do not start the skeleton before every §6 row marked **blocking = yes** has a recommendation.

---

## 2. Context and constraints

### 2.1 System landscape (as understood — confirm in §8)

- A data platform built around **Deephaven** (real-time table engine) fed by **connectors** that
  ingest from **Kafka**, **AMPS** (60East) and **relational databases** (SQL Server via JDBC), and
  publish into Deephaven and/or AMPS.
- **Hazelcast** appears in the integration-test list; its role (cache, distributed map, connector
  source/target?) needs clarifying.
- Business flows `cash`, `deriv`, `swap` and regions `us`, `jp` suggest trading / market-data
  flows → deployment windows and regional isolation matter (§5.12).
- **Deployment target (confirmed v0.4): production runs on Kubernetes — Amazon EKS.**
  docker-compose is used **only** for local development and CI test stacks; it is not a production
  artefact. Every runtime answer below (config delivery, secrets, CD, health, operations) targets
  Kubernetes; compose answers apply to tests and developer machines. Still open: are dev and qa on
  EKS too, one cluster per `<region>-<stage>` or namespaces in shared clusters (§8)?

### 2.2 Technology constraints (given)

| Area | Constraint |
|---|---|
| Repository | **One Gradle monorepo. Git submodules are not used anywhere in this project** — not for code, config or test data (decided v0.5, DL-01) |
| Build | Gradle multi-project, Gradle wrapper pinned, all dependencies resolved through JFrog (no direct internet) |
| Language / runtime | Java 21 (LTS); Spring Boot 3.x or 4.x — baseline to decide (DL-23) |
| Secrets | HashiCorp Vault for **all** secrets; Spring Vault / Spring Cloud Vault for database credential retrieval |
| Trust | Enterprise CA certificate must be trusted inside every image (OS trust store **and** JVM truststore) |
| CI/CD | GitHub Actions; JFrog Artifactory as Docker registry + Maven/Gradle repository (+ Xray scanning if available) |
| Production platform | **Kubernetes on Amazon EKS** (confirmed v0.4); cluster topology per `<region>-<stage>` to confirm (§8) |
| Containers | Docker **and** Podman must work for local development and CI test stacks; compose is never deployed to production |
| Versioning | Derived from git (tags / commits); **never** stored in a `version.txt` |
| Environments | `dev` → `qa` → `prod`, per region (`us`, `jp`) |
| CI execution | Build, unit tests and integration tests run on GitHub runners **inside containers**; a **Deephaven server container** is up for the integration tests; **everything is torn down** after each run, also on failure or cancel (§5.11) |
| Demo simplifications (v0.4) | **GitHub-hosted runners**; **no Vault** in the demo — secrets stubbed behind the final Spring property names; GHCR as registry stand-in (§4) |

### 2.3 Repository layout (monorepo with Gradle subprojects)

"Git subprojects" means **Gradle subprojects inside one git repository**. Decided v0.5: one Gradle
monorepo, **no git submodules** in this project. Rationale in §5.1 (DL-01).

```
<repo-root>/
├── settings.gradle.kts
├── build.gradle.kts
├── gradle/
│   ├── wrapper/
│   └── libs.versions.toml            # version catalog: single place for dependency versions
├── build-logic/                      # convention plugins: java-conventions, spring-boot-app, docker-image, integration-test
├── deephaven-server/                 # subproject: Deephaven server packaging (image, plugins, startup scripts)
├── deephaven-connectors/             # parent subproject: aggregates the connector family, shared BOM
│   ├── connectors-framework/         # library: connector abstractions, config binding, health, metrics, sinks
│   ├── source-kafka/                 # app: Kafka → Deephaven / AMPS
│   ├── source-amps/                  # app: AMPS → Deephaven
│   └── source-database/              # app: JDBC (SQL Server) → AMPS / Deephaven
├── config/                           # candidate to move to its own repository — see §5.7 / DL-06
├── test-infra/                       # compose stacks for dependencies (kafka, amps, sqlserver, deephaven, hazelcast, vault)
├── .github/
│   ├── workflows/                    # pr, main, release, nightly, base-image
│   └── actions/                      # composite actions shared by workflows
├── docs/                             # design documents produced from this brief (§3) + adr/
├── TODO.md
└── README.md
```

Naming rule to define: directory name, Gradle project name, Docker image name and `AppName` must be
the **same** lower-case kebab-case token (e.g. `source-kafka`). The v0.1 draft mixed `source-Kafka`
and `source-kafka`.

### 2.4 Per-subproject directory convention (every deployable app)

```
<subproject>/
├── build.gradle.kts
├── README.md                          # what it does, how to run locally, config keys it understands
├── src/
│   ├── main/java/...
│   ├── main/resources/application.yml # environment-agnostic safe defaults ONLY (baked into the jar)
│   ├── test/java/...                  # unit tests — no containers
│   └── integrationTest/java/...       # separate source set — needs docker / podman
├── docker/
│   ├── Dockerfile                     # multi-stage, enterprise CA, non-root, container-aware JVM flags
│   └── docker-compose.yml             # ONE template for all env/flow/instance; LOCAL DEV + CI TEST STACKS ONLY
├── scripts/
│   └── run-compose.sh                 # <env> <business-flow> <AppName> <AppInstance> <cmd>   (spec in §5.8)
├── k8s/                               # Kubernetes packaging for THIS app: Helm chart or Kustomize base (DL-29)
│   └── ...                            # Deployment, Service, ConfigMap mounts, probes, resources
└── config/                            # may live in the config repo instead (§5.7)
    └── <env>/                         # us-dev | us-qa | us-prod | jp-dev | jp-qa | jp-prod
        └── <business-flow>/           # cash | deriv | swap
            └── <AppName>/             # == subproject name, e.g. source-kafka
                ├── app-common/        # shared by all instances of this app in this env + flow
                │   ├── application.yml
                │   └── ...            # logback.xml, client properties, ...
                └── <AppInstance>/     # same image, different config (e.g. source-kafka-01)
                    ├── compose.env    # variables consumed by docker-compose.yml: IMAGE_TAG, ports, JVM opts, paths
                    ├── application.yml # instance overrides: endpoints, topics, subscriptions, table names
                    └── ...            # other instance files
```

Gaps in the v0.1 tree to resolve while writing D5:

- **`qa` is missing.** The CI/CD ask names dev → qa → prod, but the env list only has dev and prod.
  Proposed env token: `<region>-<stage>` with stage ∈ {dev, qa, prod} (+ `local` for developers).
- **Only one "common" level exists** (`app-common` per env + flow). Settings common to *all* envs,
  or to a whole env, currently have no home. Candidate extra layers: `config/_common/<AppName>/`,
  `config/<env>/_common/`, `config/<env>/<flow>/_common/`. Decide the maximum number of layers
  (suggest ≤ 4 file layers) and the precedence order (§5.6).
- **AppInstance naming** is undefined: numeric (`-01`), by upstream (`-bbg-feed`), or by target?
  The instance id will appear in Deployment and container names, logs, metrics and possibly
  Deephaven table names.
- **Kubernetes mapping (v0.4)**: every `application.yml` layer becomes a ConfigMap entry mounted
  under `/config/...`; `compose.env` values become container `env` and overlay values (image tag,
  resources, ports); one Deployment per AppInstance; the config tree doubles as the GitOps
  inventory (§5.6, §5.7, DL-33). Compose mounts the same files for tests.
- Typos fixed from v0.1: `DockerFile` → `Dockerfile`, `AppInstnace` → `AppInstance`,
  `comfig` → `config`.

---

## 3. Deliverable A — design documents

One document per topic under `docs/`, Mermaid diagrams so they render on GitHub. Suggested set
(rename freely, keep the numbering stable so the docs can cross-reference):

| Doc | File | Covers |
|---|---|---|
| D0 | `docs/00-overview.md` | One-page architecture overview, index of D1–D9, glossary, decision log / ADR index |
| D1 | `docs/01-repository-and-build.md` | §5.1 monorepo layout, Gradle multi-project, convention plugins, Java 21 toolchain |
| D2 | `docs/02-secrets-and-vault.md` | §5.2 Vault layout, authentication, Spring Vault DB credentials, local dev Vault |
| D3 | `docs/03-docker-images.md` | §5.3 Dockerfile standard, enterprise CA, base image, image naming |
| D4 | `docs/04-versioning-and-image-tagging.md` | §5.4 semver automation, git-tag triggers, lockstep vs independent, tag conventions, retention; §5.5 tags in compose |
| D5 | `docs/05-configuration-management.md` | §5.6 config hierarchy, layering & precedence, env vars vs YAML; §5.7 config repo and GitOps delivery |
| D6 | `docs/06-runtime-operations.md` | §5.8 `run-compose.sh` for local / test stacks; §5.13 Kubernetes runtime: probes, resources, logging, restart behaviour |
| D7 | `docs/07-ci-pipeline-github-actions.md` | §5.9 workflows, affected-subproject detection, caching, JFrog publish |
| D8 | `docs/08-integration-testing.md` | §5.10 docker/podman test infrastructure, test-data repository, golden-file comparison |
| D9 | `docs/09-cd-and-release-management.md` | §5.12 dev → qa → prod promotion via GitOps to EKS, rollback, hotfix, release cycle |
| D10 | `docs/10-containerised-ci-execution.md` | §5.11 job layout on GitHub runners, CI build image, Deephaven server lifecycle in CI, Kubernetes test tier (kind / ephemeral namespace / ARC), layered teardown guarantee, leak check, local parity |
| D11 | `docs/11-kubernetes-packaging-and-gitops.md` | §5.5–§5.7 Helm / Kustomize packaging per app, AppInstance modelling, config-tree → manifests mapping, Argo CD / Flux delivery, secrets delivery in Kubernetes |

**Template for every document**

1. Purpose and scope
2. Context and constraints (link back to this brief)
3. Requirements (the "must answer" bullets from §5)
4. Options considered — table with pros / cons / when to prefer
5. Recommendation and rationale
6. Conventions — tables with **concrete examples** (names, paths, tags, commands)
7. Diagrams (see below), each with a caption and a 2–3 line explanation
8. How the demo skeleton implements it (file pointers)
9. Open items / follow-ups

**Diagram requirements** (the v0.1 ask: flow, structural and sequence diagrams so concepts are easy
to grasp). Minimum set per document:

| Doc | Structural | Flow | Sequence |
|---|---|---|---|
| D0 | System context; deployment topology (regions × envs × hosts × instances) | Request-to-production overview | — |
| D1 | Repo tree; Gradle project graph | Local build → CI build | — |
| D2 | Vault path layout mirroring config hierarchy | Secret provisioning (who writes secrets, when) | App start → Vault auth → fetch DB creds → JDBC connect; credential rotation |
| D3 | Image layering (enterprise base → JRE base → app) | CA bundle → base image → app images; CA rotation rebuild | — |
| D4 | Registry / repository layout in JFrog | git event (PR, main, tag) → version → image tags → JFrog → promotion; retention job | Tag push → workflow → JFrog → config-bump PR |
| D5 | Config layering & precedence; config repo tree | Config change → PR → lint → merge → GitOps sync → rolling update | Controller reconciling a ConfigMap change into a pod restart |
| D6 | Pod internals (containers, mounts, probes, resources) and the compose equivalent for tests | `run-compose.sh` command dispatch | Pod start → config mount → readiness → traffic; `run-compose.sh start` for a test stack |
| D7 | Workflow topology (triggers → jobs → artifacts) | PR checks; main build; nightly | PR → checks → merge → main build → publish |
| D8 | Test-infra stack | Test levels (unit → component IT → system IT → smoke) | Start deps → seed → run connector → assert → teardown |
| D9 | Cluster / namespace / approval matrix per `<region>-<stage>` | dev → qa → prod promotion through the config repo with gates; hotfix path | Prod deploy via GitOps sync incl. rollback; gitGraph for release / hotfix branching |
| D10 | Runner → job container → Deephaven and dependency containers → job network (one per execution model A–D); Kubernetes variants (kind in job, ephemeral namespace, ARC) | Job lifecycle: pull → start dependencies → wait healthy → build / test → collect logs → teardown → leak check | Workflow job → compose or Testcontainers → Deephaven → tests → teardown, with the failure and cancel paths drawn |
| D11 | Config tree → ApplicationSet → Application per instance → Deployment + ConfigMap + Secret | Config or image change → PR → lint → merge → controller sync → rolling update | Image bump PR → merge → controller sync → rollout → readiness → smoke test |

Tasks

- [ ] Agree the document list and numbering.
- [ ] Write D0–D9 following the template.
- [ ] Add a traceability table in D0 mapping every §5 "must answer" bullet to a doc section.

---

## 4. Deliverable B — demo skeleton project

**In scope**

- Gradle multi-project as in §2.3 with version catalog, convention plugins, Java 21 toolchain.
- `connectors-framework` library consumed by `source-kafka`, `source-amps`, `source-database`.
- Each app: Spring Boot "hello world" that on start-up logs its `env / flow / AppName / AppInstance`,
  prints a summary of its effective configuration (secrets masked) and exposes actuator health.
- `deephaven-server` skeleton: packaging of the upstream Deephaven image with enterprise CA and a
  placeholder plugin / start-up script (exact scope to decide, see §5.1 tasks).
- Per app: `Dockerfile`, `docker-compose.yml` template, `run-compose.sh` with every command in §5.8,
  and config for at least `us-dev/cash/<AppName>/{app-common, <inst-01>, <inst-02>}` where the two
  instances differ in endpoints — proving the override mechanism.
- Secrets (demo simplification, v0.4): **no Vault**. The DB password and any other secret arrive as
  environment variables (compose) or a Kubernetes `Secret` (kind slice), bound to the **same Spring
  property names** the Vault integration will use later, so moving to Vault is a property-source
  change (`spring.config.import=vault://...`), not a code change. D2 still designs the Vault path.
  `source-database` runs a hello-world query against SQL Server with that password.
- One end-to-end integration test (SQL Server → `source-database` → stub target, or Deephaven / AMPS
  if images are available) that passes locally on Docker **and** Podman, and on a GitHub-hosted
  runner.
- GitHub workflows: PR, main, release (tag) — green in this repo on **GitHub-hosted runners**
  (`ubuntu-latest`); images pushed to a registry (GHCR as stand-in for JFrog).
- Kubernetes slice (proposed, confirm — DL-32): minimal packaging for one app (`source-database`)
  as a Helm chart or Kustomize base plus the overlay for `us-dev/cash/source-database/<inst-01>`,
  deployed to a `kind` cluster in a CI job with a readiness wait and a smoke test, then deleted. It
  proves the config-tree → manifest mapping before any EKS cluster exists. Argo CD / Flux wiring is
  documented in D11, not built.
- Versioning: main push produces a pre-release tag; pushing `v0.1.0` produces `0.1.0` image tags;
  release workflow opens a PR bumping `IMAGE_TAG` in the dev config.
- CI proof (§5.11): the PR workflow builds and unit-tests inside the `ci-build` container image; an
  integration-test job starts a Deephaven server container, waits for its readiness probe, runs one
  IT that writes and reads a table through the Deephaven client, uploads logs on failure, tears
  everything down, and ends with a leak-check step that proves nothing is left on the runner.

**Out of scope**

- Real connector logic, schemas, performance work.
- Production Vault / JFrog / self-hosted runner set-up (documented, not provisioned).
- Vault integration in code (designed in D2, deferred to the next iteration).
- Real EKS clusters, Argo CD / Flux installation, IRSA, ingress, network to on-prem sources
  (documented in D11, not provisioned).

Tasks

- [ ] Confirm the in/out list above before starting.
- [ ] Confirm GHCR as the stand-in registry and the no-Vault stub (§8).
- [ ] Confirm whether the kind-based Kubernetes slice is part of the demo (DL-32).

---

## 5. Topics

Each topic: **Original ask** (from v0.1) → **Must answer** → **Options to evaluate** → **Tasks**.

### 5.1 Repository and build (Gradle, Java 21)

**Original ask:** "use gradle build, java 21"; many subprojects under one repo, including a parent
subproject (`deephaven-connectors`) with children. **Asked v0.4:** Gradle monorepo or git submodules?
**Decided v0.5: one Gradle monorepo; git submodules are not used in this project, for simplicity.**

**Rationale kept for the record (DL-01).**

| | Gradle monorepo (one repo, multi-project build) | Git submodules (one repo per subproject, pinned SHAs) |
|---|---|---|
| Change touching framework + a connector | one atomic commit, one PR, one CI run | several PRs plus a pin-bump PR; easy to leave inconsistent |
| Dependency versions | one version catalog, one BOM | drift between repos unless policed |
| CI | one pipeline with affected-project detection | recursive clone with credentials per repo; pins bumped by CI |
| Refactoring / IDE | whole codebase in one workspace | detached HEADs, `--recurse-submodules`, forgotten pin updates |
| Release | tags per repo or per subproject (§5.4) | natural per-repo releases |
| Access control | per path (CODEOWNERS) | per repo |
| Fits when | one team owns the family and the framework API is still moving | a hard boundary is imposed: different owners, compliance, a vendor component |

If a boundary is ever needed, split into separate repositories that consume `connectors-framework`
as a **published, versioned artifact** from JFrog — never submodules. `deephaven-server` is the only
later candidate for that (different cadence, mostly upstream packaging); start it in the monorepo.

Consequences of the no-submodule rule elsewhere in this brief: test data comes from a JFrog artifact
or a second-repo checkout in CI (§5.10, DL-16); a separate config repo, if chosen, is consumed by the
GitOps controller and by CI checkouts, never embedded (§5.7, DL-06); the design docs live in this
repository under `docs/`.

**Must answer**

- Gradle multi-project structure with a nested parent (`:deephaven-connectors:source-kafka` etc.),
  root aggregation tasks (`build`, `check`, `integrationTest`, `buildImages`, `publish`).
- Centralised dependency management: version catalog (`gradle/libs.versions.toml`) + Spring Boot BOM
  via `platform(...)`; policy for upgrades (Renovate / Dependabot through JFrog remotes).
- Convention plugins in `build-logic/` (composite build): Java 21 toolchain, test configuration,
  formatting / static analysis, coverage, Spring Boot app conventions, Docker image tasks,
  `integrationTest` source set wired so `check` does **not** run ITs by default.
- Toolchain provisioning inside the enterprise: JDK distribution (Temurin / Corretto / company build)
  must match the runtime base image; Foojay auto-download is probably blocked → JDK via runner image
  or JFrog generic repo.
- Reproducibility: pinned wrapper, JFrog virtual repos for plugins **and** dependencies
  (`pluginManagement` + `dependencyResolutionManagement`), credentials from env, optional dependency
  verification.
- Build performance: Gradle build cache (local; remote node if available), configuration cache,
  parallel; CI cache strategy.
- Affected-subproject detection for CI (path filters → Gradle project mapping; fall back to
  building everything on `main`).
- `project.version` derived from git at build time (see §5.4), never from a checked-in file.
- What `deephaven-server` is as a Gradle subproject: Java code (plugins) + image, or image only?

**Options to evaluate**

- Kotlin DSL vs Groovy DSL (DL-22).
- Image build: Dockerfile via buildx vs Jib (no daemon, reproducible, but Dockerfile was requested
  and gives CA / OS control) (DL-14).
- Jar built by Gradle then `COPY` into the image vs multi-stage Gradle build inside Docker.
- Spring Boot layered jar (`layertools`) for cache-friendly image layers.

Tasks

- [ ] Decide DSL, Spring Boot baseline, Jib vs Dockerfile.
- [ ] Define shared quality gates (format, static analysis, coverage threshold) and where they run.
- [ ] Define the `deephaven-server` subproject scope.
- [ ] Define root aggregate tasks and naming for image tasks.

### 5.2 Secrets — Vault and Spring Vault

**Original ask:** "need to use vault for secrets"; "use spring vault for database password
retrieval".

**Must answer**

- Vault topology: one cluster or per region; namespaces (Enterprise); who owns policies.
- **Path convention mirroring the config hierarchy**, e.g. `secret/<env>/<flow>/<app>/<instance>/...`
  plus common levels; policy per app / instance with least privilege.
- Authentication and the "secret zero" problem: on Kubernetes the pod's service-account token solves
  it (Vault Kubernetes auth); for local / test stacks, how the first credential reaches the container
  without living in git or an image.
- What counts as a secret (DB passwords, Kafka SASL / AMPS credentials, keystores, API tokens,
  licence files?) vs configuration (hostnames, ports) that stays in the config repo.
- Database credentials: static KV v2 vs Vault Database secrets engine (dynamic, leased, rotated);
  impact on long-running connectors (lease renewal, HikariCP pool refresh); SQL Server support.
- Spring integration: `spring.config.import=vault://...` (config-data API), profile → path mapping,
  fail-fast when Vault is unreachable, token renewal, retries, startup ordering (truststore must be
  present before the Vault client connects — ties to §5.3).
- Local dev and CI: Vault dev server in compose seeded by a script; Testcontainers Vault module for
  ITs.
- Audit, rotation policy, break-glass procedure.

**Options to evaluate**

- Auth on Kubernetes (production, v0.4): Vault **Kubernetes auth** — the pod's service-account token
  proves identity, so there is no secret zero to deliver. Delivery options (DL-31): **External
  Secrets Operator** (Vault → Kubernetes `Secret` → env / volume; app stays Vault-agnostic),
  **Vault Agent Injector** (sidecar / init container renders files), **Secrets Store CSI driver**
  with the Vault provider, or **Spring Cloud Vault in-process** using Kubernetes auth (no operator).
  AWS IRSA is the parallel for any AWS-native secret (DL-11).
- Auth for local / test stacks: AppRole or a dev-mode token against a compose Vault. **Not built in
  the demo** (skipped, §4): secrets come from env / `Secret` behind the final property names.
- DB credentials: static KV first, dynamic later (DL-12).

Tasks

- [ ] Confirm Vault edition, namespaces, enabled auth methods, DB secrets engine availability (§8).
- [ ] Decide auth method and secret-zero delivery.
- [ ] Decide static vs dynamic DB credentials.
- [ ] Define path and policy naming convention aligned with `env/flow/app/instance`.
- [ ] Demo: stub secrets behind the final property names and document the switch to Vault in D2.
- [ ] Define the local-dev Vault bootstrap for the iteration after the demo.

### 5.3 Docker images and the enterprise CA certificate

**Original ask:** "The docker images needs CA certificate from enterprise company."

**Must answer**

- Where the CA bundle comes from (JFrog generic artifact / URL / build `ARG`) and how it is
  **rotated**: renewing the CA must trigger a rebuild of every image.
- **Two trust stores**: OS (`update-ca-certificates` on Debian/Ubuntu, `update-ca-trust` on RHEL/UBI)
  and JVM (`keytool -importcert` into `cacerts`, or a separate truststore passed via
  `javax.net.ssl.trustStore`). Also needed by: Gradle in CI (JFrog through the proxy), `curl` health
  checks, Vault client, AMPS / Kafka TLS.
- Dockerfile standard: multi-stage, non-root UID/GID, `WORKDIR`, `HEALTHCHECK`, entrypoint that
  honours `JAVA_OPTS`, container-aware JVM flags (`-XX:MaxRAMPercentage`, GC choice), `TZ`,
  read-only root filesystem, `.dockerignore`, hadolint clean.
- OCI labels on every image: `org.opencontainers.image.{version,revision,source,created}` + custom
  `com.<company>.{app,git-sha,build-url}` — used by `run-compose.sh version` and by cleanup.
- Base image from JFrog remote only (Docker Hub direct is unavailable / rate-limited).
- Podman build compatibility (same Dockerfile with `podman build` / buildah).
- Image scanning gate (Xray / Trivy), SBOM generation, signing (cosign) — required or optional?
- Image naming: `<registry>/<docker-repo>/<group>/<subproject>`, e.g.
  `artifactory.<company>.com/docker-dev-local/deephaven-connectors/source-kafka`.
- EKS image pull (v0.4): nodes pull from JFrog (`imagePullSecrets`, egress) or from an **ECR mirror**
  in-region (IAM auth, faster pulls, replicated from JFrog) (DL-34). Node architecture: amd64 only,
  or multi-arch for Graviton (arm64)? The SQL Server test image is amd64-only, so CI stays amd64.
- Special images: `deephaven-server` (upstream `ghcr.io/deephaven/server` + CA + plugins), test-infra
  images (AMPS is licensed — likely an internal image; SQL Server; Hazelcast; Kafka).

**Options to evaluate**

- CA injection: **company base JRE image** built once by a `base-image` workflow (CA + tz + non-root
  user) that every app `FROM`s, vs per-Dockerfile `ARG`, vs runtime volume mount (DL-13).
- Base image: Temurin vs UBI vs distroless-style.

Tasks

- [ ] Confirm whether a company base image already exists and how the CA bundle is distributed (§8).
- [ ] Define the Dockerfile template and lint rules.
- [ ] Decide base JRE image and CA injection approach.
- [ ] Define the CA rotation procedure.

### 5.4 Versioning, image tagging and retention

**Original ask:** correct tagging / versioning strategy in an enterprise; should all subprojects be
built with the same version; no `version.txt`; hybrid approach — automated semantic versioning **and**
git tags trigger image tagging; tag naming conventions; clean up old unused non-production images.

**Must answer**

- Version source of truth is git. How the version is computed on every build and how a git tag turns
  into a release.
- **Lockstep vs independent versioning** with explicit criteria (how often subprojects change
  independently, stability of the `connectors-framework` API, ops preference for "one platform
  version" in change tickets).
- Hybrid flow: `main` pushes get automatic pre-release versions; a release happens on tag (created by
  hand or by a release PR). Hotfix versioning from a release tag.
- **Tag naming convention** — proposal to review in D4:

  | Event | Image tag(s) | Mutable? | Lifetime |
  |---|---|---|---|
  | PR build | `pr-123-<sha7>` | no | until PR closed + 7 days |
  | `main` push | `1.5.0-rc.<n>` or `1.5.0-SNAPSHOT.<yyyymmdd>.<sha7>` (pick one; must sort and be unique) | no | last N per subproject |
  | Release tag `v1.4.2` (or `source-kafka/v1.4.2`) | `1.4.2` **and** `sha-<sha7>` | no | forever (promoted) |
  | Convenience | `1.4`, `1`, `main`, `latest` | yes | dev / local only — **never referenced by qa or prod compose** |

- One image tag ↔ one git commit; OCI labels carry sha, version, build URL.
- **Promote, never rebuild**: the same digest moves `docker-dev-local → docker-qa-local →
  docker-prod-local` (Artifactory promotion) or is marked with properties — decide.
- Skip rebuilding unchanged subprojects under lockstep (retag the existing digest).
- **Retention / cleanup** of non-production images: Artifactory cleanup policies or a scheduled
  workflow using JFrog CLI: delete `pr-*` after PR close, keep last N pre-releases per subproject,
  delete untagged manifests, never touch the prod repo or anything referenced by a git tag, and
  protect any tag **currently referenced by an env's `compose.env`** (needs an "in-use" query against
  the config repo). Also cover Gradle snapshot artifacts and GitHub Actions caches.

**Options to evaluate**

- Version computation: git-describe Gradle plugins (axion-release, palantir git-version, nebula,
  reckon) vs Conventional Commits + release-please / semantic-release (auto changelog, release PR,
  tag) vs manual tag only (DL-04).
- Scope: lockstep / independent / **hybrid** (connector family lockstep, `deephaven-server`
  independent) (DL-03).

Tasks

- [ ] Choose the versioning tool and prove it in the demo (main push → pre-release tag; `v0.1.0` → release tag).
- [ ] Decide lockstep vs independent vs hybrid, and the git tag format that follows from it.
- [ ] Ratify the tag table above with examples for PR, main, release, hotfix.
- [ ] Define retention rules and the in-use protection mechanism.
- [ ] Define the hotfix versioning path (`1.4.2` → `1.4.3`) end to end.

### 5.5 Image tags in deployment manifests and in compose

**Original ask:** how to manage the image tag version in docker-compose; should the CI/CD process
auto-change the image tag in docker-compose? **Re-scoped v0.4:** in production the tag lives in
Kubernetes manifests; compose only carries it for local and test stacks.

**Must answer**

- Production: the tag is a field of the instance's manifests in the config repo — Helm
  `image.tag` in `values.yaml` or Kustomize `images[].newTag` under
  `config/<env>/<flow>/<app>/<instance>/` — and the GitOps controller (§5.7) rolls the Deployment
  when it changes. Same digest promoted across envs (§5.4), never rebuilt.
- Local and test stacks: the compose file is a template, `image: ${IMAGE_REPO}/source-kafka:${IMAGE_TAG}`
  with `IMAGE_TAG` in `compose.env`; CI sets it to the image built in the same run.
- Who changes `IMAGE_TAG` and where the record lives: git must be the deployment record.
- Tag vs digest pinning (`image@sha256:...` is immutable but unreadable; store both?) (DL-20).
- Drift detection: the controller reports desired vs live image (Argo CD `OutOfSync`, Flux status)
  and can self-heal; `run-compose.sh status` does the same for test stacks.
- Rollback = revert the bump commit.

**Options to evaluate**

- **GitOps bump**: release workflow opens a PR against the config repo ("bump source-kafka to 1.4.2
  in us-dev/*"); auto-merge for dev, reviewed for qa / prod; promotion is another PR.
- Deploy-time parameter: CD passes the tag at deploy and records it elsewhere (state outside git —
  weak audit).
- Manual edit by an operator (baseline, still via PR).
- Dev auto-bump by **Argo CD Image Updater** or Flux image automation (writes back to git), PR-only
  for qa / prod.
- Bot identity for the PRs: GitHub App token vs PAT (DL-09).

Tasks

- [ ] Decide GitOps bump vs deploy-time parameter.
- [ ] Decide tag vs digest pinning per environment (e.g. tag in dev, digest + tag comment in qa/prod).
- [ ] Define the bot identity and permissions for config-repo PRs.
- [ ] Decide dev auto-bump (image updater) vs PR-only for every env.

### 5.6 Configuration model for the Spring Boot services

**Original ask:** git directory structure for configs; where the common `application.yml` goes and
where the override goes; should environment variables parameterise `application.yml`; for the same
AppName with different AppInstances (different source / target TCP hosts and ports) — env vars or
override YAML?

**Must answer**

- **Layering and precedence**, lowest → highest — proposal to evaluate:

  | # | Layer | Location | Contents |
  |---|---|---|---|
  | 1 | Jar defaults | `src/main/resources/application.yml` | safe, environment-agnostic defaults |
  | 2 | Platform-wide app defaults (optional) | `config/_common/<AppName>/` | same in every env |
  | 3 | Env-wide (optional) | `config/<env>/_common/` | Vault address, log shipping endpoint, region TZ |
  | 4 | App common in env + flow | `config/<env>/<flow>/<AppName>/app-common/` | app defaults for this env and flow |
  | 5 | Instance overrides | `config/<env>/<flow>/<AppName>/<AppInstance>/` | endpoints, topics, subscriptions, table names |
  | 6 | Environment variables | `compose.env` → container env | small set of deploy-time knobs |
  | 7 | Vault | `vault://...` | secrets only |

- Mechanism: explicit `spring.config.import` / `spring.config.additional-location` list of optional
  files mounted under `/config/...` (deterministic, visible) vs Spring profiles
  (`spring.profiles.active=us-dev,cash,inst01` with `application-<profile>.yml`) (DL-07). Spring
  config-tree for file-based secrets if Vault Agent is used.
- **Kubernetes delivery (v0.4)**: each file layer becomes a ConfigMap entry — Kustomize
  `configMapGenerator` from the very same `application.yml` files that compose mounts for tests, or
  Helm `.Files.Get` — mounted under `/config/<layer>/`; `compose.env` values become container `env`
  in the overlay / values; one Deployment per AppInstance named `<app>-<instance>` (DL-33). Same
  files, two consumers: compose for tests, Kubernetes for production; the config-lint job renders
  both.
- **Env vars vs YAML rule** (to formalise): env vars for knobs that are per host / per instance and
  are **also consumed by compose** (image tag, published ports, memory, volume paths, instance id,
  Vault role, log level); YAML for structured application config (lists of topics / subscriptions,
  mappings). For source / target host:port either works — pick **one canonical place**, allow
  `${VAR}` placeholders in YAML for the few values shared with compose, and forbid defining the same
  key in both. Document the precedence table in D5.
- Instance identity: how `AppInstance` is named and propagated (container name, logs, metrics tags,
  Deephaven table names).
- Validation: `@ConfigurationProperties` + `@Validated`; a **config-lint** CI job that checks every
  instance has its required files, renders the merged configuration, and diffs key sets across
  environments (parity check dev vs qa vs prod).
- Non-Spring files (logback, Kafka / AMPS client properties, Deephaven scripts) follow the same
  hierarchy; how `application.yml` references them.
- Hostnames are fine in the config repo; **secrets never are** (pre-commit hook + secret scanning).

Tasks

- [ ] Choose explicit-import vs profile-based layering; fix the maximum layers and precedence.
- [ ] Write the env-var-vs-YAML rule with a worked example: two `source-database` instances with
      different SQL Server hosts and different AMPS topics.
- [ ] Define the required-file checklist per instance and the config-lint job.
- [ ] Define the AppInstance naming convention.

### 5.7 Configuration repository and delivery to clusters (GitOps)

**Original ask:** should config be separated into its own repo; how to auto-sync config to target
machines across environments, business flows, AppNames and AppInstances. **Re-scoped v0.4:** the
targets are EKS clusters, so "auto-sync" becomes GitOps reconciliation.

**Must answer**

- **Separate repo — trade-offs.** Pros: independent change cadence (config change without
  rebuild), stricter access (prod paths behind CODEOWNERS / approvals), clean audit of what is
  deployed, bot bump PRs do not pollute code history. Cons: version skew between config keys and code
  (mitigate: additive keys, tolerate unknown keys, tag config with app versions), two PRs for a
  feature needing new config, discoverability.
- Alternatives: same monorepo `config/` with CODEOWNERS and path-restricted workflows; one repo per
  env (prod isolation, usually overkill); code repo holds `app-common` defaults + schema while the
  env repo holds env / instance values.
- **Inventory**: on Kubernetes the config tree *is* the inventory — an Argo CD `ApplicationSet`
  (git directory generator × cluster generator) or Flux `Kustomization`s create one Application per
  `config/<env>/<flow>/<app>/<instance>/` directory and target the `<region>-<stage>` cluster. No
  separate host inventory (the VM inventory of v0.2 is dropped).
- **Delivery mechanism (v0.4)**: a controller in each cluster (or a hub) watches the config repo and
  reconciles; nothing is pushed to machines.
  - **Argo CD**: ApplicationSets, sync waves, **sync windows** (maps directly to trading-hours
    deployment windows), UI and RBAC, Image Updater; hub-and-spoke or per-cluster install.
  - **Flux**: `GitRepository` + `Kustomization` / `HelmRelease`, image automation; lighter, no UI.
  - CI push (`kubectl apply` / `helm upgrade` from a workflow): simplest, but state and audit live in
    the pipeline rather than the cluster; acceptable for the kind-based demo only.
  - Compose stacks (local / CI tests) read the checked-out config tree directly; nothing to sync.
- Criteria: is a controller already provided on the EKS platform (DL-30)? How a ConfigMap change
  becomes a rolling restart (checksum annotation vs Reloader); drift detection and self-heal; RBAC per
  env; audit; rollback = git revert; secrets never in the config repo (delivered per §5.2 / DL-31).
- Promotion of a config change dev → qa → prod: same PR flow as image bumps?

Tasks

- [ ] Decide monorepo vs separate config repo (DL-06).
- [ ] Decide the GitOps controller (DL-30) and the ApplicationSet / Kustomization layout that mirrors
      the config tree (DL-33).
- [ ] Define drift / self-heal policy, rollback and sync windows per env.
- [ ] Define how a ConfigMap change triggers a rollout (checksum annotation vs Reloader) and its blast
      radius (one instance at a time).

### 5.8 `run-compose.sh` specification

**Original ask:** `run-compose.sh <env> <business-flow> <AppName> <AppInstance> <cmd>` with
`start, stop, down, restart, config, printenv, health, ...`.

**Scope (v0.4):** `run-compose.sh` serves **local development and CI test stacks only**. Production
operations go through Kubernetes (GitOps sync, `kubectl`, the controller UI); compose is never run
in production. The command table still applies to test stacks; the prod-safety rules reduce to
"refuse any env other than `local` and the CI env".

**Must answer**

- Argument validation against the config tree; resolution of `CONFIG_DIR` (instance) and
  `COMMON_DIR` (`app-common`); compose project name `<env>-<flow>-<app>-<instance>` so containers
  are unique per host.
- Invocation: `docker compose -p <project> --env-file <instance>/compose.env -f docker/docker-compose.yml <cmd>`.
- Command table (define exactly, with exit codes and prod safety):

  | Command | Effect | Notes |
  |---|---|---|
  | `start` | `up -d` | pull policy? wait for healthy? |
  | `stop` | `stop` | graceful timeout |
  | `down` | `down` | **never** `-v` by default; refuse in prod without `--force` |
  | `restart` | `restart` or `down` + `up` | choose semantics |
  | `config` | render merged compose config | secrets masked |
  | `app-config` (new) | render effective Spring configuration | via actuator `/configprops` or dry-run |
  | `printenv` | resolved environment | secrets masked |
  | `health` | actuator health + compose state | exit 0 / 1 — usable by monitoring |
  | `status` / `ps` (new) | running containers, desired tag vs running digest | drift detection |
  | `logs [-f]` (new) | container logs | |
  | `pull` (new) | pre-pull image | for deploy windows |
  | `validate` (new) | required files present, compose lint, env var completeness | used by config-lint too |
  | `exec` / `shell` (new) | shell into container | audit-logged |
  | `version` (new) | image tag, digest, OCI labels (git sha, build URL) | |

- Docker vs Podman detection (`docker compose` vs `podman compose` / `podman-compose`), rootless
  Podman (ports < 1024, socket for health checks), SELinux volume labels (`:Z`).
- Mounts: config dir → `/config` read-only; logs volume; truststore; `TZ`.
- Safety and audit: `--dry-run`, consistent exit codes, an audit line (who / what / when) to syslog.
- Quality: ShellCheck in CI; optional bats tests.

Tasks

- [ ] Write the CLI spec table in D6 (command, effect, exit codes, prod safety).
- [ ] Decide `config` vs `app-config` semantics.
- [ ] Decide the Podman support level (first-class vs best-effort) (DL-19).

### 5.9 CI pipeline — GitHub Actions to JFrog

**Original ask:** how to build a workflow YAML for these subprojects so a push triggers build, unit
tests, integration tests, image build and publish to JFrog.

**Must answer**

- **Execution model**: build, unit tests and integration tests run inside containers with an
  ephemeral Deephaven server, torn down after every run — specified in §5.11 (DL-24, DL-27, DL-28).
  This section owns the workflow topology, triggers, gates and publishing.
- Workflow set: `pr.yml` (build, unit tests, lint, config-lint, affected component ITs), `main.yml`
  (full build, ITs, images with pre-release tags → JFrog dev repo, dev config bump PR), `release.yml`
  (on `v*` or `<subproject>/v*` tag: build or retag, promote, GitHub Release + changelog, qa bump
  PR), `nightly.yml` (full IT matrix, dependency / security scans, image retention), `base-image.yml`,
  and `config-lint.yml` in the config repo.
- Structure: reusable workflows (`workflow_call`) per concern (gradle-build, docker-build-push,
  integration-test) + composite actions (setup Java / Gradle / JFrog credentials / CA); matrix over
  subprojects from a JSON list produced by a "detect affected" job.
- Runners: **GitHub-hosted for the demo (decided v0.4)**. For the enterprise pipeline: GitHub-hosted
  vs self-hosted — Actions Runner Controller on EKS is the natural self-hosted form (network reach to
  JFrog / Vault, CA pre-installed, Docker via `dind`, capacity for ITs) (DL-17, DL-25).
- Authentication to JFrog: OIDC (GitHub → Artifactory) preferred over static tokens (DL-18); `jf`
  CLI for build-info and Xray scans; `maven-publish` for `connectors-framework` if other repos consume
  it.
- Caching: Gradle (`gradle/actions/setup-gradle`), Docker layer cache (buildx registry cache in JFrog
  or GHA cache).
- Concurrency groups and cancellation, required status checks, branch protection, CODEOWNERS.
- Quality gates: unit tests + coverage, formatting, static analysis, dependency vulnerability scan,
  hadolint, ShellCheck, secret scanning, licence check.
- Outputs: JUnit summaries, image digests as job outputs, SBOM, build-info.
- Gating of ITs on PRs (label-triggered vs always) and time budget.

Tasks

- [ ] Confirm runner type, network policy and JFrog OIDC availability (§8).
- [ ] Draw the workflow topology in D7.
- [ ] Define affected-subproject detection.
- [ ] Define which checks are required for merge.

### 5.10 Integration testing

**Original ask:** can Docker / Podman spin up Hazelcast, AMPS, Deephaven etc. for automated
integration tests; can we SSH to a test input / expected-output messages repo to fetch data and start
tests; how to spin up SQL Server for JDBC tests, query it, and publish to AMPS or Deephaven.

**Must answer**

- CI-side lifecycle (runner class, start-up, readiness, teardown, leak check) is specified in §5.11;
  this section owns test levels, test content, test data and the harness.
- Harness: Testcontainers (JUnit 5) per test class vs a `docker compose` stack per suite
  (Testcontainers `ComposeContainer`); Podman compatibility (`DOCKER_HOST` to the Podman socket,
  Ryuk considerations); runner topology if the runner itself is a container (socket mount vs DinD).
- Dependency images and constraints: Kafka (Apache / Confluent / Redpanda), Hazelcast, SQL Server
  (`mcr.microsoft.com/mssql/server` — EULA acceptance, amd64 only, ~2 GB, slow start → health
  check), Deephaven (`ghcr.io/deephaven/server`), **AMPS** (no public image; internal image with
  licence — CI licensing must be confirmed; fallback: contract tests against a shared dev AMPS),
  Vault dev. All pulled through JFrog remotes.
- **Test data**: options — checkout of a second repo with a deploy key / GitHub App token (HTTPS
  preferred over raw SSH), or **versioned datasets published to a JFrog generic repo** and downloaded
  by version (reproducible, large-file friendly); a git submodule is excluded by DL-01. Layout:
  `testdata/<connector>/<case>/{input/, expected/, manifest.yml}`; versioning compatible with app
  versions.
- Reference scenario (`source-database`): start SQL Server → apply schema + seed → start AMPS /
  Deephaven → start the **connector image** (not just classes) with an instance config → poll the
  target → compare with expected output (canonical JSON, ordering rules, timestamp tolerance) → tear
  down. Same shape for `source-kafka` (produce input) and `source-amps`.
- Test levels: unit (no containers) → component IT (one dependency, Testcontainers) → system IT
  (compose stack including our images; `main` / nightly) → post-deploy smoke test (§5.12).
- Speed and cost: container reuse, parallelism, image pre-pull, PR budget (~15–20 min).
- `test-infra/compose/` stacks reused for local development (`dev-up` task).

Tasks

- [ ] Confirm AMPS licensing and image availability for CI; Deephaven edition; Hazelcast role (§8).
- [ ] Choose the harness per test level (DL-15).
- [ ] Decide test-data distribution and versioning (DL-16).
- [ ] Define expected-output comparison rules.
- [ ] Define resource budget and which ITs run on PR vs main vs nightly.

### 5.11 Containerised CI execution — build, unit and integration tests with an ephemeral Deephaven server

**Original ask (added v0.3):** the GitHub runner must **build, unit-test and integration-test the
project within containers**, with a **Deephaven server running** during the integration tests, and
**spin everything down after the tests**.

**Must answer**

- **Which container layers are required** — confirm all three or a subset (§8):
  1. the dependencies under test run in containers (Deephaven server, SQL Server, Kafka, AMPS,
     Vault dev);
  2. the build and test process itself runs in a container: a pinned `ci-build` image (JDK 21,
     enterprise CA, container CLI, `jf` CLI; Gradle via the wrapper) so a CI run and a local run are
     the same environment;
  3. the runner itself is a container (Actions Runner Controller, or a Podman-hosted runner), which
     implies nested containers (socket mount or Docker-in-Docker) and their security trade-offs.
- **Kubernetes as the test substrate (asked v0.4)** — yes, in three ways, usable alone or together:
  1. **Runners on Kubernetes**: Actions Runner Controller (ARC) on EKS. Runner pods are created per
     job and destroyed after it, which gives the spin-down guarantee for free. `dind` mode keeps a
     Docker daemon in the pod so compose and Testcontainers work unchanged; `kubernetes` mode has no
     Docker, so dependencies must be Kubernetes resources and Testcontainers is out.
  2. **Dependencies in Kubernetes**: Deephaven (and SQL Server, Kafka) installed by Helm / manifests
     into an ephemeral namespace `ci-<run_id>` on a dev EKS cluster — the runner authenticates via
     GitHub OIDC → IAM role → EKS RBAC — deleted in the `always()` step with a namespace TTL as
     backstop; or into a **kind** cluster created inside the job (no cloud access, images loaded
     straight from the build).
  3. **Deployment tests**: the real chart / overlay for the app applied to kind (PRs touching `k8s/`,
     config or Dockerfiles) or to the dev EKS namespace (`main` / nightly), followed by a smoke test.
     This is the part compose cannot test, and with production on EKS it is required (DL-32).
  Component ITs stay on compose / Testcontainers: faster to start and identical on a laptop.
- **Demo decision (v0.4)**: GitHub-hosted runners (`ubuntu-latest`; Docker and compose preinstalled).
  Layer 3 (runner in a container) is out of scope for the demo; ARC on EKS is the enterprise
  follow-up (DL-17, DL-25).
- **Job layout** in the PR and `main` workflows: `build` (compile, unit tests, static checks, jar and
  image artifacts) → `integration-test` (start Deephaven plus only the dependencies the subproject
  needs, run `integrationTest`, collect logs, tear down) → `system-test` on `main` / nightly (compose
  stack with **our** images and Deephaven). Matrix per subproject vs one job; what runs on PR vs
  `main` vs nightly; `needs:` ordering so images built in `build` are what `system-test` runs.
- **Deephaven server lifecycle in CI**: image and version pin (upstream `ghcr.io/deephaven/server`
  through a JFrog remote, or our `deephaven-server` image built earlier in the same workflow), JVM
  heap via `START_OPTS`, auth mode for tests (anonymous handler vs pre-shared key), exposed port
  (10000), readiness probe (HTTP or gRPC health) with a start-up timeout, how tests reach it (service
  hostname on the job network vs mapped host port), how tests assert results (Deephaven Java client
  snapshot of the target table), and how test tables are isolated between test classes.
- **Teardown guarantee**, layered so that a leak needs several failures at once:
  1. a cleanup step with `if: always()` — it runs on success, failure **and** cancel — that executes
     `compose down -v --remove-orphans` for this run's project name and prunes anything labelled with
     this run id;
  2. every container, volume and network the job creates carries a label
     `com.<company>.ci.run=<run_id>` and a unique compose project name (`ci-<run_id>-<attempt>`), so
     parallel jobs on one runner never collide and cleanup can target exactly this run;
  3. ephemeral runners (a fresh VM or container per job) as the backstop; Testcontainers' Ryuk reaper
     wherever Testcontainers is used.
  A **leak-check step** after teardown lists containers, volumes and networks with the run label and
  fails (or warns) if any remain. `timeout-minutes` on every job so a hung Deephaven cannot hold a
  runner.
- **Diagnostics before teardown**: `compose ps`, Deephaven and dependency logs, JUnit reports, uploaded
  as artifacts on failure (or always) with a retention period.
- **Networking and ports**: no published host ports in CI (tests talk over the job or compose
  network); random host ports only where Testcontainers is used; rootless Podman constraints.
- **Caches inside containers**: Gradle home as a mounted volume or `actions/cache`; Docker layer cache;
  pre-pull of the Deephaven and SQL Server images to cut start-up time.
- **Resource budget**: Deephaven heap + SQL Server + Gradle daemon must fit the runner class; measure,
  then choose GitHub-hosted standard vs larger vs self-hosted (§5.9, DL-17).
- **Local parity**: one command (`./gradlew integrationTest`) runs the same start → test → stop
  lifecycle on a developer machine with Docker or Podman.
- **Security**: mounting the container socket into a job container is root-equivalent on the runner;
  acceptable on ephemeral runners only. Rootless Podman socket as the alternative.
- **Enterprise egress**: `ghcr.io` and `mcr.microsoft.com` may be blocked; every test image must be
  mirrored through JFrog remotes and pinned by digest.

**Options to evaluate** (DL-24)

| Model | How | Pros | Cons |
|---|---|---|---|
| A. Job `container:` + `services:` | GitHub starts the job container and a Deephaven service container on one network and removes both when the job ends | least YAML, teardown built in, hostnames for free | needs Docker on the runner (not Podman-only); one container per service, no compose stack; not reproducible locally as-is |
| B. Host job + Testcontainers | Gradle runs on the runner host; tests start Deephaven via Testcontainers; Ryuk reaps | closest to the test code, random ports, works locally | build itself is not in a container; Ryuk needs socket access; Podman quirks |
| C. Ephemeral compose stack | `compose up --wait` in a step, or a Gradle compose plugin (`composeUp` → `integrationTest` → `composeDown`), plus an `always()` down step | same path locally and in CI, Docker and Podman, whole stacks, our images testable | we own teardown, labels and project names; plugin maintenance |
| D. Fully containerised build in compose | `compose run --rm build ./gradlew build integrationTest` against the `deephaven` service | build and tests both in containers from one file, trivially reproducible | Gradle cache plumbing; slower cold starts; nested access if tests also use Testcontainers |

Leaning: **C**, with the `build` job running in the `ci-build` image (`container:`) — this covers
layers 1 and 2. Deephaven is a compose service with a health condition. Testcontainers stays for
single-dependency component ITs where it is already the natural fit. For the Kubernetes tier: kind
inside the job on PRs, an ephemeral namespace on dev EKS on `main` / nightly (DL-32).

Tasks

- [ ] Confirm which container layers are mandatory and which runner class is available (§8).
- [ ] Choose the execution model (DL-24) and the CI build image approach (DL-28).
- [ ] Define the Deephaven CI profile: version pin, heap, auth mode, readiness probe, start-up timeout.
- [ ] Define labels, the project-name scheme, the `always()` teardown and the leak-check step; prove
      them on a passing, a failing and a cancelled run.
- [ ] Define the diagnostics bundle uploaded on failure.
- [ ] Measure the resource budget with Deephaven + SQL Server on the target runner.
- [ ] Decide whether ITs run against upstream Deephaven, our `deephaven-server` image, or both by test
      level (DL-26).
- [ ] Define the Kubernetes test tier: kind vs dev EKS namespace, its triggers, RBAC for namespace
      creation, TTL backstop (DL-32).
- [ ] Draw the job topology and the start → test → teardown sequence, including failure and cancel
      paths, in D10.

### 5.12 CD pipeline and release cycle (dev → qa → prod)

**Original ask:** "how to manage CI/CD release cycle in dev, qa, production"; "for CD pipeline, ..."
(left unfinished in v0.1 — this section completes it).

**Must answer**

- Environment model `<region>-<stage>` × flow × instance; GitHub Environments with protection rules
  (required reviewers for qa / prod, deployment branches limited to release tags).
- **Promotion flow**: build once → dev auto-deploy on `main` pre-release → qa on release tag (bump
  PR + approval) → prod on approved PR + change-ticket reference; same digest promoted across JFrog
  repos; no rebuild.
- Deploy mechanics on EKS (v0.4, consistent with §5.7): a merged bump in the config repo is
  reconciled by the GitOps controller into a rolling update of the instance Deployment; readiness
  probes gate traffic; `maxUnavailable` / `maxSurge` per instance; PodDisruptionBudgets; optional
  progressive delivery (Argo Rollouts) where an instance has replicas; post-sync hooks run the smoke
  test.
- **Deployment windows** per region and flow (trading hours), region ordering (e.g. jp before us);
  enforced in the cluster by Argo CD sync windows (or a Flux suspend schedule), not only in the
  pipeline.
- Rollback: revert the bump PR, same mechanism; target time-to-rollback; compatibility of any
  schema changes.
- **Hotfix flow**: branch from release tag → patch version → fast-tracked qa → prod.
- Release cadence and branching: trunk-based + tags (leaning) vs release branches; code freeze;
  release notes generated from Conventional Commits.
- Change management evidence the pipeline must produce (test reports, scan results, approvals,
  deployment record via GitHub Deployments API, notifications).
- Access control: who approves prod, bot permissions on the config repo, controller RBAC per cluster /
  namespace; no production cluster credentials in GitHub — the controller pulls.
- Environment parity: one chart / base per app, only overlays differ; config-lint renders every
  overlay and compares key sets.

Tasks

- [ ] Draw the dev → qa → prod flow and the prod-deploy sequence (incl. rollback) in D9.
- [ ] Decide the GitOps controller and promotion mechanics, consistently with DL-30.
- [ ] Define the EKS cluster topology per `<region>-<stage>` and controller placement (hub vs per
      cluster).
- [ ] Define deployment windows and the approval matrix per region / flow.
- [ ] Define rollback procedure and a rollback drill.
- [ ] Define the hotfix procedure.

### 5.13 Cross-cutting topics (not in v0.1 — proposed additions)

- **Observability**: structured JSON logs shipped by Fluent Bit (CloudWatch or the enterprise stack),
  Micrometer metrics scraped via Prometheus Operator `ServiceMonitor`s, liveness / readiness /
  startup probes on Kubernetes (`HEALTHCHECK` in compose test stacks), optional tracing;
  `env / flow / app / instance` labels on every log line and metric.
- **Resilience**: probes and Kubernetes restart policy (compose `unless-stopped` for test stacks),
  graceful shutdown (`SIGTERM`, Spring lifecycle timeout, `terminationGracePeriodSeconds`), resource
  requests / limits sized with the JVM percentage, PodDisruptionBudget, topology spread across AZs,
  replicas per instance (most connectors are single-consumer: `replicas: 1` with fast restart, or
  leader election), behaviour on config change.
- **Security and compliance**: non-root, read-only filesystem, pod security standards (restricted),
  NetworkPolicies towards on-prem sources, IRSA instead of static AWS keys, pulls from trusted
  registries only, scanning gates, dependency updates, secret scanning, SBOM, audit trail for deploys,
  least-privilege tokens (OIDC), CODEOWNERS.
- **Local developer experience**: run one app + its dependencies with the same compose template and
  a `local` env in the config tree; kind for chart / overlay work; documented in each subproject
  README.
- **Decision records**: one ADR per §6 row under `docs/adr/`.

Tasks

- [ ] Confirm which of these are in scope for the first design iteration.

---

## 6. Decision log

"Leaning" is a starting hypothesis for the design documents to validate, not a decision.

| ID | Decision | Options | Leaning (to validate) | Blocking for skeleton | Status |
|---|---|---|---|---|---|
| DL-01 | Repository model | monorepo with Gradle subprojects / git submodules / polyrepo | **One Gradle monorepo; no git submodules anywhere in the project.** Rationale in §5.1; a future split, if ever, is into polyrepos consuming published artifacts | yes | decided (v0.5) |
| DL-02 | Deployment platform | compose on VMs / Kubernetes | **Kubernetes on Amazon EKS** for production; compose for local dev and CI test stacks only | yes | decided (v0.4) |
| DL-03 | Versioning scope | lockstep / independent / hybrid | hybrid: connector family lockstep, `deephaven-server` independent | yes | open |
| DL-04 | Version computation | git-describe plugin / Conventional Commits + release PR / manual tag | Conventional Commits + release PR, tag-triggered release, pre-release on `main` | yes | open |
| DL-05 | Image tag scheme | see §5.4 table | semver + `sha-` tag; no floating tags beyond dev | yes | open |
| DL-06 | Config location | in monorepo / separate config repo | separate config repo | yes | open |
| DL-07 | Config layering mechanism | explicit `spring.config.import` list / profile chain | explicit import list, ≤ 4 file layers | yes | open |
| DL-08 | Env vars vs YAML | rule of thumb | env vars only for compose-shared / infra knobs | no | open |
| DL-09 | Image and config bump delivery | GitOps bot PR / deploy-time parameter | GitOps bot PR | yes | open |
| DL-10 | Config sync to target VMs | pull agent / push via SSH-Ansible / artifact | superseded by DL-30 (GitOps to clusters) after the v0.4 platform change | no | closed |
| DL-11 | Vault authentication | AppRole / TLS cert / Vault Agent / **Kubernetes auth** | Kubernetes auth on EKS, delivery per DL-31; AppRole only for local stacks; **not in the demo** | no (demo skips Vault) | open |
| DL-12 | DB credentials | static KV v2 / dynamic DB engine | static first, evaluate dynamic | no | open |
| DL-13 | Enterprise CA injection | company base image / per-Dockerfile ARG / runtime mount | company base image | yes | open |
| DL-14 | Image build tool | Dockerfile (buildx) / Jib | Dockerfile; jar built by Gradle outside Docker | yes | open |
| DL-15 | IT harness | Testcontainers / compose / both | Testcontainers for component ITs, compose stack for system ITs | no | open |
| DL-16 | Test-data distribution | second-repo checkout in CI / JFrog artifact (submodule excluded by DL-01) | JFrog versioned artifact | no | open |
| DL-17 | CI runners | GitHub-hosted / self-hosted (ARC on EKS) | **GitHub-hosted for the demo**; ARC on EKS when enterprise network reach is required | yes | decided for demo (v0.4) |
| DL-18 | Registry / JFrog auth from CI | static token / OIDC | OIDC | no | open |
| DL-19 | Docker vs Podman support | Docker first-class / both | both, parity tested in CI | no | open |
| DL-20 | Tag vs digest pinning in compose | tag / digest / both | tag in dev; digest + tag comment in qa / prod | no | open |
| DL-21 | Config promotion between envs | PR per env / directory copy | PR per env with CODEOWNERS | no | open |
| DL-22 | Gradle DSL | Kotlin / Groovy | Kotlin | no | open |
| DL-23 | Spring Boot baseline | 3.x / 4.x | latest GA supported on Java 21; upgrade policy documented | no | open |
| DL-24 | CI test execution model (§5.11) | job `container:` + `services:` / host job + Testcontainers / ephemeral compose stack / fully containerised compose build | ephemeral compose stack driven from Gradle, build job in the `ci-build` container | yes | open |
| DL-25 | Runner lifecycle | persistent self-hosted / ephemeral self-hosted (ARC or `--ephemeral`) / GitHub-hosted | GitHub-hosted (ephemeral by nature) for the demo; ephemeral ARC runners later | no | decided for demo (v0.4) |
| DL-26 | Deephaven image under test in CI | upstream `ghcr.io/deephaven/server` / our `deephaven-server` image / both by test level | upstream for component ITs, ours for system ITs | no | open |
| DL-27 | Teardown guarantee | `always()` compose down / run-id labels + prune / Ryuk / ephemeral runner | all of them layered, plus a leak-check step | yes | open |
| DL-28 | CI build environment | `setup-java` on the runner host / pinned `ci-build` container image | `ci-build` image maintained by `base-image.yml` | yes | open |
| DL-29 | Kubernetes packaging | Helm chart per app / Kustomize base + overlays / Helm chart + Kustomize overlays for config | Kustomize overlays generated from the same `application.yml` files the compose stacks use; Helm only where templating is needed | yes | open |
| DL-30 | GitOps controller | Argo CD / Flux / CI push (`kubectl`, `helm`) | Argo CD (ApplicationSets, sync windows); CI push for the kind demo only | no | open |
| DL-31 | Secrets delivery in Kubernetes | External Secrets Operator / Vault Agent Injector / Secrets Store CSI / Spring Cloud Vault in-process | ESO, app stays Vault-agnostic; demo uses plain `Secret` / env | no | open |
| DL-32 | Kubernetes test tier | none / kind in the job / ephemeral namespace on dev EKS / both | kind on PRs touching packaging, dev EKS namespace on `main` / nightly; kind slice in the demo | no | open (confirm demo slice) |
| DL-33 | AppInstance modelling on Kubernetes | one Application per instance / one release with N Deployments / StatefulSet | one Application per instance generated from the config tree, each owning one Deployment | yes | open |
| DL-34 | Registry for EKS | JFrog direct (`imagePullSecrets`) / ECR mirror replicated from JFrog | ECR mirror if pulls must be in-region; JFrog direct otherwise | no | open |

---

## 7. Acceptance criteria

**Design documents**

- [ ] Every question in Appendix A is answered explicitly; D0 carries the traceability table.
- [ ] Every recommendation lists at least one alternative with trade-offs.
- [ ] Every document contains the diagrams required in §3, each captioned and explained.
- [ ] Every convention is given as a table with concrete examples (names, paths, tags, commands).
- [ ] §6 updated with a recommendation and rationale per row; one ADR per row.
- [ ] D10 covers the three container layers, the job layout, the Deephaven CI profile and the
      layered teardown guarantee; its sequence diagram shows the failure and cancel paths.
- [ ] D11 shows the mapping from the config tree to Kubernetes objects with one worked instance, the
      GitOps sync flow, and the secrets delivery path.

**Demo skeleton**

- [ ] `./gradlew build` passes on a clean checkout with Java 21 through the JFrog proxy.
- [ ] Each app subproject has: Spring Boot hello world, Dockerfile with CA step, compose template,
      `run-compose.sh` implementing every §5.8 command, and config for `us-dev/cash/<AppName>` with
      `app-common` + two instances whose effective configuration provably differs.
- [ ] `connectors-framework` is consumed by all three source apps; `deephaven-server` skeleton starts.
- [ ] No Vault in the demo: `source-database` reads its DB password from an environment variable
      (compose) or a Kubernetes `Secret` (kind slice) bound to the property name the Vault integration
      will use; D2 documents the switch and it needs no code change.
- [ ] One end-to-end IT passes locally on Docker and Podman, and on a GitHub-hosted runner.
- [ ] If the kind slice is in scope: a CI job creates a kind cluster, deploys the `source-database`
      overlay for one instance, waits for readiness, runs a smoke test and deletes the cluster.
- [ ] PR, main and release workflows are green in this repo; images are pushed with the §5.4 tags.
- [ ] Pushing `v0.1.0` produces `0.1.0` image tags and a config-bump PR; no `version.txt` exists.
- [ ] Every subproject has a README; `docs/00-overview.md` indexes everything.

**Containerised CI execution (§5.11)**

- [ ] The PR workflow's `build` job runs inside the `ci-build` container image and passes unit tests.
- [ ] The `integration-test` job starts a Deephaven server container, waits for its readiness probe,
      runs at least one IT that writes and reads a table through the Deephaven client, and tears down.
- [ ] The leak-check step after teardown finds no containers, volumes or networks carrying this run's
      label — demonstrated on a passing run, a failing run and a cancelled run.
- [ ] Deephaven and dependency logs plus JUnit reports are uploaded as artifacts when the job fails.
- [ ] The same start → test → stop lifecycle runs locally with one Gradle command on Docker and Podman.
- [ ] The `integration-test` job finishes within the agreed time budget and fits the runner's memory.
- [ ] Every demo workflow runs on GitHub-hosted runners; no self-hosted runner is required.

---

## 8. Open questions and assumptions to confirm

Infrastructure and platform

- [x] "Git subprojects" = Gradle subprojects in one git repository; no git submodules (decided v0.5).
- [ ] EKS topology: one cluster per `<region>-<stage>`, or shared clusters with a namespace per
      stage? Are dev and qa on EKS too? Which AWS regions serve `us` and `jp`?
- [ ] Is a GitOps controller (Argo CD / Flux) already provided on the EKS platform, and who runs it?
- [ ] Network path from EKS to on-prem AMPS, Kafka and SQL Server (Direct Connect / VPN, latency
      budget, security groups / NetworkPolicies)? Are any sources also moving to AWS?
- [ ] Image pulls on EKS: JFrog reachable from the nodes, or an ECR mirror required? Node
      architecture (amd64 only, or Graviton arm64)?
- [ ] Pod security standards, IRSA, service mesh or ingress requirements imposed by the platform team?
- [ ] Can CI create ephemeral namespaces on a dev EKS cluster (GitHub OIDC → IAM role → EKS RBAC)?
- [ ] GitHub Enterprise Cloud or Server? Self-hosted runners available? Egress policy (Docker Hub
      blocked → JFrog remotes)?
- [ ] JFrog: Artifactory edition, Xray, OIDC support, existing repository naming conventions,
      promotion API allowed?
- [ ] Vault: edition, namespaces, enabled auth methods, Database secrets engine allowed for SQL Server?
- [ ] Is there an existing company base image and a CA bundle distribution / rotation process?
- [ ] Regional isolation: separate JFrog / Vault / runners per region (us, jp)? Data residency rules?
- [ ] CI runners: the demo uses GitHub-hosted runners (decided). For the enterprise pipeline: is ARC
      on EKS the self-hosted option, and can those runners reach JFrog, `ghcr.io` (or its JFrog
      remote) and the dev cluster?
- [ ] Which container layers are mandatory in CI: dependencies only, or the build / test process too?
      (The runner-in-a-container layer is out of the demo.)
- [ ] Is mounting the container socket into a job container acceptable to security (root-equivalent
      on the runner), or must nested access go through a rootless Podman socket?

Product and domain

- [ ] AMPS licence terms for CI / test images; Deephaven Community vs Enterprise; Hazelcast role.
- [ ] Which components publish to AMPS / Deephaven — part of `source-database`, or shared sinks in
      `connectors-framework`?
- [ ] Do other repositories consume `connectors-framework` (needs Maven publishing to JFrog)?
- [ ] Number of instances and hosts per env; are instances pinned to hosts? (sizes the sync / CD
      design)
- [ ] What identifies an AppInstance (numeric, upstream name, target name)?
- [ ] Deephaven version and auth mode for CI tests (anonymous handler vs pre-shared key)? Must our
      `deephaven-server` image be under test on every PR, or only on `main` / nightly?

Process

- [ ] Change-management constraints for prod (CAB, evidence required, deployment windows per
      region / flow).
- [ ] Ownership: config repo, base images, Vault policies, runners, test-data repo.
- [ ] Timezone policy (`TZ` per region for the app; UTC in logs?).
- [ ] Compliance: audit retention, image signing, SBOM required?
- [ ] Stand-ins for the demo: GHCR instead of JFrog (confirm); Vault skipped (decided); kind for the
      Kubernetes slice (confirm).

---

## 9. Glossary

| Term | Meaning in this brief |
|---|---|
| env | `<region>-<stage>` deployment environment, e.g. `us-dev`, `jp-prod` |
| business flow | product line the instance serves: `cash`, `deriv`, `swap` |
| AppName | a deployable Gradle subproject / Docker image, e.g. `source-kafka` |
| AppInstance | one running copy of an AppName with its own config (same image) |
| app-common | config shared by all instances of one AppName in one env + flow |
| lockstep versioning | every subproject carries the same version and is released together |
| promotion | moving the same immutable image (digest) between registry repos / environments without rebuilding |
| GitOps bump | a bot PR that changes `IMAGE_TAG` in the config repo; merge = deploy intent |
| secret zero | the first credential that lets a workload authenticate to Vault |
| AppRole | Vault auth method using `role_id` + `secret_id` |
| digest | content hash of an image (`sha256:...`); immutable, unlike a tag |
| layered jar | Spring Boot jar split into layers (deps, snapshots, app) for cache-friendly images |
| ADR | Architecture Decision Record, one per decision in §6 |
| IT | integration test (needs containers) |
| Xray | JFrog vulnerability scanner |
| job container | the container a GitHub Actions job runs in (`container:` key) |
| service container | a dependency container GitHub starts next to a job and removes afterwards (`services:` key) |
| ci-build image | pinned image with JDK 21, the enterprise CA and the CLIs, used to run builds and tests in CI and locally |
| Ryuk | Testcontainers' reaper sidecar that removes containers when the test JVM exits |
| ephemeral runner | a self-hosted runner that serves exactly one job and is then destroyed |
| ARC | Actions Runner Controller, the Kubernetes operator for self-hosted runners |
| DinD | Docker-in-Docker: a container engine running inside a container |
| leak check | a post-teardown step that fails if resources labelled with the run id still exist |
| EKS | Amazon Elastic Kubernetes Service, the production platform |
| Helm / Kustomize | Kubernetes packaging: templated charts with values, or plain manifests with base + overlays |
| overlay | a Kustomize directory that patches a base for one env / flow / instance |
| GitOps controller | Argo CD or Flux: reconciles the config repo into the cluster and reports drift |
| ApplicationSet | Argo CD object that generates one Application per directory, cluster or list entry |
| sync window | Argo CD schedule that allows or denies syncs, used for deployment windows |
| ESO | External Secrets Operator: copies secrets from Vault into Kubernetes `Secret`s |
| IRSA | IAM Roles for Service Accounts: AWS identity for a pod without static keys |
| kind | Kubernetes in Docker: a throw-away cluster inside a CI job or on a laptop |

---

## 10. Change log of this brief

| Version | Date | Change |
|---|---|---|
| v0.1 | — | Original question list (brain-dump). |
| v0.2 | 2026-09-26 | Restructured into a brief: context, two deliverables with scope, per-topic "must answer / options / tasks", decision log, acceptance criteria, open questions, glossary, traceability. Added missing pieces: `qa` environment, extra config layers, AppInstance naming, `run-compose.sh` command table, completed CD section, cross-cutting topics (observability, resilience, security, local dev). Fixed typos and naming inconsistencies. |
| v0.3 | 2026-09-26 | Added the containerised CI execution requirement: build, unit and integration tests on GitHub runners inside containers, Deephaven server container alive during ITs, guaranteed teardown. New §5.11 (CD and cross-cutting renumbered to §5.12 / §5.13), new design doc D10 with diagram requirements, constraint row in §2.2, skeleton scope in §4, decision rows DL-24 to DL-28, acceptance criteria, open questions, glossary terms. |
| v0.4 | 2026-09-26 | Platform correction: production is Kubernetes on Amazon EKS; compose is for local dev and CI test stacks only. Re-scoped §5.5 (tags in manifests), §5.7 (GitOps delivery replaces VM sync), §5.8 (test stacks only), §5.12 (rolling updates via controller, sync windows), §5.13 (Kubernetes runtime). Added Kubernetes mapping of the config tree, `k8s/` per app, design doc D11, decisions DL-29 to DL-34, EKS open questions and glossary. Answered v0.4 questions: Kubernetes as CI test substrate (§5.11), monorepo vs submodules (§5.1). Demo decisions: GitHub-hosted runners, no Vault (DL-02, DL-11, DL-17, DL-25 updated). |
| v0.5 | 2026-09-26 | Decided: one Gradle monorepo, git submodules not used anywhere in the project (code, config, test data). DL-01 closed, DL-16 options narrowed, §2.2 rule added, §2.3 / §5.1 / §5.10 wording updated, §8 question resolved. |

---

## Appendix A — Traceability from v0.1 questions

| v0.1 ask | Covered in |
|---|---|
| Design plan in `.md` files + demo project with hello-world skeleton | §1, §3, §4 |
| Subproject list (`deephaven-server`, `deephaven-connectors` with `source-kafka`, `source-amps`, `source-database`, `connectors-framework`) | §2.3 |
| Per-subproject directory structure (docker, scripts, src, config) | §2.4 |
| `run-compose.sh <env> <flow> <AppName> <AppInstance> <cmd>` | §5.8 |
| Config tree `<env>/<flow>/<AppName>/{app-common, <AppInstance>}` with `compose.env`, `application.yml` | §2.4, §5.6 |
| Gradle build, Java 21 | §5.1 |
| Vault for secrets; Spring Vault for database password | §5.2 |
| Enterprise CA certificate in Docker images | §5.3 |
| CI/CD release cycle in dev, qa, production | §5.12 |
| Image tagging / versioning strategy; same version for all subprojects? | §5.4 |
| No `version.txt`; hybrid semver automation + git-tag trigger; tag naming conventions; cleanup of old non-prod images | §5.4 |
| Image tag in docker-compose; should CI/CD auto-change it? | §5.5 |
| Separate config into its own repo? | §5.7 |
| Auto-sync config to target machines across env / flow / AppName / AppInstance | §5.7 |
| Git directory structure for Spring Boot configs | §5.6 |
| Where common `application.yml` and override `application.yml` go | §5.6 |
| Environment variables to parameterise `application.yml`; instance endpoints (hosts / ports) via env vars or override YAML | §5.6 |
| GitHub workflow: push → build, unit tests, integration tests, images, publish to JFrog | §5.9 |
| Docker / Podman to spin up Hazelcast, AMPS, Deephaven for integration tests | §5.10 |
| SSH to a test input / expected-output repo to fetch data and run tests | §5.10 |
| Spin up SQL Server for JDBC tests, query, publish to AMPS or Deephaven | §5.10 |
| "for CD pipeline," (unfinished) | §5.12 |
| Flow, structural and sequence diagrams in every `.md` | §3 |
| *(v0.3)* GitHub runner builds, unit-tests and integration-tests within containers, with a Deephaven server running, spun down after the tests | §2.2, §4, §5.11, §6 (DL-24 to DL-28), §7 |
| *(v0.4)* Production is Kubernetes on EKS; compose only for testing | §2.1, §2.2, §2.4, §5.5–§5.8, §5.12, §5.13, DL-02, DL-29 to DL-34 |
| *(v0.4)* Can the GitHub tests run in Kubernetes? | §5.11, DL-32 |
| *(v0.4)* Gradle monorepo or git submodules? *(v0.5: decided — monorepo, no submodules)* | §2.2, §2.3, §5.1, DL-01 |
| *(v0.4)* Demo: GitHub-hosted runners, skip Vault | §2.2, §4, §5.2, §5.9, §5.11, §7, DL-11, DL-17, DL-25 |
