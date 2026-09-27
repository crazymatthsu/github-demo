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
