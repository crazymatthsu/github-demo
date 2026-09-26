# DL-36 — Loop guard for bot write-backs in the same repo

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

The `deploy-dev` job writes the deployed tag back into the instance `values.yaml` / `compose.env` and
commits to `main`. Because config lives in the same repository (DL-06), that commit would trigger the
`main` workflow and another deploy. A guard must stop the loop while a config-only merge by a human
still deploys.

## Decision

Proposed: two guards together — the `deploy-dev` job's `if:` skips runs whose actor is the bot
identity, and the write-back commit message carries `[skip ci]` so GitHub skips the workflow entirely.
`paths-ignore` on `config/**` is rejected.

## Alternatives considered

- Skip bot author only: exact, but depends on a stable bot identity and still spends a run on
  `config-lint`.
- `[skip ci]` only: cheap, but a human copying the marker skips CI by accident.
- `paths-ignore: config/**`: trivial, but breaks the requirement that human config-only merges deploy.

## Consequences

- The bot identity is a GitHub App (DL-09) whose actor name is known to the workflow (D9).
- The acceptance test observes that the write-back commit starts no second deploy.
- Human commits must not contain `[skip ci]`; a PR lint warns.

## References

- TODO.md §5.7, §5.12, §7, §6 (DL-36)
- D9 (`docs/09-cd-and-release-management.md`)
