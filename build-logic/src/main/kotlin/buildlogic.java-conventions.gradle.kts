// `buildlogic.java-conventions` (D1 §6.4): every JVM subproject. Java 21 toolchain, the Spring Boot BOM as
// a platform, JUnit Platform, JaCoCo with a low (ratchet-up-only) threshold, reproducible archives.
import buildlogic.catalogLibrary

plugins {
    java
    jacoco
}

group = "com.example.connectors"

java {
    toolchain {
        // The JDK is provided by the ci-build image (CI) or the developer's installation; auto-download is off
        // in gradle.properties (D1 §6.6). The vendor is not pinned so that any installed JDK 21 matches; pin it
        // to the runtime base image's vendor (Temurin, D3) once every build host uses the ci-build image.
        languageVersion = JavaLanguageVersion.of(21)
    }
}

val springBootBom = catalogLibrary("spring-boot-dependencies")

dependencies {
    // Versions of Spring, Jackson, Micrometer, JUnit, the SQL Server driver ... come from the Boot BOM (D1 §6.3).
    "implementation"(platform(springBootBom))
    "annotationProcessor"(platform(springBootBom))
    "testImplementation"(catalogLibrary("junit-jupiter"))
    "testRuntimeOnly"(catalogLibrary("junit-platform-launcher"))
}

plugins.withId("java-test-fixtures") {
    dependencies { "testFixturesImplementation"(platform(springBootBom)) }
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
    options.compilerArgs.addAll(listOf("-parameters", "-Xlint:all,-processing,-serial"))
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
    // Deterministic defaults for tests; the identity and time zone come from the environment at runtime.
    systemProperty("user.timezone", "UTC")
    systemProperty("file.encoding", "UTF-8")
    testLogging {
        events("failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

// Coverage: a report after every test run and a deliberately low floor that only ever ratchets up (D1 §6.5).
tasks.named<Test>("test") { finalizedBy(tasks.named("jacocoTestReport")) }
tasks.named<JacocoReport>("jacocoTestReport") {
    dependsOn(tasks.named("test"))
    reports {
        xml.required = true
        html.required = true
    }
}
tasks.named<JacocoCoverageVerification>("jacocoTestCoverageVerification") {
    dependsOn(tasks.named("test"))
    violationRules {
        rule {
            limit {
                counter = "INSTRUCTION"
                minimum = providers.gradleProperty("coverage.minimum").orElse("0.20").get().toBigDecimal()
            }
        }
    }
}
tasks.named("check") { dependsOn(tasks.named("jacocoTestCoverageVerification")) }

// Reproducible archives (D1 §6.7): no timestamps, stable entry order; the version travels in the manifest.
tasks.withType<AbstractArchiveTask>().configureEach {
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}
tasks.withType<Jar>().configureEach {
    manifest {
        attributes(
            "Implementation-Title" to project.name,
            "Implementation-Version" to project.version.toString(),
        )
    }
}
