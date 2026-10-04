# DL-07 — Config layering mechanism

| | |
|---|---|
| Status | Accepted (v1.0, 2026-09-26); layer 3 amended by DL-44 (v1.8): the cluster layer `config/<env>/<flow>/_common/` replaces the env-wide layer |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

§5.6 proposes up to seven precedence layers from jar defaults through platform-wide, env-wide,
`app-common`, instance, environment variables and Vault. The mechanism can be an explicit
`spring.config.import` / `spring.config.additional-location` list of optional files mounted under
`/config/...`, or Spring profiles with `application-<profile>.yml`. The brief suggests at most four file
layers.

## Decision

Decided (v1.0, as recommended): an explicit import list of optional files (`optional:file:/config/common/application.yml`,
`optional:file:/config/instance/application.yml`, plus at most two `_common` layers if adopted), with
at most four file layers; profiles are not used for layering.

## Alternatives considered

- Profile chain (`spring.profiles.active=us-dev,cash,trades-db-to-amps`): built in, but the merged
  result is implicit, profile names collide with identity tokens, and profile-specific documents are
  easy to misplace.
- Spring config-tree for file-based secrets: complementary, only if Vault Agent renders files (DL-31).

## Consequences

- Deterministic and visible precedence; `run-compose.sh app-config` and config-lint can render it (D6).
- The chart mounts one ConfigMap per layer under `/config/<layer>/` and compose binds the same
  directories (D5, D11).
- Adding a `_common` layer is a mount and one import entry, not a code change.

## References

- TODO.md §2.4, §5.6, §6 (DL-07)
- D5 (`docs/05-configuration-management.md`), D6 (`docs/06-runtime-operations.md`)
