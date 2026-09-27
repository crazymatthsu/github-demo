package com.example.connectors.framework;

import java.time.Duration;

import org.junit.jupiter.api.Test;

import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

import static org.assertj.core.api.Assertions.assertThat;

class ConnectorPropertiesTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(
                    org.springframework.boot.validation.autoconfigure.ValidationAutoConfiguration.class,
                    ConnectorFrameworkAutoConfiguration.class))
            .withPropertyValues("spring.application.name=source-database");

    @Test
    void bindsTheConnectorContract() {
        runner.withPropertyValues(
                "connector.source.host=sql-trades.us-dev.example.com",
                "connector.source.port=1433",
                "connector.source.database=trades",
                "connector.source.table=dbo.trades",
                "connector.source.poll-interval=5s",
                "connector.sink.type=amps",
                "connector.sink.amps.host=amps-cash.us-dev.example.com",
                "connector.sink.amps.port=9007",
                "connector.sink.amps.topic=cash.trades")
                .run(context -> {
                    assertThat(context).hasNotFailed();
                    ConnectorProperties properties = context.getBean(ConnectorProperties.class);
                    assertThat(properties.source().host()).isEqualTo("sql-trades.us-dev.example.com");
                    assertThat(properties.source().port()).isEqualTo(1433);
                    assertThat(properties.source().table()).isEqualTo("dbo.trades");
                    assertThat(properties.source().pollInterval()).isEqualTo(Duration.ofSeconds(5));
                    assertThat(properties.sink().type()).isEqualTo(ConnectorProperties.SinkType.AMPS);
                    assertThat(properties.sink().amps().topic()).isEqualTo("cash.trades");
                });
    }

    @Test
    void defaultsToTheStubSinkAndThirtySecondPolling() {
        runner.run(context -> {
            ConnectorProperties properties = context.getBean(ConnectorProperties.class);
            assertThat(properties.sink().type()).isEqualTo(ConnectorProperties.SinkType.STUB);
            assertThat(properties.source().pollInterval()).isEqualTo(Duration.ofSeconds(30));
        });
    }

    @Test
    void anAmpsSinkWithoutATopicFailsValidation() {
        runner.withPropertyValues("connector.sink.type=amps", "connector.sink.amps.host=amps", "connector.sink.amps.port=9007")
                .run(context -> assertThat(context).hasFailed().getFailure()
                        .hasStackTraceContaining("connector.sink.amps.host, .port and .topic are required"));
    }

    @Test
    void anOutOfRangePortFailsValidation() {
        runner.withPropertyValues("connector.source.port=70000")
                .run(context -> assertThat(context).hasFailed().getFailure().hasStackTraceContaining("source.port"));
    }

    @Test
    void registersTheIdentityAndTheReadinessIndicator() {
        runner.withPropertyValues("APP_ENV=us-dev", "APP_FLOW=cash", "APP_INSTANCE=positions-db-to-deephaven")
                .run(context -> {
                    assertThat(context.getBean(ConnectorIdentity.class).tuple())
                            .isEqualTo("us-dev/cash/source-database/positions-db-to-deephaven");
                    assertThat(context.getBean(ConnectorHealthIndicator.class).health().getDetails())
                            .containsEntry("sink", "stub");
                });
    }
}
