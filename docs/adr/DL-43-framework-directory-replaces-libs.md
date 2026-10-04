# DL-43 — `framework/` replaces `libs/` in the project repository layout

| | |
|---|---|
| Status | Accepted (v1.7, 2026-10-04); amends DL-42 §2 (layout) and §4 (what the manifest derives) |
| Date | 2026-10-04 |
| Blocking for demo skeleton | no — the demo monorepo keeps `deephaven-connectors/connectors-framework/` (D12 §8) |
| Demo | `github-cicd-simple-apps`: `framework/connectors-framework/` (Gradle `:connectors-framework`), ADR R-0003 there |

## Context

DL-42 named the directory of a project repository's shared, non-deployable code `libs/`, beside `apps/`. In
this platform that code is the connector framework the apps are built on — identity, the `connector.*`
property contract, health, the test fixtures — not a bag of utilities. `libs` is also what Gradle and Maven
call build outputs and dependency jars (`build/libs/`, the version catalog `libs.versions.toml`, `libs.`
accessors), which made the top-level directory read as a build artefact to people new to the layout.

## Decision

The top-level directory of a project repository's shared code is **`framework/`**, in contrast to `apps/`:
`framework/<name>/` is a Gradle project discovered by `settings.gradle.kts` like an app, built and published
(never deployed, never an image), and a change under it builds everything (`shared` in the affected map).
Everything else in DL-42 stands; `platform.yml` derives the libraries from `framework/*`.

## Alternatives considered

- Keep `libs/`: conventional in polyglot monorepos, but ambiguous next to `build/libs/` and the version
  catalog named `libs`.
- `shared/` or `common/`: say nothing about what the code is; the apps share a framework.
- One `framework` Gradle project at the repository root instead of a directory: a second shared module could
  not join it later, and it would sit beside the build files instead of beside `apps/`.

## Consequences

- D12 §6.2, §6.6, §6.11 and Figure 1 revised (D12 v1.1); the demo monorepo is not affected (D12 §8).
- `github-cicd-simple-apps` moved `libs/connectors-framework/` to `framework/connectors-framework/`; its
  `settings.gradle.kts`, `.github/affected-map.yml`, CODEOWNERS, `platform.yml` and docs follow (ADR R-0003
  there). The Gradle path `:connectors-framework` and the apps' dependencies are unchanged.
- The `gha-affected-builds` skill keeps its generic `libs/common` example: it illustrates the mechanism of the
  map, not this layout.

## References

- TODO.md §6 (DL-43), §10 (v1.7)
- D12 (`docs/12-repository-layout-and-pipeline-contract.md`) §6.2, §6.6, §6.11; DL-42
