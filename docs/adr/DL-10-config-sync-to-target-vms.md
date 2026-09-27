# DL-10 — Config sync to target VMs

| | |
|---|---|
| Status | Closed — superseded by DL-30 (GitOps controller to clusters) |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

The v0.1 ask was to auto-synchronise configuration to target machines across environments, business
flows, AppNames and AppInstances, with candidate mechanisms being a pull agent on each host, a push over
SSH or Ansible, or a distributed artefact. v0.4 changed the production platform to Kubernetes on EKS.

## Decision

Closed. With production on Kubernetes (DL-02), "sync to machines" becomes reconciliation of the config
repository into clusters by a GitOps controller; DL-30 owns that decision. Compose stacks for local
development and CI read the checked-out config tree directly and need no synchronisation. The dev
compose hosts of demo step 1 are driven by the `deploy-dev` job (DL-35), not by a sync agent.

> **Update 2026-09-27 (v1.3):** DL-39 reopens this question for the on-prem compose boxes only: the
> `deploy-dev` job syncs a per-flow host bundle to every box of a `targets.yml` pool over the DL-35 SSH
> channel. Clusters stay with DL-30.

## Alternatives considered

- Pull agent on each host: no inbound access needed, but no reconciliation status and one more
  daemon to run.
- Push via SSH / Ansible: familiar, but credentials in CI and no drift detection.
- Distributed artefact per env: versioned, but still needs a delivery and restart mechanism.

## Consequences

- No host-level sync tooling is designed or built.
- The `deploy-dev` compose adapter is a transitional mechanism for demo step 1 only (D9).

## References

- TODO.md §5.7, §6 (DL-10, DL-30)
- D9 (`docs/09-cd-and-release-management.md`), D11 (`docs/11-kubernetes-packaging-and-gitops.md`)
