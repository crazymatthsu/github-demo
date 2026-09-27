package com.example.connectors.sourcedatabase;

import java.time.Instant;
import java.util.regex.Pattern;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import com.example.connectors.framework.ConnectorApplication;
import com.example.connectors.framework.ConnectorIdentity;
import com.example.connectors.framework.ConnectorMdc;
import com.example.connectors.framework.ConnectorProperties;

/**
 * The hello-world query (brief §4): {@code SELECT 1}, then {@code SELECT COUNT(*) FROM <connector.source.table>}
 * when a table is configured. It uses the {@code spring.datasource.*} connection, whose username and password
 * are bound only from the environment or {@code /secrets/} (D2 §8.1). It runs once, off the main thread, after
 * start-up and is non-fatal: without a database the app still starts and {@link SourceDatabaseHealthIndicator}
 * reports the failure.
 */
@Component
public class HelloWorldQuery implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(HelloWorldQuery.class);

    /** {@code table}, {@code schema.table} or {@code database.schema.table}: never anything else in the SQL. */
    static final Pattern TABLE = Pattern.compile("^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*){0,2}$");

    private final JdbcTemplate jdbc;
    private final ConnectorProperties properties;
    private final ConnectorIdentity identity;
    private final Environment environment;
    private volatile QueryResult result = QueryResult.pending();

    public HelloWorldQuery(JdbcTemplate jdbc, ConnectorProperties properties, ConnectorIdentity identity,
            Environment environment) {
        this.jdbc = jdbc;
        this.properties = properties;
        this.identity = identity;
        this.environment = environment;
    }

    @Override
    public void run(ApplicationArguments args) {
        if (environment.getProperty(ConnectorApplication.PRINT_CONFIG_PROPERTY, Boolean.class, false)) {
            return; // --print-config: resolve configuration only, never connect
        }
        Thread.ofPlatform().name("hello-world-query").daemon().start(ConnectorMdc.wrap(identity, this::execute));
    }

    /** Runs the queries now and records the outcome. */
    QueryResult execute() {
        String table = properties.source().table();
        try {
            Integer one = jdbc.queryForObject("SELECT 1", Integer.class);
            Long rows = null;
            if (table != null && !table.isBlank()) {
                if (!TABLE.matcher(table).matches()) {
                    throw new IllegalArgumentException("connector.source.table '" + table
                            + "' is not a plain [database.][schema.]table identifier");
                }
                rows = jdbc.queryForObject("SELECT COUNT(*) FROM " + table, Long.class);
            }
            result = QueryResult.succeeded(one, table, rows, Instant.now());
            log.info("Hello-world query succeeded: SELECT 1 -> {}{}", one,
                    rows != null ? ", SELECT COUNT(*) FROM " + table + " -> " + rows : "");
        }
        catch (RuntimeException ex) {
            result = QueryResult.failed(table, ex, Instant.now());
            log.warn("Hello-world query failed (non-fatal, the app keeps running): {}", result.error());
        }
        return result;
    }

    public QueryResult result() {
        return result;
    }

    /** Outcome of the query, exposed as health details. */
    public record QueryResult(State state, Integer selectOne, String table, Long rowCount, String error, Instant checkedAt) {

        public enum State { PENDING, SUCCEEDED, FAILED }

        static QueryResult pending() {
            return new QueryResult(State.PENDING, null, null, null, null, null);
        }

        static QueryResult succeeded(Integer one, String table, Long rows, Instant at) {
            return new QueryResult(State.SUCCEEDED, one, table, rows, null, at);
        }

        static QueryResult failed(String table, Throwable error, Instant at) {
            Throwable root = error;
            while (root.getCause() != null && root.getCause() != root) {
                root = root.getCause();
            }
            String message = root.getClass().getSimpleName() + ": " + root.getMessage();
            return new QueryResult(State.FAILED, null, table, null, message, at);
        }
    }
}
