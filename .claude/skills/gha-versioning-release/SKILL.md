---
name: gha-versioning-release
description: 'Versioning and releases for GitHub Actions without a version file: versions from git tags and Conventional Commits (release, rc on main, hotfix, PR, local), immutable version and sha- image tags plus moving main/latest tags, build once on main and promote the tested digest instead of rebuilding, a tag-triggered release workflow (version assert, wait for the tested main run, promote, SBOM, GitHub Release, bump PR), optional release-please, hotfix branches and registry retention. Use it when someone asks how to version builds or images, tag Docker images, cut or automate releases, add release-please, promote images between environments or clean up old images, or reports a wrong CI version, a release workflow that never started, or latest on an old hotfix.'
---

# Versioning and releases on GitHub Actions

## What this skill gives you

A version for every build computed from git alone, an image tag scheme that maps every tag to one commit,
and a release path that ships exactly the bytes main tested: a release adds tags to the tested digest,
never rebuilds. Scripts (`git-version.sh`, `retag-image.sh`, `resolve-image.sh`) with tests, and workflow
templates (`release.yml`, `_promote.yml`, optional `release-please.yml`).

## Principles

1. **Git is the only version source.** Every build computes its version from the release tags and the
   commits since them; no file holds a number. Why: a checked-in number drifts from what was built,
   conflicts on merges and needs a bot commit per release; a tag is atomic and *is* the release decision.
2. **One deterministic form per context.** Release `X.Y.Z`, main `<next>-rc.<n>`, hotfix
   `<patch>-rc.<n>`, PR `<next>-pr.<n>.<sha7>`, laptop `<next>-local.<n>.<sha7>[.dirty]`. Why: every
   image tag maps back to one commit and one context, and pre-releases sort below their release, so any
   SemVer tool orders builds correctly.
3. **The bump size comes from Conventional Commits, with the release tool's rules.** Breaking → major,
   `feat` → minor, anything else → patch. Why: the rc number on main predicts the next release, and a
   release pull request computes the same number.
4. **Main always builds the pre-release form, even on a commit that already carries its tag.** Why: the
   tag can appear before main's build starts; that build would push release tags before any test ran.
5. **Build once on main, test that digest, promote it.** A release adds tags to the digest main tested and
   rebuilds nothing. Why: a rebuild is another artifact (moved base image, non-reproducible build) than the
   one that passed the tests; the digest is the evidence.
6. **Release only what main tested.** The release workflow waits for a passing main run of the tagged
   commit and refuses otherwise. Why: the tag is intent, the green run is evidence; a tag on an untested
   commit, such as a bot's write-back, would ship untested bytes.
7. **Assert that the build computes the tag's version before promoting.** Why: it catches a tag on the
   wrong commit or line, a dirty tree and broken version wiring before anything is pushed.
8. **Version tags are immutable; only convenience tags move, and only forwards.** `X.Y.Z` and `sha-<sha7>`
   never move (the retag script refuses); `main`, `latest`, `X`, `X.Y` move, the last three only to the
   newest release of their series. Why: a deployment record must not change under you, and a hotfix of an
   older line must not drag `latest` backwards.
9. **Beyond dev, environments pin releases through reviewed bump pull requests.** qa and prod pin `X.Y.Z`
   (and the digest), never a moving tag. Why: approval is code review, git is the deployment log, rollback
   is a revert.
10. **The release front end is optional and replaceable.** release-please (or a person) only creates the
    tag; a hand-pushed annotated tag goes through the same workflow; the build never reads the tool's
    manifest. Why: no single point of failure, and "no version file" still holds.
11. **One version line unless cadences really differ.** Lockstep by default; one tag prefix (`<dir>/v`)
    per independently released unit. Why: one number per change ticket; every extra line costs a
    compatibility matrix and a second tag pattern everywhere.
12. **Retention protects what is referenced.** Releases, moving tags and every tag the configuration
    references are never deleted; `pr-*` images go after the PR closed plus a grace period; the newest N
    pre-releases stay; dry run first. Why: the registry stays small without breaking a running
    environment or a rollback target.

## The scheme at a glance

Example: last release `v1.4.2`, seven commits since, one of them `feat:`, HEAD `2b3c4d5`.

