package com.example.connectors.sourcedatabase;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import com.example.connectors.framework.testing.ItEnvironment.Endpoint;

/**
 * The SQL Server side of the reference case (D8 §5.2 steps 2 and 4): connect with mssql-jdbc, apply SQL files,
 * read a table back with typed columns. Only JDBC is used; the driver is on the runtime classpath through the
 * app's own dependencies.
 */
final class SqlServerSource {

    /** Rows with the Java type of each column, in select order. */
    record Rows(Map<String, Class<?>> columns, List<Map<String, Object>> values) {
        Rows {
            columns = Collections.unmodifiableMap(new LinkedHashMap<>(columns));
            values = List.copyOf(values);
        }
    }

    /** Login failed: a wrong password does not heal by waiting. */
    private static final int LOGIN_FAILED = 18456;
    /** microsoft.sql.Types.DATETIMEOFFSET, without a compile-time dependency on the driver. */
    private static final int DATETIMEOFFSET = -155;
    private static final Duration RETRY_INTERVAL = Duration.ofSeconds(2);
    private static final Pattern GO = Pattern.compile("(?im)^\\s*GO\\s*;?\\s*$");

    private SqlServerSource() {
    }

    /**
     * Opens a connection to {@code database}, retrying for at most {@code budget} while SQL Server is not ready
     * yet. The test container presents a self-signed certificate, trusted here as in the local instance config.
     */
    static Connection connect(Endpoint endpoint, String database, String user, String password, Duration budget)
            throws InterruptedException {
        String url = "jdbc:sqlserver://" + endpoint.host() + ":" + endpoint.port() + ";databaseName=" + database
                + ";encrypt=true;trustServerCertificate=true;loginTimeout=10;applicationName=integration-test";
        try {
            DriverManager.getDriver(url);
        }
        catch (SQLException ex) {
            throw new IllegalStateException("no JDBC driver for " + url + ": mssql-jdbc is not on the test runtime classpath", ex);
        }
        long deadline = System.nanoTime() + budget.toNanos();
        while (true) {
            try {
                return DriverManager.getConnection(url, user, password);
            }
            catch (SQLException ex) {
                if (ex.getErrorCode() == LOGIN_FAILED) {
                    throw new AssertionError("SQL Server rejected the login of '" + user + "' (" + endpoint + "): "
                            + "SPRING_DATASOURCE_PASSWORD must be the stack's sa password (IT_SA_PASSWORD, recorded by "
                            + "stack.sh up in test-infra/compose/.state/)", ex);
                }
                if (System.nanoTime() - deadline >= 0) {
                    throw new AssertionError("cannot connect to [" + database + "] on " + endpoint + " within " + budget
                            + ": " + ex.getMessage(), ex);
                }
            }
            Thread.sleep(RETRY_INTERVAL.toMillis());
        }
    }

    /** The {@code *.sql} files of a directory in name order (the generic seed helpers). */
    static List<Path> scripts(Path directory) throws IOException {
        try (Stream<Path> files = Files.list(directory)) {
            return files.filter(file -> file.getFileName().toString().endsWith(".sql")).sorted().toList();
        }
    }

    /**
     * Applies one SQL file: batches separated by {@code GO} lines (the case files are one batch each), every
     * result drained so that an error in any statement surfaces.
     */
    static void apply(Connection connection, Path script) throws IOException {
        String sql = Files.readString(script, StandardCharsets.UTF_8);
        try (Statement statement = connection.createStatement()) {
            for (String batch : GO.split(sql)) {
                if (!batch.isBlank()) {
                    drain(statement, statement.execute(batch));
                }
            }
        }
        catch (SQLException ex) {
            throw new AssertionError("applying " + script + " to [" + catalog(connection) + "] failed: " + ex.getMessage(), ex);
        }
    }

