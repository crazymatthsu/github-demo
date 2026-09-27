package com.example.connectors.framework;

import java.util.concurrent.atomic.AtomicReference;

import org.junit.jupiter.api.Test;
import org.slf4j.MDC;

import static org.assertj.core.api.Assertions.assertThat;

class ConnectorMdcTest {

    @Test
    void wrapCarriesTheIdentityIntoTheTaskAndClearsItAfterwards() throws InterruptedException {
        ConnectorIdentity identity = new ConnectorIdentity("us-dev", "cash", "source-amps", "reuters-fx");
        AtomicReference<String> seen = new AtomicReference<>();

        Thread worker = new Thread(ConnectorMdc.wrap(identity, () -> seen.set(MDC.get("instance") + "@" + MDC.get("env"))));
        worker.start();
        worker.join();

        assertThat(seen.get()).isEqualTo("reuters-fx@us-dev");
        assertThat(MDC.get("instance")).isNull();
    }
}
