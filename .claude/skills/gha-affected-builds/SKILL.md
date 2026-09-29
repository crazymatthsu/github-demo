---
name: gha-affected-builds
description: >-
  Monorepo change detection for GitHub Actions: build and test only what a pull request touches. A
  checked-in path map (docs, config, shared, per-project globs), a portable affected.py classifier and
  a composite action turn changed files into the projects to build, an integration-test matrix and
  flags such as deploy-test; unmapped paths build everything, docs-only and config-only changes take
  fast paths while the required gate still reports, and the merge queue or a ci:full label force full
  runs. Use it when monorepo CI is slow, when asked to "only build what changed", add path filters, a
  dynamic matrix from changed files, skip builds for docs, replace dorny/paths-filter or
  tj-actions/changed-files, or when a required check hangs on a docs-only PR.
---

# Affected builds for monorepos (GitHub Actions)

## What this skill gives you

A proven way to build and test only what a change touches in a monorepo, without ever silently
skipping a test: a path map checked into the repository, a stdlib Python classifier
(`scripts/affected.py`) wrapped in a composite action, and the wiring that turns its outputs into
build commands, an integration-test (IT) matrix, flags and a gate that always reports.

## Principles

1. **Detection is a small map plus a script you own.** The map (`.github/affected-map.yml`) lists
   globs per section; the script classifies `git diff` output against it in seconds, the same way on
   a laptop. Why: the decision stays reviewable in one file and explainable per path. Hidden logic in
   a third-party "changed files" action is also a supply-chain risk (tj-actions/changed-files was
   compromised in March 2025 and leaked CI secrets into logs). Switch to build-tool graphs (Nx,
   Turborepo, Bazel, the Gradle project graph) only when dozens of projects have deep dependencies.
2. **Unmapped means everything.** A path no section matches is handled like a shared input: every
   project builds. Why: a new directory, a renamed project or a forgotten entry then costs minutes of
   CI, never a skipped test. The map lists exceptions to "build everything", not the other way round.
3. **One class per path, first match wins, in a fixed order.**

   | Order | Section | A matching path means |
   |---|---|---|
   | 1 | `docs` | nothing to build; only docs paths changed means docs-only |
   | 2 | `config` | config lint only, no build, no image |
   | 3 | `shared` | every project (full run) |
   | 4 | `paths` | the projects listed by the first matching rule |
   | 5 | (none) | unmapped: every project (full run) |

   Why: a fixed order makes every decision deterministic, and the job summary names the rule that
   matched each path. The order is also the priority: cheap exits first, and a shared glob wins over a
   project rule.
4. **Shared inputs select everything.** Build logic and root build files, lockfiles, toolchain pins,
   CI files (`.github/**`, which also covers the map and the action), CI scripts, shared Dockerfiles
   and base images, shared test infrastructure, and libraries most projects use. Why: they feed every
   project; guessing which ones they affect is how regressions ship. A library with few dependents
   can instead list them in its `paths` rule, so they are rebuilt and retested with it.
5. **Diff the whole change against its merge-base.** Pull request: `base.sha`/`head.sha`; merge
   queue: `base_sha`/`head_sha`; branch push: the merge-base with the default branch; no usable base:
   full run. Renames count on both sides and deletions count. Why: the whole branch is the unit of
   change. A diff against the previous push misses earlier commits (and breaks after force pushes), a
   diff against the base tip drags in what landed on main meanwhile. This needs `fetch-depth: 0`.
6. **Fast paths skip jobs, never the check.** Docs-only runs skip build and tests; config-only runs
   config lint only. Skip jobs with `if:` on the detector's outputs, never the workflow with
   `on.*.paths`. Why: a workflow skipped by a path filter never reports its required check, so the PR
   waits forever; a job skipped by `if:` reports success, so only a gate that knows why things were
   skipped can tell "nothing to do" from "the detector broke".
7. **Some runs are always full.** The merge queue (it proves the actual merge result, possibly a
   batch of PRs), a `ci:full` label (the author suspects coupling the map does not know), and main,
   hotfix, nightly and release runs (`projects: all`, no detection at all). Why: affected detection
   is a feedback optimisation before merge; what gets deployed is proven in full.
8. **The map is the project registry.** `projects:` names every project CI knows and what it has:
   `image` (builds a container image) and `it` (has integration tests). The build workflow validates
   its `projects` input against it and derives the image and IT subsets from it. When everything is
   selected, the build runs the tool's root aggregate (`./gradlew build`). Why: adding a project is
   one map entry, no workflow hard-codes a name, and the root aggregate also builds projects the map
   forgot.
