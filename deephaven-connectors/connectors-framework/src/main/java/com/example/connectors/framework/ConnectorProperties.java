package com.example.connectors.framework;

import java.time.Duration;

import jakarta.validation.Valid;
import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;
import org.springframework.validation.annotation.Validated;

/**
 * The {@code connector.*} property contract shared by every connector (D5 §6.3). Endpoints, topics and table
 * names live here and in the config tree's YAML layers; secrets never do (D2 §6.4).
 *
 * <pre>
 * connector.source.{host,port,database,table,poll-interval}
 * connector.sink.type                       amps | deephaven | stub
 * connector.sink.amps.{host,port,topic}
 * connector.sink.deephaven.{host,port,table}
 * </pre>
 */
@Validated
@ConfigurationProperties("connector")
public record ConnectorProperties(@Valid @DefaultValue Source source, @Valid @DefaultValue Sink sink) {

    /** Where the pipeline reads from: a database, a Kafka broker or an AMPS server. */
    public record Source(
            String host,
            @Min(1) @Max(65535) Integer port,
            String database,
            /** Table (JDBC), topic (Kafka) or subscription topic (AMPS). */
            String table,
            @NotNull @DefaultValue("30s") Duration pollInterval) {
    }

    /** Where the pipeline publishes to. */
    public record Sink(
            @NotNull @DefaultValue("stub") SinkType type,
            @Valid @DefaultValue Amps amps,
            @Valid @DefaultValue Deephaven deephaven) {

        @AssertTrue(message = "connector.sink.amps.host, .port and .topic are required when connector.sink.type=amps")
        public boolean isAmpsComplete() {
            return type != SinkType.AMPS || (hasText(amps.host()) && amps.port() != null && hasText(amps.topic()));
        }

        @AssertTrue(message = "connector.sink.deephaven.host, .port and .table are required when connector.sink.type=deephaven")
        public boolean isDeephavenComplete() {
            return type != SinkType.DEEPHAVEN
                    || (hasText(deephaven.host()) && deephaven.port() != null && hasText(deephaven.table()));
        }
    }

    /** {@code amps}, {@code deephaven} or {@code stub} (the demo stand-in for an unavailable target). */
    public enum SinkType {
        AMPS, DEEPHAVEN, STUB
    }

    public record Amps(String host, @Min(1) @Max(65535) Integer port, String topic) {
    }

    public record Deephaven(String host, @Min(1) @Max(65535) Integer port, String table) {
    }

    private static boolean hasText(String value) {
        return value != null && !value.isBlank();
    }
}
