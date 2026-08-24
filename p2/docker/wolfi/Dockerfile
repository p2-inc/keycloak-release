# Wolfi-based vanilla Keycloak image.
#
# NOT YET IN USE. p2/config.sh sets VANILLA_BASE=tag, which builds with the
# Dockerfile from the Keycloak tag itself (ubi9-micro) and so produces bit-for-bit
# the same inputs as upstream's own image. Set VANILLA_BASE=wolfi to switch to
# this, which is the point of building a vanilla image ourselves at all: a base we
# control, patched on our schedule rather than Red Hat's. ../phasetwo-containers
# already ships on Wolfi and this follows its runtime stage.
#
# Deliberately kept faithful to upstream's image contract -- same paths, same
# uid, same entrypoint, same exposed ports -- so switching the base cannot
# quietly break anything downstream.
#
# Expects in the build context:
#   keycloak-<version>.tar.gz     the server distribution
# Build args:
#   KEYCLOAK_DIST                 the tarball's filename
#   KEYCLOAK_VERSION              for the labels

ARG KEYCLOAK_VERSION=999.0.0-SNAPSHOT
ARG KEYCLOAK_DIST=keycloak-${KEYCLOAK_VERSION}.tar.gz

# ---------------------------------------------------------------------------
# Unpack on a stage that has tar, so the runtime image needs no build tools.
# No `kc.sh build` here: upstream's image does not run one either, and doing so
# would bake in an augmentation this image is not supposed to have an opinion
# about. This stays vanilla.
# ---------------------------------------------------------------------------
FROM cgr.dev/chainguard/wolfi-base:latest AS unpack
ARG KEYCLOAK_DIST
RUN apk add --no-cache tar gzip
COPY ${KEYCLOAK_DIST} /tmp/kc.tar.gz
RUN set -eu; \
    mkdir -p /tmp/x; \
    tar -xzf /tmp/kc.tar.gz -C /tmp/x; \
    mv /tmp/x/keycloak-* /opt/keycloak; \
    mkdir -p /opt/keycloak/data; \
    chmod -R g+rwX /opt/keycloak; \
    rm -rf /tmp/kc.tar.gz /tmp/x

# ---------------------------------------------------------------------------
# Runtime.
# ---------------------------------------------------------------------------
FROM cgr.dev/chainguard/wolfi-base:latest
ARG KEYCLOAK_VERSION

ENV LANG=en_US.UTF-8
# Keycloak checks this to know it is containerised.
ENV KC_RUN_IN_CONTAINER=true
ENV KEYCLOAK_HOME=/opt/keycloak
ENV JAVA_HOME=/usr/lib/jvm/default-jvm

# bash because kc.sh is a bash script; ca-certificates so outbound TLS (identity
# brokering, SMTP) works at all.
RUN apk add --no-cache \
        bash \
        ca-certificates-bundle \
        openjdk-21-default-jvm \
    && rm -rf /var/cache/apk/*

# uid 1000 in the root group, matching upstream's image: OpenShift and our own
# manifests rely on the directory being group-writable and the process being
# non-root with this exact uid.
RUN addgroup -g 1000 keycloak \
    && adduser -u 1000 -G root -s /sbin/nologin -D -H -h /opt/keycloak keycloak \
    && addgroup keycloak root

COPY --from=unpack --chown=1000:0 /opt/keycloak /opt/keycloak

USER 1000

EXPOSE 8080
EXPOSE 8443
EXPOSE 9000

ENTRYPOINT [ "/opt/keycloak/bin/kc.sh" ]

LABEL org.opencontainers.image.title="Keycloak Server" \
      org.opencontainers.image.description="Keycloak ${KEYCLOAK_VERSION} on Wolfi" \
      org.opencontainers.image.version="${KEYCLOAK_VERSION}" \
      org.opencontainers.image.url="https://www.keycloak.org/" \
      org.opencontainers.image.source="https://github.com/p2-inc/keycloak" \
      org.opencontainers.image.vendor="Phase Two, Inc." \
      io.k8s.display-name="Keycloak Server"
