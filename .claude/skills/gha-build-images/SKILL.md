---
name: gha-build-images
description: 'Containerised CI and company base images for GitHub Actions: run the build job inside a pinned CI build image (`container:`) so CI, laptops and test runners share one toolchain; one runtime base image under every app image; an enterprise CA baked into the OS and JVM trust stores; tool versions pinned as build args with SHA-256-checked downloads; dated immutable tags plus latest, verified before push, rebuilt weekly; a bootstrap so the first run passes before any image exists. Use it for Dockerfiles, base-image workflows and container jobs, and when someone reports PKIX or self-signed certificate errors behind a proxy, `[[: not found` or docker.sock permission denied in a container job, root-owned workspace files, or CI that behaves unlike laptops.'
---

# Build images and containerised CI

## What this skill gives you

A build job that runs inside a pinned CI build image (the same image laptops and test-runner containers use),
a company runtime base image that every app image starts FROM, the enterprise CA in both trust stores of both
images, and one workflow that builds, verifies and publishes them with immutable dated tags and a weekly
rebuild. A bootstrap path keeps a brand-new repository green before any of these images exists.

## Principles

1. **Build inside a pinned CI build image.** The build job runs in `container:` with the company CI image
   (toolchain, CA, Docker CLI, kube tools, linters); test-runner containers and laptops (`docker run`) use the
   same image. Why: the environment is versioned and identical everywhere, nothing is installed per run, and a
   toolchain change is a reviewed image change instead of drift between runner images.
2. **One runtime base under every app image.** The CA, tzdata, curl, the non-root user and the directory
   layout live in `runtime-base.Dockerfile`; app Dockerfiles add only the application. Why: security-relevant
   lines are written once, there is one image to patch, scan and rotate, and app Dockerfiles stay reviewable.
3. **Bake the enterprise CA into both trust stores at build time.** Every certificate of the bundle goes into
   the OS store (curl, git, apt, OpenSSL clients) and into the JVM's default cacerts (Java reads only that);
   Node.js and Python get variables pointing at the OS bundle; the build verifies every certificate. Why: the
   image is self-contained (no runtime mount to forget on a laptop or in CI), and a missing import fails the
   build instead of a TLS handshake in production.
4. **Pin every version as a build arg and verify every download.** One `ARG` per tool under a `# renovate:`
   hint; binaries checked against their published SHA-256 sums; apt repository keys checked against their
   fingerprint; host-side pins (versions.env) equal to the image pins, enforced by `check-pins.sh`. Why: a bump
   is a one-line diff, a truncated or tampered download fails the build, and host jobs run the container's tools.
5. **Verify before publishing; dated tags are immutable.** Build and load, check from the outside
   (`verify-image.sh`), push `<yyyymmdd>-<run>` and `latest`, then prove `latest` has the dated digest; never
   overwrite a dated tag. Why: a broken image never becomes `latest`, and any consumer can name a known-good
   image forever.
6. **Rebuild weekly, without the layer cache.** A scheduled run with `no-cache` and `pull: true`. Why: OS and
   upstream patches only arrive through a rebuild, and a cached `apt-get install` layer silently republishes
   last month's packages.
7. **Resolve moving tags to digests once per run.** A probe job turns `latest` into `repo@sha256:...` and hands
   it to every job; app images record their base in `org.opencontainers.image.base.name`. Why: an image
   published mid-run cannot give two jobs different environments, and every app image names the exact base
   (CA version, patches) it carries.
8. **Plan the bootstrap.** A job's container image must exist before the job starts, so that job cannot build
   it. The probe outputs an empty image while nothing is published; the job then runs on the runner host with
   `setup-*` and builds the runtime base locally; after `base-image.yml` publishes, the next run moves into the
   container. Why: a new repository, a fork or a registry outage never deadlocks CI.
9. **Make the container job behave like the host.** `defaults.run.shell: bash`, the image user equal to the
   runner UID (1001 on GitHub-hosted runners), `--group-add` with the docker socket's GID,
   `container.credentials`, git `safe.directory`. Why: each missing piece fails the first containerised run at
   once, while every bootstrap run before it was green on the host (the shell did exactly that in production).
