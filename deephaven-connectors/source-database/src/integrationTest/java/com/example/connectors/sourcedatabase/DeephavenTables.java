package com.example.connectors.sourcedatabase;

import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import javax.lang.model.SourceVersion;

import io.deephaven.client.impl.ClientConfig;
import io.deephaven.client.impl.ConsoleSession;
import io.deephaven.client.impl.FlightClientHelper;
import io.deephaven.client.impl.FlightSession;
import io.deephaven.client.impl.FlightSessionFactoryConfig;
import io.deephaven.client.impl.ScopeId;
import io.deephaven.client.impl.TableHandle;
import io.deephaven.client.impl.script.Changes;
import io.deephaven.qst.column.Column;
import io.deephaven.qst.table.NewTable;
import io.deephaven.uri.DeephavenTarget;
import io.grpc.ManagedChannel;
import io.grpc.Status;
import org.apache.arrow.flight.CallOptions;
import org.apache.arrow.flight.FlightRuntimeException;
import org.apache.arrow.flight.FlightStream;
import org.apache.arrow.memory.BufferAllocator;
import org.apache.arrow.memory.RootAllocator;
import org.apache.arrow.vector.FieldVector;
import org.apache.arrow.vector.TimeStampVector;
import org.apache.arrow.vector.VectorSchemaRoot;
import org.apache.arrow.vector.types.pojo.ArrowType;
import org.apache.arrow.vector.util.Text;

import com.example.connectors.framework.testing.ItEnvironment.Endpoint;

/**
 * The Deephaven side of an integration test through the Deephaven Java client 42.5, Flight flavour
 * ({@code io.deephaven:deephaven-java-client-flight-dagger}): an anonymous plaintext session (the CI profile, D10
 * §6.3), tables uploaded with Flight DoPut and published into the query scope, snapshots taken with Flight DoGet on
 * the scope ticket, and the published names removed again through the server's script console.
 */
final class DeephavenTables implements AutoCloseable {

    /** Bound on every single call, so that a stuck server fails the test instead of hanging it. */
    private static final Duration CALL_TIMEOUT = Duration.ofSeconds(30);
    private static final Duration RETRY_INTERVAL = Duration.ofSeconds(2);
    private static final Duration POLL_INTERVAL = Duration.ofMillis(500);
    /** Script types of the server images: python (ghcr.io/deephaven/server, ours) or groovy (server-slim). */
    private static final List<String> CONSOLE_TYPES = List.of("python", "groovy");

    static {
        // Arrow Flight 18.3 reads DoGet data zero-copy through io.grpc.internal.ReadableBuffer.readBytes(ByteBuffer),
        // which gRPC 1.83 (managed by the Spring Boot 4.1 BOM; the client is built against 1.76) no longer has:
        // every snapshot would fail with "CANCELLED: Failed to read message." (NoSuchMethodError). The copying read
        // path uses public API only. Set before any Flight class is loaded; an explicit setting wins.
        if (System.getProperty("arrow.flight.enable_zero_copy_read") == null) {
            System.setProperty("arrow.flight.enable_zero_copy_read", "false");
        }
    }

    /** What a poll ended with: the last snapshot and how it was obtained. */
    record Snapshot(List<Map<String, Object>> rows, String note) {
    }

    private final Endpoint endpoint;
    private final ScheduledExecutorService scheduler;
    private final BufferAllocator allocator;
    private final ManagedChannel channel;
    private final FlightSession flight;
    private final List<TableHandle> uploads = new ArrayList<>();
    private final Set<String> published = new LinkedHashSet<>();

    private DeephavenTables(Endpoint endpoint, ScheduledExecutorService scheduler, BufferAllocator allocator,
            ManagedChannel channel, FlightSession flight) {
        this.endpoint = endpoint;
        this.scheduler = scheduler;
        this.allocator = allocator;
        this.channel = channel;
        this.flight = flight;
    }

    /**
     * Opens a session, retrying for at most {@code budget} while the server is not ready (the client-level probe
     * of D10 §5.3); a server that refuses anonymous sessions fails at once.
     */
    static DeephavenTables connect(Endpoint endpoint, Duration budget) throws InterruptedException {
        ClientConfig config = ClientConfig.builder()
                .target(DeephavenTarget.builder().host(endpoint.host()).port(endpoint.port()).isSecure(false).build())
                .build();
        ScheduledExecutorService scheduler = Executors.newScheduledThreadPool(2,
                Thread.ofPlatform().daemon().name("deephaven-session-", 0).factory());
        BufferAllocator allocator = new RootAllocator();
        FlightSessionFactoryConfig.Factory factory = FlightSessionFactoryConfig.builder()
                .clientConfig(config)
                .allocator(allocator)
                .scheduler(scheduler)
                .build()
                .factory();
        try {
            return new DeephavenTables(endpoint, scheduler, allocator, factory.managedChannel(),
                    openSession(factory, endpoint, budget));
        }
        catch (InterruptedException | RuntimeException | Error ex) {
            shutdown(factory.managedChannel(), allocator, scheduler);
            throw ex;
        }
    }

