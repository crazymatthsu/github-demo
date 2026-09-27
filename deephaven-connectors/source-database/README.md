# source-database

JDBC (SQL Server) → AMPS / Deephaven connector of the `deephaven-connectors` family. **Hello world for
now:** on start-up it logs its identity `<env>/<flow>/source-database/<AppInstance>` and the effective
configuration with secrets masked, runs one query against its database (`SELECT 1`, then
`SELECT COUNT(*) FROM <connector.source.table>`) and serves the actuator on port 8080. Without a database
it still starts; `/actuator/health` shows the failed query as `sourceDatabase: DOWN`, readiness stays UP.

## Build and run

```bash
./gradlew :deephaven-connectors:source-database:build          # unit tests, bootJar
./gradlew :deephaven-connectors:source-database:buildImage     # needs Docker or Podman
./gradlew -q :deephaven-connectors:source-database:printImageRef

# on a laptop, against the local dependency stack (./gradlew devUp)
export SPRING_DATASOURCE_USERNAME=sa SPRING_DATASOURCE_PASSWORD='<the test password>'
DEPS_NETWORK=local-dev_default scripts/run-compose.sh local cash source-database positions-db-to-deephaven start
scripts/run-compose.sh local cash source-database positions-db-to-deephaven health
scripts/run-compose.sh local cash source-database positions-db-to-deephaven app-config
scripts/run-compose.sh local cash source-database positions-db-to-deephaven down
```

`scripts/run-compose.sh` wraps the canonical `<repo>/scripts/run-compose.sh` (D6); `--help` lists every
command, `--dry-run` shows what would run. Configuration lives in `config/<env>/cash/source-database/`
(instances `trades-db-to-amps`, `positions-db-to-deephaven`), never in this directory (D5).

## Helm (demo step 2)

The chart is [`helm/source-database/`](helm/source-database/README.md): one release `source-database-<AppInstance>` per
instance directory, in the namespace of its flow, with the values layers chart `values.yaml` →
`config/<env>/<flow>/source-database/app-common/values.yaml` → `<AppInstance>/values.yaml` (`image.tag`,
identity, `env`) and the `application.yml` layers as file values (D11). One script builds the flag list for
every caller — config-lint, the kind deploy test and deploy-dev; run it from the repository root:

```bash
scripts/helm-deploy-instance.sh us-dev cash source-database trades-db-to-amps --tag 0.1.0-rc.39 --mode template   # or --mode lint
scripts/helm-deploy-instance.sh local cash source-database positions-db-to-deephaven --tag local \
  --secret-user sa --secret-password "$SA_PASSWORD"   # namespace, Secret, upgrade --install, rollout, helm test
scripts/helm-smoke-diff.sh -n cash source-database-trades-db-to-amps source-database-positions-db-to-deephaven   # once both are deployed
```

`--help` lists the options and exit codes, `--dry-run` prints the commands; `./gradlew configLint` lints and
renders every instance (D5 check 12). A local kind cluster to deploy into: `test-infra/kind/`.

## Configuration keys

| Key | Meaning |
|---|---|
| `connector.source.host`, `.port`, `.database` | SQL Server endpoint; `spring.datasource.url` is built from them |
| `connector.source.table` | table counted by the hello-world query (`[database.][schema.]table`) |
| `connector.source.poll-interval` | polling period (Duration, default `30s`) |
| `connector.sink.type` | `amps`, `deephaven` or `stub` (default) |
| `connector.sink.amps.host`, `.port`, `.topic` | AMPS target (required when the sink is `amps`) |
| `connector.sink.deephaven.host`, `.port`, `.table` | Deephaven target (required when the sink is `deephaven`) |
| `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD` | credentials: environment or `/secrets/spring.datasource.*` only (D2 §6.4) |
| `APP_ENV`, `APP_FLOW`, `APP_NAME`, `APP_INSTANCE` | identity, set by the deployer from the config-tree path |
| `LOG_LEVEL_ROOT` | root log level (default `INFO`) |

## Actuator (port 8080)

`/actuator/health/liveness`, `/actuator/health/readiness` (includes the `connector` indicator),
`/actuator/health` (adds `sourceDatabase` and `db`), `/actuator/info` (identity, version, git sha),
`/actuator/prometheus` (tags `env`, `flow`, `app`, `instance`), `/actuator/connectorconfig` (the masked
configuration summary). `java -jar build/libs/source-database.jar --print-config` prints the summary and
exits without connecting.