10. **Test a base-image change in the pull request that makes it.** `base-image.yml` builds and verifies on
    the PR without pushing, and the app build uses a locally built runtime base (`rebuild-base`) instead of the
    published one. Why: otherwise a broken Dockerfile or CA bundle is found after merge, by every consumer.
11. **Give the docker socket only to ephemeral runners.** The socket inside a job container is root on the
    host. Why: a GitHub-hosted (one-job) VM dies with the job; a persistent self-hosted runner keeps whatever a
    pull request left behind for the next job.

## Procedure

### 1. Discover from the repository

Read before asking:
- the toolchain and its version, the build tool and its build + test command;
- existing Dockerfiles and their `FROM` lines: CA, user or tzdata steps repeated across them belong in the
  runtime base; an existing company base image becomes `RUNTIME_IMAGE` / `TOOLCHAIN_IMAGE`;
- the registry and namespace (GHCR by default; JFrog, ECR, ACR only change `registry-login`);
- the runners: GitHub-hosted (UID 1001, ephemeral) or self-hosted (which UID? persistent?);
- an enterprise CA: TLS interception, internal endpoints with a private CA, where the bundle comes from
  (security team, artifact repository with a checksum), past `PKIX` / `self signed certificate` failures;
- jobs that need Docker: image builds (fine inside the container), compose stacks and kind (host jobs).

```bash
git ls-files | grep -E '(^|/)(gradlew|build\.gradle(\.kts)?|pom\.xml|package\.json|pnpm-lock\.yaml|pyproject\.toml|requirements[^/]*\.txt|go\.mod)$'
git ls-files | grep -iE '(^|/)(Dockerfile|Containerfile)[^/]*$|\.Dockerfile$' | xargs -r grep -n '^FROM'
grep -rnE 'container:|runs-on:|setup-(java|node|python|go)@' .github/workflows 2>/dev/null
git grep -nilE 'PKIX|self.signed certificate|unable to get local issuer|keytool -import|NODE_EXTRA_CA_CERTS'
```

Ask only what the repository cannot answer: usually the CA bundle's source and owner, and the runner UID of
self-hosted fleets.

### 2. Decide

| Decision | Default (proven form) | Alternatives |
|---|---|---|
| Where the build job runs | CI build image as `container:` | runner host + `setup-*` for a tiny repo with no CA and no CLIs to pin |
| CI image toolchain (`TOOLCHAIN_IMAGE`) | `eclipse-temurin:21-jdk` | `maven:3-eclipse-temurin-21`, `node:22`, `python:3.13`, `golang:1.25`, a company Debian/Ubuntu image |
| Runtime base (`RUNTIME_IMAGE`) | `eclipse-temurin:21-jre` | `node:22-slim`, `python:3.13-slim`, `debian:stable-slim` (Go); UBI and distroless: references/enterprise-ca.md |
| CA bundle source | committed `docker/ca/ca-bundle.pem`, CODEOWNERS security | fetched by version from an artifact repository, checked with `CA_BUNDLE_SHA256` |
| Base image tags | `<yyyymmdd>-<run_number>` (immutable) + `latest` | also pin `tag@digest` in git, bumped by Renovate |
| Base used by app builds | `latest` resolved to a digest once per run | `FROM` pinned `tag@digest` in git (references/pinning.md) |
| Registry login | GHCR with `GITHUB_TOKEN` | JFrog / ECR / ACR through OIDC (`registry-login` notes) |
| Docker socket in the job container | user 1001 + `--group-add <gid>` | `--user root` (ephemeral runners only); or build images in a host job |
| Platforms | `linux/amd64` | multi-arch (references/pinning.md) |

### 3. Create the files

| From this skill | To the target repository |
|---|---|
| `assets/docker/ci-build.Dockerfile` | `docker/base/ci-build.Dockerfile` |
| `assets/docker/runtime-base.Dockerfile` | `docker/base/runtime-base.Dockerfile` |
| the CA bundle (PEM, certificates only) | `docker/ca/ca-bundle.pem`, plus `docker/ca/README.md`: owner, subjects, SHA-256 fingerprints, version |
| `assets/docker/app.Dockerfile` | `<app>/Dockerfile`, one per app |
| `assets/workflows/base-image.yml` | `.github/workflows/base-image.yml` |
| `assets/actions/{setup-build-env,registry-login,setup-kube-tools}/action.yml` | `.github/actions/<name>/action.yml` |
| `assets/versions.env.example` | `ci/versions.env` |
| `assets/snippets/container-build-job.yml` | merged into the build workflow (step 5) |
| `scripts/verify-image.sh`, `scripts/check-pins.sh` | `scripts/ci/`, executable |

