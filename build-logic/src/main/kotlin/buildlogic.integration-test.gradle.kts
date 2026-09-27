// `buildlogic.integration-test` (D1 §6.4, D8 §4.2, §6.1, D10 §5.10, §6.2): the three connector apps.
//
// - `integrationTest`: a JVM Test Suite with its own source set (src/integrationTest/java), never wired into
//   `check` (check only compiles it so it cannot rot).
// - `composeUp` / `composeDown`: Exec tasks calling the same script as the workflows,
//   `test-infra/compose/stack.sh up --project <gradle path> [--local]` and `stack.sh down`;
//   integrationTest dependsOn composeUp and is finalizedBy composeDown, so the stack also goes down on failure.
//   `-Pcompose.managed=false` (CI: the workflow owns the stack) removes both from the graph;
//   `-Pcompose.keep=true` keeps the stack up for debugging; `-Pcompose.local=false` drops `--local`.
// - `devUp` / `devDown`: the dependency stack for local work (D6 §6.12, D8 §5.7), compose project `local-dev`
//   (or $COMPOSE_PROJECT_NAME) shared by every app, so one network serves `run-compose.sh local ...`.
import buildlogic.ComposeStackLock
import buildlogic.catalogLibrary

plugins {
    id("buildlogic.java-conventions")
    `jvm-test-suite`
}

val springBootBom = catalogLibrary("spring-boot-dependencies")
val junitJupiter = catalogLibrary("junit-jupiter")
val junitLauncher = catalogLibrary("junit-platform-launcher")

testing {
    suites {
        register<JvmTestSuite>("integrationTest") {
            useJUnitJupiter()
            dependencies {
                implementation(project())
                implementation(platform(springBootBom))
                implementation(junitJupiter)
                runtimeOnly(junitLauncher)
            }
            targets.all {
                testTask.configure {
                    description = "Runs src/integrationTest against the compose stack (D8); not part of check."
                    shouldRunAfter(tasks.named("test"))
                    // The stack is external state: never up-to-date, never from the build cache.
                    outputs.upToDateWhen { false }
                    outputs.cacheIf { false }
                }
            }
        }
    }
}

// check compiles the integration tests (no containers needed) but never runs them.
tasks.named("check") { dependsOn(tasks.named("integrationTestClasses")) }

val projectPath: String = path
val appName: String = name
val stackScript: File = rootDir.resolve("test-infra/compose/stack.sh")
val managed = providers.gradleProperty("compose.managed").map { it.toBoolean() }.orElse(true).get()
val keepStack = providers.gradleProperty("compose.keep").map { it.toBoolean() }.orElse(false).get()
val localPorts = providers.gradleProperty("compose.local").map { it.toBoolean() }.orElse(true).get()
val itProjectName = providers.environmentVariable("COMPOSE_PROJECT_NAME").orElse("local-$appName")
val devProjectName = providers.environmentVariable("COMPOSE_PROJECT_NAME").orElse("local-dev")
val stackLock = gradle.sharedServices.registerIfAbsent("composeStackLock", ComposeStackLock::class) {
    maxParallelUsages = 1
}
val imageRefsFile = layout.buildDirectory.file("image/refs.txt")

fun Exec.stackCommand(vararg args: String) {
    group = "integration test"
    workingDir = rootDir
    commandLine(listOf("bash", stackScript.path) + args.toList())
    usesService(stackLock)
    val script = stackScript
    doFirst {
        if (!script.isFile) {
            throw GradleException(
                "$script not found: the dependency stacks live in test-infra/compose/ (D8 §6.3, D10 §6.2). " +
                    "Run with -Pcompose.managed=false when the stack is started elsewhere.",
            )
        }
    }
}

val composeUp = tasks.register<Exec>("composeUp") {
    description = "Starts this subproject's test stack: stack.sh up --project $projectPath${if (localPorts) " --local" else ""}."
    stackCommand(*(listOf("up", "--project", projectPath) + if (localPorts) listOf("--local") else emptyList()).toTypedArray())
    environment("COMPOSE_PROJECT_NAME", itProjectName.get())
    val refs = imageRefsFile
    doFirst {
        // The app image built by buildImage in this build (tag `local`), unless the caller chose one.
        val refsFile = refs.get().asFile
        if (System.getenv("APP_IMAGE").isNullOrBlank() && refsFile.isFile) {
            refsFile.readLines().firstOrNull { it.isNotBlank() }?.let { environment("APP_IMAGE", it) }
        }
    }
}

val composeDown = tasks.register<Exec>("composeDown") {
    description = "Stops this subproject's test stack: stack.sh down (volumes removed)."
    stackCommand("down")
    environment("COMPOSE_PROJECT_NAME", itProjectName.get())
}

if (managed) {
    tasks.named("integrationTest") {
        dependsOn(composeUp)
        if (!keepStack) finalizedBy(composeDown)
    }
    composeDown.configure { mustRunAfter(tasks.named("integrationTest")) }
    // Component ITs exercise the app image (D8 §5.1): build it first when this project has one.
    plugins.withId("buildlogic.docker-image") {
        composeUp.configure { dependsOn(tasks.named("buildImage")) }
    }
}

tasks.register<Exec>("devUp") {
    description = "Starts the dependency stack for local development (D6 §6.12): stack.sh up --project $projectPath --local."
    stackCommand("up", "--project", projectPath, "--local")
    val composeProject = devProjectName.get()
    environment("COMPOSE_PROJECT_NAME", composeProject)
    doLast {
        logger.lifecycle(
            "Dependencies are up (compose project $composeProject). Run an app against them with, e.g.:\n" +
                "  DEPS_NETWORK=${composeProject}_default deephaven-connectors/$appName/scripts/run-compose.sh local cash $appName <AppInstance> start",
        )
    }
}

tasks.register<Exec>("devDown") {
    description = "Stops the local dependency stack: stack.sh down."
    stackCommand("down")
    environment("COMPOSE_PROJECT_NAME", devProjectName.get())
}
