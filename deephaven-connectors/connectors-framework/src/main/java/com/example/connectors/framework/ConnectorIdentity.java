package com.example.connectors.framework;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

import org.springframework.core.env.PropertyResolver;

/**
 * The identity tuple {@code <env>/<flow>/<AppName>/<AppInstance>} of one running pipeline (D5 §6.2, DL-37).
 *
 * <p>The deployer sets it through the environment variables {@code APP_ENV}, {@code APP_FLOW},
 * {@code APP_NAME} and {@code APP_INSTANCE} (compose.env / Helm values); it must equal the config-tree path
 * the instance was started from. Without them (a laptop, a unit test) the identity is
 * {@code local/none/<spring.application.name>/none}, which {@link #isComplete()} reports as incomplete.
 */
public record ConnectorIdentity(String env, String flow, String app, String instance) {

    public static final String ENV_VARIABLE = "APP_ENV";
    public static final String FLOW_VARIABLE = "APP_FLOW";
    public static final String NAME_VARIABLE = "APP_NAME";
    public static final String INSTANCE_VARIABLE = "APP_INSTANCE";

    /** Marker for a flow or instance that was not set (only accepted in the {@code local} env). */
    public static final String UNSET = "none";

    static final Pattern ENV = Pattern.compile("^(local|[a-z]{2}-(dev|qa|prod))$");
    static final Pattern TOKEN = Pattern.compile("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$");
    static final Set<String> FLOWS = Set.of("cash", "deriv", "swap");
    static final int MAX_APP_NAME = 20;
    static final int MAX_APP_INSTANCE = 32;

    public ConnectorIdentity {
        require(env != null && ENV.matcher(env).matches(),
                ENV_VARIABLE + "='" + env + "' must be local or <region>-<stage> (e.g. us-dev)");
        boolean local = "local".equals(env);
        require(flow != null && (FLOWS.contains(flow) || (local && UNSET.equals(flow))),
                FLOW_VARIABLE + "='" + flow + "' must be one of " + FLOWS);
        require(app != null && TOKEN.matcher(app).matches() && app.length() <= MAX_APP_NAME,
                NAME_VARIABLE + "='" + app + "' must be lower-case kebab-case, at most " + MAX_APP_NAME + " characters");
        require(instance != null && TOKEN.matcher(instance).matches() && instance.length() <= MAX_APP_INSTANCE
                        && !instance.chars().allMatch(Character::isDigit)
                        && (local || !UNSET.equals(instance)),
                INSTANCE_VARIABLE + "='" + instance + "' must be a lower-case kebab-case business name (never a bare"
                        + " number), at most " + MAX_APP_INSTANCE + " characters");
    }

    /**
     * Reads the identity from the environment. {@code APP_NAME}, when set, must equal
     * {@code spring.application.name}: an image started with another app's compose.env fails fast.
     */
    public static ConnectorIdentity from(PropertyResolver environment) {
        String applicationName = blankToNull(environment.getProperty("spring.application.name"));
        String appName = blankToNull(environment.getProperty(NAME_VARIABLE));
        if (appName != null && applicationName != null && !appName.equals(applicationName)) {
            throw new IllegalStateException(NAME_VARIABLE + "=" + appName + " but this is the " + applicationName
                    + " image: the compose.env or Helm values of another app were used");
        }
        String app = appName != null ? appName : (applicationName != null ? applicationName : "unknown");
        return new ConnectorIdentity(
                valueOr(environment, ENV_VARIABLE, "local"),
                valueOr(environment, FLOW_VARIABLE, UNSET),
                app,
                valueOr(environment, INSTANCE_VARIABLE, UNSET));
    }

    /** True when flow and instance were set by a deployer (never the {@code none} markers). */
    public boolean isComplete() {
        return !UNSET.equals(flow) && !UNSET.equals(instance);
    }

    /** {@code us-dev/cash/source-database/trades-db-to-amps}. */
    public String tuple() {
        return env + "/" + flow + "/" + app + "/" + instance;
    }

    /** The compose project name {@code <env>-<flow>-<app>-<instance>} (D6 §6.2). */
    public String composeProject() {
        return env + "-" + flow + "-" + app + "-" + instance;
    }

    /** The Helm release / Deployment name {@code <app>-<instance>} (D11). */
    public String releaseName() {
        return app + "-" + instance;
    }

    /** The Deephaven table-name prefix {@code <flow>_<instance>_} with dashes as underscores (D5 §6.2). */
    public String tablePrefix() {
        return (flow + "_" + instance + "_").replace('-', '_');
    }

    /** {@code env, flow, app, instance}: metric tags, MDC fields, log fields and labels (D6 §6.9). */
    public Map<String, String> asTags() {
        Map<String, String> tags = new LinkedHashMap<>();
        tags.put("env", env);
        tags.put("flow", flow);
        tags.put("app", app);
        tags.put("instance", instance);
        return tags;
    }

    @Override
    public String toString() {
        return tuple();
    }

    private static String valueOr(PropertyResolver environment, String name, String fallback) {
        String value = blankToNull(environment.getProperty(name));
        return value != null ? value : fallback;
    }

    private static String blankToNull(String value) {
        return (value == null || value.isBlank()) ? null : value.trim();
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new IllegalArgumentException("Invalid connector identity: " + message);
        }
    }
}
