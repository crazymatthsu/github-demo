package com.example.connectors.framework.testing;

import java.math.BigDecimal;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The {@code compare:} block of a test case manifest (D8 §6.5): key columns for a set match (or
 * {@code ordered}), ignored columns, and tolerances for timestamp and numeric columns.
 */
public record CompareRules(
        List<String> keyColumns,
        boolean ordered,
        Set<String> ignoreColumns,
        Set<String> timestampColumns,
        Duration timestampTolerance,
        Set<String> numericColumns,
        BigDecimal numericTolerance) {

    public CompareRules {
        keyColumns = List.copyOf(keyColumns);
        ignoreColumns = Set.copyOf(ignoreColumns);
        timestampColumns = Set.copyOf(timestampColumns);
        numericColumns = Set.copyOf(numericColumns);
        if (timestampTolerance == null || timestampTolerance.isNegative()) {
            throw new IllegalArgumentException("timestampTolerance must be zero or positive");
        }
        if (numericTolerance == null || numericTolerance.signum() < 0) {
            throw new IllegalArgumentException("numericTolerance must be zero or positive");
        }
    }

    /** Exact comparison, set match on the given key columns. */
    public static CompareRules keyedBy(String... keyColumns) {
        return new CompareRules(List.of(keyColumns), false, Set.of(), Set.of(), Duration.ZERO, Set.of(), BigDecimal.ZERO);
    }

    public CompareRules ordered(boolean value) {
        return new CompareRules(keyColumns, value, ignoreColumns, timestampColumns, timestampTolerance,
                numericColumns, numericTolerance);
    }

    public CompareRules ignoring(String... columns) {
        return new CompareRules(keyColumns, ordered, Set.of(columns), timestampColumns, timestampTolerance,
                numericColumns, numericTolerance);
    }

    public CompareRules withTimestampTolerance(Duration tolerance, String... columns) {
        return new CompareRules(keyColumns, ordered, ignoreColumns, Set.of(columns), tolerance, numericColumns,
                numericTolerance);
    }

    public CompareRules withNumericTolerance(BigDecimal tolerance, String... columns) {
        return new CompareRules(keyColumns, ordered, ignoreColumns, timestampColumns, timestampTolerance,
                Set.of(columns), tolerance);
    }

    /**
     * Reads the {@code compare:} mapping of a manifest, e.g. {@code keyColumns: [account, instrument]},
     * {@code ignoreColumns: [ingested_at]}, {@code timestampTolerance: {columns: [as_of], seconds: 2}},
     * {@code numericTolerance: {columns: [qty], abs: 0}}.
     */
    public static CompareRules fromManifest(Map<String, ?> compare) {
        Map<String, ?> timestamps = map(compare.get("timestampTolerance"));
        Map<String, ?> numerics = map(compare.get("numericTolerance"));
        return new CompareRules(
                strings(compare.get("keyColumns")),
                Boolean.TRUE.equals(compare.get("ordered")),
                Set.copyOf(strings(compare.get("ignoreColumns"))),
                Set.copyOf(strings(timestamps.get("columns"))),
                Duration.ofMillis(Math.round(number(timestamps.get("seconds")).doubleValue() * 1000)),
                Set.copyOf(strings(numerics.get("columns"))),
                CanonicalJson.decimal(number(numerics.get("abs"))));
    }

    @SuppressWarnings("unchecked")
    private static Map<String, ?> map(Object value) {
        return value instanceof Map<?, ?> m ? (Map<String, ?>) m : Map.of();
    }

    private static List<String> strings(Object value) {
        return value instanceof List<?> list ? list.stream().map(String::valueOf).toList() : List.of();
    }

    private static Number number(Object value) {
        return value instanceof Number n ? n : 0;
    }
}
