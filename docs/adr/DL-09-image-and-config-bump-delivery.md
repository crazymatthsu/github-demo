# DL-09 — Image and config bump delivery

| | |
|---|---|
| Status | Accepted for dev (v0.7); Proposed for qa / prod |
| Date | 2026-09-26 |
| Blocking for demo skeleton | yes |

## Context

Git must be the deployment record, so the image tag of every instance lives in `values.yaml` and
`compose.env`. §5.5 asks who changes it: a GitOps bot PR, a deploy-time parameter recorded elsewhere,
an operator edit, or an image updater writing back to git. v0.7 decided the dev path.

## Decision

Dev: merge to `main` deploys via the `deploy-dev` job, which then writes the deployed tag back into the
instance `values.yaml` / `compose.env` with a loop guard (DL-36). Proposed for qa and prod: a bot PR
(GitHub App identity) against `config/<region>-qa/**` and `config/<region>-prod/**`, approved under
CODEOWNERS; merge is the deploy intent.

## Alternatives considered

- Deploy-time parameter: no PR, but state outside git and a weak audit trail.
- Manual operator edit via PR: baseline fallback, slow.
- Argo CD Image Updater / Flux image automation: automatic write-back, acceptable for dev only;
  contradicts the approval gate for prod.
- Bot identity PAT instead of GitHub App: simpler, but tied to a person and broader in scope.

## Consequences

- `release.yml` opens the qa bump PR; the promote job or ops opens the prod bump PR with a change-ticket
  reference (D9).
- The bot can write to `config/*-dev/**` and open PRs but never approve.
- Rollback is a revert of the bump commit in every environment.

## References

- TODO.md §5.5, §5.12, §4, §6 (DL-09)
- D4 (`docs/04-versioning-and-image-tagging.md`), D9 (`docs/09-cd-and-release-management.md`)
