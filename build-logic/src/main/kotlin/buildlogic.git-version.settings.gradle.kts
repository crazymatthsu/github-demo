// Settings plugin `buildlogic.git-version` (D1 §6.10, D4 §6.1–§6.2): derives project.version from git on
// every invocation — no version file exists anywhere. Two lines: the connector family (tags vX.Y.Z, every
// project except :deephaven-server) and deephaven-server (tags deephaven-server/vX.Y.Z). -Pversion=<v>
// overrides both (experiments only). Each project also receives extra properties used by the other
// convention plugins: buildlogic.versionKind, buildlogic.imageTags, buildlogic.gitSha, buildlogic.gitSha7,
// buildlogic.gitDirty, buildlogic.gitBranch, buildlogic.gitCommitTime, buildlogic.version.<line>.
buildlogic.GitVersionSettings.apply(settings)
