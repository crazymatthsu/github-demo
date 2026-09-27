package com.example.connectors.framework;

import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Decides which configuration values are printed as {@value #MASK} (D2 §6.4, D6 §4.3): every key under the
 * secret property names of D2 (usernames included, they rotate with their password) and every key with a
 * secret-looking segment ({@code password}, {@code secret}, {@code token}, {@code credential}, {@code *key}).
 * Credentials embedded in URLs are masked in the value itself.
 */
public final class SecretMasker {

    public static final String MASK = "******";

    /** D2 §6.4: the secret properties of the connectors, in normalised form. */
    private static final List<String> SECRET_PROPERTIES = List.of(
            "spring.datasource.username", "spring.datasource.password",
            "connector.amps.username", "connector.amps.password",
            "connector.kafka.sasl", "connector.deephaven.token",
            "connector.tls.keystore.password");

    private static final Pattern SECRET_SEGMENT = Pattern.compile(
            "^(.*(password|passwd|secret|token|credential).*|pwd|.*key)$");

    private static final Pattern URL_PASSWORD = Pattern.compile("(?i)((?:password|pwd)=)[^;&]*");
    private static final Pattern URL_USER_INFO = Pattern.compile("(://[^/@:]+:)[^/@]*@");

    private SecretMasker() {
    }

    /** True when the value of {@code key} (dotted, relaxed or environment-variable form) must not be shown. */
    public static boolean isSecret(String key) {
        String normalised = normalise(key);
        for (String property : SECRET_PROPERTIES) {
            String secret = normalise(property);
            if (normalised.equals(secret) || normalised.startsWith(secret + ".")) {
                return true;
            }
        }
        for (String segment : normalised.split("\\.")) {
            if (SECRET_SEGMENT.matcher(segment).matches()) {
                return true;
            }
        }
        return false;
    }

    /** The printable form of a configuration value. */
    public static String mask(String key, Object value) {
        if (value == null) {
            return "null";
        }
        if (isSecret(key)) {
            return MASK;
        }
        return maskUrlCredentials(String.valueOf(value));
    }

    /** {@code jdbc:...;password=x} and {@code scheme://user:pass@host} lose their credentials. */
    public static String maskUrlCredentials(String value) {
        String masked = URL_PASSWORD.matcher(value).replaceAll("$1" + MASK);
        return URL_USER_INFO.matcher(masked).replaceAll("$1" + MASK + "@");
    }

    /**
     * Lower case, {@code _} as the separator of environment-variable names, {@code -} and {@code [n]} dropped:
     * {@code SPRING_DATASOURCE_PASSWORD}, {@code spring.datasource.password} and
     * {@code spring.data-source.password} compare equal after {@link #isSecret}'s segment rules.
     */
    static String normalise(String key) {
        String k = key.toLowerCase(Locale.ROOT);
        if (!k.contains(".") && k.contains("_")) {
            k = k.replace('_', '.');
        }
        return k.replaceAll("\\[\\d+]", "").replace("-", "").replace("_", "");
    }
}
