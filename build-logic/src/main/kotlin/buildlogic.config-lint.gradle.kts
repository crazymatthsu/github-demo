// `buildlogic.config-lint` (D5 §6.5): root task `configLint` over the config/ tree. Checks 1–6 and 9–12
// run here; 7 (merged configuration vs spring-configuration-metadata.json) and 8 (parity across envs) are
// reported as TODO. A deployable app is a subproject with docker/docker-compose.yml (the compose template
// run-compose.sh uses); its name is the AppName directory expected in the tree, and its Helm chart is
// <subproject>/helm/<AppName>/Chart.yaml (D11 §6.1).
//
//   ./gradlew configLint                      # render check 6 with docker compose / podman compose if present,
//                                             # check 12 with helm (and kubeconform) if present
//   -PconfigLint.compose=none|docker|podman   # choose or disable the compose CLI for check 6
//   -PconfigLint.helm=auto|none|<path>        # Helm 4 for check 12: from the PATH, off, or this binary
//   -PconfigLint.requireRender=true           # fail when no compose CLI / Helm 4 exists (default when CI=true)
//   -PconfigLint.completeEnvs=local           # envs in which every deployable app must have configuration and a chart
//
// Check 12 runs scripts/helm-deploy-instance.sh --mode lint and --mode template per instance and keeps the
// manifests in build/reports/config-lint/rendered/<env>/<flow>/<AppName>/<AppInstance>.yaml; kubeconform
// (-strict, Kubernetes 1.37.0) validates them when it is on the PATH.
import buildlogic.ConfigLintTask

val deployableApps: Map<String, File> = subprojects
    .map { it.name to it.projectDir.resolve("docker/docker-compose.yml") }
    .filter { (_, template) -> template.isFile }
    .toMap()

val appCharts: Map<String, File> = subprojects
    .filter { it.name in deployableApps }
    .map { it.name to it.projectDir.resolve("helm/${it.name}") }
    .filter { (_, chart) -> chart.resolve("Chart.yaml").isFile }
    .toMap()

tasks.register<ConfigLintTask>("configLint") {
    group = "verification"
    description = "Lints the config/ tree (D5 §6.5 checks 1–6, 9–12; 7–8 TODO)."
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
    charts = appCharts.mapValues { it.value.absolutePath }
    chartFiles.from(appCharts.values)
    helmCli = providers.gradleProperty("configLint.helm").orElse("auto")
    helmScript = layout.projectDirectory.file("scripts/helm-deploy-instance.sh")
    renderDir = layout.buildDirectory.dir("reports/config-lint/rendered")
}
