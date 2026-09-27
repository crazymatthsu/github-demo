package com.example.connectors.framework;

import io.micrometer.core.instrument.MeterRegistry;

import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.info.InfoContributor;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.health.contributor.HealthIndicator;
import org.springframework.boot.micrometer.metrics.autoconfigure.MeterRegistryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.ConfigurableEnvironment;

/**
 * Wires the framework into every connector app: identity, {@code connector.*} binding and validation,
 * the start-up summary, identity tags on every meter, the readiness indicator {@code connector}, the
 * identity in {@code /actuator/info} and the {@code connectorconfig} endpoint.
 */
@AutoConfiguration
@EnableConfigurationProperties(ConnectorProperties.class)
public class ConnectorFrameworkAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    ConnectorIdentity connectorIdentity(ConfigurableEnvironment environment) {
        return ConnectorIdentity.from(environment);
    }

    @Bean
    ConnectorStartupReporter connectorStartupReporter(ConnectorIdentity identity) {
        return new ConnectorStartupReporter(identity);
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnClass({ MeterRegistry.class, MeterRegistryCustomizer.class })
    static class MetricsConfiguration {

        /** Common tags {@code env, flow, app, instance} on every meter (D6 §6.9). */
        @Bean
        MeterRegistryCustomizer<MeterRegistry> connectorIdentityTags(ConnectorIdentity identity) {
            return registry -> identity.asTags().forEach((key, value) -> registry.config().commonTags(key, value));
        }
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnClass(HealthIndicator.class)
    static class HealthConfiguration {

        @Bean
        ConnectorHealthIndicator connectorHealthIndicator(ConnectorIdentity identity, ConnectorProperties properties) {
            return new ConnectorHealthIndicator(identity, properties);
        }
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnClass({ InfoContributor.class, Endpoint.class })
    static class ActuatorConfiguration {

        @Bean
        ConnectorInfoContributor connectorInfoContributor(ConnectorIdentity identity) {
            return new ConnectorInfoContributor(identity);
        }

        @Bean
        ConnectorConfigEndpoint connectorConfigEndpoint(ConfigurableEnvironment environment, ConnectorIdentity identity) {
            return new ConnectorConfigEndpoint(environment, identity);
        }
    }
}
