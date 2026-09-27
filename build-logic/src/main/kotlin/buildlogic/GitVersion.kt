package buildlogic

import org.gradle.api.IsolatedAction
import org.gradle.api.Project
import org.gradle.api.initialization.Settings
import org.gradle.api.logging.Logging
import org.gradle.api.provider.ProviderFactory
import java.io.File
import java.io.Serializable
import java.time.OffsetDateTime

/**
 * Version computation from git (D1 §6.10, D4 §6.1, §6.2). The pure scheme ([VersionScheme]) is kept apart
 * from the git reader ([GitReader]) so that it is unit-tested without a repository.
 *
 * | Situation                          | project.version                  | image tags (first = primary)       |
 * |------------------------------------|----------------------------------|------------------------------------|
 * | HEAD carries the line's tag vX.Y.Z | X.Y.Z                            | X.Y.Z, sha-<sha7>                  |
 * | main in CI                         | <next>-rc.<n>                    | <next>-rc.<n>, sha-<sha7>, main    |
 * | hotfix/<x> branch in CI            | <next-patch>-rc.<n>              | <next-patch>-rc.<n>, sha-<sha7>    |
 * | pull request / merge queue in CI   | <next>-pr.<num>.<sha7>           | pr-<num>-<sha7>                    |
 * | anything else (developer machine)  | <next>-local.<n>.<sha7>[.dirty]  | local, <version>                   |
 *
 * `<n>` is the number of commits since the last tag of the line (all commits when the line has no tag);
 * `<next>` is the last tag bumped by the Conventional Commits since it, or 0.1.0 when there is no tag.
 */
enum class VersionKind { RELEASE, MAIN, HOTFIX, PR, LOCAL }

enum class Bump { MAJOR, MINOR, PATCH }

/** A version line: the connector family (tags `v1.2.3`) or deephaven-server (tags `deephaven-server/v1.2.3`). */
enum class VersionLine(val id: String, val tagPrefix: String, val pathFilter: String?) {
    FAMILY("family", "v", null),
    DEEPHAVEN_SERVER("deephaven-server", "deephaven-server/v", "deephaven-server"),
    ;

    companion object {
        /** The line a Gradle project belongs to: `:deephaven-server` has its own, everything else is the family. */
        fun forProjectPath(path: String): VersionLine = if (path == ":deephaven-server") DEEPHAVEN_SERVER else FAMILY

        fun byId(id: String): VersionLine = entries.firstOrNull { it.id == id }
            ?: throw IllegalArgumentException("Unknown version line '$id' (expected one of ${entries.joinToString { it.id }})")
    }
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
        private val PULL_REF = Regex("""^refs/pull/(\d+)/""")
        private val MERGE_QUEUE_REF = Regex("""^refs/heads/gh-readonly-queue/[^/]+/pr-(\d+)-""")

        fun from(env: (String) -> String?): CiContext {
            val isCi = env("GITHUB_ACTIONS") == "true"
            val ref = env("GITHUB_REF")?.takeIf { it.isNotBlank() }
            val explicitPr = env("PR_NUMBER")?.takeIf { it.isNotBlank() }
            val prFromRef = ref?.let { PULL_REF.find(it)?.groupValues?.get(1) }
                ?: ref?.let { MERGE_QUEUE_REF.find(it)?.groupValues?.get(1) }
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

    /** Conventional Commits: `feat!:` / `BREAKING CHANGE:` -> major, `feat:` -> minor, anything else -> patch. */
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

/** Reads [GitFacts] with the git CLI through [ProviderFactory.exec] (tracked as configuration-cache inputs). */
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

    val dirty: Boolean by lazy { available && !git("status", "--porcelain", "--untracked-files=normal").isNullOrEmpty() }

    val shallow: Boolean by lazy { available && git("rev-parse", "--is-shallow-repository") == "true" }

    val branch: String by lazy { (if (available) git("rev-parse", "--abbrev-ref", "HEAD") else null) ?: "unknown" }

    /** Committer time of HEAD in UTC ISO-8601 (used as the reproducible build time), empty without git. */
    val commitTime: String by lazy {
        val raw = if (available) git("show", "-s", "--format=%cI", "HEAD") else null
        raw?.let { runCatching { OffsetDateTime.parse(it).toInstant().toString() }.getOrNull() } ?: ""
    }

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
        val range = if (tag != null && tagVersion != null) "$tag..HEAD" else "HEAD"
        val distance = git("rev-list", "--count", range)?.toIntOrNull() ?: 0
        val logArgs = mutableListOf("log", "--format=%B%x1e", range)
        if (line.pathFilter != null) logArgs += listOf("--", line.pathFilter)
        val messages = git(*logArgs.toTypedArray())
            ?.split('\u001e')?.map { it.trim() }?.filter { it.isNotEmpty() }
            ?: emptyList()
        return GitFacts(tagVersion, distance, sha, sha7, dirty, messages)
    }
}

