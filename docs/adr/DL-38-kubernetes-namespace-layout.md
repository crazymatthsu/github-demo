# DL-38 — Kubernetes namespace layout

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no (demo step 2) |
| Phase | deferred to Phase 3 (brief v1.1) — not needed for the demo skeleton |

## Context

Each `<region>-<stage>` cluster hosts one Helm release per AppInstance across the business flows `cash`,
`deriv` and `swap`. Namespaces set the scope for RBAC, NetworkPolicies, Pod Security Standards, resource
quotas and Argo CD projects; candidates are one namespace per flow, per `<flow>-<app>`, or one per env.

## Decision

Proposed: one namespace per business flow in each `<region>-<stage>` cluster (`cash`, `deriv`, `swap`),
with the release name `<app>-<instance>` unique inside it.

## Alternatives considered

- Namespace per `<flow>-<app>`: finer quotas, but many namespaces and cross-app policies become verbose.
- One namespace per env: simplest, but no per-flow RBAC, quota or policy boundary.

## Consequences

- Argo CD `AppProject`, sync windows and RBAC align with the flow (D9, D11).
- NetworkPolicies and PSS labels are applied per flow namespace (D6).
- `workflows-config.yml` carries a `namespace` field equal to the flow until the ApplicationSet derives it (D11).

## References

- TODO.md §5.6, §6 (DL-38)
- D11 (`docs/11-kubernetes-packaging-and-gitops.md`), D9 (`docs/09-cd-and-release-management.md`)
