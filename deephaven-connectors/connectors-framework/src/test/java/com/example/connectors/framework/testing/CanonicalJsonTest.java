package com.example.connectors.framework.testing;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.assertj.core.api.Assertions.assertThat;

class CanonicalJsonTest {

    @Test
    void sortsKeysAndDropsInsignificantWhitespace() {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("qty", 10);
        row.put("account", "A-1");
        row.put("nested", Map.of("z", 1, "a", true));
        row.put("note", null);

        assertThat(CanonicalJson.write(row))
                .isEqualTo("{\"account\":\"A-1\",\"nested\":{\"a\":true,\"z\":1},\"note\":null,\"qty\":10}");
    }

    @Test
    void writesNumbersAsPlainDecimalsWithoutTrailingZeros() {
        assertThat(CanonicalJson.write(Arrays.asList(new BigDecimal("1.50"), 1.5e3, new BigDecimal("1E+2"), -0.0, 7L)))
                .isEqualTo("[1.5,1500,100,0,7]");
    }

    @Test
    void writesTimestampsAsUtcWithMilliseconds() {
        assertThat(CanonicalJson.write(Instant.parse("2026-09-26T10:15:00Z"))).isEqualTo("\"2026-09-26T10:15:00.000Z\"");
        assertThat(CanonicalJson.write(OffsetDateTime.parse("2026-09-26T12:15:00.123456+02:00")))
                .isEqualTo("\"2026-09-26T10:15:00.123Z\"");
        assertThat(CanonicalJson.write(LocalDateTime.parse("2026-09-26T10:15:00"))).isEqualTo("\"2026-09-26T10:15:00.000Z\"");
    }

    @Test
    void escapesStrings() {
        assertThat(CanonicalJson.write("a\"b\\c\nd\u0001")).isEqualTo("\"a\\\"b\\\\c\\nd\\u0001\"");
    }

    @Test
    void readsJsonLinesKeepingDecimalsExact(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("positions.jsonl");
        Files.writeString(file, "{\"account\":\"A-1\",\"qty\":10.10}\n\n{\"account\":\"A-2\",\"qty\":3}\n");

        List<Map<String, Object>> rows = CanonicalJson.readJsonLines(file);

        assertThat(rows).hasSize(2);
        assertThat(CanonicalJson.write(rows.get(0))).isEqualTo("{\"account\":\"A-1\",\"qty\":10.1}");
    }
}
