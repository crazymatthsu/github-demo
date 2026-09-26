# TODO — Architecture Design Brief: Deephaven Platform & Connectors

> **Status:** DRAFT v0.2 (restructured and expanded from the v0.1 question list; see §10).
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

**Order of work**

1. Finalise this brief: answer the §8 questions that gate decisions.
2. Write the design documents (§3). Each document records a recommendation for its §6 rows.
3. Review; mark §6 rows `decided` (one ADR per decision, see §5.12).
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
  flows → deployment windows and regional isolation matter (§5.11).
- **Deployment target: VMs running Docker or Podman with `docker compose`, not Kubernetes.**
  This single assumption shapes most answers below (config sync, CD, health checks). If Kubernetes
  is a realistic option within 12–18 months, say so now — several recommendations change.

### 2.2 Technology constraints (given)

| Area | Constraint |
|---|---|
| Build | Gradle multi-project, Gradle wrapper pinned, all dependencies resolved through JFrog (no direct internet) |
| Language / runtime | Java 21 (LTS); Spring Boot 3.x or 4.x — baseline to decide (DL-23) |
| Secrets | HashiCorp Vault for **all** secrets; Spring Vault / Spring Cloud Vault for database credential retrieval |
| Trust | Enterprise CA certificate must be trusted inside every image (OS trust store **and** JVM truststore) |
| CI/CD | GitHub Actions; JFrog Artifactory as Docker registry + Maven/Gradle repository (+ Xray scanning if available) |
| Containers | Docker **and** Podman must work for local development and integration tests |
| Versioning | Derived from git (tags / commits); **never** stored in a `version.txt` |
| Environments | `dev` → `qa` → `prod`, per region (`us`, `jp`) |

### 2.3 Repository layout (monorepo with Gradle subprojects)

"Git subprojects" is read as **Gradle subprojects inside one git repository** (not git submodules) —
confirm in §8.

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
│   └── docker-compose.yml             # ONE template for all env/flow/instance; parameterised by compose.env
├── scripts/
│   └── run-compose.sh                 # <env> <business-flow> <AppName> <AppInstance> <cmd>   (spec in §5.8)
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
  The instance id will appear in container names, logs, metrics and possibly Deephaven table names.
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
| D5 | `docs/05-configuration-management.md` | §5.6 config hierarchy, layering & precedence, env vars vs YAML; §5.7 config repo, sync to targets |
| D6 | `docs/06-runtime-operations.md` | §5.8 `run-compose.sh` spec; §5.12 health, logging, restart policy, resource limits |
| D7 | `docs/07-ci-pipeline-github-actions.md` | §5.9 workflows, affected-subproject detection, caching, JFrog publish |
| D8 | `docs/08-integration-testing.md` | §5.10 docker/podman test infrastructure, test-data repository, golden-file comparison |
| D9 | `docs/09-cd-and-release-management.md` | §5.11 dev → qa → prod promotion, deploy to VMs, rollback, hotfix, release cycle |

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
| D5 | Config layering & precedence; config repo tree | Config change → PR → lint → merge → sync → restart | Sync agent / push deploy on a target VM |
| D6 | Container internals (mounts, ports, env, healthcheck) | `run-compose.sh` command dispatch | `run-compose.sh start` → resolve config → compose → container → health |
| D7 | Workflow topology (triggers → jobs → artifacts) | PR checks; main build; nightly | PR → checks → merge → main build → publish |
| D8 | Test-infra stack | Test levels (unit → component IT → system IT → smoke) | Start deps → seed → run connector → assert → teardown |
| D9 | Environment / approval matrix | dev → qa → prod promotion with gates; hotfix path | Prod deploy incl. rollback; gitGraph for release / hotfix branching |

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
- Vault: compose-based dev Vault + seed script; `source-database` retrieves a DB password through
  Spring Vault and runs a hello-world query against SQL Server.
- One end-to-end integration test (SQL Server → `source-database` → stub target, or Deephaven / AMPS
  if images are available) that passes locally on Docker **and** Podman, and in CI.
- GitHub workflows: PR, main, release (tag) — green in this repo; images pushed to a registry
  (JFrog, or GHCR as stand-in for the demo).
- Versioning: main push produces a pre-release tag; pushing `v0.1.0` produces `0.1.0` image tags;
  release workflow opens a PR bumping `IMAGE_TAG` in the dev config.

**Out of scope**

- Real connector logic, schemas, performance work.
- Production Vault / JFrog / runner set-up (documented, not provisioned).
- Kubernetes manifests.

Tasks

