# connectors-framework

The library every connector app depends on (D1 §6.4). Auto-configured (`ConnectorFrameworkAutoConfiguration`):

| Piece | What it does |
|---|---|
| `ConnectorIdentity` | the tuple `<env>/<flow>/<AppName>/<AppInstance>` from `APP_ENV`, `APP_FLOW`, `APP_NAME`, `APP_INSTANCE`, validated against the naming model (D5 §6.2); fails fast when `APP_NAME` is another app's |
| `ConnectorProperties` | `@ConfigurationProperties("connector")` + `@Validated`: `connector.source.*`, `connector.sink.type` (`amps`, `deephaven`, `stub`), `connector.sink.amps.*`, `connector.sink.deephaven.*` (D5 §6.3) |
| `ConfigurationSummary`, `SecretMasker` | the start-up summary: identity, config layers found, every `connector.*` / `spring.datasource.*` value with secrets masked (D2 §6.4) |
| `ConnectorApplication` | `main` helper; `--print-config` prints the summary and exits (`run-compose.sh app-config --offline`) |
| metrics, MDC | common tags `env`, `flow`, `app`, `instance` on every meter; `ConnectorMdc` puts them into the MDC |
| `ConnectorHealthIndicator` | health contributor `connector`, part of the readiness group |
| `ConnectorInfoContributor`, `ConnectorConfigEndpoint` | identity in `/actuator/info`; `/actuator/connectorconfig` returns the masked summary |

Test fixtures (`testFixtures(project(":deephaven-connectors:connectors-framework"))`):
`CanonicalJson`, `CompareRules`, `RowSetComparator`, `ComparisonResult` — the expected-output comparison of
D8 §5.5 — and `AbstractConnectorApplicationTest`, the actuator contract every app's unit test inherits.
