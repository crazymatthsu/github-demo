# Pinning: versions, checksums, digests, tags

Read this when choosing how a tool or image is pinned, when setting up Renovate for the base images, and
when deciding between per-run digests and digests committed to git.

Contents: 1 What to pin where · 2 Versions as build args · 3 Checksums · 4 Renovate · 5 Digests per run ·
6 Base image tags · 7 The weekly rebuild · 8 hadolint · 9 Multi-arch

## 1. What to pin where

| What | Where | Form | Moves by |
|---|---|---|---|
| Upstream toolchain / runtime image | `TOOLCHAIN_IMAGE`, `RUNTIME_IMAGE` ARG defaults | tag (patches arrive with the weekly rebuild), or `tag@sha256:...` for controlled updates | weekly rebuild; or a Renovate digest PR |
| Tool images used as build stages (hadolint, shellcheck, yq, crane) | ARG + `FROM ...:${VERSION} AS <stage>` | tag, optionally `@sha256:` | Renovate (`# renovate:` hint) |
| Release binaries (helm, kubectl, kind) | ARG | exact version, SHA-256 from the project (or pinned in git) | Renovate |
| Docker CLI, compose, buildx | ARG | exact apt package version; repository key checked by fingerprint | Renovate or by hand, the three together |
| OS packages (ca-certificates, curl, git, jq, tzdata) | not pinned | whatever the archive has at build time | the weekly rebuild |
| Tools of host jobs | `ci/versions.env` | the same versions as the image ARGs (`check-pins.sh`) | Renovate, one PR for both files |
| Company base images in app builds | not in git: resolved per run | `repo@sha256:...` from `latest` | every run (probe job) |
| The CI image of the build job | not in git: resolved per run | `repo@sha256:...` | every run (probe job) |
| The CI image for laptops and compose | `ci/versions.env` | `tag@sha256:...` | Renovate |
| Test dependency images | compose versions file | `tag@sha256:...` | Renovate (gha-ephemeral-test-envs) |
| Third-party actions | workflows | major tag (`@v4`), or a full commit SHA for stricter control | Renovate / Dependabot |

Why OS packages stay unpinned: pinned Debian and Ubuntu package versions disappear from the archive when a
fix lands (the build then breaks), and the weekly rebuild exists precisely to take the fixes. The Docker
packages come from Docker's own repository, which keeps old versions, so they are pinned.

## 2. Versions as build args

- One `ARG` per tool, under a `# renovate:` hint: a bump is a one-line diff.
- An `ARG` before the first `FROM` is visible only in `FROM` lines; redeclare it (`ARG TOOLCHAIN_IMAGE`) after
  `FROM` to use it in `LABEL` or `RUN`.
- A build arg in the workflow overrides a default for one run (`CA_BUNDLE_VERSION` on a dispatch); keep the
  defaults in the Dockerfile so a laptop build equals the CI build.
- Never pass secrets as build args: they stay in the image history. Registry credentials come from the
  engine's login.

## 3. Checksums

Where each project publishes its sum (the templates use these):

| Tool | Download | Published sum |
|---|---|---|
| helm | `https://get.helm.sh/helm-<v>-linux-<arch>.tar.gz` | `<file>.sha256sum`: `<hash>  <file>` |
| kubectl | `https://dl.k8s.io/release/<v>/bin/linux/<arch>/kubectl` | `<file>.sha256`: the hash only |
| kind | `https://github.com/kubernetes-sigs/kind/releases/download/<v>/kind-linux-<arch>` | `<file>.sha256sum`: `<hash>  <file>` |
| kubeconform | `.../yannh/kubeconform/releases/download/<v>/kubeconform-linux-<arch>.tar.gz` | `CHECKSUMS`: one line per file |

The check refuses a missing or malformed sum as well as a wrong one:

```bash
verify() { [[ $1 =~ ^[0-9a-f]{64}$ ]] || { echo "no SHA-256 published for $2" >&2; return 1; }; echo "$1  $2" | sha256sum -c --quiet -; }
```

