#!/usr/bin/env bash
#
# Publish an agent-assisted port for human review, as a PR whose diff is exactly
# the CockroachDB patch.
#
# Branch naming here is a safety property, not a style choice. Anything named
# `<version>_crdb` is treated as publishable: `phasetwo-containers` resolves that
# exact ref to decide what to build, so creating it early -- even empty, even as
# a PR base -- would have that repo build an unpatched Keycloak and ship it as
# the CockroachDB image. So review happens entirely under `review/`:
#
#   review/<version>_base   the upstream tag, unmodified -- the PR base
#   review/<version>_crdb   the port                     -- the PR head
#
# The diff between them is the patch and nothing else, which is the same view as
# the compare link the manual process used. Merging the PR is harmless: it moves
# `review/<version>_base`, not `<version>_crdb`. Publishing is a separate,
# deliberate step, and the PR body says so and gives the command.
#
# Idempotent: re-running updates the branches and the existing PR.
#
# Usage:
#   open-review-pr.sh --version VERSION --staging-ref REF
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd git gh

VERSION="" STAGING_REF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version)     VERSION=${2:?}; shift 2 ;;
        --staging-ref) STAGING_REF=${2:?}; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done
assert_version "$VERSION"
[ -n "$STAGING_REF" ] || die "--staging-ref is required"

REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}
HEAD_BRANCH="review/${VERSION}_crdb"
BASE_BRANCH="review/${VERSION}_base"
BASE=${BASE:-unknown}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

group "Pushing review branches"
git init -q .
git remote add origin "https://x-access-token:${GH_TOKEN:?GH_TOKEN must be set}@github.com/${REPO}.git"
git remote add upstream "$UPSTREAM_REPO"

# The tag, as the PR base. Fetched from upstream because the fork has no tags.
git fetch -q --depth 1 --filter=blob:none upstream "refs/tags/${VERSION}"
TAG_SHA=$(git rev-parse FETCH_HEAD)
git push -q --force origin "${TAG_SHA}:refs/heads/${BASE_BRANCH}"
log "base $BASE_BRANCH at $VERSION (${TAG_SHA:0:8})"

git fetch -q --depth 1 --filter=blob:none origin "$STAGING_REF"
PORT_SHA=$(git rev-parse FETCH_HEAD)
git push -q --force origin "${PORT_SHA}:refs/heads/${HEAD_BRANCH}"
log "head $HEAD_BRANCH at ${PORT_SHA:0:8}"
endgroup

group "Opening the PR"
COMPARE="https://github.com/keycloak/keycloak/compare/${VERSION}...${REPO%%/*}:${REPO##*/}:${HEAD_BRANCH}"

# Written to a file rather than a variable: `gh --body-file` avoids shell
# quoting of a page of markdown entirely, and a heredoc inside $(...) is
# mis-parsed by bash 3.2 as soon as the body contains an apostrophe.
cat > "$WORK/body.md" <<EOF
<!-- p2-crdb-review -->
Automated CockroachDB port of **Keycloak ${VERSION}**, based on \`${BASE}_crdb\`.

This needed an agent to resolve something, so it is **not** auto-published.
It has still been verified: the image built from this branch passed the
CockroachDB smoke test (schema migrated, \`-crdb\` changeSets applied, admin API
live, migrations idempotent across a restart).

### What to review

The diff on this PR *is* the CockroachDB patch — \`${BASE_BRANCH}\` is the
unmodified \`${VERSION}\` tag. Read the agent's account in the
[workflow run](${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-}),
then check the diff. Pay attention to:

- conflict resolutions that dropped our side rather than merging both intents
- any new \`jpa-changelog-*-crdb.xml\`: does it copy the **whole** upstream
  changelog, is every changeSet id suffixed \`-crdb\`, and is the CockroachDB
  divergence explained in a comment?
- \`jpa-changelog-master-crdb.xml\`: is the new include in the same position it
  holds upstream?

Also viewable against upstream directly: [compare ${VERSION}...${HEAD_BRANCH}](${COMPARE})

### Publishing

**Merging this PR publishes nothing** — it moves \`${BASE_BRANCH}\`, not
\`${VERSION}_crdb\`. Nothing resolves a \`review/\` branch, so this is inert
until you say otherwise.

When the diff is right, publish it:

\`\`\`
gh workflow run p2-crdb-publish.yml -f version=${VERSION} -f from_ref=${HEAD_BRANCH}
\`\`\`

That pushes \`${VERSION}_crdb\` and the multi-arch image, and cleans up both
\`review/\` branches.

If it is wrong, fix it on \`${HEAD_BRANCH}\` and re-run the same command — or
push \`${HEAD_BRANCH}\` yourself and take it from there.
EOF

EXISTING=$(gh pr list --repo "$REPO" --head "$HEAD_BRANCH" --state open \
    --json number --jq '.[0].number // empty' 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
    gh pr edit "$EXISTING" --repo "$REPO" --body-file "$WORK/body.md"
    URL=$(gh pr view "$EXISTING" --repo "$REPO" --json url --jq .url)
    log "updated existing PR #$EXISTING"
else
    URL=$(gh pr create --repo "$REPO" \
        --base "$BASE_BRANCH" --head "$HEAD_BRANCH" \
        --title "CRDB port: Keycloak ${VERSION} (needs review)" \
        --body-file "$WORK/body.md")
    log "opened $URL"
fi
endgroup

emit pr_url "$URL"
emit head_branch "$HEAD_BRANCH"

summary "### Review needed for \`$VERSION\`"
summary ""
summary "The port is verified but was agent-assisted, so it was not auto-published."
summary ""
summary "- PR: $URL"
summary "- publish with: \`gh workflow run p2-crdb-publish.yml -f version=$VERSION -f from_ref=$HEAD_BRANCH\`"
