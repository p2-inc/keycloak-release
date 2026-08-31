#!/usr/bin/env bash
#
# Put a Keycloak checkout on disk with exactly the refs a port or build needs.
#
# The fork carries Keycloak's whole history plus 80-odd _crdb branches, so a
# full clone is gigabytes of blobs we will never read. A blobless clone
# (--filter=blob:none) of the same repository is ~99MB and ~11s, and the one
# tree we actually check out costs another ~8s of on-demand blob fetches. Total
# ~20s and ~150MB, against a Maven build that takes half an hour.
#
# Upstream release tags are NOT in the fork -- p2-inc/keycloak has exactly one
# tag (26.0.0) and 84 _crdb branches -- so the tag comes from
# keycloak/keycloak and the base branch from the fork, as two separate fetches.
#
# Usage:
#   prepare-source.sh --dir DIR --version VERSION [--base BASE] [--no-checkout]
#
#   --base BASE   also fetch BASE (tag) and BASE_crdb (branch), for a port
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd git

DIR="" VERSION="" BASE="" CHECKOUT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)         DIR=${2:?}; shift 2 ;;
        --version)     VERSION=${2:?}; shift 2 ;;
        --base)        BASE=${2:?}; shift 2 ;;
        --no-checkout) CHECKOUT=0; shift ;;
        *) die "unknown option: $1" ;;
    esac
done
[ -n "$DIR" ] || die "--dir is required"
assert_version "$VERSION"
[ -n "$BASE" ] && assert_version "$BASE"

if [ -d "$DIR/.git" ]; then
    log "reusing existing checkout at $DIR"
else
    group "Cloning $FORK_REPO (blobless)"
    git clone --filter=blob:none --no-checkout --no-tags "$FORK_REPO" "$DIR"
    endgroup
fi

git -C "$DIR" remote get-url upstream >/dev/null 2>&1 \
    || git -C "$DIR" remote add upstream "$UPSTREAM_REPO"

# A committer identity is needed for the cherry-pick commit. GitHub Actions does
# not set one, and the fork's own history uses the xgp noreply address.
git -C "$DIR" config user.name  "xgp"
git -C "$DIR" config user.email "244253+xgp@users.noreply.github.com"
# Cherry-picking a commit that renames or deletes files across a release wants
# rename detection to be generous; the default limit gives up on Keycloak-sized
# trees and degrades the merge to add/delete pairs.
git -C "$DIR" config merge.renameLimit 999999
git -C "$DIR" config diff.renameLimit 999999

group "Fetching refs"
fetch_tag_into "$DIR" "$VERSION"
if [ -n "$BASE" ]; then
    # The tag is the cherry-pick's merge base: BASE_crdb is one commit on top of
    # it, so without the tag git has no common ancestor to three-way against.
    fetch_tag_into "$DIR" "$BASE"
    fetch_branch_into "$DIR" "${BASE}_crdb"
fi
endgroup

if [ "$CHECKOUT" = "1" ]; then
    group "Checking out $VERSION"
    git -C "$DIR" checkout --detach "$VERSION"
    endgroup
fi

emit dir "$DIR"
emit sha "$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo '')"
log "ready: $DIR at $VERSION${BASE:+ (base ${BASE}_crdb)}"
