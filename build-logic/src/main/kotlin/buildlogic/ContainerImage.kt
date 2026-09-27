package buildlogic

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.provider.MapProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.Optional
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.process.ExecOperations
import org.gradle.work.DisableCachingByDefault
import java.io.ByteArrayOutputStream
import java.io.File
import java.time.Instant
import java.time.temporal.ChronoUnit
import javax.inject.Inject

/** The image build tool decided by DL-14: a Dockerfile built with `docker buildx` or `podman build`. */
enum class EngineKind(val executable: String) { DOCKER("docker"), PODMAN("podman") }

data class Engine(val kind: EngineKind, val buildx: Boolean) {
    val executable: String get() = kind.executable
}

data class CommandResult(val exitCode: Int, val output: String)

/** Outcome of engine detection: an engine, or the reasons why none is usable. */
sealed interface EngineProbe {
    data class Found(val engine: Engine) : EngineProbe
    data class Missing(val reasons: List<String>) : EngineProbe
}

object ContainerEngines {
    /**
     * `auto` tries Docker, then Podman (D3 §6.7): a CLI on the PATH is not enough, the daemon (Docker) or the
     * service (Podman) must answer `info`. Pure function over [run] so that it is unit-tested.
     */
    fun detect(choice: String, run: (List<String>) -> CommandResult): EngineProbe {
        val candidates = when (choice.lowercase()) {
            "", "auto" -> listOf(EngineKind.DOCKER, EngineKind.PODMAN)
            "docker" -> listOf(EngineKind.DOCKER)
            "podman" -> listOf(EngineKind.PODMAN)
            else -> throw GradleException("image.engine must be auto, docker or podman (was '$choice')")
        }
        val reasons = mutableListOf<String>()
        for (kind in candidates) {
            val version = run(listOf(kind.executable, "--version"))
            if (version.exitCode != 0) {
                reasons += "${kind.executable}: CLI not found on the PATH"
                continue
            }
            val infoFormat = if (kind == EngineKind.DOCKER) "{{.ServerVersion}}" else "{{.Version.Version}}"
            val info = run(listOf(kind.executable, "info", "--format", infoFormat))
            if (info.exitCode != 0) {
                val lines = info.output.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toList()
                val detail = lines.firstOrNull { Regex("(?i)error|cannot|failed|refused").containsMatchIn(it) }
                    ?: lines.firstOrNull() ?: "no output"
                reasons += "${kind.executable}: CLI found but the ${if (kind == EngineKind.DOCKER) "daemon" else "service"} " +
                    "is not reachable ($detail)"
                continue
            }
            val buildx = kind == EngineKind.DOCKER && run(listOf("docker", "buildx", "version")).exitCode == 0
            return EngineProbe.Found(Engine(kind, buildx))
        }
        return EngineProbe.Missing(reasons)
    }

    /** The build command line for [engine] (D3 §6.7: Podman builds with `--format docker` to keep HEALTHCHECK). */
    fun buildCommand(
        engine: Engine,
        contextDir: File,
        dockerfile: String,
        refs: List<String>,
        buildArgs: Map<String, String>,
        labels: Map<String, String>,
        extraArgs: List<String>,
    ): List<String> {
        val cmd = mutableListOf(engine.executable)
        when {
            engine.kind == EngineKind.PODMAN -> cmd += listOf("build", "--format", "docker")
            engine.buildx -> cmd += listOf("buildx", "build", "--load")
            else -> cmd += "build"
        }
        cmd += listOf("--file", contextDir.resolve(dockerfile).path)
        refs.forEach { cmd += listOf("--tag", it) }
        buildArgs.toSortedMap().forEach { (k, v) -> cmd += listOf("--build-arg", "$k=$v") }
        labels.toSortedMap().forEach { (k, v) -> cmd += listOf("--label", "$k=$v") }
        cmd += extraArgs
        cmd += contextDir.path
        return cmd
    }

    private val ARG_DEFAULT = Regex("""^\s*ARG\s+(\S+?)=(\S+)\s*$""")

