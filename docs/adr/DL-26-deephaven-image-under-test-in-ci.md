# DL-26 — Deephaven image under test in CI

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

Integration tests need a Deephaven server. It can be the upstream `ghcr.io/deephaven/server` image
(through a JFrog remote), our own `deephaven-server` image with the enterprise CA and plugins built
earlier in the same workflow, or both depending on the test level. Whether our image must be under test
on every PR is a §8 question.

## Decision

Proposed: upstream image for component ITs (fast, pinned by digest); our `deephaven-server` image for
system ITs on `main` and nightly, built in the same run so the image under test is the one deployed.

## Alternatives considered

- Upstream only: simplest, but our packaging is never exercised before dev.
- Ours only: full coverage, but every PR pays for the server image build.

## Consequences

- The Deephaven CI profile (version pin, heap, auth mode, readiness probe, timeout) is shared by both
  images (D10).
- `needs:` ordering ensures the `deephaven-server` image built in `build` is what `system-test` runs.

## References

- TODO.md §5.3, §5.11, §8, §6 (DL-26)
- D10 (`docs/10-containerised-ci-execution.md`), D8 (`docs/08-integration-testing.md`)
