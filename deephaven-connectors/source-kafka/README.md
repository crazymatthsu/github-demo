# source-kafka

Kafka → Deephaven / AMPS connector of the `deephaven-connectors` family. **Hello world for now:** on start-up it logs its
identity `<env>/<flow>/source-kafka/<AppInstance>` and the effective configuration with secrets masked, and serves
the actuator on port 8080. No client library is wired in yet.

## Build and run

```bash
./gradlew :deephaven-connectors:source-kafka:build          # unit tests, bootJar
./gradlew :deephaven-connectors:source-kafka:buildImage     # needs Docker or Podman
scripts/run-compose.sh local cash source-kafka bbg-equity-ticks start
scripts/run-compose.sh local cash source-kafka bbg-equity-ticks health
scripts/run-compose.sh local cash source-kafka bbg-equity-ticks down
```

`scripts/run-compose.sh` wraps the canonical `<repo>/scripts/run-compose.sh` (D6); `--help` lists every
command. Configuration lives in `config/<env>/<flow>/source-kafka/` (local instance: `bbg-equity-ticks`), never here (D5).

## Helm (demo step 2)

The chart is [`helm/source-kafka/`](helm/source-kafka/README.md): one release `source-kafka-<AppInstance>` per
instance directory, in the namespace of its flow, with the values layers chart `values.yaml` →
`config/<env>/<flow>/source-kafka/app-common/values.yaml` → `<AppInstance>/values.yaml` (`image.tag`,
identity, `env`) and the `application.yml` layers as file values (D11). One script builds the flag list for
every caller — config-lint, the kind deploy test and deploy-dev; run it from the repository root:

```bash
scripts/helm-deploy-instance.sh local cash source-kafka bbg-equity-ticks --tag local --mode template   # or --mode lint
scripts/helm-deploy-instance.sh local cash source-kafka bbg-equity-ticks --tag local \
  --secret-user sa --secret-password "$SA_PASSWORD"   # namespace, Secret, upgrade --install, rollout, helm test
```

`--help` lists the options and exit codes, `--dry-run` prints the commands; `./gradlew configLint` lints and
renders every instance (D5 check 12). A local kind cluster to deploy into: `test-infra/kind/`.

## Configuration keys

| Key | Meaning |
|---|---|
| `connector.source.host`, `.port` | source endpoint |
| `connector.source.table` | the Kafka topic |
| `connector.source.poll-interval` | polling period (Duration, default `30s`) |
| `connector.sink.type` | `amps`, `deephaven` or `stub` (default) |
| `connector.sink.amps.*`, `connector.sink.deephaven.*` | target endpoints (`host`, `port`, `topic` / `table`) |
| `APP_ENV`, `APP_FLOW`, `APP_NAME`, `APP_INSTANCE` | identity, set by the deployer from the config-tree path |
| `LOG_LEVEL_ROOT` | root log level (default `INFO`) |

## Actuator (port 8080)

`/actuator/health/liveness`, `/actuator/health/readiness`, `/actuator/info` (identity, version, git sha),
`/actuator/prometheus` (tags `env`, `flow`, `app`, `instance`), `/actuator/connectorconfig`.
`--print-config` prints the masked configuration and exits.
