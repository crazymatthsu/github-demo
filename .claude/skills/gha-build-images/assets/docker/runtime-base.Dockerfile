# runtime-base.Dockerfile: the company runtime base image (gha-build-images skill).
#
# Every app image starts FROM this image. It adds what every app needs and no app Dockerfile should
# repeat: the enterprise CA in the OS trust store and, for a JVM runtime, in the JVM's default cacerts;
# tzdata and curl (for HEALTHCHECK); the non-root user app (10001:10001); and the layout /app
# (application files, read-only), /app/logs (writable) and /config (empty mount point for configuration,
# read-only at runtime). One place to patch, scan and rotate the CA; app Dockerfiles stay short.
#
# Placeholders (grep -n '__[A-Z0-9_]*__'):
#   __CA_ALIAS__           cacerts alias of the first bundle certificate (then -02, -03, ...)   acme-root-ca
#   __CA_BUNDLE_VERSION__  version of the CA bundle, written to the com.example.ca-bundle label  2026-09
#   __VENDOR__             value of the OCI vendor label                                          Acme Corp
# Also replace the label namespace `com.example` with your reverse-DNS prefix (same as ci-build).
#
# Build context = the directory holding the CA bundle; nothing else is copied:
#   docker buildx build -f docker/base/runtime-base.Dockerfile -t <prefix>/runtime-base:dev --load docker/ca
#   podman build --format docker -f docker/base/runtime-base.Dockerfile -t <prefix>/runtime-base:dev docker/ca
# Other runtimes (Debian or Ubuntu images: the RUN steps use apt), for example
#   --build-arg RUNTIME_IMAGE=docker.io/library/node:22-slim   (or python:3.13-slim, a company OS image).
# Distroless and UBI images need another recipe (references/enterprise-ca.md). UID 10001, not the runner's
# 1001: a high UID that no host account uses; Kubernetes runAsNonRoot checks the numeric USER.

ARG RUNTIME_IMAGE=docker.io/library/eclipse-temurin:21-jre
FROM ${RUNTIME_IMAGE}

ARG RUNTIME_IMAGE
# The CA bundle (references/enterprise-ca.md). CA_BUNDLE_SHA256, when set, must match the file.
ARG CA_BUNDLE_FILE=ca-bundle.pem
ARG CA_BUNDLE_SHA256=""
ARG CA_BUNDLE_VERSION=__CA_BUNDLE_VERSION__
ARG CA_ALIAS=__CA_ALIAS__
ARG APP_UID=10001
ARG APP_GID=10001
# OCI labels, set by base-image.yml.
ARG IMAGE_VERSION=""
ARG GIT_SHA=""
ARG CREATED=""
ARG SOURCE_URL=""

LABEL org.opencontainers.image.title="runtime-base" \
      org.opencontainers.image.description="Company runtime base: enterprise CA in the OS and JVM trust stores, tzdata, curl, non-root user app (10001)" \
      org.opencontainers.image.vendor="__VENDOR__" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${RUNTIME_IMAGE}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${CREATED}" \
      com.example.ca-bundle="${CA_BUNDLE_VERSION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# OS packages, deliberately unpinned (DL3008): the weekly rebuild exists to pick up security fixes, and
# pinned Debian/Ubuntu versions vanish from the archive. The image promises curl and tzdata (HEALTHCHECK,
# TZ), so they are installed even where the upstream image happens to ship them today. Then the runtime
# user and the directory layout.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssl tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && if ! getent group "${APP_GID}" >/dev/null; then groupadd --gid "${APP_GID}" app; fi \
 && if ! getent passwd "${APP_UID}" >/dev/null; then useradd --uid "${APP_UID}" --gid "${APP_GID}" --no-create-home --home-dir /app --shell /usr/sbin/nologin app; fi \
 && install -d -m 0755 /app /config \
 && install -d -m 0755 -o "${APP_UID}" -g "${APP_GID}" /app/logs

COPY ${CA_BUNDLE_FILE} /tmp/ca-bundle.pem

# The enterprise CA, identical in ci-build.Dockerfile (references/enterprise-ca.md): refuse a bundle that
# holds a private key or does not match CA_BUNDLE_SHA256; split it into one file per certificate; OS
# store (curl, git, apt, OpenSSL-based clients) and, for a JVM runtime, the default cacerts (every Java
# client: JDBC, Kafka, HTTP). During a rotation the bundle holds the old and the new root, and both are
# imported. A JVM without keytool (a jlink runtime) fails the build instead of silently missing the CA.
# `|| exit 1` inside the loop: bash ignores -e in a loop that is part of an && chain. The bundle also
# stays at /etc/ssl/certs/company-ca-bundle.pem for tools that read a file.
RUN if grep -q 'PRIVATE KEY' /tmp/ca-bundle.pem; then echo "${CA_BUNDLE_FILE} contains a private key: refusing to build" >&2; exit 1; fi \
 && if [ -n "${CA_BUNDLE_SHA256}" ]; then echo "${CA_BUNDLE_SHA256}  /tmp/ca-bundle.pem" | sha256sum -c -; fi \
 && install -d -m 0755 /usr/local/share/ca-certificates/company \
 && awk '/-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("/usr/local/share/ca-certificates/company/ca-%02d.crt", n) } out { print > out } /-----END CERTIFICATE-----/ { close(out); out = "" }' /tmp/ca-bundle.pem \
 && test -s /usr/local/share/ca-certificates/company/ca-01.crt \
 && update-ca-certificates \
 && jvm=false \
 && if command -v keytool >/dev/null 2>&1; then jvm=true; elif command -v java >/dev/null 2>&1; then echo "java without keytool: cannot add the CA to the JVM trust store" >&2; exit 1; fi \
 && for crt in /usr/local/share/ca-certificates/company/ca-*.crt; do \
      openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "${crt}" || exit 1; \
      if [ "${jvm}" = true ]; then \
        n="$(basename "${crt}" .crt)"; n="${n#ca-}"; \
        name="${CA_ALIAS}"; if [ "${n}" != "01" ]; then name="${CA_ALIAS}-${n}"; fi; \
        keytool -importcert -noprompt -trustcacerts -cacerts -storepass changeit -alias "${name}" -file "${crt}" || exit 1; \
      fi; \
    done \
 && if [ "${jvm}" = true ]; then keytool -list -cacerts -storepass changeit -alias "${CA_ALIAS}"; fi \
 && install -m 0644 /tmp/ca-bundle.pem /etc/ssl/certs/company-ca-bundle.pem \
 && rm /tmp/ca-bundle.pem

# Clients outside the OS store and the JVM: Node.js adds NODE_EXTRA_CA_CERTS to its built-in roots;
# Python requests/pip and other OpenSSL-based tools read the full OS bundle, which now holds the CA.
ENV TZ=UTC \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/company-ca-bundle.pem
WORKDIR /app
# Numeric (hadolint DL3066): Kubernetes runAsNonRoot can only verify a numeric user.
USER ${APP_UID}:${APP_GID}
