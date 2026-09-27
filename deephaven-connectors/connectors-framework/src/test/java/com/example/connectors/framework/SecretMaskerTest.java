package com.example.connectors.framework;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class SecretMaskerTest {

    @ParameterizedTest
    @ValueSource(strings = {
            "spring.datasource.password", "spring.datasource.username", "SPRING_DATASOURCE_PASSWORD",
            "connector.amps.password", "connector.amps.username", "connector.kafka.sasl.jaas-config",
            "connector.deephaven.token", "connector.tls.keystore.password", "connector.sink.amps.api-key",
            "some.client-secret", "vault.credentials.role", "private-key" })
    void masksSecretLookingKeys(String key) {
        assertThat(SecretMasker.isSecret(key)).isTrue();
        assertThat(SecretMasker.mask(key, "hunter2")).isEqualTo(SecretMasker.MASK);
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "connector.source.host", "connector.source.table", "connector.sink.deephaven.table",
            "connector.source.poll-interval", "spring.datasource.url", "compare.key-columns", "connector.sink.type" })
    void showsEverythingElse(String key) {
        assertThat(SecretMasker.isSecret(key)).isFalse();
        assertThat(SecretMasker.mask(key, "value")).isEqualTo("value");
    }

    @Test
    void masksCredentialsInsideUrls() {
        assertThat(SecretMasker.mask("spring.datasource.url",
                "jdbc:sqlserver://sql:1433;databaseName=trades;user=sa;password=p@ss;encrypt=true"))
                .isEqualTo("jdbc:sqlserver://sql:1433;databaseName=trades;user=sa;password=******;encrypt=true");
        assertThat(SecretMasker.maskUrlCredentials("https://svc:t0ken@example.com/path"))
                .isEqualTo("https://svc:******@example.com/path");
    }

    @Test
    void nullStaysVisibleAsNull() {
        assertThat(SecretMasker.mask("connector.source.host", null)).isEqualTo("null");
    }
}
