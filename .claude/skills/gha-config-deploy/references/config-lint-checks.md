# Config lint: the checks, and how to run them

Read this when you implement or review the linter of the config tree, or wire it into CI. The checks are
language-agnostic; the reference implemented them as one Gradle task in Kotlin (`./gradlew configLint`), pure over
the file system plus pluggable runners for `docker compose`, Helm and kubeconform, so the rules are unit-tested
with fixture trees. A Python 3 script (PyYAML, or `ruamel.yaml` to keep line numbers) or a Go binary works as
well. Keep the numbers stable: findings, docs and PR comments refer to them.

## Contents

1. Output and exit codes
2. The catalogue (checks 1 to 13)
3. Running it: required through the gate, and locally
4. Testing the linter

## 1. Output and exit codes

One finding per line, sorted by path: `<SEVERITY> check <n>  <path>: <message>` with `ERROR`, `WARN` or `TODO`
(a check not implemented yet says so instead of passing silently). Exit non-zero when any ERROR exists. Write the
same lines to a report file (`build/reports/config-lint/config-lint.txt`) for the job summary and the artifact.
Report every finding in one run rather than stopping at the first, so one push fixes them all.

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

## 3. Running it: required through the gate, and locally

Locally, with no CI-only dependency: `./gradlew configLint` in the reference; `python3 scripts/config_lint.py`
or `make config-lint` elsewhere. Helm and a compose CLI are optional locally (their checks warn when the tool is
missing) and required in CI (`CI=true` turns the warning into an error), so a laptop without Helm can still lint
the rest; the reference kept a missing kubeconform a warning everywhere and installed it in CI.

In CI, make config lint a job of the pull-request pipeline whose result feeds the single required gate check
(see gha-pipeline-design), and run it on `main` before anything is published or deployed. Do not make a
path-filtered workflow a required status check on its own: on a PR that does not touch its paths it never
reports, and the PR waits for it forever. The affected-files map decides when it runs (config-only changes run
config lint and skip the build; see gha-affected-builds). A reusable workflow the PR and main pipelines call:

````yaml
# .github/workflows/config-lint.yml
name: config-lint
on:
  workflow_call:
permissions:
  contents: read
jobs:
  config-lint:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7          # update to the current major when adopting
      # Install the pinned helm and kubeconform here (checksum-verified), e.g. your setup composite action.
      - name: Config lint
        run: ./gradlew configLint --continue   # or: python3 scripts/config_lint.py
        env:
          CI: 'true'
      - name: Report in the job summary
        if: always()
        run: |
          report=build/reports/config-lint/config-lint.txt
          [[ -f $report ]] || exit 0
          { echo "### config lint"; echo '```'; head -n 200 "$report"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
      - uses: actions/upload-artifact@v7
        if: always()
        with:
          name: config-lint-${{ github.run_id }}-${{ github.run_attempt }}
          path: build/reports/config-lint/**
          if-no-files-found: ignore
          retention-days: 7
````

Keep the rendered releases of check 12 (`build/reports/config-lint/rendered/<env>/<flow>/<app>/<instance>.yaml`)
in that artifact: reviewers of a chart change can diff what Kubernetes would receive. The wrapper that runs one
instance offline (`run-compose.sh <env> <flow> <app> <instance> validate` in the reference) should call the same
rules, so "validate on the box" and "lint in the PR" never disagree.

## 4. Testing the linter

Unit-test every rule with a minimal fixture tree per case (a good and a bad variant), with the compose, Helm and
kubeconform runners stubbed. Build fixtures inside the test, never by copying the live `config/`: the live tree
changes under the tests (the reference's pool tests went red once the first write-back recorded a `host` in the
live inventory).
