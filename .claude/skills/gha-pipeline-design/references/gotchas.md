# Pipeline gotchas: symptom → cause → fix

Read this when a pipeline misbehaves, and before handing a new pipeline over. Every item happened in the
reference pipeline or was designed around there. Items owned by a companion skill point to it.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Every push to a PR branch starts two runs of `pr.yml` | The push and the `pull_request` event both match | Expected. Per-PR concurrency group for PR runs; name the gates `push-gate` / `pr-gate` |
| 2 | A tag push starts nothing | The workflow's `on.push` has only branch filters; or the tag points at a `[skip ci]` commit; or `GITHUB_TOKEN` created the tag | Add a `tags:` filter; tag the tested commit, not the bot commit after it; dispatch the release workflow from the bot |
| 3 | A bot's pull request shows no checks, and the required check waits forever | Events caused by `GITHUB_TOKEN` start no workflow | Close and reopen it by hand, or use a GitHub App token for the bot |
| 4 | Required check "Expected — waiting for status" forever | The workflow has path filters, or branch protection requires a matrix or reusable-workflow job name that no longer exists | No path filters on the gate's workflow; require only the gate |
| 5 | The gate is green although a job failed | The gate lacks `if: always()`, misses a job in `needs`, or ignores `cancelled` | `if: always()`, every job in `needs`, fail on `failure` and `cancelled`, and on a failed detector |
| 6 | A deploy stopped halfway through | `cancel-in-progress: true` on main | main queues, never cancels |
| 7 | Bot commits start pipelines that write back again | No loop guard | `[skip ci]` in the bot commit, skip jobs when the actor is the bot, separate concurrency group (skill gha-config-deploy) |
| 8 | `release-please failed: GitHub Actions is not permitted to create or approve pull requests` | Repository setting | Settings → Actions → General → allow Actions to create and approve PRs (skill gha-versioning-release) |
| 9 | 403 on image push, retag or delete | The package does not grant this repository Actions access, or the job lacks `packages: write` | Package settings → Manage Actions access; `permissions: packages: write` on that job |
| 10 | Fork PRs fail on the image push | Read-only token on forks | Push only for same-repository PRs and the merge queue; skip the jobs that need pushed images |
| 11 | `needs.build.outputs.images` is empty and `fromJSON` fails | The producing job was skipped | Default reusable outputs (`${{ jobs.x.outputs.y \|\| '{}' }}`) and guard consumers with `!= '{}'` |
| 12 | A value set in the caller's `env:` is empty inside a reusable workflow | `env` does not cross `workflow_call` | Pass it as an input |
| 13 | A composite action step fails with "Required property is missing: shell" | Every `run:` step in a composite action needs `shell:` | Add `shell: bash` |
| 14 | A job in a `container:` fails at once with `[[: not found` | Job containers default to `sh` | `defaults.run.shell: bash` on the job (skill gha-build-images) |
| 15 | The version is `0.1.0` everywhere, or wrong after a checkout | Shallow clone: no tags, no history | `fetch-depth: 0` where a version is computed (skill gha-versioning-release) |
| 16 | A script test passes on the PR and fails a day later on an unrelated PR | The test reads files a bot keeps writing (deployed tags, recorded placements) | Build test fixtures from a copy with the bot-managed fields reset; never assert on mutable state |
| 17 | The nightly run silently stopped | Public repository without activity for 60 days | Keep activity or re-enable; alert on missing scheduled runs |
| 18 | A diagram shows as an error box on GitHub | Mermaid syntax GitHub's renderer rejects | Validate with `scripts/render-mermaid.cjs` before pushing (references/documenting-pipelines.md) |
| 19 | Actions run with more rights than they need | Top-level `permissions` missing, so the repository default applies | `permissions: contents: read` at the top of every workflow, elevate per job |
| 20 | A reused third-party action changed behaviour overnight | Floating ref (`@main`) | Pin to a major version, or to a commit SHA where policy requires it |
