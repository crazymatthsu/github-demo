# DL-20 — Tag vs digest pinning in compose and manifests

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

A tag is readable in reviews but mutable in principle; `image@sha256:...` is immutable but unreadable.
The instance `values.yaml` (production) and `compose.env` (tests, dev hosts) carry the image reference,
and promotion moves the same digest between registry repositories.

## Decision

Proposed: tag only in dev (`image.tag`, `IMAGE_TAG`); in qa and prod the digest is pinned
(`image.digest`) with the tag kept alongside as the human-readable comment, and the promote job checks
that the digest matches the tag before promoting.

## Alternatives considered

- Tag everywhere: readable, but a retagged image could change what prod runs.
- Digest everywhere: immutable, but unreadable diffs and awkward for developers in dev.

## Consequences

- The chart supports both `image.tag` and `image.digest` (D11); compose templates use
  `${IMAGE_REF}` resolved by `run-compose.sh` (D6).
- Bump PRs for qa and prod are generated, not hand-written, so the digest is always correct (D9).
- Retention protects any digest referenced by an env's config (D4).

## References

- TODO.md §5.5, §5.4, §6 (DL-20)
- D4 (`docs/04-versioning-and-image-tagging.md`), D9 (`docs/09-cd-and-release-management.md`)