The image name is the Dockerfile's base name: `docker/base/<name>.Dockerfile` becomes
`<namespace>/base/<name>`. Add CODEOWNERS rules so base images and the CA need platform and security review:

```text
/docker/base/   @<org>/platform-team
/docker/ca/     @<org>/platform-team @<org>/security
```

### 4. Adapt the templates

1. Replace the placeholders; each template lists its own in the header. `__IMAGE_NAMESPACE__` must be
   lowercase (GHCR rejects uppercase; derive it with `${GITHUB_REPOSITORY_OWNER,,}` if needed).
2. Rename the label namespace `com.example` in both base Dockerfiles (a placeholder there breaks hadolint).
3. Set the toolchain for the stack (table below). The Dockerfiles need a Debian or Ubuntu base (apt).
4. Self-hosted runners whose user is not 1001: add `RUNNER_UID=<uid>` and `RUNNER_GID=<gid>` to the ci-build
   build args in `base-image.yml` and change its `--expect-uid`.
5. Enterprise registry: pull upstream images through its remote (`TOOLCHAIN_IMAGE`, `RUNTIME_IMAGE` and the
   tool stage images), set `registry-login` inputs, and list the remote in hadolint's `trustedRegistries`.
6. No private CA at all: delete the `COPY ${CA_BUNDLE_FILE}` line and the CA part of the following `RUN` in
   both base Dockerfiles (keep ci-build's user and self-check), and pass `--no-ca` to `verify-image.sh`.

| Stack | `TOOLCHAIN_IMAGE` (ci-build) | `RUNTIME_IMAGE` | setup-build-env `toolchain` / `toolchain-version` / `build-tool` | Build command in the container |
|---|---|---|---|---|
| Java + Gradle (proven) | `eclipse-temurin:21-jdk` | `eclipse-temurin:21-jre` | `java` / `21` / `gradle` | `./gradlew build --continue` |
| Java + Maven | `maven:3-eclipse-temurin-21` | `eclipse-temurin:21-jre` | `java` / `21` / `maven` | `./mvnw -B verify` |
| Node.js | `node:22` | `node:22-slim` | `node` / `22` / `npm` or `pnpm` | `npm ci && npm test` (pnpm: add `corepack enable` to the image) |
| Python | `python:3.13` | `python:3.13-slim` | `python` / `3.13` / `pip` | `pip install -r requirements.txt && pytest` |
| Go | `golang:1.25` | `debian:stable-slim` | `go` / `1.25` / `go` | `go build ./... && go test ./...` |

(Image names under `docker.io/library/`; fully qualified, because Podman requires it.)

### 5. Wire the build workflow

Merge `assets/snippets/container-build-job.yml` into the reusable build workflow (`_build.yml` of
gha-pipeline-design):
- add the `probe` job; give the `build` job `needs: probe`, the `container:` block (image, credentials,
  `--group-add`), `defaults.run.shell: bash`, and the `setup-build-env` step right after checkout;
- pass `--build-arg BASE_IMAGE="$BASE_IMAGE"` to every app image build, and remove `docker/setup-buildx-action`
  from that job: the engine's default builder sees a locally built base, a docker-container builder does not;
- add the `rebuild-base` input and feed it from change detection (`base-changed` of gha-affected-builds, whose
  path map lists `docker/base/**` and `docker/ca/**` under `base-images`), or from a paths filter;
- expose `needs.probe.outputs.ci-image` as a workflow output, so jobs that start test-runner containers use the
  same digest (gha-ephemeral-test-envs: input `test-runner-image`);
- keep jobs that run compose stacks or kind clusters on the runner host; they get tools from `setup-kube-tools`
  at the same pins as the image.

### 6. Bootstrap on GitHub, in this order

1. The PR that adds all this: `base-image.yml` builds and verifies both images without pushing; the probe
   finds nothing, so the build job runs on the host and builds the runtime base locally. Both must be green.
2. Merge. `base-image.yml` publishes on the path trigger; or run it by hand: `gh workflow run base-image.yml`.
3. GHCR packages start private: grant every repository that uses the base images read access (package
   settings, Manage Actions access), or make the packages internal or public.
4. The next run: the probe resolves `ci-build`, the build job runs in the container. Its summary line
   "Job container ... as 1001:1001 (groups ...)" proves the image, the UID and the socket group.
5. Pin laptops and compose files to the published `<tag>@<digest>` (`CI_BUILD_IMAGE` in `ci/versions.env`,
   `TEST_RUNNER_IMAGE` of gha-ephemeral-test-envs).

### 7. Keep it healthy

- Renovate: the `# renovate:` hints, the dated tag versioning and a group for kind + kubectl
  (references/pinning.md). Bump tool pins in the image and in `ci/versions.env` in the same PR.
- The PR lint job: hadolint on `docker/base/*.Dockerfile` and every app Dockerfile, `check-pins.sh`,
  ShellCheck on `scripts/ci/*.sh`.
- CA rotation is a rebuild cascade: references/enterprise-ca.md.
- Watch the weekly run; scheduled workflows stop after 60 days without repository activity (public repos).

## Templates and scripts

| File | Purpose | What to adapt |
|---|---|---|
| `assets/docker/ci-build.Dockerfile` | CI build image: toolchain, CA (OS + JVM), Docker CLI + compose + buildx (key fingerprint), helm/kubectl/kind (SHA-256), hadolint, shellcheck, yq, crane, jq, git, user 1001, self-check | `__CA_ALIAS__`, `__CA_BUNDLE_VERSION__`, `__VENDOR__`, `com.example`; `TOOLCHAIN_IMAGE`; versions |
| `assets/docker/runtime-base.Dockerfile` | runtime base: CA (OS + JVM), tzdata, curl, user 10001, `/app`, `/app/logs`, `/config` | same placeholders; `RUNTIME_IMAGE`; `APP_UID` |
| `assets/docker/app.Dockerfile` | app image FROM the runtime base: layered jar, non-root, HEALTHCHECK, exec entrypoint | `__IMAGE_NAMESPACE__`, `__APP_NAME__`; port, health path; other stacks at the end |
| `assets/workflows/base-image.yml` | build → verify → push dated + `latest` → `latest` == dated digest; PR build + verify; weekly without cache; dispatch with a CA version | `__IMAGE_NAMESPACE__`; matrix paths; verify arguments |
| `assets/actions/setup-build-env/action.yml` | toolchain on the host only, build-tool cache, base images from the registry or built locally; exports `BASE_IMAGE`, `CI_BUILD_IMAGE` | `__IMAGE_NAMESPACE__`; toolchain and build-tool defaults |
| `assets/actions/registry-login/action.yml` | one login for every job: GHCR token, OIDC stub with notes | `registry`, `mode` |
| `assets/actions/setup-kube-tools/action.yml` | pinned kind, kubectl, helm, kubeconform for host jobs, SHA-256 checked | nothing; reads the versions file |
| `assets/versions.env.example` | host-side pins equal to the image ARGs; the CI image pin for laptops and compose | `__IMAGE_NAMESPACE__`; versions |
| `assets/snippets/container-build-job.yml` | probe job + build job in the CI image (empty image = host bootstrap) | `__IMAGE_NAMESPACE__`, `__BUILD_COMMAND__`, `__IMAGE_BUILD_COMMAND__`, `__IMAGE_PUSH_COMMAND__` |
| `scripts/verify-image.sh` | checks a built image from the outside: non-root user (UID), every CA certificate in the OS store and JVM cacerts, tools, TLS; CI and laptops | nothing (options) |
| `scripts/check-pins.sh` | fails when a Dockerfile `ARG` pin differs from the versions file | nothing |
| `references/containerised-ci.md` | why, what the runner does, bootstrap, UID / socket / shell, Docker-outside-of-Docker limits, laptops, Podman, self-hosted runners | read when wiring container jobs |
| `references/enterprise-ca.md` | bundle handling and integrity, import per store and distribution, verification, rotation cascade | read when a CA is involved |
| `references/pinning.md` | what to pin where, checksums, Renovate, digests per run, tags, weekly rebuild, hadolint config | read when choosing pins and tags |

`setup-kube-tools` is the same action gha-ephemeral-test-envs ships (same inputs; it defaults to
`test-infra/kind/versions.env`, this copy looks for `ci/versions.env` first). Keep one copy per repository.

## Gotchas

Symptom → cause → fix.

- **`[[: not found` or `Syntax error: redirection unexpected` in the first `run:` step of a container job** →
  a job container ran the steps with `sh`, although the image had bash; host jobs default to bash, so every
  bootstrap run had been green → `defaults.run.shell: bash` on the job. This failed the first production run
  inside the freshly published CI image.
- **The job fails in "Initialize containers" with `manifest unknown`** → `container.image` names an image that
  is not published (new repository, deleted package) → resolve it in a probe job; an empty image runs the job
  on the host.
- **`denied` / `unauthorized` pulling the job container** → the runner pulls before the first step, so a login
  step is too late; another repository's token has no access to the package → `container.credentials`
  (`github.actor`, `secrets.GITHUB_TOKEN`) with `packages: read`; grant consuming repositories read access.
- **`permission denied while trying to connect to the Docker daemon socket`** → the image's non-root user is
  not in the socket's group, whose GID differs between runner images → the probe reads
  `stat -c %g /var/run/docker.sock` on the host; the job adds `options: --group-add <gid>`.
- **`EACCES` writing the workspace, `$HOME` (`/github/home`) or `$RUNNER_TEMP`; root-owned files break the next
  checkout on a self-hosted runner** → the container UID is not the runner's → `USER 1001` for GitHub-hosted
  runners; `RUNNER_UID` build arg or `--user <uid>` for other fleets; never leave root-owned files on a
  persistent runner.
- **`fatal: detected dubious ownership in repository`** → git in a container whose UID does not own the
  checkout → `git config --global --add safe.directory "$GITHUB_WORKSPACE"` (setup-build-env), and fix the UID.
- **No `.git` in the checkout; git-derived versions fail** → `actions/checkout` downloads a tarball when git is
  missing (or older than 2.18) in the container → git in the CI image.
- **Bind mounts made from the job container are empty; `localhost:<port>` is refused; kubectl cannot reach a
  kind cluster** → the socket is the host's daemon: mount sources and published ports resolve on the host,
  and kind's API server listens on the host's 127.0.0.1 → build images in the container (the context is
  streamed), run compose stacks and kind in host jobs with test runners on the stack network.
- **An app build fails with `pull access denied` for `<namespace>/base/runtime-base:bootstrap-...`** → a
  docker-container buildx builder (what `setup-buildx-action` makes the default) cannot see images loaded into
  the engine → build apps with the default `docker` driver, or pass the base with `--build-context`.
- **`PKIX path building failed` (Java), `self signed certificate in certificate chain` (Node.js, npm),
  `unable to get local issuer certificate` (curl, git, Python)** → the CA is missing from the store that
  client reads: Java only reads cacerts, Node.js its own roots, requests and pip certifi → both stores in the
  base images, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE` and `SSL_CERT_FILE` pointing at the OS bundle.
- **Only the first certificate of the bundle is trusted** → `update-ca-certificates` and `keytool` take one
  certificate per file → split the bundle, import and verify each certificate.
- **A certificate in the middle of the bundle fails to import, yet the build passes** → bash ignores `-e` in a
  loop that is part of an `&&` chain, and a loop returns only its last command's status → `|| exit 1` on each
  command in the loop, and verify every certificate from the outside (`verify-image.sh` matches fingerprints).
  The reference's import loop had this latent gap; the templates close it.
- **The weekly rebuild publishes the same packages** → BuildKit reused the cached `apt-get` layer → `no-cache`
  on scheduled runs and `pull: true` for the upstream base.
- **`latest` and the dated tag point at different digests, or a re-run overwrote a dated tag** → concurrent
  or re-run publishing → one publishing run at a time (never cancelled), refuse an existing dated tag, compare
  the digests after pushing.
- **Host jobs run other kind, kubectl or helm versions than the job container** → the pins live in two files →
  `check-pins.sh` in the PR lint job; bump both in one PR.
- **Checksum mismatch or "no SHA-256 published"** → a truncated download, a stale mirror, a renamed release
  asset → never skip the check; re-pin; pin the sums in git when downloads go through a mirror.
- **`docker-ce-cli=5:<version>-1~ubuntu.24.04~noble` has no installation candidate** → Docker's package
  version embeds the distribution; that version is not published for the base's release → choose a version
  `apt-cache madison docker-ce-cli` lists inside the base image; bump the three DOCKER_* pins together.
- **A base-image change passes its PR and breaks main** → the PR used the published images → `base-image.yml`
  on `pull_request` (build + verify) and `rebuild-base` for the app build.
- **HEALTHCHECK is missing from a Podman-built image** → the OCI image format has no HEALTHCHECK →
  `podman build --format docker`.

## Validation

Static checks, no container engine needed:

```bash
hadolint --failure-threshold style docker/base/*.Dockerfile <app>/Dockerfile
actionlint .github/workflows/base-image.yml .github/workflows/_build.yml
python3 -c 'import sys,yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/actions/*/action.yml
shellcheck --severity=style scripts/ci/verify-image.sh scripts/ci/check-pins.sh
scripts/ci/check-pins.sh docker/base/ci-build.Dockerfile ci/versions.env
grep -rn '__[A-Z0-9_]*__' docker .github ci scripts || echo "no placeholders left"
! grep -l 'PRIVATE KEY' docker/ca/*                   # the bundle holds certificates only
openssl crl2pkcs7 -nocrl -certfile docker/ca/ca-bundle.pem | openssl pkcs7 -print_certs -noout
```

With a container engine (a laptop):

```bash
docker buildx build -f docker/base/runtime-base.Dockerfile -t local/runtime-base:dev --load docker/ca
scripts/ci/verify-image.sh --kind runtime --tls-url https://github.com local/runtime-base:dev
docker buildx build -f docker/base/ci-build.Dockerfile -t local/ci-build:dev --load docker/ca
scripts/ci/verify-image.sh --kind ci-build --expect-uid 1001 local/ci-build:dev
docker buildx build -f <app>/Dockerfile --build-arg BASE_IMAGE=local/runtime-base:dev -t local/<app>:dev --load <app>
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/workspace" -w /workspace local/ci-build:dev ./gradlew build
```

On GitHub: the bootstrap PR green on the host, `base-image.yml`'s summary showing `latest` on the dated
digest, and the next build job's summary naming the job container and user 1001.

## Related skills

- **gha-pipeline-design**: the `_build.yml` the snippet merges into, the PR lint job (actionlint, ShellCheck,
  hadolint, `check-pins.sh`), permissions, the single gate check.
- **gha-affected-builds**: the `base-images` section of the path map raises `base-changed`, which feeds
  `rebuild-base`.
- **gha-versioning-release**: app image tags, promotion by digest, `resolve-image.sh`, package access and the
  retention of dated base tags.
- **gha-ephemeral-test-envs**: compose stacks and kind clusters in host jobs, the test-runner service started
  from the CI build image, the same `setup-kube-tools` action.
- **gha-config-deploy**: deployments of the app images built on these bases.

Without a companion skill, the part it covers is left out: say which skill would add it.

## Provenance

Distilled from the reference repository crazymatthsu/github-demo, where this ran green on GitHub-hosted
runners: `docker/base/ci-build/Dockerfile`, `docker/base/jre21/Dockerfile`, `.github/workflows/base-image.yml`,
the probe and container build job of `.github/workflows/_gradle-build.yml`, the composite actions
`setup-build-env`, `registry-login` and `setup-kube-tools`, `scripts/ci/resolve-image.sh`, `test-infra/ca/`,
the app Dockerfiles, `.hadolint.yaml`, design documents D3 and D10 and decisions DL-13, DL-14, DL-17, DL-18,
DL-19 and DL-28. Generalised here: any Debian/Ubuntu toolchain, the per-certificate `|| exit 1`, pull-request
verification, the immutable-tag guard, the no-cache weekly run and the two scripts. Nothing depends on that
repository.
