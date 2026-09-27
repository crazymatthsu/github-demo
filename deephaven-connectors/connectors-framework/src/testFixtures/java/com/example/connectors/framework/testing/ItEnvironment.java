package com.example.connectors.framework.testing;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * What an integration test reads from its environment (D8 §6.2, D10 §6.6): the endpoints of the test stack, the
 * table prefix and the connection budget. The test JVM is the host JVM locally (Gradle's integrationTest passes
 * {@code localhost} and the published ports) or the it-runner container in CI (service names on the compose
 * network); the defaults below are the local ones.
 */
public final class ItEnvironment {

    /** Default {@code IT_TABLE_PREFIX} outside Gradle and CI (an IDE run); stack.sh and Gradle pass it_&lt;sha7&gt;_. */
    public static final String LOCAL_TABLE_PREFIX = "it_local_";

    /** Client-level readiness budget per dependency (D10 §5.3), overridden by {@code IT_CONNECT_TIMEOUT}. */
    public static final Duration DEFAULT_CONNECT_TIMEOUT = Duration.ofSeconds(60);

    private static final Duration PROBE_TIMEOUT = Duration.ofSeconds(3);

    private ItEnvironment() {
    }

    /** One service of the test stack as the test JVM reaches it. */
    public record Endpoint(String service, String host, int port, String hostVariable, String portVariable) {

        /** A TCP connect within {@code timeout}; empty when something accepts connections, else the reason. */
        public Optional<String> probe(Duration timeout) {
            try (Socket socket = new Socket()) {
                socket.connect(new InetSocketAddress(host, port), Math.toIntExact(timeout.toMillis()));
                return Optional.empty();
            }
            catch (IOException ex) {
                return Optional.of(ex.getClass().getSimpleName() + ": " + ex.getMessage());
            }
        }

        @Override
        public String toString() {
            return service + " at " + host + ":" + port;
        }
    }

    public static Endpoint deephaven() {
        return endpoint("Deephaven", "IT_DEEPHAVEN_HOST", "localhost", "IT_DEEPHAVEN_PORT", 10000);
    }

    public static Endpoint sqlServer() {
        return endpoint("SQL Server", "IT_SQLSERVER_HOST", "localhost", "IT_SQLSERVER_PORT", 1433);
    }

    /**
     * The actuator of the app under test ({@code IT_APP_HOST}, {@code IT_APP_PORT} default 8080), when whoever
     * started the stack says where it is: the compose service {@code <AppName>} in CI, a published port locally.
     */
    public static Optional<Endpoint> appUnderTest() {
        return optional("IT_APP_HOST")
                .map(host -> new Endpoint("app under test", host, port("IT_APP_PORT", 8080), "IT_APP_HOST", "IT_APP_PORT"));
    }

    /** {@code IT_TABLE_PREFIX}: the run's prefix for Deephaven table names (D8 §6.6). */
    public static String tablePrefix() {
        return optional("IT_TABLE_PREFIX").orElse(LOCAL_TABLE_PREFIX);
    }

    /** {@code IT_CONNECT_TIMEOUT} as an ISO-8601 duration ({@code PT60S}) or whole seconds. */
    public static Duration connectTimeout() {
        return optional("IT_CONNECT_TIMEOUT").map(value -> {
            try {
                return value.chars().allMatch(Character::isDigit) ? Duration.ofSeconds(Long.parseLong(value))
                        : Duration.parse(value);
            }
            catch (DateTimeParseException ex) {
                throw new IllegalStateException("IT_CONNECT_TIMEOUT='" + value + "' is neither seconds nor an ISO-8601 duration", ex);
            }
        }).orElse(DEFAULT_CONNECT_TIMEOUT);
    }

    /** A non-blank environment variable. */
    public static Optional<String> optional(String name) {
        return Optional.ofNullable(System.getenv(name)).map(String::trim).filter(value -> !value.isEmpty());
    }

    public static String value(String name, String defaultValue) {
        return optional(name).orElse(defaultValue);
    }

    /**
     * Fails fast, naming every unreachable endpoint, when nothing accepts connections where the stack should be
     * (the stack is not up, or the IT_* variables point elsewhere). Readiness beyond a TCP connect is each
     * client's own bounded probe.
     */
    public static void requireReachable(String hint, Endpoint... endpoints) {
        List<String> problems = new ArrayList<>();
        for (Endpoint endpoint : endpoints) {
            endpoint.probe(PROBE_TIMEOUT).ifPresent(problem -> problems.add("  - " + endpoint + " ("
                    + endpoint.hostVariable() + "/" + endpoint.portVariable() + "): " + problem));
        }
        if (!problems.isEmpty()) {
            throw new AssertionError("The integration-test stack is not reachable:\n" + String.join("\n", problems)
                    + "\n" + hint);
        }
    }

    /**
     * The repository root: the nearest directory at or above the working directory that holds {@code test-infra/}
     * (Gradle runs the tests in the subproject directory, locally and inside it-runner).
     */
    public static Path repositoryRoot() {
        Path start = Path.of("").toAbsolutePath();
        for (Path dir = start; dir != null; dir = dir.getParent()) {
            if (Files.isDirectory(dir.resolve("test-infra"))) {
                return dir;
            }
        }
        throw new IllegalStateException("no test-infra/ directory at or above " + start
                + ": run the tests from inside the repository or set " + TestCase.TESTDATA_DIR_VARIABLE);
    }

    private static Endpoint endpoint(String service, String hostVariable, String defaultHost, String portVariable,
            int defaultPort) {
        return new Endpoint(service, value(hostVariable, defaultHost), port(portVariable, defaultPort), hostVariable,
                portVariable);
    }

    private static int port(String variable, int defaultPort) {
        String value = value(variable, Integer.toString(defaultPort));
        try {
            int port = Integer.parseInt(value);
            if (port < 1 || port > 65535) {
                throw new NumberFormatException("out of range");
            }
            return port;
        }
        catch (NumberFormatException ex) {
            throw new IllegalStateException(variable + "='" + value + "' is not a TCP port", ex);
        }
    }
}
