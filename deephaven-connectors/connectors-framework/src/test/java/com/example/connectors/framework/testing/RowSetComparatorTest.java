package com.example.connectors.framework.testing;

import java.math.BigDecimal;
import java.time.Duration;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class RowSetComparatorTest {

    private static final CompareRules RULES = CompareRules.keyedBy("account", "instrument")
            .ignoring("ingested_at")
            .withTimestampTolerance(Duration.ofSeconds(2), "as_of")
            .withNumericTolerance(new BigDecimal("0.01"), "price");

    private static Map<String, Object> row(String account, String instrument, Object qty, Object price, String asOf) {
        return Map.of("account", account, "instrument", instrument, "qty", qty, "price", price, "as_of", asOf,
                "ingested_at", "2026-09-26T00:00:00Z");
    }

    @Test
    void matchesAsASetOnTheKeyColumnsWithinTolerances() {
        List<Map<String, Object>> expected = List.of(
                row("A-1", "IBM", 10, new BigDecimal("101.50"), "2026-09-26T10:00:00Z"),
                row("A-2", "MSFT", 5, new BigDecimal("300.00"), "2026-09-26T10:00:00Z"));
        List<Map<String, Object>> actual = List.of(
                Map.of("account", "A-2", "instrument", "MSFT", "qty", new BigDecimal("5.0"), "price", 300.004,
                        "as_of", "2026-09-26T10:00:01.500Z", "ingested_at", "2026-09-27T08:00:00Z"),
                row("A-1", "IBM", 10L, 101.5, "2026-09-26T10:00:00.000Z"));

        ComparisonResult result = RowSetComparator.compare(expected, actual, RULES);

        assertThat(result.matches()).as(result.summary(10)).isTrue();
        assertThat(result.summary(10)).isEqualTo("rows match (2 rows)");
    }

    @Test
    void reportsMissingUnexpectedAndPerColumnDifferences() {
        List<Map<String, Object>> expected = List.of(
                row("A-1", "IBM", 10, 101.5, "2026-09-26T10:00:00Z"),
                row("A-3", "AAPL", 1, 200, "2026-09-26T10:00:00Z"));
        List<Map<String, Object>> actual = List.of(
                row("A-1", "IBM", 11, 101.6, "2026-09-26T10:00:05Z"),
                row("A-9", "ORCL", 1, 100, "2026-09-26T10:00:00Z"));

        ComparisonResult result = RowSetComparator.compare(expected, actual, RULES);

        assertThat(result.matches()).isFalse();
        assertThat(result.missing()).singleElement().asString().contains("\"account\":\"A-3\"");
        assertThat(result.unexpected()).singleElement().asString().contains("\"account\":\"A-9\"");
        assertThat(result.differences()).extracting(ComparisonResult.Difference::column)
                .containsExactly("as_of", "price", "qty");
        assertThat(result.summary(10)).contains("missing (1)", "unexpected (1)", "differences (3)");
        assertThat(result.toJson()).startsWith("{\"actualRows\":2,\"differences\":[");
    }

    @Test
    void duplicateKeysAreAFailure() {
        List<Map<String, Object>> rows = List.of(
                row("A-1", "IBM", 10, 1, "2026-09-26T10:00:00Z"),
                row("A-1", "IBM", 12, 1, "2026-09-26T10:00:00Z"));

        ComparisonResult result = RowSetComparator.compare(rows.subList(0, 1), rows, RULES);

        assertThat(result.duplicates()).containsExactly("actual {\"account\":\"A-1\",\"instrument\":\"IBM\"}");
        assertThat(result.matches()).isFalse();
    }

    @Test
    void orderedComparisonMatchesByPosition() {
        CompareRules ordered = CompareRules.keyedBy().ordered(true);
        List<Map<String, Object>> expected = List.of(Map.of("n", 1), Map.of("n", 2));

        assertThat(RowSetComparator.compare(expected, List.of(Map.of("n", 1), Map.of("n", 2)), ordered).matches()).isTrue();
        ComparisonResult swapped = RowSetComparator.compare(expected, List.of(Map.of("n", 2), Map.of("n", 1)), ordered);
        assertThat(swapped.differences()).hasSize(2);
    }

    @Test
    void readsTheCompareBlockOfAManifest() {
        CompareRules rules = CompareRules.fromManifest(Map.of(
                "keyColumns", List.of("account", "instrument"),
                "ordered", false,
                "ignoreColumns", List.of("ingested_at"),
                "timestampTolerance", Map.of("columns", List.of("as_of"), "seconds", 2),
                "numericTolerance", Map.of("columns", List.of("qty"), "abs", 0)));

        assertThat(rules.keyColumns()).containsExactly("account", "instrument");
        assertThat(rules.ignoreColumns()).containsExactly("ingested_at");
        assertThat(rules.timestampTolerance()).isEqualTo(Duration.ofSeconds(2));
        assertThat(rules.numericColumns()).containsExactly("qty");
        assertThat(rules.numericTolerance()).isEqualByComparingTo("0");
    }
}
