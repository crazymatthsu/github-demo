package buildlogic

import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor
import java.io.File

/**
 * config-lint (D5 §6.5): checks 1–6 and 9–11 over the config tree; 7 and 8 are reported as TODO.
 * Pure over the file system plus an optional [ComposeRenderer], so that it is unit-tested.
 */
enum class Severity { ERROR, WARN, TODO }

data class Finding(val check: Int, val severity: Severity, val path: String, val message: String) {
    override fun toString(): String = "${severity.name.padEnd(5)} check ${check.toString().padStart(2)}  $path: $message"
}

/** One `docker compose config` run (check 6). */
data class ComposeRenderRequest(
    val template: File,
    val envFile: File,
    val project: String,
    val environment: Map<String, String>,
)

fun interface ComposeRenderer {
    /** Renders and validates; `null` when no compose CLI is available. */
    fun render(request: ComposeRenderRequest): CommandResult?
}

object ConfigRules {
    val ENV = Regex("^(local|(us|jp)-(dev|qa|prod))$")
    val FLOWS = setOf("cash", "deriv", "swap")
    val TOKEN = Regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
    const val MAX_APP_NAME = 20
    const val MAX_APP_INSTANCE = 32
    const val MAX_RELEASE_NAME = 53
    const val APP_COMMON = "app-common"
    const val COMMON = "_common"

    /** D5 §6.3: the only variables `compose.env` may carry (plus `*_HOST_PORT`). */
    val COMPOSE_ENV_ALLOWED = setOf(
        "IMAGE_REPO", "IMAGE_TAG", "APP_ENV", "APP_FLOW", "APP_NAME", "APP_INSTANCE",
        "JAVA_OPTS", "TZ", "LOG_LEVEL_ROOT", "LOGS_DIR", "DATA_DIR", "MEM_LIMIT",
    )
    val HOST_PORT = Regex("^[A-Z][A-Z0-9_]*_HOST_PORT$")
    val FORBIDDEN_PREFIXES = listOf("SPRING_", "LOGGING_", "MANAGEMENT_", "CONNECTOR_")

    /** Variables `run-compose.sh` sets itself; an instance may never define them (D5 §6.3, D6 §6.2). */
    val SCRIPT_VARIABLES = setOf("CONFIG_DIR", "COMMON_DIR", "PLATFORM_DIR", "ENV_COMMON_DIR", "PROJECT")
    val IDENTITY = listOf("APP_ENV", "APP_FLOW", "APP_NAME", "APP_INSTANCE")

    /** D2 §6.4: secret properties; none of them may appear in any YAML layer. */
    val SECRET_PROPERTIES = listOf(
        "spring.datasource.username", "spring.datasource.password",
        "connector.amps.username", "connector.amps.password",
        "connector.kafka.sasl", "connector.deephaven.token", "connector.tls.keystore.password",
    )

    val DOCKER_TAG = Regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
    val RELEASE_TAG = Regex("""^\d+\.\d+\.\d+(@sha256:[0-9a-f]{64})?$""")

    val SECRET_VALUE_PATTERNS = listOf(
        Regex("-----BEGIN [A-Z ]*PRIVATE KEY-----") to "PEM private key",
        Regex("\\bAKIA[0-9A-Z]{16}\\b") to "AWS access key id",
        Regex("\\bgh[pousr]_[A-Za-z0-9]{36,}\\b") to "GitHub token",
        Regex("\\bxox[baprs]-[A-Za-z0-9-]{10,}") to "Slack token",
        Regex("(?i)\\b(password|passwd|pwd|secret|token|api[-_]?key)\\b\\s*[:=]\\s*['\"]?(?!\\$\\{)[^\\s'\"#]{4,}") to
            "literal value for a secret-looking key",
        Regex("(?i)jdbc:[^\\s]*;password=[^;\\s\${]+") to "password inside a JDBC URL",
    )

    fun normalise(key: String): String = key.lowercase().replace("-", "").replace("_", "")

    fun isSecretProperty(key: String): Boolean {
        val k = normalise(key)
        return SECRET_PROPERTIES.any { s -> val n = normalise(s); k == n || k.startsWith("$n.") }
    }
}

