# DL-31 — Secrets delivery in Kubernetes

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

With Vault Kubernetes auth (DL-11) the remaining question is how a secret reaches the container:
External Secrets Operator copying Vault data into Kubernetes `Secret`s, the Vault Agent Injector
rendering files via a sidecar or init container, the Secrets Store CSI driver with the Vault provider, or
Spring Cloud Vault in-process. The demo uses a plain `Secret` bound to the final property names.

## Decision

Proposed: External Secrets Operator — the app stays Vault-agnostic and consumes ordinary `Secret`s as
env or files; the demo's plain `Secret` is therefore already the final shape.

## Alternatives considered

- Vault Agent Injector: no operator, but a sidecar per pod and file-based consumption.
- Secrets Store CSI driver: no `Secret` objects at rest, but a CSI driver dependency and file mounts.
- Spring Cloud Vault in-process: no cluster components, but every app holds Vault client logic and
  token renewal.

## Consequences

- One `ExternalSecret` per release mapping `secret/<env>/<flow>/<app>/<instance>/...` to a `Secret`
  (D2, D11).
- Rotation appears as a `Secret` update; a restart or Reloader picks it up (D5).
- Static KV first (DL-12); dynamic leases would favour the in-process option and reopen this decision.

## References

- TODO.md §5.2, §4, §6 (DL-31)
- D2 (`docs/02-secrets-and-vault.md`), D11 (`docs/11-kubernetes-packaging-and-gitops.md`)