| Context (first match wins) | Version | Image tags on the digest |
|---|---|---|
| HEAD carries `v1.5.0`, clean tree | `1.5.0` | `1.5.0`, `sha-2b3c4d5`; release.yml adds `1.5`, `1`, `latest` when newest |
| pull request #123 (merge commit `9f8e7d6`) | `1.5.0-pr.123.9f8e7d6` | `pr-123-9f8e7d6` |
| main | `1.5.0-rc.7` | `1.5.0-rc.7`, `sha-2b3c4d5`, `main` (re-asserted on the tested digest by `publish`) |
| `hotfix/1.4.x`, 2 commits | `1.4.3-rc.2` (patch only) | `1.4.3-rc.2`, `sha-<sha7>` |
| laptop, edited tracked file | `1.5.0-local.7.2b3c4d5.dirty` | `local`, the version (never pushed) |

Bump from the commits since the last release tag: `type!:` or a `BREAKING CHANGE:` footer → major, `feat:`
→ minor, anything else → patch; no tag yet → `0.1.0`. The release path in one line: main builds and tests
the digest and `publish` re-asserts its tags; a tag `vX.Y.Z` on that commit makes release.yml assert the
version, find the passing main run, add the release tags to the same digest, attach SBOMs to the GitHub
Release and open the bump pull request. Details: references/version-scheme.md and references/release-flow.md.

## Procedure

### 1. Discover

- The build tool(s) and where a version lives today: `package.json`, `pom.xml`, `gradle.properties`,
  `pyproject.toml`, a `VERSION` file, `-ldflags`, and what reads it (banners, health endpoints, labels).
- Release units: which images and packages always release together (one line) and which have their own
  cadence (their own line).
- Existing tags: `git tag -l --sort=-v:refname | head -20` (prefixes, pre-release tags, oddities).
- History: squash merges with Conventional Commit PR titles? Is there a PR-title check?
- Trunk name, hotfix practice, merge queue; the registry (GHCR default; JFrog, ECR); whether main pushes
  images and whether anything tags them after the tests.
- Environments and where their image tags live (skill gha-config-deploy); whether the entry-point skill's
  `main.yml` and `_build.yml` exist (skill gha-pipeline-design).

### 2. Decide (recommended defaults first)

| Decision | Default | Alternatives |
|---|---|---|
| Version computation | `scripts/ci/git-version.sh` | a build plugin with the same rules (references/version-scheme.md §7) |
| Version lines | one line, tags `vX.Y.Z` | `<dir>/vX.Y.Z` per independently released unit |
| Moving tags | `main` on main builds; `X.Y`, `X`, `latest` for the newest release | none (`CONVENIENCE_TAGS: 'false'`); `main` only after the tests (references/version-scheme.md §5) |
| Release front end | annotated tags by hand | release-please release pull requests |
| Promotion | retag inside the same repository (GHCR) | a repository path per stage (`retag-image.sh --to`), JFrog promotion |
| After the release | bump pull request to the next environment | none: delete the `bump` job |
| Retention | nightly sweep, dry run until reviewed | registry-native policies plus an in-use job |

### 3. Compute the version from git

1. Copy `scripts/git-version.sh` to `scripts/ci/` and `scripts/test-git-version.sh` to
   `scripts/test/git-version-test.sh` (the tests find the script in `../ci/`; the entry-point skill's lint
   job runs `scripts/test/*-test.sh`). Keep every copied script executable (`git add --chmod=+x`): the
   workflows and `retag-image.sh` call them directly.
2. Remove version numbers from build files, or leave a fixed placeholder such as `0.0.0-dev` that every
   build overrides. Feed the computed version into the build per references/version-scheme.md §8 (Gradle,
   Maven, npm/pnpm, Go, Python, container labels).
3. Every job that computes a version checks out with `fetch-depth: 0` (the script exits 4 on a shallow
   clone in CI) and sets `PR_NUMBER: ${{ github.event.pull_request.number }}`.
4. Main builds ignore tags on HEAD: `git-version.sh --ignore-head-tags`, or delete the local HEAD tags
   first (`_build.yml` of gha-pipeline-design does this with `ignore-head-tags: true`).
5. The build pushes the tags the script prints (`--field tags`): main pushes `<rc>` and `sha-<sha7>`
   (and `main`, which the publish job re-asserts after the tests); PRs push `pr-<n>-<sha7>` from
   same-repository branches only. It outputs `version`, `images` (key → `repo:tag@sha256:…`) and
   `image-tags` (key → list of tags).
