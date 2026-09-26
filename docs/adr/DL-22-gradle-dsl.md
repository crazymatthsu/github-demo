# DL-22 — Gradle DSL

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

The build uses Gradle multi-project with convention plugins in `build-logic/`, a version catalog and a
Java 21 toolchain. Gradle scripts can be written in the Kotlin DSL or the Groovy DSL; the choice affects
IDE support, type safety of convention plugins and readability for the team.

## Decision

Proposed: Kotlin DSL (`*.gradle.kts`) for all build scripts and convention plugins.

## Alternatives considered

- Groovy DSL: more examples online and terser, but weaker IDE assistance and no compile-time checking
  of convention plugins.

## Consequences

- `settings.gradle.kts`, `build.gradle.kts` and `build-logic/` plugins share one language (D1).
- Slightly slower first configuration; mitigated by the configuration cache.

## References

- TODO.md §2.3, §5.1, §6 (DL-22)
- D1 (`docs/01-repository-and-build.md`)
