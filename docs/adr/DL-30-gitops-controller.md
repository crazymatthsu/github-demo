# DL-30 — GitOps controller

| | |
|---|---|
| Status | Accepted for the demo (v0.7); Proposed for EKS |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no (Phase 3) |
| Phase | deferred to Phase 3 (brief v1.1) — not needed for the demo skeleton |

## Context

Configuration and image bumps merged to the config tree must become rolling updates in the clusters.
A controller in each cluster (or a hub) can reconcile the repository; alternatively CI pushes with
`helm upgrade`. Deployment windows per region and flow, drift detection, RBAC per env and audit are the
criteria; whether the platform already provides a controller is a §8 question.

## Decision

Demo: CI push — `helm upgrade --install` per AppInstance from the `deploy-dev` job (kind in the
workflow until a dev cluster exists). Proposed for EKS (Phase 3): Argo CD with ApplicationSets over the
config tree, sync windows for deployment windows, notifications and per-project RBAC, replacing CI push.

## Alternatives considered

- Flux (`GitRepository` + `HelmRelease`, image automation): lighter and without a UI, but windows only
  via a suspend schedule.
- CI push permanently: simplest, but prod cluster credentials in GitHub and no drift detection or
  self-heal.

## Consequences

- No production cluster credentials in GitHub; the controller pulls (D9).
- `targets.yml` retires on EKS in favour of an ApplicationSet (D11).
- DL-10 is superseded by this decision.

## References

- TODO.md §4, §5.7, §5.12, §6 (DL-30)
- D9 (`docs/09-cd-and-release-management.md`), D11 (`docs/11-kubernetes-packaging-and-gitops.md`)
