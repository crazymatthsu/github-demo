// Convention plugins as precompiled Kotlin script plugins (D1 §4.4, §6.4). Plugin ids follow the
// file names: src/main/kotlin/buildlogic.<name>.gradle.kts -> id("buildlogic.<name>").
plugins {
    `kotlin-dsl`
}

dependencies {
    // Lets the precompiled scripts apply id("org.springframework.boot") without a version.
    implementation(libs.spring.boot.gradle.plugin)
    // YAML parsing for configLint (targets.yml, application.yml key scan).
    implementation(libs.snakeyaml)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.test {
    useJUnitPlatform()
}
