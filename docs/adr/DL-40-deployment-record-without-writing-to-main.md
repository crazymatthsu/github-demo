# DL-40 — Deployment record without writing to `main`

| | |
|---|---|
| Status | Accepted (v1.5, 2026-10-03); supersedes DL-36 and the dev path of DL-09 |
| Date | 2026-10-03 |
| Blocking for demo skeleton | yes — the v1.0 write-back cannot run under the company ruleset |
| Demo | `config/us-dev/**` declares `main`; `_deploy-dev.yml` records the Deployment and commits nothing; `deploy` block in `workflows-config.yml` (DL-41 schema) |

## Context

The company ruleset on `main` allows changes only through a pull request with at least one human
approval, with no bypass for workflows or GitHub Apps. The v1.0 design ends every dev deploy with a
commit pushed straight to `main` (`chore(config): us-dev deployed <tag> [skip ci]`, DL-09 dev path),
guarded against re-triggering the pipeline by DL-36. That push is now rejected.

The write-back did three jobs at once, and each needs a new home:

1. **record** — git showed what dev runs; `retention.sh` and the qa bump read the recorded tag;
2. **input for the next deploy** — the next bundle sync and the "restart the previous tag" rollback read
   the tree's `IMAGE_TAG`;
3. **placement pin** — the box `pool-deploy.sh` chose became `host` in `workflows-config.yml` (DL-39).

The platform owner also asked that dev not deploy on every merge by default: a flow opts in to
deploy-on-merge, to a nightly deploy at a fixed time, or deploys only by hand.

## Options considered

| Option | Assessment |
|---|---|
| A. Record PR after the deploy: the bot opens a pull request recording the tag; humans or auto-merge merge it | the record lags until someone merges; one "documentation" PR per deploy, or a rolling one; the tree disagrees with reality most of the time |
| B. **Record off `main`; the tree declares intent** — dev's files say `main`, the deploy pins the digest and records a GitHub Deployment; nothing is written to `main` | hands-free dev deploys under the ruleset; git keeps the intent, the Deployment the fact; `retention.sh` and `release.yml` need nothing from the dev tree |
| C. Bump PR before the deploy ("promote to dev"): the bot opens a PR with the new tag, merging it is the deploy — the qa / prod mechanism applied to dev | the shape Argo CD needs later, but with one human approval required every dev deploy is a click, and a rolling bump PR loses its approval on every new tag — on a busy day dev never catches up; approval fatigue on "bump to rc.57" |
| GitHub App in the ruleset's bypass list | the policy forbids exactly this |
| An orphan `deploy-records` branch written by Actions | compliant (not `main`), but redundant with the Deployments API; not adopted, available if auditors want `git log` |

## Decision

1. **No workflow writes to `main`.** `write-back-tag.sh`, `set-target-host.sh`, the `[skip ci]` marker,
   the bot-actor conditions and the bot concurrency group in `main.yml`, and `contents: write` on the deploy
   job are retired. DL-36 is superseded; the dev path of DL-09 is replaced by this decision. qa and prod
   are unchanged: they change through bump pull requests with human approval (DL-09, DL-21).
2. **The dev tree declares intent, not a literal version.** In `config/*-dev/**`, `compose.env` says
   `IMAGE_TAG=main` and `values.yaml` says `image.tag: main` with no digest: "dev runs the latest tested
   `main`". `main` is the convenience tag that `publish` re-asserts on the tested digest after the system
   test; config-lint check 10 already permits floating tags in `*-dev` and `local` (DL-20) and check 4 still
   holds. This is a one-time, human-approved pull request; after it no workflow has a reason to touch `main`.
3. **The deploy pins the literal version and records it.** On merge, the run's `<next>-rc.<n>` tag and
   digests; on a nightly or manual deploy, the version the `main` tag currently points to (its OCI `version`
   label names the rc). The tag travels as the `IMAGE_TAG` override and is written into the boxes' version
   directory (DL-41). The record is the GitHub Deployment of the env's Environment, one per run, with a
   payload per instance: tag, digest, box, version directory, the config tree's git SHA. The box's
   `.platform-bundle` manifest is the second copy; the job summary the human-readable one.