    /** The default value of `ARG <name>=<value>` in a Dockerfile, used for the base-name label. */
    fun argDefault(dockerfile: File, name: String): String? =
        if (!dockerfile.isFile) null
        else dockerfile.readLines().firstNotNullOfOrNull { line ->
            ARG_DEFAULT.matchEntire(line)?.destructured?.let { (k, v) -> if (k == name) v.trim('"') else null }
        }
}

/** Shared engine handling: detect, then either run or explain clearly why nothing happens. */
@DisableCachingByDefault(because = "Talks to the local container engine")
abstract class ContainerEngineTask : DefaultTask() {
    /** `auto`, `docker` or `podman` (`-Pimage.engine`, env `CONTAINER_ENGINE`). */
    @get:Input
    abstract val engineChoice: Property<String>

    /** Fail instead of a logged no-op when no engine is usable (`-Pimage.requireEngine`, default: `CI=true`). */
    @get:Input
    abstract val requireEngine: Property<Boolean>

    @get:Inject
    abstract val execOperations: ExecOperations

    protected fun run(command: List<String>): CommandResult {
        val out = ByteArrayOutputStream()
        return try {
            val result = execOperations.exec {
                commandLine(command)
                standardOutput = out
                errorOutput = out
                isIgnoreExitValue = true
            }
            CommandResult(result.exitValue, out.toString(Charsets.UTF_8))
        } catch (e: Exception) {
            CommandResult(127, e.message ?: e.toString())
        }
    }

    /** Runs [command] with its output streamed to the build log; throws on a non-zero exit. */
    protected fun runLoud(command: List<String>, what: String) {
        logger.lifecycle("> ${command.joinToString(" ")}")
        val result = execOperations.exec {
            commandLine(command)
            isIgnoreExitValue = true
        }
        if (result.exitValue != 0) throw GradleException("$what failed (exit ${result.exitValue}): ${command.joinToString(" ")}")
    }

    /** The usable engine, or null after logging why the task does nothing (or throwing when required). */
    protected fun engineOrSkip(action: String): Engine? =
        when (val probe = ContainerEngines.detect(engineChoice.get(), ::run)) {
            is EngineProbe.Found -> probe.engine
            is EngineProbe.Missing -> {
                val message = "$path: no usable container engine, $action skipped.\n" +
                    probe.reasons.joinToString("\n") { "  - $it" } +
                    "\n  Start Docker (or `systemctl --user start podman.socket`), or choose one with -Pimage.engine=docker|podman."
                if (requireEngine.get()) throw GradleException("$message\n  (-Pimage.requireEngine=true / CI=true: failing instead of skipping)")
                logger.warn(message)
                null
            }
        }
}

/** `buildImage`: builds `docker/Dockerfile` against the staged context `build/docker/` (D1 §6.4, D3 §6.4–§6.5). */
@DisableCachingByDefault(because = "The image lands in the local engine, not in a Gradle output")
abstract class BuildImageTask : ContainerEngineTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val contextDir: DirectoryProperty

    /** Dockerfile path relative to [contextDir]. */
    @get:Input
    abstract val dockerfile: Property<String>

    @get:Input
    abstract val imageRefs: ListProperty<String>

    /** Static build arguments; CREATED is added at execution time. */
    @get:Input
    abstract val buildArgs: MapProperty<String, String>

    /** Static labels; `org.opencontainers.image.created` and `.base.name` are added at execution time. */
    @get:Input
    abstract val labels: MapProperty<String, String>

    /** Name of the Dockerfile ARG that selects the base image (`BASE_IMAGE`, `DEEPHAVEN_IMAGE`). */
    @get:Input
    abstract val baseImageArg: Property<String>

    /** Base image override; when absent the Dockerfile default applies. */
    @get:Input
    @get:Optional
    abstract val baseImage: Property<String>

    /** Extra engine arguments (`-Pimage.extraArgs`, e.g. buildx cache flags in CI). */
    @get:Input
    abstract val extraArgs: ListProperty<String>

    /** Every reference built, one per line (`build/image/refs.txt`), for workflows. */
    @get:OutputFile
    abstract val refsFile: RegularFileProperty

    init {
        outputs.upToDateWhen { false } // the engine owns the layer cache; the image may have been removed
    }

    @TaskAction
    fun build() {
        val engine = engineOrSkip("build of ${imageRefs.get().joinToString()}") ?: return
        val context = contextDir.get().asFile
        val created = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()
        val args = buildArgs.get().toMutableMap()
        args["CREATED"] = created
        val base = baseImage.orNull?.takeIf { it.isNotBlank() }
        if (base != null) args[baseImageArg.get()] = base
        val allLabels = labels.get().toMutableMap()
        allLabels["org.opencontainers.image.created"] = created
        (base ?: ContainerEngines.argDefault(context.resolve(dockerfile.get()), baseImageArg.get()))
            ?.let { allLabels["org.opencontainers.image.base.name"] = it }
        val refs = imageRefs.get()
        val command = ContainerEngines.buildCommand(engine, context, dockerfile.get(), refs, args, allLabels, extraArgs.get())
        runLoud(command, "Image build")
        refsFile.get().asFile.writeText(refs.joinToString("\n", postfix = "\n"))
        logger.lifecycle("Built ${refs.joinToString(", ")} with ${engine.executable}${if (engine.buildx) " buildx" else ""}")
    }
}

