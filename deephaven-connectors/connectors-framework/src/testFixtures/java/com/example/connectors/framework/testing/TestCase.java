package com.example.connectors.framework.testing;

import java.io.IOException;
import java.io.Reader;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

import org.yaml.snakeyaml.LoaderOptions;
import org.yaml.snakeyaml.Yaml;
import org.yaml.snakeyaml.constructor.SafeConstructor;

/**
 * One case of the test-data tree, {@code <dataset root>/<connector>/<case>/{manifest.yml, input/, expected/}}
 * (D8 §5.4, §6.5). {@link #load} reads the manifest and resolves the files it names against the case directory;
 * {@link #assertMatches} compares a connector's output with the expected rows under the manifest's rules and
 * writes the report D8 §6.6 asks for.
 *
 * @param directory the case directory
 * @param name {@code case}
 * @param connector {@code connector}, the AppName
 * @param instance {@code instance}, the AppInstance whose config (under the {@code local} env) the case runs with
 * @param datasetVersion {@code datasetVersion}
 * @param inputDatabase {@code input.database}, where the input files run
 * @param schema {@code input.schema}
 * @param seeds {@code input.seed}, in order
 * @param target {@code expected.target}: deephaven, amps or stub
 * @param table {@code expected.table}, without the run prefix
 * @param expectedFile {@code expected.file}, canonical JSON lines
 * @param rules the {@code compare} block
 * @param timeout {@code compare.timeout}: how long to poll for the expected rows
 */
