// `buildlogic.docker-image` (D1 §6.4, D3 §6.4–§6.7, D4 §6.2): buildImage, pushImage, printImageRef.
//
//   ./gradlew :deephaven-connectors:source-database:buildImage      # docker buildx / podman build
//   ./gradlew -q :deephaven-connectors:source-database:printImageRef
//
// The build context is staged under build/docker/ with the same relative layout as the subproject
// (docker/Dockerfile, scripts/entrypoint.sh, build/libs/<AppName>.jar), so the Dockerfile also builds by hand
// from the subproject directory. Tags come from buildlogic.git-version (D4 §6.2); labels and build args
// from project.version and git (D3 §6.5).
//
// Properties: -Pimage.registry (env IMAGE_REGISTRY, default ghcr.io/crazymatthsu), -Pimage.tags=a,b,
// -Pimage.engine=auto|docker|podman (env CONTAINER_ENGINE), -Pimage.requireEngine=true (default when CI=true),
// -Pimage.arg.BASE_IMAGE=<ref> (env BASE_IMAGE; -Pimage.arg.DEEPHAVEN_BASE_IMAGE for deephaven-server),
// -Pimage.extraArgs="--cache-from ...", -Pimage.allowLocalPush=true, -Pimage.sourceUrl=<repo url>.
// Outputs for workflows: build/image/refs.txt (every reference built), build/image/digest.txt (after push).
import buildlogic.BuildImageTask
import buildlogic.DockerImageExtension
import buildlogic.PrintImageRefTask
import buildlogic.PushImageTask
import buildlogic.buildlogicProperty
import org.gradle.api.provider.Provider

plugins {
    base
}

val image = extensions.create<DockerImageExtension>("dockerImage")
image.registry.convention(
    providers.gradleProperty("image.registry")
        .orElse(providers.environmentVariable("IMAGE_REGISTRY"))
        .orElse("ghcr.io/crazymatthsu"),
)
// :deephaven-connectors:source-kafka -> group "deephaven-connectors"; :deephaven-server -> no group.
image.group.convention(path.removePrefix(":").split(':').dropLast(1).joinToString("/"))
image.imageName.convention(name)
image.dockerfile.convention("docker/Dockerfile")
image.baseImageArg.convention("BASE_IMAGE")

// Task properties only ever receive plain values or providers whose lambdas capture their own parameters:
// the configuration cache cannot serialise references to this script.
val githubServer: String? = providers.environmentVariable("GITHUB_SERVER_URL").orNull
val githubRepository: String? = providers.environmentVariable("GITHUB_REPOSITORY").orNull
val githubRunId: String? = providers.environmentVariable("GITHUB_RUN_ID").orNull
val sourceUrlValue: String = providers.gradleProperty("image.sourceUrl").orNull
    ?: if (githubServer != null && githubRepository != null) "$githubServer/$githubRepository"
    else "https://github.com/crazymatthsu/github-demo"
val buildUrlValue: String = if (githubServer != null && githubRepository != null && githubRunId != null)
    "$githubServer/$githubRepository/actions/runs/$githubRunId" else "local"
val versionValue: String = version.toString()
val gitShaValue: String = buildlogicProperty("gitSha", "unknown")
val versionKindValue: String = buildlogicProperty("versionKind", "LOCAL")
val imageTagList: List<String> = providers.gradleProperty("image.tags").orNull
    ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
    ?: buildlogicProperty("imageTags", "local").split(',')