6. Several lines: the build computes the version per image with `--prefix <dir>/v --path <dir>` for the
   images of that line; a build that stamps one version on every image fits a single line only.

### 4. Publish only tested digests

1. Copy `scripts/retag-image.sh`, `scripts/resolve-image.sh` to `scripts/ci/` and
   `scripts/test-retag-image.sh` to `scripts/test/retag-image-test.sh`.
2. Copy `assets/workflows/_promote.yml` to `.github/workflows/`, fill `__REGISTRY__`.
3. In `main.yml`, a job `publish` calls `_promote.yml` after the tests with `images` and `image-tags` of
   the build (the entry-point template already does). Nothing downstream, deploys or releases, consumes an
   image before this job has passed.

### 5. The release workflow

1. Copy `assets/workflows/release.yml`; fill every placeholder (listed in its header): the main workflow
   file name, registry, image namespace, `RELEASE_LINES` (tag prefix → images), the version command, and
   the bump environment, directory and command.
2. Keep the `on.push.tags` patterns in line with the prefixes of `RELEASE_LINES`; the negative patterns
   keep pre-release tags out.
3. If the version command needs a toolchain (`./gradlew -q printVersion`), add its setup step where the
   template marks it.
4. The main workflow must run on `main` and `hotfix/**` and publish `sha-<sha7>` tags for every image of
   a line on every commit (with affected builds: retag unchanged images, skill gha-affected-builds).
