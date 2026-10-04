# Architecture Decision Records

One ADR per row of the decision log (TODO.md §6). Status: **Accepted** = the brief marks the row
decided; **Proposed** = the row is open and the ADR records the leaning as the proposal; **Closed** = the
row is closed or superseded and the ADR names what supersedes it. Rows decided for the demo only carry
both markers. Conventions for writing and superseding ADRs: D6 (`docs/06-runtime-operations.md`) §6.13.

| ID | Title | Status | File |
|---|---|---|---|
| DL-01 | Repository model | Accepted | [DL-01-repository-model.md](DL-01-repository-model.md) |
| DL-02 | Deployment platform | Accepted | [DL-02-deployment-platform.md](DL-02-deployment-platform.md) |
| DL-03 | Versioning scope | Accepted (v1.0) | [DL-03-versioning-scope.md](DL-03-versioning-scope.md) |
| DL-04 | Version computation | Accepted (v1.0) | [DL-04-version-computation.md](DL-04-version-computation.md) |
| DL-05 | Image tag scheme | Accepted (v1.0) | [DL-05-image-tag-scheme.md](DL-05-image-tag-scheme.md) |
| DL-06 | Config location | Accepted | [DL-06-config-location.md](DL-06-config-location.md) |
| DL-07 | Config layering mechanism | Accepted (v1.0) | [DL-07-config-layering-mechanism.md](DL-07-config-layering-mechanism.md) |
| DL-08 | Env vars vs YAML | Proposed | [DL-08-env-vars-vs-yaml.md](DL-08-env-vars-vs-yaml.md) |
| DL-09 | Image and config bump delivery | Accepted (qa / prod v1.0); dev path superseded by DL-40 (v1.5) | [DL-09-image-and-config-bump-delivery.md](DL-09-image-and-config-bump-delivery.md) |
| DL-10 | Config sync to target VMs | Closed for clusters (DL-39 covers the bare-metal pools) (superseded by DL-30) | [DL-10-config-sync-to-target-vms.md](DL-10-config-sync-to-target-vms.md) |
| DL-11 | Vault authentication | Proposed — deferred to Phase 3 | [DL-11-vault-authentication.md](DL-11-vault-authentication.md) |
| DL-12 | DB credentials | Proposed — deferred to Phase 3 | [DL-12-db-credentials.md](DL-12-db-credentials.md) |
| DL-13 | Enterprise CA injection | Accepted (v1.0) | [DL-13-enterprise-ca-injection.md](DL-13-enterprise-ca-injection.md) |
| DL-14 | Image build tool | Accepted (v1.0) | [DL-14-image-build-tool.md](DL-14-image-build-tool.md) |
| DL-15 | IT harness | Accepted for the demo; Proposed for later | [DL-15-it-harness.md](DL-15-it-harness.md) |
| DL-16 | Test-data distribution | Proposed | [DL-16-test-data-distribution.md](DL-16-test-data-distribution.md) |
| DL-17 | CI runners | Accepted for the demo; Proposed for the enterprise pipeline | [DL-17-ci-runners.md](DL-17-ci-runners.md) |
| DL-18 | Registry / JFrog auth from CI | Proposed | [DL-18-registry-jfrog-auth-from-ci.md](DL-18-registry-jfrog-auth-from-ci.md) |
| DL-19 | Docker vs Podman support | Proposed | [DL-19-docker-vs-podman-support.md](DL-19-docker-vs-podman-support.md) |
| DL-20 | Tag vs digest pinning in compose and manifests | Proposed | [DL-20-tag-vs-digest-pinning-in-compose.md](DL-20-tag-vs-digest-pinning-in-compose.md) |
| DL-21 | Config promotion between envs | Proposed | [DL-21-config-promotion-between-envs.md](DL-21-config-promotion-between-envs.md) |
| DL-22 | Gradle DSL | Proposed | [DL-22-gradle-dsl.md](DL-22-gradle-dsl.md) |
| DL-23 | Spring Boot baseline | Accepted | [DL-23-spring-boot-baseline.md](DL-23-spring-boot-baseline.md) |
| DL-24 | CI test execution model | Accepted for the demo | [DL-24-ci-test-execution-model.md](DL-24-ci-test-execution-model.md) |
| DL-25 | Runner lifecycle | Accepted for the demo; Proposed for later | [DL-25-runner-lifecycle.md](DL-25-runner-lifecycle.md) |
| DL-26 | Deephaven image under test in CI | Proposed | [DL-26-deephaven-image-under-test-in-ci.md](DL-26-deephaven-image-under-test-in-ci.md) |
| DL-27 | Teardown guarantee | Accepted (v1.0) | [DL-27-teardown-guarantee.md](DL-27-teardown-guarantee.md) |
| DL-28 | CI build environment | Accepted (v1.0) | [DL-28-ci-build-environment.md](DL-28-ci-build-environment.md) |
| DL-29 | Kubernetes packaging | Accepted | [DL-29-kubernetes-packaging.md](DL-29-kubernetes-packaging.md) |
| DL-30 | GitOps controller | Accepted for the demo; EKS part deferred to Phase 3 | [DL-30-gitops-controller.md](DL-30-gitops-controller.md) |
| DL-31 | Secrets delivery in Kubernetes | Proposed — deferred to Phase 3 | [DL-31-secrets-delivery-in-kubernetes.md](DL-31-secrets-delivery-in-kubernetes.md) |
| DL-32 | Kubernetes test tier | Accepted for the demo; Proposed for Phase 3 | [DL-32-kubernetes-test-tier.md](DL-32-kubernetes-test-tier.md) |
| DL-33 | AppInstance modelling on Kubernetes | Accepted | [DL-33-appinstance-modelling-on-kubernetes.md](DL-33-appinstance-modelling-on-kubernetes.md) |
| DL-34 | Registry for EKS | Proposed — deferred to Phase 3 | [DL-34-registry-for-eks.md](DL-34-registry-for-eks.md) |
| DL-35 | Reaching the dev compose hosts from CI (demo step 1) | Accepted (v1.0); demo placeholder with TODO | [DL-35-reaching-the-dev-compose-hosts-from-ci.md](DL-35-reaching-the-dev-compose-hosts-from-ci.md) |
| DL-36 | Loop guard for bot write-backs in the same repo | Superseded by DL-40 (v1.5) | [DL-36-loop-guard-for-bot-write-backs.md](DL-36-loop-guard-for-bot-write-backs.md) |
| DL-37 | AppInstance naming | Accepted | [DL-37-appinstance-naming.md](DL-37-appinstance-naming.md) |
| DL-38 | Kubernetes namespace layout | Proposed — deferred to Phase 3 | [DL-38-kubernetes-namespace-layout.md](DL-38-kubernetes-namespace-layout.md) |
| DL-39 | Host pools per env/flow for the bare-metal compose targets | Accepted (v1.3); decisions 2–3 superseded by DL-41 (v1.5) | [DL-39-host-pools-per-env-flow.md](DL-39-host-pools-per-env-flow.md) |
| DL-40 | Deployment record without writing to `main` | Accepted (v1.5) | [DL-40-deployment-record-without-writing-to-main.md](DL-40-deployment-record-without-writing-to-main.md) |
| DL-41 | Versioned per-project bundles on dedicated boxes (host pools v2) | Accepted (v1.5) | [DL-41-versioned-bundles-on-dedicated-boxes.md](DL-41-versioned-bundles-on-dedicated-boxes.md) |
| DL-42 | Repository layout and pipeline contract across repositories | Accepted (v1.6); §2 / §4 amended by DL-43 (v1.7) | [DL-42-repository-layout-and-pipeline-contract.md](DL-42-repository-layout-and-pipeline-contract.md) |
| DL-43 | `framework/` replaces `libs/` in the project repository layout | Accepted (v1.7) | [DL-43-framework-directory-replaces-libs.md](DL-43-framework-directory-replaces-libs.md) |
