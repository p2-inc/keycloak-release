#!/usr/bin/env bash
#
# Sanity-check a vanilla Keycloak image: does it actually boot and serve?
#
# Much lighter than the CRDB smoke test, and deliberately so. There is no
# CockroachDB patch to verify here -- the risk being covered is a broken image,
# not a broken schema: a truncated distribution, a Dockerfile change upstream
# made that we mishandled, a base image missing something the server needs. So
# it runs in dev mode against the embedded database, which needs no dependencies
# and takes about a minute.
#
# Usage:
#   smoke-vanilla.sh --image IMAGE [--timeout SECONDS]
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker curl

IMAGE="" TIMEOUT=180
while [ $# -gt 0 ]; do
    case "$1" in
        --image)   IMAGE=${2:?}; shift 2 ;;
        --timeout) TIMEOUT=${2:?}; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done
[ -n "$IMAGE" ] || die "--image is required"

NAME="p2-vanilla-smoke-$$"
cleanup() {
    local rc=$?
    [ "$rc" != "0" ] && { echo "::group::container logs"; docker logs "$NAME" 2>&1 | tail -120; echo "::endgroup::"; }
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    return $rc
}
trap cleanup EXIT

group "Booting $IMAGE in dev mode"
# Ephemeral host ports: the runner may already have 8080 in use, and this
# container is never restarted, so the mapping is stable for its lifetime.
docker run -d --name "$NAME" \
    -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
    -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
    -e KC_HEALTH_ENABLED=true \
    -p 127.0.0.1::8080 -p 127.0.0.1::9000 \
    "$IMAGE" start-dev >/dev/null
HTTP_PORT=$(docker port "$NAME" 8080 | tail -1); HTTP_PORT=${HTTP_PORT##*:}
MGMT_PORT=$(docker port "$NAME" 9000 | tail -1); MGMT_PORT=${MGMT_PORT##*:}
log "http=$HTTP_PORT management=$MGMT_PORT"
endgroup

group "Waiting for /health/ready (up to ${TIMEOUT}s)"
deadline=$((SECONDS + TIMEOUT)); ready=0
while [ $SECONDS -lt $deadline ]; do
    curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${MGMT_PORT}/health/ready" 2>/dev/null \
        && { ready=1; break; }
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
        die "the container exited before becoming ready"
    fi
    sleep 3
done
[ "$ready" = "1" ] || die "not ready after ${TIMEOUT}s"
log "ready"
endgroup

group "Checking the server serves and reports the expected version"
TOKEN=$(curl -fsS -m 15 -X POST \
    "http://127.0.0.1:${HTTP_PORT}/realms/master/protocol/openid-connect/token" \
    -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
    2>/dev/null | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p') || true
[ -n "$TOKEN" ] || die "could not obtain an admin token"
log "admin token works"

# Confirms the image contains the distribution we think it does -- a stale cache
# or a mixed-up build arg would otherwise ship the wrong version under the right
# tag, which is invisible from the outside.
REPORTED=$(curl -fsS -m 15 -H "Authorization: Bearer $TOKEN" \
    "http://127.0.0.1:${HTTP_PORT}/admin/serverinfo" 2>/dev/null \
    | sed -n 's/.*"systemInfo":{[^}]*"version":"\([^"]*\)".*/\1/p' | head -1)
log "server reports version: ${REPORTED:-unknown}"
if [ -n "${EXPECT_VERSION:-}" ] && [ -n "$REPORTED" ] && [ "$REPORTED" != "$EXPECT_VERSION" ]; then
    die "image reports Keycloak $REPORTED but should be $EXPECT_VERSION"
fi
endgroup

summary "### Vanilla smoke test passed"
summary ""
summary "| check | result |"
summary "|---|---|"
summary "| image | \`$IMAGE\` |"
summary "| boots in dev mode | yes |"
summary "| admin token | works |"
summary "| reported version | \`${REPORTED:-unknown}\` |"
log "vanilla smoke test passed"
