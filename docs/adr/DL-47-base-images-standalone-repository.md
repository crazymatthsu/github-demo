# DL-47 — The company base images live in a standalone base-image repository

| | |
|---|---|
| Status | Accepted (v1.11, 2026-10-05); amends DL-42 (a fourth repository kind) and the "built by" of DL-13 / DL-28 |
| Date | 2026-10-05 |
| Blocking for demo skeleton | no — the demo monorepo keeps its `docker/base/` and `base-image.yml` until it consumes the new images (D12 §8) |
| Demo | `github-cicd-simple-base`: `docker/base/{jre21,ci-build}`, `docker/ca`, `verify.args` per image, `pr.yml` / `base-image.yml` / `_build-image.yml` (ADR B-0001 there) |

## Context

DL-13 and DL-28 decided one company runtime base (`jre21`) under every app image and one pinned build image
(`ci-build`) for every build job, both built by a `base-image.yml` workflow. The demo built them in the
monorepo, next to the apps, and the apps repository extracted by DL-42 kept consuming
`ghcr.io/<org>/base/*` from there. A base image is a platform concern with its own owners (platform team;
security for the CA bundle), its own cadence (weekly rebuilds for OS and JDK patches, tool bumps, CA
rotation) and the widest blast radius in the estate: every app image and every build job. The platform owner
wants it in a repository that does nothing else — builds base images for Java 21 applications and lets
toolchains be added to them — with `main` behind pull requests and one human approval, like every other
repository.

## Decision

1. **A fourth repository kind, `base`** (D12 §6.1, §6.6): `<org>/<base>` holds the Dockerfiles of the company
   base images, the CA bundle (the build context), the outside verification and the publishing workflow, and
   nothing built on them. It deploys nothing and has no release line: its images are versioned by their dated
   tags `<yyyymmdd>-<run>` alone, so no job needs `contents: write`.
2. **Images are `<registry>/<project>/<name>`**, the project being the repository (D12 §6.7 naming): for the
   demo `ghcr.io/crazymatthsu/github-cicd-simple-base/jre21` and `…/ci-build`. New names, not `base/*`: GHCR links
   a package to the repository that first pushed it and only that repository's token may push to it; the same
   reasoning gave the apps their names (R-0001 in the apps repository).
3. **One image per directory, declared once.** `docker/base/<name>/Dockerfile` is the image and the workflows
   derive their matrix from the tree; `docker/base/<name>/verify.args` declares what the image promises — the
   arguments of `verify-image.sh`, run against the built image before any push (user, every bundle
   certificate in both trust stores, tools, TLS through the OS store).
4. **A toolchain is one block of `ci-build`**: a version `ARG` under a `# renovate:` hint, one checksum-verified
   install, one self-check line, one `--check` in `verify.args`. A toolchain that would double the image, or
   that one consumer alone needs, becomes an image of its own in the same repository (so does another JDK line).
5. **Proven in the pull request, published from `main`.** The pull request builds and verifies every image
   without pushing and reports the one required check; `main` builds, verifies and publishes, weekly without the
   layer cache and on demand (one image, a CA bundle version, no cache). Both call one reusable workflow, so
   what the pull request proved is what `main` publishes. Dated tags are immutable; `latest` moves only after
   the dated tag was pushed and resolves to the same digest.
6. **Consumers move with their next base bump**: `BASE_IMAGE`, the `ci-build` probe and `CI_BUILD_IMAGE`
   point at the new names; the local bootstrap build of a base image (`setup-build-env`) is no longer needed
   once the base repository has published.

## Alternatives considered

- **Keep the base images in the monorepo / in platform-ci** and grant the consumers read access: one less
  repository, but every base change rides another repository's pull-request flow, reviewers and cadence,
  and platform-ci's version line (semver, consumed by major) has nothing to do with a dated image.
- **Build the base images inside each consumer** (the bootstrap path of `setup-build-env`, made permanent):
  no shared image to publish, but N copies of the CA and toolchain steps drift and a CA rotation touches
  every repository — the problem DL-13 was decided to avoid.
- **Keep the package names `base/*`** by granting the new repository write access to the monorepo's packages:
  no consumer change, but the packages stay linked to a repository that no longer owns them and break the
  `<registry>/<project>/<name>` rule.
- **A `toolchains/<tool>.sh` layer composed by a build argument**: composable, but each pinned, verified
  install already is one block, and a script layer hides the pins from hadolint and Renovate.

## Consequences

- D12 §6.1 (four kinds), §6.6 (`kind: base`), §8; D3 §8 and this ADR's notes on DL-13, DL-28 and DL-42; D0 and
  TODO.md §6 / §10 are revised.
- `github-cicd-simple-base` is created with the two images, their verification and pipeline (B-0001 there).
  Its settings follow D12 §6.10: a ruleset on `main` (pull request, one approval, required check `pr-gate`,
  linear history, no bypass); the GHCR packages' visibility after the first publish.
- `github-cicd-simple-apps` points its base references at the new names in a follow-up; the demo monorepo
  keeps `docker/base/` and `base-image.yml` until it consumes the new images, then removes them.
- The platform's `gha-build-images` skill keeps describing the in-repository form; the base-repository form
  is this ADR plus the new repository's `docs/toolchains.md`.

## References

- TODO.md §5.3, §5.11, §6 (DL-47), §10 (v1.11)
- D3 §5 (1), §6.1–§6.3, §8; D10 §5; D12 §6.1, §6.6, §6.7, §6.10, §8; DL-13, DL-28, DL-42
- `github-cicd-simple-base`: ADR B-0001, `docs/toolchains.md`
