# DL-19 — Docker vs Podman support

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

§2.2 requires that Docker and Podman both work for local development and CI test stacks. `run-compose.sh`
must detect `docker compose` versus `podman compose` / `podman-compose`, and rootless Podman brings
constraints on ports below 1024, the API socket for health checks and SELinux volume labels. The demo's
end-to-end IT must pass locally on both engines.

## Decision

Proposed: both engines first-class — `run-compose.sh` detects the engine, the compose template avoids
Docker-only features, and CI proves parity by re-running the compose integration test on Podman in a
nightly job.

## Alternatives considered

- Docker first-class, Podman unsupported: one engine to test, but excludes Podman-only developer
  desktops and violates §2.2.
- Both engines, Podman best-effort: cheap, but parity regressions go unnoticed until a developer hits
  them.

## Consequences

- The `local` template publishes only ports ≥ 1024; health checks use the published port, not the
  engine socket; mounts carry SELinux labels (D6).
- Test images must work rootless (SQL Server and Deephaven do; verify AMPS).
- A Podman install step on the GitHub-hosted runner is needed for the parity job (verify).

## References

- TODO.md §2.2, §5.8, §5.10, §6 (DL-19)
- D6 (`docs/06-runtime-operations.md`), D8 (`docs/08-integration-testing.md`)
