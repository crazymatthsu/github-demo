# deephaven-server

Image-only subproject (D1 §4.10, D3 §6.10): the upstream Deephaven Community server
`ghcr.io/deephaven/server:42.5` (pinned by digest in `docker/Dockerfile`) with the CA certificates of
`test-infra/ca/*.pem` imported into the OS trust store and the server JVM's `cacerts`, a `/plugins`
placeholder and `/opt/deephaven/bin/verify-trust.sh`. Entrypoint, port 10000 and the `grpc_health_probe`
health check come from the upstream image.

```bash
./gradlew :deephaven-server:buildImage                       # needs Docker or Podman
./gradlew -q :deephaven-server:printImageRef                 # ghcr.io/crazymatthsu/deephaven-server:<tag>
./gradlew -q printVersion -PversionLine=deephaven-server     # its own version line
```

Versioning: tags `deephaven-server/vX.Y.Z` (D4 §6.1), independent of the connector family. Without
`test-infra/ca/demo-root-ca.pem` the build still succeeds and keeps the upstream trust stores. Bump the
upstream tag together with `deephaven` in `gradle/libs.versions.toml`.
