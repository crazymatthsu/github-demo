package com.example.connectors.framework;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.boot.actuate.info.Info;
import org.springframework.boot.actuate.info.InfoContributor;

/** Adds the identity to {@code /actuator/info} next to Boot's build (version, git sha) section. */
public class ConnectorInfoContributor implements InfoContributor {

    private final ConnectorIdentity identity;

    public ConnectorInfoContributor(ConnectorIdentity identity) {
        this.identity = identity;
    }

    @Override
    public void contribute(Info.Builder builder) {
        Map<String, Object> connector = new LinkedHashMap<>(identity.asTags());
        connector.put("tuple", identity.tuple());
        connector.put("complete", identity.isComplete());
        builder.withDetail("connector", connector);
    }
}
