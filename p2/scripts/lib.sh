#!/usr/bin/env bash
#
# Shared helpers for the release automation. Source this, don't execute it:
#
#   . "$(dirname "$0")/lib.sh"
#
# Sourcing also sources p2/config.sh, so callers get the configuration too.

# Resolve the branch root from this file's location so scripts work regardless
# of the directory they are invoked from.
P2_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
P2_ROOT=$(cd "$P2_LIB_DIR/../.." && pwd)
# shellcheck source=../config.sh
. "$P2_ROOT/p2/config.sh"

# --- output ---------------------------------------------------------------
# GitHub Actions renders ::group::/::error:: markers; a terminal just sees text.
log()   { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
group() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$*" || log "$*"; }
endgroup() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::" || true; }

# Emit a step output when running under Actions, and echo it either way so the
# scripts stay debuggable from a shell.
emit() {
    local name=$1 value=$2
    printf '%s=%s\n' "$name" "$value" >&2
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        if [ "${value}" != "${value#*$'\n'}" ]; then
            # Multi-line values need heredoc syntax. The delimiter includes the
            # name so two concurrent emits can't collide.
            printf '%s<<__P2_EOF_%s\n%s\n__P2_EOF_%s\n' "$name" "$name" "$value" "$name" \
                >> "$GITHUB_OUTPUT"
        else
            printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
        fi
    fi
}

# Append markdown to the job summary, if there is one.
summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
    else
        printf '%s\n' "$*"
    fi
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null || die "$c not found on PATH"
    done
}

# --- versions -------------------------------------------------------------
# "26.7.2" -> "26.7". A stream is a minor release line; upstream backports CVE
# fixes into several at once, which is why scope is decided per stream.
stream_of() { printf '%s\n' "${1%.*}"; }

is_release_tag() { printf '%s' "$1" | grep -qE "$TAG_PATTERN"; }

# Reject anything that could escape into a shell or a git refname. Every version
# in this pipeline arrives from the network (upstream tags, workflow_dispatch
# input), so it gets checked before it reaches a command line.
assert_version() {
    is_release_tag "${1:-}" || die "not a release version: '${1:-}'"
}

# Highest of the versions on stdin, by version order. Empty stdin -> empty.
version_max() { sort -V | tail -1; }

# True when $1 < $2. Uses sort -V so 26.10.0 > 26.9.0, which a lexical
# comparison gets wrong.
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# --- remote refs ----------------------------------------------------------
# All of these hit the network but none of them clone. The poller runs every
# six hours, so it stays cheap: three ls-remotes and two registry queries.
#
# Each one honours a P2_FAKE_* override naming a file of canned output. That is
# what p2/scripts/test-detect.sh drives the policy logic with -- the decisions
# in detect-work.sh are pure functions of these three lists, so stubbing them is
# enough to test every branch of the policy without touching the network. The
# overrides are unset in normal operation.

# Release tags in the upstream repository, one per line, version-sorted.
upstream_tags() {
    if [ -n "${P2_FAKE_UPSTREAM_TAGS:-}" ]; then
        grep -E "$TAG_PATTERN" "$P2_FAKE_UPSTREAM_TAGS" | sort -V; return
    fi
    git ls-remote --tags --refs "$UPSTREAM_REPO" \
        | sed 's|.*refs/tags/||' \
        | grep -E "$TAG_PATTERN" \
        | sort -V
}

# Versions that have a <version>_crdb branch in the fork, version-sorted.
fork_crdb_versions() {
    if [ -n "${P2_FAKE_CRDB_VERSIONS:-}" ]; then
        grep -E "$TAG_PATTERN" "$P2_FAKE_CRDB_VERSIONS" | sort -V; return
    fi
    git ls-remote --heads "$FORK_REPO" '*_crdb' \
        | sed 's|.*refs/heads/||; s|_crdb$||' \
        | grep -E "$TAG_PATTERN" \
        | sort -V
}

