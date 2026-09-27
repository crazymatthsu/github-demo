// Included build holding the convention plugins (D1 §6.4). Same repository switch as the root build:
// public repositories unless ARTIFACTORY_URL points at the JFrog virtual repositories.

pluginManagement {
    repositories {
        val artifactoryUrl = providers.environmentVariable("ARTIFACTORY_URL").orNull
        if (artifactoryUrl.isNullOrBlank()) {
            gradlePluginPortal()
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

dependencyResolutionManagement {
    repositoriesMode = RepositoriesMode.FAIL_ON_PROJECT_REPOS
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
    versionCatalogs {
        create("libs") {
            from(files("../gradle/libs.versions.toml"))
        }
    }
}

rootProject.name = "build-logic"
