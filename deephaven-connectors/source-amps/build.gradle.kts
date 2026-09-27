// source-amps (D1 §6.1): AMPS -> Deephaven. Hello world for now: identity, masked configuration
// summary and the actuator contract; no AMPS client yet (licensed, D3 §6.10).
plugins {
    id("buildlogic.spring-boot-app")
    id("buildlogic.docker-image")
    id("buildlogic.integration-test")
}

dependencies {
    implementation(project(":deephaven-connectors:connectors-framework"))
    implementation(libs.spring.boot.starter.webmvc)
    implementation(libs.bundles.observability)

    testImplementation(libs.spring.boot.starter.test)
    testImplementation(testFixtures(project(":deephaven-connectors:connectors-framework")))
    integrationTestImplementation(testFixtures(project(":deephaven-connectors:connectors-framework")))
}
