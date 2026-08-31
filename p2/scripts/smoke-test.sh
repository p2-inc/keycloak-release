#!/usr/bin/env bash
#
# Verify a keycloak-crdb image actually works against a real CockroachDB.
#
# This is the step the manual process did by eye ("update the kc version in
# docker-compose.yml and run docker compose up"). It matters more than a build
# passing: the CockroachDB patch is mostly Liquibase changelogs and a JDBC
# dialect, and none of that is exercised by compiling. A port can build cleanly,
# produce an image, and then fail to create its schema.
#
# Four things are checked, in increasing order of what they'd catch:
#
#   1. Keycloak reaches /health/ready          -- it booted and migrated
#   2. our -crdb changeSets are in            -- the CockroachDB changelogs were
#      DATABASECHANGELOG                         actually applied, not silently
#                                                skipped by a broken master-crdb
#   3. an admin token can be minted           -- the server serves requests, so
#                                                the schema is usable
#   4. it survives a restart                  -- migrations are idempotent; a
#                                                changeSet that re-runs and
#                                                fails breaks every upgrade
#
# Check 2 is the one that justifies the exercise: a master-crdb.xml that lost its
# includes in a merge produces a server that boots fine on an empty database and
# is wrong in a way nothing else here would notice.
#
# Usage:
#   smoke-test.sh --image IMAGE [--timeout SECONDS] [--keep]
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker

IMAGE="" TIMEOUT=${SMOKE_TIMEOUT} KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --image)   IMAGE=${2:?}; shift 2 ;;
        --timeout) TIMEOUT=${2:?}; shift 2 ;;
        --keep)    KEEP=1; shift ;;
        *) die "unknown option: $1" ;;
    esac
done
[ -n "$IMAGE" ] || die "--image is required"

COMPOSE="$P2_ROOT/p2/docker/docker-compose.smoke.yml"
[ -f "$COMPOSE" ] || die "$COMPOSE not found"
PROJECT="p2smoke$$"

export KC_IMAGE="$IMAGE"
export CRDB_VERSION="$CRDB_TEST_VERSION"

dc() { docker compose -p "$PROJECT" -f "$COMPOSE" "$@"; }

dump_logs() {
    echo "::group::cockroach logs (tail)"; dc logs --tail=40 cockroach 2>&1 || true; echo "::endgroup::"
    echo "::group::keycloak logs"; dc logs --tail=250 keycloak 2>&1 || true; echo "::endgroup::"
}

cleanup() {
    local rc=$?
    [ "$rc" != "0" ] && dump_logs
    if [ "$KEEP" = "1" ]; then
        warn "--keep: leaving project $PROJECT running"
    else
        log "tearing down"
        dc down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    return $rc
}
trap cleanup EXIT

group "Starting $IMAGE against cockroachdb:$CRDB_TEST_VERSION"
dc up -d --quiet-pull
endgroup

# --- 1. readiness ---------------------------------------------------------
# All HTTP checks run from inside the compose network, using the cockroach
# container as the client -- its image ships curl for its own healthcheck. No
# host ports means nothing to collide with and, more importantly, nothing to be
# remapped underneath us: `compose restart` rebinds ephemeral host ports, so a
# cached one silently goes dead halfway through the run.
incurl() { dc exec -T cockroach curl -sS -m 15 "$@"; }
ready_check() { dc exec -T cockroach curl -fsS -m 5 -o /dev/null "http://keycloak:9000/health/ready"; }

group "Waiting for /health/ready (up to ${TIMEOUT}s)"
deadline=$((SECONDS + TIMEOUT))
ready=0
while [ $SECONDS -lt $deadline ]; do
    if ready_check >/dev/null 2>&1; then
        ready=1; break
    fi
    # Fail fast instead of waiting out the timeout when the container has died.
    state=$(dc ps --format json keycloak 2>/dev/null | tr -d '\n' || true)
    case "$state" in
        *'"State":"exited"'*|*'"State": "exited"'*)
            die "the keycloak container exited before becoming ready" ;;
    esac
    sleep 3
