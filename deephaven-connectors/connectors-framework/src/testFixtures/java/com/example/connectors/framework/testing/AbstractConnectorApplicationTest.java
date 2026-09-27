package com.example.connectors.framework.testing;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;

import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The actuator contract every connector app honours (D6 §6.9), as a reusable Spring Boot test: extend it
 * from the app's test package and the whole application starts on a random port with the identity
 * {@code local/cash/<app>/unit-test}.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "APP_ENV=local", "APP_FLOW=cash", "APP_INSTANCE=unit-test",
        "connector.amps.password=not-a-real-secret-1234" })
public abstract class AbstractConnectorApplicationTest {

    private static final HttpClient HTTP = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

    @Value("${local.server.port}")
    private int port;

    @Value("${spring.application.name}")
    private String appName;

    protected Map<String, Object> getJson(String path) {
        return CanonicalJson.parseObject(get(path));
    }

    protected String get(String path) {
        try {
            HttpRequest request = HttpRequest.newBuilder(URI.create("http://localhost:" + port + path))
                    .timeout(Duration.ofSeconds(10)).GET().build();
            HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
            assertThat(response.statusCode()).as("HTTP status of %s: %s", path, response.body()).isEqualTo(200);
            return response.body();
        }
        catch (IOException ex) {
            throw new AssertionError("GET " + path + " failed", ex);
        }
        catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw new AssertionError("interrupted", ex);
        }
    }

    protected String expectedTuple() {
        return "local/cash/" + appName + "/unit-test";
    }

    @Test
    void livenessIsUp() {
        assertThat(getJson("/actuator/health/liveness")).containsEntry("status", "UP");
    }

    @Test
    void readinessIsUpAndIncludesTheConnectorIndicator() {
        Map<String, Object> readiness = getJson("/actuator/health/readiness");
        assertThat(readiness).containsEntry("status", "UP");
        assertThat(readiness.get("components")).asString().contains("connector").contains(expectedTuple());
    }

    @Test
    void infoShowsIdentityAndBuild() {
        Map<String, Object> info = getJson("/actuator/info");
        assertThat(info.get("connector")).asString().contains(expectedTuple());
        assertThat(info).containsKey("build");
    }

    @Test
    void prometheusCarriesIdentityTags() {
        assertThat(get("/actuator/prometheus"))
                .contains("env=\"local\"", "flow=\"cash\"", "app=\"" + appName + "\"", "instance=\"unit-test\"");
    }

    @Test
    void connectorConfigEndpointMasksSecrets() {
        String body = get("/actuator/connectorconfig");
        assertThat(body).contains(expectedTuple()).contains("connector.amps.password")
                .doesNotContain("not-a-real-secret-1234");
    }
}
