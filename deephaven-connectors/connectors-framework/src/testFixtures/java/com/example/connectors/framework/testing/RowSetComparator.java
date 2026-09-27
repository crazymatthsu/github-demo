package com.example.connectors.framework.testing;

import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.TreeSet;

/**
 * Compares the rows a connector produced with the golden rows of a test case under {@link CompareRules}
 * (D8 §5.5, §6.6): set match on the key columns unless ordered, duplicates are failures, ignored columns are
 * dropped, timestamps and numerics match within their tolerances.
 */
public final class RowSetComparator {

    private RowSetComparator() {
    }

    public static ComparisonResult compare(List<? extends Map<String, ?>> expected, List<? extends Map<String, ?>> actual,
            CompareRules rules) {
        List<Map<String, Object>> expectedRows = expected.stream().map(row -> prepare(row, rules)).toList();
        List<Map<String, Object>> actualRows = actual.stream().map(row -> prepare(row, rules)).toList();
        List<String> missing = new ArrayList<>();
        List<String> unexpected = new ArrayList<>();
        List<ComparisonResult.Difference> differences = new ArrayList<>();
        List<String> duplicates = new ArrayList<>();

        if (rules.ordered()) {
            int common = Math.min(expectedRows.size(), actualRows.size());
            for (int i = 0; i < common; i++) {
                compareRow("#" + i, expectedRows.get(i), actualRows.get(i), rules, differences);
            }
            expectedRows.subList(common, expectedRows.size()).forEach(row -> missing.add(CanonicalJson.write(row)));
            actualRows.subList(common, actualRows.size()).forEach(row -> unexpected.add(CanonicalJson.write(row)));
        }
        else {
            Map<String, Map<String, Object>> expectedByKey = index(expectedRows, rules, duplicates, "expected");
            Map<String, Map<String, Object>> actualByKey = index(actualRows, rules, duplicates, "actual");
            expectedByKey.forEach((key, row) -> {
                Map<String, Object> other = actualByKey.get(key);
                if (other == null) {
                    missing.add(CanonicalJson.write(row));
                }
                else {
                    compareRow(key, row, other, rules, differences);
                }
            });
            actualByKey.forEach((key, row) -> {
                if (!expectedByKey.containsKey(key)) {
                    unexpected.add(CanonicalJson.write(row));
                }
            });
        }
        return new ComparisonResult(expectedRows.size(), actualRows.size(), missing, unexpected, differences, duplicates);
    }

    private static Map<String, Object> prepare(Map<String, ?> row, CompareRules rules) {
        Map<String, Object> prepared = new TreeMap<>();
        row.forEach((column, value) -> {
            if (!rules.ignoreColumns().contains(column)) {
                Object normalised = CanonicalJson.normalise(value);
                if (rules.timestampColumns().contains(column)) {
                    Instant instant = CanonicalJson.parseTimestamp(value);
                    normalised = instant != null ? CanonicalJson.timestamp(instant) : normalised;
                }
                prepared.put(column, normalised);
            }
        });
        return prepared;
    }

    private static Map<String, Map<String, Object>> index(List<Map<String, Object>> rows, CompareRules rules,
            List<String> duplicates, String side) {
        Map<String, Map<String, Object>> byKey = new LinkedHashMap<>();
        for (Map<String, Object> row : rows) {
            String key = key(row, rules);
            if (byKey.putIfAbsent(key, row) != null) {
                duplicates.add(side + " " + key);
            }
        }
        return byKey;
    }

    private static String key(Map<String, Object> row, CompareRules rules) {
        if (rules.keyColumns().isEmpty()) {
            return CanonicalJson.write(row);
        }
        Map<String, Object> key = new TreeMap<>();
        rules.keyColumns().forEach(column -> key.put(column, row.get(column)));
        return CanonicalJson.write(key);
    }

    private static void compareRow(String key, Map<String, Object> expected, Map<String, Object> actual, CompareRules rules,
            List<ComparisonResult.Difference> differences) {
        TreeSet<String> columns = new TreeSet<>(expected.keySet());
        columns.addAll(actual.keySet());
        for (String column : columns) {
            Object e = expected.get(column);
            Object a = actual.get(column);
            if (!expected.containsKey(column) || !actual.containsKey(column) || !matches(column, e, a, rules)) {
                differences.add(new ComparisonResult.Difference(key, column,
                        expected.containsKey(column) ? CanonicalJson.write(e) : "<absent>",
                        actual.containsKey(column) ? CanonicalJson.write(a) : "<absent>"));
            }
        }
    }

    private static boolean matches(String column, Object expected, Object actual, CompareRules rules) {
        if (Objects.equals(expected, actual)) {
            return true;
        }
        if (rules.timestampColumns().contains(column)) {
            Instant e = CanonicalJson.parseTimestamp(expected);
            Instant a = CanonicalJson.parseTimestamp(actual);
            return e != null && a != null && Duration.between(e, a).abs().compareTo(rules.timestampTolerance()) <= 0;
        }
        if (expected instanceof BigDecimal e && actual instanceof BigDecimal a) {
            BigDecimal tolerance = rules.numericColumns().contains(column) ? rules.numericTolerance() : BigDecimal.ZERO;
            return e.subtract(a).abs().compareTo(tolerance) <= 0;
        }
        return false;
    }
}
