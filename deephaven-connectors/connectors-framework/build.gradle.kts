// connectors-framework (D1 §6.4): the library every connector app depends on — identity, the `connector.*`
// property contract (D5 §6.3), the masked start-up summary, identity tags on metrics and log lines, a
// readiness health indicator and /actuator/info identity. Test fixtures carry the canonical-JSON comparator
// that the apps' integration tests use (D8 §5.5).
plugins {
    id("buildlogic.java-conventions")
    `java-library`
    `java-test-fixtures`
}

dependencies {
    api(libs.spring.boot.starter.actuator)
    api(libs.spring.boot.starter.validation)
    // Boot's actuator types carry Jackson annotations; visible at compile time to the framework and the apps.
    compileOnlyApi(libs.jackson.annotations)
    annotationProcessor(libs.spring.boot.configuration.processor)

    testFixturesApi(libs.jackson.databind)
    testFixturesApi(libs.spring.boot.starter.test)

    testImplementation(libs.spring.boot.starter.test)
}
