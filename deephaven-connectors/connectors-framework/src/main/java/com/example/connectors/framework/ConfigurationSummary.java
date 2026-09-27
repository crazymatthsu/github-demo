package com.example.connectors.framework;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.SortedMap;
import java.util.TreeMap;

import org.springframework.boot.context.properties.bind.Bindable;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.context.properties.source.ConfigurationPropertyName;
import org.springframework.boot.context.properties.source.ConfigurationPropertySource;
import org.springframework.boot.context.properties.source.ConfigurationPropertySources;
import org.springframework.boot.context.properties.source.IterableConfigurationPropertySource;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.PropertySource;

/**
 * The effective configuration of a connector as every app prints it at start-up, as
 * {@code --print-config} prints it and as {@code /actuator/connectorconfig} returns it (D6 §4.3): the
 * identity, the configuration layers that were found, and every property under {@link #PREFIXES} with its
 * effective value — secrets masked by {@link SecretMasker}.
 */
public record ConfigurationSummary(ConnectorIdentity identity, List<String> layers, SortedMap<String, String> properties) {

    /** The prefixes shown: the connector contract and the datasource (to prove its credentials are masked). */
    public static final List<String> PREFIXES = List.of("connector", "spring.datasource");

    public ConfigurationSummary {
        layers = List.copyOf(layers);
        properties = Collections.unmodifiableSortedMap(new TreeMap<>(properties));
    }

    public static ConfigurationSummary capture(ConfigurableEnvironment environment, ConnectorIdentity identity) {
        Binder binder = Binder.get(environment);
        SortedMap<String, String> properties = new TreeMap<>();
        for (ConfigurationPropertySource source : ConfigurationPropertySources.get(environment)) {
            if (!(source instanceof IterableConfigurationPropertySource iterable)) {
                continue;
            }
            iterable.stream().filter(ConfigurationSummary::isShown).forEach(name -> properties.computeIfAbsent(
                    name.toString(), key -> SecretMasker.mask(key, effectiveValue(binder, name))));
        }
        return new ConfigurationSummary(identity, configLayers(environment), properties);
    }

    private static boolean isShown(ConfigurationPropertyName name) {
        for (String prefix : PREFIXES) {
            ConfigurationPropertyName root = ConfigurationPropertyName.of(prefix);
            if (root.isAncestorOf(name)) {
                return true;
            }
        }
        return false;
    }

    private static String effectiveValue(Binder binder, ConfigurationPropertyName name) {
        try {
            return binder.bind(name, Bindable.of(String.class)).orElse(null);
        }
        catch (RuntimeException ex) {
            return "<unresolvable: " + ex.getClass().getSimpleName() + ">";
        }
    }

    /**
     * The config-tree layers and secret trees that contributed, lowest precedence first (D5 §6.1). Property
     * source names carry the resource location, never a value.
     */
    private static List<String> configLayers(ConfigurableEnvironment environment) {
        List<String> layers = new ArrayList<>();
        for (PropertySource<?> source : environment.getPropertySources()) {
            String name = source.getName();
            String lower = name.toLowerCase(java.util.Locale.ROOT);
            boolean fileLayer = lower.startsWith("config resource 'file [");
            boolean secretTree = lower.contains("config tree") || lower.contains("configtree");
            if (fileLayer) {
                // Config resource 'file [/config/instance/application.yml]' via location '...'
                layers.add(between(name, '[', ']'));
            }
            else if (secretTree) {
                // Config tree '/secrets'
                String path = between(name, '\'', '\'');
                layers.add(path.endsWith("/") ? path : path + "/");
            }
        }
        Collections.reverse(layers);
        return layers;
    }

    private static String between(String text, char open, char close) {
        int start = text.indexOf(open);
        int end = text.indexOf(close, start + 1);
        return (start >= 0 && end > start) ? text.substring(start + 1, end) : text;
    }

    /** The structured form (actuator endpoint, tests). */
    public Map<String, Object> asMap() {
        Map<String, Object> map = new LinkedHashMap<>();
        map.put("identity", identity.tuple());
        map.put("complete", identity.isComplete());
        map.put("layers", layers);
        map.put("properties", properties);
        return map;
    }

    /** The text form, one property per line (start-up log, {@code --print-config}). */
    public String render() {
        StringBuilder text = new StringBuilder();
        text.append("Connector ").append(identity.tuple())
                .append(" (env=").append(identity.env()).append(" flow=").append(identity.flow())
                .append(" app=").append(identity.app()).append(" instance=").append(identity.instance()).append(')');
        if (!identity.isComplete()) {
            text.append("\n  identity incomplete: APP_FLOW / APP_INSTANCE not set (fine on a laptop, never deployed)");
        }
        text.append("\n  config layers (lowest precedence first): ")
                .append(layers.isEmpty() ? "none (jar defaults only)" : String.join(", ", layers));
        text.append("\n  effective configuration (secrets masked):");
        if (properties.isEmpty()) {
            text.append("\n    (no connector.* properties)");
        }
        properties.forEach((key, value) -> text.append("\n    ").append(key).append(" = ").append(value));
        return text.toString();
    }
}