9. **One output contract, strings on the wire.** Lists are compact JSON (`[]`), booleans are
   `'true'`/`'false'`; consumers compare strings and `fromJSON` the lists. Why: job outputs are
   strings, and a stable contract lets several workflows and skills consume the detector unchanged.
10. **Flags for checks that cut across projects.** A flag is raised by any path matching its globs,
    whatever the path's class: `deploy-test` (charts, deployment config, the deployed app; also raised
    by full runs), `base-images` (rebuild base images locally; not raised by full runs) and custom
    `flags` (e2e, migrations, docs lint). Why: some tests depend on files outside any project, and
    some expensive rebuilds should only follow the files that need them.
11. **Jobs that need pushed images skip where images cannot exist.** Fork PRs get a read-only token:
    build the images, do not push them, skip the IT and deploy-test jobs, and let the gate warn. The
    merge queue treats the same skip as a failure. Why: a red check on every fork PR teaches people
    to ignore red, and a silent skip in the queue would merge untested code.
12. **Same answer on a laptop.** `python3 scripts/ci/affected.py --base origin/main` prints what CI
    will select, and the job summary lists every path with its class and rule. Why: people trust, and
    fix, what they can reproduce.

## Procedure

1. **Discover the repository.**

   | What | Where to look |
   |---|---|
   | build tool and project ids | `settings.gradle(.kts)` includes; Maven `<modules>`; `package.json` workspaces or `pnpm-workspace.yaml`; `go.work` or every `go.mod`; `[tool.uv.workspace] members`; Bazel packages; `nx show projects` |
   | dependencies between projects | which projects are libraries, and who uses each |
   | images and integration tests | a Dockerfile in the project directory; an IT task, suite or folder |
   | shared inputs | root build files, lockfiles, toolchain pins, `.github/`, CI scripts, shared Docker and test-infra folders |
   | docs and metadata | `docs/`, Markdown, licence and editor files, `.claude/`; any Markdown that is a build input (docs site, packaged README) |
   | config tree | per-environment deployment config that a config lint checks |
   | cross-cutting tests | a deployment test (charts into a throwaway cluster), e2e, migrations |
   | repository settings | default branch, merge queue, fork PRs, current required checks |

2. **Decide, with these defaults.**
   - Method: a path map (default up to a few dozen projects); the build tool's graph for more (see
     `references/wiring.md` section 12).
   - Project key: the project directory (`services/api`, default: every tool can be fed from it); or
     the tool's native id, as the reference did with Gradle paths (`":app"`).
   - Libraries: `shared` when most projects use them; otherwise list the dependents in the rule.
   - Docs: `docs/**`, `**/*.md`, repository metadata, `.claude/**`; narrow `**/*.md` when a Markdown
     file is a build input.
   - Config-only: config lint only. Forced full: merge queue and label `ci:full`. Main: `projects: all`.
   - Flags: `deploy-test` and `base-images` only if those tests and images exist; custom flags for
     other cross-cutting suites.
3. **Copy the templates** (table below): the script to `scripts/ci/affected.py` (keep it executable),
   the example map to `.github/affected-map.yml`, the action to `.github/actions/affected-matrix/`.
4. **Write the map.** Projects first (with `image` / `it`), then one `paths` rule per project
   directory, then `shared`, `docs`, `config` and the flags. Quote every glob. Then audit it against
   every tracked file:

   ```bash
   git ls-files | python3 scripts/ci/affected.py --files-from - | jq -r '.unmapped[]'
   ```

   Every listed file would force a full run: map it (usually `docs`, `shared` or a project rule) or
   accept that on purpose. Preview a few paths per class with `--files`.
5. **Wire the workflows** from `references/wiring.md`: the detect job (full history, per-event base
   and head, force-full), the build job's `projects` input and the per-tool commands, the IT matrix
   via `fromJSON`, flag consumers, the gate's rules for skipped jobs, and `projects: all` on main. If
   the pipeline itself is new, start from skill `gha-pipeline-design` (its `pr.yml` already calls
   this action) and come back for the map.
6. **Configure the repository.** Create the label once (`gh label create ci:full --color B60205
   --description "Run every build and test on this pull request"`); require only the gate check; add
   `merge_group:` to the PR workflow before turning the merge queue on.
7. **Prove it** with the commands under Validation, then on GitHub with throwaway PRs: docs-only,
   config-only, one project, one library, one shared file, the `ci:full` label, and (when possible) a
   fork PR and a merge-queue run. Read the gate's summary each time.

