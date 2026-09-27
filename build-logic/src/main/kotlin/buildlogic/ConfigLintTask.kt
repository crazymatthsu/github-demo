package buildlogic

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.MapProperty
import org.gradle.api.provider.Property
import org.gradle.api.provider.SetProperty
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.process.ExecOperations
import org.gradle.work.DisableCachingByDefault
import java.io.ByteArrayOutputStream
import java.io.File
import javax.inject.Inject

/** Root task `configLint` (D5 §6.5): runs [ConfigLinter] and fails on any ERROR finding. */
@DisableCachingByDefault(because = "Cheap, and check 6 depends on the local compose CLI")
abstract class ConfigLintTask : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val configDir: DirectoryProperty

    /** Deployable AppName -> absolute path of its `docker/docker-compose.yml`. */
    @get:Internal
    abstract val apps: MapProperty<String, String>

    @get:Input
    val appNames: Set<String> get() = apps.get().keys

    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val composeTemplates: ConfigurableFileCollection

    @get:Input
    abstract val completeEnvs: SetProperty<String>

    /** `auto`, `docker`, `podman` or `none` (`-PconfigLint.compose`). */
    @get:Input
    abstract val composeCli: Property<String>

    /** Fail check 6 when no compose CLI exists (`-PconfigLint.requireRender`, default CI=true). */
    @get:Input
    abstract val requireRender: Property<Boolean>

    @get:OutputFile
    abstract val reportFile: RegularFileProperty

    @get:Inject
    abstract val execOperations: ExecOperations

    private fun exec(command: List<String>, environment: Map<String, String>? = null): CommandResult {
        val out = ByteArrayOutputStream()
        return try {
            val result = execOperations.exec {
                commandLine(command)
                if (environment != null) setEnvironment(environment)
                standardOutput = out
                errorOutput = out
                isIgnoreExitValue = true
            }
            CommandResult(result.exitValue, out.toString(Charsets.UTF_8))
        } catch (e: Exception) {
            CommandResult(127, e.message ?: e.toString())
        }
    }

    private fun composeCommand(): List<String>? {
        val candidates = when (composeCli.get()) {
            "none" -> emptyList()
            "docker" -> listOf(listOf("docker", "compose"))
            "podman" -> listOf(listOf("podman", "compose"), listOf("podman-compose"))
            else -> listOf(listOf("docker", "compose"), listOf("podman", "compose"), listOf("docker-compose"), listOf("podman-compose"))
        }
        return candidates.firstOrNull { exec(it + "version").exitCode == 0 }
    }

    @TaskAction
    fun lint() {
        val compose = composeCommand()
        // A controlled environment: the developer's shell must not leak IMAGE_TAG & co. into the render.
        val baseEnv = listOf("PATH", "HOME", "DOCKER_HOST", "DOCKER_CONFIG", "XDG_RUNTIME_DIR", "CONTAINERS_CONF")
            .mapNotNull { key -> System.getenv(key)?.let { key to it } }.toMap()
        val renderer = compose?.let { cmd ->
            ComposeRenderer { request ->
                exec(
                    cmd + listOf("-p", request.project, "--env-file", request.envFile.path, "-f", request.template.path, "config", "--quiet"),
                    baseEnv + request.environment,
                )
            }
        }
        val linter = ConfigLinter(
            configRoot = configDir.get().asFile,
            apps = apps.get().mapValues { File(it.value) },
            completeEnvs = completeEnvs.get(),
            renderer = renderer ?: ComposeRenderer { null },
            requireRender = requireRender.get(),
        )
        val findings = linter.lint()
        val errors = findings.count { it.severity == Severity.ERROR }
        val warnings = findings.count { it.severity == Severity.WARN }
        val header = "config-lint: ${findings.size} finding(s): $errors error(s), $warnings warning(s); " +
            "render with ${compose?.joinToString(" ") ?: "no compose CLI"}"
        val report = (listOf(header) + findings.map { it.toString() }).joinToString("\n", postfix = "\n")
        reportFile.get().asFile.apply { parentFile.mkdirs() }.writeText(report)
        findings.forEach { if (it.severity == Severity.ERROR) logger.error(it.toString()) else logger.lifecycle(it.toString()) }
        logger.lifecycle(header)
        if (errors > 0) throw GradleException("config-lint found $errors error(s); report: ${reportFile.get().asFile}")
    }
}
