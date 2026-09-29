# Config lint: the checks, and how to run them

Read this when you set up, trim or review the linter of the config tree, or wire it into CI. The checks are
language-agnostic. The skill ships a configurable, tested implementation, `assets/scripts/config_lint.py`
(Python 3.8+, standard library, YAML through PyYAML or mikefarah yq), that runs checks 1 to 6 and 9 to 12 for
the deployment shape a repository declares in `.github/config-lint.yml` (section 3); start from it rather than
writing a linter from scratch. The reference implemented the same checks as one Gradle task in Kotlin
(`./gradlew configLint`), pure over the file system plus pluggable runners for `docker compose`, Helm and
kubeconform, so the rules are unit-tested with fixture trees. Keep the numbers stable: findings, docs and PR
comments refer to them.

## Contents

1. Output and exit codes
2. The catalogue (checks 1 to 13)
3. Running it: the shipped linter, required through the gate, and locally
4. Which checks apply: trimming the catalogue
5. Testing the linter

## 1. Output and exit codes

One finding per line, sorted by path: `<SEVERITY> check <n>  <path>: <message>` with `ERROR`, `WARN`, `TODO` (a
check not implemented yet says so instead of passing silently) or `INFO` (a check skipped on purpose, or one the
repository's deployment shape does not use, says so once). Exit 1 when any ERROR exists, 0 otherwise, 2 when the
linter cannot run (an option, the config file, no tree). Write the same lines to a report file
(`build/reports/config-lint/config-lint.txt`) for the job summary and the artifact. Report every finding in one
run rather than stopping at the first, so one push fixes them all, and never print the value a secret check
matched.

## 2. The catalogue

| # | Check | Prevents | Fails when (example) |
|---|---|---|---|
| 1 | Naming | tokens that break DNS labels, release names and dashboards | `config/us-dev/Payments/` (upper case); instance `2`; instance `ledger-db-to-the-central-data-warehouse` (39 characters, over 32); `<app>-<instance>` over 53; `config/us-dev/paymnts/` (flow not allow-listed); an unexpected file at the top of `config/` |
| 2 | Apps match deployables | a config directory nobody deploys, or an app nobody configured | `config/us-dev/payments/old-app/` with no project `old-app`; in an env that must be complete (`local`), a project `sync-app` without a directory |
| 3 | Required and forbidden files | an instance that cannot start, a stray env file | `ledger-db/` without `application.yml`, `compose.env` or `values.yaml`; `app-common/` without `application.yml` or `values.yaml`; a dev flow without `workflows-config.yml`; `compose.env` in `app-common/`; any `.env` file; YAML that does not parse; a nested directory in a layer |
| 4 | Identity restated | metrics and logs under the wrong name after a copy-paste | `compose.env` of `ledger-db` says `APP_INSTANCE=refunds-db`; `values.yaml` lacks `identity` or `env.APP_FLOW`; `image.tag: "0.2.0"` while `IMAGE_TAG=0.1.9`; `image.tag` or `identity` in `app-common/values.yaml`; `env:` holds a variable outside the app-facing subset; warn when `JAVA_OPTS` / `TZ` / `LOG_LEVEL_ROOT` differ between `compose.env` and the values `env:` |
| 5 | compose.env allow-list | application config or secrets smuggled into env vars | `SPRING_DATASOURCE_URL=...`; `CONNECTOR_PASSWORD=...`; `PROJECT=x` (set by the wrapper); `FOO=1` (not allow-listed); a line that is not `KEY=VALUE`; a key defined twice; `HTTP_HOST_PORT=80` (outside 1024-65535); `IMAGE_REPO` missing |
| 6 | Compose renders | a template or env file that only fails on the host | `docker compose -p lint-... --env-file compose.env -f <template> config --quiet` fails; supply a placeholder for every required `${VAR:?}` the tree does not define (the secrets), and the wrapper's own variables |
| 7 | Merged config is valid | a typo'd key or wrong type found at start-up in dev | layers 2 to 5 deep-merged in import order and validated against the app's schema (Spring: `spring-configuration-metadata.json`; unknown keys warn, wrong types fail). The reference reported it as TODO |
| 8 | Parity across envs | a key added in dev and forgotten in prod | key sets of the merged configuration of the same `<flow>/<app>/<instance>` differ between dev, qa and prod: missing in prod fails, in qa warns; attach the report to promotion PRs. The reference reported it as TODO |
| 9 | Secret scan | a credential in git history forever | a PEM private key, an AWS key id (`AKIA...`), a GitHub or Slack token, `password: hunter22` (a literal, not `${...}`), `;password=` in a JDBC URL, anywhere in `config/`; a secret property (`spring.datasource.password`) as a key in any YAML layer, whatever its value |
| 10 | Tag policy | a floating tag reaching an environment that must be reproducible | `IMAGE_TAG=latest`, `main` or `1.4` in a qa or prod env (must be `X.Y.Z`, optionally `@sha256:<digest>`); an invalid tag; `image.tag` not a string (unquoted `1.10`); `image.digest` not `sha256:<64 hex>`. Floating tags stay legal in dev and `local` |
| 11 | Deploy inventory | a deploy that skips an instance, or deploys one that no longer exists | see below |
| 12 | Helm renders and validates | a chart or values error found by `helm upgrade` in the deploy job | `helm lint` and `helm template` per instance with the exact flags the deploy uses (one script builds them for lint, template and deploy), then `kubeconform -strict -kubernetes-version <cluster version>` on the output. Run both: the reference found that `helm lint` skips the chart's `fail` guards (identity vs `env.APP_*`) and `helm template` enforces them |
| 13 | GitOps generator (when a controller is adopted) | an Application name the tree cannot produce | the ApplicationSet dry run yields names other than `<app>-<instance>`, or longer than 53 characters |

Check 11 in detail (one inventory per flow of a dev env, `config/<env>/<flow>/workflows-config.yml`):

- an env-level `config/<env>/workflows-config.yml` is an error; an inventory in a qa or prod env warns (ignored);
- `env` and `flow` equal the path; only the keys `env, flow, pool, defaults, targets` (and per target
  `instance, kind, host, user, cluster, namespace`) exist;
- every instance directory of the flow has exactly one target and every target has a directory ("inventory
  drift"): `targets[3]: payments/sync-app/old-db has no directory`, `instance sync-app/new-db has no target`;
- `kind` is `compose` or `helm`; a compose target has a `host` or its flow has a `pool`; a `host` under a pool is
  one of `pool.hosts`; every host is a lower-case DNS name or IPv4 address;
- `pool.hosts` is a non-empty list of unique hosts, `pool.user` a login name, `pool.root` an absolute path of
  plain segments (no `.` or `..`: it appears in rsync targets and SSH command lines); the same box in two flows'
  pools with the same `root` is an error (their bundles would overwrite each other);
- a helm target has a `cluster`, and its `namespace` (default: the flow) is a DNS label of at most 63 characters;
- `config/<env>/known_hosts`, when present, holds `ssh-keyscan` lines only (`<hosts> <key type> <base64>`),
  never a private key.

## 3. Running it: the shipped linter, required through the gate, and locally

The skill ships four files; copy them, then set the keys of the config file for your deployment shape (section 4):

| Skill file | Copy to | What it is |
|---|---|---|
| `assets/scripts/config_lint.py` | `scripts/ci/config_lint.py` | the linter: checks 1 to 6 and 9 to 12, one TODO line each for 7, 8 and 13; `--help` documents options, keys, exit codes |
| `assets/config-lint.example.yml` | `.github/config-lint.yml` | its settings, every key documented: allow-lists, env patterns, runtimes, `app_config`, chart and compose paths, the Helm adapter, `checks.skip` |
| `assets/scripts/config-lint-test.sh` | `scripts/test/config-lint-test.sh` | its plain-bash fixture test (section 5); the lint job runs `scripts/test/*-test.sh` |
| `assets/workflows/_config-lint.yml` | `.github/workflows/_config-lint.yml` | the reusable workflow CI calls (below) |

All repository knowledge lives in the config file, never in the script: nothing in `config_lint.py` needs editing,
and without the file the linter runs on the defaults (the reference's shape: Helm and compose everywhere,
`application.yml` layers, charts in `deploy/helm/<app>`) and warns that the env and flow allow-lists are off.
Check 12 runs `scripts/ci/helm-deploy-instance.sh <env> <flow> <app> <instance> --mode lint` and `--mode template`
(the skill's Helm adapter, over `helm-release.sh` of gha-ephemeral-test-envs) with `HELM_CHART_DIR` and
`HELM_CONFIG_DIR` from the config file, so a pull request lints exactly the flags the deploy installs with; then
`kubeconform -strict -summary` validates the rendered files. Check 6 runs `docker compose config --quiet` per
instance with the wrapper's variables (`wrapper_vars`) and a placeholder for every secret the host would pass.

Locally, from the repository root: `python3 scripts/ci/config_lint.py`, or with `--no-render` on a laptop without
docker, helm or kubeconform. Those tools are optional locally (a missing one is a WARN) and required in CI, where
`CI=true` turns the WARN into an ERROR, so a check never passes because it silently did not run.

In CI, make config lint a job of the pull-request pipeline whose result feeds the single required gate check
(see gha-pipeline-design), and run it on `main` before anything is published or deployed. Do not make a
path-filtered workflow a required status check on its own: on a PR that does not touch its paths it never
reports, and the PR waits for it forever. The affected-files map decides when it runs (config-only changes run
config lint and skip the build; see gha-affected-builds). `_config-lint.yml` checks out the repository, installs
the pinned helm and kubeconform through `./.github/actions/setup-kube-tools` (input `kube-tools`, default
`helm,kubeconform`; `''` when no env runs Helm), runs the linter with `CI: 'true'`, writes the report to the job
summary and its first 50 ERROR and WARN lines as annotations on the pull request's files, and uploads
`build/reports/config-lint/` as an artifact. The caller:

```yaml
jobs:
  config-lint:
    uses: ./.github/workflows/_config-lint.yml   # with: {kube-tools: ''} when no env runs Helm
    permissions:
      contents: read
  # the gate job lists config-lint in needs: and fails unless it succeeded (or was skipped on purpose)
```

Keep the rendered releases of check 12 (`build/reports/config-lint/rendered/<env>/<flow>/<app>/<instance>.yaml`)
in that artifact: reviewers of a chart change can diff what Kubernetes would receive. The wrapper that runs one
instance offline (`run-compose.sh <env> <flow> <app> <instance> validate` in the reference) should call the same
rules, so "validate on the box" and "lint in the PR" never disagree.

## 4. Which checks apply: trimming the catalogue

The catalogue describes the reference's shape: every instance rendered by both Helm and compose, apps reading the
`application.yml` layers, a deploy inventory per dev flow. Few repositories match it exactly. Trim it through the
config file, never by deleting rules: a check the shape does not use, or one listed in `checks.skip`, prints one
`INFO` line, so the report always shows what was not checked, and 7, 8 and 13 stay `TODO` lines until written.

| Deployment shape | Keys in `.github/config-lint.yml` | What changes | Checks that do not run |
|---|---|---|---|
| Helm only: clusters for every env | `runtimes: [helm]`; `chart_dir` | check 3 requires `values.yaml` in each instance and `app-common/` and rejects any `compose.env`; 4 checks `identity` and `env.APP_*`; 10 pins `image.tag` plus `image.digest`; 11 accepts helm targets only | 5 and 6 (INFO) |
| Compose only: hosts, no Kubernetes | `runtimes: [compose]`; `compose_file`; `wrapper_vars` | 3 requires `compose.env` per instance and rejects any `values.yaml`; 4 checks `APP_*` of `compose.env`; 10 pins `IMAGE_TAG=X.Y.Z` (optionally `@sha256:`); 11 accepts compose targets, hosts and pools | 12 (INFO); drop `kube-tools` in the workflow |
| Both: Helm on clusters, compose on hosts (the reference, the default) | `runtimes: [helm, compose]` for both files in every env, or `{helm: '.*', compose: '^(local\|([a-z][a-z0-9]*-)?dev)$'}` when compose runs only on laptops and dev hosts | a runtime's file is required only in the envs it runs, and an error where it does not; 4 also compares `image.tag` with `IMAGE_TAG` and warns when `env:` and `compose.env` disagree | none |
| Apps that read no config file (environment variables only) | `app_config: false`, with one of the rows above | `application.yml` becomes optional; `env:` and `compose.env` may carry the app's own variables (never a secret; compose knobs stay out of `env:`); `env.APP_*` are checked where set, the `identity` map stays required | 7 (INFO: no merged config to validate); 8 stays a TODO for the variables |
| GitOps without a dev inventory: a controller deploys dev too | `inventory: ''` | 3 no longer asks each dev flow for an inventory | 11 (INFO); 13 applies now: write the ApplicationSet dry run, or list 13 in `checks.skip` until then |
| Minimum viable first iteration | the allow-lists, `runtimes`, `app_config`; `checks: {skip: [6, 12]}`; `kube-tools: ''` in the workflow | only file checks run: no tool but python3, seconds per run, and they catch the costly mistakes (secrets, identity, floating tags in prod, inventory drift) | 6 and 12 (INFO) until `compose_file` and the Helm adapter exist; then remove them from `checks.skip` and restore `kube-tools` |

A Helm-only repository (dev deployed by CI through its inventory, staging and prod promoted by bump pull
requests, an API that reads no config file yet, charts in `deploy/helm/<app>`) needs no more than:

```yaml
envs: [dev, staging, prod]
flows: [orders]
runtimes: [helm]
app_config: false
checks:
  skip: [13] # no GitOps controller
```

Other keys cover the rest: `apps` when one chart serves every app or the directories must match the build's
projects, `complete_envs` for an env such as `local` that must hold every app, `compose_env_allow`,
`values_env_allow` and `secret_keys_allow` for reviewed exceptions, `tag_var` when the write-back uses another
variable than `IMAGE_TAG`, `kubernetes_version` and `kubeconform_args` for the clusters' API version and CRD
schemas. A check of your own gets the next number (14), one more method in the linter's check table and a test
case.

## 5. Testing the linter

Unit-test every rule with a minimal fixture tree per case (a good and a bad variant), with the compose, Helm and
kubeconform runners stubbed. Build fixtures inside the test, never by copying the live `config/`: the live tree
changes under the tests (the reference's pool tests went red once the first write-back recorded a `host` in the
live inventory).

`config-lint-test.sh` does this for the shipped linter: one good tree (a dev env with a pool, one compose and one
helm target, and a pinned prod env) that must pass without an ERROR, broken variants for every rule family of
checks 1 to 6 and 9 to 12 asserting the check number, the path and the exit code, one case per deployment shape
of section 4, stub replacements of the Helm adapter, kubeconform and docker that record their arguments (no
helm, cluster or daemon needed), and usage errors. It runs the whole suite once with PyYAML and once through yq
with PyYAML blocked. Credentials in its fixtures are assembled by string concatenation, so that neither push
protection nor the linter flags the test file itself. When you change a rule or add a key, add its case there.
