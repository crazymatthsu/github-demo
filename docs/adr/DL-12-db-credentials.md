# DL-12 — DB credentials

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

`source-database` connects to SQL Server via JDBC with a password retrieved through Spring Vault. Vault
can serve static KV v2 secrets or dynamic, leased credentials from the Database secrets engine; dynamic
credentials affect long-running connectors through lease renewal and HikariCP pool refresh, and SQL
Server support must be confirmed (§8).

## Decision

Proposed: static KV v2 credentials first, at `secret/<env>/<flow>/<app>/<instance>/...` mirroring the
config hierarchy; evaluate the Database secrets engine once lease renewal and pool refresh are proven.

## Alternatives considered

- Dynamic Database secrets engine from day one: rotation for free, but lease handling in every connector
  and an unconfirmed SQL Server engine in this Vault edition.

## Consequences

- Rotation of static credentials is a documented procedure with a restart per instance (D2).
- The property names used by the demo stub are the ones the Vault integration binds to later.
- Vault policies follow the `env/flow/app/instance` path with least privilege (D2).

## References

- TODO.md §5.2, §6 (DL-12)
- D2 (`docs/02-secrets-and-vault.md`)
