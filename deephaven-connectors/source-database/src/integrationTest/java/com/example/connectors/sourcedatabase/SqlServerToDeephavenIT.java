package com.example.connectors.sourcedatabase;

import java.nio.file.Path;
import java.sql.Connection;
import java.time.Duration;
import java.util.Map;
import java.util.Optional;

import org.assertj.core.api.InstanceOfAssertFactories;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;

import com.example.connectors.framework.testing.ActuatorClient;
import com.example.connectors.framework.testing.ItEnvironment;
import com.example.connectors.framework.testing.ItEnvironment.Endpoint;
import com.example.connectors.framework.testing.TestCase;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * The reference case of source-database (D8 §5.2, §6.5), {@code test-infra/testdata/source-database/positions-basic},
 * against the compose stack (sqlserver + deephaven, and the app image when APP_IMAGE is set).
 *
 * <p>The app is still a hello world that does not publish to Deephaven, so this test plays the connector's part:
 * it seeds SQL Server, reads the rows back over JDBC, uploads them to Deephaven as {@code ${IT_TABLE_PREFIX}positions}
 * (the name the instance config gives the connector's target table), then polls and snapshots that table through the
 * Deephaven Java client and compares it with the expected rows under the manifest's rules. Once the connector
 * publishes the table itself, only the upload step goes. The app under test is checked through its actuator.
 */
@Tag("component")
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SqlServerToDeephavenIT {

    private static final String CONNECTOR = "source-database";
    private static final String CASE = "positions-basic";
    /** The table input/schema.sql creates: connector.source.table of the instance config. */
    private static final String SOURCE_TABLE = "dbo.positions";
    private static final String STACK_HINT = "Start the stack first: ./gradlew :deephaven-connectors:source-database:"
            + "integrationTest does (composeUp) unless -Pcompose.managed=false is given; otherwise run "
            + "test-infra/compose/stack.sh up --project :deephaven-connectors:source-database --local, or point "
            + "IT_SQLSERVER_HOST/PORT and IT_DEEPHAVEN_HOST/PORT at a running stack.";

    private TestCase testCase;
    private String targetTable;
    private SqlServerSource.Rows sourceRows;
    private DeephavenTables deephaven;

    @BeforeAll
    void seedSqlServerAndOpenDeephavenSession() throws Exception {
        testCase = TestCase.load(CONNECTOR, CASE);
        Endpoint sqlServer = ItEnvironment.sqlServer();
        Endpoint deephavenServer = ItEnvironment.deephaven();
        ItEnvironment.requireReachable(STACK_HINT, sqlServer, deephavenServer);
        targetTable = ItEnvironment.tablePrefix() + testCase.table();
        Duration budget = ItEnvironment.connectTimeout();

        String user = ItEnvironment.value("SPRING_DATASOURCE_USERNAME", "sa");
        String password = ItEnvironment.optional("SPRING_DATASOURCE_PASSWORD")
                .or(() -> ItEnvironment.optional("IT_SA_PASSWORD"))
                .orElseThrow(() -> new AssertionError("SPRING_DATASOURCE_PASSWORD (or IT_SA_PASSWORD) is not set: "
                        + "use the stack's sa password, which stack.sh up records in test-infra/compose/.state/"));
        // Step 2 of D8 §5.2, idempotent on the shared stack: the generic helpers create the database if the seed
        // has not, schema.sql drops and recreates the table, then the seed files fill it.
        try (Connection master = SqlServerSource.connect(sqlServer, "master", user, password, budget)) {
            for (Path helper : SqlServerSource.scripts(ItEnvironment.repositoryRoot().resolve("test-infra/seed/sqlserver"))) {
                SqlServerSource.apply(master, helper);
            }
        }
        try (Connection database = SqlServerSource.connect(sqlServer, testCase.inputDatabase(), user, password, budget)) {
            SqlServerSource.apply(database, testCase.schema());
            for (Path seed : testCase.seeds()) {
                SqlServerSource.apply(database, seed);
            }
            sourceRows = SqlServerSource.query(database, "SELECT * FROM " + SOURCE_TABLE + " ORDER BY "
                    + String.join(", ", testCase.rules().keyColumns()));
        }
        deephaven = DeephavenTables.connect(deephavenServer, budget);
    }

    @AfterAll
    void releaseTables() throws Exception {
        if (deephaven != null) {
            try (DeephavenTables client = deephaven) {
                client.releaseAll();
            }
        }
    }

    /** The seed landed as the case describes it: separates a seeding problem from a Deephaven one. */
    @Test
    void sourceTableHoldsTheCaseInput() {
        testCase.assertMatches("source", "SQL Server table [" + testCase.inputDatabase() + "]." + SOURCE_TABLE,
                sourceRows.values());
    }

    @Test
    void positionsArriveInDeephavenAsExpected() throws Exception {
        deephaven.publish(targetTable, sourceRows.columns(), sourceRows.values());

        DeephavenTables.Snapshot snapshot = deephaven.awaitRows(targetTable, testCase.expectedRows().size(),
                testCase.timeout());
        testCase.assertMatches(null, "Deephaven table " + targetTable + " (" + snapshot.note() + ")", snapshot.rows());
    }

    /** D8 §5.1: the image under test runs with the instance config and reports the instance's identity. */
    @Test
    void appUnderTestIsReadyWithTheInstanceIdentity() throws Exception {
        Optional<String> image = ItEnvironment.optional("APP_IMAGE");
        assumeTrue(image.isPresent(), "APP_IMAGE is not set: the stack runs without the app under test");
        Optional<Endpoint> app = ItEnvironment.appUnderTest();
        assumeTrue(app.isPresent(), () -> "APP_IMAGE=" + image.get() + " is set, but IT_APP_HOST is not: nothing "
                + "tells this JVM where the app's actuator is (compose service " + CONNECTOR + ":8080 inside the stack "
                + "network, a published port such as 127.0.0.1:18081 on a laptop), so the actuator check is skipped");

        ActuatorClient actuator = new ActuatorClient(app.get());
        assertThat(actuator.awaitReadiness(testCase.timeout())).containsEntry("status", "UP");

        String tuple = String.join("/", ItEnvironment.value("APP_ENV", "local"), ItEnvironment.value("APP_FLOW", "cash"),
                CONNECTOR, testCase.instance());
        Map<String, Object> info = actuator.info();
        assertThat(info).as("/actuator/info of %s", app.get())
                .extractingByKey("connector", InstanceOfAssertFactories.map(String.class, Object.class))
                .containsEntry("tuple", tuple)
                .containsEntry("app", CONNECTOR)
                .containsEntry("instance", testCase.instance())
                .containsEntry("complete", true);
    }
}
