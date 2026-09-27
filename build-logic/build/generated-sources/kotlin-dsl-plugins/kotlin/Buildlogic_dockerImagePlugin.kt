/**
 * Precompiled [buildlogic.docker-image.gradle.kts][Buildlogic_docker_image_gradle] script plugin.
 *
 * @see Buildlogic_docker_image_gradle
 */
public
class Buildlogic_dockerImagePlugin : org.gradle.api.Plugin<org.gradle.api.Project> {
    override fun apply(target: org.gradle.api.Project) {
        try {
            Class
                .forName("Buildlogic_docker_image_gradle")
                .getDeclaredConstructor(org.gradle.api.Project::class.java, org.gradle.api.Project::class.java)
                .newInstance(target, target)
        } catch (e: java.lang.reflect.InvocationTargetException) {
            throw e.targetException
        }
    }
}