class ConfigLinter(
    private val configRoot: File,
    /** Deployable AppName -> its compose template (`<subproject>/docker/docker-compose.yml`). */
    private val apps: Map<String, File>,
    /** Envs in which every deployable app must have configuration (check 2, "vice versa"). */
    private val completeEnvs: Set<String> = setOf("local"),
    private val renderer: ComposeRenderer? = null,
    /** When true, a missing compose CLI fails check 6 instead of warning. */
    private val requireRender: Boolean = false,
) {
    private val findings = mutableListOf<Finding>()
    private val yaml = Yaml(SafeConstructor(LoaderOptions()))

    private fun rel(file: File): String = file.relativeTo(configRoot.parentFile ?: configRoot).path

    private fun error(check: Int, file: File, message: String) { findings += Finding(check, Severity.ERROR, rel(file), message) }
    private fun warn(check: Int, file: File, message: String) { findings += Finding(check, Severity.WARN, rel(file), message) }

    fun lint(): List<Finding> {
        findings.clear()
        if (!configRoot.isDirectory) {
            error(3, configRoot, "config tree not found")
            return findings.toList()
        }
        val children = configRoot.listFiles().orEmpty().sortedBy { it.name }
        for (child in children) {
            when {
                child.isFile && child.name == "README.md" -> Unit
                child.isDirectory && child.name == ConfigRules.COMMON -> lintPlatformLayer(child)
                child.isDirectory -> lintEnv(child)
                else -> error(1, child, "unexpected file at the top of config/ (only <env>/, _common/ and README.md)")
            }
        }
        configRoot.walkTopDown().filter { it.isFile }.sortedBy { it.path }.forEach { scanSecrets(it) }
        findings += Finding(7, Severity.TODO, "config", "merged-configuration validation against " +
            "spring-configuration-metadata.json is not implemented yet (D5 §6.5 check 7)")
        findings += Finding(8, Severity.TODO, "config", "parity report across us-dev / us-qa / us-prod is not " +
            "implemented yet (D5 §6.5 check 8)")
        return findings.toList()
    }

    // --- layers ---------------------------------------------------------------------------------------

    private fun lintPlatformLayer(dir: File) {
        for (appDir in dir.listFiles().orEmpty().sortedBy { it.name }) {
            if (!appDir.isDirectory) {
                if (appDir.name != "README.md") error(1, appDir, "unexpected file in config/_common/ (expected <AppName>/)")
                continue
            }
            checkAppName(appDir)
            lintLayerFiles(appDir, allowComposeEnv = false)
        }
    }

    private fun lintEnv(envDir: File) {
        val env = envDir.name
        if (!ConfigRules.ENV.matches(env)) {
            error(1, envDir, "env '$env' must be local or <region>-<stage> with region us|jp and stage dev|qa|prod")
            return
        }
        val targetsFile = File(envDir, "targets.yml")
        val instances = mutableListOf<Triple<String, String, String>>()
        val appsSeen = mutableSetOf<String>()
        for (child in envDir.listFiles().orEmpty().sortedBy { it.name }) {
            when {
                child.isFile && child.name == "targets.yml" -> Unit
                child.isFile && child.name == "README.md" -> Unit
                child.isDirectory && child.name == ConfigRules.COMMON -> lintLayerFiles(child, allowComposeEnv = false)
                child.isDirectory && child.name in ConfigRules.FLOWS -> lintFlow(child, env, instances, appsSeen)
                child.isDirectory -> error(1, child, "flow '${child.name}' must be one of ${ConfigRules.FLOWS.sorted()}")
                else -> error(1, child, "unexpected file in config/$env/ (expected targets.yml, _common/, <flow>/)")
            }
        }
        if (env in completeEnvs) {
            for (app in apps.keys.sorted()) {
                if (app !in appsSeen) error(2, envDir, "deployable app '$app' has no configuration in env '$env' (every app must)")
            }
        }
        if (env.endsWith("-dev")) {
            if (!targetsFile.isFile) error(3, targetsFile, "required for a *-dev env (deploy-dev inventory, D5 §6.6)")
            else lintTargets(targetsFile, env, instances)
        } else if (targetsFile.isFile) {
            warn(11, targetsFile, "only *-dev envs are deployed from targets.yml; this file is ignored")
            lintTargets(targetsFile, env, instances)
        }
    }

    private fun lintFlow(flowDir: File, env: String, instances: MutableList<Triple<String, String, String>>, appsSeen: MutableSet<String>) {
        for (appDir in flowDir.listFiles().orEmpty().sortedBy { it.name }) {
            if (!appDir.isDirectory) {
                error(1, appDir, "unexpected file in a flow directory (expected <AppName>/)")
                continue
            }
            val app = appDir.name
            appsSeen += app
            checkAppName(appDir)
            val common = File(appDir, ConfigRules.APP_COMMON)
            if (!common.isDirectory) {
                error(3, common, "required: every <env>/<flow>/<AppName>/ has app-common/application.yml")
            } else {
                if (!File(common, "application.yml").isFile) error(3, File(common, "application.yml"), "required file missing")
                lintLayerFiles(common, allowComposeEnv = false)
            }
            for (instDir in appDir.listFiles().orEmpty().sortedBy { it.name }) {
                if (instDir.name == ConfigRules.APP_COMMON) continue
                if (!instDir.isDirectory) {
                    error(1, instDir, "unexpected file in an app directory (expected app-common/ and <AppInstance>/)")
                    continue
                }
                instances += Triple(flowDir.name, app, instDir.name)
                lintInstance(instDir, env, flowDir.name, app)
            }
        }
    }

    private fun checkAppName(appDir: File) {
        val app = appDir.name
        if (!ConfigRules.TOKEN.matches(app) || app.length > ConfigRules.MAX_APP_NAME) {
            error(1, appDir, "AppName must match ${ConfigRules.TOKEN.pattern} and be at most ${ConfigRules.MAX_APP_NAME} characters")
        }
        if (app !in apps) {
            error(2, appDir, "'$app' is not a deployable Gradle subproject (known: ${apps.keys.sorted().joinToString()})")
        }
    }

    private fun lintInstance(dir: File, env: String, flow: String, app: String) {
        val instance = dir.name
        when {
            !ConfigRules.TOKEN.matches(instance) ->
                error(1, dir, "AppInstance must match ${ConfigRules.TOKEN.pattern}")
            instance.all { it.isDigit() } ->
                error(1, dir, "AppInstance is a business-logic name, never a bare number (DL-37)")
            instance.length > ConfigRules.MAX_APP_INSTANCE ->
                error(1, dir, "AppInstance is ${instance.length} characters, at most ${ConfigRules.MAX_APP_INSTANCE}")
            "$app-$instance".length > ConfigRules.MAX_RELEASE_NAME ->
                error(1, dir, "'$app-$instance' exceeds the ${ConfigRules.MAX_RELEASE_NAME}-character Helm release budget")
        }
        val composeEnv = File(dir, "compose.env")
        val appYml = File(dir, "application.yml")
        if (!appYml.isFile) error(3, appYml, "required file missing")
        if (!composeEnv.isFile) {
            error(3, composeEnv, "required file missing")
        } else {
            val vars = parseEnvFile(composeEnv)
            if (vars != null) {
                checkComposeEnv(composeEnv, vars, env, flow, app, instance)
                render(dir, composeEnv, vars, env, flow, app, instance)
            }
        }
        lintLayerFiles(dir, allowComposeEnv = true)
    }

    /** Every file of a layer directory: YAML parses, no forbidden env files, secret scan. */
    private fun lintLayerFiles(dir: File, allowComposeEnv: Boolean) {
        for (file in dir.listFiles().orEmpty().sortedBy { it.name }) {
            if (file.isDirectory) {
                error(1, file, "layer directories are flat: nested directory not allowed")
                continue
            }
            val name = file.name
            when {
                name == "compose.env" && !allowComposeEnv ->
                    error(3, file, "compose.env belongs to an <AppInstance>/ directory only")
                name != "compose.env" && (name == ".env" || name.endsWith(".env")) ->
                    error(3, file, "forbidden: the only env file allowed is <AppInstance>/compose.env")
                name.endsWith(".yml") || name.endsWith(".yaml") -> lintYaml(file)
            }
        }
    }

    private fun lintYaml(file: File) {
        val documents = try {
            yaml.loadAll(file.readText()).toList()
        } catch (e: Exception) {
            error(3, file, "YAML does not parse: ${e.message?.lineSequence()?.firstOrNull()}")
            return
        }
        for (doc in documents) {
            for (key in flatten(doc)) {
                if (ConfigRules.isSecretProperty(key)) {
                    error(9, file, "'$key' is a secret property (D2 §6.4): it arrives from the environment or " +
                        "/secrets/, never from the config tree")
                }
            }
        }
    }

    private fun flatten(node: Any?, prefix: String = ""): List<String> = when (node) {
        is Map<*, *> -> node.entries.flatMap { (k, v) ->
            val key = if (prefix.isEmpty()) k.toString() else "$prefix.$k"
            flatten(v, key).ifEmpty { listOf(key) }
        }
        is List<*> -> node.flatMapIndexed { i, v -> flatten(v, "$prefix[$i]") }
        else -> if (prefix.isEmpty()) emptyList() else listOf(prefix)
    }

    // --- compose.env ------------------------------------------------------------------------------------

    /** `KEY=VALUE` lines, `#` comments; null (after reporting) when the file is malformed. */
    internal fun parseEnvFile(file: File): Map<String, String>? {
        val vars = linkedMapOf<String, String>()
        var ok = true
        file.readLines().forEachIndexed { index, raw ->
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) return@forEachIndexed
            val match = Regex("^([A-Za-z_][A-Za-z0-9_]*)=(.*)$").matchEntire(line)
            if (match == null) {
                error(5, file, "line ${index + 1} is not KEY=VALUE")
                ok = false
                return@forEachIndexed
            }
            val (key, value) = match.destructured
            if (key in vars) error(5, file, "line ${index + 1}: $key defined twice")
            vars[key] = value.trim().removeSurrounding("\"").removeSurrounding("'")
        }
        return if (ok) vars else null
    }

    private fun checkComposeEnv(file: File, vars: Map<String, String>, env: String, flow: String, app: String, instance: String) {
        // Check 5: allow-list.
        for (key in vars.keys) {
            when {
                ConfigRules.FORBIDDEN_PREFIXES.any { key.startsWith(it) } ->
                    error(5, file, "$key is forbidden in compose.env (SPRING_/LOGGING_/MANAGEMENT_/CONNECTOR_ belong " +
                        "in YAML; secrets are passed through from the shell, D5 §6.3)")
                key in ConfigRules.SCRIPT_VARIABLES ->
                    error(5, file, "$key is set by run-compose.sh and must not appear in compose.env")
                key !in ConfigRules.COMPOSE_ENV_ALLOWED && !ConfigRules.HOST_PORT.matches(key) ->
                    error(5, file, "$key is not an allowed compose.env variable (D5 §6.3)")
            }
        }
        // Check 4: identity restated equals the path.
        val expected = mapOf("APP_ENV" to env, "APP_FLOW" to flow, "APP_NAME" to app, "APP_INSTANCE" to instance)
        for ((key, value) in expected) {
            val actual = vars[key]
            if (actual == null) error(4, file, "$key missing (must restate the directory path: $value)")
            else if (actual != value) error(4, file, "$key=$actual does not match the directory path ($value)")
        }
        // Check 10: tag policy.
        val tag = vars["IMAGE_TAG"]
        if (tag == null) {
            error(10, file, "IMAGE_TAG missing")
        } else {
            val bareTag = tag.substringBefore('@')
            if (!ConfigRules.DOCKER_TAG.matches(bareTag)) error(10, file, "IMAGE_TAG '$tag' is not a valid image tag")
            val immutableEnv = env.endsWith("-qa") || env.endsWith("-prod")
            if (immutableEnv && !ConfigRules.RELEASE_TAG.matches(tag)) {
                error(10, file, "IMAGE_TAG '$tag' in $env must be an immutable release tag X.Y.Z (optionally " +
                    "@sha256:<digest>); floating tags are allowed only in *-dev and local (DL-20)")
            }
        }
        if (vars["IMAGE_REPO"].isNullOrBlank()) error(5, file, "IMAGE_REPO missing")
        for ((key, value) in vars) {
            if (ConfigRules.HOST_PORT.matches(key) && value.toIntOrNull()?.let { it in 1024..65535 } != true) {
                error(5, file, "$key=$value must be a port in 1024..65535 (rootless Podman, D6 §6.6)")
            }
        }
    }

    // --- check 6: render --------------------------------------------------------------------------------

    private val templateVariable = Regex("""\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-?+][^}]*)?}""")

    private fun render(dir: File, composeEnv: File, vars: Map<String, String>, env: String, flow: String, app: String, instance: String) {
        val template = apps[app] ?: return // check 2 already reported it
        val r = renderer ?: return
        val appDir = dir.parentFile
        val envDir = appDir.parentFile.parentFile
        val environment = linkedMapOf(
            "APP_ENV" to env, "APP_FLOW" to flow, "APP_NAME" to app, "APP_INSTANCE" to instance,
            "CONFIG_DIR" to dir.absolutePath,
            "COMMON_DIR" to File(appDir, ConfigRules.APP_COMMON).absolutePath,
            "PROJECT" to "$env-$flow-$app-$instance",
        )
        File(configRoot, "${ConfigRules.COMMON}/$app").takeIf { it.isDirectory }?.let { environment["PLATFORM_DIR"] = it.absolutePath }
        File(envDir, ConfigRules.COMMON).takeIf { it.isDirectory }?.let { environment["ENV_COMMON_DIR"] = it.absolutePath }
        // Placeholders for every required variable nobody else provides: the secrets passed through the shell.
        for (match in templateVariable.findAll(template.readText())) {
            val (name, modifier) = match.destructured
            val required = modifier.startsWith(":?") || modifier.startsWith("?")
            if (required && name !in environment && name !in vars) environment[name] = "config-lint-placeholder"
        }
        val result = r.render(ComposeRenderRequest(template, composeEnv, "lint-$env-$flow-$app-$instance", environment))
        when {
            result == null && requireRender -> error(6, composeEnv, "no compose CLI (docker compose / podman compose) to render the template")
            result == null -> warn(6, composeEnv, "render skipped: no compose CLI (docker compose / podman compose) found")
            result.exitCode != 0 -> error(6, composeEnv, "`compose config` failed for ${rel(template)}:\n" +
                result.output.lineSequence().filter { it.isNotBlank() }.joinToString("\n") { "      $it" })
        }
    }

    // --- check 9: secret scan ---------------------------------------------------------------------------

    private fun scanSecrets(file: File) {
        if (!file.isFile || file.length() > 1_000_000) return
        val lines = try { file.readLines() } catch (e: Exception) { return }
        lines.forEachIndexed { index, line ->
            if (line.trimStart().startsWith("#")) return@forEachIndexed
            for ((pattern, what) in ConfigRules.SECRET_VALUE_PATTERNS) {
                if (pattern.containsMatchIn(line)) error(9, file, "line ${index + 1} looks like a secret ($what)")
            }
        }
    }

    // --- check 11: targets.yml --------------------------------------------------------------------------

    private fun lintTargets(file: File, env: String, instances: List<Triple<String, String, String>>) {
        val doc = try {
            yaml.load<Any?>(file.readText())
        } catch (e: Exception) {
            error(11, file, "YAML does not parse: ${e.message?.lineSequence()?.firstOrNull()}")
            return
        }
        if (doc !is Map<*, *>) {
            error(11, file, "must be a mapping with env, defaults, targets")
            return
        }
        (doc.keys.map { it.toString() } - setOf("env", "defaults", "targets")).forEach {
            error(11, file, "unknown top-level key '$it' (allowed: env, defaults, targets)")
        }
        if (doc["env"]?.toString() != env) error(11, file, "env: must be '$env' (was '${doc["env"]}')")
        val entryKeys = setOf("kind", "host", "cluster", "namespace")
        val defaults = doc["defaults"] ?: emptyMap<String, Any>()
        if (defaults !is Map<*, *>) {
            error(11, file, "defaults: must be a mapping")
            return
        }
        (defaults.keys.map { it.toString() } - entryKeys).forEach { error(11, file, "defaults: unknown key '$it'") }
        val targets = doc["targets"]
        if (targets !is List<*>) {
            error(11, file, "targets: must be a list")
            return
        }
        val known = instances.map { (f, a, i) -> "$f/$a/$i" }.toSet()
        val listed = mutableSetOf<String>()
        targets.forEachIndexed { index, entry ->
            val where = "targets[$index]"
            if (entry !is Map<*, *>) {
                error(11, file, "$where must be a mapping")
                return@forEachIndexed
            }
            (entry.keys.map { it.toString() } - (entryKeys + "instance")).forEach { error(11, file, "$where: unknown key '$it'") }
            val instance = entry["instance"]?.toString()
            if (instance == null || !Regex("^[a-z]+/[a-z0-9-]+/[a-z0-9-]+$").matches(instance)) {
                error(11, file, "$where: instance must be <flow>/<AppName>/<AppInstance>")
                return@forEachIndexed
            }
            if (!listed.add(instance)) error(11, file, "$where: $instance listed twice")
            if (instance !in known) error(11, file, "$where: $instance has no directory config/$env/$instance/")
            val effective = defaults.entries.associate { it.key.toString() to it.value } + entry.entries.associate { it.key.toString() to it.value }
            when (val kind = effective["kind"]?.toString()) {
                "compose" -> if (effective["host"]?.toString().isNullOrBlank()) error(11, file, "$where: kind compose needs host")
                "helm" -> listOf("cluster", "namespace").forEach {
                    if (effective[it]?.toString().isNullOrBlank()) error(11, file, "$where: kind helm needs $it")
                }
                else -> error(11, file, "$where: kind must be compose or helm (was '$kind')")
            }
        }
        (known - listed).sorted().forEach { error(11, file, "instance $it has no target (inventory drift)") }
    }
}
