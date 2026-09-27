# docker/base/ci-build/Dockerfile: the pinned build image (D3 §6.1, §6.10; D10 §4.2, §5.1; DL-28).
#
# The `build` job runs in it (`container:`) and the integration tests run in it as the it-runner compose
# service, so CI and a laptop share one environment: JDK 21 (same vendor as the runtime base), the
# enterprise CA in both trust stores, the Docker CLI with compose and buildx, helm, kubectl, kind,
# hadolint, shellcheck, yq, jq, git, curl and crane. Gradle comes from the wrapper. It is a sibling of
# jre21 (built by the same workflow from the JDK variant), not a child.
#
# Build context = the directory holding the CA bundle:
#   docker buildx build -f docker/base/ci-build/Dockerfile -t ghcr.io/crazymatthsu/base/ci-build:<yyyymmdd>-<n> test-infra/ca
# Every tool version is an ARG. Renovate or a manual bump PR changes one line (D3 §6.3).

ARG TEMURIN_IMAGE=eclipse-temurin:21-jdk
ARG HADOLINT_VERSION=v2.15.1
ARG SHELLCHECK_VERSION=v0.11.0
ARG YQ_VERSION=4.53.6
ARG CRANE_VERSION=v0.22.1

# Static binaries from the tools' official multi-arch images (paths verified in each image).
FROM docker.io/hadolint/hadolint:${HADOLINT_VERSION} AS hadolint
FROM docker.io/koalaman/shellcheck:${SHELLCHECK_VERSION} AS shellcheck
FROM docker.io/mikefarah/yq:${YQ_VERSION} AS yq
FROM gcr.io/go-containerregistry/crane:${CRANE_VERSION} AS crane

FROM ${TEMURIN_IMAGE}

ARG TEMURIN_IMAGE
# Docker's apt repository (docker-ce-cli, docker-compose-plugin, docker-buildx-plugin; buildx because
# the build job builds images with `docker buildx build`, D1 / D3 §6.7).
ARG DOCKER_VERSION=29.8.1
ARG DOCKER_COMPOSE_VERSION=5.5.1
ARG DOCKER_BUILDX_VERSION=0.37.1
ARG DOCKER_APT_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# Kubernetes tooling for demo step 2 (kind + Helm).
ARG HELM_VERSION=v4.3.0
ARG KUBECTL_VERSION=v1.37.1
ARG KIND_VERSION=v0.33.0
ARG CA_BUNDLE_FILE=demo-root-ca.pem
ARG CA_BUNDLE_VERSION=demo-2026-09
ARG CA_ALIAS=demo-root-ca
ARG IMAGE_VERSION=""
ARG GIT_SHA=""
ARG CREATED=""
# Set by buildx and podman from --platform (dpkg decides when a builder does not); CI stays amd64 (D3 §4.6).
ARG TARGETARCH

LABEL org.opencontainers.image.title="ci-build" \
      org.opencontainers.image.description="Company build image: JDK 21, enterprise CA in both trust stores, Docker CLI with compose and buildx, helm, kubectl, kind, hadolint, shellcheck, yq, jq, git, crane" \
      org.opencontainers.image.source="https://github.com/crazymatthsu/github-demo" \
      org.opencontainers.image.vendor="com.example" \
      org.opencontainers.image.base.name="${TEMURIN_IMAGE}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${CREATED}" \
      com.example.ca-bundle="${CA_BUNDLE_VERSION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# OS packages (unpinned, see jre21), then Docker's apt repository with its signing key checked against
# the published fingerprint, and the Docker client packages pinned to the ARG versions.
# hadolint ignore=DL3008,SC1091
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git gnupg jq tzdata \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && gpg --batch --show-keys --with-colons /etc/apt/keyrings/docker.asc > /tmp/docker-key.colons \
 && grep -q "^fpr:::::::::${DOCKER_APT_KEY_FINGERPRINT}:" /tmp/docker-key.colons \
 && rm /tmp/docker-key.colons \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && . /etc/os-release \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "docker-ce-cli=5:${DOCKER_VERSION}-1~ubuntu.${VERSION_ID}~${VERSION_CODENAME}" \
      "docker-compose-plugin=${DOCKER_COMPOSE_VERSION}-1~ubuntu.${VERSION_ID}~${VERSION_CODENAME}" \
      "docker-buildx-plugin=${DOCKER_BUILDX_VERSION}-1~ubuntu.${VERSION_ID}~${VERSION_CODENAME}" \
 && rm -rf /var/lib/apt/lists/*

# Static tool binaries from the stages above.
COPY --from=hadolint /bin/hadolint /usr/local/bin/hadolint
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY --from=crane /ko-app/crane /usr/local/bin/crane

# helm, kubectl and kind: official release binaries, checked against the SHA-256 sums their projects
# publish next to them. The enterprise pins the sums as ARGs and fetches through a JFrog remote.
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && case "${arch}" in amd64 | arm64) ;; *) echo "unsupported architecture ${arch}" >&2; exit 1 ;; esac \
 && tmp="$(mktemp -d)" \
 && helm_tgz="helm-${HELM_VERSION}-linux-${arch}.tar.gz" \
 && curl -fsSLo "${tmp}/${helm_tgz}" "https://get.helm.sh/${helm_tgz}" \
 && echo "$(curl -fsSL "https://get.helm.sh/${helm_tgz}.sha256sum" | cut -d ' ' -f 1)  ${tmp}/${helm_tgz}" | sha256sum -c - \
 && tar -xzf "${tmp}/${helm_tgz}" -C "${tmp}" \
 && install -m 0755 "${tmp}/linux-${arch}/helm" /usr/local/bin/helm \
 && curl -fsSLo "${tmp}/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
 && echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl.sha256")  ${tmp}/kubectl" | sha256sum -c - \
 && install -m 0755 "${tmp}/kubectl" /usr/local/bin/kubectl \
 && kind_url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${arch}" \
 && curl -fsSLo "${tmp}/kind" "${kind_url}" \
 && echo "$(curl -fsSL "${kind_url}.sha256sum" | cut -d ' ' -f 1)  ${tmp}/kind" | sha256sum -c - \
 && install -m 0755 "${tmp}/kind" /usr/local/bin/kind \
 && rm -rf "${tmp}"

COPY ${CA_BUNDLE_FILE} /tmp/ca-bundle.pem

# The CA, exactly as in jre21 (D3 §6.2): OS store and JDK cacerts, so Gradle, curl, git and the
# container CLIs trust it. Then the non-root user runner, whose UID 1001 matches the GitHub-hosted
# runner user, so files written into the bind-mounted workspace keep their owner. Finally the build
# fails unless the CA and every tool are in place.
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
 && keytool -list -cacerts -storepass changeit -alias "${CA_ALIAS}" \
 && groupadd --gid 1001 runner \
 && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash runner \
 && install -d -m 0755 -o runner -g runner /workspace \
 && java -version \
 && docker --version && docker compose version && docker buildx version \
 && helm version --short && kubectl version --client && kind version \
 && hadolint --version && shellcheck --version && yq --version && jq --version \
 && git --version && curl --version && crane version

ENV TZ=UTC
WORKDIR /workspace
# The user runner, numerically (hadolint DL3066; matches the GitHub-hosted runner UID).
USER 1001:1001
