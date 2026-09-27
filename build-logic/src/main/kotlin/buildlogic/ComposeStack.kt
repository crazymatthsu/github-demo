package buildlogic

import org.gradle.api.services.BuildService
import org.gradle.api.services.BuildServiceParameters

/**
 * Serialises every task that drives `test-infra/compose/stack.sh` within one build: a laptop has one set of
 * published localhost ports (local-ports.yml), so two stacks must never be started at the same time.
 */
abstract class ComposeStackLock : BuildService<BuildServiceParameters.None>
