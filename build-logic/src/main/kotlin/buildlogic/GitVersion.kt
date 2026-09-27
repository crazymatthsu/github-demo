package buildlogic

import org.gradle.api.logging.Logging
import org.gradle.api.provider.ProviderFactory
import java.io.File

/**
 * Version computation from git (D1 §6.10, D4 §6.1, §6.2). Pure functions are kept apart from the
 * git reader so that the scheme is unit-tested without a repository.
 *
 * | Situation                          | project.version                  | image tags (first = primary)       |
 * |------------------------------------|----------------------------------|------------------------------------|
 * | HEAD carries the line's tag vX.Y.Z | X.Y.Z                            | X.Y.Z, sha-<sha7>                  |
 * | main in CI                         | <next>-rc.<n>                    | <next>-rc.<n>, sha-<sha7>, main    |
 * | hotfix/<x> branch in CI            | <next-patch>-rc.<n>              | <next-patch>-rc.<n>, sha-<sha7>    |
 * | pull request / merge queue in CI   | <next>-pr.<num>.<sha7>           | pr-<num>-<sha7>                    |
 * | anything else (developer machine)  | <next>-local.<n>.<sha7>[.dirty]  | local, <version>                   |
 */
enum class VersionKind { RELEASE, MAIN, HOTFIX, PR, LOCAL }

enum class Bump { MAJOR, MINOR, PATCH }

/** A version line: the connector family (tags `v1.2.3`) or deephaven-server (tags `deephaven-server/v1.2.3`). */
enum class VersionLine(val tagPrefix: String, val pathFilter: String?) {
    FAMILY("v", null),
    DEEPHAVEN_SERVER("deephaven-server/v", "deephaven-server"),
}

data class SemVer(val major: Int, val minor: Int, val patch: Int) {
    fun bump(bump: Bump): SemVer = when (bump) {
        Bump.MAJOR -> SemVer(major + 1, 0, 0)
        Bump.MINOR -> SemVer(major, minor + 1, 0)
        Bump.PATCH -> SemVer(major, minor, patch + 1)
    }

    override fun toString() = "$major.$minor.$patch"

    companion object {
        private val PATTERN = Regex("""^(\d+)\.(\d+)\.(\d+)$""")
        fun parse(text: String): SemVer? = PATTERN.matchEntire(text)?.destructured?.let { (a, b, c) ->
            SemVer(a.toInt(), b.toInt(), c.toInt())
        }
    }
}

/** What the CI environment says about this build (GitHub Actions variables; all optional). */
data class CiContext(
    val isCi: Boolean,
    val ref: String?,
    val prNumber: String?,
) {
    companion object {
        fun from(env: (String) -> String?): CiContext {
            val isCi = env("GITHUB_ACTIONS") == "true"
            val ref = env("GITHUB_REF")
            val explicitPr = env("PR_NUMBER")?.takeIf { it.isNotBlank() }
            val prFromRef = ref?.let { Regex("""^refs/pull/(\d+)/""").find(it)?.groupValues?.get(1) }
                ?: ref?.let { Regex("""^refs/heads/gh-readonly-queue/[^/]+/pr-(\d+)-""").find(it)?.groupValues?.get(1) }
            return CiContext(isCi, ref, explicitPr ?: prFromRef)
        }
    }
}

/** Raw facts read from git for one version line. */
data class GitFacts(
    val lastTagVersion: SemVer?,
    val distance: Int,
    val sha: String,
    val sha7: String,
    val dirty: Boolean,
    val messagesSinceTag: List<String>,
)

data class VersionResult(val version: String, val kind: VersionKind, val imageTags: List<String>)

object VersionScheme {
    private val BREAKING_SUBJECT = Regex("""^[a-zA-Z]+(\([^)]*\))?!:""")
    private val BREAKING_FOOTER = Regex("""(?m)^BREAKING[ -]CHANGE:""")
    private val FEAT_SUBJECT = Regex("""^feat(\([^)]*\))?:""")

    /** Conventional Commits: `feat!:` / `BREAKING CHANGE:` → major, `feat:` → minor, anything else → patch. */
    fun bumpFor(messages: List<String>): Bump {
        var bump = Bump.PATCH
        for (message in messages) {
            val subject = message.trim().lineSequence().firstOrNull().orEmpty()
            if (BREAKING_SUBJECT.containsMatchIn(subject) || BREAKING_FOOTER.containsMatchIn(message)) return Bump.MAJOR
            if (FEAT_SUBJECT.containsMatchIn(subject)) bump = Bump.MINOR
        }
        return bump
    }

    /** `<next>`: 0.1.0 when the line has no tag at all, otherwise the last tag bumped by the commits since. */
    fun next(facts: GitFacts, forcePatch: Boolean = false): SemVer {
        val last = facts.lastTagVersion ?: return SemVer(0, 1, 0)
        return last.bump(if (forcePatch) Bump.PATCH else bumpFor(facts.messagesSinceTag))
    }

