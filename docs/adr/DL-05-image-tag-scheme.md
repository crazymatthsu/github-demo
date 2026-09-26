# DL-05 — Image tag scheme

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

§5.4 proposes a tag table: `pr-123-<sha7>` for PR builds, a sortable unique pre-release tag for `main`
pushes, `1.4.2` plus `sha-<sha7>` for release tags, and mutable convenience tags (`1.4`, `1`, `main`,
`latest`) for dev and local only. One image tag must map to one git commit, and the same digest is
promoted between registry repositories rather than rebuilt.

## Decision

Proposed: semantic version tags plus an immutable `sha-<sha7>` tag on every published image; the
`main` pre-release form to be fixed in D4 (`1.5.0-rc.<n>` or `1.5.0-SNAPSHOT.<yyyymmdd>.<sha7>`);
no floating tags beyond dev; qa and prod never reference a mutable tag.

## Alternatives considered

- Floating tags everywhere (`latest`, `main`): convenient, but not reproducible and unusable as a
  deployment record.
- Digest-only references: immutable, but unreadable in reviews; digest pinning is handled in DL-20.

## Consequences

- OCI labels carry version, revision, source and build URL so `run-compose.sh version` can show them.
- Retention rules key off the tag class: `pr-*` deleted after PR close, last N pre-releases kept,
  release tags kept for ever, in-use tags protected (D4).
- `compose.env` and `values.yaml` in qa and prod carry release tags (and digests per DL-20).

## References

- TODO.md §5.4, §5.5, §6 (DL-05)
- D4 (`docs/04-versioning-and-image-tagging.md`)
