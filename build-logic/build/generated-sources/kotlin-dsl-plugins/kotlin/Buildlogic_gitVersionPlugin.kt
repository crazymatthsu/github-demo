/**
 * Precompiled [buildlogic.git-version.settings.gradle.kts][Buildlogic_git_version_settings_gradle] script plugin.
 *
 * @see Buildlogic_git_version_settings_gradle
 */
public
class Buildlogic_gitVersionPlugin : org.gradle.api.Plugin<org.gradle.api.initialization.Settings> {
    override fun apply(target: org.gradle.api.initialization.Settings) {
        try {
            Class
                .forName("Buildlogic_git_version_settings_gradle")
                .getDeclaredConstructor(org.gradle.api.initialization.Settings::class.java, org.gradle.api.initialization.Settings::class.java)
                .newInstance(target, target)
        } catch (e: java.lang.reflect.InvocationTargetException) {
            throw e.targetException
        }
    }
}