4. **Dev deploy policy per flow**, in `config/<env>/<flow>/workflows-config.yml` (dev envs only; schema in
   DL-41 and D5 §6.6):
   - `deploy.on-merge: [<project>...]` — the projects deployed on every tested `main` merge;
   - `deploy.schedule: {projects, at: "HH:MM", tz: <IANA zone>, days}` — the projects deployed at that time,
     only when the latest tested `main` differs from the flow's last successful Deployment;
   - the block is **required** for a dev flow (config-lint fails without it); a flow that lists no project
     under either key deploys only by hand. "Deploy on every merge" is therefore always a conscious choice.
   - Triggers: `push` to `main` (flows with `on-merge`, the run's version); an hourly tick workflow that
     matches each flow's `at` / `days` in its `tz` (GitHub cron lives in workflow files, so a per-flow time
     cannot be a GitHub schedule); `workflow_dispatch` with inputs **project, env, flow** (the latest tested
     `main`, now); a rollback dispatch with the same inputs (DL-41). All share the `deploy-<env>` concurrency
     group. A deploy is always complete — every instance of the project in the flow — never partial.
5. **Rollback.** Dev: the previous version directory (DL-41), old image and old config together. qa / prod:
   the unit of rollback is a *revision* of the env's tree, not a list of pull requests — a PR that restores
   `config/<env>/**` to the SHA of the last good Deployment (`git checkout <sha> -- config/<env>`), approved
   under the env's gates; a change to the shared platform layer `config/_common/` is rolled back for one env
   by pinning the old value in that env's own layer, never by reverting the shared file (which would roll
   dev and qa back too). Helm (`helm rollback`) and later `argocd app rollback` with auto-sync paused remain
   the minutes-fast path; the restore PR always follows.
6. **Retention.** `retention.sh` already never deletes a version carrying `main` and keeps the newest rc
   tags; it additionally protects the tags of the last successful Deployment of each dev env.

## Alternatives considered

See the options table. C stays documented as the mode to switch to if dev should ever be human-gated:
put literal tags back into the dev tree and point the qa bump job at dev; the deploy side does not change.

## Consequences

- "What runs in dev" is answered by the Deployment record (and `pool-deploy.sh status`), not by
  `git log config/us-dev`; for qa and prod git remains the record. D5 §6.8 and D9 §6.3 say so.
- A GitHub App is still needed for the qa / prod bump pull requests (a PR opened with `GITHUB_TOKEN` starts no
  checks, so it never becomes mergeable); without one, a human closes and reopens the bump PR to start them.
  Dev needs no App at all.
- The acceptance criterion "the write-back commit starts no second deploy" is replaced by "no workflow
  commits to `main`; the Deployment record names the deployed digest" (TODO.md §7).
- Laptops running `run-compose.sh us-dev …` from a checkout pull the moving `main` image, which is the
  intended meaning of the dev tree; D6 notes it.
- Revised here: D5 §6.6 / §6.8, D9, DL-09, DL-36, DL-39, DL-41. To revise with the implementation: D4
  §4.8 / §6.4 (who changes the tag), D6 §6.3 / §6.4, D7 (`main.yml` figure and loop-guard rows), D11 §7.3,
  the overview, `.github/workflows/README.md`, and the `gha-config-deploy` / `gha-pipeline-design` skills
  (which keep both modes: write-back where `main` accepts bot pushes, declared intent where it does not).
- `main.yml` still builds every push; a config-only merge may later skip the build and deploy the current
  `main` digest (an optimisation, not required by this decision).

## References

- TODO.md §5.12, §6 (DL-40), §7, §10 (v1.5)
- D5 (`docs/05-configuration-management.md`) §6.6, §6.8; D9 (`docs/09-cd-and-release-management.md`)
  §4.2, §6.3–§6.6, §6.9; D4 §6.2 (convenience tags); DL-09, DL-20, DL-21, DL-36, DL-39, DL-41
