package com.example.connectors.framework;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.core.env.ConfigurableEnvironment;

/** Logs the identity and the masked effective configuration once the application is ready (brief §4). */
public class ConnectorStartupReporter implements ApplicationListener<ApplicationReadyEvent> {

    private static final Logger log = LoggerFactory.getLogger(ConnectorStartupReporter.class);

    private final ConnectorIdentity identity;

    public ConnectorStartupReporter(ConnectorIdentity identity) {
        this.identity = identity;
    }

    @Override
    public void onApplicationEvent(ApplicationReadyEvent event) {
        ConnectorMdc.put(identity);
        ConfigurableEnvironment environment = event.getApplicationContext().getEnvironment();
        if (environment.getProperty(ConnectorApplication.PRINT_CONFIG_PROPERTY, Boolean.class, false)) {
            return; // --print-config prints the summary itself
        }
        log.info("Started {}", identity.tuple());
        log.info("{}", ConfigurationSummary.capture(environment, identity).render());
    }
}
