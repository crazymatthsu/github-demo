# The config tree: layout, layers, identity, naming, secrets, renderings

Read this when you create or review the `config/` tree of a repository, decide where a setting belongs, or map
one instance to docker compose and to Helm.

## Contents

1. Layout
2. Layers and precedence
3. Environment variables or YAML: one canonical place per key
4. Identity: the path is the name
5. Naming rules
6. Secrets
7. One instance, two renderings (compose and Helm)
8. One Helm release per instance, one namespace per flow
9. Files other than application.yml

## 1. Layout

```
config/
  _common/<app>/application.yml             platform layer: the app's defaults in every env (optional)
  <env>/
    _common/application.yml                 env layer: every app of this env (optional)
    known_hosts                             reviewed ssh-keyscan lines of the env's hosts (dev envs with hosts)
    <flow>/
      workflows-config.yml                  deploy inventory of this env/flow (dev envs only; deploy-inventory.md)
      <app>/
        app-common/                         app-common layer: every instance of <app> in <env>/<flow>
          application.yml   values.yaml
        <instance>/                         instance layer: the only place two instances of <app> differ
          application.yml   values.yaml   compose.env
```

- `<env>` is a stage (`dev`, `qa`, `prod`) or `<region>-<stage>` (`us-dev`, `eu-prod`), plus `local` for
  laptops and CI test stacks. Automation keys on the suffix: only envs matching `^([a-z][a-z0-9]*-)?dev$` are
  deployed and written back by CI.
- `<flow>` is the business boundary that owns a set of instances (a domain, a product line, a team). It becomes
  the Kubernetes namespace and the unit of ownership (CODEOWNERS, host pools, sync windows).
- `<app>` is a deployable code base: one build-tool project, one image, one Helm chart, one compose template.
- `<instance>` is one running pipeline or service of that app with its own configuration.
- The tree carries nothing repository-specific, so it can move to its own repository later: only the
  deployer's checkout changes. The reference kept it in the monorepo, next to the code, so that a change and
  its config ship in one PR and config lint sees the app's configuration metadata.

## 2. Layers and precedence

Lowest to highest; a later layer overrides an earlier one key by key (deep merge of maps).

| # | Layer | In git | Mounted at (compose bind, Kubernetes ConfigMap) | Holds | Required |
|---|---|---|---|---|---|
| 1 | Built-in defaults | inside the artifact (`src/main/resources/application.yml`) | in the jar / image | safe, env-agnostic defaults; the import list | yes |
| 2 | Platform | `config/_common/<app>/application.yml` | `/config/platform/` | same value in every env (poll intervals, metric names) | no |
| 3 | Env | `config/<env>/_common/application.yml` | `/config/env/` | log format, region-wide endpoints | no |
| 4 | App common | `config/<env>/<flow>/<app>/app-common/application.yml` | `/config/common/` | endpoints shared by the flow's instances | yes |
| 5 | Instance | `config/<env>/<flow>/<app>/<instance>/application.yml` | `/config/instance/` | source, target, topic, table of this instance | yes |
| 6 | Secrets | never in git | `/secrets/` (Kubernetes Secret) or process env (compose) | credentials only | at runtime |
| 7 | Environment variables | `compose.env`, `values.yaml` `env:` | process env | deploy-time knobs only (section 3) | yes |

Keep it to four file layers (2 to 5). A fifth layer (for example flow-wide `config/<env>/<flow>/_common/`) makes
the effective value harder to predict than the duplication it saves.

Load the layers with an explicit, ordered import list in the built-in defaults, identical for every app, with
every file optional, instead of profile arithmetic. Spring Boot form (the proven one):

```yaml
spring:
  config:
    import:
      - optional:file:/config/platform/application.yml
      - optional:file:/config/env/application.yml
      - optional:file:/config/common/application.yml
      - optional:file:/config/instance/application.yml
      - optional:configtree:/secrets/
```

Why an import list and not profiles (`spring.profiles.active=us-dev,payments,ledger-db`): profile names collide
across dimensions, the merged result is implicit, and a misplaced `application-<profile>.yml` silently wins.
With a list, each file is its own visible property source (`/actuator/env`), a missing optional layer is skipped,
and compose and Kubernetes mount the same four directories. Other runtimes: read the same four paths in the same
order (Node `config` / `convict` with explicit files, Python `pydantic-settings` with a YAML source per path, Go
`koanf` / `viper` merging files in order). Pin the order with a test that starts the app with a key defined in
every layer and asserts the instance value wins. Spring ranks OS environment variables above every import, which
is harmless only because of the rule in section 3.

