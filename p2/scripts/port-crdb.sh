#!/usr/bin/env bash
#
# Port the CockroachDB patch onto a new Keycloak tag, mechanically.
#
# Every *_crdb branch in the fork is exactly one commit on top of its tag --
# verified across 26.4.12, 26.6.5, 26.6.6, 26.7.0 and 26.7.2 -- so the port is a
# cherry-pick, not a `git diff | git apply`. That matters: a cherry-pick gets
# real three-way merging with the tag as the merge base, resolves most upstream
# drift by itself, carries the binary JDBC driver jar across without a manual
# copy, and leaves conflict markers on the parts it genuinely cannot decide
# instead of failing the whole patch.
#
# Measured on real tags: a patch bump (26.6.5_crdb -> 26.6.6) cherry-picks clean
# and lands byte-identical to the hand-built branch apart from the two fixups
# below. A minor bump (26.6.6_crdb -> 26.7.0) produces three conflicts, of which
# two are eliminated here by construction:
#
#   openapi.yaml/.json  Build output that was committed by accident. It records
#                       the version string the build stamped in, so it conflicts
#                       on every single release, and upstream renamed .yaml to
#                       .json in 26.7.0 which turns that into a modify/delete.
#                       Dropped from the patch entirely -- the build regenerates
#                       it, so carrying it forward has never served a purpose.
#
#   rolling-upgrades-   Upstream appends to the same JSON list we append to, so
#   supported-          it conflicts whenever a release adds a changeSet.
#   changes.json        Regenerated from the *-crdb.xml files instead of merged;
#                       see sync-rolling-upgrades.py.
#
# What is left is genuine upstream drift in the ~10 patched Java files, which
# needs judgement and goes to an agent and then to review.
#
# Usage:
#   port-crdb.sh --repo DIR --version VERSION [--base BASE]
#
# Outputs (GITHUB_OUTPUT):
#   base        the branch that was ported from
#   status      clean | conflicts
#   conflicts   space-separated unresolved paths
#   branch      the branch name that was created
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd git python3

REPO="" VERSION="" BASE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)    REPO=${2:?}; shift 2 ;;
        --version) VERSION=${2:?}; shift 2 ;;
        --base)    BASE=${2:?}; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done
[ -d "${REPO:?--repo is required}/.git" ] || die "$REPO is not a git checkout"
assert_version "$VERSION"

g() { git -C "$REPO" "$@"; }

# Resolved here rather than trusted from the poller: if upstream publishes two
# tags between polls, the poller sees the same base for both, but by the time the
# second is ported the first one's branch exists and is the better base.
if [ -z "$BASE" ]; then
    log "resolving base for $VERSION"
    BASE=$(pick_crdb_base "$VERSION") \
        || die "no _crdb branch predates $VERSION; nothing to port from"
fi
assert_version "$BASE"
version_lt "$BASE" "$VERSION" || die "base $BASE does not predate $VERSION"

BRANCH="${VERSION}_crdb"
SRC="${BASE}_crdb"

# Fetched here rather than assumed: the base was re-resolved above and may not
# be the one prepare-source.sh was told about.
g remote get-url upstream >/dev/null 2>&1 || g remote add upstream "$UPSTREAM_REPO"
fetch_tag_into "$REPO" "$VERSION"
fetch_tag_into "$REPO" "$BASE"
fetch_branch_into "$REPO" "$SRC"

# A cherry-pick only reduces to "apply this one patch" if the source really is a
# single commit on its tag. If upstream ever changes that shape, stop rather
# than silently squashing several commits' worth of work into one.
n=$(g rev-list --count "$BASE..$SRC")
[ "$n" = "1" ] || die "$SRC is $n commits on top of $BASE, expected exactly 1; \
the port assumes one squashed commit per branch and needs revisiting"

group "Creating $BRANCH at $VERSION"
# Re-runnable: a previous attempt may have left a conflicted index, which would
# make the checkout below fail. Clear it -- but only when the mess is ours, so
# pointing --repo at a working copy can never discard someone's edits.
if [ -n "$(g status --porcelain)" ]; then
    current=$(g rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    case "$current" in
        *_crdb|HEAD) log "clearing state from a previous port attempt on '$current'" ;;
        *) die "$REPO has uncommitted changes on '$current'; refusing to reset it" ;;
    esac