- [ ] Confirm the in/out list above before starting.
- [ ] Decide the stand-in registry and stand-in Vault for the demo (§8).

---

## 5. Topics

Each topic: **Original ask** (from v0.1) → **Must answer** → **Options to evaluate** → **Tasks**.

### 5.1 Repository and build (Gradle, Java 21)

**Original ask:** "use gradle build, java 21"; many subprojects under one repo, including a parent
subproject (`deephaven-connectors`) with children.

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
- Authentication and the "secret zero" problem on VMs: how the first credential reaches the
  container without living in git or an image.
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

- Auth: AppRole (role_id in config, secret_id delivered per host via the deploy / sync channel,
  response-wrapped) vs TLS certificate auth (machine cert) vs Vault Agent sidecar (auto-auth +
  template rendering to files, app stays Vault-agnostic) vs Spring Cloud Vault in-process (DL-11).
- DB credentials: static KV first, dynamic later (DL-12).

Tasks

- [ ] Confirm Vault edition, namespaces, enabled auth methods, DB secrets engine availability (§8).
- [ ] Decide auth method and secret-zero delivery.
- [ ] Decide static vs dynamic DB credentials.
- [ ] Define path and policy naming convention aligned with `env/flow/app/instance`.
- [ ] Define the local-dev Vault bootstrap for the demo.

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

### 5.5 Image tags in docker-compose

**Original ask:** how to manage the image tag version in docker-compose; should the CI/CD process
auto-change the image tag in docker-compose?

**Must answer**

- The compose file is a template: `image: ${IMAGE_REPO}/source-kafka:${IMAGE_TAG}`; the value lives
  in the instance `compose.env`, so each env / flow / instance can pin its own version.
- Who changes `IMAGE_TAG` and where the record lives: git must be the deployment record.
- Tag vs digest pinning (`image@sha256:...` is immutable but unreadable; store both?) (DL-20).
- Drift detection: `run-compose.sh status` shows desired tag vs running digest.
- Rollback = revert the bump commit.

**Options to evaluate**