## 3. Environment variables or YAML: one canonical place per key

Environment variables are for deploy-time knobs that compose, the chart or the platform also consume. Everything
else is YAML. A key lives in exactly one place, so no precedence question ever arises between them.

| Variable (compose.env) | Consumed by | App-facing (allowed in `values.yaml` `env:`) |
|---|---|---|
| `IMAGE_REPO`, `IMAGE_TAG` | compose template `${IMAGE_REPO}/${APP_NAME}:${IMAGE_TAG}` | no: Helm uses `image.repository`, `image.tag` |
| `APP_ENV`, `APP_FLOW`, `APP_NAME`, `APP_INSTANCE` | compose project name, app identity | yes, must equal the path |
| runtime options (`JAVA_OPTS`; `NODE_OPTIONS`, `GOMEMLIMIT` elsewhere) | entrypoint | yes |
| `TZ`, `LOG_LEVEL_ROOT` | container, app via `${LOG_LEVEL_ROOT:INFO}` | yes |
| `*_HOST_PORT` | compose published ports (1024-65535; distinct per host) | no |
| `LOGS_DIR`, `DATA_DIR`, `MEM_LIMIT` | compose volumes and limits | no: Kubernetes uses `resources` and volumes |
| framework prefixes (`SPRING_*`, `LOGGING_*`, `MANAGEMENT_*`, your app's own prefix) | forbidden | forbidden: YAML, or a Secret for credentials |
| variables the launcher sets itself (`CONFIG_DIR`, `COMMON_DIR`, `PROJECT`) | the compose wrapper | never in a file |

Config lint enforces the allow-list (config-lint-checks.md, checks 4 and 5). Two instances of one app then differ
only in their instance `application.yml`, which is exactly what a reviewer wants to see in a diff.

## 4. Identity: the path is the name

`config/<env>/<flow>/<app>/<instance>/` is the identity tuple. Write it down again where the runtime needs it,
and let lint check that the copies equal the path (a copied directory with a stale `APP_INSTANCE` otherwise
reports metrics and logs under another instance's name):

- `compose.env`: `APP_ENV`, `APP_FLOW`, `APP_NAME`, `APP_INSTANCE`;
- instance `values.yaml`: an `identity: {env, flow, app, instance}` map and the same `APP_*` in `env:`.

Derive every other name from the tuple, never type it:

| Where | Name |
|---|---|
| compose project | `<env>-<flow>-<app>-<instance>`; CI test stacks prefix `ci-<run_id>-<attempt>-` |
| Helm release, Deployment, Service, ConfigMap, Secret | `<app>-<instance>` (+ `-config`, `-secrets`) in namespace `<flow>` |
| labels | `app.kubernetes.io/name=<app>`, `app.kubernetes.io/instance=<app>-<instance>`, `<your-domain>/env`, `/flow`, `/app`, `/instance` |
| log fields and metric tags | `env`, `flow`, `app`, `instance` from the `APP_*` variables |

## 5. Naming rules

| Token | Rule | Why |
|---|---|---|
| all tokens | `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (lower-case kebab, DNS-label safe) | they become DNS labels, label values, file names |
| `<env>` | allow-listed (`local`, `dev`/`qa`/`prod` or `<region>-<stage>`) | automation keys on the stage suffix |
| `<flow>` | allow-listed | a typo would create a new namespace and owner |
| `<app>` | equals a deployable project and its image; at most 20 characters | lint maps directories to projects |
| `<instance>` | a business name (source, optionally source-to-target), never a bare number, unique within `<env>/<flow>/<app>`, at most 32 characters | `instance-2` means nothing in a log line or an alert |
| `<app>-<instance>` | at most 53 characters | Helm's release-name limit (20 + 1 + 32) |
| `app-common`, `_common` | reserved | they are layers, not instances |

The same instance name may recur in another flow: the flow is part of the identity.

## 6. Secrets

Secrets never enter the tree, the host bundle, the Helm values or the logs.

- Contract: the app reads credentials under fixed property names (for example `spring.datasource.password`).
  Only the delivery differs.
- Compose: the template requires them (`${SPRING_DATASOURCE_PASSWORD:?set it in the shell}`) and the wrapper
  passes them through from the host's environment; `compose.env` may never define them (check 5). On a host pool
  every box holds the secret environment of every instance of its flow, provisioned outside git.
- Kubernetes: a `Secret` named `<app>-<instance>-secrets` with property-name keys, mounted read-only at
  `/secrets/` (Spring `configtree:`) or as env. Production creates it from a secret store (External Secrets
  Operator from Vault or a cloud secret manager); the chart only references it (`secrets.existingSecret`) and
  never templates a value. While no store exists, the deploy script creates it from CI secrets with
  `kubectl create secret ... --dry-run=client -o yaml | kubectl apply --server-side -f -` (server-side apply
  keeps the values out of the `last-applied-configuration` annotation) and masks them in every printed command.
- A rotated `Secret` does not change the pod template: restart with a Reloader-style controller or annotation;
  Helm's checksum annotation only covers the ConfigMap it renders.
- Lint: a value scan (private keys, cloud keys, tokens, `password: <literal>`, passwords in JDBC URLs) on every
  file of the tree, and a key-name rule (a secret property may not appear in any YAML layer). Add GitHub secret
  scanning with push protection as the backstop.

## 7. One instance, two renderings (compose and Helm)

Compose (laptops, CI test stacks, dev hosts) and Kubernetes (clusters) read the same files; config lint renders
both on every PR, so neither rots.

| Source | docker compose | Helm / Kubernetes |
|---|---|---|
| `<app>` | `<app-dir>/docker/docker-compose.yml`, service named `<app>` | chart `<app-dir>/helm/<app>/` |
| `application.yml` of the four layers | bind mounts, read-only, at `/config/<layer>/` | `--set-file appConfig.<layer>=<file>` into one ConfigMap, projected to `/config/<layer>/application.yml` |
| other files of a layer (`logback.xml`, `*.properties`) | the same bind mount | `--set-file appFiles.<layer>.<file>` (escape dots: `logback\.xml`) |
| `compose.env` | `--env-file` | app-facing subset repeated in instance `values.yaml` `env:` (a map, so Helm deep-merges layers) |
| `IMAGE_TAG` | `IMAGE_TAG=` in `compose.env` | `image.tag` in instance `values.yaml` (same value; the write-back sets both) |
| sizing | `MEM_LIMIT` | `resources` in `app-common/values.yaml` |
| values layers | n/a | chart `values.yaml` < `app-common/values.yaml` < `<instance>/values.yaml` (`-f`, later wins) |
| secrets | host environment, pass-through | `Secret <app>-<instance>-secrets` at `/secrets/` |

Compose invocation, from one wrapper script that laptops, CI and the hosts share:
`docker compose -p <env>-<flow>-<app>-<instance> --env-file <instance>/compose.env -f <compose file> up -d --wait`.
The wrapper validates the tuple against the tree, refuses every env but `local` and dev while qa and prod run
on Kubernetes (the reference's case: compose never reaches production), accepts `IMAGE_TAG` / `IMAGE_REPO` from
its environment as the only overrides of `compose.env` (how a deploy injects the new tag before the write-back
records it), and writes an audit line.

Keep list-valued keys out of layered values (`env:` as a map, not a list): Helm replaces lists instead of merging
them, so the instance layer would silently drop the app-common entries.

## 8. One Helm release per instance, one namespace per flow

- One release, one Deployment, `replicas: 1` per instance: an upgrade, a failed rollout or a rollback touches one
  pipeline. One release holding N instances turns a bad value in one of them into N rollbacks.
- Release `<app>-<instance>` in namespace `<flow>` of the env's cluster. The namespace is the boundary for RBAC,
  quotas, NetworkPolicies, Pod Security labels and deployment windows; release names stay short and may repeat
  across flows. If stages share a cluster, put the stage in the namespace (`payments-dev`).
- A ConfigMap change must roll the pod: annotate the pod template with `checksum/config` (sha256 of the rendered
  ConfigMap).
- Single-consumer workloads: `strategy: Recreate` (never two consumers at once); a PodDisruptionBudget only when
  `replicas > 1` (with one replica it blocks node drains forever).
- Pass the tag with `--set-string image.tag=<tag>` and quote it in values files (`tag: "1.10"`): `--set` and
  unquoted YAML turn `1.10` into the number `1.1` and `1` into an integer.
- A `values.schema.json` in the chart turns a misspelt key or a secret-looking `env` name into a lint error.

## 9. Files other than application.yml

| File | Layers | Referenced as |
|---|---|---|
| `logback.xml` (or another logging config) | app-common, instance | `file:/config/instance/logback.xml`, else `/config/common/...` |
| client properties, scripts | app-common, instance | `file:/config/<layer>/<file>` |
| `values.yaml` | app-common, instance | Helm only; not read by the app |
| `compose.env` | instance only | compose only; not read by the app |

Every file of a layer directory reaches the same mount path in both renderings; lint fails a reference to a file
that does not exist and a nested directory inside a layer (layers are flat).
