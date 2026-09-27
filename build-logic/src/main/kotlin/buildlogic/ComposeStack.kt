package buildlogic

import org.gradle.api.services.BuildService
import org.gradle.api.services.BuildServiceParameters
import java.security.SecureRandom

/**
 * Serialises every task that drives `test-infra/compose/stack.sh` within one build: a laptop has one set of
 * published localhost ports (local-ports.yml), so two stacks must never be started at the same time.
 */
abstract class ComposeStackLock : BuildService<BuildServiceParameters.None>

/**
 * The throwaway SQL Server `sa` password of a Gradle-managed test stack (D2 §6.4, D8 §6.4): generated once per
 * build at execution time (never stored in the configuration cache) and handed to both `composeUp` (SQL
 * Server's MSSQL_SA_PASSWORD) and the host-JVM `integrationTest` (SPRING_DATASOURCE_PASSWORD). An
 * `IT_SA_PASSWORD` set in the environment wins.
 */
abstract class IntegrationTestSecrets : BuildService<BuildServiceParameters.None> {
    val saPassword: String by lazy {
        System.getenv("IT_SA_PASSWORD")?.takeIf { it.isNotBlank() } ?: generate()
    }

    private fun generate(): String {
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        // Upper case, lower case, digits and a symbol: the SQL Server password policy (same shape as stack.sh).
        return "It-" + bytes.joinToString("") { "%02x".format(it) } + "-Aa1"
    }
}