done
[ "$ready" = "1" ] || die "not ready after ${TIMEOUT}s"
log "ready after ~$((SECONDS))s"
endgroup

# --- 2. the CockroachDB changelogs actually ran ---------------------------
group "Checking DATABASECHANGELOG for -crdb changeSets"
sql() {
    dc exec -T cockroach ./cockroach sql --insecure --database=defaultdb \
        --format=tsv -e "$1" 2>/dev/null | tail -n +2
}
CRDB_APPLIED=$(sql "SELECT count(*) FROM databasechangelog WHERE filename LIKE '%-crdb.xml';" | tr -d ' \r')
TOTAL_APPLIED=$(sql "SELECT count(*) FROM databasechangelog;" | tr -d ' \r')
log "changeSets applied: $TOTAL_APPLIED total, $CRDB_APPLIED from -crdb changelogs"
case "$CRDB_APPLIED" in
    ''|*[!0-9]*) die "could not read DATABASECHANGELOG from CockroachDB" ;;
esac
# The consolidated 17.0.0-crdb baseline alone is 268 changeSets, so anything
# near zero means master-crdb.xml was not the changelog that ran.
[ "$CRDB_APPLIED" -ge 200 ] \
    || die "only $CRDB_APPLIED -crdb changeSets applied; expected 200+. \
master-crdb.xml is probably not being used -- check its includes survived the merge."
log "the CockroachDB changelogs were applied"

# Every changeSet Liquibase ran must have succeeded; MARK_RAN is legitimate
# (preconditions), but FAILED is not.
BAD=$(sql "SELECT count(*) FROM databasechangelog WHERE exectype NOT IN ('EXECUTED','MARK_RAN','RERAN');" | tr -d ' \r')
[ "${BAD:-0}" = "0" ] || die "$BAD changeSet(s) in a non-success exectype"
log "no failed changeSets"
endgroup

# --- 3. the server serves ------------------------------------------------
group "Minting an admin token"
TOKEN=$(incurl -X POST \
    "http://keycloak:8080/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "username=admin" -d "password=admin" \
    -d "grant_type=password" 2>/dev/null \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p') || true
[ -n "$TOKEN" ] || die "could not obtain an admin token; the server is up but not usable"
REALMS=$(incurl -H "Authorization: Bearer $TOKEN" \
    "http://keycloak:8080/admin/realms" | grep -o '"realm"' | wc -l | tr -d ' ')
[ "${REALMS:-0}" -ge 1 ] || die "admin API returned no realms"
log "admin token works; $REALMS realm(s) visible"
endgroup

# --- 4. restart, so migrations must be idempotent ------------------------
group "Restarting to confirm migrations are idempotent"
dc restart keycloak >/dev/null
deadline=$((SECONDS + TIMEOUT))
ready=0
while [ $SECONDS -lt $deadline ]; do
    ready_check >/dev/null 2>&1 && { ready=1; break; }
    sleep 3
done
[ "$ready" = "1" ] || die "did not come back after a restart; a changeSet probably re-ran and failed"
AFTER=$(sql "SELECT count(*) FROM databasechangelog;" | tr -d ' \r')
[ "$AFTER" = "$TOTAL_APPLIED" ] \
    || die "changeSet count moved from $TOTAL_APPLIED to $AFTER across a restart"
log "restarted cleanly; changeSet count unchanged"
endgroup

summary "### Smoke test passed"
summary ""
summary "| check | result |"
summary "|---|---|"
summary "| image | \`$IMAGE\` |"
summary "| CockroachDB | \`$CRDB_TEST_VERSION\` |"
summary "| changeSets applied | $TOTAL_APPLIED ($CRDB_APPLIED from \`-crdb\` changelogs) |"
summary "| admin API | $REALMS realm(s) |"
summary "| restart | clean, migrations idempotent |"
log "smoke test passed"
