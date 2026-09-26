# DL-14 — Image build tool

| | |
|---|---|
| Status | Accepted (v1.0, 2026-09-26) |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

The brief requested a Dockerfile standard (multi-stage, enterprise CA, non-root, `HEALTHCHECK`,
container-aware JVM flags, hadolint clean) and Podman build compatibility. Jib would build without a
daemon and reproducibly but gives less control over the OS layer and the CA step.

## Decision

Decided (v1.0, as recommended): Dockerfile built with buildx (and buildable with `podman build`); the Spring Boot jar is built
by Gradle outside Docker and copied into the image, using layered-jar extraction for cache-friendly
layers.

## Alternatives considered

- Jib: daemonless and reproducible, but no OS-level control for the CA and trust stores and not what
  was asked for.
- Multi-stage Gradle build inside Docker: one file builds everything, but Gradle cache plumbing and
  slow cold starts.

## Consequences

- A Gradle `docker-image` convention plugin wraps the build so `./gradlew buildImages` works locally
  and in CI (D1, D3).
- OCI labels are set at build time from the git-derived version (D4).
- hadolint runs in the PR workflow (D7).

## References

- TODO.md §5.1, §5.3, §6 (DL-14)
- D3 (`docs/03-docker-images.md`)
