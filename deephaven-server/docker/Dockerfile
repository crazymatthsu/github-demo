# deephaven-server image (D3 §6.10): the upstream Deephaven Community server, pinned by tag and digest, with
# the demo / enterprise CA imported into the OS store and into the server's own JVM cacerts, a /plugins
# placeholder and helper scripts under /opt/deephaven/bin/. Built by `./gradlew :deephaven-server:buildImage`
# from the staged context build/docker/ (docker/**, plus test-infra/ca/*.pem under docker/ca/).
# Keep the tag equal to the Deephaven Java client version in gradle/libs.versions.toml.
ARG DEEPHAVEN_BASE_IMAGE=ghcr.io/deephaven/server:42.5@sha256:bcdf0383631ac8df5446751b2a333a8f90627391900e183b95f84d4e22c65edb
FROM ${DEEPHAVEN_BASE_IMAGE}
ARG DEEPHAVEN_BASE_IMAGE
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILD_URL=local
ARG CREATED=unknown
LABEL org.opencontainers.image.title="deephaven-server" \
      org.opencontainers.image.description="Deephaven Community server with the enterprise CA (github-demo)" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.source="https://github.com/crazymatthsu/github-demo" \
      org.opencontainers.image.base.name="${DEEPHAVEN_BASE_IMAGE}" \
      com.example.app="deephaven-server" \
      com.example.git-sha="${GIT_SHA}" \
      com.example.build-url="${BUILD_URL}"

# The upstream image (Ubuntu 24.04, Temurin 21 at /opt/java/openjdk) runs as root; so does this overlay.
# TODO: run as a non-root user once /data and /cache ownership is settled with the Deephaven defaults.
# hadolint ignore=DL3002,DL3066
USER root
COPY --chmod=0755 docker/bin/ /opt/deephaven/bin/
COPY docker/plugins/ /plugins/
COPY docker/ca/ /tmp/ca/
# Every certificate of every *.pem (bundles are split) goes into /usr/local/share/ca-certificates (OS store)
# and into the JVM cacerts under the same alias (D3 §6.2); then both stores are verified.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eu; \
    count=0; \
    for pem in /tmp/ca/*.pem; do \
      [ -f "$pem" ] || continue; \
      name="$(basename "$pem" .pem)"; \
      awk -v out="/tmp/ca/split-${name}" '/-----BEGIN CERTIFICATE-----/ { n++ } n { print > (out "-" n ".crt") }' "$pem"; \
      for crt in /tmp/ca/split-"${name}"-*.crt; do \
        alias="$(basename "$crt" .crt | sed 's/^split-//')"; \
        cp "$crt" "/usr/local/share/ca-certificates/${alias}.crt"; \
        keytool -importcert -noprompt -cacerts -storepass changeit -alias "$alias" -file "$crt"; \
        count=$((count + 1)); \
      done; \
    done; \
    if [ "$count" -gt 0 ]; then \
      update-ca-certificates; \
      /opt/deephaven/bin/verify-trust.sh; \
    else \
      echo "docker/ca/ holds no *.pem: the image keeps the upstream trust stores"; \
    fi; \
    rm -rf /tmp/ca
EXPOSE 10000
# ENTRYPOINT (/opt/deephaven/server-jetty/bin/start) and the grpc_health_probe HEALTHCHECK on port 10000
# are inherited from the upstream image.
