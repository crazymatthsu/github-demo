// Root settings (D1 §6.1, §6.7, §6.10).
//
// Repositories: public repositories when ARTIFACTORY_URL is unset (the demo on GitHub-hosted runners),
// the JFrog virtual repositories when it is set (the enterprise). Credentials only ever come from the
// environment (ARTIFACTORY_USER / ARTIFACTORY_TOKEN), never from a file. No subproject declares a
// repository of its own (FAIL_ON_PROJECT_REPOS).

pluginManagement {
    includeBuild("build-logic")
    repositories {
        val artifactoryUrl = providers.environmentVariable("ARTIFACTORY_URL").orNull
        if (artifactoryUrl.isNullOrBlank()) {
            gradlePluginPortal()
            mavenCentral()
        } else {
            maven {
                name = "artifactoryPlugins"
                url = uri("${artifactoryUrl.trimEnd('/')}/" +
                    providers.environmentVariable("ARTIFACTORY_PLUGINS_REPO").getOrElse("gradle-plugins-virtual"))
                credentials {
                    username = providers.environmentVariable("ARTIFACTORY_USER").orNull
                    password = providers.environmentVariable("ARTIFACTORY_TOKEN").orNull
                }
            }
        }
    }
}

plugins {
    // Computes project.version from git for every project (D4 §6.1); -Pversion=... overrides it.
    id("buildlogic.git-version")
}

dependencyResolutionManagement {
    repositoriesMode = RepositoriesMode.FAIL_ON_PROJECT_REPOS
    repositories {
        val artifactoryUrl = providers.environmentVariable("ARTIFACTORY_URL").orNull
        if (artifactoryUrl.isNullOrBlank()) {
            mavenCentral()
        } else {
            maven {
                name = "artifactoryLibs"
                url = uri("${artifactoryUrl.trimEnd('/')}/" +
                    providers.environmentVariable("ARTIFACTORY_LIBS_REPO").getOrElse("libs-virtual"))
                credentials {
                    username = providers.environmentVariable("ARTIFACTORY_USER").orNull
                    password = providers.environmentVariable("ARTIFACTORY_TOKEN").orNull
                }
            }
        }
    }
}

rootProject.name = "github-demo"

// Directory name == Gradle project name == image name == AppName (D1 §6.1).
include(
    ":deephaven-server",
    ":deephaven-connectors",
    ":deephaven-connectors:connectors-framework",
    ":deephaven-connectors:source-kafka",
    ":deephaven-connectors:source-amps",
    ":deephaven-connectors:source-database",
)
