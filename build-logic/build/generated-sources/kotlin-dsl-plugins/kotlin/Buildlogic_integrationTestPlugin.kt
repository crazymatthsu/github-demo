/**
 * Precompiled [buildlogic.integration-test.gradle.kts][Buildlogic_integration_test_gradle] script plugin.
 *
 * @see Buildlogic_integration_test_gradle
 */
public
class Buildlogic_integrationTestPlugin : org.gradle.api.Plugin<org.gradle.api.Project> {
    override fun apply(target: org.gradle.api.Project) {
        try {
            Class
                .forName("Buildlogic_integration_test_gradle")
                .getDeclaredConstructor(org.gradle.api.Project::class.java, org.gradle.api.Project::class.java)
                .newInstance(target, target)
        } catch (e: java.lang.reflect.InvocationTargetException) {
            throw e.targetException
        }
    }
}