    /** Runs a query and returns its rows with Java values of the types in {@link Rows#columns()}. */
    static Rows query(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement(); ResultSet rs = statement.executeQuery(sql)) {
            ResultSetMetaData meta = rs.getMetaData();
            int count = meta.getColumnCount();
            String[] names = new String[count + 1];
            int[] sqlTypes = new int[count + 1];
            Map<String, Class<?>> columns = new LinkedHashMap<>();
            for (int i = 1; i <= count; i++) {
                names[i] = meta.getColumnLabel(i);
                sqlTypes[i] = meta.getColumnType(i);
                columns.put(names[i], javaType(sqlTypes[i]));
            }
            List<Map<String, Object>> rows = new ArrayList<>();
            while (rs.next()) {
                Map<String, Object> row = new LinkedHashMap<>();
                for (int i = 1; i <= count; i++) {
                    row.put(names[i], value(rs, i, sqlTypes[i], columns.get(names[i])));
                }
                rows.add(row);
            }
            return new Rows(columns, rows);
        }
    }

    /**
     * The Java type a column travels as, chosen from what the Deephaven client can upload: exact numerics become
     * double (the case's quantities are exact in binary floating point), SQL timestamps become instants in UTC.
     */
    static Class<?> javaType(int sqlType) {
        return switch (sqlType) {
            case Types.DECIMAL, Types.NUMERIC, Types.FLOAT, Types.DOUBLE, Types.REAL -> Double.class;
            case Types.BIGINT -> Long.class;
            case Types.INTEGER, Types.SMALLINT, Types.TINYINT -> Integer.class;
            case Types.BIT, Types.BOOLEAN -> Boolean.class;
            case Types.TIMESTAMP, Types.TIMESTAMP_WITH_TIMEZONE, DATETIMEOFFSET -> Instant.class;
            case Types.DATE -> LocalDate.class;
            case Types.TIME -> LocalTime.class;
            default -> String.class;
        };
    }

    private static Object value(ResultSet rs, int index, int sqlType, Class<?> type) throws SQLException {
        Object value;
        if (type == Instant.class) {
            // datetime2 carries no zone: the source tables store UTC (schema.sql), so read it as UTC, never
            // through the JVM default zone.
            value = (sqlType == DATETIMEOFFSET || sqlType == Types.TIMESTAMP_WITH_TIMEZONE)
                    ? toInstant(rs.getObject(index, OffsetDateTime.class))
                    : toInstant(rs.getObject(index, LocalDateTime.class));
        }
        else if (type == Double.class) {
            double number = rs.getDouble(index);
            value = rs.wasNull() ? null : number;
        }
        else if (type == Long.class) {
            long number = rs.getLong(index);
            value = rs.wasNull() ? null : number;
        }
        else if (type == Integer.class) {
            int number = rs.getInt(index);
            value = rs.wasNull() ? null : number;
        }
        else if (type == Boolean.class) {
            boolean bit = rs.getBoolean(index);
            value = rs.wasNull() ? null : bit;
        }
        else if (type == LocalDate.class || type == LocalTime.class) {
            value = rs.getObject(index, type);
        }
        else {
            value = rs.getString(index);
        }
        return value;
    }

    private static Instant toInstant(Object value) {
        return switch (value) {
            case null -> null;
            case LocalDateTime local -> local.toInstant(ZoneOffset.UTC);
            case OffsetDateTime offset -> offset.toInstant();
            default -> throw new IllegalStateException("unexpected timestamp " + value.getClass());
        };
    }

    private static void drain(Statement statement, boolean isResultSet) throws SQLException {
        boolean more = isResultSet;
        while (true) {
            if (more) {
                statement.getResultSet().close();
            }
            else if (statement.getUpdateCount() == -1) {
                return;
            }
            more = statement.getMoreResults();
        }
    }

    private static String catalog(Connection connection) {
        try {
            return connection.getCatalog();
        }
        catch (SQLException ex) {
            return "?";
        }
    }
}
