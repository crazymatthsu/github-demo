package buildlogic

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
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
    private val chart: File get() = File(root, "source-database/helm/source-database")
    private val config: File get() = File(root, "config")
    private val rendered: File get() = File(root, "rendered")

    private fun write(path: String, text: String) = File(config, path).apply { parentFile.mkdirs(); writeText(text) }

    private fun composeEnv(env: String, flow: String, app: String, instance: String, extra: String = "", tag: String = "local") =
        "IMAGE_REPO=ghcr.io/o/deephaven-connectors\nIMAGE_TAG=$tag\nAPP_ENV=$env\nAPP_FLOW=$flow\nAPP_NAME=$app\n" +
            "APP_INSTANCE=$instance\nJAVA_OPTS=-XX:MaxRAMPercentage=60\nTZ=UTC\nACTUATOR_HOST_PORT=18081\n$extra"

    private fun instanceValues(env: String, instance: String, tag: String = "local", extraEnv: String = "") =
        "image:\n  tag: \"$tag\"\nidentity:\n  env: $env\n  flow: cash\n  app: source-database\n  instance: $instance\n" +
            "env:\n  APP_ENV: $env\n  APP_FLOW: cash\n  APP_NAME: source-database\n  APP_INSTANCE: $instance\n" +
            "  JAVA_OPTS: \"-XX:MaxRAMPercentage=60\"\n$extraEnv"

    private fun validInstance(env: String, instance: String, tag: String = "local") {
        write("$env/cash/source-database/app-common/application.yml", "connector:\n  source:\n    port: 1433\n")
        write("$env/cash/source-database/app-common/values.yaml", "resources:\n  limits:\n    memory: 768Mi\nenv:\n  TZ: UTC\n")
        write("$env/cash/source-database/$instance/application.yml", "connector:\n  source:\n    host: db\n")
        write("$env/cash/source-database/$instance/compose.env", composeEnv(env, "cash", "source-database", instance, tag = tag))
        write("$env/cash/source-database/$instance/values.yaml", instanceValues(env, instance, tag))
    }

    /** A kubeconform answer in the shape of `-output json -summary`. */
    private fun kubeconform(valid: Int, skipped: Int = 0, resources: String = "") =
        "{\n  \"resources\": [$resources],\n  \"summary\": {\"valid\": $valid, \"invalid\": 0, \"errors\": 0, \"skipped\": $skipped}\n}\n"

    private val helmRequests = mutableListOf<HelmRequest>()
    private val helmOk = HelmRunner { request -> helmRequests += request; CommandResult(0, "") }
    private val kubeconformOk = ManifestValidator { CommandResult(0, kubeconform(valid = 5)) }

    private fun linter(
        renderer: ComposeRenderer? = null,
        helm: HelmRunner? = helmOk,
        validator: ManifestValidator? = kubeconformOk,
        completeEnvs: Set<String> = emptySet(),
        requireRender: Boolean = false,
        charts: Map<String, File> = mapOf("source-database" to chart),
    ) = ConfigLinter(config, mapOf("source-database" to template), completeEnvs, renderer, requireRender, charts, helm,
        validator, rendered)

    private fun lint(renderer: ComposeRenderer? = null): List<Finding> =
        linter(renderer).lint().filter { it.severity != Severity.TODO }

    private fun List<Finding>.checks() = map { it.check }.toSet()
    private fun List<Finding>.text() = joinToString("\n")

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
        val messages = findings.text()
        assertTrue(findings.checks().containsAll(setOf(1, 4, 5)), messages)
        assertTrue(messages.contains("never a bare number"), messages)
        assertTrue(messages.contains("SPRING_DATASOURCE_PASSWORD is forbidden"), messages)
        assertTrue(messages.contains("FOO is not an allowed"), messages)
        assertTrue(messages.contains("CONFIG_DIR is set by run-compose.sh"), messages)
        assertTrue(messages.contains("APP_INSTANCE=other does not match"), messages)
        assertTrue(messages.contains("flow 'fx'"), messages)
        assertTrue(messages.contains("env 'us-uat'"), messages)
        assertTrue(helmRequests.isEmpty(), "an invalid AppInstance is never rendered: $helmRequests")
    }

    @Test
    fun `unknown apps, missing files and missing targets are reported`() {
        write("us-dev/cash/source-nothing/app-common/application.yml", "a: 1\n")
        write("us-dev/cash/source-database/app-common/application.yml", "a: 1\n")
        write("us-dev/cash/source-database/trades-db-to-amps/application.yml", "a: 1\n")
        val messages = lint().text()
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
        val messages = findings.text()
        assertTrue(findings.checks().containsAll(setOf(9, 10)), messages)
        assertTrue(messages.contains("'spring.datasource.password' is a secret property"), messages)
        assertTrue(messages.contains("IMAGE_TAG 'latest' in us-prod must be an immutable release tag"), messages)
        assertTrue(messages.contains("image.tag 'latest' in us-prod must be an immutable release tag"), messages)
    }

    @Test
    fun `targets must match the instance directories`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/targets.yml", "env: us-dev\ntargets:\n  - instance: cash/source-database/gone\n    kind: compose\n" +
            "    host: h\n    user: Root!\n  - instance: cash/source-database/trades-db-to-amps\n    kind: helm\n")
        val messages = lint().filter { it.check == 11 }.text()
        assertTrue(messages.contains("cash/source-database/gone has no directory"), messages)
        assertTrue(messages.contains("kind helm needs cluster"), messages)
        assertTrue(messages.contains("user 'Root!' is not a valid login name"), messages)
    }

    @Test
    fun `a failing render is an error and a missing compose CLI only a warning`() {
        validInstance("local", "trades-db-to-amps")
        val failed = lint { CommandResult(1, "services.app.image: invalid reference") }
        assertTrue(failed.any { it.check == 6 && it.severity == Severity.ERROR }, failed.text())
        val skipped = lint { null }
        assertTrue(skipped.any { it.check == 6 && it.severity == Severity.WARN }, skipped.text())
    }

    @Test
    fun `checks 7 and 8 are reported as TODO`() {
        validInstance("local", "trades-db-to-amps")
        val todo = ConfigLinter(config, mapOf("source-database" to template), emptySet()).lint().filter { it.severity == Severity.TODO }
        assertEquals(listOf(7, 8), todo.map { it.check })
    }

    // --- demo step 2: values.yaml (checks 3, 4, 10) and helm (check 12) ------------------------------------

    @Test
    fun `check 3 requires values_yaml in app-common and in every instance`() {
        validInstance("local", "trades-db-to-amps")
        File(config, "local/cash/source-database/app-common/values.yaml").delete()
        File(config, "local/cash/source-database/trades-db-to-amps/values.yaml").delete()
        val findings = lint().filter { it.check == 3 }
        val messages = findings.text()
        assertEquals(2, findings.size, messages)
        assertTrue(messages.contains("app-common/values.yaml: required file missing (Helm values layer 2"), messages)
        assertTrue(messages.contains("trades-db-to-amps/values.yaml: required file missing (Helm values layer 3"), messages)
        assertTrue(helmRequests.isEmpty(), "no helm run without the values layers: $helmRequests")
    }

    @Test
    fun `check 4 compares identity, APP variables and image_tag with the path and compose_env`() {
        validInstance("us-dev", "trades-db-to-amps", tag = "0.1.0-rc.39")
        write("us-dev/targets.yml", "env: us-dev\ntargets:\n  - instance: cash/source-database/trades-db-to-amps\n" +
            "    kind: compose\n    host: h\n")
        write("us-dev/cash/source-database/trades-db-to-amps/values.yaml",
            "image:\n  tag: \"0.1.0-rc.38\"\nidentity:\n  env: us-dev\n  flow: cash\n  app: source-database\n" +
                "  instance: positions-db-to-deephaven\nenv:\n  APP_ENV: us-dev\n  APP_FLOW: swap\n  APP_NAME: source-database\n" +
                "  JAVA_OPTS: \"-XX:MaxRAMPercentage=75\"\n  SPRING_DATASOURCE_PASSWORD: x\n  MEM_LIMIT: 1g\n  IMAGE_TAG: x\n")
        write("us-dev/cash/source-database/app-common/values.yaml",
            "image:\n  tag: \"0.1.0\"\nenv:\n  TZ: UTC\n  APP_INSTANCE: shared\n  ACTUATOR_HOST_PORT: \"18081\"\n")
        val findings = lint()
        val messages = findings.text()
        for (expected in listOf(
            "identity.instance=positions-db-to-deephaven does not match the directory path (trades-db-to-amps)",
            "env.APP_FLOW=swap does not match the directory path (cash)",
            "env.APP_INSTANCE=shared does not match the directory path (trades-db-to-amps)",
            "image.tag '0.1.0-rc.38' differs from IMAGE_TAG '0.1.0-rc.39' in compose.env",
            "env.SPRING_DATASOURCE_PASSWORD is forbidden",
            "env.MEM_LIMIT is not an app-facing variable",
            "env.IMAGE_TAG is not an app-facing variable",
            "env.ACTUATOR_HOST_PORT is not an app-facing variable",
            "app-common/values.yaml: image.tag belongs in <AppInstance>/values.yaml",
            "app-common/values.yaml: env.APP_INSTANCE belongs in <AppInstance>/values.yaml",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
        val divergent = findings.single { it.severity == Severity.WARN && it.check == 4 }
        assertTrue(divergent.message.contains("env.JAVA_OPTS=-XX:MaxRAMPercentage=75 differs from JAVA_OPTS=-XX:MaxRAMPercentage=60"),
            divergent.toString())
    }

    @Test
    fun `check 4 requires the identity map and every APP variable`() {
        validInstance("local", "trades-db-to-amps")
        write("local/cash/source-database/trades-db-to-amps/values.yaml", "image:\n  tag: \"local\"\nenv:\n  TZ: UTC\n")
        val messages = lint().filter { it.check == 4 }.text()
        assertTrue(messages.contains("identity missing: must restate the directory path"), messages)
        for (key in ConfigRules.IDENTITY) assertTrue(messages.contains("env.$key missing"), messages)
        assertTrue(messages.contains("JAVA_OPTS is set in compose.env (-XX:MaxRAMPercentage=60) but not in the values env"), messages)
    }

    @Test
    fun `check 10 applies the tag policy to image_tag`() {
        validInstance("us-prod", "trades-db-to-amps", tag = "1.4.2")
        validInstance("us-prod", "positions-db-to-deephaven", tag = "1.4.2")
        validInstance("local", "trades-db-to-amps", tag = "1.0")
        write("us-prod/cash/source-database/trades-db-to-amps/values.yaml",
            instanceValues("us-prod", "trades-db-to-amps", "1.4").replace("image:\n", "image:\n  digest: sha256:abc\n"))
        write("local/cash/source-database/trades-db-to-amps/values.yaml",
            instanceValues("local", "trades-db-to-amps").replace("tag: \"local\"", "tag: 1.0"))
        val findings = lint().filter { it.check == 10 }
        val messages = findings.text()
        assertTrue(messages.contains("image.tag '1.4' in us-prod must be an immutable release tag"), messages)
        assertTrue(messages.contains("image.digest 'sha256:abc' must be sha256:<64 hex digits>"), messages)
        assertTrue(messages.contains("image.tag must be a string: quote it (\"1.0\")"), messages)
        assertFalse(messages.contains("positions-db-to-deephaven"), "1.4.2 is a release tag: $messages")
    }

    @Test
    fun `check 12 lints and renders every instance through the deploy script, then runs kubeconform`() {
        validInstance("local", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven", tag = "0.1.0-rc.39")
        write("us-dev/targets.yml", "env: us-dev\ntargets:\n  - instance: cash/source-database/positions-db-to-deephaven\n" +
            "    kind: helm\n    cluster: kind-ci\n    namespace: \"{flow}\"\n")
        val validated = mutableListOf<File>()
        val findings = linter(validator = { file -> validated += file; CommandResult(0, kubeconform(valid = 5)) }).lint()
            .filter { it.severity != Severity.TODO }
        assertEquals(emptyList<Finding>(), findings)
        assertEquals(
            listOf("local/trades-db-to-amps/local/LINT", "local/trades-db-to-amps/local/TEMPLATE",
                "us-dev/positions-db-to-deephaven/0.1.0-rc.39/LINT", "us-dev/positions-db-to-deephaven/0.1.0-rc.39/TEMPLATE"),
            helmRequests.map { "${it.env}/${it.instance}/${it.tag}/${it.mode}" })
        assertTrue(helmRequests.all { it.chart == chart && it.flow == "cash" && it.app == "source-database" })
        assertEquals(listOf(null, File(rendered, "local/cash/source-database/trades-db-to-amps.yaml")),
            helmRequests.take(2).map { it.renderOut })
        assertEquals(helmRequests.mapNotNull { it.renderOut }, validated)
    }

    @Test
    fun `check 12 failures are errors, and a missing or old Helm is reported once`() {
        validInstance("local", "trades-db-to-amps")
        validInstance("local", "positions-db-to-deephaven")
        val lintFails = linter(helm = { r -> CommandResult(if (r.mode == HelmMode.LINT) 1 else 0, "[ERROR] values.yaml: - at '/env/SPRING_X': false schema") })
            .lint().filter { it.check == 12 }
        assertEquals(2, lintFails.size, lintFails.text())
        assertTrue(lintFails.all { it.severity == Severity.ERROR && it.message.contains("helm lint failed") }, lintFails.text())
        assertTrue(lintFails[0].message.contains("false schema"), lintFails.text())

        val templateFails = linter(helm = { r -> CommandResult(if (r.mode == HelmMode.TEMPLATE) 1 else 0, "Error: execution error: env.APP_ENV") })
            .lint().filter { it.check == 12 }
        assertTrue(templateFails.all { it.severity == Severity.ERROR && it.message.contains("helm template failed") }, templateFails.text())

        val oldHelm = CommandResult(5, "helm-deploy-instance: error: Helm v3.19.0 found: this script needs Helm 4")
        val warned = linter(helm = { oldHelm }).lint().filter { it.check == 12 }
        assertEquals(1, warned.size, warned.text())
        assertEquals(Severity.WARN, warned[0].severity)
        assertTrue(warned[0].message.contains("Helm v3.19.0 found"), warned.text())
        val required = linter(helm = { oldHelm }, requireRender = true).lint().filter { it.check == 12 }
        assertEquals(listOf(Severity.ERROR), required.map { it.severity })
        val off = linter(helm = null).lint().filter { it.check == 12 }
        assertEquals(1, off.size, off.text())
        assertTrue(off[0].message.contains("-PconfigLint.helm=none"), off.text())
    }

    @Test
    fun `check 12 reports kubeconform rejections, vacuous passes and its absence`() {
        validInstance("local", "trades-db-to-amps")
        val rejected = linter(validator = {
            CommandResult(1, kubeconform(valid = 4, resources = "{\"filename\": \"x.yaml\", \"kind\": \"Deployment\", \"name\": " +
                "\"source-database-trades-db-to-amps\", \"version\": \"apps/v1\", \"status\": \"statusInvalid\", \"msg\": \"\", " +
                "\"validationErrors\": [{\"path\": \"/spec/replicas\", \"msg\": \"expected integer\"}]}"))
        }).lint().filter { it.check == 12 }
        assertEquals(Severity.ERROR, rejected.single().severity)
        assertTrue(rejected.single().message.contains("Deployment source-database-trades-db-to-amps: statusInvalid /spec/replicas: expected integer"),
            rejected.text())

        val vacuous = linter(validator = { CommandResult(0, kubeconform(valid = 0, skipped = 5)) }).lint().filter { it.check == 12 }
        assertEquals(Severity.WARN, vacuous.single().severity)
        assertTrue(vacuous.single().message.contains("kubeconform validated no resource"), vacuous.text())

        val absent = linter(validator = null).lint().filter { it.check == 12 }
        assertEquals(Severity.WARN, absent.single().severity)
        assertTrue(absent.single().message.contains("kubeconform not available: 1 rendered instance(s)"), absent.text())
    }

    @Test
    fun `check 12 needs a chart per app, an error only in complete envs`() {
        validInstance("local", "trades-db-to-amps")
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/targets.yml", "env: us-dev\ntargets:\n  - instance: cash/source-database/trades-db-to-amps\n" +
            "    kind: compose\n    host: h\n")
        val findings = linter(charts = emptyMap(), completeEnvs = setOf("local")).lint().filter { it.check == 12 }
        assertEquals(listOf("ERROR config/local/cash/source-database", "WARN config/us-dev/cash/source-database"),
            findings.map { "${it.severity} ${it.path}" }, findings.text())
        assertTrue(findings.all { it.message.contains("expected <subproject>/helm/source-database/Chart.yaml") })
        assertTrue(helmRequests.isEmpty(), "nothing to render without a chart: $helmRequests")
    }

    // --- host pools (DL-39): check 11 ------------------------------------------------------------------------

    private fun pooledTargets(pools: String, targets: String) = "env: us-dev\npools:\n$pools\ntargets:\n$targets"
    private val cashPool = "  cash:\n    hosts: [dev-cash-01.example.com, dev-cash-02.example.com]\n"

    @Test
    fun `check 11 accepts a pool whose compose targets have no host or one of its boxes`() {
        validInstance("us-dev", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven")
        write("us-dev/targets.yml", pooledTargets(
            "  cash:\n    hosts:\n      - dev-cash-01.example.com\n      - 10.0.0.2\n    user: deploy\n    root: /opt/platform\n",
            "  - instance: cash/source-database/trades-db-to-amps\n    kind: compose\n" +
                "  - instance: cash/source-database/positions-db-to-deephaven\n    kind: compose\n    host: 10.0.0.2\n"))
        write("us-dev/known_hosts", "# pinned host keys\ndev-cash-01.example.com,10.0.0.2 ssh-ed25519 " +
            "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n")
        val findings = lint()
        assertEquals(emptyList<Finding>(), findings.filter { it.check == 1 || it.check == 11 }, findings.text())
    }

    @Test
    fun `check 11 rejects a host that is not a box of the flow's pool`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/targets.yml", pooledTargets(cashPool,
            "  - instance: cash/source-database/trades-db-to-amps\n    kind: compose\n    host: dev-other-01.example.com\n"))
        val findings = lint().filter { it.check == 11 }
        assertEquals(1, findings.size, findings.text())
        assertEquals(Severity.ERROR, findings[0].severity)
        assertTrue(findings[0].message.contains("host 'dev-other-01.example.com' is not a box of pools.cash " +
            "(dev-cash-01.example.com, dev-cash-02.example.com)"), findings.text())
    }

    @Test
    fun `check 11 rejects bad host names, users, roots and flows in pools`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/targets.yml", pooledTargets(
            "  cash:\n    hosts: [Dev_Cash_01.example.com, dev-cash-02.example.com., 42]\n    user: Root!\n" +
                "    root: opt/platform\n  deriv:\n    hosts: []\n    root: /opt/../etc\n    port: 22\n  fx:\n    hosts: [h]\n",
            "  - instance: cash/source-database/trades-db-to-amps\n    kind: compose\n"))
        val messages = lint().filter { it.check == 11 && it.severity == Severity.ERROR }.text()
        for (expected in listOf(
            "pools.cash.hosts[0]: 'Dev_Cash_01.example.com' is not a lower-case DNS name or IPv4 address",
            "pools.cash.hosts[1]: 'dev-cash-02.example.com.' is not a lower-case DNS name or IPv4 address",
            "pools.cash.hosts[2]: '42' is not a lower-case DNS name or IPv4 address",
            "pools.cash.user 'Root!' is not a valid login name",
            "pools.cash.root 'opt/platform' must be an absolute path",
            "pools.deriv.hosts must be a non-empty list",
            "pools.deriv.root '/opt/../etc' must be an absolute path",
            "pools.deriv: unknown key 'port'",
            "pools.fx: flow 'fx' must be one of [cash, deriv, swap]",
        )) {
            assertTrue(messages.contains(expected), "missing '$expected' in:\n$messages")
        }
    }

    @Test
    fun `check 11 rejects a box listed twice, within one pool or across pools`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/targets.yml", pooledTargets(
            "  cash:\n    hosts: [dev-01.example.com, dev-02.example.com, dev-01.example.com]\n" +
                "  swap:\n    hosts: [dev-02.example.com, dev-03.example.com]\n",
            "  - instance: cash/source-database/trades-db-to-amps\n    kind: compose\n"))
        val messages = lint().filter { it.check == 11 && it.severity == Severity.ERROR }.text()
        assertTrue(messages.contains("pools.cash.hosts[2]: dev-01.example.com is listed twice"), messages)
        assertTrue(messages.contains("pools.swap.hosts[0]: dev-02.example.com is already a box of pools.cash " +
            "(a box belongs to one pool)"), messages)
    }

    @Test
    fun `check 11 needs a host or a pool for every compose target`() {
        validInstance("us-dev", "trades-db-to-amps")
        validInstance("us-dev", "positions-db-to-deephaven")
        write("us-dev/targets.yml", "env: us-dev\npools:\n  deriv:\n    hosts: [dev-deriv-01.example.com]\n" +
            "defaults:\n  kind: compose\ntargets:\n  - instance: cash/source-database/trades-db-to-amps\n" +
            "  - instance: cash/source-database/positions-db-to-deephaven\n    host: Not_A_Host\n")
        val messages = lint().filter { it.check == 11 && it.severity == Severity.ERROR }.text()
        assertTrue(messages.contains("targets[0]: kind compose needs host, or a pool for its flow (pools.cash)"), messages)
        assertTrue(messages.contains("targets[1]: host 'Not_A_Host' is not a lower-case DNS name or IPv4 address"), messages)
    }

    @Test
    fun `check 11 warns about a pool whose flow has no compose target, and a malformed known_hosts fails`() {
        validInstance("us-dev", "trades-db-to-amps")
        write("us-dev/targets.yml", pooledTargets(cashPool,
            "  - instance: cash/source-database/trades-db-to-amps\n    kind: helm\n    cluster: kind-ci\n    namespace: cash\n"))
        write("us-dev/known_hosts", "dev-cash-01.example.com ssh-ed25519\n")
        val findings = lint().filter { it.check == 11 }
        val warning = findings.single { it.severity == Severity.WARN }
        assertTrue(warning.message.contains("pools.cash: flow 'cash' has no compose target"), findings.text())
        val error = findings.single { it.severity == Severity.ERROR }
        assertTrue(error.path.endsWith("known_hosts") && error.message.contains("line 1: expected"), findings.text())
    }
}
