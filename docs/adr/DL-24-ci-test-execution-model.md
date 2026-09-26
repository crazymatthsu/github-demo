# DL-24 — CI test execution model

| | |
|---|---|
| Status | Accepted for the demo (v0.6) |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

Build, unit tests and integration tests must run inside containers on GitHub runners with a Deephaven
server container alive during the ITs and everything torn down afterwards. §5.11 compares four models:
job `container:` + `services:`, host job + Testcontainers, an ephemeral compose stack, and a fully
containerised build in compose.

## Decision

Model C for the demo: an ephemeral docker compose stack per job (`compose up --wait`, tests, `compose
down -v` in an `always()` step) on GitHub-hosted runners, with the `build` job running in the `ci-build`
container image per DL-28. Deephaven is a compose service with a health condition.

## Alternatives considered

- A. Job `container:` + `services:`: least YAML and built-in teardown, but no compose stack and not
  reproducible locally.
- B. Host job + Testcontainers: closest to test code, but the build is not containerised and Ryuk needs
  socket access.
- D. Fully containerised build in compose: trivially reproducible, but Gradle cache plumbing and slow
  cold starts.

## Consequences

- Same path locally (`./gradlew integrationTest`) and in CI, on Docker and Podman (D8, D10).
- Teardown, labels and project names are owned by us (DL-27).
- Testcontainers may join later for component ITs (DL-15).

## References

- TODO.md §5.9, §5.11, §7, §6 (DL-24)
- D10 (`docs/10-containerised-ci-execution.md`)