fi
g cherry-pick --quit 2>/dev/null || true
g reset -q --hard
g checkout -q --detach "$VERSION"
g branch -f "$BRANCH" "$VERSION"
g checkout -q "$BRANCH"
endgroup

group "Cherry-picking $SRC"
# --no-commit: the commit is made at the end, after the fixups below, so the
# branch never carries a commit containing generated noise.
# -X patience: better hunk matching on the large, repeatedly-edited Java files.
CHERRY_RC=0
g cherry-pick --no-commit -X patience "$SRC" || CHERRY_RC=$?
[ "$CHERRY_RC" = "0" ] && log "applied cleanly" || warn "conflicts to resolve"
endgroup

unmerged() { g diff --name-only --diff-filter=U; }

group "Fixup: drop generated openapi from the patch"
# Reset to whatever the tag has, in whatever shape the tag has it. This runs
# whether or not openapi conflicted, so the file leaves the patch lineage for
# good rather than being resolved again on every release.
OPENAPI_DIR="js/libs/keycloak-admin-client"
tag_openapi=$(g ls-tree -r --name-only "$VERSION" -- "$OPENAPI_DIR" \
    | grep -E '/openapi\.(ya?ml|json)$' || true)
for p in $tag_openapi; do
    g checkout "$VERSION" -- "$p" && log "reset $p to $VERSION"
done
# Anything the patch left behind that the tag does not have -- e.g. openapi.yaml
# surviving as a modify/delete conflict after upstream renamed it to .json.
# sort -u because ls-files lists an unmerged path once per merge stage.
for p in $(g ls-files -- "$OPENAPI_DIR" | grep -E '/openapi\.(ya?ml|json)$' | sort -u || true); do
    if ! printf '%s\n' $tag_openapi | grep -qxF "$p"; then
        g rm -q -f --ignore-unmatch "$p" && log "removed $p (not present at $VERSION)"
    fi
done
endgroup

group "Fixup: docker-compose image tag"
COMPOSE="quarkus/container/docker-compose.yml"
if [ -f "$REPO/$COMPOSE" ]; then
    # Only the crdb image line; the cockroach and any proxy images are pinned
    # deliberately and are none of our business.
    python3 - "$REPO/$COMPOSE" "$CRDB_IMAGE" "$VERSION" <<'PY'
import re, sys
path, image, version = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
new, n = re.subn(rf'(image:\s*){re.escape(image)}:\S+', rf'\g<1>{image}:{version}', s)
if n:
    open(path, 'w').write(new)
print(f"updated {n} image reference(s) to {image}:{version}", file=sys.stderr)
PY
    g add "$COMPOSE"
else
    warn "$COMPOSE not present; skipping image tag fixup"
fi
endgroup

group "Fixup: regenerate rolling-upgrades-supported-changes.json"
RU="model/jpa/src/main/resources/META-INF/rolling-upgrades-supported-changes.json"
# Regenerated from upstream's file at the tag plus the *-crdb.xml changeSets, so
# a conflict here is discarded rather than resolved.
"$P2_ROOT/p2/scripts/sync-rolling-upgrades.py" --repo "$REPO" --upstream-ref "$VERSION"
g add "$RU"
endgroup

REMAINING=$(unmerged | tr '\n' ' ' | sed 's/ *$//')

group "Result"
if [ -n "$REMAINING" ]; then
    warn "unresolved conflicts in:"
    for f in $REMAINING; do warn "  $f"; done
    # Left mid-cherry-pick on purpose: the markers and the unmerged index are
    # what an agent (or a human) needs in order to resolve them. finalize-crdb.sh
    # makes the commit once they are gone.
    emit status conflicts
else
    log "no conflicts; committing"
    g cherry-pick --quit 2>/dev/null || true
    g add -A
    g commit -q -s -m "update to $VERSION"
    log "committed $(g rev-parse --short HEAD) on $BRANCH"
    emit status clean
fi
endgroup

emit base      "$BASE"
emit branch    "$BRANCH"
emit conflicts "$REMAINING"

summary "### CRDB port: \`$VERSION\` from \`$SRC\`"
summary ""
if [ -n "$REMAINING" ]; then
    summary "Cherry-pick left **$(printf '%s\n' $REMAINING | grep -c .) unresolved conflict(s)**:"
    summary ""
    for f in $REMAINING; do summary "- \`$f\`"; done
else
    summary "Cherry-pick applied cleanly."
fi
