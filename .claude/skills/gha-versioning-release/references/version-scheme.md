# Version scheme: forms, bump rules, image tags, feeding the build

Read this when you choose or explain a version form, wire the version into a build tool, add a second
version line, or debug "why is the version X". The implementation is `scripts/git-version.sh`; its tests
(`scripts/test-git-version.sh`) are the executable form of every rule below.

Contents: 1 Inputs · 2 Forms per context · 3 Bump rules · 4 Why these forms · 5 Image tag scheme ·
6 Version lines · 7 git-version.sh in practice · 8 Feeding the version into the build

## 1. Inputs

- **Release tags** `<prefix>X.Y.Z` (default prefix `v`), annotated or lightweight. Nothing else is a
  version source: no `VERSION` file, no number in `package.json`/`pom.xml`/`gradle.properties` that a
  human edits. The tag is the release decision; the history since it decides everything else.
- **Base** = the highest `<prefix>X.Y.Z` tag that HEAD contains. `X.Y.Z` is strict (no leading zeros);
  pre-release tags (`v1.5.0-rc.3`), other lines' tags and malformed tags (`v1.6`, `v1.2.3foo`) never count.
- **`<n>`** = commits since the base (every commit when there is no tag). Never path-filtered: it must
  grow with every main commit, or two main builds would compute the same immutable version.
- **`<next>`** = the base bumped by the commits since it (section 3); `0.1.0` when the line has no tag.
- **CI context**: `GITHUB_ACTIONS`, `GITHUB_REF`, `PR_NUMBER` (or flags `--ci`, `--ref`, `--pr`).

The reference computed the base with `git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*'
--exclude '*-*'` (nearest tag). The portable script takes the highest reachable tag instead: identical on a
linear history, and still right after an older hotfix line is merged back (describe then returns the
hotfix tag `v1.4.3` although `v1.5.0` is in the history, and main would build `1.5.0-rc.N` after `1.5.0`
shipped). It also avoids the bare `--exclude '*-*'`, which drops every tag of a line whose prefix contains
a dash (`my-server/v1.2.0`).

## 2. Forms per context

Checked in this order; the first match wins.

| Kind | When | Version | Image tags (first = primary) |
|---|---|---|---|
| `release` | HEAD carries a release tag of the line and tracked files are clean | `X.Y.Z` | `X.Y.Z`, `sha-<sha7>` |
| `pr` | a PR number is known: `PR_NUMBER`, `refs/pull/<n>/…`, or a merge-queue ref `refs/heads/gh-readonly-queue/<base>/pr-<n>-<sha>` | `<next>-pr.<n>.<sha7>` | `pr-<n>-<sha7>` |
| `main` | CI on `refs/heads/main` | `<next>-rc.<n>` | `<next>-rc.<n>`, `sha-<sha7>`, `main` |
| `hotfix` | CI on `refs/heads/hotfix/*` | `<base patch+1>-rc.<n>` | `<version>`, `sha-<sha7>` |
| `local` | anything else (laptop, CI push to a feature branch) | `<next>-local.<n>.<sha7>[.dirty]` | `local`, `<version>` |

Worked example: last release `v1.4.2`; since then `fix: a`, `feat(api): b` and five more commits (7);
HEAD `2b3c4d5`.

| Context | Version | Tags |
|---|---|---|
| laptop, clean | `1.5.0-local.7.2b3c4d5` | `local`, `1.5.0-local.7.2b3c4d5` |
| laptop, edited tracked file | `1.5.0-local.7.2b3c4d5.dirty` | never pushed |
| PR #123 (merge commit `9f8e7d6`) | `1.5.0-pr.123.9f8e7d6` | `pr-123-9f8e7d6` |
| main | `1.5.0-rc.7` | `1.5.0-rc.7`, `sha-2b3c4d5`, `main` (after the tests) |
| tag `v1.5.0` on `2b3c4d5` | `1.5.0` | release.yml adds `1.5.0` (+ `1.5`, `1`, `latest` when newest) to the digest `sha-2b3c4d5` names |
| `hotfix/1.4.x` from `v1.4.2`, 2 commits incl. a `feat` | `1.4.3-rc.2` | `1.4.3-rc.2`, `sha-<sha7>` |

Notes:
- **PR before main**: `pull_request_target` runs with `GITHUB_REF=refs/heads/main`; set
  `PR_NUMBER: ${{ github.event.pull_request.number }}` in the job env so such builds are PR builds.
- **Dirty** counts tracked files only: an untracked file must not turn a tag checkout into `.dirty`. A CI
  step that rewrites a tracked file makes the tag checkout `local` and the release assert fails, on purpose.
- **main after a release tag**: release-please (or a person) may tag the merge commit before main's build
  computes its version; that build would then produce `1.5.0` and push release tags before any test ran.
  Main builds pass `--ignore-head-tags` (or delete the local tags on HEAD first), so they always build the
  pre-release form; release.yml later promotes that digest.

