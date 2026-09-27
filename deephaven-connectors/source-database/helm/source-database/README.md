# Connector Helm chart (`Chart.yaml` name = the AppName)

The chart of one connector app. `source-database`, `source-kafka` and `source-amps` carry identical copies
under `deephaven-connectors/<AppName>/helm/<AppName>/`; only `Chart.yaml` (name, description) and
`image.repository` differ. One Helm release per AppInstance of the config tree (D11 §6, DL-29, DL-33): the
directory `config/<env>/<flow>/<AppName>/<AppInstance>/` becomes the release `<AppName>-<AppInstance>` in the
namespace `<flow>` (DL-38), with one Deployment (`replicas: 1`), its ConfigMap, Service and ServiceAccount.
The `Secret` with the credentials is never templated from values (D11 R4): the deployer creates
`<release>-secrets`, or the `ExternalSecret` of Phase 3 does.

Deploy, lint or render an instance with the one deployer, never with a hand-written `helm` line (example:
`source-database`):

```bash
scripts/helm-deploy-instance.sh us-dev cash source-database trades-db-to-amps --tag 0.1.0-rc.39 --mode template
scripts/helm-deploy-instance.sh us-dev cash source-database trades-db-to-amps --tag 0.1.0-rc.39 --mode lint
scripts/helm-deploy-instance.sh local cash source-database trades-db-to-amps --tag local \
  --secret-user sa --secret-password "$SA_PASSWORD"          # --mode deploy (default); --dry-run prints it
helm test source-database-trades-db-to-amps -n cash --logs   # the smoke test alone
```

## Flag list (`scripts/helm-deploy-instance.sh`, D11 §8.3)

| Flag | Source | Layer (D5 §6.1) |
|---|---|---|
| chart `values.yaml` | this directory | values layer 1 |
| `-f config/<env>/<flow>/<AppName>/app-common/values.yaml` | sizing, `env.TZ` | values layer 2 |
| `-f config/<env>/<flow>/<AppName>/<AppInstance>/values.yaml` | `image.tag`, `identity`, `env.APP_*`, `JAVA_OPTS`, `LOG_LEVEL_ROOT` | values layer 3 |
| `--set-string image.tag=<tag>` | the deployed tag (`--tag`) | wins over layer 3 |
| `--set-file appConfig.platform=config/_common/<AppName>/application.yml` | only when the file exists | `/config/platform/application.yml` |
| `--set-file appConfig.env=config/<env>/_common/application.yml` | only when the file exists | `/config/env/application.yml` |
| `--set-file appConfig.common=.../app-common/application.yml` | required | `/config/common/application.yml` |
| `--set-file appConfig.instance=.../<AppInstance>/application.yml` | required | `/config/instance/application.yml` |
| `--set-file appFiles.<layer>.<file>=<path>` | every other file of those four directories (not `values.yaml`, `compose.env`, `README.md`), `.` in the name escaped as `\.` | `/config/<layer>/<file>` |

`--mode deploy` adds: the namespace with the `restricted` Pod Security labels, the `Secret`
`<release>-secrets` (`spring.datasource.username`, `spring.datasource.password`), `helm lint`,
`helm upgrade --install --create-namespace --rollback-on-failure --wait --timeout 5m` (a first install runs
without `--rollback-on-failure`: nothing to restore, and its failed pods stay for the diagnostics),
`kubectl rollout status` and `helm test --logs`; a failure after the upgrade rolls back to the previous
revision. `--help` has the details and exit codes.

## Objects

| Object | Name | Notes |
|---|---|---|
| ServiceAccount | `<release>` | no token mounted; IRSA / Vault identity in Phase 3 (`serviceAccount.annotations`) |
| ConfigMap | `<release>-config` | keys `<layer>.application.yml` and `<layer>.<file>`; projected to `/config/<layer>/<file>` |
| Deployment | `<release>` | `Recreate`, probes on the actuator, restricted security context, `checksum/config` annotation |
| Service | `<release>` | ClusterIP, port `http` → 8080 (actuator: health, metrics) |
| Job (helm test) | `<release>-smoke-test` | curl from the app image: readiness `UP`, `/actuator/info` identity tuple and `complete: true` |
| NetworkPolicy, PodDisruptionBudget, ServiceMonitor, ExternalSecret | `<release>` | off by default (`enabled` flags); the PDB also needs `replicaCount > 1` |

