# github-demo — Deephaven platform and connectors (demo skeleton)

A Gradle monorepo (Java 21, Spring Boot 4.1, Kotlin DSL) that demonstrates the build, image, configuration,
test and delivery conventions designed in [`docs/`](docs/00-overview.md) from the brief in
[`TODO.md`](TODO.md). The connectors are hello-world apps: they log their identity and masked
configuration and serve the actuator; the plumbing around them is the point.

| Path | What |
|---|---|
| `deephaven-connectors/connectors-framework` | shared library: identity, `connector.*` properties, masked start-up summary, health, metrics tags |
| `deephaven-connectors/source-{kafka,amps,database}` | the connector apps (Spring Boot, `docker/`, `scripts/run-compose.sh`) |
| `deephaven-server` | image-only: the upstream Deephaven server with the enterprise CA |
| `build-logic/` | convention plugins `buildlogic.*` (D1 §6.4) |
| `config/` | configuration tree `<env>/<flow>/<AppName>/{app-common,<AppInstance>}` (D5) |
| `scripts/run-compose.sh` | start / inspect / stop one app instance with compose (D6) |
| `test-infra/`, `docker/base/`, `.github/` | test stacks (D8, D10), base images (D3), workflows (D7) |

## Build

Requires a JDK 21; everything else comes through the Gradle wrapper.

```bash
./gradlew build                    # compile, unit tests, coverage floor, boot jars (no containers)
./gradlew configLint               # lint the config tree (D5 §6.5)
./gradlew -q printVersion          # version derived from git, e.g. 0.1.0-local.3.1a2b3c4 (D4)
./gradlew buildImages              # container images (Docker or Podman)
./gradlew integrationTest          # compose stack + integration tests, per app (D8)
./gradlew devUp / devDown          # dependency stack for local development

scripts/run-compose.sh local cash source-database positions-db-to-deephaven start --dry-run
scripts/run-compose.sh --help
```

Design documents: [D0 overview](docs/00-overview.md) · [D1 build](docs/01-repository-and-build.md) ·
[D3 images](docs/03-docker-images.md) · [D4 versions](docs/04-versioning-and-image-tagging.md) ·
[D5 configuration](docs/05-configuration-management.md) · [D6 runtime](docs/06-runtime-operations.md) ·
[D8 integration tests](docs/08-integration-testing.md) · [ADRs](docs/adr/README.md).