## Templates and scripts

| File | Purpose | What to adapt |
|---|---|---|
| `scripts/affected.py` | the classifier: map + diff -> JSON, `GITHUB_OUTPUT` lines, job summary; `--files` / `--files-from` for previews and audits; stdlib only (reads YAML through mikefarah yq v4 or PyYAML) | nothing: copy to `scripts/ci/affected.py`; all repository knowledge lives in the map |
| `scripts/test_affected.py` | self-test: rules, output contract, map validation, git mode in temp repos, both YAML readers, the action's run step | nothing; run it after changing the script (`AFFECTED_PY=<path>` tests a copy) |
| `assets/affected-map.example.yml` | commented example map for a multi-service monorepo (two services, a web app, a library, config, base images, deploy test, custom flags) | every project, glob and flag; delete the shared lines of build tools you do not use |
| `assets/actions/affected-matrix/action.yml` | composite action: runs the classifier, returns the contract outputs, writes the job summary | no placeholders; the `script` input defaults to `scripts/ci/affected.py` and `map` to `.github/affected-map.yml`; add a named output per custom flag if you prefer it to the `flags` JSON |
| `references/wiring.md` | the consuming jobs: detect, build and plan step, per-tool commands (Gradle, Maven, npm, pnpm, Go, uv, Bazel/Nx notes), IT matrix, flags, gate rules, merge queue and label, main, local preview, a map pin test | job ids and reusable-workflow names of your pipeline |

Action inputs: `base-ref`, `head-ref`, `default-branch` (empty: `origin/<repository default branch>`),
`force-full`, `force-full-reason`, `map`, `script`. Outputs: `projects`, `image-projects`, `matrix`,
`full`, `docs-only`, `config-changed`, `base-changed`, `deploy-test`, `flags`, `reason`.

## Gotchas

Each entry: symptom -> cause -> fix.

- **A change under a new folder ran no tests** -> the detector treated unmatched paths as "nothing to
  do" -> unmapped must mean shared (built into `affected.py`); review the `unmapped -> all` rows in
  the summary and map those paths.
- **A docs-only PR cannot merge: "Expected - Waiting for status to be reported"** -> the workflow
  carrying the required check was skipped by `on.pull_request.paths` / `paths-ignore`, and a skipped
  workflow never reports -> no path filters on that workflow; skip jobs with `if:` and let the gate
  (`if: always()`) report.
- **Every job skipped and the gate green, yet nothing was tested** -> the detect job failed (bad map,
  no python3) and skipped jobs count as success -> the gate checks `needs.detect-affected.result ==
  'success'` before anything else.
- **A code change skipped its project's build** -> an earlier section claimed the path (first match
  wins): `**/*.md` in docs, a broad `config` glob -> narrow the earlier glob (no negation exists) and
  preview with `--files`.
- **Every run is full with "no usable diff base"** -> shallow checkout (the default `fetch-depth: 1`),
  the base ref not fetched, a default branch that is not `main`, or git refusing a workspace owned by
  another user inside a job container -> `fetch-depth: 0` on the detect job, run it on the runner host
  (or add `safe.directory`); the action derives `origin/<default branch>` from the event.
- **A docs-only PR with a non-ASCII or unusual file name ran everything** -> `git diff --name-only`
  C-quotes such names (`"docs/caf\303\251.md"`), which match no glob -> read `git diff -z` (the
  portable script does; the reference did not).
- **`*.md` or `Dockerfile` misses nested files** -> `*` stays inside one path segment and a bare name
  matches only at the root -> `**/*.md`, `**/Dockerfile`.
- **The map does not parse ("found character that cannot start any token", an alias error)** -> an
  unquoted glob starts with `*` -> quote every glob.
- **Adding the `ci:full` label starts nothing** -> `labeled` is missing from `pull_request.types`
  (the defaults are opened, synchronize, reopened) -> add it; test the label with
  `contains(github.event.pull_request.labels.*.name, 'ci:full')`.
- **Merge-queue entries time out, or every queue entry runs twice** -> the workflow lacks
  `merge_group:`, or `on.push` does not exclude `gh-readonly-queue/**` -> add the trigger and the
  exclusion.
- **Fork PRs fail pushing images (403, "denied")** -> fork PRs get a read-only token -> push only when
  `head.repo.full_name == github.repository`, skip jobs that need pushed images (`images != '{}'`),
  warn in the gate on PRs and fail it in the merge queue.
- **"Matrix vector 'project' does not contain any values"** -> the matrix came from `fromJSON('[]')`
  -> guard the job with `if: needs.detect-affected.outputs.matrix != '[]'`.
