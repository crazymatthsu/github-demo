# DL-11 — Vault authentication

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no (demo skips Vault) |
| Phase | deferred to Phase 3 (brief v1.1) — not needed for the demo skeleton |

## Context

All secrets come from HashiCorp Vault. The "secret zero" problem asks how the first credential reaches a
workload without living in git or an image. On Kubernetes the pod's service-account token can prove
identity; local and test stacks need a different path. The demo stubs secrets as environment variables
or a Kubernetes `Secret` behind the final Spring property names.

## Decision

Proposed: Vault Kubernetes auth on EKS — the service-account token authenticates the pod, so there is
no secret zero to deliver — with delivery per DL-31; AppRole (or a dev-mode token) only for local and
test compose stacks. Not built in the demo.

## Alternatives considered

- AppRole everywhere: needs `role_id` / `secret_id` delivery to every pod, recreating secret zero.
- TLS certificate auth: strong, but certificate issuance and rotation per workload.
- Vault Agent as the auth client: valid as a delivery option (DL-31), not a separate auth method.

## Consequences

- One Vault role per app or instance bound to the release's ServiceAccount and namespace (D2).
- Moving the demo to Vault is a property-source change (`spring.config.import=vault://...`), not a
  code change.
- Local Vault bootstrap is designed for the iteration after the demo.

## References

- TODO.md §5.2, §4, §6 (DL-11)
- D2 (`docs/02-secrets-and-vault.md`)
