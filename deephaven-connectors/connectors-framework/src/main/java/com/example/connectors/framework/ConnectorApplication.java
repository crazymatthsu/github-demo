package com.example.connectors.framework;

import java.util.Arrays;
import java.util.Map;

import org.springframework.boot.Banner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.WebApplicationType;
import org.springframework.context.ConfigurableApplicationContext;

/**
 * {@code main} of every connector app. Besides a normal start it supports {@value #PRINT_CONFIG}: resolve the
 * configuration exactly as a start would, print the masked summary on stdout and exit without serving or
 * connecting — what {@code run-compose.sh ... app-config --offline} runs (D6 §4.3).
 */
public final class ConnectorApplication {

    public static final String PRINT_CONFIG = "--print-config";

    /** Set while printing the configuration: components that would connect somewhere stay idle. */
    public static final String PRINT_CONFIG_PROPERTY = "connectors.framework.print-config";

    private ConnectorApplication() {
    }

    public static ConfigurableApplicationContext run(Class<?> primarySource, String... args) {
        if (Arrays.asList(args).contains(PRINT_CONFIG)) {
            System.exit(printConfig(primarySource, args));
        }
        return SpringApplication.run(primarySource, args);
    }

    /** Prints the summary on stdout and returns the exit code (0 when the configuration binds and validates). */
    public static int printConfig(Class<?> primarySource, String... args) {
        SpringApplication application = new SpringApplication(primarySource);
        application.setWebApplicationType(WebApplicationType.NONE);
        application.setBannerMode(Banner.Mode.OFF);
        application.setLogStartupInfo(false);
        application.setDefaultProperties(Map.of(PRINT_CONFIG_PROPERTY, "true"));
        // stdout carries the summary only: start-up INFO logging is silenced (command-line arguments win).
        String[] quiet = Arrays.copyOf(args, args.length + 1);
        quiet[args.length] = "--logging.level.root=WARN";
        try (ConfigurableApplicationContext context = application.run(quiet)) {
            ConnectorIdentity identity = context.getBean(ConnectorIdentity.class);
            System.out.println(ConfigurationSummary.capture(context.getEnvironment(), identity).render());
            return 0;
        }
    }
}