A sum fetched next to the file protects against truncated downloads, corrupt mirrors and renamed assets, not
against a compromised host that serves both. Pinning the sums in git closes that gap, at the price of a
manual step per bump (Renovate cannot compute them):

```dockerfile
ARG HELM_VERSION=v4.3.0
ARG HELM_SHA256_AMD64=<64 hex from the release page>
ARG HELM_SHA256_ARM64=<64 hex>
RUN case "${arch}" in amd64) sum="${HELM_SHA256_AMD64}" ;; arm64) sum="${HELM_SHA256_ARM64}" ;; esac \
 && verify "${sum}" "${tmp}/${helm_tgz}"
```

Behind an enterprise mirror (artifact repository remotes), pinned sums are the norm: the mirror is one more
party that could serve the wrong bytes. Where projects publish signatures (Sigstore / cosign, GPG), verifying
them is stronger still; the templates stop at checksums.

Apt repositories: check the key before apt trusts it.

```bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
gpg --batch --show-keys --with-colons /etc/apt/keyrings/docker.asc > /tmp/key.colons   # a file, not a pipe:
grep -q '^fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:' /tmp/key.colons       # grep -q + pipefail can SIGPIPE
```

## 4. Renovate

The hint above each pin names the datasource and the package; one regex manager reads the base Dockerfiles
and `ci/versions.env`:

```json
{
  "customManagers": [
    {
      "customType": "regex",
      "description": "Pins under a `# renovate:` hint in the base Dockerfiles and ci/versions.env.",
      "managerFilePatterns": ["/(^|/)docker/base/[^/]+\\.Dockerfile$/", "/(^|/)ci/versions\\.env$/"],
      "matchStrings": [
        "# renovate: datasource=(?<datasource>[a-z-]+) depName=(?<depName>\\S+)(?: extractVersion=(?<extractVersion>\\S+))?\\s*\\n(?:ARG )?[A-Z0-9_]+=(?<currentValue>\\S+)"
      ]
    }
  ],
  "packageRules": [
    {
      "description": "Company base images are tagged <yyyymmdd>-<run>.",
      "matchDatasources": ["docker"],
      "matchPackageNames": ["ghcr.io/acme/base/**"],
      "versioning": "regex:^(?<major>\\d{4})(?<minor>\\d{2})(?<patch>\\d{2})-(?<build>\\d+)$"
    },
    {
      "description": "kind's release decides the Kubernetes node image; kubectl follows it.",
      "matchPackageNames": ["kubernetes-sigs/kind", "kubernetes/kubernetes"],
      "groupName": "kind and kubectl"
    }
  ]
}
```

- `extractVersion=^v(?<version>.+)$` in a hint strips the `v` of tags such as `v29.8.1` when the ARG holds
  `29.8.1` (the Docker packages).
- The same dependency pinned in the Dockerfile and in `ci/versions.env` is updated in one PR, which keeps
  `check-pins.sh` green.
- The reference configured Renovate for its versions files and dated base tags; the Dockerfile pattern above
  generalises its hints and was not exercised there. Dry-run it before relying on it:
  `npx renovate --platform=local --dry-run=lookup` in the repository.
- With `tag@sha256:` pins, Renovate's `pinDigests` keeps the digests current.

## 5. Digests per run

The probe job resolves each moving tag once and hands the digest to every later job:

```bash
digest=$(docker buildx imagetools inspect "$NAMESPACE/base/ci-build:latest" --format '{{.Manifest.Digest}}')
echo "ci-build=$NAMESPACE/base/ci-build@$digest" >> "$GITHUB_OUTPUT"
# equivalents: crane digest <ref>; resolve-image.sh of gha-versioning-release (also reads RepoDigests)
```

Why: `base-image.yml` may publish while a run is in flight; with digests, the build job, the test runners and
the image builds of one run still share one environment. App images record the digest in
`org.opencontainers.image.base.name`, so each image names the base (and CA version) it carries.

| Model | Pros | Cons |
|---|---|---|
| **`latest` resolved per run** (default, as the reference ran) | patches reach every app on its next build; no bump PRs | a rebuild of the same commit can take a newer base (never an issue when releases promote the tested digest instead of rebuilding) |
| `FROM <base>:<yyyymmdd>-<n>@sha256:...` in git, bumped by Renovate | reproducible from git alone; each base change is reviewed | a bump PR per base rebuild (weekly) for every app |

The reference documented the second model as its target and ran the first: app Dockerfiles default to
`latest` and CI passes the resolved digest as `BASE_IMAGE`.

## 6. Base image tags

- `<yyyymmdd>-<run_number>`: sorts by date, unique per workflow run, and Renovate can compare it (regex
  versioning above).
- Immutable: GHCR has no tag-immutability setting, so `base-image.yml` refuses to push a dated tag that
  exists (a re-run of a published run fails on purpose; start a new run). Registries with immutable
  repositories (ECR `IMMUTABLE`) would also block moving `latest`: keep `latest` in a separate mutable
  repository there, or drop it and resolve the newest dated tag instead.
- `latest`: for the probe, bootstrapping and laptops; never let a build consume it unresolved.
- Retention: keep the most recent dated tags and every tag an image in use was built on (the label tells);
  delete the rest on a schedule (skill gha-versioning-release).

## 7. The weekly rebuild

- A schedule off the hour (`23 4 * * 1`): top-of-the-hour schedules queue longest.
- `no-cache: true` on scheduled runs: the cached `apt-get install` layer would otherwise be reused and the
  image republished with last week's packages. `pull: true` always, so a moved upstream tag is taken.
- Packages already in the upstream image are only updated when upstream rebuilds. To patch them sooner, add
  `apt-get upgrade -y` to the first `RUN` (hadolint no longer objects); the image then drifts from upstream.
- Downstream: with per-run resolution every app takes the new base on its next build; with pinned `FROM`
  lines Renovate opens the bump.
- In public repositories GitHub disables schedules after 60 days without activity, and schedules run only on
  the default branch: watch the workflow, or alert on the age of `latest` (label `org.opencontainers.image.created`).

## 8. hadolint

```yaml
# .hadolint.yaml
failure-threshold: style          # the templates pass at style; the reference ran `warning` for all Dockerfiles
trustedRegistries:                # FROM lines with a literal registry must use one of these
  - docker.io
  - gcr.io
  - ghcr.io                       # enterprise: only your registry's remotes, so bypassing the mirror fails
