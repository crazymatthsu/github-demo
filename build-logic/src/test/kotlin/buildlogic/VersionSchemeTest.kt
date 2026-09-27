package buildlogic

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class VersionSchemeTest {
    private val sha = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"
    private fun facts(tag: String?, distance: Int, vararg messages: String, dirty: Boolean = false) =
        GitFacts(tag?.let(SemVer::parse), distance, sha, sha.take(7), dirty, messages.toList())

    private val laptop = CiContext(isCi = false, ref = null, prNumber = null)
    private val main = CiContext(isCi = true, ref = "refs/heads/main", prNumber = null)

    @Test
    fun `a commit carrying the release tag is that version with the immutable tag pair`() {
        val result = VersionScheme.compute(facts("1.4.2", 0), main)
        assertEquals("1.4.2", result.version)
        assertEquals(listOf("1.4.2", "sha-1a2b3c4"), result.imageTags)
    }

    @Test
    fun `main is the next version as a release candidate numbered by the distance`() {
        val result = VersionScheme.compute(facts("1.4.1", 7, "fix: a", "feat(source-kafka): b", "chore: c"), main)
        assertEquals("1.5.0-rc.7", result.version)
        assertEquals(listOf("1.5.0-rc.7", "sha-1a2b3c4", "main"), result.imageTags)
    }

    @Test
    fun `breaking changes bump the major version`() {
        assertEquals(Bump.MAJOR, VersionScheme.bumpFor(listOf("feat!: drop the v1 API")))
        assertEquals(Bump.MAJOR, VersionScheme.bumpFor(listOf("refactor(core): x\n\nBREAKING CHANGE: renamed keys")))
        assertEquals(Bump.MINOR, VersionScheme.bumpFor(listOf("fix: y", "feat: z")))
        assertEquals(Bump.PATCH, VersionScheme.bumpFor(listOf("fix: y", "docs: z")))
    }

    @Test
    fun `a pull request build carries the PR number and the short sha`() {
        val ci = CiContext.from(mapOf("GITHUB_ACTIONS" to "true", "GITHUB_REF" to "refs/pull/123/merge")::get)
        val result = VersionScheme.compute(facts("1.4.1", 7, "feat: b"), ci)
        assertEquals("1.5.0-pr.123.1a2b3c4", result.version)
        assertEquals(listOf("pr-123-1a2b3c4"), result.imageTags)
    }

    @Test
    fun `the merge queue ref is a pull request build too`() {
        val ci = CiContext.from(mapOf("GITHUB_ACTIONS" to "true",
            "GITHUB_REF" to "refs/heads/gh-readonly-queue/main/pr-77-0123456789abcdef")::get)
        assertEquals("77", ci.prNumber)
    }

    @Test
    fun `a developer build is local, counts the distance and flags a dirty tree`() {
        val result = VersionScheme.compute(facts("1.4.1", 7, "fix: a", dirty = true), laptop)
        assertEquals("1.4.2-local.7.1a2b3c4.dirty", result.version)
        assertEquals(listOf("local", "1.4.2-local.7.1a2b3c4.dirty"), result.imageTags)
    }

    @Test
    fun `without any tag the next version is 0_1_0`() {
        assertEquals("0.1.0-rc.22", VersionScheme.compute(facts(null, 22, "feat: first"), main).version)
        assertEquals("0.1.0-local.22.1a2b3c4", VersionScheme.compute(facts(null, 22), laptop).version)
    }

    @Test
    fun `a hotfix branch always bumps the patch`() {
        val ci = CiContext(isCi = true, ref = "refs/heads/hotfix/1.5.x", prNumber = null)
        assertEquals("1.5.1-rc.2", VersionScheme.compute(facts("1.5.0", 2, "feat: sneaky"), ci).version)
    }

    @Test
    fun `an explicit version overrides the computation`() {
        assertEquals("9.9.9", VersionScheme.compute(facts("1.4.1", 7), main, override = "9.9.9").version)
    }

    @Test
    fun `tags are sanitised to the Docker tag grammar`() {
        assertEquals("1.0.0-local.1.abc", VersionScheme.sanitiseTag("1.0.0-local.1.abc"))
        assertEquals("a-b", VersionScheme.sanitiseTag("..a+b"))
    }

    @Test
    fun `deephaven-server has its own line and everything else is the family`() {
        assertEquals(VersionLine.DEEPHAVEN_SERVER, VersionLine.forProjectPath(":deephaven-server"))
        assertEquals(VersionLine.FAMILY, VersionLine.forProjectPath(":deephaven-connectors:source-kafka"))
        assertEquals(VersionLine.DEEPHAVEN_SERVER, VersionLine.byId("deephaven-server"))
    }
}
