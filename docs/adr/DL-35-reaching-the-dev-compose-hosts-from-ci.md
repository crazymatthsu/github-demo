# DL-35 — Reaching the dev compose hosts from CI (demo step 1)

| | |
|---|---|
| Status | Accepted (v1.0, 2026-09-26) |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes (demo step 1) |
| Demo | placeholder (v1.1): `run-compose.sh --dry-run` on the runner plus a `TODO(DL-35)` comment; the SSH transport is implemented when dev hosts exist |

## Context

In demo step 1 the `deploy-dev` job must run `run-compose.sh <env> <flow> <app> <inst> pull`, `start`,
`health` on the dev compose hosts listed in `config/us-dev/cash/targets.yml`. GitHub-hosted runners may or
may not reach those hosts; a self-hosted runner on the host is the one exception §7 allows.

## Decision

Decided (v1.0, as recommended): SSH from the GitHub-hosted runner with a deploy key held in GitHub Environment `dev`, to a
`deploy` user whose forced command allows only `run-compose.sh`, if the host is reachable; otherwise a
self-hosted runner on the host. The host-side command is identical in both cases.

## Alternatives considered

- Self-hosted runner on the host: no inbound path needed, but a runner process per host to operate.
- Pull agent on the host: no credentials in GitHub, but no synchronous result and a second mechanism
  that the controller model makes redundant (DL-10, DL-30).

## Consequences

- Host key pinning and key rotation are part of the `dev` Environment's runbook (D9).
- The `run-compose.sh` audit line records the GitHub run URL and actor (D6).
- The mechanism stays for the bare-metal boxes after demo step 2: with host pools (DL-39, v1.3) the same
  SSH channel carries the per-flow bundle sync (`rsync --delete` into `/opt/platform`) before the three
  commands, and the forced command must allow `run-compose.sh` with `pull`, `start`, `stop`, `health` and
  `status --json`, plus the bundle sync (`rsync --server` into the root, for example through `rrsync`); the boxes
  hold the deploy key and the env's `known_hosts` and use the same user among themselves for the single-run rule.

## References

- TODO.md §4, §5.12, §7, §8, §6 (DL-35)
- D9 (`docs/09-cd-and-release-management.md`), D6 (`docs/06-runtime-operations.md`)
