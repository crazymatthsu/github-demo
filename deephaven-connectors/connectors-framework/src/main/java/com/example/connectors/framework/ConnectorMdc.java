package com.example.connectors.framework;

import org.slf4j.MDC;

/**
 * The identity as MDC fields {@code env}, {@code flow}, {@code app}, {@code instance} (D6 §6.9). Structured
 * (JSON) log formats emit MDC entries as fields; {@link #wrap(ConnectorIdentity, Runnable)} carries them into
 * worker threads.
 */
public final class ConnectorMdc {

    private ConnectorMdc() {
    }

    public static void put(ConnectorIdentity identity) {
        identity.asTags().forEach(MDC::put);
    }

    public static void clear(ConnectorIdentity identity) {
        identity.asTags().keySet().forEach(MDC::remove);
    }

    /** A runnable that runs with the identity in its thread's MDC. */
    public static Runnable wrap(ConnectorIdentity identity, Runnable task) {
        return () -> {
            put(identity);
            try {
                task.run();
            }
            finally {
                clear(identity);
            }
        };
    }
}
