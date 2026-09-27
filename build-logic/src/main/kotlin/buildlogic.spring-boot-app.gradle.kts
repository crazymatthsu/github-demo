// `buildlogic.spring-boot-app` (D1 §6.4): the three connector apps. java-conventions + the Spring Boot
// plugin, a layered bootJar with a version-less name (the Dockerfile copies build/libs/<AppName>.jar), no
// plain jar, and bootBuildInfo carrying the version and git facts into /actuator/info.
import buildlogic.buildlogicProperty
import org.springframework.boot.gradle.tasks.bundling.BootJar

plugins {
    id("buildlogic.java-conventions")
    id("org.springframework.boot")
}

tasks.named<Jar>("jar") { enabled = false }

tasks.named<BootJar>("bootJar") {
    archiveFileName = "${project.name}.jar"
    // Layered (default in Boot 4.1, stated for the reader) with the tools jarmode included, so that the
    // Dockerfile can run `java -Djarmode=tools -jar app.jar extract --layers --launcher` (D3 §6.11).
    layered { enabled = true }
    includeTools = true
}

val gitSha = buildlogicProperty("gitSha", "unknown")
val gitBranch = buildlogicProperty("gitBranch", "unknown")
val gitDirty = buildlogicProperty("gitDirty", "false")
val gitCommitTime = buildlogicProperty("gitCommitTime", "")
val versionKind = buildlogicProperty("versionKind", "LOCAL")

springBoot {
    buildInfo {
        properties {
            // The commit time instead of "now" keeps build-info.properties (and the jar) reproducible.
            if (gitCommitTime.isNotEmpty()) time = gitCommitTime
            additional.putAll(
                mapOf(
                    "git.sha" to gitSha,
                    "git.sha7" to gitSha.take(7),
                    "git.branch" to gitBranch,
                    "git.dirty" to gitDirty,
                    "version-kind" to versionKind.lowercase(),
                ),
            )
        }
    }
}
