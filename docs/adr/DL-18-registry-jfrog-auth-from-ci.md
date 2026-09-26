# DL-18 — Registry / JFrog auth from CI

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

Workflows must publish images and Gradle artefacts to JFrog Artifactory, promote digests between
repositories and run Xray scans. Static tokens stored as GitHub secrets are long-lived and shared; OIDC
lets a workflow exchange its identity token for a short-lived Artifactory token, if the Artifactory
edition supports it (§8).

## Decision

Proposed: OIDC from GitHub Actions to Artifactory for every registry and repository operation, scoped
per workflow and environment; static tokens only as a documented fallback.

## Alternatives considered

- Static Artifactory token in GitHub secrets: works everywhere, but long-lived, shared and rotated by
  hand.

## Consequences

- Promotion jobs under GitHub Environments `<region>-qa` / `<region>-prod` get their own OIDC subject
  claims and Artifactory permissions (D9).
- `jf` CLI build-info and scans authenticate the same way (D7).
- The demo uses `GITHUB_TOKEN` against GHCR as the stand-in.

## References

- TODO.md §5.9, §8, §6 (DL-18)
- D7 (`docs/07-ci-pipeline-github-actions.md`)
