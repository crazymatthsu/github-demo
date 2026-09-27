package com.example.connectors.framework;

import org.springframework.boot.health.contributor.Health;
import org.springframework.boot.health.contributor.HealthIndicator;

/**
 * Health contributor {@code connector}, member of the readiness group (jar defaults:
 * {@code management.endpoint.health.group.readiness.include=readinessState,connector}). The hello-world
 * connectors have no pipeline yet, so it reports UP with the identity and the sink; a real pipeline reports
 * its source and sink connections here, so that {@code start --wait} and {@code helm --atomic} wait for a
 * working pipeline (D6 §6.9).
 */
public class ConnectorHealthIndicator implements HealthIndicator {

    private final ConnectorIdentity identity;
    private final ConnectorProperties properties;

    public ConnectorHealthIndicator(ConnectorIdentity identity, ConnectorProperties properties) {
        this.identity = identity;
        this.properties = properties;
    }

    @Override
    public Health health() {
        return Health.up()
                .withDetail("identity", identity.tuple())
                .withDetail("sink", properties.sink().type().name().toLowerCase(java.util.Locale.ROOT))
                .withDetail("pipeline", "hello-world")
                .build();
    }
}
