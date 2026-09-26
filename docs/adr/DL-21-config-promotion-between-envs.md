# DL-21 — Config promotion between envs

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

A configuration change proven in dev must reach qa and prod. §5.7 asks whether promotion of config
follows the same PR flow as image bumps, and §5.12 requires environment parity with a key-set comparison.

## Decision

Proposed: one PR per target env, changing only `config/<env>/**`, approved under the CODEOWNERS rules of
that env; config-lint renders every env and fails the PR when key sets diverge.

## Alternatives considered

- Directory copy (`us-qa/` → `us-prod/` by script): fast, but overwrites env-specific values and
  bypasses review.

## Consequences

- Image bumps and config changes share one gate per env (D9).
- Env-specific values (endpoints, sizes) never travel; only keys and shared values do.
- Promotion tooling may pre-fill the PR, but a human approves it.

## References

- TODO.md §5.7, §5.12, §6 (DL-21)
- D5 (`docs/05-configuration-management.md`), D9 (`docs/09-cd-and-release-management.md`)