- **GitOps bump**: release workflow opens a PR against the config repo ("bump source-kafka to 1.4.2
  in us-dev/*"); auto-merge for dev, reviewed for qa / prod; promotion is another PR.
- Deploy-time parameter: CD passes the tag at deploy and records it elsewhere (state outside git —
  weak audit).
- Manual edit by an operator (baseline, still via PR).
- Bot identity for the PRs: GitHub App token vs PAT (DL-09).

Tasks

- [ ] Decide GitOps bump vs deploy-time parameter.
- [ ] Decide tag vs digest pinning per environment (e.g. tag in dev, digest + tag comment in qa/prod).
- [ ] Define the bot identity and permissions for config-repo PRs.

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

### 5.7 Configuration repository and synchronisation to target machines

**Original ask:** should config be separated into its own repo; how to auto-sync config to target
machines across environments, business flows, AppNames and AppInstances.

**Must answer**

- **Separate repo — trade-offs.** Pros: independent change cadence (config change without
  rebuild), stricter access (prod paths behind CODEOWNERS / approvals), clean audit of what is
  deployed, bot bump PRs do not pollute code history. Cons: version skew between config keys and code
  (mitigate: additive keys, tolerate unknown keys, tag config with app versions), two PRs for a
  feature needing new config, discoverability.
- Alternatives: same monorepo `config/` with CODEOWNERS and path-restricted workflows; one repo per
  env (prod isolation, usually overkill); code repo holds `app-common` defaults + schema while the
  env repo holds env / instance values.
- **Inventory**: where "which instances run on which host" is recorded (e.g. `inventory.yml` per env
  in the config repo) — needed by sync and by CD.
- **Sync mechanisms** for compose on VMs:
  - Pull: agent / systemd timer on each VM does a sparse `git pull` limited to its env / flow /
    instances, validates, switches atomically (`releases/<sha>` + `current` symlink), optionally
    restarts affected instances.
  - Push: CD job over SSH (rsync / Ansible) from a runner with network reach, driven by the inventory.
  - Artifact: config packaged as a versioned tarball / OCI artifact in JFrog; target pulls by version
    (same promotion story as images).
  - Config server (Spring Cloud Config / Consul): adds a runtime dependency; probably not for compose
    on VMs.
- Criteria: allowed network direction (may runners SSH into prod?), audit, rollback, drift detection,
  whether a config change implies a restart and who triggers it, and reuse of this channel to deliver
  the Vault secret-zero (§5.2).
- Promotion of a config change dev → qa → prod: same PR flow as image bumps?

Tasks

- [ ] Decide monorepo vs separate config repo (DL-06).
- [ ] Decide pull vs push sync (DL-10) and define the inventory format.
- [ ] Define atomic switch, rollback and drift-report behaviour.
- [ ] Define restart semantics after a config change.

### 5.8 `run-compose.sh` specification

**Original ask:** `run-compose.sh <env> <business-flow> <AppName> <AppInstance> <cmd>` with
`start, stop, down, restart, config, printenv, health, ...`.

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

- Workflow set: `pr.yml` (build, unit tests, lint, config-lint, affected component ITs), `main.yml`
  (full build, ITs, images with pre-release tags → JFrog dev repo, dev config bump PR), `release.yml`
  (on `v*` or `<subproject>/v*` tag: build or retag, promote, GitHub Release + changelog, qa bump
  PR), `nightly.yml` (full IT matrix, dependency / security scans, image retention), `base-image.yml`,
  and `config-lint.yml` in the config repo.
- Structure: reusable workflows (`workflow_call`) per concern (gradle-build, docker-build-push,
  integration-test) + composite actions (setup Java / Gradle / JFrog credentials / CA); matrix over
  subprojects from a JSON list produced by a "detect affected" job.
- Runners: GitHub-hosted vs self-hosted (network reach to JFrog / Vault, CA pre-installed, Docker or
  Podman available, capacity for ITs) (DL-17).
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

- Harness: Testcontainers (JUnit 5) per test class vs a `docker compose` stack per suite
  (Testcontainers `ComposeContainer`); Podman compatibility (`DOCKER_HOST` to the Podman socket,
  Ryuk considerations); runner topology if the runner itself is a container (socket mount vs DinD).
- Dependency images and constraints: Kafka (Apache / Confluent / Redpanda), Hazelcast, SQL Server
  (`mcr.microsoft.com/mssql/server` — EULA acceptance, amd64 only, ~2 GB, slow start → health
  check), Deephaven (`ghcr.io/deephaven/server`), **AMPS** (no public image; internal image with
  licence — CI licensing must be confirmed; fallback: contract tests against a shared dev AMPS),
  Vault dev. All pulled through JFrog remotes.
- **Test data**: options — checkout of a second repo with a deploy key / GitHub App token (HTTPS
  preferred over raw SSH), git submodule pinned to a commit, or **versioned datasets published to a
  JFrog generic repo** and downloaded by version (reproducible, large-file friendly). Layout:
  `testdata/<connector>/<case>/{input/, expected/, manifest.yml}`; versioning compatible with app
  versions.
- Reference scenario (`source-database`): start SQL Server → apply schema + seed → start AMPS /
  Deephaven → start the **connector image** (not just classes) with an instance config → poll the
  target → compare with expected output (canonical JSON, ordering rules, timestamp tolerance) → tear
  down. Same shape for `source-kafka` (produce input) and `source-amps`.
- Test levels: unit (no containers) → component IT (one dependency, Testcontainers) → system IT
  (compose stack including our images; `main` / nightly) → post-deploy smoke test (§5.11).
- Speed and cost: container reuse, parallelism, image pre-pull, PR budget (~15–20 min).
- `test-infra/compose/` stacks reused for local development (`dev-up` task).

Tasks

- [ ] Confirm AMPS licensing and image availability for CI; Deephaven edition; Hazelcast role (§8).
- [ ] Choose the harness per test level (DL-15).
- [ ] Decide test-data distribution and versioning (DL-16).
- [ ] Define expected-output comparison rules.
- [ ] Define resource budget and which ITs run on PR vs main vs nightly.

### 5.11 CD pipeline and release cycle (dev → qa → prod)

**Original ask:** "how to manage CI/CD release cycle in dev, qa, production"; "for CD pipeline, ..."
(left unfinished in v0.1 — this section completes it).

**Must answer**

- Environment model `<region>-<stage>` × flow × instance; GitHub Environments with protection rules
  (required reviewers for qa / prod, deployment branches limited to release tags).
- **Promotion flow**: build once → dev auto-deploy on `main` pre-release → qa on release tag (bump
  PR + approval) → prod on approved PR + change-ticket reference; same digest promoted across JFrog
  repos; no rebuild.
- Deploy mechanics on VMs (consistent with §5.7): push (CD job over SSH / Ansible: pull image,
  `run-compose.sh start`, `health`, smoke test) or pull (sync agent sees the bump and restarts).
  Rolling per instance, stop-on-failure, pre / post hooks.
- **Deployment windows** per region and flow (trading hours), region ordering (e.g. jp before us).
- Rollback: revert the bump PR, same mechanism; target time-to-rollback; compatibility of any
  schema changes.
- **Hotfix flow**: branch from release tag → patch version → fast-tracked qa → prod.
- Release cadence and branching: trunk-based + tags (leaning) vs release branches; code freeze;
  release notes generated from Conventional Commits.
- Change management evidence the pipeline must produce (test reports, scan results, approvals,
  deployment record via GitHub Deployments API, notifications).
- Access control: who approves prod, bot permissions, CD credentials (SSH keys in Vault, short-lived).
- Environment parity: one compose template, only config differs; config-lint parity check.

Tasks

- [ ] Draw the dev → qa → prod flow and the prod-deploy sequence (incl. rollback) in D9.
- [ ] Decide push vs pull deploy, consistently with DL-10.
- [ ] Define deployment windows and the approval matrix per region / flow.
- [ ] Define rollback procedure and a rollback drill.
- [ ] Define the hotfix procedure.

### 5.12 Cross-cutting topics (not in v0.1 — proposed additions)

- **Observability**: structured JSON logs and shipping (which stack?), Micrometer metrics
  (Prometheus endpoint; scraping VMs), liveness / readiness used by `HEALTHCHECK` and
  `run-compose.sh health`, optional tracing; `env / flow / app / instance` labels on every log line
  and metric.
- **Resilience**: restart policy (`unless-stopped`), graceful shutdown (`SIGTERM`, Spring lifecycle
  timeout), memory limits + JVM percentage, `depends_on` with health conditions, behaviour on config
  change.
- **Security and compliance**: non-root, read-only filesystem, scanning gates, dependency updates,
  secret scanning, SBOM, audit trail for deploys and script runs, least-privilege tokens (OIDC),
  CODEOWNERS.
- **Local developer experience**: run one app + its dependencies with the same compose template and
  a `local` env in the config tree; Vault dev; documented in each subproject README.
- **Decision records**: one ADR per §6 row under `docs/adr/`.

Tasks

- [ ] Confirm which of these are in scope for the first design iteration.

---

## 6. Decision log

"Leaning" is a starting hypothesis for the design documents to validate, not a decision.

| ID | Decision | Options | Leaning (to validate) | Blocking for skeleton | Status |
|---|---|---|---|---|---|
| DL-01 | Repository model | monorepo with Gradle subprojects / git submodules / polyrepo | monorepo | yes | open |
| DL-02 | Deployment platform | compose on VMs / Kubernetes | compose on VMs (given) | yes | confirm |
| DL-03 | Versioning scope | lockstep / independent / hybrid | hybrid: connector family lockstep, `deephaven-server` independent | yes | open |
| DL-04 | Version computation | git-describe plugin / Conventional Commits + release PR / manual tag | Conventional Commits + release PR, tag-triggered release, pre-release on `main` | yes | open |
| DL-05 | Image tag scheme | see §5.4 table | semver + `sha-` tag; no floating tags beyond dev | yes | open |
| DL-06 | Config location | in monorepo / separate config repo | separate config repo | yes | open |
| DL-07 | Config layering mechanism | explicit `spring.config.import` list / profile chain | explicit import list, ≤ 4 file layers | yes | open |
| DL-08 | Env vars vs YAML | rule of thumb | env vars only for compose-shared / infra knobs | no | open |
| DL-09 | Image and config bump delivery | GitOps bot PR / deploy-time parameter | GitOps bot PR | yes | open |
| DL-10 | Config sync to targets | pull agent / push via SSH-Ansible / artifact | pull agent with sparse checkout; push if network policy forbids | no | open |
| DL-11 | Vault authentication | AppRole / TLS cert / Vault Agent | AppRole via Spring Cloud Vault; Vault Agent if rotation is required | yes | open |
| DL-12 | DB credentials | static KV v2 / dynamic DB engine | static first, evaluate dynamic | no | open |
| DL-13 | Enterprise CA injection | company base image / per-Dockerfile ARG / runtime mount | company base image | yes | open |
| DL-14 | Image build tool | Dockerfile (buildx) / Jib | Dockerfile; jar built by Gradle outside Docker | yes | open |
| DL-15 | IT harness | Testcontainers / compose / both | Testcontainers for component ITs, compose stack for system ITs | no | open |
| DL-16 | Test-data distribution | repo checkout / submodule / JFrog artifact | JFrog versioned artifact | no | open |
| DL-17 | CI runners | GitHub-hosted / self-hosted | self-hosted (enterprise network) | yes | confirm |
| DL-18 | Registry / JFrog auth from CI | static token / OIDC | OIDC | no | open |
| DL-19 | Docker vs Podman support | Docker first-class / both | both, parity tested in CI | no | open |
| DL-20 | Tag vs digest pinning in compose | tag / digest / both | tag in dev; digest + tag comment in qa / prod | no | open |
| DL-21 | Config promotion between envs | PR per env / directory copy | PR per env with CODEOWNERS | no | open |
| DL-22 | Gradle DSL | Kotlin / Groovy | Kotlin | no | open |
| DL-23 | Spring Boot baseline | 3.x / 4.x | latest GA supported on Java 21; upgrade policy documented | no | open |

---

## 7. Acceptance criteria

**Design documents**

- [ ] Every question in Appendix A is answered explicitly; D0 carries the traceability table.
- [ ] Every recommendation lists at least one alternative with trade-offs.
- [ ] Every document contains the diagrams required in §3, each captioned and explained.
- [ ] Every convention is given as a table with concrete examples (names, paths, tags, commands).
- [ ] §6 updated with a recommendation and rationale per row; one ADR per row.

**Demo skeleton**

- [ ] `./gradlew build` passes on a clean checkout with Java 21 through the JFrog proxy.
- [ ] Each app subproject has: Spring Boot hello world, Dockerfile with CA step, compose template,
      `run-compose.sh` implementing every §5.8 command, and config for `us-dev/cash/<AppName>` with
      `app-common` + two instances whose effective configuration provably differs.
- [ ] `connectors-framework` is consumed by all three source apps; `deephaven-server` skeleton starts.
- [ ] Dev Vault in compose; `source-database` reads a DB password via Spring Vault and connects to
      SQL Server.
- [ ] One end-to-end IT passes locally on Docker and Podman, and in CI.
- [ ] PR, main and release workflows are green in this repo; images are pushed with the §5.4 tags.
- [ ] Pushing `v0.1.0` produces `0.1.0` image tags and a config-bump PR; no `version.txt` exists.
- [ ] Every subproject has a README; `docs/00-overview.md` indexes everything.

---

## 8. Open questions and assumptions to confirm

Infrastructure and platform

- [ ] "Git subprojects" = Gradle subprojects in one git repository, not git submodules?
- [ ] Deployment target is VMs + compose, no Kubernetes? Docker or Podman in production (rootless?)?
      Host OS (RHEL?) — affects CA store commands and SELinux labels.
- [ ] GitHub Enterprise Cloud or Server? Self-hosted runners available? Egress policy (Docker Hub
      blocked → JFrog remotes)?
- [ ] JFrog: Artifactory edition, Xray, OIDC support, existing repository naming conventions,
      promotion API allowed?
- [ ] Vault: edition, namespaces, enabled auth methods, Database secrets engine allowed for SQL Server?
- [ ] Is there an existing company base image and a CA bundle distribution / rotation process?
- [ ] Regional isolation: separate JFrog / Vault / runners per region (us, jp)? Data residency rules?

Product and domain

- [ ] AMPS licence terms for CI / test images; Deephaven Community vs Enterprise; Hazelcast role.
- [ ] Which components publish to AMPS / Deephaven — part of `source-database`, or shared sinks in
      `connectors-framework`?
- [ ] Do other repositories consume `connectors-framework` (needs Maven publishing to JFrog)?
- [ ] Number of instances and hosts per env; are instances pinned to hosts? (sizes the sync / CD
      design)
- [ ] What identifies an AppInstance (numeric, upstream name, target name)?

Process

- [ ] Change-management constraints for prod (CAB, evidence required, deployment windows per
      region / flow).
- [ ] Ownership: config repo, base images, Vault policies, runners, test-data repo.
- [ ] Timezone policy (`TZ` per region for the app; UTC in logs?).
- [ ] Compliance: audit retention, image signing, SBOM required?
- [ ] Stand-ins for the demo (GHCR instead of JFrog? Vault dev server?) acceptable?

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

---

## 10. Change log of this brief

| Version | Date | Change |
|---|---|---|
| v0.1 | — | Original question list (brain-dump). |
| v0.2 | 2026-09-26 | Restructured into a brief: context, two deliverables with scope, per-topic "must answer / options / tasks", decision log, acceptance criteria, open questions, glossary, traceability. Added missing pieces: `qa` environment, extra config layers, AppInstance naming, `run-compose.sh` command table, completed CD section, cross-cutting topics (observability, resilience, security, local dev). Fixed typos and naming inconsistencies. |

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
| CI/CD release cycle in dev, qa, production | §5.11 |
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
| "for CD pipeline," (unfinished) | §5.11 |
| Flow, structural and sequence diagrams in every `.md` | §3 |
