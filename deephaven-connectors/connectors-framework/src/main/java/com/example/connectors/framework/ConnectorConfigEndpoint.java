package com.example.connectors.framework;

import java.util.Map;

import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.core.env.ConfigurableEnvironment;

/**
 * {@code GET /actuator/connectorconfig}: the same masked summary as the start-up log, for
 * {@code run-compose.sh ... app-config} against a running stack (D6 §4.3). Unlike {@code /actuator/env} it
 * never shows a value that the summary would mask.
 */
@Endpoint(id = "connectorconfig")
public class ConnectorConfigEndpoint {

    private final ConfigurableEnvironment environment;
    private final ConnectorIdentity identity;

    public ConnectorConfigEndpoint(ConfigurableEnvironment environment, ConnectorIdentity identity) {
        this.environment = environment;
        this.identity = identity;
    }

    @ReadOperation
    public Map<String, Object> config() {
        return ConfigurationSummary.capture(environment, identity).asMap();
    }
}
