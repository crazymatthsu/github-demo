# DL-04 — Version computation

| | |
|---|---|
| Status | Accepted (v1.0, 2026-09-26) |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

Git is the version source of truth; a `version.txt` is forbidden. The brief asks for a hybrid flow in
which `main` pushes get automatic pre-release versions and a release happens on a git tag created by
hand or by a release PR, with release notes generated. `project.version` must be derived at build time.

## Decision

Decided (v1.0, as recommended): Conventional Commits with a release PR tool (release-please leaning) that computes the next
semantic version, maintains the changelog and creates the tag; the tag triggers `release.yml`; every
`main` push produces a pre-release version derived from the last tag and the commit.

## Alternatives considered

- git-describe Gradle plugins (axion-release, palantir git-version, nebula, reckon): no commit
  convention needed, but no generated changelog or release PR.
- Manual tag only: simplest, but error-prone and no automatic pre-releases.

## Consequences

- Commit messages must follow Conventional Commits (enforced by a PR lint).
- Release notes are generated and attached to the GitHub Release and the prod bump PR (D9).
- The Gradle build reads the version from git (plugin or script), never from a file (D1, D4).
- The demo proves both paths: `main` push → pre-release tag; `v0.1.0` → `0.1.0` image tags.

## References

- TODO.md §5.4, §4, §6 (DL-04)
- D4 (`docs/04-versioning-and-image-tagging.md`)
