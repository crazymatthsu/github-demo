package com.example.connectors.sourcedatabase;

import org.junit.jupiter.api.Test;

import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.mock.env.MockEnvironment;

import com.example.connectors.framework.ConnectorIdentity;
import com.example.connectors.framework.ConnectorProperties;
import com.example.connectors.framework.ConnectorProperties.Amps;
import com.example.connectors.framework.ConnectorProperties.Deephaven;
import com.example.connectors.framework.ConnectorProperties.Sink;
import com.example.connectors.framework.ConnectorProperties.SinkType;
import com.example.connectors.framework.ConnectorProperties.Source;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class HelloWorldQueryTest {

    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final ConnectorIdentity identity = new ConnectorIdentity("local", "cash", "source-database", "positions-db-to-deephaven");

    private HelloWorldQuery query(String table) {
        ConnectorProperties properties = new ConnectorProperties(
                new Source("sqlserver", 1433, "positions", table, java.time.Duration.ofSeconds(5)),
                new Sink(SinkType.STUB, new Amps(null, null, null), new Deephaven(null, null, null)));
        return new HelloWorldQuery(jdbc, properties, identity, new MockEnvironment());
    }

    @Test
    void runsSelectOneAndCountsTheConfiguredTable() {
        when(jdbc.queryForObject("SELECT 1", Integer.class)).thenReturn(1);
        when(jdbc.queryForObject("SELECT COUNT(*) FROM dbo.positions", Long.class)).thenReturn(42L);

        HelloWorldQuery.QueryResult result = query("dbo.positions").execute();

        assertThat(result.state()).isEqualTo(HelloWorldQuery.QueryResult.State.SUCCEEDED);
        assertThat(result.selectOne()).isEqualTo(1);
        assertThat(result.rowCount()).isEqualTo(42L);
        assertThat(new SourceDatabaseHealthIndicator(query("dbo.positions")).health().getStatus().getCode()).isEqualTo("UNKNOWN");
    }

    @Test
    void withoutATableOnlySelectOneRuns() {
        when(jdbc.queryForObject("SELECT 1", Integer.class)).thenReturn(1);

        HelloWorldQuery.QueryResult result = query(null).execute();

        assertThat(result.state()).isEqualTo(HelloWorldQuery.QueryResult.State.SUCCEEDED);
        assertThat(result.rowCount()).isNull();
        verify(jdbc, never()).queryForObject(eq("SELECT COUNT(*) FROM null"), eq(Long.class));
    }

    @Test
    void aMissingDatabaseIsReportedNotThrown() {
        when(jdbc.queryForObject("SELECT 1", Integer.class))
                .thenThrow(new DataAccessResourceFailureException("no route", new java.net.ConnectException("Connection refused")));
        HelloWorldQuery query = query("dbo.positions");

        HelloWorldQuery.QueryResult result = query.execute();

        assertThat(result.state()).isEqualTo(HelloWorldQuery.QueryResult.State.FAILED);
        assertThat(result.error()).isEqualTo("ConnectException: Connection refused");
        assertThat(new SourceDatabaseHealthIndicator(query).health().getStatus().getCode()).isEqualTo("DOWN");
    }

    @Test
    void refusesATableNameThatIsNotAnIdentifier() {
        when(jdbc.queryForObject("SELECT 1", Integer.class)).thenReturn(1);

        HelloWorldQuery.QueryResult result = query("dbo.positions; DROP TABLE x").execute();

        assertThat(result.state()).isEqualTo(HelloWorldQuery.QueryResult.State.FAILED);
        assertThat(result.error()).contains("not a plain");
    }
}
