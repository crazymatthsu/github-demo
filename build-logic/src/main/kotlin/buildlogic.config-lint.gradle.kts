// `buildlogic.config-lint` (D5 §6.5): root task `configLint` over the config/ tree. Checks 1–6 and 9–11
// run here; 7 (merged configuration vs spring-configuration-metadata.json) and 8 (parity across envs) are
// reported as TODO. A deployable app is a subproject with docker/docker-compose.yml (the compose template
// run-compose.sh uses); its name is the AppName directory expected in the tree.
//
//   ./gradlew configLint                      # render check 6 with docker compose / podman compose if present
//   -PconfigLint.compose=none|docker|podman   # choose or disable the compose CLI for check 6
//   -PconfigLint.requireRender=true           # fail when no compose CLI exists (default when CI=true)
//   -PconfigLint.completeEnvs=local           # envs in which every deployable app must have configuration
import buildlogic.ConfigLintTask

val deployableApps: Map<String, File> = subprojects
    .map { it.name to it.projectDir.resolve("docker/docker-compose.yml") }
    .filter { (_, template) -> template.isFile }
    .toMap()

tasks.register<ConfigLintTask>("configLint") {
    group = "verification"
    description = "Lints the config/ tree (D5 §6.5 checks 1–6, 9–11; 7–8 TODO)."
    configDir = layout.projectDirectory.dir("config")
    apps = deployableApps.mapValues { it.value.absolutePath }
    composeTemplates.from(deployableApps.values)
    completeEnvs = providers.gradleProperty("configLint.completeEnvs")
        .map { it.split(',').map(String::trim).filter(String::isNotEmpty).toSet() }
        .orElse(setOf("local"))
    composeCli = providers.gradleProperty("configLint.compose").orElse("auto")
    requireRender = providers.gradleProperty("configLint.requireRender").map { it.toBoolean() }
        .orElse(providers.environmentVariable("CI").map { it == "true" })
        .orElse(false)
    reportFile = layout.buildDirectory.file("reports/config-lint/config-lint.txt")
}