5. The `bump` job's command belongs to the configuration layout (skill gha-config-deploy); delete the job
   if there is no next environment. With that skill's tree the command is its `set-image-tag.sh`:
   `IMAGE_DIGESTS="$IMAGES" bash scripts/ci/set-image-tag.sh --apps "$APPS" "$BUMP_DIR" "$VERSION"` (tag and
   digest on every instance of the released apps); its `deploy.yml` then deploys the merged bump and proposes
   the next environment. The resolve job outputs `apps` (the images' last path segments, space-separated).

### 6. Optional: release-please

1. Copy `assets/workflows/release-please.yml`; create `release-please-config.json` from
   `assets/release-please-config.example.json` (placeholders `__ROOT_COMPONENT__`, `__SUB_PACKAGE_PATH__`,
   `__SUB_COMPONENT__`; drop the second package for one line) and `.release-please-manifest.json`
   (`{".": "0.0.0"}` plus one entry per extra package).
2. Settings → Actions → General → allow GitHub Actions to create and approve pull requests.
3. Decide one combined release pull request (default with several packages) or one per package
   (`"separate-pull-requests": true`).
4. With a GitHub App token for release-please, remove the dispatch step (its tags then start release.yml).
   Details and the disable path: references/release-flow.md §6.

### 7. Repository settings and retention

- Packages grant this repository Actions access (write for pushes and retags, admin for deletes).
- A ruleset restricts who may create `v*` tags; `main` and `hotfix/**` are protected.
- Environments with reviewers guard promotion jobs that move images into qa/prod registry paths.
- Add the nightly retention job per references/retention.md.

### 8. Validate, then prove it

Run the Validation commands, merge a change and read the first main run (rc tag, `sha-` tag and `main`,
re-asserted by publish), then cut the first release (references/release-flow.md §4) and watch every job of it.

## Templates and scripts

| File | Purpose | What to adapt |
|---|---|---|
| `scripts/git-version.sh` | version, kind and image tags of the checkout from tags + Conventional Commits; `--field`, `--format env\|json\|github` | `--prefix` / `--path` per line; `--main-branch`, `--hotfix-prefix` if not `main` / `hotfix/` |
| `scripts/test-git-version.sh` | 83 plain-bash cases in throwaway repositories (every form, bump rule, lines, hotfix, shallow, usage) | install as `scripts/test/git-version-test.sh` |
| `scripts/retag-image.sh` | point tags at an existing digest; immutable version tags; verify after each write; `--to` another repository | `RETAG_MUTABLE_REGEX` if your moving tags differ (a trunk not named `main`) |
| `scripts/resolve-image.sh` | image reference → `repo@sha256:…` without pulling (registry, then local store) | none |
| `scripts/test-retag-image.sh` | 31 cases for both image scripts against a stubbed `docker` (no registry needed) | install as `scripts/test/retag-image-test.sh` |
| `assets/workflows/_promote.yml` | reusable retag by digest: inputs `images`, `tags`; output `published` | `__REGISTRY__`; login step for JFrog/ECR |
| `assets/workflows/release.yml` | tag → assert version → wait for the tested main run → promote → SBOM → GitHub Release → bump PR | `__MAIN_WORKFLOW__`, `__REGISTRY__`, `__IMAGE_NAMESPACE__`, `__RELEASE_LINES__`, `__VERSION_COMMAND__`, `__BUMP_ENV__`, `__BUMP_DIR__`, `__BUMP_COMMAND__`; tag patterns |
| `assets/workflows/release-please.yml` | optional release pull requests; dispatches release.yml per new tag | none (keep the file names) |
| `assets/release-please-config.example.json` | `simple` type, `initial-version` 0.1.0, one package per line, root `exclude-paths` | `__ROOT_COMPONENT__`, `__SUB_PACKAGE_PATH__`, `__SUB_COMPONENT__` |
| `references/version-scheme.md` | forms, bump rules, tag scheme, lines, feeding Gradle/Maven/npm/Go/Python | — |
| `references/release-flow.md` | the chain, release.yml job by job, manual route, hotfix, release-please, promotion targets | — |
| `references/retention.md` | what to keep and delete, GHCR API, algorithm, nightly job, other registries | — |

Third-party actions are pinned to a major version as in the reference (`actions/checkout@v7`,
`docker/login-action@v4`, `anchore/sbom-action@v0`, `googleapis/release-please-action@v5`, ...): update to
the current major when adopting.

## Gotchas

| Symptom | Cause | Fix |
|---|---|---|
| CI version is `0.1.0-rc.1` or otherwise wrong, laptops are right | shallow clone (checkout's default `fetch-depth: 1`): no tags, no history | `fetch-depth: 0` wherever a version is computed; git-version.sh exits 4 on a shallow clone in CI |
| after someone pushed a pre-release tag (`v1.5.0-rc.3`), main's versions jump (back to `0.1.0-rc.N`, or to odd bases) | the pre-release tag became the base (`git describe` without `--exclude`) | only strict `<prefix>X.Y.Z` tags count; with describe use `--match '<prefix>[0-9]*.[0-9]*.[0-9]*' --exclude '<prefix>*-*'` |
| a line such as `my-server/v*` never finds its tags | `--exclude '*-*'` also matches the dash in the prefix | put the prefix in the exclude (`'<prefix>*-*'`), or use git-version.sh (strict filter) |
| main build pushed `1.5.0` images before its tests | release-please tagged the merge commit before main's build computed the version | main builds ignore HEAD tags (`--ignore-head-tags`); release.yml promotes the tested rc digest |
| after merging an old hotfix branch, main builds `1.5.0-rc.N` although 1.5.0 shipped | `git describe` returns the nearest tag (`v1.4.3`), not the highest | git-version.sh uses the highest release tag HEAD contains |
| promoted image has a new digest | `imagetools create` without `--prefer-index=false` wraps a single manifest in a new index | use the flag (retag-image.sh does) and verify the digest after every write |
| `imagetools inspect --format '{{.Manifest.Digest}}'` prints `Name: … MediaType: … Digest: …` | buildx (v0.31.1 seen) prints its summary for any template starting with `{{.Manifest` | `--format '{{json .Manifest}}'` and read the first `digest` (resolve-image.sh); validate `^sha256:[0-9a-f]{64}$` |
| retag exits 3 "refusing to move immutable tag" | a version tag already points at another digest: the commit was rebuilt, or two builds computed one version | never re-push version tags; find why two digests got one version (a path-filtered `<n>`?) |
| released image's `org.opencontainers.image.version` label says `-rc.N` | promotion never rebuilds, labels are from the main build | accepted; identify releases by tag or by the `revision` label |
| release-please merged, tag exists, release.yml never ran | tags created with `GITHUB_TOKEN` start no workflow | dispatch it: `gh workflow run release.yml --ref <tag>` (the template does), or an App token |
| release-please fails creating its pull request | repository setting missing | Settings → Actions → General → allow GitHub Actions to create and approve pull requests |
| one release pull request contains every package | `separate-pull-requests` defaults to false with several packages | set it true for one pull request per package |
| release pull request or bump pull request shows no checks | pull requests opened with `GITHUB_TOKEN` start no workflow | close and reopen it, or open it with a GitHub App token |
| release.yml: "has no run for <sha>", or a hand-pushed tag started nothing | the tag sits on the bot's `[skip ci]` write-back commit: main never ran there, and `[skip ci]` in the tagged commit also suppresses the tag-push workflow | tag the tested merge commit (`gh run list --workflow main.yml --status success`), not `origin/main` blindly |
| after a hand-pushed tag, release-please proposes the same version | release-please reads the last release from its manifest | a pull request that sets the manifest to the tagged version |
| `latest` or GitHub's "Latest release" points at an old line's hotfix | the moving tags followed whatever released last; `gh release create` without `--latest` lets GitHub mark the newly created release Latest | move `X.Y`, `X`, `latest` only for the newest of the series; pass `--latest=false` otherwise (the template does) |
| GitHub Release created twice, or notes span two lines | release-please already created it; auto notes start at the previous release of any line | `gh release view` first; `--verify-tag`; `--notes-start-tag <previous tag of the line>` |
| push, retag or retention delete gets 403 on GHCR | the package does not grant this repository Actions access | Package settings → Manage Actions access (write; admin to delete), or a dedicated token |
| a PR build via `pull_request_target` is versioned as main | `GITHUB_REF` is the base branch there | set `PR_NUMBER` from `github.event.pull_request.number` |
| deleting untagged GHCR versions broke multi-platform images | per-platform manifests are listed as untagged versions | never delete untagged versions on GHCR |

## Validation

Run in the target repository before handing the pipeline over:

```bash
bash scripts/test/git-version-test.sh          # 83 cases, temp repositories
bash scripts/test/retag-image-test.sh          # 31 cases, stubbed docker
shellcheck --severity=style scripts/ci/git-version.sh scripts/ci/retag-image.sh scripts/ci/resolve-image.sh scripts/test/*-test.sh
actionlint .github/workflows/release.yml .github/workflows/_promote.yml .github/workflows/release-please.yml
python3 -c 'import sys,yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/workflows/*.yml
python3 -m json.tool release-please-config.json >/dev/null && python3 -m json.tool .release-please-manifest.json >/dev/null
grep -rn '__[A-Z0-9_]*__' .github/ scripts/ release-please-config.json || echo "no placeholders left"
git tag -l --sort=-v:refname | head                        # tags the lines will see
scripts/ci/git-version.sh --ci --ref main --format json    # what main builds from here
scripts/ci/git-version.sh --ci --ref main --prefix server/v --path server --field version   # per extra line
```

Then on GitHub: the first main run publishes `<rc>`, `sha-<sha7>` and `main`, re-asserted after the tests; the
first release (hand-pushed tag on that tested commit, or a merged release pull request) shows the version
assert, the tested run's URL, the promoted tags, the SBOMs on the GitHub Release and the bump pull request.

## Related skills

- **gha-pipeline-design**: the entry point; `main.yml` (whose `publish` job calls `_promote.yml`) and
  `_build.yml` (calls `git-version.sh --field version|tags`), the event model, `GITHUB_TOKEN` limits.
- **gha-affected-builds**: which images a change builds; under lockstep, unchanged images must still get
  the commit's `sha-` tag by retagging their previous digest.
- **gha-config-deploy**: where environments pin image tags and digests, the dev write-back (`[skip ci]`
  commits you must not tag), the bump pull request contents and CODEOWNERS approvals.
- **gha-ephemeral-test-envs**: the integration tests that gate `publish`.
- **gha-build-images**: base images with dated immutable tags and their own retention.

If one is not installed, keep the corresponding piece out and name the skill that would add it.

## Provenance

Distilled from the reference repository crazymatthsu/github-demo: `build-logic` `GitVersion.kt` and the
`buildlogic.git-version` settings plugin (the version algorithm), `.github/workflows/release.yml`,
`release-please.yml`, `release-please-config.json`, `_docker-publish.yml`, `main.yml`, `_gradle-build.yml`,
`nightly.yml`, `scripts/ci/retag-image.sh`, `resolve-image.sh`, `retention.sh`, design document D4 and
ADRs DL-03, DL-04, DL-05, DL-09 and DL-20. Its main path ran green there on GHCR (rc versions, build once,
publish by digest, dev deploy with write-back) and release-please opened its combined release pull
request; the release workflow's logic was re-tested here with stubs, and the image scripts against a real
registry. The portable scripts reimplement the algorithm in bash; nothing depends on that repository.
