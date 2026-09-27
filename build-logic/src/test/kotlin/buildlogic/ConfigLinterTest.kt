package buildlogic

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class ConfigLinterTest {
    @TempDir
    lateinit var root: File

    private val template: File by lazy {
        File(root, "source-database/docker/docker-compose.yml").apply {
            parentFile.mkdirs()
            writeText("services:\n  app:\n    image: \${IMAGE_REPO:?x}/\${APP_NAME:?x}:\${IMAGE_TAG:?x}\n" +
                "    environment:\n      SPRING_DATASOURCE_PASSWORD: \${SPRING_DATASOURCE_PASSWORD:?secret}\n")
        }
    }
    private val config: File get() = File(root, "config")

    private fun write(path: String, text: String) = File(config, path).apply { parentFile.mkdirs(); writeText(text) }

    private fun composeEnv(env: String, flow: String, app: String, instance: String, extra: String = "", tag: String = "local") =
        "IMAGE_REPO=ghcr.io/o/deephaven-connectors\nIMAGE_TAG=$tag\nAPP_ENV=$env\nAPP_FLOW=$flow\nAPP_NAME=$app\n" +
            "APP_INSTANCE=$instance\nACTUATOR_HOST_PORT=18081\n$extra"

    private fun validInstance(env: String, instance: String, tag: String = "local") {
        write("$env/cash/source-database/app-common/application.yml", "connector:\n  source:\n    port: 1433\n")
        write("$env/cash/source-database/$instance/application.yml", "connector:\n  source:\n    host: db\n")
        write("$env/cash/source-database/$instance/compose.env", composeEnv(env, "cash", "source-database", instance, tag = tag))
    }

    private fun lint(renderer: ComposeRenderer? = null): List<Finding> =
        ConfigLinter(config, mapOf("source-database" to template), completeEnvs = emptySet(), renderer = renderer)
            .lint().filter { it.severity != Severity.TODO }

    private fun List<Finding>.checks() = map { it.check }.toSet()

    @Test
    fun `a valid tree has no findings and passes placeholders for the secrets to the renderer`() {
        validInstance("local", "trades-db-to-amps")
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/targets.yml", "env: us-dev\ndefaults: { kind: compose, user: deploy }\ntargets:\n" +
            "  - instance: cash/source-database/trades-db-to-amps\n    host: dev-01.example.com\n")
        val requests = mutableListOf<ComposeRenderRequest>()
        val findings = lint { request -> requests += request; CommandResult(0, "") }
        assertEquals(emptyList<Finding>(), findings)
        assertEquals(2, requests.size)
        assertEquals("config-lint-placeholder", requests[0].environment["SPRING_DATASOURCE_PASSWORD"])
        assertEquals("local-cash-source-database-trades-db-to-amps", requests[0].environment["PROJECT"])
    }

    @Test
    fun `naming, identity and allow-list violations are reported`() {
        validInstance("local", "42")
        write("local/cash/source-database/42/compose.env",
            composeEnv("local", "cash", "source-database", "other", "SPRING_DATASOURCE_PASSWORD=x\nFOO=1\nCONFIG_DIR=/x\n"))
        write("local/fx/source-database/app-common/application.yml", "a: 1\n")
        write("us-uat/README.md", "x")
        val findings = lint()
        val messages = findings.joinToString("\n")
        assertTrue(findings.checks().containsAll(setOf(1, 4, 5)), messages)
        assertTrue(messages.contains("never a bare number"), messages)
        assertTrue(messages.contains("SPRING_DATASOURCE_PASSWORD is forbidden"), messages)
        assertTrue(messages.contains("FOO is not an allowed"), messages)
        assertTrue(messages.contains("CONFIG_DIR is set by run-compose.sh"), messages)
        assertTrue(messages.contains("APP_INSTANCE=other does not match"), messages)
        assertTrue(messages.contains("flow 'fx'"), messages)
        assertTrue(messages.contains("env 'us-uat'"), messages)
    }

    @Test
    fun `unknown apps, missing files and missing targets are reported`() {
        write("us-dev/cash/source-nothing/app-common/application.yml", "a: 1\n")
        write("us-dev/cash/source-database/app-common/application.yml", "a: 1\n")
        write("us-dev/cash/source-database/trades-db-to-amps/application.yml", "a: 1\n")
        val messages = lint().joinToString("\n")
        assertTrue(messages.contains("'source-nothing' is not a deployable Gradle subproject"), messages)
        assertTrue(messages.contains("trades-db-to-amps/compose.env: required file missing"), messages)
        assertTrue(messages.contains("targets.yml: required for a *-dev env"), messages)
    }

    @Test
    fun `secrets in YAML and floating tags in prod fail`() {
        validInstance("us-prod", "positions-db-to-deephaven", tag = "latest")
        write("us-prod/cash/source-database/positions-db-to-deephaven/application.yml",
            "spring:\n  datasource:\n    password: hunter2hunter2\n")
        val findings = lint()
        val messages = findings.joinToString("\n")
        assertTrue(findings.checks().containsAll(setOf(9, 10)), messages)
        assertTrue(messages.contains("'spring.datasource.password' is a secret property"), messages)
        assertTrue(messages.contains("IMAGE_TAG 'latest' in us-prod must be an immutable release tag"), messages)
    }

    @Test
    fun `targets must match the instance directories`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/targets.yml", "env: us-dev\ntargets:\n  - instance: cash/source-database/gone\n    kind: compose\n" +
            "    host: h\n    user: Root!\n  - instance: cash/source-database/trades-db-to-amps\n    kind: helm\n")
        val messages = lint().filter { it.check == 11 }.joinToString("\n")
        assertTrue(messages.contains("cash/source-database/gone has no directory"), messages)
        assertTrue(messages.contains("kind helm needs cluster"), messages)
        assertTrue(messages.contains("user 'Root!' is not a valid login name"), messages)
    }

    @Test
    fun `a failing render is an error and a missing compose CLI only a warning`() {
        validInstance("local", "trades-db-to-amps")
        val failed = lint { CommandResult(1, "services.app.image: invalid reference") }
        assertTrue(failed.any { it.check == 6 && it.severity == Severity.ERROR }, failed.joinToString("\n"))
        val skipped = lint { null }
        assertTrue(skipped.any { it.check == 6 && it.severity == Severity.WARN }, skipped.joinToString("\n"))
    }

    @Test
    fun `checks 7 and 8 are reported as TODO`() {
        validInstance("local", "trades-db-to-amps")
        val todo = ConfigLinter(config, mapOf("source-database" to template), emptySet()).lint().filter { it.severity == Severity.TODO }
        assertEquals(listOf(7, 8), todo.map { it.check })
    }
}
