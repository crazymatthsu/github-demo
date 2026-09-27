# config/ — the configuration tree (D5)

`config/<env>/<flow>/<AppName>/{app-common,<AppInstance>}/` plus the optional layers
`config/_common/<AppName>/` (every env) and `config/<env>/_common/` (every app of one env), and the
deploy-dev inventory `config/<env>/targets.yml` (`*-dev` envs only). The directory path is the identity
tuple; `run-compose.sh` mounts the layers read-only under `/config/<layer>/` and the jar's import list
applies them lowest precedence first: platform, env, app-common, instance (D5 §6.1).

| File | Holds | Never |
|---|---|---|
| `application.yml` | endpoints, topics, table names, poll intervals, log levels | secrets (D2 §6.4) |
| `<AppInstance>/compose.env` | `IMAGE_REPO`, `IMAGE_TAG`, identity, `JAVA_OPTS`, `TZ`, `LOG_LEVEL_ROOT`, `*_HOST_PORT`, `LOGS_DIR`, `DATA_DIR`, `MEM_LIMIT` | `SPRING_*`, `LOGGING_*`, `MANAGEMENT_*`, `CONNECTOR_*`, secrets |

`./gradlew configLint` checks the tree (D5 §6.5); `scripts/run-compose.sh <env> <flow> <AppName>
<AppInstance> validate` checks one instance.
