# DL-03 — Versioning scope

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

The brief asks whether all subprojects are built with the same version. Criteria named in §5.4: how
often subprojects change independently, the stability of the `connectors-framework` API, and the
operations preference for "one platform version" in change tickets. `deephaven-server` is mostly
upstream packaging with a different cadence.

## Decision

Proposed: hybrid versioning — the connector family (`connectors-framework`, `source-kafka`,
`source-amps`, `source-database`) in lockstep under `v<major>.<minor>.<patch>` tags;
`deephaven-server` versioned independently under `deephaven-server/v*` tags.

## Alternatives considered

- Lockstep for everything: one platform version in tickets, but `deephaven-server` releases force
  connector version bumps without changes.
- Independent per subproject: precise, but N tags per release and a compatibility matrix to maintain
  while the framework API is unstable.

## Consequences

- Unchanged subprojects under lockstep are retagged from the existing digest, not rebuilt (§5.4).
- Release tags, bump PRs and GitHub Environment deployment-branch rules must accept both tag shapes
  (D4, D9).
- Change tickets reference one connector-family version plus, when relevant, one server version.

## References

- TODO.md §5.4, §6 (DL-03)
- D4 (`docs/04-versioning-and-image-tagging.md`)
