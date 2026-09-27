package buildlogic

import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor
import java.io.File

/**
 * config-lint (D5 §6.5): checks 1–6 and 9–12 over the config tree; 7 and 8 are reported as TODO.
 * Pure over the file system plus the optional [ComposeRenderer], [HelmRunner] and [ManifestValidator], so that
 * it is unit-tested.
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

/** The two check-12 modes of `scripts/helm-deploy-instance.sh` (D11 §8.3). */
enum class HelmMode(val flag: String) { LINT("lint"), TEMPLATE("template") }

/** One `scripts/helm-deploy-instance.sh <env> <flow> <app> <instance> --tag <tag> --mode lint|template` run. */
data class HelmRequest(
    val env: String,
    val flow: String,
    val app: String,
    val instance: String,
    val tag: String,
    val chart: File,
    val mode: HelmMode,
    /** [HelmMode.TEMPLATE] only: the file the manifests are rendered to (`--render-out`). */
    val renderOut: File? = null,
)

fun interface HelmRunner {
    /** Runs the deploy script; `null` when Helm is switched off (`-PconfigLint.helm=none`). Exit 5: no usable Helm 4. */
    fun run(request: HelmRequest): CommandResult?
}

fun interface ManifestValidator {
    /** kubeconform over rendered manifests (JSON output with summary); `null` when kubeconform is not available. */
    fun validate(rendered: File): CommandResult?
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

    /** D5 §6.3: the app-facing subset — the only names a values.yaml `env:` map may carry (check 4). */
    val VALUES_ENV_ALLOWED = IDENTITY.toSet() + setOf("JAVA_OPTS", "TZ", "LOG_LEVEL_ROOT")
    /** Knobs both consumers set: compose.env and the values `env:` should agree (check 4 warns otherwise). */
    val SHARED_KNOBS = listOf("JAVA_OPTS", "TZ", "LOG_LEVEL_ROOT")
    const val VALUES = "values.yaml"
    /** The script's exit code for "no usable Helm 4" (helm-deploy-instance.sh). */
    const val EXIT_TOOL = 5

    /** D2 §6.4: secret properties; none of them may appear in any YAML layer. */
    val SECRET_PROPERTIES = listOf(
        "spring.datasource.username", "spring.datasource.password",
        "connector.amps.username", "connector.amps.password",
        "connector.kafka.sasl", "connector.deephaven.token", "connector.tls.keystore.password",
    )

    val DOCKER_TAG = Regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
    val RELEASE_TAG = Regex("""^\d+\.\d+\.\d+(@sha256:[0-9a-f]{64})?$""")
    val DIGEST = Regex("^sha256:[0-9a-f]{64}$")
    /** What `helm-deploy-instance.sh --tag` accepts: a tag, optionally pinned by digest. */
    val TAG_REFERENCE = Regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}(@sha256:[0-9a-f]{64})?$")
    /** The Kubernetes version the rendered manifests are validated against (kubeconform, check 12). */
    const val KUBERNETES_VERSION = "1.37.0"

    /** Check 11: a compose host, also every box of a flow's pool (DL-39) — a lower-case DNS name or an IPv4 address. */
    val HOST_NAME = Regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")
    /** Check 11: the SSH user of a compose host or pool (DL-35: `deploy`, whose forced command is run-compose.sh). */
    val LOGIN = Regex("^[a-z_][a-z0-9_-]{0,31}$")
    /**
     * Check 11: a pool's install root — absolute, plain path segments only (it appears in rsync targets and SSH
     * command lines), never `.` or `..`.
     */
    val POOL_ROOT = Regex("^(/[A-Za-z0-9._-]+)+/?$")
    const val POOL_USER = "deploy"
    const val POOL_ROOT_DEFAULT = "/opt/platform"
    /** A helm target's namespace once "{flow}" is substituted: a DNS label (DL-38; the flow name by default). */
    val NAMESPACE = Regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
    /** `config/<env>/known_hosts`: `[@marker] <host patterns> <key type> <base64 key> [comment]` (ssh-keyscan format). */
    val SSH_KEY_TYPE = Regex("^(ssh|ecdsa|sk)-[A-Za-z0-9@._-]+$")
    val BASE64 = Regex("^[A-Za-z0-9+/]+={0,3}$")

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
    /**
     * Envs in which every deployable app must have configuration (check 2, "vice versa") and a Helm chart
     * (check 12: ERROR there, WARN elsewhere).
     */
    private val completeEnvs: Set<String> = setOf("local"),
    private val renderer: ComposeRenderer? = null,
    /** When true, a missing compose CLI (check 6) or Helm (check 12) fails instead of warning. */
    private val requireRender: Boolean = false,
    /** AppName -> its chart directory (`<subproject>/helm/<AppName>/`), for the apps that have one (check 12). */
    private val charts: Map<String, File> = emptyMap(),
    /** `scripts/helm-deploy-instance.sh --mode lint|template` (check 12); null: Helm switched off. */
    private val helm: HelmRunner? = null,
    /** kubeconform over the rendered manifests (check 12); null: not available. */
    private val validator: ManifestValidator? = null,
    /** Where check 12 keeps `<env>/<flow>/<AppName>/<AppInstance>.yaml`; null: temporary files. */
    private val renderDir: File? = null,
) {
    private val findings = mutableListOf<Finding>()
    private val yaml = Yaml(SafeConstructor(LoaderOptions()))
    private var helmSkipped = false
    private var unvalidated = 0

    private fun rel(file: File): String = file.relativeTo(configRoot.parentFile ?: configRoot).path

    private fun error(check: Int, file: File, message: String) { findings += Finding(check, Severity.ERROR, rel(file), message) }
    private fun warn(check: Int, file: File, message: String) { findings += Finding(check, Severity.WARN, rel(file), message) }

    fun lint(): List<Finding> {
        findings.clear()
        helmSkipped = false
        unvalidated = 0
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
        if (unvalidated > 0) {
            warn(12, configRoot, "kubeconform not available: $unvalidated rendered instance(s) not validated against the " +
                "Kubernetes ${ConfigRules.KUBERNETES_VERSION} schemas (CI installs it)")
        }
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
        val appsSeen = mutableSetOf<String>()
        val pools = mutableListOf<FlowPool>()
        for (child in envDir.listFiles().orEmpty().sortedBy { it.name }) {
            when {
                child.isFile && (child.name == "workflows-config.yml" || child.name == "targets.yml") -> error(11, child, "moved to config/$env/<flow>/workflows-config.yml: one " +
                    "deploy inventory per flow (env, flow, pool, defaults, targets; D5 §6.6, DL-39)")
                child.isFile && child.name == "README.md" -> Unit
                child.isFile && child.name == "known_hosts" -> lintKnownHosts(child)
                child.isDirectory && child.name == ConfigRules.COMMON -> lintLayerFiles(child, allowComposeEnv = false)
                child.isDirectory && child.name in ConfigRules.FLOWS -> lintFlow(child, env, appsSeen)?.let { pools += it }
                child.isDirectory -> error(1, child, "flow '${child.name}' must be one of ${ConfigRules.FLOWS.sorted()}")
                else -> error(1, child, "unexpected file in config/$env/ (expected known_hosts, _common/, <flow>/)")
            }
        }
        if (env in completeEnvs) {
            for (app in apps.keys.sorted()) {
                if (app !in appsSeen) error(2, envDir, "deployable app '$app' has no configuration in env '$env' (every app must)")
            }
        }
        checkSharedBoxes(pools)
    }

    /** Returns the flow's pool (check 11) when its workflows-config.yml declares one. */
    private fun lintFlow(flowDir: File, env: String, appsSeen: MutableSet<String>): FlowPool? {
        val instances = mutableListOf<String>()
        for (appDir in flowDir.listFiles().orEmpty().sortedBy { it.name }) {
            if (!appDir.isDirectory) {
                when (appDir.name) {
                    "workflows-config.yml" -> Unit
                    "targets.yml" -> error(11, appDir, "renamed: the flow's deploy inventory is workflows-config.yml (D5 §6.6, DL-39)")
                    else -> error(1, appDir, "unexpected file in a flow directory (expected workflows-config.yml and <AppName>/)")
                }
                continue
            }
            val app = appDir.name
            appsSeen += app
            checkAppName(appDir)
            if (app in apps && app !in charts) {
                val message = "no Helm chart for '$app': expected <subproject>/helm/$app/Chart.yaml (D11 §6.1)"
                if (env in completeEnvs) error(12, appDir, message) else warn(12, appDir, message)
            }
            val common = File(appDir, ConfigRules.APP_COMMON)
            var commonEnv: Map<String, String> = emptyMap()
            var commonComplete = false
            if (!common.isDirectory) {
                error(3, common, "required: every <env>/<flow>/<AppName>/ has app-common/application.yml and values.yaml")
            } else {
                val appYml = File(common, "application.yml")
                val values = File(common, ConfigRules.VALUES)
                if (!appYml.isFile) error(3, appYml, "required file missing")
                if (!values.isFile) error(3, values, "required file missing (Helm values layer 2, D11 §6.2)")
                else loadValues(values)?.let { commonEnv = checkCommonValues(values, it) }
                commonComplete = appYml.isFile && values.isFile
                lintLayerFiles(common, allowComposeEnv = false)
            }
            for (instDir in appDir.listFiles().orEmpty().sortedBy { it.name }) {
                if (instDir.name == ConfigRules.APP_COMMON) continue
                if (!instDir.isDirectory) {
                    error(1, instDir, "unexpected file in an app directory (expected app-common/ and <AppInstance>/)")
                    continue
                }
                instances += "$app/${instDir.name}"
                lintInstance(instDir, env, flowDir.name, app, commonEnv, commonComplete)
            }
        }
        val targetsFile = File(flowDir, "workflows-config.yml")
        return when {
            env.endsWith("-dev") && !targetsFile.isFile -> {
                error(3, targetsFile, "required in every flow of a *-dev env (the flow's deploy-dev inventory, D5 §6.6)")
                null
            }
            env.endsWith("-dev") -> lintTargets(targetsFile, env, flowDir.name, instances)
            targetsFile.isFile -> {
                warn(11, targetsFile, "only *-dev envs are deployed from workflows-config.yml; this file is ignored")
                lintTargets(targetsFile, env, flowDir.name, instances)
            }
            else -> null
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

    private fun lintInstance(
        dir: File, env: String, flow: String, app: String, commonEnv: Map<String, String>, commonComplete: Boolean,
    ) {
        val instance = dir.name
        val nameProblem = when {
            !ConfigRules.TOKEN.matches(instance) -> "AppInstance must match ${ConfigRules.TOKEN.pattern}"
            instance.all { it.isDigit() } -> "AppInstance is a business-logic name, never a bare number (DL-37)"
            instance.length > ConfigRules.MAX_APP_INSTANCE ->
                "AppInstance is ${instance.length} characters, at most ${ConfigRules.MAX_APP_INSTANCE}"
            "$app-$instance".length > ConfigRules.MAX_RELEASE_NAME ->
                "'$app-$instance' exceeds the ${ConfigRules.MAX_RELEASE_NAME}-character Helm release budget"
            else -> null
        }
        nameProblem?.let { error(1, dir, it) }
        val composeEnv = File(dir, "compose.env")
        val appYml = File(dir, "application.yml")
        val valuesFile = File(dir, ConfigRules.VALUES)
        if (!appYml.isFile) error(3, appYml, "required file missing")
        var vars: Map<String, String>? = null
        if (!composeEnv.isFile) {
            error(3, composeEnv, "required file missing")
        } else {
            vars = parseEnvFile(composeEnv)
            if (vars != null) {
                checkComposeEnv(composeEnv, vars, env, flow, app, instance)
                render(dir, composeEnv, vars, env, flow, app, instance)
            }
        }
        var values: Map<*, *>? = null
        if (!valuesFile.isFile) {
            error(3, valuesFile, "required file missing (Helm values layer 3, D11 §6.2)")
        } else {
            values = loadValues(valuesFile)
            values?.let { checkInstanceValues(valuesFile, it, commonEnv, vars, env, flow, app, instance) }
        }
        lintLayerFiles(dir, allowComposeEnv = true)
        if (nameProblem == null && commonComplete && appYml.isFile && valuesFile.isFile) {
            helmRender(dir, env, flow, app, instance, renderTag(values, vars))
        }
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
        if (tag == null) error(10, file, "IMAGE_TAG missing") else checkTag(file, "IMAGE_TAG", tag, env)
        if (vars["IMAGE_REPO"].isNullOrBlank()) error(5, file, "IMAGE_REPO missing")
        for ((key, value) in vars) {
            if (ConfigRules.HOST_PORT.matches(key) && value.toIntOrNull()?.let { it in 1024..65535 } != true) {
                error(5, file, "$key=$value must be a port in 1024..65535 (rootless Podman, D6 §6.6)")
            }
        }
    }

    /** Check 10: the tag policy, identical for `IMAGE_TAG` (compose.env) and `image.tag` (values.yaml). */
    private fun checkTag(file: File, what: String, tag: String, env: String) {
        val bareTag = tag.substringBefore('@')
        if (!ConfigRules.DOCKER_TAG.matches(bareTag)) error(10, file, "$what '$tag' is not a valid image tag")
        val immutableEnv = env.endsWith("-qa") || env.endsWith("-prod")
        if (immutableEnv && !ConfigRules.RELEASE_TAG.matches(tag)) {
            error(10, file, "$what '$tag' in $env must be an immutable release tag X.Y.Z (optionally " +
                "@sha256:<digest>); floating tags are allowed only in *-dev and local (DL-20)")
        }
    }

    // --- values.yaml (checks 3, 4, 10) ------------------------------------------------------------------

    /** A values file as a map; null when it does not parse (check 3 reports that through [lintYaml]). */
    private fun loadValues(file: File): Map<*, *>? {
        val documents = try {
            yaml.loadAll(file.readText()).toList()
        } catch (e: Exception) {
            return null
        }
        return when {
            documents.size > 1 -> { error(3, file, "a Helm values file holds one YAML document"); null }
            documents.isEmpty() || documents[0] == null -> emptyMap<String, Any>()
            documents[0] is Map<*, *> -> documents[0] as Map<*, *>
            else -> { error(3, file, "must be a YAML mapping (Helm values)"); null }
        }
    }

    /** Check 4: the `env:` map carries only app-facing variables (D5 §6.3); returns its scalar entries. */
    private fun valuesEnv(file: File, values: Map<*, *>): Map<String, String> {
        val env = values["env"] ?: return emptyMap()
        if (env !is Map<*, *>) {
            error(4, file, "env: must be a map NAME: value (the container environment, D11 §6.3)")
            return emptyMap()
        }
        val result = linkedMapOf<String, String>()
        for ((k, v) in env) {
            val key = k.toString()
            when {
                ConfigRules.FORBIDDEN_PREFIXES.any { key.startsWith(it) } ->
                    error(4, file, "env.$key is forbidden: SPRING_/LOGGING_/MANAGEMENT_/CONNECTOR_ settings belong in " +
                        "YAML, secrets in the Secret mounted at /secrets/ (D5 §6.3, D2 §6.4)")
                key !in ConfigRules.VALUES_ENV_ALLOWED ->
                    error(4, file, "env.$key is not an app-facing variable (D5 §6.3; allowed: " +
                        "${ConfigRules.VALUES_ENV_ALLOWED.sorted().joinToString()})")
            }
            when (v) {
                null -> Unit
                is Map<*, *>, is List<*> -> error(4, file, "env.$key must be a single value")
                else -> result[key] = v.toString()
            }
        }
        return result
    }

    /** app-common/values.yaml: shared values only — the tag and the identity belong to the instance. */
    private fun checkCommonValues(file: File, values: Map<*, *>): Map<String, String> {
        if ((values["image"] as? Map<*, *>)?.containsKey("tag") == true) {
            error(10, file, "image.tag belongs in <AppInstance>/values.yaml (written back per instance with IMAGE_TAG, D5 §6.8)")
        }
        if (values.containsKey("identity")) error(4, file, "identity belongs in <AppInstance>/values.yaml (the instance's path)")
        val env = valuesEnv(file, values)
        if ("APP_INSTANCE" in env) error(4, file, "env.APP_INSTANCE belongs in <AppInstance>/values.yaml")
        return env
    }

    private fun checkInstanceValues(
        file: File, values: Map<*, *>, commonEnv: Map<String, String>, vars: Map<String, String>?,
        env: String, flow: String, app: String, instance: String,
    ) {
        // Check 4: identity restated equals the path, in `identity` and in the APP_* variables.
        val path = linkedMapOf("env" to env, "flow" to flow, "app" to app, "instance" to instance)
        when (val identity = values["identity"]) {
            null -> error(4, file, "identity missing: must restate the directory path { env: $env, flow: $flow, app: $app, instance: $instance }")
            !is Map<*, *> -> error(4, file, "identity must be a map { env, flow, app, instance }")
            else -> for ((key, want) in path) {
                val got = identity[key]?.toString()
                if (got == null) error(4, file, "identity.$key missing (must restate the directory path: $want)")
                else if (got != want) error(4, file, "identity.$key=$got does not match the directory path ($want)")
            }
        }
        val effective = commonEnv + valuesEnv(file, values)
        for ((key, want) in ConfigRules.IDENTITY.zip(path.values)) {
            val got = effective[key]
            if (got == null) error(4, file, "env.$key missing (must restate the directory path: $want)")
            else if (got != want) error(4, file, "env.$key=$got does not match the directory path ($want)")
        }
        // Check 4 (warning): compose and Kubernetes should run the instance with the same knobs.
        if (vars != null) {
            for (key in ConfigRules.SHARED_KNOBS) {
                val composeValue = vars[key] ?: continue
                val helmValue = effective[key]
                if (helmValue == null) {
                    warn(4, file, "$key is set in compose.env ($composeValue) but not in the values env (app-common or instance)")
                } else if (helmValue != composeValue) {
                    warn(4, file, "env.$key=$helmValue differs from $key=$composeValue in compose.env")
                }
            }
        }
        // Checks 10 and 4: image.tag obeys the tag policy and equals IMAGE_TAG (one record, D5 §6.8).
        val image = values["image"]
        val tag = (image as? Map<*, *>)?.get("tag")
        when {
            image != null && image !is Map<*, *> -> error(10, file, "image must be a map (image.tag, image.digest)")
            tag == null -> error(10, file, "image.tag missing: the instance's image tag, equal to IMAGE_TAG in compose.env (D11 §6.2)")
            tag !is String -> error(10, file, "image.tag must be a string: quote it (\"$tag\")")
            else -> {
                checkTag(file, "image.tag", tag, env)
                val composeTag = vars?.get("IMAGE_TAG")
                if (composeTag != null && composeTag != tag) {
                    error(4, file, "image.tag '$tag' differs from IMAGE_TAG '$composeTag' in compose.env: both record " +
                        "the deployed tag and are written back together (D5 §6.8)")
                }
            }
        }
        val digest = (image as? Map<*, *>)?.get("digest")?.toString()
        if (!digest.isNullOrEmpty() && !ConfigRules.DIGEST.matches(digest)) {
            error(10, file, "image.digest '$digest' must be sha256:<64 hex digits> (DL-20)")
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

    // --- check 12: helm lint, helm template, kubeconform ------------------------------------------------

    /** The tag check 12 renders with: the instance's image.tag, else IMAGE_TAG, when the deploy script accepts it. */
    private fun renderTag(values: Map<*, *>?, vars: Map<String, String>?): String {
        val fromValues = (values?.get("image") as? Map<*, *>)?.get("tag") as? String
        return listOfNotNull(fromValues, vars?.get("IMAGE_TAG")).firstOrNull { ConfigRules.TAG_REFERENCE.matches(it) }
            ?: "config-lint"
    }

    private fun indented(output: String): String =
        output.lineSequence().filter { it.isNotBlank() }.joinToString("\n") { "      $it" }

    /** No usable Helm: reported once for the whole run (the same cause for every instance). */
    private fun helmUnavailable(dir: File, reason: String) {
        if (helmSkipped) return
        helmSkipped = true
        val message = "helm lint / helm template skipped for every instance: $reason"
        if (requireRender) error(12, dir, message) else warn(12, dir, message)
    }

    /**
     * Check 12 (D5 §6.5, D11 §6.4): `helm lint` and `helm template` of one instance through
     * scripts/helm-deploy-instance.sh — the flag list has one implementation — then kubeconform over the result.
     * `helm lint` does not evaluate the chart's `fail` guards; `helm template` does.
     */
    private fun helmRender(dir: File, env: String, flow: String, app: String, instance: String, tag: String) {
        val chart = charts[app] ?: return // reported once per app directory
        if (helmSkipped) return
        val runner = helm
        if (runner == null) {
            helmUnavailable(dir, "Helm is switched off (-PconfigLint.helm=none)")
            return
        }
        fun run(mode: HelmMode, out: File?): CommandResult? {
            val result = runner.run(HelmRequest(env, flow, app, instance, tag, chart, mode, out))
            when {
                result == null -> helmUnavailable(dir, "Helm is switched off (-PconfigLint.helm=none)")
                result.exitCode == ConfigRules.EXIT_TOOL ->
                    helmUnavailable(dir, "no usable Helm 4 (-PconfigLint.helm=auto|none|<path>):\n${indented(result.output)}")
                result.exitCode != 0 -> error(12, dir, "helm ${mode.flag} failed (scripts/helm-deploy-instance.sh $env $flow $app " +
                    "$instance --tag $tag --mode ${mode.flag}):\n${indented(result.output)}")
                else -> return result
            }
            return null
        }
        run(HelmMode.LINT, null) ?: return
        val out = renderDir?.let { File(it, "$env/$flow/$app/$instance.yaml") }
            ?: File.createTempFile("config-lint-$app-$instance-", ".yaml").apply { deleteOnExit() }
        out.parentFile.mkdirs()
        run(HelmMode.TEMPLATE, out) ?: return
        val result = validator?.validate(out)
        if (result == null) {
            unvalidated++
            return
        }
        val summary = kubeconformSummary(result.output)
        when {
            result.exitCode != 0 -> error(12, dir, "kubeconform (-strict, Kubernetes ${ConfigRules.KUBERNETES_VERSION}) " +
                "rejected ${rel(out)}:\n${indented(kubeconformProblems(result.output) ?: result.output)}")
            summary != null && (summary["valid"] ?: 0) == 0 ->
                warn(12, dir, "kubeconform validated no resource of ${rel(out)} (skipped: ${summary["skipped"]}; no schemas " +
                    "for Kubernetes ${ConfigRules.KUBERNETES_VERSION}?)")
        }
    }

    /** `{"resources": [...], "summary": {"valid": n, ...}}` of `kubeconform -output json -summary`, when it parses. */
    private fun kubeconformJson(output: String): Map<*, *>? {
        val json = output.substring(output.indexOf('{').takeIf { it >= 0 } ?: return null)
        return try { yaml.load<Any?>(json) as? Map<*, *> } catch (e: Exception) { null }
    }

    private fun kubeconformSummary(output: String): Map<String, Int>? =
        (kubeconformJson(output)?.get("summary") as? Map<*, *>)?.entries
            ?.associate { (k, v) -> k.toString() to ((v as? Number)?.toInt() ?: 0) }

    private fun kubeconformProblems(output: String): String? =
        (kubeconformJson(output)?.get("resources") as? List<*>)?.filterIsInstance<Map<*, *>>()?.joinToString("\n") { r ->
            val errors = (r["validationErrors"] as? List<*>)?.filterIsInstance<Map<*, *>>()
                ?.joinToString("; ") { "${it["path"]}: ${it["msg"]}" }
            "${r["kind"]} ${r["name"]}: ${r["status"]} ${errors ?: r["msg"] ?: ""}".trimEnd()
        }?.takeIf { it.isNotBlank() }

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

    // --- check 11: config/<env>/<flow>/workflows-config.yml (D5 §6.6) and the host pool of DL-39 --------------------

    /** The `pool` of one flow: the boxes of `<env>/<flow>`, reached as [user], the bundle under [root]. */
    private data class Pool(val hosts: List<String>, val user: String, val root: String)
    private data class FlowPool(val file: File, val flow: String, val pool: Pool)

    /** Lints one flow's inventory; returns its pool, if it declares one. [instances] are `<AppName>/<AppInstance>`. */
    private fun lintTargets(file: File, env: String, flow: String, instances: List<String>): FlowPool? {
        val doc = try {
            yaml.load<Any?>(file.readText())
        } catch (e: Exception) {
            error(11, file, "YAML does not parse: ${e.message?.lineSequence()?.firstOrNull()}")
            return null
        }
        if (doc !is Map<*, *>) {
            error(11, file, "must be a mapping with env, flow, pool, defaults, targets")
            return null
        }
        (doc.keys.map { it.toString() } - setOf("env", "flow", "pool", "defaults", "targets")).forEach {
            error(11, file, "unknown top-level key '$it' (allowed: env, flow, pool, defaults, targets)")
        }
        if (doc["env"]?.toString() != env) error(11, file, "env: must be '$env', the env of its path (was '${doc["env"]}')")
        if (doc["flow"]?.toString() != flow) error(11, file, "flow: must be '$flow', the flow of its path (was '${doc["flow"]}')")
        val pool = if (doc.containsKey("pool")) lintPool(file, doc["pool"]) else null
        val flowPool = pool?.let { FlowPool(file, flow, it) }
        // `user`: the SSH user of a compose host (DL-35: `deploy`, the default of the deploy-dev job).
        val entryKeys = setOf("kind", "host", "user", "cluster", "namespace")
        val defaults = doc["defaults"] ?: emptyMap<String, Any>()
        if (defaults !is Map<*, *>) {
            error(11, file, "defaults: must be a mapping")
            return flowPool
        }
        (defaults.keys.map { it.toString() } - entryKeys).forEach { error(11, file, "defaults: unknown key '$it'") }
        val targets = doc["targets"]
        if (targets !is List<*>) {
            error(11, file, "targets: must be a list")
            return flowPool
        }
        val listed = mutableSetOf<String>()
        var composeTargets = 0
        targets.forEachIndexed { index, entry ->
            val where = "targets[$index]"
            if (entry !is Map<*, *>) {
                error(11, file, "$where must be a mapping")
                return@forEachIndexed
            }
            (entry.keys.map { it.toString() } - (entryKeys + "instance")).forEach { error(11, file, "$where: unknown key '$it'") }
            val instance = entry["instance"]?.toString()
            if (instance == null || !Regex("^[a-z0-9-]+/[a-z0-9-]+$").matches(instance)) {
                error(11, file, "$where: instance must be <AppName>/<AppInstance>, relative to the flow (was '$instance')")
                return@forEachIndexed
            }
            if (!listed.add(instance)) error(11, file, "$where: $instance listed twice")
            if (instance !in instances) error(11, file, "$where: $instance has no directory config/$env/$flow/$instance/")
            val effective = defaults.entries.associate { it.key.toString() to it.value } + entry.entries.associate { it.key.toString() to it.value }
            effective["user"]?.toString()?.let { user ->
                if (!ConfigRules.LOGIN.matches(user)) error(11, file, "$where: user '$user' is not a valid login name")
            }
            when (val kind = effective["kind"]?.toString()) {
                "compose" -> {
                    composeTargets++
                    lintComposePlacement(file, where, effective["host"]?.toString()?.takeIf { it.isNotBlank() },
                        entry["user"]?.toString(), pool)
                }
                "helm" -> {
                    if (effective["cluster"]?.toString().isNullOrBlank()) error(11, file, "$where: kind helm needs cluster")
                    // namespace: the flow name by default (DL-38); the literal "{flow}" stands for it.
                    val namespace = (effective["namespace"]?.toString() ?: flow).replace("{flow}", flow)
                    if (!ConfigRules.NAMESPACE.matches(namespace)) {
                        error(11, file, "$where: namespace '$namespace' is not a DNS label (RFC 1123, at most 63 characters)")
                    }
                }
                else -> error(11, file, "$where: kind must be compose or helm (was '$kind')")
            }
        }
        (instances - listed).sorted().forEach { error(11, file, "instance $it has no target (inventory drift)") }
        if (pool != null && composeTargets == 0) {
            warn(11, file, "pool: flow '$flow' has no compose target, so nothing is deployed to its boxes")
        }
        return flowPool
    }

    /**
     * A compose target runs on its own `host` (or `defaults.host`), or on a box of the flow's `pool` (DL-39): there
     * `host` is the recorded placement — optional, and when present one of the pool's boxes.
     */
    private fun lintComposePlacement(file: File, where: String, host: String?, ownUser: String?, pool: Pool?) {
        when {
            host == null && pool == null -> error(11, file, "$where: kind compose needs host, or a pool in this file")
            host != null && !ConfigRules.HOST_NAME.matches(host) ->
                error(11, file, "$where: host '$host' is not a lower-case DNS name or IPv4 address")
            host != null && pool != null && pool.hosts.isNotEmpty() && host !in pool.hosts ->
                error(11, file, "$where: host '$host' is not a box of the pool (${pool.hosts.joinToString()}); " +
                    "a pooled instance runs on one of its flow's boxes")
        }
        if (pool != null && ownUser != null && ownUser != pool.user) {
            warn(11, file, "$where: user '$ownUser' is ignored: every box of the pool is reached as '${pool.user}'")
        }
    }

    /** `pool`: {hosts, user?, root?} (DL-39); null after reporting when it is not a mapping. */
    private fun lintPool(file: File, node: Any?): Pool? {
        if (node !is Map<*, *>) {
            error(11, file, "pool: must be a mapping with hosts, user, root")
            return null
        }
        (node.keys.map { it.toString() } - setOf("hosts", "user", "root")).forEach {
            error(11, file, "pool: unknown key '$it' (allowed: hosts, user, root)")
        }
        val hosts = mutableListOf<String>()
        val list = node["hosts"]
        if (list !is List<*> || list.isEmpty()) {
            error(11, file, "pool.hosts must be a non-empty list of host names (the boxes of the flow)")
        } else {
            list.forEachIndexed { i, item ->
                val name = item?.toString().orEmpty()
                when {
                    item !is String || !ConfigRules.HOST_NAME.matches(name) ->
                        error(11, file, "pool.hosts[$i]: '$name' is not a lower-case DNS name or IPv4 address")
                    name in hosts -> error(11, file, "pool.hosts[$i]: $name is listed twice")
                    else -> hosts += name
                }
            }
        }
        val user = node["user"]?.toString() ?: ConfigRules.POOL_USER
        if (!ConfigRules.LOGIN.matches(user)) error(11, file, "pool.user '$user' is not a valid login name")
        val root = node["root"]?.toString() ?: ConfigRules.POOL_ROOT_DEFAULT
        if (!ConfigRules.POOL_ROOT.matches(root) || root.split('/').any { it == "." || it == ".." }) {
            error(11, file, "pool.root '$root' must be an absolute path of plain segments ([A-Za-z0-9._-], no '.' or '..')")
        }
        return Pool(hosts, user, root.trimEnd('/'))
    }

    /** One box may serve two flows of an env only under different roots: two bundles in one root would collide. */
    private fun checkSharedBoxes(pools: List<FlowPool>) {
        val owner = mutableMapOf<Pair<String, String>, String>()
        for ((file, flow, pool) in pools) {
            for (host in pool.hosts) {
                val other = owner.putIfAbsent(host to pool.root, flow)
                if (other != null) {
                    error(11, file, "pool.hosts: $host is also a box of flow '$other' with the same root ${pool.root}: " +
                        "their bundles would collide on it (give one of the pools another root)")
                }
            }
        }
    }

    /** `config/<env>/known_hosts` (DL-35, DL-39): the pinned host keys of the SSH transport — public keys only. */
    private fun lintKnownHosts(file: File) {
        file.readLines().forEachIndexed { index, raw ->
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) return@forEachIndexed
            val fields = line.split(Regex("\\s+")).let { if (it.first().startsWith("@")) it.drop(1) else it }
            if (fields.size < 3 || !ConfigRules.SSH_KEY_TYPE.matches(fields[1]) || !ConfigRules.BASE64.matches(fields[2])) {
                error(11, file, "line ${index + 1}: expected '<host>[,<host>...] <key type> <base64 key>' (ssh-keyscan format)")
            }
        }
    }
}