Every object carries `app.kubernetes.io/name`, `app.kubernetes.io/instance` (the release),
`app.kubernetes.io/managed-by: Helm` and `platform.example.com/{env,flow,app,instance}` from `identity`.
The pods of the connector add `app.kubernetes.io/component: connector` (the selector); the test Job has
`smoke-test`, so it never joins the Service.

## Values

| Key | Default | Meaning |
|---|---|---|
| `replicaCount` | `1` | DL-33: one consumer per pipeline |
| `image.repository` | `ghcr.io/crazymatthsu/deephaven-connectors/<AppName>` | required; JFrog or the ECR mirror on EKS (DL-34) |
| `image.tag` | `""` | required (schema): instance values, `--set-string image.tag=<tag>` from the deployer |
| `image.digest` | `""` | `sha256:…` pins the image: `repository@digest` (DL-20) |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | `[{ name: … }]` for a private registry |
| `serviceAccount.create`, `.name`, `.annotations`, `.automountToken` | `true`, `""`, `{}`, `false` | |
| `identity.env`, `.flow`, `.app`, `.instance` | `""` | required, from the instance values; labels and the helm test; must equal `env.APP_*`, `app` the chart name |
| `env` | `{}` | container environment as a map (rendered sorted); `SPRING_*`, `CONNECTOR_*_PASSWORD` and other secret-bearing names are rejected |
| `appConfig.<layer>` | `{}` | `platform`, `env`, `common` (required), `instance` (required): `application.yml` contents |
| `appFiles.<layer>.<file>` | `{}` | other layer files (`logback.xml`, `*.properties`) |
| `secrets.existingSecret` | `""` | default `<release>-secrets`, mounted at `/secrets/` (mode 0400, `optional: false`) |
| `secrets.externalSecret.enabled`, `.storeRef`, `.storeKind`, `.vaultPath`, `.refreshInterval` | `false`, `vault-<env>`, `ClusterSecretStore`, `<env>/<flow>/<app>/<instance>`, `1m` | Phase 3 (DL-31) |
| `service.port` | `8080` | Service port `http` |
| `probes.startup` | liveness path, every 5 s, 24 failures | 2-minute start budget (D6 §6.9) |
| `probes.readiness`, `probes.liveness` | `/actuator/health/readiness`, `/actuator/health/liveness`, every 10 s, 3 failures, 3 s timeout | D6 §6.9 |
| `resources` | requests `250m` / `1Gi`, limits `1Gi` | memory request = limit; app-common sets it per env + flow |
| `strategy` | `{ type: Recreate }` | `RollingUpdate` only for idempotent pipelines (D6 §6.10) |
| `terminationGracePeriodSeconds` | `30` | graceful shutdown (D6 §6.10) |
| `podSecurityContext`, `securityContext` | non-root 10001, `fsGroup` 10001, `RuntimeDefault` seccomp; read-only root, no privilege escalation, all capabilities dropped | Pod Security Standard `restricted` |
| `tmp.sizeLimit`, `logs.sizeLimit` | `256Mi` | emptyDir `/tmp` and `/app/logs` |
| `topologySpread.*` | enabled, `topology.kubernetes.io/zone`, skew 1, `ScheduleAnyway` | instances of one app spread across zones |
| `reloader.enabled` | `false` | Reloader annotation for the ESO-owned Secret (D5 §4.6) |
| `serviceMonitor.enabled`, `.interval`, `.path`, `.labels` | `false`, `30s`, `/actuator/prometheus`, `{}` | Prometheus Operator |
| `podDisruptionBudget.enabled`, `.maxUnavailable` | `false`, `1` | rendered only with `replicaCount > 1` |
| `networkPolicy.enabled`, `.ingressNamespaces`, `.egress` | `false`, `[monitoring]`, `[]` | ingress from the release's own pods and those namespaces; egress DNS plus the given rules |

`values.schema.json` rejects unknown top-level keys and unknown keys in the chart's own sections, so a
misspelt key fails `helm lint` / `helm template` in config-lint (D5 check 12) before any deploy. `helm lint`
does not evaluate the chart's `fail` guards (identity vs `env.APP_*`, `identity.app` vs the chart): `helm
template`, which config-lint runs as well, and `helm upgrade` do.