# Active tags in a public quay.io repository, one per line. Paginates because
# keycloak-crdb has more than one page of history. An unreachable registry is
# fatal rather than treated as "nothing published": guessing empty here would
# rebuild and re-push every image we have.
quay_tags() {
    local image=$1 repo page=1 body has_more
    repo=${image#quay.io/}
    if [ -n "${P2_FAKE_QUAY_DIR:-}" ]; then
        cat "$P2_FAKE_QUAY_DIR/${repo//\//_}" 2>/dev/null || true
        return
    fi
    while :; do
        body=$(curl -fsSL --retry 3 --retry-delay 2 \
            "https://quay.io/api/v1/repository/${repo}/tag/?limit=100&onlyActiveTags=true&page=${page}") \
            || die "cannot list tags for $image"
        printf '%s' "$body" | jq -r '.tags[]?.name'
        has_more=$(printf '%s' "$body" | jq -r '.has_additional // false')
        [ "$has_more" = "true" ] || break
        page=$((page + 1))
        [ "$page" -gt 50 ] && die "runaway pagination listing $image"
    done
}

# --- policy ---------------------------------------------------------------
# Membership in a space-separated list, e.g. in_list 26.4 "$CRDB_DORMANT_STREAMS".
# A `case` glob rather than a loop over $*: unquoted $* relies on word splitting
# to do the right thing here, which works but reads like a bug, and "$@" -- the
# obvious-looking fix -- would test the whole list as one element and silently
# always return false. Versions and stream names never contain spaces, so
# padding both sides and globbing is exact.
in_list() {
    local needle=$1 hay
    shift
    hay=" $* "
    # Callers pass both space-separated lists (config values) and newline-
    # separated ones (baseline_tags, quay_tags), so normalise the separators
    # before matching rather than leaning on IFS word splitting to paper over
    # the difference. Done with parameter expansion, not a subshell: this is
    # called a few hundred times per poll.
    hay=${hay//$'\n'/ }
    hay=${hay//$'\t'/ }
    case "$hay" in *" $needle "*) return 0 ;; esac
    return 1
}

is_dormant_stream() { in_list "$1" "$CRDB_DORMANT_STREAMS"; }

# The set of tags that already existed when the automation was switched on.
# Anything in here is out of scope: the poller exists to catch what upstream
# publishes from now on, not to backfill years of history. Backfilling is a
# deliberate workflow_dispatch with an explicit version.
baseline_tags() {
    if [ -f "$P2_ROOT/p2/baseline-tags.txt" ]; then
        grep -vE '^\s*(#|$)' "$P2_ROOT/p2/baseline-tags.txt" || true
    fi
}

# Memoised: a loop over many tags should cost one ls-remote, not one per tag.
_P2_CRDB_CACHED=0
_P2_CRDB_LIST=""
crdb_versions() {
    if [ "$_P2_CRDB_CACHED" = "0" ]; then
        _P2_CRDB_LIST=$(fork_crdb_versions || true)
        _P2_CRDB_CACHED=1
    fi
    printf '%s\n' "$_P2_CRDB_LIST" | grep . || true
}

# Pick the branch a CRDB port should be based on: the newest _crdb branch that
# predates the target. Same stream wins over a globally newer branch -- basing a
# 26.4.x backport on 26.7.2_crdb would drag in a release's worth of unrelated
# upstream drift and turn a clean cherry-pick into a conflict pile.
#
# Deliberately resolved fresh at port time rather than trusted from the poller.
# If upstream publishes 26.7.3 and 26.7.4 between two polls, the poller sees
# 26.7.2 as the base for both; by the time 26.7.4 is ported, 26.7.3_crdb exists
# and is the better base. Ports run one at a time, ascending, so re-resolving
# always walks the chain one generation at a time.
#
# Prints the base version, or fails if nothing predates the target.
pick_crdb_base() {
    local target=$1 stream candidates base
    stream=$(stream_of "$target")
    candidates=$(crdb_versions)

    older_than_target() {
        local v
        while read -r v; do
            [ -n "$v" ] || continue
            version_lt "$v" "$target" && printf '%s\n' "$v"
        done
    }

    base=$(printf '%s\n' "$candidates" | grep -E "^${stream//./\\.}\." | older_than_target | version_max)
    [ -n "$base" ] && { printf '%s\n' "$base"; return 0; }

    base=$(printf '%s\n' "$candidates" | older_than_target | version_max)
    [ -n "$base" ] && { printf '%s\n' "$base"; return 0; }

    return 1
}

# True when $1 is the highest version we have shipped to $2, and so should also
# move the `latest` tag. Backports must never steal `latest` from a newer
# release -- 26.4.15 landing after 26.7.2 is a routine occurrence.
is_newest_published() {
    local version=$1 image=$2 highest
    highest=$( { quay_tags "$image" | grep -E "$TAG_PATTERN" || true; printf '%s\n' "$version"; } | version_max )
    [ "$highest" = "$version" ]
}

# --- fetching refs into a checkout ---------------------------------------
# Shared by prepare-source.sh and port-crdb.sh. port-crdb.sh re-resolves the
# base at port time, which is the point -- but it can therefore land on a branch
# prepare-source.sh was never asked for. When upstream publishes 26.7.3 and
# 26.7.4 between two polls, the poller passes base=26.7.2 for both; by the time
# 26.7.4 is ported, 26.7.3_crdb exists and is the better base, and nothing has
# fetched it. So whatever resolves a ref also fetches it.
#
# All fetches are blobless; blobs arrive on demand at checkout.

fetch_tag_into() {
    local dir=$1 tag=$2
    git -C "$dir" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null && return 0
    log "fetching upstream tag $tag"
    git -C "$dir" fetch --filter=blob:none --no-tags upstream tag "$tag" \
        || die "upstream tag $tag not found in $UPSTREAM_REPO"
}

fetch_branch_into() {
    local dir=$1 br=$2
    git -C "$dir" rev-parse -q --verify "refs/heads/$br" >/dev/null && return 0
    log "fetching fork branch $br"
    git -C "$dir" fetch --filter=blob:none --no-tags origin \
        "refs/heads/$br:refs/heads/$br" \
        || die "branch $br not found in $FORK_REPO"
}
