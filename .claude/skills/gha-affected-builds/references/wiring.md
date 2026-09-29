# Wiring the detector into GitHub Actions

How the outputs of `affected-matrix` (the composite action around `affected.py`) drive the jobs of a
pull-request workflow. Job ids match the `pr.yml` template of skill `gha-pipeline-design`
(`detect-affected`, `build`, `integration-test`, `gate`). YAML blocks whose first line names a
workflow file are excerpts of that file; the build workflow is the reusable `_build.yml` of the same
skill (inputs `projects`, `build-images`, `push-images`; outputs `images`, `it-projects`, `version`).
Third-party actions are pinned to a major version as in the reference (`actions/checkout@v7`): update
to the current major when adopting.

1. [The output contract](#1-the-output-contract)
2. [The detect job](#2-the-detect-job)
3. [The build job and its projects input](#3-the-build-job-and-its-projects-input)
4. [From project keys to build-tool commands](#4-from-project-keys-to-build-tool-commands)
5. [The integration-test matrix](#5-the-integration-test-matrix)
6. [Flags](#6-flags)
7. [The fan-in gate and skipped jobs](#7-the-fan-in-gate-and-skipped-jobs)
8. [Docs-only and config-only runs](#8-docs-only-and-config-only-runs)
9. [Merge queue and the label that forces a full run](#9-merge-queue-and-the-label-that-forces-a-full-run)
10. [Main, nightly and release: always everything](#10-main-nightly-and-release-always-everything)
11. [Preview locally and pin the map's decisions](#11-preview-locally-and-pin-the-maps-decisions)
12. [When a path map is not enough](#12-when-a-path-map-is-not-enough)

## 1. The output contract

| Output | On the wire | Example | Consumed by |
|---|---|---|---|
| `projects` | compact JSON list | `["services/api"]` | the build job's `projects` input |
| `image-projects` | compact JSON list | `["services/api"]` | image build and push, if planned outside the build workflow |
| `matrix` | compact JSON list | `["services/api"]` | `strategy.matrix` of the integration tests |
| `full` | `'true'` / `'false'` | `'false'` | summaries, jobs that only run on full runs |
| `docs-only` | `'true'` / `'false'` | `'false'` | the `if:` of every build and test job, the gate |
| `config-changed` | `'true'` / `'false'` | `'true'` | config lint, when you gate it (see section 8) |
| `base-changed` | `'true'` / `'false'` | `'false'` | the build's "rebuild base images locally" input |
| `deploy-test` | `'true'` / `'false'` | `'true'` | the deployment test job, the gate |
| `flags` | compact JSON object | `{"e2e":true}` | `fromJSON(needs.detect-affected.outputs.flags).e2e` |
| `reason` | one line | `affected: services/api` | the gate's summary |

Rules that keep conditions correct:

- Job outputs are strings. Compare booleans as strings (`== 'true'`, `!= 'true'`): a bare
  `if: needs.detect-affected.outputs.full` is true for the string `'false'` (non-empty strings are
  truthy). Pass a real boolean to a `type: boolean` input with `${{ ... == 'true' }}`.
- Lists are compact JSON, so the empty list is exactly `'[]'` and `!= '[]'` is a safe guard.
- A job exposes only the outputs it re-declares under `outputs:`: list every one the workflow reads.
- The outputs of a skipped job are empty strings, not your JSON default: guard with `|| '{}'` or test
  `needs.<job>.result` before `fromJSON`.

## 2. The detect job

```yaml
# .github/workflows/pr.yml
jobs:
  detect-affected:
    name: detect affected
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      projects: ${{ steps.affected.outputs.projects }}
      image-projects: ${{ steps.affected.outputs.image-projects }}
      matrix: ${{ steps.affected.outputs.matrix }}
      full: ${{ steps.affected.outputs.full }}
      docs-only: ${{ steps.affected.outputs.docs-only }}
      config-changed: ${{ steps.affected.outputs.config-changed }}
      base-changed: ${{ steps.affected.outputs.base-changed }}
      deploy-test: ${{ steps.affected.outputs.deploy-test }}
      flags: ${{ steps.affected.outputs.flags }}
      reason: ${{ steps.affected.outputs.reason }}
    steps:
      - uses: actions/checkout@v7 # update to the current major when adopting
        with:
          fetch-depth: 0 # the merge-base needs history (a very large repo can add `filter: blob:none`)

      - id: affected
        uses: ./.github/actions/affected-matrix
        with:
          base-ref: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || '' }}
          head-ref: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.sha }}
          force-full: ${{ github.event_name == 'merge_group' || contains(github.event.pull_request.labels.*.name, 'ci:full') }}
          force-full-reason: ${{ github.event_name == 'merge_group' && 'merge queue' || 'label ci:full' }}
```

| Event | `base-ref` | `head-ref` | What is compared |
|---|---|---|---|
| `pull_request` | `pull_request.base.sha` | `pull_request.head.sha` | merge-base(base, head)..head: the PR's own change, as GitHub's "Files changed" shows it |
| `merge_group` | `merge_group.base_sha` | `merge_group.head_sha` | the queued change (irrelevant in practice: the queue forces a full run) |
| `push` to a branch | empty | `github.sha` | merge-base(origin/<default branch>, head)..head: the whole branch, not only the last push |

Why the whole branch on push: the diff against `github.event.before` covers only the latest push, so
a docs fix pushed after a code commit would look docs-only, and after a force push `before` may not
even be an ancestor. The script also treats an all-zero `before` (a new branch) as empty.

The detect job runs on the runner host, not in a job container: inside a container, git may refuse the
workspace ("detected dubious ownership"), the diff base becomes unusable and every run silently goes
full. If it must run in a container, add `git config --global --add safe.directory "$GITHUB_WORKSPACE"`.

## 3. The build job and its projects input

```yaml
# .github/workflows/pr.yml
jobs:
  build:
    needs: detect-affected
    if: needs.detect-affected.outputs.docs-only != 'true' && needs.detect-affected.outputs.projects != '[]'
    uses: ./.github/workflows/_build.yml
    permissions:
      contents: read
      packages: write
    with:
      projects: ${{ needs.detect-affected.outputs.projects }}
      # Plain branch pushes stay in the fast tier: no images.
      build-images: ${{ github.event_name != 'push' }}
      # Fork PRs get a read-only token: they build images but cannot push them (their ITs are skipped).
      push-images: ${{ github.event_name == 'merge_group' || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository) }}
      # When _build.yml has the input (skill gha-build-images):
      # rebuild-base: ${{ needs.detect-affected.outputs.base-changed == 'true' }}
```

`projects != '[]'` skips the build on a config-only change. Inside the build workflow, a plan step
validates the list against the map (a typo or a stale list fails loudly instead of building nothing),
derives the image and IT subsets from the map's `image` / `it` keys, and notes whether every project
is selected, so the build can use the tool's root aggregate. Callers without detection (main,
nightly) pass `projects: all`.

```bash
# Plan step of _build.yml: PROJECTS is the input ('all' or a JSON list); needs yq v4 and jq.
meta=$(yq -o=json -I=0 '.projects' .github/affected-map.yml)
known=$(jq -c 'keys_unsorted' <<<"$meta")
if [[ $PROJECTS == all ]]; then
  selected=$known
else
  selected=$(jq -c --argjson known "$known" '
    if type == "array" and length > 0 and all(.[]; . as $p | $known | index($p) != null) then .
    else error("projects must be a non-empty JSON list of keys of .projects in the affected map") end
  ' <<<"$PROJECTS")
fi
{
  echo "projects=$selected"
  echo "image-projects=$(jq -c --argjson m "$meta" '[.[] | select($m[.].image == true)]' <<<"$selected")"
  echo "it-projects=$(jq -c --argjson m "$meta" '[.[] | select($m[.].it == true)]' <<<"$selected")"
  echo "all=$(jq -r --argjson known "$known" 'sort == ($known | sort)' <<<"$selected")"
} >> "$GITHUB_OUTPUT"
```

Why the root aggregate when everything is selected: `./gradlew build` (or `mvn verify`, `go test
./...`) also builds projects the map does not list yet, so a full run covers what the build tool
knows, not only what the map knows. The reference did exactly this (per-project `:<project>:build`
tasks for a subset, the root `build` for all).

## 4. From project keys to build-tool commands

The map keys are project directories (`services/api`); each tool gets its own id from them. In the
snippets `PROJECTS` is the planned JSON list and `ALL` the plan's `all` output. Gradle is the form
proven in the reference; the others are short sketches: check the flags against your tool version.

Gradle (project paths mirror directories: `services/api` -> `:services:api`):

```bash
if [[ $ALL == true ]]; then
  tasks=(build) # root aggregate: every project Gradle knows
else
  mapfile -t tasks < <(jq -r '.[] | ":" + gsub("/"; ":") + ":build"' <<<"$PROJECTS")
fi
./gradlew "${tasks[@]}" --continue
```

`:p:build` compiles p's dependencies but does not run their tests; a library's dependents are covered
by listing them in the library's `paths` rule (or run `:lib:buildDependents`). The reference keyed the
map by Gradle path (`":app"`) instead of directory; then the keys pass through unchanged
(`map(. + ":build")`). Image tasks follow the same pattern (`:p:buildImage`, root `buildImages`).

Maven (`-pl` takes module directories; `-am` also builds what they depend on, `-amd` their dependents):

```bash
if [[ $ALL == true ]]; then
  ./mvnw -B verify
else
  ./mvnw -B verify -pl "$(jq -r 'join(",")' <<<"$PROJECTS")" -am
fi
```

npm workspaces (`--workspace` accepts a directory):

```bash
if [[ $ALL == true ]]; then
  args=(--workspaces)
else
  mapfile -t args < <(jq -r '.[] | "--workspace=" + .' <<<"$PROJECTS")
fi
npm ci
npm run build "${args[@]}" --if-present
npm test "${args[@]}" --if-present
```

pnpm (`--filter ./dir` selects the package in that directory; `"...{./dir}"` adds its dependents):

```bash
if [[ $ALL == true ]]; then
  filters=(--recursive)
else
  mapfile -t filters < <(jq -r '.[] | ("--filter", "./" + .)' <<<"$PROJECTS")
fi
pnpm install --frozen-lockfile
pnpm "${filters[@]}" run build
pnpm "${filters[@]}" run test
```

Go, one module at the root (`./dir/...` = every package below the project directory):

```bash
if [[ $ALL == true ]]; then
  pkgs=(./...)
else
  mapfile -t pkgs < <(jq -r '.[] | "./" + . + "/..."' <<<"$PROJECTS")
fi
go vet "${pkgs[@]}"
go test "${pkgs[@]}"
```

With a `go.work` and one module per project, loop instead: `go -C "$dir" test ./...` per directory.

Python with a uv workspace (one member per project directory):

```bash
mapfile -t dirs < <(jq -r '.[]' <<<"$PROJECTS") # the plan already expanded 'all' to every key
for dir in "${dirs[@]}"; do
  (cd "$dir" && uv run --locked pytest)
done
```

Other tools:

- **Bazel**: key the map by package (`//services/api`) and run `bazel test <key>/...`; `//...` for all.
  Bazel's cache already makes "everything" cheap; for precise selection use a target determinator
  (bazel-diff, target-determinator) and keep the map for the docs-only / config-only / full decisions.
- **Nx / Turborepo**: they compute affected projects from their own graph (`nx affected -t build test
  --base=... --head=...`, `turbo run build --filter="...[origin/main]"`). Either let them select and use
  the map only for docs-only / config-only / full, or feed them the map's list (`nx run-many -t build
  --projects=a,b`, one `--filter` per key) to keep one source of truth.

## 5. The integration-test matrix

```yaml
# .github/workflows/pr.yml
jobs:
  integration-test:
    needs: [detect-affected, build]
    if: >-
      (github.event_name == 'pull_request' || github.event_name == 'merge_group')
      && needs.detect-affected.outputs.matrix != '[]'
      && needs.build.outputs.images != '{}'
    strategy:
      fail-fast: false
      matrix:
        project: ${{ fromJSON(needs.detect-affected.outputs.matrix) }}
    uses: ./.github/workflows/_integration-test.yml # skill gha-ephemeral-test-envs
    permissions:
      contents: read
      packages: read
    with:
      project: ${{ matrix.project }}
      images: ${{ needs.build.outputs.images }}
```

- `matrix != '[]'` is required: GitHub rejects a matrix built from an empty list ("Matrix vector
  'project' does not contain any values"), and the `if:` is evaluated before the matrix is expanded.
- `images != '{}'` skips the tests when nothing was pushed (fork PRs); the gate explains the skip.
- `fail-fast: false`: one project's failure must not cancel the evidence of the others. Add
  `max-parallel` when the tests share scarce capacity. A matrix holds at most 256 jobs.
- Each job pulls the image built in this run by digest: `fromJSON(inputs.images)[inputs.project]`.
- On main, feed the matrix from the build's `it-projects` output (every project with `it: true`).

## 6. Flags

A flag is raised by any changed path that matches its globs, whatever class the path has, so a path
can select a project and raise a flag at once. `deploy-test` and custom flags with `on-full: true`
(the default) are also raised by full runs; `base-changed` and `on-full: false` flags are not.

```yaml
# .github/workflows/pr.yml
jobs:
  deploy-test:
    needs: [detect-affected, build]
    # The deployment test needs the image of the app it deploys, pushed by this run.
    if: >-
      (github.event_name == 'pull_request' || github.event_name == 'merge_group')
      && needs.detect-affected.outputs.deploy-test == 'true'
      && contains(needs.build.outputs.images, '"services/api"')
    uses: ./.github/workflows/_kind-deploy.yml # skill gha-ephemeral-test-envs
    permissions:
      contents: read
      packages: read
    with:
      project: services/api # the key of `images` whose image the chart runs
      images: ${{ needs.build.outputs.images }}

  e2e:
    needs: [detect-affected, build]
    if: needs.detect-affected.outputs.docs-only != 'true' && fromJSON(needs.detect-affected.outputs.flags).e2e
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v7
      - name: End-to-end suite
        env:
          IMAGES: ${{ needs.build.outputs.images }}
        run: scripts/ci/e2e.sh "$IMAGES" # your suite, against the images of this run
```

- Flags fire on docs paths too (a `README.md` under a chart raises `deploy-test` on a docs-only run).
  That is useful for docs checks (a `docs-lint` flag on `docs/**` runs a link checker when everything
  else is skipped) and a trap for jobs that need a build: combine those with `docs-only != 'true'` or
  with the image condition, as above.
- Custom flags reach the workflow through the `flags` JSON output of the action. The script also
  writes each flag as its own `GITHUB_OUTPUT` line, so to expose one as a named action output add it
  to the action's `outputs:` (`value: ${{ steps.detect.outputs.<name> }}`).
- `base-changed` goes to the build (rebuild the base images from this change instead of pulling the
  published ones, skill `gha-build-images`); it is not raised by a full run because that rebuild is
  only needed when the base images changed.

## 7. The fan-in gate and skipped jobs

One job fans everything in and is the only required status check (skill `gha-pipeline-design` owns
the pattern). What this skill adds is the judgement of skipped jobs, because a skipped job reports
success and a required check that is never reported blocks the PR forever:

| Situation | Skipped | Gate verdict |
|---|---|---|
| docs-only change | everything but detect | success, "docs-only" line in the summary |
| config-only change | build, integration tests, deploy test | success (config lint ran) |
| no affected project has ITs | integration tests | success |
| fork PR (images not pushed) | integration tests, deploy test | success with a warning |
| merge queue with a skipped IT or deploy test | | failure: the queue must prove the merge result |
| detect-affected failed | everything | failure (otherwise the gate passes vacuously) |
| any job failed or was cancelled | | failure |

```yaml
# .github/workflows/pr.yml
jobs:
  gate:
    # A branch push reports `push-gate`, so its result can never satisfy the required `pr-gate`.
    name: ${{ github.event_name == 'push' && 'push-gate' || 'pr-gate' }}
    if: always()
    needs: [detect-affected, build, config-lint, integration-test, deploy-test, e2e]
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Evaluate
        env:
          NEEDS: ${{ toJSON(needs) }}
          EVENT: ${{ github.event_name }}
          REASON: ${{ needs.detect-affected.outputs.reason }}
          DOCS_ONLY: ${{ needs.detect-affected.outputs.docs-only }}
          MATRIX: ${{ needs.detect-affected.outputs.matrix }}
          DEPLOY_TEST: ${{ needs.detect-affected.outputs.deploy-test }}
          IMAGES: ${{ needs.build.outputs.images }}
          BUILD_RESULT: ${{ needs.build.result }}
          DEPLOY_RESULT: ${{ needs.deploy-test.result }}
        run: |
          set -euo pipefail
          gate=pr-gate
          [[ $EVENT == push ]] && gate=push-gate
          {
            echo "### $gate"
            echo ""
            echo "Affected: ${REASON:-unknown}"
            echo ""
            echo "| job | result |"
            echo "|---|---|"
            jq -r 'to_entries[] | "| \(.key) | \(.value.result) |"' <<<"$NEEDS"
          } >> "$GITHUB_STEP_SUMMARY"
          fail=0
          if [[ $(jq -r '."detect-affected".result' <<<"$NEEDS") != success ]]; then
            echo "::error::detect-affected did not succeed"; fail=1
          fi
          bad=$(jq -r '[to_entries[] | select(.value.result == "failure" or .value.result == "cancelled") | .key] | join(", ")' <<<"$NEEDS")
          if [[ -n $bad ]]; then
            echo "::error::failed or cancelled: $bad"; fail=1
          fi
          tested=false
          [[ $EVENT == pull_request || $EVENT == merge_group ]] && tested=true
          if [[ $DOCS_ONLY == true ]]; then
            echo "- docs-only change: build and tests skipped" >> "$GITHUB_STEP_SUMMARY"
          elif [[ $tested == true && $MATRIX != '[]' && ${IMAGES:-'{}'} == '{}' ]]; then
            if [[ $EVENT == merge_group ]]; then
              echo "::error::merge queue: no images were pushed, so the integration tests could not run"; fail=1
            else
              echo "::warning::images not pushed (fork PR): integration tests skipped; the merge queue and main run them"
            fi
          fi
          if [[ $DOCS_ONLY != true && $tested == true && $DEPLOY_TEST == true && $DEPLOY_RESULT == skipped &&
                ($BUILD_RESULT == success || $BUILD_RESULT == skipped) ]]; then
            if [[ $EVENT == merge_group ]]; then
              echo "::error::merge queue: the deploy test did not run"; fail=1
            else
              echo "- deploy test skipped: no image of the deployed app was pushed (fork PR, or a change that builds none)" >> "$GITHUB_STEP_SUMMARY"
            fi
          fi
          exit "$fail"
```

A job that must run even when one of its `needs` was skipped (for example a check that needs `build`
but must also run on config-only changes) needs an explicit condition, because the implicit
`success()` skips it: `if: ${{ !cancelled() && needs.detect-affected.result == 'success' && ... }}`.

## 8. Docs-only and config-only runs

- Never filter the workflow that carries the required check with `on.pull_request.paths` or
  `paths-ignore`: a workflow skipped that way never reports, and the PR waits for "Expected - Waiting
  for status to be reported" forever. Always run, detect, skip jobs with `if:`, let the gate report.
- Docs-only: every job carries `if: needs.detect-affected.outputs.docs-only != 'true'` (or needs a job
  that does); the gate passes and says why. The detect job costs a checkout and a few seconds.
- Config-only: `projects` is `[]`, so the build and everything that needs it are skipped; config lint
  (skill `gha-config-deploy`) runs because it only needs the detect job:

```yaml
# .github/workflows/pr.yml
jobs:
  config-lint:
    needs: detect-affected
    if: needs.detect-affected.outputs.docs-only != 'true'
    uses: ./.github/workflows/config-lint.yml
    permissions:
      contents: read
```

The reference ran config lint on every non-docs change (it is cheap, and it also renders charts that
live outside the config tree); gate it on `config-changed == 'true' || full == 'true'` only when it is
expensive and nothing outside `config` feeds it. On main a config-only merge still runs the whole
pipeline and the deployment.

## 9. Merge queue and the label that forces a full run

```yaml
# .github/workflows/pr.yml
name: pr
on:
  push:
    # main (and hotfix branches) run main.yml; merge-queue branches run here through merge_group.
    branches-ignore: [main, 'hotfix/**', 'gh-readonly-queue/**']
  pull_request:
    types: [opened, synchronize, reopened, labeled]
  merge_group:
concurrency:
  group: pr-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
permissions:
  contents: read
jobs:
  # detect-affected, build, integration-test, deploy-test, e2e, gate, config-lint: sections 2 to 8
```

- `merge_group:` is mandatory once the queue is on: without it the required check is never reported
  for the queue's commit and every entry times out. `gh-readonly-queue/**` stays out of `on.push`,
  otherwise each queue entry also starts a push run.
- The queue passes `force-full: true` (section 2): it tests the actual merge result, possibly a batch
  of PRs, with everything. The price: a docs-only PR also gets a full run in the queue.
- The label: `labeled` must be in `pull_request.types`, or adding the label starts nothing (the default
  types are opened, synchronize, reopened). Any label event reruns the workflow; the per-PR concurrency
  group cancels the superseded run. Create the label once:
  `gh label create ci:full --color B60205 --description "Run every build and test on this pull request"`.
  Removing it takes effect on the next push.
- A `ci:skip-tests` label is deliberately not offered: a PR that cannot afford its tests is not ready.

## 10. Main, nightly and release: always everything

Affected detection is a pre-merge feedback optimisation. What gets deployed is proven in full: main,
hotfix branches and the nightly run pass `projects: all`, and a release promotes what main tested.

```yaml
# .github/workflows/main.yml
name: main
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/_build.yml
    permissions:
      contents: read
      packages: write
    with:
      projects: all
      push-images: true

  integration-test:
    needs: build
    if: needs.build.outputs.it-projects != '[]'
    strategy:
      fail-fast: false
      matrix:
        project: ${{ fromJSON(needs.build.outputs.it-projects) }}
    uses: ./.github/workflows/_integration-test.yml
    permissions:
      contents: read
      packages: read
    with:
      project: ${{ matrix.project }}
      images: ${{ needs.build.outputs.images }}
```

## 11. Preview locally and pin the map's decisions

```bash
git fetch origin main
python3 scripts/ci/affected.py --base origin/main --summary /dev/stdout  # this branch, as CI sees it
python3 scripts/ci/affected.py --files services/api/src/app.py docs/intro.md
git ls-files | python3 scripts/ci/affected.py --files-from - | jq -r '.unmapped[]'  # map coverage
```

The summary table lists every changed path with the class and the rule that matched it; `unmapped`
lists what would force a full run. Pin the decisions that matter in a plain-bash test the lint job
runs (for example `scripts/test/affected-map-test.sh`), so a later map edit cannot quietly change them:

```bash
#!/usr/bin/env bash
# Pins the affected map's key decisions. Run from the repository root; needs python3 and jq.
set -euo pipefail
check() { # check <jq condition on the decision> <path>...
  local expect=$1
  shift
  if ! python3 scripts/ci/affected.py --files "$@" | jq -e "$expect" >/dev/null; then
    echo "FAIL: $* -> expected $expect" >&2
    return 1
  fi
}
check '."docs-only"' docs/intro.md README.md
check '.projects == ["services/api"] and (.full | not)' services/api/src/app.py
check '.projects == ["libs/common", "services/api", "services/worker"]' libs/common/src/util.go
check '.full' pnpm-lock.yaml
check '."config-changed" and .projects == [] and (."docs-only" | not)' config/dev/api.yml
echo "affected map: decisions hold"
```

## 12. When a path map is not enough

| Approach | Strengths | Costs | Prefer when |
|---|---|---|---|
| Path map + script (this skill) | transparent, seconds, no build-tool start-up, one small reviewed file, same answer on a laptop | follows the tree by hand; coarse (a comment change rebuilds its project) | up to a few dozen projects with a shallow dependency graph |
| Build-tool graph (Gradle project graph, Nx / Turborepo, Bazel target determinators, `pnpm --filter "...[origin/main]"`) | precise, follows real dependencies | tool start-up in the detect job, a plugin or tool to maintain, harder to explain | dozens of projects with deep dependencies |
| Always everything | no logic at all | every push pays for every project | tiny repositories, main, nightly |

The approaches combine: keep the map for docs-only, config-only, full and the flags, and let the
build tool select precisely within a non-full run. Third-party "changed files" actions are not a
substitute for either: they hide the decision in someone else's code and hand it your token
(tj-actions/changed-files was compromised in March 2025 and dumped CI secrets into build logs).
