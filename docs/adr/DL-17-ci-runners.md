# DL-17 — CI runners

| | |
|---|---|
| Status | Accepted for the demo (v0.4); Proposed for the enterprise pipeline |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

Builds, unit tests and integration tests run inside containers on GitHub runners. GitHub-hosted runners
have Docker and compose preinstalled but no reach into the enterprise network; self-hosted runners via
Actions Runner Controller on EKS would have network reach to JFrog and Vault, the CA preinstalled and
capacity for ITs.

## Decision

Demo: GitHub-hosted runners (`ubuntu-latest`) for every workflow; the one allowed exception is a
self-hosted runner on a dev compose host (DL-35). Proposed for the enterprise pipeline: Actions Runner
Controller on EKS when network reach to JFrog, Vault or the dev cluster is required.

## Alternatives considered

- Self-hosted persistent VMs: network reach, but state leaks between jobs and patching burden.
- ARC on EKS from the start: right target, but out of the demo's scope (§4).

## Consequences

- Demo images are pushed to GHCR and test images pulled from public registries; the enterprise
  pipeline mirrors everything through JFrog remotes (D7, D10).
- The resource budget (Deephaven heap + SQL Server + Gradle) must fit the GitHub-hosted runner class.
- ARC `dind` mode keeps compose working unchanged later; `kubernetes` mode would not.

## References

- TODO.md §2.2, §5.9, §5.11, §7, §6 (DL-17)
- D7 (`docs/07-ci-pipeline-github-actions.md`), D10 (`docs/10-containerised-ci-execution.md`)
