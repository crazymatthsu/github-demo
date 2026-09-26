# DL-01 — Repository model

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

The project comprises a parent subproject (`deephaven-connectors`) with a shared framework and three
connector apps, plus `deephaven-server` packaging. v0.4 asked whether these should be Gradle
subprojects in one repository or separate repositories pinned as git submodules. A change touching the
framework and a connector is the common case while the framework API is still moving.

## Decision

One Gradle monorepo with Gradle subprojects. Git submodules are not used anywhere in this project —
not for code, configuration or test data (decided v0.5). If a hard boundary is ever needed, the split
is into separate repositories consuming `connectors-framework` as a published, versioned artefact
from JFrog; `deephaven-server` is the only later candidate.

## Alternatives considered

- Git submodules (one repo per subproject, pinned SHAs): natural per-repo releases, but several PRs
  plus a pin-bump PR per cross-cutting change, detached HEADs and forgotten pin updates.
- Polyrepo consuming published artefacts: clean boundaries, but version drift and two PRs per feature;
  kept as the only acceptable future split.

## Consequences

- One version catalog and one BOM; one CI pipeline with affected-subproject detection (D1, D7).
- Test data comes from a JFrog artefact or a second-repo checkout in CI, never a submodule (DL-16).
- A separate config repository, if ever chosen, is consumed by the controller and CI checkouts, never
  embedded (DL-06).
- Access control is per path via CODEOWNERS rather than per repository.

## References

- TODO.md §2.2, §2.3, §5.1, §6 (DL-01)
- D1 (`docs/01-repository-and-build.md`)
