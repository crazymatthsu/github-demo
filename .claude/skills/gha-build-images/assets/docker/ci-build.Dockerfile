# ci-build.Dockerfile: the CI build image (gha-build-images skill).
#
# The build job runs in it (`container:`), test-runner containers start from it, and a laptop runs the
# same build with `docker run`: one environment everywhere. It holds the language toolchain
# (TOOLCHAIN_IMAGE, default a JDK), the enterprise CA in the OS trust store and, when the toolchain has
# a JVM, in its cacerts; the Docker CLI with compose and buildx (Docker's apt repository, signing key
# checked against its published fingerprint); helm, kubectl and kind (release binaries checked against
# the SHA-256 sums their projects publish); hadolint, shellcheck, yq and crane (from their official
# images), jq, git and curl; and the non-root user 1001, the UID of the GitHub-hosted runner user, so
# files written into the bind-mounted workspace keep their owner. The last RUN fails the build unless
# every piece works.
#
# Placeholders (grep -n '__[A-Z0-9_]*__'):
#   __CA_ALIAS__           cacerts alias of the first bundle certificate (then -02, -03, ...)   acme-root-ca
#   __CA_BUNDLE_VERSION__  version of the CA bundle, written to the com.example.ca-bundle label  2026-09
#   __VENDOR__             value of the OCI vendor label                                          Acme Corp
# Also replace the label namespace `com.example` with your reverse-DNS prefix (a placeholder in a label
# key would fail hadolint DL3048).
#
# Build context = the directory holding the CA bundle; nothing else is copied:
#   docker buildx build -f docker/base/ci-build.Dockerfile -t <namespace>/base/ci-build:dev --load docker/ca
#   podman build --format docker -f docker/base/ci-build.Dockerfile -t <namespace>/base/ci-build:dev docker/ca
# Other toolchains (Debian or Ubuntu images only: the RUN steps use apt), for example
#   --build-arg TOOLCHAIN_IMAGE=docker.io/library/maven:3-eclipse-temurin-21   (or node:22, python:3.13,
#   golang:1.25 under docker.io/library/). Registries are fully qualified because Podman requires it.
# Every version is an ARG under a `# renovate:` hint, so a bump is a one-line diff (references/pinning.md).
# Keep HELM_VERSION, KUBECTL_VERSION and KIND_VERSION equal to ci/versions.env (scripts/check-pins.sh)
# and the CA step identical to runtime-base.Dockerfile.

ARG TOOLCHAIN_IMAGE=docker.io/library/eclipse-temurin:21-jdk
# Linters and the registry client, copied as static binaries from their official images.
# renovate: datasource=docker depName=hadolint/hadolint
ARG HADOLINT_VERSION=v2.15.1
# renovate: datasource=docker depName=koalaman/shellcheck
ARG SHELLCHECK_VERSION=v0.11.0
# renovate: datasource=docker depName=mikefarah/yq
ARG YQ_VERSION=4.53.6
# renovate: datasource=docker depName=gcr.io/go-containerregistry/crane
ARG CRANE_VERSION=v0.22.1

FROM docker.io/hadolint/hadolint:${HADOLINT_VERSION} AS hadolint
FROM docker.io/koalaman/shellcheck:${SHELLCHECK_VERSION} AS shellcheck
FROM docker.io/mikefarah/yq:${YQ_VERSION} AS yq
FROM gcr.io/go-containerregistry/crane:${CRANE_VERSION} AS crane

FROM ${TOOLCHAIN_IMAGE}

ARG TOOLCHAIN_IMAGE
# Docker's apt repository: the CLI plus the compose and buildx plugins (images are built with buildx).
# renovate: datasource=github-tags depName=docker/cli extractVersion=^v(?<version>.+)$
ARG DOCKER_VERSION=29.8.1
# renovate: datasource=github-releases depName=docker/compose extractVersion=^v(?<version>.+)$
ARG DOCKER_COMPOSE_VERSION=5.5.1
# renovate: datasource=github-releases depName=docker/buildx extractVersion=^v(?<version>.+)$
ARG DOCKER_BUILDX_VERSION=0.37.1
# Fingerprint of Docker's release signing key, as published in Docker's installation guide.
ARG DOCKER_APT_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# Kubernetes tools. Keep equal to ci/versions.env (host jobs install the same versions).
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v4.3.0
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.37.1
# renovate: datasource=github-releases depName=kubernetes-sigs/kind
ARG KIND_VERSION=v0.33.0
# The CA bundle (references/enterprise-ca.md). CA_BUNDLE_SHA256, when set, must match the file.
ARG CA_BUNDLE_FILE=ca-bundle.pem
ARG CA_BUNDLE_SHA256=""
ARG CA_BUNDLE_VERSION=__CA_BUNDLE_VERSION__
ARG CA_ALIAS=__CA_ALIAS__
# The job container runs as this user: 1001 is the GitHub-hosted runner UID; self-hosted fleets pass theirs.
ARG RUNNER_UID=1001
ARG RUNNER_GID=1001
# OCI labels, set by base-image.yml.
ARG IMAGE_VERSION=""
ARG GIT_SHA=""
ARG CREATED=""
ARG SOURCE_URL=""
# Set by buildx and podman from --platform; dpkg decides when a builder does not set it.
ARG TARGETARCH

