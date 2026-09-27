# Company base images

Two sibling images carry the enterprise CA (demo: `test-infra/ca/demo-root-ca.pem`) so that nothing
downstream has to (D3 §5 (1), §6.1; DL-13, DL-28).

| Image | Dockerfile | From | Adds | Used by |
|---|---|---|---|---|
| `ghcr.io/crazymatthsu/base/jre21` | `jre21/Dockerfile` | `eclipse-temurin:21-jre` | CA in the OS store and JVM `cacerts`, `tzdata`, `curl`, user `app` (10001:10001), `/app`, `/app/logs`, `/config`, `TZ=UTC` | `FROM` of every app image (`deephaven-connectors/<AppName>/docker/Dockerfile`) |
| `ghcr.io/crazymatthsu/base/ci-build` | `ci-build/Dockerfile` | `eclipse-temurin:21-jdk` | the same CA steps, Docker CLI with compose and buildx (Docker's apt repository), `helm`, `kubectl`, `kind`, `hadolint`, `shellcheck`, `yq`, `jq`, `git`, `curl`, `crane`, user `runner` (1001:1001), `WORKDIR /workspace` | the `build` job (`container:`) and the `it-runner` compose service (`test-infra/compose/it-runner.yml`) |

Both images label the bundle they carry: `com.example.ca-bundle=<CA_BUNDLE_VERSION>` (D3 §6.5). The
same label on an app image comes from its base. Tool versions are `ARG`s at the top of
`ci-build/Dockerfile`, so a bump is a one-line change. Both Dockerfiles pass
`hadolint --failure-threshold style`: the only suppressions are inline, for unpinned apt packages
(DL3008, see below) and for sourcing `/etc/os-release` (SC1091).

## Building

The build context is **the directory that holds the CA bundle**. Neither Dockerfile copies anything
else, so the context stays tiny and the same Dockerfile takes the enterprise bundle from another
directory.

```bash
tag=$(date -u +%Y%m%d)-1   # see "Tags" for <n>
docker buildx build -f docker/base/jre21/Dockerfile    -t ghcr.io/crazymatthsu/base/jre21:$tag    --load test-infra/ca
docker buildx build -f docker/base/ci-build/Dockerfile -t ghcr.io/crazymatthsu/base/ci-build:$tag --load test-infra/ca

# Podman: --format docker keeps Docker-format metadata such as HEALTHCHECK in derived images (D3 §6.7)
podman build --format docker -f docker/base/jre21/Dockerfile -t ghcr.io/crazymatthsu/base/jre21:$tag test-infra/ca
```

Build arguments (all optional):

| Argument | Default | Purpose |
|---|---|---|
| `TEMURIN_IMAGE` | `eclipse-temurin:21-jre` / `eclipse-temurin:21-jdk` | upstream base; enterprise: `artifactory.<company>.com/docker-remote/eclipse-temurin:21-jre@sha256:...` |
| `CA_BUNDLE_FILE` | `demo-root-ca.pem` | bundle file inside the build context (one or more PEM certificates) |
| `CA_BUNDLE_VERSION` | `demo-2026-09` | value of the `com.example.ca-bundle` label |
| `CA_ALIAS` | `demo-root-ca` | `cacerts` alias of the first certificate; later ones get `-02`, `-03`, ... |
| `IMAGE_VERSION`, `GIT_SHA`, `CREATED` | empty | OCI labels `version`, `revision`, `created`, set by the workflow |
| `DOCKER_VERSION`, `DOCKER_COMPOSE_VERSION`, `DOCKER_BUILDX_VERSION`, `HELM_VERSION`, `KUBECTL_VERSION`, `KIND_VERSION`, `HADOLINT_VERSION`, `SHELLCHECK_VERSION`, `YQ_VERSION`, `CRANE_VERSION` | see `ci-build/Dockerfile` | tool versions (`ci-build` only) |

Each build verifies itself. It fails unless `keytool -list -cacerts -alias <CA_ALIAS>` finds the CA
and `openssl verify` accepts every bundle certificate against the OS store; `ci-build` also runs
`--version` on every tool. After pushing, `base-image.yml` should also check the image from the
outside (D3 §6.2):

```bash
docker run --rm ghcr.io/crazymatthsu/base/jre21:$tag keytool -list -cacerts -storepass changeit -alias demo-root-ca
docker run --rm ghcr.io/crazymatthsu/base/jre21:$tag curl -sS -o /dev/null -w '%{http_code}\n' https://github.com
```

Apt packages (`ca-certificates`, `curl`, `tzdata`, `git`, `jq`, `gnupg`) are deliberately unpinned. The
weekly rebuild exists to pick up Ubuntu security fixes, and pinned versions vanish from the archive.
Docker's client packages are pinned (`ARG`s), and the repository key is checked against its published
fingerprint. `helm`, `kubectl` and `kind` are verified against the SHA-256 files their projects
publish. The enterprise pins those sums as `ARG`s and downloads through JFrog remotes.

## Tags

`<yyyymmdd>-<n>` (D3 §6.1): the UTC build date, and `n` = 1 + the number of tags already published for
that date (`crane ls ghcr.io/crazymatthsu/base/jre21 | grep -c "^$(date -u +%Y%m%d)-"`). Tags are
immutable and sort chronologically. Renovate bumps them in every app `FROM` line, and the bump PR
records the digest in a comment. `latest` follows the newest build for bootstrapping and local use
only. `test-infra/compose/versions.env` uses `ci-build:latest` until the first dated tag exists, and
should then move to it.

`base-image.yml` (CI workstream) builds both images on changes under `docker/base/**` or
`test-infra/ca/**`, weekly (OS patches), and on `workflow_dispatch` with an optional
`CA_BUNDLE_VERSION` (D3 §6.3).

## CA rotation

A rotation is a rebuild cascade, not a runtime mount (D3 §6.3, Figure 3; `test-infra/ca/README.md`):

1. The bundle gains the new root **next to** the old one. Both Dockerfiles import every certificate
   in the file, so both roots are trusted during the overlap.
2. `base-image.yml` rebuilds `jre21` and `ci-build` with a new `CA_BUNDLE_VERSION` and publishes new
   `<yyyymmdd>-<n>` tags.
3. One bump PR moves every app `FROM` to the new `jre21` tag. Merging rebuilds the apps
   (pre-release tags, `deploy-dev`), and a patch release carries them to qa and prod (D4, D9).
4. When every environment runs images labelled with the new `com.example.ca-bundle`, the old root
   leaves the bundle and the cycle runs once more.

`deephaven-server/docker/Dockerfile` imports the same bundle into the upstream Deephaven image's own
JVM (D3 §6.10), so it is rebuilt in the same cascade.

## First-run bootstrap

On a fresh repository neither image exists in GHCR, and the demo's first CI run must still pass
(contract: base images are prerequisites of the app images):

- **`jre21` for app images.** When `docker buildx imagetools inspect ghcr.io/crazymatthsu/base/jre21:<tag>`
  (or `crane manifest`) fails, the build job builds `jre21` itself with the command above and
  `--load`, with the GitHub Actions cache (`--cache-from/--cache-to type=gha,scope=base-jre21`). The
  app builds then resolve `FROM` from the local image store. That works with buildx's default
  `docker` driver; with a `docker-container` builder, pass the local image through
  `--build-context` instead.
- **`ci-build` for the `build` job.** A job's `container:` image must be pullable when the job starts,
  so it cannot be built inside that job. Run `base-image.yml` once (`workflow_dispatch`, or a push to
  `main` that touches `docker/base/**`) before the first PR. Alternatively, a preliminary job
  publishes `ci-build` when the tag is missing and hands its reference to `container:` through a job
  output.
- **Socket access in `container:` jobs.** The image runs as `runner` (1001), which matches the
  GitHub-hosted runner user, so the bind-mounted workspace keeps its owner. The mounted
  `/var/run/docker.sock`, however, belongs to the host's `docker` group, whose GID varies between
  runner images. Pass it with `options: --group-add <gid>` (read it with
  `stat -c %g /var/run/docker.sock` on the host), or run that job as root. Never do either on a
  persistent self-hosted runner (D10 §5.11).

The JFrog CLI (`jf`) and a Podman CLI, which D3 §6.10 lists for the enterprise image, are not
installed: the demo has no JFrog, and Podman parity runs on the host runner (D3 §6.7).