```

Rules the templates meet, and the inline suppressions they carry (each with its reason in the file):

| Rule | Meaning | In the templates |
|---|---|---|
| DL3008 | pin apt package versions | suppressed inline: OS packages float on purpose (section 1) |
| SC1091 | cannot follow a sourced file | suppressed inline: `. /etc/os-release` |
| DL4006 | set `-o pipefail` before a pipe | `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` |
| DL3002 | last `USER` is root (per stage) | no stage runs as root; the app's jar extraction writes under `/tmp` |
| DL3066 | non-numeric `USER` | numeric users (`USER ${RUNNER_UID}:${RUNNER_GID}`, `USER 10001:10001`) |
| DL3048 | invalid label key | why the label namespace is `com.example`, not a placeholder |
| DL3059 | consecutive `RUN`s (info level, fails at `style`) | each `RUN` is followed by a `COPY` or instruction of another kind |

`FROM ${ARG}` lines are not checked against `trustedRegistries`; check the ARG defaults in review.

## 9. Multi-arch

The Dockerfiles download for `TARGETARCH` (amd64 and arm64) and `base-image.yml` builds `linux/amd64`, as the
reference did. For both: add `docker/setup-qemu-action` and `platforms: linux/amd64,linux/arm64`. A
multi-platform image cannot be loaded into the classic image store, so "verify before push" becomes: build
and load each platform separately and verify it (`docker run --platform ...`), then build the index and push
it, or push to a staging tag, verify each platform by digest, and move the dated tag and `latest` with
`docker buildx imagetools create`. Not exercised in the reference.
