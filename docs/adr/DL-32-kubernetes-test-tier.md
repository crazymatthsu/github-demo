# DL-32 — Kubernetes test tier

| | |
|---|---|
| Status | Accepted for the demo (v0.7); Proposed for Phase 3 |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes (demo step 2) |

## Context

Compose cannot test the chart, probes or ConfigMap mapping. With production on EKS a deployment test is
required: kind inside the job (no cloud access, images loaded from the build), an ephemeral namespace on
a dev EKS cluster (`ci-<run_id>`, GitHub OIDC → IAM → EKS RBAC, TTL backstop), or both.

## Decision

Demo step 2: kind inside the workflow — create the cluster, load the images built in the run, `helm
lint` and `helm upgrade --install` one release per AppInstance, wait for readiness, run a smoke test,
delete the cluster; kind is also the `deploy-dev` target until a dev cluster exists. Proposed for Phase
3: an ephemeral namespace on dev EKS on `main` / nightly in addition.

## Alternatives considered

- None: cheapest, but the chart is first exercised in dev.
- Ephemeral EKS namespace only: real platform, but needs cloud access from CI and RBAC for namespace
  creation before the demo can run.

## Consequences

- Integration tests stay on compose; kind is for the Helm deploy test only (D10).
- The kind namespace carries the `restricted` Pod Security Standard labels so chart defaults are
  checked (D6).
- NetworkPolicies are rendered but not enforced by kind's default CNI (verify); EKS enforces them.

## References

- TODO.md §4, §5.11, §7, §6 (DL-32)
- D10 (`docs/10-containerised-ci-execution.md`), D11 (`docs/11-kubernetes-packaging-and-gitops.md`)
