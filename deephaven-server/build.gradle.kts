// :deephaven-server — image-only subproject (D1 §4.10, D3 §6.10): the pinned upstream Deephaven server with
// the demo / enterprise CA in both trust stores. No java plugin; it has its own version line
// (tags deephaven-server/vX.Y.Z, D4 §6.1) and joins buildImages / pushImages.
plugins {
    id("buildlogic.docker-image")
}

dockerImage {
    // The Dockerfile selects the upstream image with this ARG (-Pimage.arg.DEEPHAVEN_IMAGE= or env).
    baseImageArg = "DEEPHAVEN_IMAGE"
}

// The demo root CA is produced by test-infra (test-infra/ca/demo-root-ca.pem). It is staged into the build
// context when present; without it the image keeps the upstream trust stores.
tasks.named<Sync>("stageDockerContext") {
    from(rootDir.resolve("test-infra/ca")) {
        include("*.pem")
        into("docker/ca")
    }
}
