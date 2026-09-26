# DL-02 — Deployment platform

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

The v0.1 questions assumed docker compose on target machines with config synchronised to hosts.
v0.4 corrected the platform: production runs on Kubernetes on Amazon EKS, and every runtime answer
(config delivery, secrets, CD, health, operations) must target Kubernetes. Cluster topology per
`<region>-<stage>` and whether dev and qa are on EKS remain §8 questions.

## Decision

Production runs on Kubernetes on Amazon EKS. Docker compose is used only for local development, CI
test stacks and the dev compose hosts of demo step 1; it is never a production artefact.

## Alternatives considered

- Compose on VMs with a config sync agent: simple, but no reconciliation, drift detection, rolling
  updates or platform-level RBAC; superseded together with DL-10.

## Consequences

- Packaging is a Helm chart per app (DL-29); one release per AppInstance (DL-33).
- Delivery becomes GitOps reconciliation into clusters (DL-30); `run-compose.sh` refuses every env
  other than `local`, the CI env and `*-dev` (D6).
- Secrets use Vault Kubernetes auth (DL-11, DL-31); image pulls need a JFrog or ECR path (DL-34).
- The demo adds a kind-based step to prove the chart before EKS exists (DL-32).

## References

- TODO.md §2.1, §2.2, §5.5–§5.8, §5.12, §5.13, §6 (DL-02)
- D6 (`docs/06-runtime-operations.md`), D9 (`docs/09-cd-and-release-management.md`), D11 (`docs/11-kubernetes-packaging-and-gitops.md`)
