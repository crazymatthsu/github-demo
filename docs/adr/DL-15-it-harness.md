# DL-15 — IT harness

| | |
|---|---|
| Status | Accepted for the demo (v0.6); Proposed for later test levels |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

Integration tests need Deephaven, SQL Server, Kafka, AMPS and Hazelcast containers. Candidate harnesses
are Testcontainers per test class, a docker compose stack per suite, or both; Podman compatibility and
the runner topology influence the choice.

## Decision

Demo: docker compose stacks only, started and stopped by the workflow (or by the Gradle compose
lifecycle so `./gradlew integrationTest` behaves the same locally); no Testcontainers. Proposed for
later: Testcontainers for single-dependency component ITs, compose stacks for system ITs that include
our images.

## Alternatives considered

- Testcontainers everywhere: closest to test code and random ports, but Ryuk needs socket access,
  Podman quirks, and whole stacks with our images are awkward.
- Compose everywhere: identical locally and in CI, but per-class isolation is coarser.

## Consequences

- Tests reach services by compose service name; no published host ports in CI (D8, D10).
- The teardown guarantee is owned by the workflow and `run-compose.sh` labels (DL-27).
- Adding Testcontainers later does not change the system-IT path.

## References

- TODO.md §4, §5.10, §5.11, §6 (DL-15)
- D8 (`docs/08-integration-testing.md`), D10 (`docs/10-containerised-ci-execution.md`)
