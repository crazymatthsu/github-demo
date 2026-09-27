package com.example.connectors.sourcedatabase;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.yaml.snakeyaml.Yaml;

import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.core.env.ConfigurableEnvironment;

import com.example.connectors.framework.ConfigurationSummary;
import com.example.connectors.framework.ConnectorApplication;
import com.example.connectors.framework.ConnectorIdentity;
import com.example.connectors.framework.SecretMasker;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The rendered-config test of D5 §8 (R2): the jar's import list, pointed at a temporary tree instead of
 * /config and /secrets, applies jar defaults < platform < env < app-common < instance < secrets.
 */
class ConfigLayeringTest {

    private static final List<String> DOCUMENTED_IMPORTS = List.of(
            "optional:file:/config/platform/application.yml",
            "optional:file:/config/env/application.yml",
            "optional:file:/config/common/application.yml",
            "optional:file:/config/instance/application.yml",
            "optional:configtree:/secrets/");

    @SuppressWarnings("unchecked")
    private static List<String> jarImportList() throws IOException {
        try (InputStream in = ConfigLayeringTest.class.getResourceAsStream("/application.yml")) {
            Map<String, Object> yaml = new Yaml().load(in);
            Map<String, Object> config = (Map<String, Object>) ((Map<String, Object>) yaml.get("spring")).get("config");
            return (List<String>) config.get("import");
        }
    }

    private static void write(Path file, String content) throws IOException {
        Files.createDirectories(file.getParent());
        Files.writeString(file, content);
    }

    @Test
    void laterLayersOverrideEarlierOnesAndSecretsComeLast(@TempDir Path root) throws IOException {
        List<String> imports = jarImportList();
        assertThat(imports).containsExactlyElementsOf(DOCUMENTED_IMPORTS);
        write(root.resolve("config/platform/application.yml"),
                "connector.source.poll-interval: 15s\nconnector.source.port: 1111\nconnector.source.host: from-platform\n");
        write(root.resolve("config/env/application.yml"), "connector.source.host: from-env\n");
        write(root.resolve("config/common/application.yml"),
                "connector.source.port: 1433\nconnector.source.poll-interval: 5s\nconnector.sink.amps.port: 9007\n");
        write(root.resolve("config/instance/application.yml"),
                "connector.source.host: sql-trades.us-dev.example.com\nconnector.source.table: dbo.trades\n");
        write(root.resolve("secrets/spring.datasource.password"), "from-the-secret-tree");
        String rewritten = imports.stream()
                .map(i -> i.replace("/config/", root + "/config/").replace("/secrets/", root + "/secrets/"))
                .collect(Collectors.joining(","));

        try (ConfigurableApplicationContext context = new SpringApplicationBuilder(SourceDatabaseApplication.class)
                .web(WebApplicationType.NONE)
                .properties(ConnectorApplication.PRINT_CONFIG_PROPERTY + "=true")
                .run("--spring.config.import=" + rewritten, "--APP_ENV=us-dev", "--APP_FLOW=cash",
                        "--APP_INSTANCE=trades-db-to-amps")) {
            ConfigurableEnvironment environment = context.getEnvironment();
            assertThat(environment.getProperty("connector.source.host")).as("instance > env > platform")
                    .isEqualTo("sql-trades.us-dev.example.com");
            assertThat(environment.getProperty("connector.source.port")).as("app-common > platform").isEqualTo("1433");
            assertThat(environment.getProperty("connector.source.poll-interval")).as("app-common > platform > jar")
                    .isEqualTo("5s");
            assertThat(environment.getProperty("connector.sink.type")).as("jar default").isEqualTo("stub");
            assertThat(environment.getProperty("spring.datasource.password")).as("secrets config tree")
                    .isEqualTo("from-the-secret-tree");
            assertThat(environment.getProperty("spring.datasource.url"))
                    .isEqualTo("jdbc:sqlserver://sql-trades.us-dev.example.com:1433;databaseName=master;encrypt=true");

            ConfigurationSummary summary = ConfigurationSummary.capture(environment,
                    context.getBean(ConnectorIdentity.class));
            assertThat(summary.layers()).containsExactly(
                    root + "/config/platform/application.yml", root + "/config/env/application.yml",
                    root + "/config/common/application.yml", root + "/config/instance/application.yml",
                    root + "/secrets/");
            assertThat(summary.properties()).containsEntry("spring.datasource.password", SecretMasker.MASK);
            assertThat(summary.render()).doesNotContain("from-the-secret-tree");
        }
    }
}
