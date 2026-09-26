# DL-13 — Enterprise CA injection

| | |
|---|---|
| Status | Accepted (v1.0, 2026-09-26) |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

Every image must trust the enterprise CA in both the OS trust store and the JVM truststore; the CA is
also needed by Gradle in CI, `curl` health checks, the Vault client and AMPS / Kafka TLS. Renewing the
CA must trigger a rebuild of every image. Whether a company base image already exists is a §8 question.

## Decision

Decided (v1.0, as recommended): a company base JRE image built once by a `base-image.yml` workflow (CA in both stores,
timezone data, non-root user) that every app image uses as its `FROM`; the CA bundle is fetched from a
JFrog generic artefact at base-image build time.

## Alternatives considered

- Per-Dockerfile `ARG` with the bundle: no shared image to maintain, but the CA step is duplicated in
  every Dockerfile and rotation means touching each one.
- Runtime volume mount of the bundle: no rebuild on rotation, but the JVM truststore must be assembled
  at start-up and the mount must exist on every platform.

## Consequences

- CA rotation = rebuild the base image, then rebuild the app images (a `base-image` change triggers
  `main.yml`) (D3).
- The `ci-build` image (DL-28) derives from the same base so Gradle trusts JFrog.
- `run-compose.sh` only offers an optional truststore override mount for rotation tests (D6).

## References

- TODO.md §5.3, §8, §6 (DL-13)
- D3 (`docs/03-docker-images.md`)
