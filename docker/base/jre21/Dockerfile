# docker/base/jre21/Dockerfile: the company base JRE image (D3 §5 (1), §6.1-§6.5; DL-13).
#
# Every app image starts FROM this image. It adds the enterprise CA bundle (demo: the public
# test-infra/ca/demo-root-ca.pem) to both trust stores, tzdata and curl, the non-root user app
# (10001:10001) and the /app + /config layout, so app Dockerfiles never repeat these steps.
#
# Build context = the directory holding the CA bundle (nothing else is copied):
#   docker buildx build -f docker/base/jre21/Dockerfile -t ghcr.io/crazymatthsu/base/jre21:<yyyymmdd>-<n> test-infra/ca
# Enterprise: TEMURIN_IMAGE through the JFrog remote (pinned by digest); the context is the directory
# the versioned bundle was downloaded into (D3 §6.3). Plain Dockerfile syntax, so
# `podman build --format docker` builds it too (D3 §6.7).

ARG TEMURIN_IMAGE=eclipse-temurin:21-jre
FROM ${TEMURIN_IMAGE}

ARG TEMURIN_IMAGE
ARG CA_BUNDLE_FILE=demo-root-ca.pem
ARG CA_BUNDLE_VERSION=demo-2026-09
ARG CA_ALIAS=demo-root-ca
ARG IMAGE_VERSION=""
ARG GIT_SHA=""
ARG CREATED=""

LABEL org.opencontainers.image.title="jre21" \
      org.opencontainers.image.description="Company base JRE 21: enterprise CA in the OS and JVM trust stores, tzdata, curl, non-root user app (10001)" \
      org.opencontainers.image.source="https://github.com/crazymatthsu/github-demo" \
      org.opencontainers.image.vendor="com.example" \
      org.opencontainers.image.base.name="${TEMURIN_IMAGE}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${CREATED}" \
      com.example.ca-bundle="${CA_BUNDLE_VERSION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# OS packages: tzdata and curl ship with the Temurin image today, but this image promises them (TZ below,
# the curl HEALTHCHECK of every app, D3 §6.4), so they are installed explicitly. No version pins: the
# weekly rebuild picks up patched packages (D3 §6.1), and pinned Ubuntu versions vanish from the archive.
# Then the runtime user and the directory layout of D3 §6.4: /app (application files, read-only),
# /app/logs (writable), /config (empty mount point for the D5 layers, read-only at runtime).
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /app --shell /usr/sbin/nologin app \
 && install -d -m 0755 /app /config \
 && install -d -m 0755 -o app -g app /app/logs

COPY ${CA_BUNDLE_FILE} /tmp/ca-bundle.pem

# Every certificate of the bundle goes into the OS store (update-ca-certificates: curl, git, apt) and
# into the JVM's default cacerts (every Java client: JDBC, Kafka, AMPS, Deephaven, Vault), D3 §6.2.
# During a rotation the bundle holds the old and the new root (D3 §6.3). The first certificate gets
# the alias CA_ALIAS, later ones CA_ALIAS-<n>. The bundle also stays at
# /etc/ssl/certs/company-ca-bundle.pem for tools that read a file.
# The verification at the end fails the build unless both stores hold the CA.
RUN install -d -m 0755 /usr/local/share/ca-certificates/company \
 && awk '/-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("/usr/local/share/ca-certificates/company/ca-%02d.crt", n) } out { print > out } /-----END CERTIFICATE-----/ { close(out); out = "" }' /tmp/ca-bundle.pem \
 && test -s /usr/local/share/ca-certificates/company/ca-01.crt \
 && update-ca-certificates \
 && for crt in /usr/local/share/ca-certificates/company/ca-*.crt; do \
      n="$(basename "${crt}" .crt)"; n="${n#ca-}"; \
      name="${CA_ALIAS}"; if [ "${n}" != "01" ]; then name="${CA_ALIAS}-${n}"; fi; \
      keytool -importcert -noprompt -trustcacerts -cacerts -storepass changeit -alias "${name}" -file "${crt}"; \
      openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "${crt}"; \
    done \
 && install -m 0644 /tmp/ca-bundle.pem /etc/ssl/certs/company-ca-bundle.pem \
 && rm /tmp/ca-bundle.pem \
 && keytool -list -cacerts -storepass changeit -alias "${CA_ALIAS}"

ENV TZ=UTC
WORKDIR /app
# The user app, numerically: Kubernetes runAsNonRoot can only verify a numeric user (D11), hadolint DL3066.
USER 10001:10001
