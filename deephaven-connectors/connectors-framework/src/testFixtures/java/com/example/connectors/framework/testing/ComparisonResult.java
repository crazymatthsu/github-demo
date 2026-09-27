package com.example.connectors.framework.testing;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Outcome of {@link RowSetComparator#compare}: missing rows, unexpected rows, per-column differences and
 * duplicate keys (D8 §6.6). {@link #toJson()} is the {@code <case>-diff.json} report.
 */
public record ComparisonResult(
        int expectedRows,
        int actualRows,
        List<String> missing,
        List<String> unexpected,
        List<Difference> differences,
        List<String> duplicates) {

    /** One column of one matched row that differs. */
    public record Difference(String key, String column, String expected, String actual) {
    }

    public ComparisonResult {
        missing = List.copyOf(missing);
        unexpected = List.copyOf(unexpected);
        differences = List.copyOf(differences);
        duplicates = List.copyOf(duplicates);
    }

    public boolean matches() {
        return missing.isEmpty() && unexpected.isEmpty() && differences.isEmpty() && duplicates.isEmpty();
    }

    /** A human summary with at most {@code limit} items per category (the JUnit failure message). */
    public String summary(int limit) {
        if (matches()) {
            return "rows match (" + actualRows + " rows)";
        }
        StringBuilder text = new StringBuilder("rows differ: expected ").append(expectedRows)
                .append(", actual ").append(actualRows);
        section(text, "missing", missing, limit);
        section(text, "unexpected", unexpected, limit);
        section(text, "duplicate keys", duplicates, limit);
        section(text, "differences", differences.stream()
                .map(d -> d.key() + " ." + d.column() + ": expected " + d.expected() + ", actual " + d.actual())
                .toList(), limit);
        return text.toString();
    }

    public String toJson() {
        Map<String, Object> report = new LinkedHashMap<>();
        report.put("matches", matches());
        report.put("expectedRows", expectedRows);
        report.put("actualRows", actualRows);
        report.put("missing", missing);
        report.put("unexpected", unexpected);
        report.put("duplicates", duplicates);
        report.put("differences", differences.stream().map(d -> Map.of(
                "key", d.key(), "column", d.column(), "expected", d.expected(), "actual", d.actual())).toList());
        return CanonicalJson.write(report);
    }

    private static void section(StringBuilder text, String title, List<String> items, int limit) {
        if (items.isEmpty()) {
            return;
        }
        text.append("\n  ").append(title).append(" (").append(items.size()).append("):");
        items.stream().limit(limit).forEach(item -> text.append("\n    ").append(item));
        if (items.size() > limit) {
            text.append("\n    ...");
        }
    }
}
