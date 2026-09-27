// `buildlogic.integration-test` (D1 §6.4, D8 §4.2, §6.1, D10 §5.10, §6.2): the three connector apps.
//
// - `integrationTest`: a JVM Test Suite with its own source set (src/integrationTest/java), never wired into
//   `check` (check only compiles it so it cannot rot).
// - `composeUp` / `composeDown`: Exec tasks calling the same script as the workflows,
//   `test-infra/compose/stack.sh up --project <gradle path> --local` and `stack.sh down --project <path>`;
//   integrationTest dependsOn composeUp and is finalizedBy composeDown, so the stack also goes down on failure.
//   The app image under test is built first (buildImage) and passed as APP_IMAGE. One generated
//   IT_SA_PASSWORD per build reaches both the stack and the tests, which run on the host JVM against
//   localhost (IT_DEEPHAVEN_HOST/PORT, IT_SQLSERVER_HOST/PORT, SPRING_DATASOURCE_*, IT_TABLE_PREFIX).
//   `-Pcompose.managed=false` (CI: the workflow owns the stack and runs the tests in it-runner, whose
//   environment then applies unchanged) removes all of this from the graph; `-Pcompose.keep=true` keeps the
//   stack up for debugging.
// - `devUp` / `devDown`: the dependency stack for local work (D6 §6.12, D8 §5.7), compose project `local-dev`
//   (or $COMPOSE_PROJECT_NAME) shared by every app, so one network serves `run-compose.sh local ...`.
import buildlogic.ComposeStackLock
import buildlogic.IntegrationTestSecrets
import buildlogic.buildlogicProperty
import buildlogic.catalogLibrary

plugins {
    id("buildlogic.java-conventions")
    `jvm-test-suite`
}

val springBootBom = catalogLibrary("spring-boot-dependencies")
val junitJupiter = catalogLibrary("junit-jupiter")
val junitLauncher = catalogLibrary("junit-platform-launcher")
val deephavenClient = catalogLibrary("deephaven-java-client-flight-dagger")

testing {
    suites {
        register<JvmTestSuite>("integrationTest") {
            useJUnitJupiter()
            dependencies {
                implementation(project())
                implementation(platform(springBootBom))
                implementation(junitJupiter)
                // Every component stack contains Deephaven and the tests assert through its Java client
                // (Flight session: upload, snapshot, release; D8 §5.2, D10 §5.3).
                implementation(deephavenClient)
                runtimeOnly(junitLauncher)
            }
            targets.all {
                testTask.configure {
                    description = "Runs src/integrationTest against the compose stack (D8); not part of check."
                    shouldRunAfter(tasks.named("test"))
                    // The stack is external state: never up-to-date, never from the build cache.
                    outputs.upToDateWhen { false }
                    outputs.cacheIf { false }
                    // Arrow (under the Deephaven Flight client) reads direct buffers reflectively: JDK 16+ needs
                    // java.nio opened, or MemoryUtil fails to initialise.
                    jvmArgs("--add-opens=java.base/java.nio=ALL-UNNAMED")
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
val devProjectName = providers.environmentVariable("COMPOSE_PROJECT_NAME").orElse("local-dev")
val tablePrefixDefault = "it_${buildlogicProperty("gitSha7", "local")}_"
val stackLock = gradle.sharedServices.registerIfAbsent("composeStackLock", ComposeStackLock::class) {
    maxParallelUsages = 1
}
val itSecrets = gradle.sharedServices.registerIfAbsent("integrationTestSecrets", IntegrationTestSecrets::class) {}
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
    description = "Starts this subproject's test stack: stack.sh up --project $projectPath --local."
    stackCommand("up", "--project", projectPath, "--local")
    usesService(itSecrets)
    val secrets = itSecrets
    val refs = imageRefsFile
    val prefix = tablePrefixDefault
    doFirst {
        val exec = this as Exec
        exec.environment("IT_SA_PASSWORD", secrets.get().saPassword)
        exec.environment("IT_TABLE_PREFIX", System.getenv("IT_TABLE_PREFIX") ?: prefix)
        // The app image built by buildImage in this build (tag `local`), unless the caller chose one.
        val refsFile = refs.get().asFile
        if (System.getenv("APP_IMAGE").isNullOrBlank() && refsFile.isFile) {
            refsFile.readLines().firstOrNull { it.isNotBlank() }?.let { exec.environment("APP_IMAGE", it) }
        }
    }
}

val composeDown = tasks.register<Exec>("composeDown") {
    description = "Stops this subproject's test stack and removes its volumes: stack.sh down --project $projectPath."
    stackCommand("down", "--project", projectPath)
}

if (managed) {
    tasks.named<Test>("integrationTest") {
        dependsOn(composeUp)
        if (!keepStack) finalizedBy(composeDown)
        usesService(itSecrets)
        val secrets = itSecrets
        val prefix = tablePrefixDefault
        // What composeUp recorded (stack.sh write_state): the app image under test and the actuator port that
        // local-ports publishes for it. The project name follows stack.sh: COMPOSE_PROJECT_NAME, else local-<app>.
        val stateFile = rootDir.resolve(
            "test-infra/compose/.state/" +
                (System.getenv("COMPOSE_PROJECT_NAME")?.takeIf { it.isNotBlank() } ?: "local-$appName") + ".env",
        )
        doFirst {
            // The tests run on this JVM, so they reach the stack on the ports local-ports.yml publishes.
            val password = secrets.get().saPassword
            val state = if (stateFile.isFile) {
                stateFile.readLines()
                    .filter { it.isNotBlank() && !it.startsWith("#") && it.contains('=') }
                    .associate { it.substringBefore('=') to it.substringAfter('=').trim('\'', '"') }
            } else {
                emptyMap()
            }
            val env = mutableMapOf(
                "IT_DEEPHAVEN_HOST" to "localhost",
                "IT_DEEPHAVEN_PORT" to (System.getenv("DEEPHAVEN_HOST_PORT") ?: "10000"),
                "IT_SQLSERVER_HOST" to "localhost",
                "IT_SQLSERVER_PORT" to (System.getenv("SQLSERVER_HOST_PORT") ?: "1433"),
                "IT_SA_PASSWORD" to password,
                "SPRING_DATASOURCE_USERNAME" to "sa",
                "SPRING_DATASOURCE_PASSWORD" to password,
                "IT_TABLE_PREFIX" to (System.getenv("IT_TABLE_PREFIX") ?: prefix),
            )
            // The app under test (D8 §5.1), when the stack includes it: its actuator on the published port.
            val appImage = System.getenv("APP_IMAGE")?.takeIf { it.isNotBlank() } ?: state["APP_IMAGE"]
            if (appImage != null) {
                env["APP_IMAGE"] = appImage
                env["IT_APP_HOST"] = "localhost"
                env["IT_APP_PORT"] = System.getenv("ACTUATOR_HOST_PORT")?.takeIf { it.isNotBlank() }
                    ?: state["ACTUATOR_HOST_PORT"] ?: "18080"
            }
            (this as Test).environment(env)
        }
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
            "Dependencies are up (compose project $composeProject; the SQL Server password is IT_SA_PASSWORD in " +
                "test-infra/compose/.state/$composeProject.env). Run an app against them with, e.g.:\n" +
                "  DEPS_NETWORK=${composeProject}_default deephaven-connectors/$appName/scripts/run-compose.sh local cash $appName <AppInstance> start",
        )
    }
}

tasks.register<Exec>("devDown") {
    description = "Stops the local dependency stack: stack.sh down."
    stackCommand("down")
    environment("COMPOSE_PROJECT_NAME", devProjectName.get())
}
