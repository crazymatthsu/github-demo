/**
 * Precompiled [buildlogic.config-lint.gradle.kts][Buildlogic_config_lint_gradle] script plugin.
 *
 * @see Buildlogic_config_lint_gradle
 */
public
class Buildlogic_configLintPlugin : org.gradle.api.Plugin<org.gradle.api.Project> {
    override fun apply(target: org.gradle.api.Project) {
        try {
            Class
                .forName("Buildlogic_config_lint_gradle")
                .getDeclaredConstructor(org.gradle.api.Project::class.java, org.gradle.api.Project::class.java)
                .newInstance(target, target)
        } catch (e: java.lang.reflect.InvocationTargetException) {
            throw e.targetException
        }
    }
}
