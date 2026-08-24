#!/usr/bin/env bash
#
# Configuration for the p2-inc/keycloak release automation.
#
# Sourced by everything under p2/scripts/. Plain bash rather than YAML/JSON so
# there is nothing to parse and no dependency to install -- and so the policy
# decisions below can carry the explanation of *why* they are what they are.
#
#
# Every setting below is env-overridable (`${VAR-default}`), so a workflow_dispatch
# or a test can change one policy knob without editing this file. An explicitly
# empty value wins too -- CRDB_DORMANT_STREAMS= clears the list rather than
# falling back to the default.
#
# shellcheck disable=SC2034  # these are consumed by the scripts that source us

# --- upstream -------------------------------------------------------------
UPSTREAM_REPO=${UPSTREAM_REPO-"https://github.com/keycloak/keycloak.git"}
FORK_REPO=${FORK_REPO-"https://github.com/p2-inc/keycloak.git"}

# Release tags only: bare three-part semver. Deliberately excludes upstream's
# pre-release shapes (26.8.0-rc1, 999.0.0-SNAPSHOT, nightly) and the ancient
# `.Final` scheme, none of which we ship.
TAG_PATTERN=${TAG_PATTERN-'^[0-9]+\.[0-9]+\.[0-9]+$'}

# --- registries -----------------------------------------------------------
CRDB_IMAGE=${CRDB_IMAGE-"quay.io/phasetwo/keycloak-crdb"}
VANILLA_IMAGE=${VANILLA_IMAGE-"quay.io/phasetwo/keycloak"}

# --- CRDB port scope ------------------------------------------------------
# A stream is "tracked" if it already has a <version>_crdb branch -- that is
# derived from the fork's refs, not listed here, so adopting a stream is a
# consequence of publishing its first branch rather than a separate edit.
#
# Streams that have _crdb branches but which we have stopped maintaining. As of
# the 2026-08-24 activation, 26.4 and 26.2 were both several backports behind
# (26.4.13/14/15 and 26.2.14/15/16 were all skipped by hand), so treating them
# as tracked would resurrect six ports nobody asked for. Remove a stream from
# this list to pick it back up.
CRDB_DORMANT_STREAMS=${CRDB_DORMANT_STREAMS-"26.2 26.4"}

# When upstream opens a brand-new minor or major (26.8.0, 27.0.0), port it even
# though no branch in that stream exists yet. The base is then the highest crdb
# branch overall, which is the case most likely to need conflict resolution --
# see p2/prompts/resolve-crdb-port.md.
CRDB_ADOPT_NEW_STREAMS=${CRDB_ADOPT_NEW_STREAMS-1}

# --- vanilla image scope --------------------------------------------------
# Every new tag, in every stream, including backports upstream never cut a
# GitHub release for -- catching those is the whole point of this image.
VANILLA_ENABLED=${VANILLA_ENABLED-1}

# Base image for the vanilla build.
#   tag    - the Dockerfile from the Keycloak tag itself (ubi9-micro). Truly
#            vanilla: identical inputs to upstream's own image build.
#   wolfi  - p2/docker/wolfi/Dockerfile, matching ../phasetwo-containers.
VANILLA_BASE=${VANILLA_BASE-"tag"}

# --- build ----------------------------------------------------------------
# Keycloak 26.x builds on JDK 21 and the published jars say Build-Jdk-Spec: 21.
JDK_VERSION=${JDK_VERSION-"21"}

# quarkus/dist is the server distribution; quarkus/deployment is needed for the
# augmentation step. `-am` pulls in their dependencies (~49 of 136 modules).
BUILD_MODULES=${BUILD_MODULES-"quarkus/deployment,quarkus/dist"}

# The dist embeds one platform-specific brotli4j native jar, chosen by
# OS-activated Maven profiles in brotli4j's own pom and not overridable from the
# command line. Upstream builds on linux/amd64, so we do too, and both
# architectures' images are assembled from that one tarball.
DIST_BUILD_ARCH=${DIST_BUILD_ARCH-"amd64"}

# Platforms to publish. Assembled on native runners and joined into a manifest
# rather than emulated under QEMU -- the Dockerfile's dnf/microdnf steps are
# painfully slow under binfmt.
PLATFORMS=${PLATFORMS-"linux/amd64,linux/arm64"}

# --- smoke test -----------------------------------------------------------
# The CockroachDB the image is verified against. Matches the version pinned in
# quarkus/container/docker-compose.yml on the _crdb branches, so CI tests what
# the documented local setup runs.
CRDB_TEST_VERSION=${CRDB_TEST_VERSION-"v23.2.23"}

# Seconds to wait for Keycloak to report ready. First boot runs the whole
# Liquibase migration against CockroachDB, which is the slow part.
SMOKE_TIMEOUT=${SMOKE_TIMEOUT-300}
