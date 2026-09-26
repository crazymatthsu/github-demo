# DL-27 — Teardown guarantee

| | |
|---|---|
| Status | Accepted (v1.0, 2026-09-26) |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

Everything a CI job starts must be gone after the run, whether it passed, failed or was cancelled. A
single mechanism can fail (a cancelled step, a crashed runner), so §5.11 proposes layering: an `always()`
compose down, run-id labels with a prune, Ryuk where Testcontainers is used, and ephemeral runners, plus
a leak-check step that proves nothing remains.

## Decision

Decided (v1.0, as recommended): all layers together — (1) an `if: always()` step running `compose down -v --remove-orphans`
for this run's project and pruning anything labelled `com.<company>.ci.run=<run_id>`; (2) every
container, volume and network labelled with the run id under a unique project name prefixed
`ci-<run_id>-<attempt>`; (3) ephemeral runners (and Ryuk where Testcontainers exists); followed by a
leak-check step that fails if labelled resources remain. `timeout-minutes` on every job.

## Alternatives considered

- `always()` down alone: covers the normal paths, but not a runner crash or a parallel job collision.
- Labels and prune alone: precise, but needs a step that runs — same gap.
- Ephemeral runner alone: hides leaks instead of proving their absence.

## Consequences

- `run-compose.sh` builds the run-scoped project name and labels when `GITHUB_RUN_ID` is set (D6).
- Diagnostics (`compose ps`, logs, JUnit) are collected before teardown (D10).
- The acceptance test demonstrates a clean leak check on passing, failing and cancelled runs.

## References

- TODO.md §5.11, §7, §6 (DL-27)
- D10 (`docs/10-containerised-ci-execution.md`), D6 (`docs/06-runtime-operations.md`)
