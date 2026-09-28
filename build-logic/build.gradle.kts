// Convention plugins as precompiled Kotlin script plugins (D1 §4.4, §6.4). Plugin ids follow the file
// names: src/main/kotlin/buildlogic.<name>.gradle.kts -> id("buildlogic.<name>"); the settings plugin is
// buildlogic.git-version.settings.gradle.kts -> id("buildlogic.git-version"). The logic behind the scripts
// lives in plain Kotlin classes under src/main/kotlin/buildlogic/ so that it is unit-tested here.
plugins {
    `kotlin-dsl`
}

dependencies {
    // Lets the precompiled scripts apply id("org.springframework.boot") without a version.
    implementation(libs.spring.boot.gradle.plugin)
    // YAML parsing for configLint (workflows-config.yml, application.yml key scan).
    implementation(libs.snakeyaml)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.test {
    useJUnitPlatform()
}
