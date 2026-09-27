// Settings plugin `buildlogic.git-version` (D1 §6.10, D4 §6.1–§6.2): derives project.version from git
// on every invocation — no version file exists anywhere. Two lines: the connector family (tags vX.Y.Z,
// every project except :deephaven-server) and deephaven-server (tags deephaven-server/vX.Y.Z).
// -Pversion=<v> overrides both (experiments only; never used by workflows).
import buildlogic.CiContext
import buildlogic.GitReader
import buildlogic.VersionLine
import buildlogic.VersionScheme

val override: String? = providers.gradleProperty("version").orNull?.takeIf { it.isNotBlank() }
val ci = CiContext.from { name -> providers.environmentVariable(name).orNull }
val git = GitReader(providers, rootDir)

val family = VersionScheme.compute(git.facts(VersionLine.FAMILY), ci, override)
val server = VersionScheme.compute(git.facts(VersionLine.DEEPHAVEN_SERVER), ci, override)

// Plain strings only: the action below is isolated (configuration cache / isolated projects).
val familyVersion = family.version
val familyKind = family.kind.name
val familyTags = family.imageTags.joinToString(",")
val serverVersion = server.version
val serverKind = server.kind.name
val serverTags = server.imageTags.joinToString(",")
val gitSha = git.sha
val gitSha7 = git.sha7
val gitDirty = git.dirty.toString()
val gitBranch = providers.environmentVariable("GITHUB_HEAD_REF").orNull?.takeIf { it.isNotBlank() }
    ?: providers.environmentVariable("GITHUB_REF_NAME").orNull?.takeIf { it.isNotBlank() }
    ?: git.branch
val gitCommitTime = git.commitTime

gradle.lifecycle.beforeProject {
    val isServer = path == ":deephaven-server"
    version = if (isServer) serverVersion else familyVersion
    val extra = extensions.extraProperties
    extra["buildlogic.versionKind"] = if (isServer) serverKind else familyKind
    extra["buildlogic.imageTags"] = if (isServer) serverTags else familyTags
    extra["buildlogic.version.family"] = familyVersion
    extra["buildlogic.version.deephaven-server"] = serverVersion
    extra["buildlogic.gitSha"] = gitSha
    extra["buildlogic.gitSha7"] = gitSha7
    extra["buildlogic.gitDirty"] = gitDirty
    extra["buildlogic.gitBranch"] = gitBranch
    extra["buildlogic.gitCommitTime"] = gitCommitTime
}
