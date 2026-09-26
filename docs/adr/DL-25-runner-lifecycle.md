# DL-25 — Runner lifecycle

| | |
|---|---|
| Status | Accepted for the demo (v0.4); Proposed for later phases |
| Date | 2026-09-26 |
| Blocking for demo skeleton | no |

## Context

The teardown guarantee (§5.11) relies on a backstop: a runner that serves exactly one job and is then
destroyed cannot leak containers into the next job. Persistent self-hosted runners accumulate state;
ephemeral self-hosted runners (ARC, or `--ephemeral`) and GitHub-hosted runners do not.

## Decision

Demo: GitHub-hosted runners, ephemeral by nature. Proposed for later: ephemeral ARC runners on EKS, one
runner pod per job, when self-hosted capacity or network reach is needed.

## Alternatives considered

- Persistent self-hosted runners: cheaper per job, but leaked containers, caches and credentials survive
  between jobs.

## Consequences

- The leak-check step (DL-27) is still required: ephemerality is the last layer, not the first.
- ARC in `dind` mode is the target so compose keeps working (D10).

## References

- TODO.md §5.9, §5.11, §6 (DL-25)
- D10 (`docs/10-containerised-ci-execution.md`)