LABEL org.opencontainers.image.title="ci-build" \
      org.opencontainers.image.description="CI build image: toolchain, enterprise CA in the OS and JVM trust stores, Docker CLI with compose and buildx, helm, kubectl, kind, hadolint, shellcheck, yq, jq, git, crane" \
      org.opencontainers.image.vendor="__VENDOR__" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${TOOLCHAIN_IMAGE}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${CREATED}" \
      com.example.ca-bundle="${CA_BUNDLE_VERSION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# OS packages, deliberately unpinned (DL3008): the weekly rebuild exists to pick up security fixes, and
# pinned Debian/Ubuntu versions vanish from the archive. Then Docker's apt repository, its key checked
# against the published fingerprint before apt trusts it, and the Docker client packages pinned to the
# ARGs. Their version string embeds the distribution (ID, VERSION_ID, codename from /etc/os-release).
# hadolint ignore=DL3008,SC1091
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git gnupg jq openssl tzdata \
 && . /etc/os-release \
 && case "${ID}" in debian | ubuntu) ;; *) echo "unsupported distribution ${ID}: use a Debian or Ubuntu image" >&2; exit 1 ;; esac \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL --proto '=https' "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc \
 && gpg --batch --show-keys --with-colons /etc/apt/keyrings/docker.asc > /tmp/docker-key.colons \
 && grep -q "^fpr:::::::::${DOCKER_APT_KEY_FINGERPRINT}:" /tmp/docker-key.colons \
 && rm /tmp/docker-key.colons \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && suffix="-1~${ID}.${VERSION_ID}~${VERSION_CODENAME}" \
 && apt-get install -y --no-install-recommends \
      "docker-ce-cli=5:${DOCKER_VERSION}${suffix}" \
      "docker-compose-plugin=${DOCKER_COMPOSE_VERSION}${suffix}" \
      "docker-buildx-plugin=${DOCKER_BUILDX_VERSION}${suffix}" \
 && rm -rf /var/lib/apt/lists/*

# Static binaries from the stages above (paths as published in each image).
COPY --from=hadolint /bin/hadolint /usr/local/bin/hadolint
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY --from=crane /ko-app/crane /usr/local/bin/crane

# helm, kubectl, kind: official release binaries, each checked against the SHA-256 file its project
# publishes next to it (a sum that is missing or malformed fails too). To also survive a compromised
# download host, pin the sums as ARGs instead (references/pinning.md).
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && case "${arch}" in amd64 | arm64) ;; *) echo "unsupported architecture ${arch}" >&2; exit 1 ;; esac \
 && fetch() { curl -fsSL --proto '=https' --retry 3 --retry-connrefused "$@"; } \
 && verify() { [[ "$1" =~ ^[0-9a-f]{64}$ ]] || { echo "no SHA-256 published for $2" >&2; return 1; }; echo "$1  $2" | sha256sum -c --quiet -; } \
 && tmp="$(mktemp -d)" \
 && helm_tgz="helm-${HELM_VERSION}-linux-${arch}.tar.gz" \
 && fetch -o "${tmp}/${helm_tgz}" "https://get.helm.sh/${helm_tgz}" \
 && sum="$(fetch "https://get.helm.sh/${helm_tgz}.sha256sum" | cut -d ' ' -f 1)" \
 && verify "${sum}" "${tmp}/${helm_tgz}" \
 && tar -xzf "${tmp}/${helm_tgz}" -C "${tmp}" \
 && install -m 0755 "${tmp}/linux-${arch}/helm" /usr/local/bin/helm \
 && kubectl_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
 && fetch -o "${tmp}/kubectl" "${kubectl_url}" \
 && sum="$(fetch "${kubectl_url}.sha256" | cut -d ' ' -f 1)" \
 && verify "${sum}" "${tmp}/kubectl" \
 && install -m 0755 "${tmp}/kubectl" /usr/local/bin/kubectl \
 && kind_url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${arch}" \
 && fetch -o "${tmp}/kind" "${kind_url}" \
 && sum="$(fetch "${kind_url}.sha256sum" | cut -d ' ' -f 1)" \
 && verify "${sum}" "${tmp}/kind" \
 && install -m 0755 "${tmp}/kind" /usr/local/bin/kind \
 && rm -rf "${tmp}"

COPY ${CA_BUNDLE_FILE} /tmp/ca-bundle.pem

# The enterprise CA, identical in runtime-base.Dockerfile (references/enterprise-ca.md): refuse a bundle
# that holds a private key or does not match CA_BUNDLE_SHA256; split it into one file per certificate
# (both stores read one certificate per file); OS store (curl, git, apt, OpenSSL-based clients) and,
# when the toolchain has a JVM, its default cacerts (the build tool and every Java client). A JVM
# without keytool fails the build instead of silently missing the CA. `|| exit 1` inside the loop:
# bash ignores -e in a loop that is part of an && chain, and a loop reports only its last command.
# Then the runner user and /workspace, and finally the self-check of every tool.
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
 && rm /tmp/ca-bundle.pem \
 && if ! getent group "${RUNNER_GID}" >/dev/null; then groupadd --gid "${RUNNER_GID}" runner; fi \
 && if ! getent passwd "${RUNNER_UID}" >/dev/null; then useradd --uid "${RUNNER_UID}" --gid "${RUNNER_GID}" --create-home --shell /bin/bash runner; fi \
 && install -d -m 0755 -o "${RUNNER_UID}" -g "${RUNNER_GID}" /workspace \
 && if command -v java >/dev/null 2>&1; then java -version; fi \
 && docker --version && docker compose version && docker buildx version \
 && helm version --short && kubectl version --client && kind version \
 && hadolint --version && shellcheck --version && yq --version && jq --version \
 && git --version && curl --version && crane version

# Clients outside the OS store and the JVM: Node.js adds NODE_EXTRA_CA_CERTS to its built-in roots;
# Python requests/pip and other OpenSSL-based tools read the full OS bundle, which now holds the CA.
ENV TZ=UTC \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/company-ca-bundle.pem
WORKDIR /workspace
# Numeric (hadolint DL3066): the runner UID, so a job container writes the workspace as its owner.
USER ${RUNNER_UID}:${RUNNER_GID}