/** Everything the projects need to know, as plain strings (the carrier of an isolated action). */
data class VersionInfo(
    val versions: Map<String, String>,
    val kinds: Map<String, String>,
    val imageTags: Map<String, List<String>>,
    val gitSha: String,
    val gitSha7: String,
    val gitDirty: Boolean,
    val gitBranch: String,
    val gitCommitTime: String,
) : Serializable

/**
 * Applies [VersionInfo] to every project before its build script runs. Kept as a top-level class that only
 * holds serialisable data: `gradle.lifecycle.beforeProject` requires an isolated action.
 */
class ApplyProjectVersion(private val info: VersionInfo) : IsolatedAction<Project> {
    override fun execute(project: Project) {
        val line = VersionLine.forProjectPath(project.path).id
        project.version = info.versions.getValue(line)
        val extra = project.extensions.extraProperties
        extra["buildlogic.versionLine"] = line
        extra["buildlogic.versionKind"] = info.kinds.getValue(line)
        extra["buildlogic.imageTags"] = info.imageTags.getValue(line).joinToString(",")
        for ((id, version) in info.versions) extra["buildlogic.version.$id"] = version
        extra["buildlogic.gitSha"] = info.gitSha
        extra["buildlogic.gitSha7"] = info.gitSha7
        extra["buildlogic.gitDirty"] = info.gitDirty.toString()
        extra["buildlogic.gitBranch"] = info.gitBranch
        extra["buildlogic.gitCommitTime"] = info.gitCommitTime
    }
}

/** Entry point of the `buildlogic.git-version` settings plugin. */
object GitVersionSettings {
    fun apply(settings: Settings) {
        val providers = settings.providers
        // -Pversion=<v> overrides both lines (experiments only; never used by workflows, D1 §6.10).
        val override = providers.gradleProperty("version").orNull?.takeIf { it.isNotBlank() && it != "unspecified" }
        val ci = CiContext.from { name -> providers.environmentVariable(name).orNull }
        val git = GitReader(providers, settings.rootDir)
        val results = VersionLine.entries.associateWith { VersionScheme.compute(git.facts(it), ci, override) }
        val branch = providers.environmentVariable("GITHUB_HEAD_REF").orNull?.takeIf { it.isNotBlank() }
            ?: providers.environmentVariable("GITHUB_REF_NAME").orNull?.takeIf { it.isNotBlank() }
            ?: git.branch
        val info = VersionInfo(
            versions = results.entries.associate { (line, r) -> line.id to r.version },
            kinds = results.entries.associate { (line, r) -> line.id to r.kind.name },
            imageTags = results.entries.associate { (line, r) -> line.id to r.imageTags },
            gitSha = git.sha,
            gitSha7 = git.sha7,
            gitDirty = git.dirty,
            gitBranch = branch,
            gitCommitTime = git.commitTime,
        )
        settings.gradle.lifecycle.beforeProject(ApplyProjectVersion(info))
    }
}
