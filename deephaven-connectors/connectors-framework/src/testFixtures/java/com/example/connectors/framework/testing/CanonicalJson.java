package com.example.connectors.framework.testing;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.json.JsonMapper;

/**
 * Canonical JSON for expected-output comparison (D8 §5.5, §6.6): keys sorted, UTF-8, no insignificant
 * whitespace, numbers as plain decimals without exponent or trailing zeros, timestamps as ISO-8601 UTC with
 * millisecond precision, {@code null} written explicitly.
 */
public final class CanonicalJson {

    private static final DateTimeFormatter UTC_MILLIS =
            DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC);

    private static final JsonMapper MAPPER = JsonMapper.builder()
            .enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
            .enable(DeserializationFeature.USE_BIG_INTEGER_FOR_INTS)
            .build();

    private CanonicalJson() {
    }

    /** Reads a JSON Lines file (one object per line, blank lines ignored) as rows. */
    public static List<Map<String, Object>> readJsonLines(Path file) {
        try {
            List<Map<String, Object>> rows = new ArrayList<>();
            for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
                if (!line.isBlank()) {
                    rows.add(parseObject(line));
                }
            }
            return rows;
        }
        catch (IOException ex) {
            throw new UncheckedIOException(ex);
        }
    }

    /** Parses one JSON object; decimals stay {@link BigDecimal}, integers {@link BigInteger}. */
    public static Map<String, Object> parseObject(String json) {
        return MAPPER.readValue(json, new TypeReference<Map<String, Object>>() { });
    }

    /** The canonical text of any value: object, array, number, string, boolean, temporal or null. */
    public static String write(Object value) {
        StringBuilder out = new StringBuilder();
        append(out, normalise(value));
        return out.toString();
    }

    /**
     * The canonical Java form of a value: maps become sorted {@link TreeMap}s, numbers {@link BigDecimal}s
     * without trailing zeros, temporals UTC-millisecond strings; other scalars are kept.
     */
    public static Object normalise(Object value) {
        if (value == null || value instanceof String || value instanceof Boolean) {
            return value;
        }
        if (value instanceof Number number) {
            return decimal(number);
        }
        Instant instant = toInstant(value);
        if (instant != null) {
            return timestamp(instant);
        }
        if (value instanceof Map<?, ?> map) {
            Map<String, Object> sorted = new TreeMap<>();
            map.forEach((k, v) -> sorted.put(String.valueOf(k), normalise(v)));
            return sorted;
        }
        if (value instanceof Collection<?> collection) {
            List<Object> list = new ArrayList<>();
            collection.forEach(v -> list.add(normalise(v)));
            return list;
        }
        if (value.getClass().isArray() && value instanceof Object[] array) {
            return normalise(List.of(array));
        }
        return value.toString();
    }

    /** A plain decimal: {@code 1.50} and {@code 1.5E0} both become {@code 1.5}; {@code -0.0} becomes {@code 0}. */
    public static BigDecimal decimal(Number number) {
        BigDecimal decimal = switch (number) {
            case BigDecimal d -> d;
            case BigInteger i -> new BigDecimal(i);
            case Double d -> new BigDecimal(Double.toString(d));
            case Float f -> new BigDecimal(Float.toString(f));
            default -> new BigDecimal(number.toString());
        };
        return decimal.signum() == 0 ? BigDecimal.ZERO : decimal.stripTrailingZeros();
    }

    /** ISO-8601 UTC with exactly three fractional digits. */
    public static String timestamp(Instant instant) {
        return UTC_MILLIS.format(instant.truncatedTo(ChronoUnit.MILLIS));
    }

    /** Parses a timestamp written by a connector or a golden file; {@code null} when it is not one. */
    public static Instant parseTimestamp(Object value) {
        Instant instant = toInstant(value);
        if (instant != null || !(value instanceof String text)) {
            return instant;
        }
        try {
            return OffsetDateTime.parse(text).toInstant();
        }
        catch (DateTimeParseException notOffset) {
            try {
                return LocalDateTime.parse(text).toInstant(ZoneOffset.UTC);
            }
            catch (DateTimeParseException notLocal) {
                return null;
            }
        }
    }

    private static Instant toInstant(Object value) {
        return switch (value) {
            case Instant i -> i;
            case OffsetDateTime o -> o.toInstant();
            case ZonedDateTime z -> z.toInstant();
            case LocalDateTime l -> l.toInstant(ZoneOffset.UTC);
            case Date d -> d.toInstant();
            case null, default -> null;
        };
    }

    private static void append(StringBuilder out, Object value) {
        switch (value) {
            case null -> out.append("null");
            case BigDecimal d -> out.append(d.toPlainString());
            case Boolean b -> out.append(b);
            case String s -> appendString(out, s);
            case Map<?, ?> map -> {
                out.append('{');
                boolean first = true;
                for (Map.Entry<?, ?> entry : map.entrySet()) {
                    if (!first) {
                        out.append(',');
                    }
                    first = false;
                    appendString(out, String.valueOf(entry.getKey()));
                    out.append(':');
                    append(out, entry.getValue());
                }
                out.append('}');
            }
            case List<?> list -> {
                out.append('[');
                for (int i = 0; i < list.size(); i++) {
                    if (i > 0) {
                        out.append(',');
                    }
                    append(out, list.get(i));
                }
                out.append(']');
            }
            default -> appendString(out, value.toString());
        }
    }

    private static void appendString(StringBuilder out, String text) {
        out.append('"');
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                case '\b' -> out.append("\\b");
                case '\f' -> out.append("\\f");
                default -> {
                    if (c < 0x20) {
                        out.append(String.format("\\u%04x", (int) c));
                    }
                    else {
                        out.append(c);
                    }
                }
            }
        }
        out.append('"');
    }
}
