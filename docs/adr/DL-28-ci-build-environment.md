# DL-28 — CI build environment

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

The build and test process itself should run in a container so a CI run and a local run are the same
environment (§5.11 layer 2). The alternatives are `setup-java` on the runner host or a pinned `ci-build`
image with JDK 21, the enterprise CA, the container CLI and the `jf` CLI, with Gradle via the wrapper.

## Decision

Proposed: a pinned `ci-build` container image, maintained by `base-image.yml` from the same company
base as the app images (DL-13), used as the `container:` of the `build` job and runnable locally.

## Alternatives considered

- `setup-java` on the runner host: less to maintain, but the environment differs from a laptop and the
  enterprise CA must be installed per job.

## Consequences

- Gradle home is a mounted volume or `actions/cache` inside the container (D10).
- The image is pinned by digest and rebuilt when the base image or the CA changes (D3).
- Compose is driven from inside the container through the runner's engine socket — acceptable on
  ephemeral runners only (§5.11 security).

## References

- TODO.md §5.11, §5.9, §6 (DL-28)
- D10 (`docs/10-containerised-ci-execution.md`), D3 (`docs/03-docker-images.md`)
