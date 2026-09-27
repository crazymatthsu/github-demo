package com.example.connectors.framework.testing;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;

/**
 * The actuator of a running connector container (D6 §6.9) as an integration test sees it: readiness polled within
 * a bounded time, {@code /actuator/info} read once. The in-JVM equivalent is {@link AbstractConnectorApplicationTest}.
 */
public final class ActuatorClient {

    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(5);
    private static final Duration POLL_INTERVAL = Duration.ofSeconds(2);

    private final URI base;
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(REQUEST_TIMEOUT).build();

    public ActuatorClient(ItEnvironment.Endpoint endpoint) {
        this(URI.create("http://" + endpoint.host() + ":" + endpoint.port()));
    }

    public ActuatorClient(URI base) {
        this.base = base;
    }

    /**
     * Polls {@code /actuator/health/readiness} until it answers 200 with {@code "status":"UP"}, at most
     * {@code timeout}; fails with the last answer.
     */
    public Map<String, Object> awaitReadiness(Duration timeout) throws InterruptedException {
        long deadline = System.nanoTime() + timeout.toNanos();
        String last;
        while (true) {
            try {
                HttpResponse<String> response = get("/actuator/health/readiness");
                if (response.statusCode() == 200) {
                    Map<String, Object> body = CanonicalJson.parseObject(response.body());
                    if ("UP".equals(body.get("status"))) {
                        return body;
                    }
                }
                last = "HTTP " + response.statusCode() + " " + response.body();
            }
            catch (IOException ex) {
                last = ex.getClass().getSimpleName() + ": " + ex.getMessage();
            }
            if (System.nanoTime() - deadline >= 0) {
                throw new AssertionError(base.resolve("/actuator/health/readiness") + " is not UP after " + timeout
                        + "; last answer: " + last);
            }
            Thread.sleep(POLL_INTERVAL.toMillis());
        }
    }

    /** {@code GET /actuator/info}, which must answer 200. */
    public Map<String, Object> info() throws InterruptedException {
        try {
            HttpResponse<String> response = get("/actuator/info");
            if (response.statusCode() != 200) {
                throw new AssertionError(base.resolve("/actuator/info") + " answered HTTP " + response.statusCode()
                        + ": " + response.body());
            }
            return CanonicalJson.parseObject(response.body());
        }
        catch (IOException ex) {
            throw new AssertionError("GET " + base.resolve("/actuator/info") + " failed", ex);
        }
    }

    private HttpResponse<String> get(String path) throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder(base.resolve(path)).timeout(REQUEST_TIMEOUT).GET().build();
        return http.send(request, HttpResponse.BodyHandlers.ofString());
    }
}
