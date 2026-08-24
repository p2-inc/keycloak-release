#!/usr/bin/env bash
#
# Work out which image tags a version should be pushed as.
#
# The interesting part is `latest`. Upstream maintains several release streams at
# once and backports CVE fixes into all of them, so tags do not arrive in version
# order: 26.4.15 was published after 26.7.2. Moving `latest` on every push would
# hand it to a backport of a two-releases-old line. So `latest` moves only when
# this version is the highest we have ever published to that repository -- which
# is exactly the rule the manual process applied by hand ("if doing a backport,
# don't push latest").
#
# Usage:
#   image-tags.sh --image crdb|vanilla --version VERSION
#
# Outputs (GITHUB_OUTPUT):
#   image     the repository
#   tags      comma-separated, ready for docker/build-push-action
#   latest    true|false
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd curl jq

KIND="" VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image)   KIND=${2:?}; shift 2 ;;
        --version) VERSION=${2:?}; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done
assert_version "$VERSION"
case "$KIND" in
    crdb)    IMAGE=$CRDB_IMAGE ;;
    vanilla) IMAGE=$VANILLA_IMAGE ;;
    *) die "--image must be crdb or vanilla" ;;
esac

TAGS="${IMAGE}:${VERSION}"
if is_newest_published "$VERSION" "$IMAGE"; then
    TAGS="${TAGS},${IMAGE}:latest"
    log "$VERSION is the newest published to $IMAGE; moving latest"
    emit latest true
else
    log "$VERSION is not the newest on $IMAGE; leaving latest where it is"
    emit latest false
fi

emit image "$IMAGE"
emit tags  "$TAGS"
