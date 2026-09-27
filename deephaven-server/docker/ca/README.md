Staging directory for the CA certificates baked into the deephaven-server image. `./gradlew
:deephaven-server:buildImage` copies `test-infra/ca/*.pem` (the demo root CA; in the enterprise, the CA
bundle) here in the staged build context; nothing is committed here except this file.
