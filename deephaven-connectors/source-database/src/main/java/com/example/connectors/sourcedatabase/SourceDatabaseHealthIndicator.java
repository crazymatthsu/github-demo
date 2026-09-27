package com.example.connectors.sourcedatabase;

import org.springframework.boot.health.contributor.Health;
import org.springframework.boot.health.contributor.HealthIndicator;
import org.springframework.stereotype.Component;

/**
 * Health contributor {@code sourceDatabase}: the result of the start-up {@link HelloWorldQuery}. Not a member
 * of the readiness group, so a missing database never stops the app from starting or becoming ready — it
 * shows in {@code /actuator/health} as DOWN with the error instead.
 */
@Component
public class SourceDatabaseHealthIndicator implements HealthIndicator {

    private final HelloWorldQuery query;

    public SourceDatabaseHealthIndicator(HelloWorldQuery query) {
        this.query = query;
    }

    @Override
    public Health health() {
        HelloWorldQuery.QueryResult result = query.result();
        Health.Builder builder = switch (result.state()) {
            case PENDING -> Health.unknown();
            case SUCCEEDED -> Health.up();
            case FAILED -> Health.down();
        };
        builder.withDetail("query", "SELECT 1" + (result.table() != null ? " / SELECT COUNT(*) FROM " + result.table() : ""));
        if (result.selectOne() != null) {
            builder.withDetail("selectOne", result.selectOne());
        }
        if (result.rowCount() != null) {
            builder.withDetail("rowCount", result.rowCount());
        }
        if (result.error() != null) {
            builder.withDetail("error", result.error());
        }
        if (result.checkedAt() != null) {
            builder.withDetail("checkedAt", result.checkedAt().toString());
        }
        return builder.build();
    }
}