    /**
     * Uploads {@code rows} as a new table (Flight DoPut) and publishes it into the query scope as {@code table},
     * where a connector's table of that name would be.
     */
    void publish(String table, Map<String, Class<?>> columns, List<Map<String, Object>> rows) throws Exception {
        if (!SourceVersion.isName(table)) {
            throw new IllegalArgumentException(
                    "'" + table + "' is not a valid Deephaven variable name (check IT_TABLE_PREFIX)");
        }
        List<Column<?>> data = new ArrayList<>();
        columns.forEach((name, type) -> data.add(column(name, type, rows)));
        TableHandle handle = flight.putExport(NewTable.of(data), allocator);
        uploads.add(handle);
        published.add(table); // before the call: a publish that lands after a client-side timeout is released too
        flight.session().publish(table, handle).get(CALL_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS);
    }

    /**
     * Polls the table until it has at least {@code expectedRows} rows or {@code timeout} has passed (D8 §6.6); the
     * caller compares the returned snapshot once. A table that does not exist yet counts as empty.
     */
    Snapshot awaitRows(String table, int expectedRows, Duration timeout) throws Exception {
        long deadline = System.nanoTime() + timeout.toNanos();
        List<Map<String, Object>> rows = List.of();
        String last;
        for (int polls = 1; ; polls++) {
            try {
                rows = snapshot(table);
                if (rows.size() >= expectedRows) {
                    return new Snapshot(rows, rows.size() + " rows, poll " + polls);
                }
                last = rows.size() + " of " + expectedRows + " rows";
            }
            catch (FlightRuntimeException ex) {
                last = ex.status().code() + " " + ex.getMessage();
            }
            if (System.nanoTime() - deadline >= 0) {
                return new Snapshot(rows, "gave up after " + timeout + " and " + polls + " polls; last: " + last);
            }
            Thread.sleep(POLL_INTERVAL.toMillis());
        }
    }

    /** One snapshot of a query-scope table through Flight DoGet, as rows of Java values. */
    @SuppressWarnings("try") // FlightStream.close() declares Exception, InterruptedException included
    List<Map<String, Object>> snapshot(String table) throws Exception {
        List<Map<String, Object>> rows = new ArrayList<>();
        try (FlightStream stream = FlightClientHelper.get(flight.getClient(), new ScopeId(table),
                CallOptions.timeout(CALL_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS))) {
            while (stream.next()) {
                VectorSchemaRoot batch = stream.getRoot();
                for (int i = 0; i < batch.getRowCount(); i++) {
                    Map<String, Object> row = new LinkedHashMap<>();
                    for (FieldVector vector : batch.getFieldVectors()) {
                        row.put(vector.getName(), value(vector, i));
                    }
                    rows.add(row);
                }
            }
        }
        return rows;
    }

    /**
     * Removes every table this client published from the query scope (D10 §5.3: a class releases its tables in
     * {@code @AfterAll}) and releases the uploads. The server has no API call for that, so it goes through the
     * script console of whichever type the server runs.
     */
    void releaseAll() throws Exception {
        try {
            for (String table : List.copyOf(published)) {
                removeFromScope(table);
                published.remove(table);
            }
        }
        finally {
            uploads.forEach(TableHandle::close);
            uploads.clear();
        }
    }

    /** Local clean-up only (session, channel, Arrow memory, threads); problems are reported, never thrown. */
    @Override
    public void close() {
        uploads.forEach(TableHandle::close);
        uploads.clear();
        flight.session().close(); // waits, within the session's close timeout, for the server to end the session
        closeQuietly(flight);
        shutdown(channel, allocator, scheduler);
    }