/** `pushImage`: pushes every tag of this build; local builds are never pushed (D4 §6.2). */
@DisableCachingByDefault(because = "Pushes to a registry")
abstract class PushImageTask : ContainerEngineTask() {
    @get:Input
    abstract val imageRefs: ListProperty<String>

    @get:Input
    abstract val versionKind: Property<String>

    @get:Input
    abstract val allowLocalPush: Property<Boolean>

    /** `<repository>@sha256:…` of the pushed manifest (`build/image/digest.txt`), for workflows. */
    @get:OutputFile
    abstract val digestFile: RegularFileProperty

    init {
        outputs.upToDateWhen { false }
    }

    @TaskAction
    fun push() {
        if (versionKind.get() == "LOCAL" && !allowLocalPush.get()) {
            throw GradleException(
                "$path: refusing to push a local build (${imageRefs.get().joinToString()}); local images are never " +
                    "published (D4 §6.2). CI computes pr-/rc-/release tags; override with -Pimage.allowLocalPush=true.",
            )
        }
        val engine = engineOrSkip("push of ${imageRefs.get().joinToString()}") ?: return
        val refs = imageRefs.get()
        refs.forEach { runLoud(listOf(engine.executable, "push", it), "Image push") }
        val repository = refs.first().substringBeforeLast(':')
        val inspect = run(listOf(engine.executable, "image", "inspect", "--format", "{{join .RepoDigests \"\\n\"}}", refs.first()))
        val digest = inspect.output.lineSequence().map { it.trim() }.firstOrNull { it.startsWith("$repository@") }
        digestFile.get().asFile.writeText((digest ?: "") + "\n")
        logger.lifecycle("Pushed ${refs.joinToString(", ")}${digest?.let { " ($it)" } ?: ""}")
    }
}

/** `printImageRef`: the primary reference `<registry>/<group>/<AppName>:<tag>` on stdout (use -q). */
@DisableCachingByDefault(because = "Prints to the console")
abstract class PrintImageRefTask : DefaultTask() {
    @get:Input
    abstract val imageRef: Property<String>

    @TaskAction
    fun print() {
        println(imageRef.get())
    }
}

/** `dockerImage { }` extension of the `buildlogic.docker-image` plugin. */
abstract class DockerImageExtension {
    /** `ghcr.io/crazymatthsu` in the demo (`-Pimage.registry`, env `IMAGE_REGISTRY`). */
    abstract val registry: Property<String>

    /** Repository group between registry and name: the parent project (`deephaven-connectors`) or empty. */
    abstract val group: Property<String>

    /** Image name == AppName == project name (D1 §6.1). */
    abstract val imageName: Property<String>

    /** Dockerfile relative to the subproject (and to the staged context). */
    abstract val dockerfile: Property<String>

    /** Dockerfile ARG naming the base image, overridable with `-Pimage.arg.<ARG>=` or env `<ARG>`. */
    abstract val baseImageArg: Property<String>
}