## 3. Bump rules (Conventional Commits)

| Commits since the base (any of them) | Bump | Example |
|---|---|---|
| subject `<type>!:` or `<type>(<scope>)!:` | major | `feat!: drop the v1 API` |
| a line starting `BREAKING CHANGE:` or `BREAKING-CHANGE:` | major | footer `BREAKING CHANGE: renamed keys` |
| subject `feat:` / `feature:` (scope optional) | minor | `feat(api): paging` |
| anything else | patch | `fix:`, `perf:`, `chore:`, `docs:`, `Merge pull request #5 ...` |

- Types are case-sensitive (`Feat:` is a patch), as in release-please. `feature:` counts as minor for the
  same reason; the reference matched `feat` only.
- Before 1.0 a breaking change still goes to `1.0.0` (release-please's default `bump-minor-pre-major:
  false`). Change both together if you change it.
- A hotfix branch bumps the patch whatever its commits say.
- The number on main is a prediction. `1.5.0-rc.7` may become `2.0.0-rc.8` after a `feat!:`; release-please
  skips chore-only histories and honours a `Release-As: x.y.z` footer, which the prediction ignores. All
  harmless: pre-releases are dev-only, and release.yml checks the tag, not the prediction.
- Enforce the convention where it is cheap: squash merges with a PR-title check (the squash commit
  subject is the PR title).

## 4. Why these forms

- **SemVer ordering holds**: `1.4.2 < 1.5.0-rc.9 < 1.5.0-rc.10 < 1.5.0 < 2.0.0-rc.1` (numeric identifiers
  compare as numbers), so any tool that sorts SemVer sorts builds correctly.
- **One version per commit and context**: `-rc.<n>` is unique per main commit on a linear history;
  PR and local forms carry the sha, so two pushes of one PR never collide.
- **No build metadata**: `+` is illegal in Docker tags. The script maps illegal characters to `-`, trims
  leading `.`/`-` and cuts at 128 characters.
- **Edge case**: a sha7 of digits only with a leading zero (about 1 commit in 270) is not a valid SemVer
  identifier; npm and PEP 440 silently normalise `0123456` to `123456` in PR/local versions. Image tags and
  release/rc versions are unaffected.

## 5. Image tag scheme

| Event | Tags on the digest | Mutable | Lifetime (retention) | Written by |
|---|---|---|---|---|
| PR build | `pr-<n>-<sha7>` | no | PR closed + 7 days | PR build (same-repository PRs only; forks cannot push) |
| main build | `<next>-rc.<n>`, `sha-<sha7>` | no | newest 20, and all younger than 30 days | main build job |
| main, tests passed | `main` | moves | while newest | main `publish` (`_promote.yml`) |
| hotfix build | `<patch>-rc.<n>`, `sha-<sha7>` | no | as rc | main workflow on `hotfix/**` |
| release | `X.Y.Z` (+ the existing `sha-<sha7>`) | no | forever | release.yml `promote` |
| release, newest of its series | `X.Y`, `X`, `latest` | move | while newest | release.yml `promote` |
| laptop | `local`, `<version>` | local only | never pushed | developer |

- One immutable version tag and one `sha-<sha7>` tag per commit; `retag-image.sh` refuses to move them.
- `sha-<sha7>` joins an image to its commit (and to the `org.opencontainers.image.revision` label); the
  release workflow finds the tested image through it.
- Moving tags are for humans and dev only. qa and prod configuration pins `X.Y.Z` plus the digest; a lint
  on the config tree can reject moving tags outside dev (skill gha-config-deploy).
- OCI labels are written at build time (`version`, `revision`, `source`, `created`). A promoted image keeps
  its `-rc.<n>` version label: the accepted price of never rebuilding. Identify a release by its tag or by
  `revision`, not by the version label.

## 6. Version lines

A version line is a tag prefix plus, optionally, the paths whose commits decide its bump.

- **One line (`v`) by default**: everything releases together (lockstep); one number in change tickets.
  Unchanged images still get the new version by retagging their existing digest, never by rebuilding.
- **A second line** (`<dir>/v`, commits under `<dir>/`) only for a unit with its own cadence. The
  reference's criteria to split: a different release cadence for two quarters, a stable shared API, a
  different owning team, operations accepting a compatibility matrix instead of one number.
- Commands for a root line plus `server/`:
  ```bash
  scripts/ci/git-version.sh                                      # root line, every commit counts
  scripts/ci/git-version.sh --path . --path ':(exclude)server'   # root line without server-only commits
  scripts/ci/git-version.sh --prefix server/v --path server      # the server line
  ```
  Match release-please: its root package sees every commit unless `exclude-paths` lists `server`; a
  package at `server` sees commits touching `server/`. The reference counted every commit for its root line.
- The build must compute the version **per image**: the reference mapped each Gradle project to its line
  in a settings plugin. A build that computes one version for all images fits a single line only.
- Go uses the same convention for nested modules (`<dir>/vX.Y.Z`), so Go module tags and image lines agree.

## 7. git-version.sh in practice

```bash
scripts/ci/git-version.sh                          # KEY=value facts; what a laptop build gets
scripts/ci/git-version.sh --ci --ref main          # what main would build from this checkout
scripts/ci/git-version.sh --field version          # the version alone (build tools, release assert)
scripts/ci/git-version.sh --field tags             # "1.5.0-rc.7 sha-2b3c4d5 main"
scripts/ci/git-version.sh --format json            # one object (kind, base_tag, distance, next, bump, ...)
scripts/ci/git-version.sh --format github >> "$GITHUB_OUTPUT"   # version, kind, tags (JSON list), ...
```

In a workflow job that computes a version:

```yaml
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0            # tags and history; the script exits 4 on a shallow clone in CI
      - id: version
        env:
          PR_NUMBER: ${{ github.event.pull_request.number }}
        run: scripts/ci/git-version.sh --ignore-head-tags --format github >> "$GITHUB_OUTPUT"   # main builds
```

Exit codes: 0 ok, 2 usage, 3 not a git work tree or no commit, 4 shallow clone in CI (`--allow-shallow`
accepts it). If you compute the version inside a build plugin with git instead, use `git describe --tags
--abbrev=0 --match '<prefix>[0-9]*.[0-9]*.[0-9]*' --exclude '<prefix>*-*'`: `--tags` because release-please
creates lightweight tags, and the prefix inside `--exclude` for the dashed-prefix reason above.

## 8. Feeding the version into the build

Compute it once per build from git and pass it in; never commit it back into a file.

**Gradle** (verified with Gradle 9.8 and the configuration cache: the command re-runs on every build and a
new commit invalidates the cache entry). Root `build.gradle.kts`:

```kotlin
val gitVersion: String = providers.exec {
    commandLine("bash", "scripts/ci/git-version.sh", "--field", "version")
}.standardOutput.asText.get().trim()
allprojects { version = gitVersion }

tasks.register("printVersion") {      // the release workflow's version command: ./gradlew -q printVersion
    val v = gitVersion                // a plain value, so the configuration cache does not capture the script
    doLast { println(v) }
}
```

For several lines, pass `--prefix`/`--path` per project. The reference did this in a settings plugin
(`gradle.lifecycle.beforeProject`) that also exposed kind, tags and sha as extra properties.

**Maven** (CI-friendly versions, Maven 3.5+): `<version>${revision}</version>` with a laptop default
`<revision>0.0.0-SNAPSHOT</revision>` in `<properties>`; CI runs `./mvnw -B -Drevision="$VERSION" verify`.
Add flatten-maven-plugin when poms are deployed. Maven sorts unknown qualifiers (`-pr.`, `-local.`) above
the release, so never deploy PR or local builds to a Maven repository.

**npm / pnpm**: `npm version "$VERSION" --no-git-tag-version` in the CI workspace (edits `package.json`,
never committed; works in pnpm workspaces per package), or pass it to the bundler as `APP_VERSION`.

**Go**: `go build -ldflags "-X main.version=$VERSION" ./cmd/app`. Module versions are the git tags
themselves (`vX.Y.Z`; `<dir>/vX.Y.Z` for a nested module; `/v2` in the module path from 2.0.0 on).

**Python**: PEP 440 differs from SemVer. Map, then hand the result to setuptools-scm / hatch-vcs with
`SETUPTOOLS_SCM_PRETEND_VERSION`, or write an untracked `_version.py` at build time:

```bash
py_version=$(sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)-rc\.([0-9]+)$/\1rc\2/;
  s/^([0-9]+\.[0-9]+\.[0-9]+)-(pr|local)\.([0-9]+)\.(.+)$/\1.dev\3+\2.\4/' <<<"$VERSION")
# 1.5.0-rc.7 -> 1.5.0rc7 ; 1.5.0-pr.123.1a2b3c4 -> 1.5.0.dev123+pr.1a2b3c4 ; 1.5.0 -> 1.5.0
```

Image tags keep the SemVer form in every case.

**Container images** (any build tool):

```bash
eval "$(scripts/ci/git-version.sh)"   # VERSION, IMAGE_TAGS, GIT_SHA, ...
args=(); for t in ${IMAGE_TAGS//,/ }; do args+=(--tag "$REPO:$t"); done
docker buildx build "${args[@]}" --push \
  --label "org.opencontainers.image.version=$VERSION" \
  --label "org.opencontainers.image.revision=$GIT_SHA" \
  --label "org.opencontainers.image.source=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY" .
```