    private void removeFromScope(String table) throws Exception {
        List<String> problems = new ArrayList<>();
        for (String type : CONSOLE_TYPES) {
            ConsoleSession console;
            try {
                console = flight.session().console(type).get(CALL_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS);
            }
            catch (ExecutionException ex) {
                problems.add(type + ": " + Status.fromThrowable(ex.getCause()));
                continue;
            }
            try (console) {
                String script = "python".equals(type) ? "globals().pop('" + table + "', None)"
                        : "binding.variables.remove('" + table + "')";
                Changes changes = console.executeCodeFuture(script)
                        .get(CALL_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS);
                if (changes.errorMessage().isPresent()) {
                    throw new AssertionError("removing '" + table + "' from the Deephaven query scope (" + type
                            + " console) failed: " + changes.errorMessage().get());
                }
                return;
            }
        }
        throw new AssertionError("cannot remove '" + table + "' from the Deephaven query scope on " + endpoint
                + ": no script console of type " + CONSOLE_TYPES + " (" + String.join("; ", problems) + ")");
    }

    private static FlightSession openSession(FlightSessionFactoryConfig.Factory factory, Endpoint endpoint,
            Duration budget) throws InterruptedException {
        long deadline = System.nanoTime() + budget.toNanos();
        while (true) {
            // Opening a session blocks on the handshake without a deadline of its own: bound each attempt.
            CompletableFuture<FlightSession> attempt = CompletableFuture.supplyAsync(factory::newFlightSession,
                    task -> Thread.ofPlatform().daemon().name("deephaven-connect").start(task));
            Throwable failure;
            try {
                return attempt.get(Math.min(CALL_TIMEOUT.toNanos(), Math.max(deadline - System.nanoTime(), 1)),
                        TimeUnit.NANOSECONDS);
            }
            catch (ExecutionException ex) {
                failure = ex.getCause();
                Status.Code code = Status.fromThrowable(failure).getCode();
                if (code == Status.Code.UNAUTHENTICATED || code == Status.Code.PERMISSION_DENIED) {
                    throw new AssertionError("Deephaven " + endpoint + " refuses anonymous sessions (" + code + "): "
                            + "the CI profile needs the anonymous handler (test-infra/compose/deephaven.yml)", failure);
                }
            }
            catch (TimeoutException ex) {
                failure = ex;
                attempt.thenAccept(DeephavenTables::closeQuietly); // a late session must not leak
            }
            if (System.nanoTime() - deadline >= 0) {
                throw new AssertionError("no Deephaven session with " + endpoint + " within " + budget + ": "
                        + Status.fromThrowable(failure), failure);
            }
            Thread.sleep(RETRY_INTERVAL.toMillis());
        }
    }

    private static <T> Column<T> column(String name, Class<T> type, List<Map<String, Object>> rows) {
        List<T> values = new ArrayList<>(rows.size());
        for (Map<String, Object> row : rows) {
            values.add(type.cast(row.get(name)));
        }
        return Column.of(name, type, values);
    }

    /** A cell as a plain Java value: strings as String, timestamps as Instant, numbers as their boxed type. */
    private static Object value(FieldVector vector, int row) {
        if (vector.isNull(row)) {
            return null;
        }
        if (vector instanceof TimeStampVector timestamps
                && vector.getField().getType() instanceof ArrowType.Timestamp type) {
            long raw = timestamps.get(row);
            return switch (type.getUnit()) {
                case SECOND -> Instant.ofEpochSecond(raw);
                case MILLISECOND -> Instant.ofEpochMilli(raw);
                case MICROSECOND -> Instant.EPOCH.plus(raw, ChronoUnit.MICROS);
                case NANOSECOND -> Instant.EPOCH.plusNanos(raw);
            };
        }
        Object value = vector.getObject(row);
        return value instanceof Text text ? text.toString() : value;
    }

    private static void closeQuietly(FlightSession session) {
        try {
            session.close();
        }
        catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
        }
        catch (RuntimeException ex) {
            // FlightClient.close() checks its Arrow allocator; a leak after an aborted stream is not a test result.
            System.err.println("[DeephavenTables] closing the Flight session: " + ex);
        }
    }

    private static void shutdown(ManagedChannel channel, BufferAllocator allocator,
            ScheduledExecutorService scheduler) {
        // Graceful first, so that release calls still in flight complete; forced after five seconds.
        channel.shutdown();
        try {
            if (!channel.awaitTermination(5, TimeUnit.SECONDS)) {
                channel.shutdownNow().awaitTermination(5, TimeUnit.SECONDS);
            }
        }
        catch (InterruptedException ex) {
            channel.shutdownNow();
            Thread.currentThread().interrupt();
        }
        try {
            allocator.close();
        }
        catch (IllegalStateException leak) {
            // Arrow reports buffers still held (e.g. after an aborted stream); the JVM ends with the test run.
            System.err.println("[DeephavenTables] " + leak.getMessage());
        }
        scheduler.shutdownNow();
    }
}
