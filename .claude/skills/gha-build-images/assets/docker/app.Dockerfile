# app.Dockerfile: the image of one application, FROM the company runtime base (gha-build-images skill).
#
# The runtime base already holds the enterprise CA (OS and JVM stores), tzdata, curl, the non-root user
# 10001 and the /app, /app/logs, /config layout, so this file adds only the application. Shown for a
# Spring Boot jar built by the build tool outside Docker (the proven form); other stacks at the end.
#
# Placeholders (grep -n '__[A-Z0-9_]*__'):
#   __IMAGE_NAMESPACE__    registry namespace; base images live under <namespace>/base/   ghcr.io/acme
#   __APP_NAME__           application (and image) name                                    orders-api
# Adapt the port (8080) and the health endpoint of HEALTHCHECK to the app.
#
# CI passes --build-arg BASE_IMAGE=<namespace>/base/runtime-base@sha256:<digest> (resolved once per run,
# or the local bootstrap build); the default below serves hand builds. Build context = the project
# directory after the build tool produced the jar:
#   docker buildx build -f Dockerfile --build-arg BASE_IMAGE="$BASE_IMAGE" -t __APP_NAME__:dev .
#   podman build --format docker -f Dockerfile -t __APP_NAME__:dev .    (Docker format keeps HEALTHCHECK)
ARG BASE_IMAGE=__IMAGE_NAMESPACE__/base/runtime-base:latest

# Stage 1: explode the layered jar, so dependencies and application code become separate, cache-friendly
# layers. It runs as the base's user 10001 and writes under /tmp only, so no stage needs root.
FROM ${BASE_IMAGE} AS layers
ARG JAR_FILE=build/libs/__APP_NAME__.jar
COPY ${JAR_FILE} /tmp/app.jar
RUN java -Djarmode=tools -jar /tmp/app.jar extract --layers --launcher --destination /tmp/extracted

# Stage 2: the runtime image, least-changing layer first.
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG CREATED=unknown
ARG SOURCE_URL=""
# base.name records the exact base (a digest in CI), so every image says which CA and patches it carries.
LABEL org.opencontainers.image.title="__APP_NAME__" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}"
# Heap as a share of the container memory limit, never a fixed -Xmx; JAVA_OPTS is for operators.
ENV JAVA_DEFAULT_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError -Djava.io.tmpdir=/tmp" \
    JAVA_OPTS=""
WORKDIR /app
COPY --from=layers /tmp/extracted/dependencies/ ./
COPY --from=layers /tmp/extracted/spring-boot-loader/ ./
COPY --from=layers /tmp/extracted/snapshot-dependencies/ ./
COPY --from=layers /tmp/extracted/application/ ./
# Numeric, so Kubernetes runAsNonRoot can verify it. The files above stay root-owned: read-only for the
# app, whose only writable paths are /tmp and /app/logs (compatible with a read-only root filesystem).
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD ["sh", "-c", "curl -fsS http://localhost:8080/actuator/health/liveness || exit 1"]
# exec keeps java as PID 1, so SIGTERM reaches it (graceful shutdown); container arguments pass through.
ENTRYPOINT ["sh", "-c", "exec java $JAVA_DEFAULT_OPTS $JAVA_OPTS -cp /app org.springframework.boot.loader.launch.JarLauncher \"$@\"", "app"]

# Other stacks: keep `FROM ${BASE_IMAGE}`, the labels, USER, EXPOSE and HEALTHCHECK; replace the stages.
#   Plain jar  COPY ${JAR_FILE} /app/app.jar, and `-jar /app/app.jar` in the ENTRYPOINT.
#   Node.js    runtime base built FROM node:22-slim; `npm ci --omit=dev` in a builder stage FROM the same
#              base; COPY node_modules/ and dist/; ENTRYPOINT ["node", "dist/server.js"].
#   Python     runtime base FROM python:3.13-slim; a venv built in a builder stage (pip install
#              --no-cache-dir -r requirements.txt); COPY the venv; ENTRYPOINT ["/app/venv/bin/python", "-m", "<module>"].
#   Go         a static binary: COPY it onto the runtime base (the CA and the user come along).