val repositoryRef: Provider<String> = image.registry.zip(image.group) { registry, group ->
    if (group.isBlank()) registry.trimEnd('/') else "${registry.trimEnd('/')}/$group"
}.zip(image.imageName) { prefix, imageName -> "$prefix/$imageName" }
val allImageRefs: Provider<List<String>> = repositoryRef.zip(providers.provider { imageTagList.toList() }) { repo, tags ->
    tags.map { "$repo:$it" }
}
val imageLabels: Provider<Map<String, String>> = image.imageName.zip(
    providers.provider {
        mapOf(
            "version" to versionValue, "sha" to gitShaValue, "kind" to versionKindValue.lowercase(),
            "source" to sourceUrlValue, "build" to buildUrlValue,
        )
    },
) { imageName, facts ->
    mapOf(
        "org.opencontainers.image.title" to imageName,
        "org.opencontainers.image.description" to "$imageName (github-demo, Deephaven connectors skeleton)",
        "org.opencontainers.image.version" to facts.getValue("version"),
        "org.opencontainers.image.revision" to facts.getValue("sha"),
        "org.opencontainers.image.source" to facts.getValue("source"),
        "com.example.app" to imageName,
        "com.example.git-sha" to facts.getValue("sha").take(7),
        "com.example.build-url" to facts.getValue("build"),
        "com.example.version-kind" to facts.getValue("kind"),
    )
}
// -Pimage.arg.<ARG>=<ref>; for the apps' BASE_IMAGE also the environment variable BASE_IMAGE (CI exports the
// jre21 base it resolved or bootstrapped). DEEPHAVEN_IMAGE in the environment means "the server image to
// run" to test-infra, so the deephaven-server base is only ever taken from -Pimage.arg.DEEPHAVEN_BASE_IMAGE.
val argProperties: Provider<Map<String, String>> = providers.gradlePropertiesPrefixedBy("image.arg.")
val baseImageEnvironment: Provider<String> = providers.environmentVariable("BASE_IMAGE").orElse("")
val baseImageOverride: Provider<String> = image.baseImageArg.zip(argProperties.zip(baseImageEnvironment) { p, e -> p to e }) { arg, (props, env) ->
    props["image.arg.$arg"]?.takeIf { it.isNotBlank() } ?: if (arg == "BASE_IMAGE") env else ""
}
val engineChoiceProvider: Provider<String> = providers.gradleProperty("image.engine")
    .orElse(providers.environmentVariable("CONTAINER_ENGINE")).orElse("auto")
val requireEngineProvider: Provider<Boolean> = providers.gradleProperty("image.requireEngine").map { it.toBoolean() }
    .orElse(providers.environmentVariable("CI").map { it == "true" })
    .orElse(false)
val extraArgsProvider: Provider<List<String>> = providers.gradleProperty("image.extraArgs")
    .map { it.trim().split(Regex("\\s+")).filter(String::isNotEmpty) }
    .orElse(emptyList())

val stageDockerContext = tasks.register<Sync>("stageDockerContext") {
    group = "container image"
    description = "Stages the minimal image build context under build/docker/."
    into(layout.buildDirectory.dir("docker"))
    from("docker") {
        exclude("docker-compose*.yml") // the compose template is not part of the image
        into("docker")
    }
    from("scripts") {
        include("entrypoint.sh")
        into("scripts")
    }
}
plugins.withId("org.springframework.boot") {
    stageDockerContext.configure { from(tasks.named("bootJar")) { into("build/libs") } }
}

val buildImage = tasks.register<BuildImageTask>("buildImage") {
    group = "container image"
    description = "Builds the image with docker buildx or podman build (no-op with a message when no engine is usable)."
    contextDir.fileProvider(stageDockerContext.map { it.destinationDir })
    dockerfile = image.dockerfile
    imageRefs = allImageRefs
    engineChoice = engineChoiceProvider
    requireEngine = requireEngineProvider
    baseImageArg = image.baseImageArg
    baseImage = baseImageOverride
    extraArgs = extraArgsProvider
    buildArgs = mapOf("APP_VERSION" to versionValue, "GIT_SHA" to gitShaValue, "BUILD_URL" to buildUrlValue)
    labels = imageLabels
    refsFile = layout.buildDirectory.file("image/refs.txt")
}

tasks.register<PushImageTask>("pushImage") {
    group = "container image"
    description = "Pushes every tag of this build (never a local build)."
    dependsOn(buildImage)
    imageRefs = allImageRefs
    versionKind = versionKindValue
    allowLocalPush = providers.gradleProperty("image.allowLocalPush").map { it.toBoolean() }.orElse(false)
    engineChoice = engineChoiceProvider
    requireEngine = requireEngineProvider
    digestFile = layout.buildDirectory.file("image/digest.txt")
}

tasks.register<PrintImageRefTask>("printImageRef") {
    group = "container image"
    description = "Prints the primary image reference <registry>/<group>/<AppName>:<tag> (use -q)."
    imageRef = allImageRefs.map { it.first() }
}