public record TestCase(
        Path directory,
        String name,
        String connector,
        String instance,
        String datasetVersion,
        String inputDatabase,
        Path schema,
        List<Path> seeds,
        String target,
        String table,
        Path expectedFile,
        CompareRules rules,
        Duration timeout) {

    /** Points at another dataset root, e.g. one unpacked by fetchTestData into build/testdata (D8 §5.4). */
    public static final String TESTDATA_DIR_VARIABLE = "IT_TESTDATA_DIR";

    /** The poll budget when the manifest sets no {@code compare.timeout} (D8 §6.7). */
    public static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(60);

    /** Where the reports go, relative to the test JVM's working directory (the subproject under Gradle). */
    public static final Path REPORTS_DIR = Path.of("build", "reports", "integrationTest");

    /** At most this many differences per category in the assertion message (D8 §6.6). */
    private static final int MESSAGE_LIMIT = 10;

    public TestCase {
        seeds = List.copyOf(seeds);
    }

    /** {@code $IT_TESTDATA_DIR}, else {@code test-infra/testdata} of this repository. */
    public static Path testDataRoot() {
        return ItEnvironment.optional(TESTDATA_DIR_VARIABLE).map(Path::of)
                .orElseGet(() -> ItEnvironment.repositoryRoot().resolve("test-infra").resolve("testdata"));
    }

    public static TestCase load(String connector, String caseName) {
        return load(testDataRoot().resolve(connector).resolve(caseName));
    }

    public static TestCase load(Path directory) {
        Path manifestFile = directory.resolve("manifest.yml");
        Manifest manifest = new Manifest(manifestFile, readYaml(manifestFile));
        Map<String, Object> input = manifest.map("input");
        Map<String, Object> expected = manifest.map("expected");
        Map<String, Object> compare = manifest.map("compare");
        List<Path> seeds = new ArrayList<>();
        for (Object seed : manifest.list(input, "input.seed")) {
            seeds.add(manifest.file(directory, "input.seed", seed));
        }
        return new TestCase(
                directory,
                manifest.text(manifest.root(), "case"),
                manifest.text(manifest.root(), "connector"),
                manifest.text(manifest.root(), "instance"),
                manifest.text(manifest.root(), "datasetVersion"),
                manifest.text(input, "input.database"),
                manifest.file(directory, "input.schema", input.get("schema")),
                seeds,
                manifest.text(expected, "expected.target"),
                manifest.text(expected, "expected.table"),
                manifest.file(directory, "expected.file", expected.get("file")),
                CompareRules.fromManifest(compare),
                manifest.duration(compare, "compare.timeout", DEFAULT_TIMEOUT));
    }

    /** The golden rows, as parsed from {@link #expectedFile()}. */
    public List<Map<String, Object>> expectedRows() {
        return CanonicalJson.readJsonLines(expectedFile);
    }

    public ComparisonResult compare(List<? extends Map<String, ?>> actual) {
        return RowSetComparator.compare(expectedRows(), actual, rules);
    }

    /**
     * Compares {@code actual} with the expected rows and writes
     * {@code build/reports/integrationTest/<report>-diff.json} plus {@code <report>-actual.jsonl} (the actual rows in
     * canonical form, ignored columns dropped, ordered by key: what the expected file would hold). {@code <report>} is
     * the case name, suffixed with {@code stage} when one is given. Throws an {@link AssertionError} with the first
     * ten differences on a mismatch.
     *
     * @param stage report-name suffix for a check other than the case's final one (e.g. {@code source}); may be null
     * @param description what {@code actual} is, for the message (e.g. {@code Deephaven table it_abc_positions})
     * @param actual the rows to check
     * @return the (matching) comparison result
     */
    public ComparisonResult assertMatches(String stage, String description, List<? extends Map<String, ?>> actual) {
        ComparisonResult result = compare(actual);
        String report = (stage == null || stage.isBlank()) ? name : name + "-" + stage;
        Path diff = REPORTS_DIR.resolve(report + "-diff.json");
        try {
            Files.createDirectories(REPORTS_DIR);
            Files.writeString(diff, result.toJson() + "\n", StandardCharsets.UTF_8);
            Files.write(REPORTS_DIR.resolve(report + "-actual.jsonl"), canonicalLines(actual), StandardCharsets.UTF_8);
        }
        catch (IOException ex) {
            throw new UncheckedIOException("cannot write the comparison report " + diff.toAbsolutePath(), ex);
        }
        if (!result.matches()) {
            throw new AssertionError(description + " does not match " + expectedFile + " (case " + name + "): "
                    + result.summary(MESSAGE_LIMIT) + "\n  report: " + diff.toAbsolutePath());
        }
        return result;
    }

    /** The rows as canonical JSON lines without the ignored columns, ordered by key columns, then by text. */
    public List<String> canonicalLines(List<? extends Map<String, ?>> rows) {
        record Line(String key, String text) {
        }
        List<Line> lines = new ArrayList<>();
        for (Map<String, ?> row : rows) {
            Map<String, Object> kept = new TreeMap<>();
            row.forEach((column, value) -> {
                if (!rules.ignoreColumns().contains(column)) {
                    kept.put(column, value);
                }
            });
            List<Object> key = rules.keyColumns().stream().map(kept::get).toList();
            lines.add(new Line(CanonicalJson.write(key), CanonicalJson.write(kept)));
        }
        lines.sort(Comparator.comparing(Line::key).thenComparing(Line::text));
        return lines.stream().map(Line::text).toList();
    }

    private static Map<String, Object> readYaml(Path file) {
        if (!Files.isRegularFile(file)) {
            throw new IllegalStateException("test case manifest not found: " + file.toAbsolutePath());
        }
        try (Reader reader = Files.newBufferedReader(file, StandardCharsets.UTF_8)) {
            Object document = new Yaml(new SafeConstructor(new LoaderOptions())).load(reader);
            if (!(document instanceof Map<?, ?> map)) {
                throw new IllegalStateException(file + ": the manifest must be a YAML mapping");
            }
            Map<String, Object> result = new TreeMap<>();
            map.forEach((k, v) -> result.put(String.valueOf(k), v));
            return result;
        }
        catch (IOException ex) {
            throw new UncheckedIOException(ex);
        }
    }

    /**
     * Typed access to the manifest with messages that name the file and the key. Keys are dotted paths
     * ({@code input.database}); the value is looked up by the last segment in the given parent mapping.
     */
    private record Manifest(Path file, Map<String, Object> root) {

        private static Object get(Map<String, ?> parent, String key) {
            return parent.get(key.substring(key.lastIndexOf('.') + 1));
        }

        @SuppressWarnings("unchecked")
        Map<String, Object> map(String key) {
            Object value = root.get(key);
            if (!(value instanceof Map<?, ?>)) {
                throw invalid(key, "a mapping");
            }
            return (Map<String, Object>) value;
        }

        List<?> list(Map<String, ?> parent, String key) {
            Object value = get(parent, key);
            if (value == null) {
                return List.of();
            }
            return value instanceof List<?> items ? items : List.of(value);
        }

        String text(Map<String, ?> parent, String key) {
            Object value = get(parent, key);
            if (value == null || String.valueOf(value).isBlank()) {
                throw invalid(key, "a value");
            }
            return String.valueOf(value);
        }

        Path file(Path directory, String key, Object value) {
            if (value == null || String.valueOf(value).isBlank()) {
                throw invalid(key, "a file path relative to the case directory");
            }
            Path path = directory.resolve(String.valueOf(value)).normalize();
            if (!path.startsWith(directory.normalize()) || !Files.isRegularFile(path)) {
                throw invalid(key, "an existing file inside the case directory (" + path + ")");
            }
            return path;
        }

        Duration duration(Map<String, ?> parent, String key, Duration fallback) {
            Object value = get(parent, key);
            if (value == null) {
                return fallback;
            }
            try {
                return Duration.parse(String.valueOf(value));
            }
            catch (DateTimeParseException ex) {
                throw invalid(key, "an ISO-8601 duration such as PT60S");
            }
        }

        private IllegalStateException invalid(String key, String what) {
            return new IllegalStateException(file + ": '" + key + "' must be " + what);
        }
    }
}
