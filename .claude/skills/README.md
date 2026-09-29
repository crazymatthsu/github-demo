# Portable CI/CD skills for GitHub Actions

Six Claude Code skills distilled from this repository's GitHub Actions pipeline: its workflows, composite
actions, scripts and the lessons learned running them. Copy them into another project and ask Claude to build,
extend or review that project's pipeline; Claude reads the matching skill and applies its principles, procedure
and templates. Nothing in the skills depends on this repository.

## The skills

| Skill | Use it for |
|---|---|
| [`gha-pipeline-design`](gha-pipeline-design/SKILL.md) | **Start here.** Event model (push, PR, merge queue, main, tag, schedule), thin trigger workflows over reusable `_*.yml` workflows and composite actions, the single required gate check, concurrency, permissions, validation, and diagrams of what runs when. Templates `pr.yml`, `main.yml`, `_build.yml`. Routes to the others. |
| [`gha-affected-builds`](gha-affected-builds/SKILL.md) | Monorepo change detection: a path map, "unmapped means build everything", docs-only and config-only fast paths, the integration-test matrix. Ships `affected.py` and its composite action. |
| [`gha-versioning-release`](gha-versioning-release/SKILL.md) | Versions from git tags and Conventional Commits, the image tag scheme, build once and promote the tested digest, the release workflow (SBOM, GitHub Release, bump PR), registry retention, release-please as an option. Ships `git-version.sh`, `retag-image.sh`, `resolve-image.sh`. |
| [`gha-ephemeral-test-envs`](gha-ephemeral-test-envs/SKILL.md) | Throwaway docker compose stacks and kind clusters inside CI jobs with a teardown guarantee, diagnostics, Helm release tests, and the nightly teardown drill. |
| [`gha-build-images`](gha-build-images/SKILL.md) | The pinned CI build image the build job runs in, runtime base images with the enterprise CA, checksum-pinned tools, the first-run bootstrap, container-job gotchas. |
| [`gha-config-deploy`](gha-config-deploy/SKILL.md) | Configuration as code per env / flow / app / instance, config lint, deploy-dev after main with a deployed-tag write-back and loop guard, qa/prod through bump PRs deployed behind GitHub Environment approvals, Helm per instance, host pools. Ships `write-back-tag.sh`, `set-image-tag.sh`, `helm-deploy-instance.sh`. |

## Install them in another project

- **For one repository**: copy the six folders into `<repo>/.claude/skills/` and commit them, so everyone working
  on that repository with Claude Code gets them.
- **For all your repositories**: copy them into `~/.claude/skills/`.
- Keep the set together: `gha-pipeline-design` routes to the other five, and the templates call each other's
  files by path. A missing companion only means that part is left out.
- Claude Code loads skills when a session starts: start a new session after copying.

## Use them

Ask for the outcome in your own words, for example:

- "Set up CI/CD with GitHub Actions for this repo: PR checks, build the images, deploy dev from main."
- "Our PRs sometimes can't merge because a required check never reports. Fix the workflows."
- "Add integration tests against Postgres to the pipeline, and make sure the containers are always cleaned up."
- "How should we version and release the images? We want to promote what we tested."
- "Deploy staging and prod only after approval, with exactly the image dev tested."

Claude picks the skill from its description; you can also name it (`/gha-pipeline-design`). Each skill tells
Claude to read the repository first, ask only what the repository cannot answer, generate from its templates,
and validate (actionlint, ShellCheck, hadolint, script tests) before handing over.

## Where they came from

The reference implementation is this repository: `.github/workflows/`, `.github/actions/`, `scripts/ci/`,
`test-infra/`, `docker/base/`, `config/` and the design documents in `docs/` (D1 to D11, decision log DL-01 to
DL-39). When the pipeline here changes in a way worth reusing, update the matching skill in the same pull request.
