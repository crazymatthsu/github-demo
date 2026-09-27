package com.example.connectors.sourcedatabase;

import org.springframework.boot.autoconfigure.SpringBootApplication;

import com.example.connectors.framework.ConnectorApplication;

/**
 * source-database: JDBC (SQL Server) -> AMPS / Deephaven. Hello world: on start-up it logs its identity and the masked effective configuration
 * (connectors-framework) and serves the actuator on 8080; {@code --print-config} prints the configuration and
 * exits.
 */
@SpringBootApplication
public class SourceDatabaseApplication {

    public static void main(String[] args) {
        ConnectorApplication.run(SourceDatabaseApplication.class, args);
    }
}