    fun kindOf(facts: GitFacts, ci: CiContext): VersionKind = when {
        facts.lastTagVersion != null && facts.distance == 0 && !facts.dirty -> VersionKind.RELEASE
        // prNumber is only ever set from PR_NUMBER or from a pull-request / merge-queue ref.
        ci.prNumber != null -> VersionKind.PR
        ci.isCi && ci.ref == "refs/heads/main" -> VersionKind.MAIN
        ci.isCi && ci.ref?.startsWith("refs/heads/hotfix/") == true -> VersionKind.HOTFIX
        else -> VersionKind.LOCAL
    }

    fun compute(facts: GitFacts, ci: CiContext, override: String? = null): VersionResult {
        val kind = kindOf(facts, ci)
        val version = override ?: when (kind) {
            VersionKind.RELEASE -> facts.lastTagVersion.toString()
            VersionKind.MAIN -> "${next(facts)}-rc.${facts.distance}"
            VersionKind.HOTFIX -> "${next(facts, forcePatch = true)}-rc.${facts.distance}"
            VersionKind.PR -> "${next(facts)}-pr.${ci.prNumber}.${facts.sha7}"
            VersionKind.LOCAL -> "${next(facts)}-local.${facts.distance}.${facts.sha7}" + if (facts.dirty) ".dirty" else ""
        }
        return VersionResult(version, kind, imageTags(kind, version, facts.sha7, ci.prNumber))
    }

    /** D4 §6.2: one immutable tag pair per commit; convenience tags only where the scheme allows them. */
    fun imageTags(kind: VersionKind, version: String, sha7: String, prNumber: String?): List<String> = when (kind) {
        VersionKind.RELEASE -> listOf(version, "sha-$sha7")
        VersionKind.MAIN -> listOf(version, "sha-$sha7", "main")
        VersionKind.HOTFIX -> listOf(version, "sha-$sha7")
        VersionKind.PR -> listOf("pr-$prNumber-$sha7")
        VersionKind.LOCAL -> listOf("local", version)
    }.map(::sanitiseTag).distinct()

    /** Docker tags allow `[A-Za-z0-9_.-]`, at most 128 characters, not starting with `.` or `-`. */
    fun sanitiseTag(tag: String): String =
        tag.replace(Regex("[^A-Za-z0-9_.-]"), "-").trimStart('.', '-').take(128)
}

/** Reads [GitFacts] with the git CLI through [ProviderFactory.exec] (configuration-cache inputs). */
class GitReader(private val providers: ProviderFactory, private val rootDir: File) {
    private val logger = Logging.getLogger(GitReader::class.java)

    private fun git(vararg args: String): String? = try {
        val exec = providers.exec {
            workingDir = rootDir
            commandLine(listOf("git") + args.toList())
            isIgnoreExitValue = true
        }
        if (exec.result.get().exitValue == 0) exec.standardOutput.asText.get().trim() else null
    } catch (e: Exception) {
        null // git not installed
    }

    val available: Boolean by lazy { git("rev-parse", "--is-inside-work-tree") == "true" }

    val sha: String by lazy { (if (available) git("rev-parse", "HEAD") else null) ?: "0".repeat(40) }

    val sha7: String get() = sha.take(7)

    val dirty: Boolean by lazy { available && !git("status", "--porcelain").isNullOrEmpty() }

    val shallow: Boolean by lazy { available && git("rev-parse", "--is-shallow-repository") == "true" }

    val branch: String by lazy { (if (available) git("rev-parse", "--abbrev-ref", "HEAD") else null) ?: "unknown" }

    val commitTime: String by lazy { (if (available) git("show", "-s", "--format=%cI", "HEAD") else null) ?: "" }

    fun facts(line: VersionLine): GitFacts {
        if (!available) {
            logger.warn("buildlogic.git-version: not a git work tree (or git missing); using 0.1.0 and sha 0000000")
            return GitFacts(null, 0, sha, sha7, false, emptyList())
        }
        if (shallow) {
            logger.warn("buildlogic.git-version: shallow clone — tags and commit counts may be missing; " +
                "check out with fetch-depth: 0 for a correct version")
        }
        val tag = git("describe", "--tags", "--abbrev=0",
            "--match", "${line.tagPrefix}[0-9]*.[0-9]*.[0-9]*", "--exclude", "*-*", "HEAD")
        val tagVersion = tag?.removePrefix(line.tagPrefix)?.let(SemVer::parse)
        val range = if (tag != null && tagVersion != null) listOf("$tag..HEAD") else listOf("HEAD")
        val distance = git("rev-list", "--count", *range.toTypedArray())?.toIntOrNull() ?: 0
        val logArgs = mutableListOf("log", "--format=%B%x1e") + range
        if (line.pathFilter != null) logArgs += listOf("--", line.pathFilter)
        val messages = git(*logArgs.toTypedArray())
            ?.split('\u001e')?.map { it.trim() }?.filter { it.isNotEmpty() }
            ?: emptyList()
        return GitFacts(tagVersion, distance, sha, sha7, dirty, messages)
    }
}
