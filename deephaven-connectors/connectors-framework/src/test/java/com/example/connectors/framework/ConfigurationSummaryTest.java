package com.example.connectors.framework;

import java.util.Map;

import org.junit.jupiter.api.Test;

import org.springframework.core.env.MapPropertySource;
import org.springframework.core.env.StandardEnvironment;

import static org.assertj.core.api.Assertions.assertThat;

class ConfigurationSummaryTest {

    @Test
    void showsTheEffectiveConnectorConfigurationWithSecretsMasked() {
        StandardEnvironment environment = new StandardEnvironment();
        environment.getPropertySources().addFirst(new MapPropertySource(
                "Config resource 'file [/config/common/application.yml]' via location 'optional:file:/config/common/application.yml'",
                Map.of("connector.source.port", 1433, "connector.source.poll-interval", "15s")));
        environment.getPropertySources().addFirst(new MapPropertySource(
                "Config resource 'file [/config/instance/application.yml]' via location 'optional:file:/config/instance/application.yml'",
                Map.of("connector.source.poll-interval", "5s", "connector.sink.type", "amps")));
        environment.getPropertySources().addFirst(new MapPropertySource("secrets", Map.of(
                "spring.datasource.password", "s3cr3t-value", "connector.amps.password", "an0ther-value")));
        ConnectorIdentity identity = new ConnectorIdentity("us-dev", "cash", "source-database", "trades-db-to-amps");

        ConfigurationSummary summary = ConfigurationSummary.capture(environment, identity);

        assertThat(summary.layers()).containsExactly("/config/common/application.yml", "/config/instance/application.yml");
        assertThat(summary.properties())
                .containsEntry("connector.source.poll-interval", "5s")
                .containsEntry("connector.source.port", "1433")
                .containsEntry("connector.sink.type", "amps")
                .containsEntry("connector.amps.password", SecretMasker.MASK)
                .containsEntry("spring.datasource.password", SecretMasker.MASK);
        String text = summary.render();
        assertThat(text).contains("Connector us-dev/cash/source-database/trades-db-to-amps")
                .contains("connector.source.poll-interval = 5s")
                .doesNotContain("s3cr3t-value", "an0ther-value");
        assertThat(summary.asMap()).containsEntry("identity", "us-dev/cash/source-database/trades-db-to-amps");
    }

    @Test
    void anIncompleteIdentityIsFlagged() {
        ConfigurationSummary summary = ConfigurationSummary.capture(new StandardEnvironment(),
                new ConnectorIdentity("local", "none", "source-kafka", "none"));

        assertThat(summary.render()).contains("identity incomplete").contains("none (jar defaults only)");
    }
}
