# DL-16 — Test-data distribution

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

Integration tests need input messages and expected outputs, originally proposed as a separate repository
fetched over SSH. Git submodules are excluded by DL-01. Datasets can be large and must be versioned
compatibly with app versions.

## Decision

Proposed: versioned datasets published to a JFrog generic repository and downloaded by version in CI and
locally; layout `testdata/<connector>/<case>/{input/, expected/, manifest.yml}`.

## Alternatives considered

- Second-repository checkout in CI with a deploy key or GitHub App token over HTTPS: simple diffs, but
  large binaries in git and credentials per repository.
- Git submodule: excluded by DL-01.

## Consequences

- A `testdata` Gradle task resolves the dataset version declared in the version catalog (D8).
- Datasets are immutable once published; a change is a new version.
- Golden-file comparison rules (canonical JSON, ordering, timestamp tolerance) are defined in D8.

## References

- TODO.md §5.1, §5.10, §6 (DL-16)
- D8 (`docs/08-integration-testing.md`)
