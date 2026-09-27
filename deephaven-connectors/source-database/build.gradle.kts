// source-database (D1 §6.1): JDBC (SQL Server) -> AMPS / Deephaven. Hello world for now: identity, masked
// configuration summary, the actuator contract and one start-up query (SELECT 1, SELECT COUNT(*) FROM
// connector.source.table) with credentials bound only from the environment or /secrets/ (D2 §8.1).
plugins {
    id("buildlogic.spring-boot-app")
    id("buildlogic.docker-image")
    id("buildlogic.integration-test")
}

dependencies {
    implementation(project(":deephaven-connectors:connectors-framework"))
    implementation(libs.spring.boot.starter.webmvc)
    implementation(libs.spring.boot.starter.jdbc)
    implementation(libs.bundles.observability)
    runtimeOnly(libs.mssql.jdbc)

    testImplementation(libs.spring.boot.starter.test)
    testImplementation(testFixtures(project(":deephaven-connectors:connectors-framework")))
    integrationTestImplementation(testFixtures(project(":deephaven-connectors:connectors-framework")))
}
