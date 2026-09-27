package buildlogic

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File
import java.nio.file.Files

class ContainerEnginesTest {
    private fun runner(vararg ok: String): (List<String>) -> CommandResult = { cmd ->
        val line = cmd.joinToString(" ")
        if (ok.any { line.startsWith(it) }) CommandResult(0, "ok")
        else if (line.endsWith("--version")) CommandResult(127, "not found")
        else CommandResult(1, "Client: Docker Engine\nCannot connect to the Docker daemon at unix:///var/run/docker.sock")
    }

    @Test
    fun `docker with a daemon and buildx is preferred`() {
        val probe = ContainerEngines.detect("auto", runner("docker --version", "docker info", "docker buildx version"))
        assertEquals(EngineProbe.Found(Engine(EngineKind.DOCKER, buildx = true)), probe)
    }

    @Test
    fun `a docker CLI without a daemon falls back to podman`() {
        val probe = ContainerEngines.detect("auto", runner("docker --version", "podman --version", "podman info"))
        assertEquals(EngineProbe.Found(Engine(EngineKind.PODMAN, buildx = false)), probe)
    }

    @Test
    fun `nothing usable explains why`() {
        val probe = ContainerEngines.detect("auto", runner("docker --version")) as EngineProbe.Missing
        assertEquals(2, probe.reasons.size)
        assertTrue(probe.reasons[0].contains("daemon is not reachable (Cannot connect to the Docker daemon"), probe.reasons[0])
        assertTrue(probe.reasons[1].contains("podman: CLI not found"), probe.reasons[1])
    }

    @Test
    fun `podman builds keep the docker manifest format`() {
        val cmd = ContainerEngines.buildCommand(Engine(EngineKind.PODMAN, false), File("/ctx"), "docker/Dockerfile",
            listOf("r/a:1", "r/a:sha-1"), mapOf("GIT_SHA" to "x"), mapOf("k" to "v"), listOf("--pull"))
        assertEquals(listOf("podman", "build", "--format", "docker", "--file", "/ctx/docker/Dockerfile",
            "--tag", "r/a:1", "--tag", "r/a:sha-1", "--build-arg", "GIT_SHA=x", "--label", "k=v", "--pull", "/ctx"), cmd)
    }

    @Test
    fun `buildx loads the result into the local image store`() {
        val cmd = ContainerEngines.buildCommand(Engine(EngineKind.DOCKER, true), File("/ctx"), "docker/Dockerfile",
            listOf("r/a:1"), emptyMap(), emptyMap(), emptyList())
        assertEquals(listOf("docker", "buildx", "build", "--load", "--file", "/ctx/docker/Dockerfile", "--tag", "r/a:1", "/ctx"), cmd)
    }

    @Test
    fun `the base image default is read from the Dockerfile`() {
        val file = Files.createTempFile("Dockerfile", "").toFile()
        file.writeText("# c\nARG BASE_IMAGE=ghcr.io/o/base/jre21:latest\nFROM \${BASE_IMAGE}\n")
        assertEquals("ghcr.io/o/base/jre21:latest", ContainerEngines.argDefault(file, "BASE_IMAGE"))
        assertEquals(null, ContainerEngines.argDefault(file, "DEEPHAVEN_IMAGE"))
    }
}
