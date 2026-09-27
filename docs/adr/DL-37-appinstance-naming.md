# DL-37 — AppInstance naming

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

The v0.1 tree used numeric instance suffixes and mixed-case names. An instance name must identify one
concrete pipeline across compose project names, Helm releases, labels, metrics and Deephaven table
prefixes, and must fit Kubernetes name limits. One code base serves many flows and many source / target
endpoints.

## Decision

Decided v0.8: `AppName` is the code base (Gradle subproject and image, e.g. `source-database`);
`AppInstance` is the business-logic name of one pipeline — usually the data source, optionally with its
target (`bbg-equity-ticks`, `trades-db-to-amps`), never a bare number. Lower-case kebab-case, DNS-label
safe, unique within `<env>/<flow>/<AppName>`; AppName ≤ 20 and AppInstance ≤ 32 characters so
`<AppName>-<AppInstance>` ≤ 53 (Helm release-name limit; budget corrected in brief v0.9). The identity tuple `<env>/<flow>/<AppName>/<AppInstance>` is propagated
to the compose project `<env>-<flow>-<app>-<instance>`, the Helm release `<app>-<instance>`, labels and
log fields, metrics tags and the Deephaven table-name prefix.

## Alternatives considered

- Numeric suffix (`instance-1`): short, but meaningless in logs, tickets and dashboards.
- Upstream system name only: readable, but ambiguous once a source feeds several targets.

## Consequences

- config-lint validates the regex, the length budget and uniqueness (D5).
- `run-compose.sh` and the chart derive every name from the tuple (D6, D11).
- The same AppInstance name may recur under another flow because the flow is part of the identity.

## References

- TODO.md §2.2, §2.4, §5.6, §9, §6 (DL-37)
- D5 (`docs/05-configuration-management.md`), D6 (`docs/06-runtime-operations.md`)