- **A job meant for config-only changes never runs** -> it `needs:` a skipped job (the build) and the
  implicit `success()` skips it -> depend on the detect job only, or use
  `if: ${{ !cancelled() && needs.detect-affected.result == 'success' && ... }}`.
- **A condition is true although the output says `false`** -> `if: needs.x.outputs.full` tests a
  non-empty string, which is truthy -> compare `== 'true'`; pass `${{ ... == 'true' }}` to boolean inputs.
- **The deploy test ran (or tried to) on a docs-only PR** -> flags are raised whatever the class of
  the path, so a README under `helm/` raises `deploy-test` -> combine flag conditions with
  `docs-only != 'true'` or with the image the job needs.
- **A library change passed CI but broke an app using it** -> the library's rule listed only the
  library -> list its dependents in the rule or move it to `shared` (or use the tool's dependents
  selection: Gradle `buildDependents`, Maven `-amd`, pnpm `"...{./dir}"`).
- **The map is rejected after adding a key such as `owners:`** -> unknown top-level keys fail
  validation so typos like `share:` cannot silently empty a section -> prefix custom keys with `x-`.
- **`cannot read ... install mikefarah yq v4 or PyYAML` on a self-hosted runner or in a container** ->
  no YAML reader there -> install one of them, or keep the map as `affected-map.json`.

## Validation

Run these before handing the pipeline over (paths as in the adopting repository):

```bash
python3 .claude/skills/gha-affected-builds/scripts/test_affected.py   # the script's self-test
AFFECTED_PY=scripts/ci/affected.py python3 .claude/skills/gha-affected-builds/scripts/test_affected.py
python3 scripts/ci/affected.py --help
python3 -c 'import sys,yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' \
  .github/affected-map.yml .github/actions/affected-matrix/action.yml
git ls-files | python3 scripts/ci/affected.py --files-from - | jq -r '.unmapped[]'   # expect nothing unplanned
python3 scripts/ci/affected.py --files docs/README.md            # docs-only
python3 scripts/ci/affected.py --files <a file of one project>   # that project only
python3 scripts/ci/affected.py --files <a shared file>           # full
python3 scripts/ci/affected.py --base origin/main --summary /dev/stdout   # the current branch
actionlint   # with shellcheck on PATH: also checks the action's inputs and outputs as the workflows use them
bash scripts/test/affected-map-test.sh   # if you added the pin test of references/wiring.md section 11
```

A map error exits 2 with every problem listed; a git error exits 3. On GitHub, check the throwaway
PRs of procedure step 7: the detect job's summary names each path's rule, the gate's summary says
why jobs were skipped, and a docs-only PR is mergeable with the gate green.

## Related skills

- `gha-pipeline-design`: the entry point. Workflow topology, events, the fan-in gate, concurrency,
  permissions; its `pr.yml` and `_build.yml` templates consume this skill's action and map.
- `gha-ephemeral-test-envs`: the integration-test job each matrix entry runs, and the kind
  deployment test that `deploy-test` triggers.
- `gha-build-images`: what `base-changed` feeds (rebuild the base images in the PR that changes
  them) and the containerised build job.
- `gha-config-deploy`: the config tree and the config lint that config-only changes run.
- `gha-versioning-release`: the PR image tags the IT matrix pulls, and why main builds everything
  and releases promote what main tested.

When one of them is absent, the calling jobs in `references/wiring.md` still show the contract each
part must meet (the IT workflow takes `project` and `images`; the build returns `images` and
`it-projects`), so you can write those workflows yourself.

## Provenance

Distilled from the reference repository crazymatthsu/github-demo: `.github/affected-map.yml`,
`scripts/ci/affected.py`, `.github/actions/affected-matrix/action.yml`, the detect-affected, build,
integration-test, kind-deploy (named deploy-test in the templates) and pr-gate jobs of `.github/workflows/pr.yml`, the "Plan the Gradle
tasks" step of `.github/workflows/_gradle-build.yml` with `main.yml` passing `projects: all`, and the
design notes in `docs/07-ci-pipeline-github-actions.md` (sections 4.2, 5.3, 5.4, 6.3) and
`.github/README.md`; there the pipeline ran green on GitHub for pull requests and main. The portable
script keeps the reference's rule order, flags and output contract, and adds NUL-separated git
output (the reference ran everything for non-ASCII file names), strict map validation, custom
`flags`, `--files-from` and the `unmapped` list. Nothing here depends on that repository.
