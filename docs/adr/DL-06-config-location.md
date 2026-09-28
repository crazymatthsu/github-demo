# DL-06 — Config location

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

§5.7 weighs a separate configuration repository (independent cadence, stricter access, clean deploy
audit, no bot PR noise in code history) against version skew between config keys and code, two PRs per
feature and discoverability. Git submodules are excluded by DL-01.

## Decision

Configuration lives in this monorepo under `config/<env>/<flow>/<AppName>/{app-common,<AppInstance>}`
for now (decided v0.7), guarded by CODEOWNERS on `config/**` with prod paths reviewed by ops,
path-filtered workflows (`config-lint` on config changes, no image rebuild for config-only changes) and
bot write-backs with a loop guard (DL-36). The layout is repo-agnostic so a later move is a history
split plus a deployer source change.

## Alternatives considered

- Separate config repository: independent cadence and access, but key/code skew and two PRs per
  feature; revisit when access control or change cadence demands it.
- One repository per env, or code repo with defaults and schema plus an env repo with values: kept
  for the record.

## Consequences

- `deploy-dev`, Argo CD and compose all read the same tree; `run-compose.sh` resolves `CONFIG_ROOT`
  to `<repo>/config` by default and accepts an override (D6).
- Bot write-back commits land in the code repository, so the loop guard is mandatory (DL-36).
- `config/<env>/<flow>/workflows-config.yml` (one per flow, v1.3) is the dev deploy inventory until an ApplicationSet replaces it (D11).

## References

- TODO.md §2.2, §2.4, §5.7, §6 (DL-06)
- D5 (`docs/05-configuration-management.md`), D11 (`docs/11-kubernetes-packaging-and-gitops.md`)
