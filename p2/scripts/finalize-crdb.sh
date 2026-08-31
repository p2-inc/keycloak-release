#!/usr/bin/env bash
#
# Finish a CRDB port whose conflicts have been resolved, and check it over.
#
# Runs after port-crdb.sh reported `status=conflicts` and something -- an agent
# or a person -- resolved them. Re-applies the generated fixups (the resolution
# may have added a -crdb changelog, which changes what
# rolling-upgrades-supported-changes.json must record), makes the commit, and
# then checks the shape of what it produced.
#
# Idempotent: safe to run when the port was already clean and committed.
#
# Usage:
#   finalize-crdb.sh --repo DIR --version VERSION --base BASE
#
# Outputs (GITHUB_OUTPUT):
#   status      committed | markers | unmerged
#   sha         the resulting commit
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
assert_version "$BASE"

g() { git -C "$REPO" "$@"; }
BRANCH="${VERSION}_crdb"

g rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null \
    || die "branch $BRANCH does not exist; run port-crdb.sh first"

group "Checking for unfinished resolution"
UNMERGED=$(g diff --name-only --diff-filter=U | sort -u)
if [ -n "$UNMERGED" ]; then
    warn "still unmerged:"
    printf '%s\n' "$UNMERGED" | while read -r f; do warn "  $f"; done
    emit status unmerged
    die "cannot finalize with unmerged paths"
fi

# Conflict markers that were edited around rather than removed would otherwise
# be committed and then fail the build with a syntax error a long way from here.
# Only files this port touched are scanned, so an unrelated fixture containing a
# line of equals signs can't trip it.
CHANGED=$(g diff --name-only "$VERSION" -- . | sort -u)
MARKERS=""
while read -r f; do
    [ -n "$f" ] || continue
    [ -f "$REPO/$f" ] || continue
    if grep -qE '^(<{7}|>{7}) ' "$REPO/$f" 2>/dev/null; then
        MARKERS="$MARKERS $f"
    fi
done <<< "$CHANGED"
MARKERS=${MARKERS# }
if [ -n "$MARKERS" ]; then
    warn "conflict markers left in:"
    for f in $MARKERS; do warn "  $f"; done
    emit status markers
    die "refusing to commit files containing conflict markers"
fi
log "no unmerged paths, no conflict markers"
endgroup

group "Re-applying generated fixups"
# The resolution may have added a jpa-changelog-<v>-crdb.xml, whose changeSets
# must be recorded or model/jpa's db-compatibility-verifier fails the build.
"$P2_ROOT/p2/scripts/sync-rolling-upgrades.py" --repo "$REPO" --upstream-ref "$VERSION"
# Re-dropped here because a resolution can restore them: a tree carrying
# upstream's .github/workflows/ cannot be pushed with GITHUB_TOKEN at all.
if [ -n "$(g ls-files -- .github/workflows)" ]; then
    g rm -q -r -f --ignore-unmatch -- .github/workflows
    log "removed .github/workflows from the patch"
fi
endgroup

group "Committing"
g cherry-pick --quit 2>/dev/null || true
g add -A
if g diff --cached --quiet && g rev-parse -q --verify HEAD >/dev/null \
   && [ "$(g rev-list --count "$VERSION..HEAD")" = "1" ]; then
    log "already committed; nothing staged"
else
    if [ "$(g rev-list --count "$VERSION..HEAD")" = "0" ]; then
        g commit -q -s -m "update to $VERSION"
        log "committed $(g rev-parse --short HEAD)"
    else
        # Fold the resolution into the single commit rather than stacking a
        # second one: every published *_crdb branch is one commit on its tag,
        # and the next release's port asserts that shape before cherry-picking.
        g commit -q -s --amend --no-edit
        log "amended into $(g rev-parse --short HEAD)"
    fi
fi
endgroup

group "Verifying the result"
N=$(g rev-list --count "$VERSION..HEAD")
[ "$N" = "1" ] || die "expected 1 commit on top of $VERSION, found $N"
log "one commit on top of $VERSION"

# A port that changed nothing has silently dropped the whole patch.
FILES=$(g diff --name-only "$VERSION..HEAD" | wc -l | tr -d ' ')
[ "$FILES" -gt 5 ] || die "only $FILES file(s) differ from $VERSION; the patch did not apply"
log "$FILES files differ from $VERSION"

# The parts of the patch that make CockroachDB work at all. If the merge quietly
# dropped one of these the image would build and then fail against a real
# CockroachDB, which the smoke test would catch much later and less clearly.
for required in \
    "model/jpa/src/main/resources/META-INF/jpa-changelog-master-crdb.xml" \
    "model/jpa/src/main/resources/META-INF/jpa-changelog-17.0.0-crdb.xml" \
    "quarkus/config-api/src/main/java/org/keycloak/config/database/Database.java" \
    "quarkus/container/Dockerfile"
do
    g cat-file -e "HEAD:$required" 2>/dev/null || die "$required missing from the port"
done
g diff --name-only "$VERSION..HEAD" | grep -q 'cockroachdb-jdbc-driver-.*\.jar' \
    || die "the CockroachDB JDBC driver jar is not in the port; the image would have no driver"
log "CockroachDB essentials present"

if g diff --name-only "$VERSION..HEAD" | grep -qE 'openapi\.(ya?ml|json)$'; then
    die "openapi is back in the patch; it is generated and must not be committed"
fi
log "no generated openapi in the patch"

# Mirrors the openapi guard: if these came back the push would be rejected with
# "refusing to allow a GitHub App to create or update workflow".
if [ -n "$(g ls-tree -r --name-only HEAD -- .github/workflows)" ]; then
    die "upstream workflows are back in the patch; GITHUB_TOKEN cannot push them"
fi
log "no upstream workflows in the patch"
endgroup

group "Changelog coverage"
GAP_RC=0
"$P2_ROOT/p2/scripts/changelog-gaps.py" --repo "$REPO" \
    --base-ref "$BASE" --new-ref "$VERSION" --github-output || GAP_RC=$?
endgroup

emit status committed
emit sha "$(g rev-parse HEAD)"

summary ""
SHORT=$(g rev-parse --short HEAD)
summary "Port committed as \`$SHORT\` on \`$BRANCH\` ($FILES files vs \`$VERSION\`)."
[ "$GAP_RC" = "2" ] && summary "" && summary ":warning: unported changelogs remain — see the log."
exit 0
