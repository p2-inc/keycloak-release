#!/usr/bin/env bash
#
# Decide what needs building, and emit it as GitHub Actions matrices.
#
# State is derived, never stored: "is this tag done?" is answered by asking the
# fork for a <version>_crdb branch and quay.io for a <version> image tag. That
# makes the poller idempotent and self-healing -- delete an image tag and the
# next run rebuilds it; no bookkeeping file can drift out of sync with reality.
#
# The one piece of stored state is p2/baseline-tags.txt, which records what
# already existed at activation so the first run doesn't try to build the world.
#
# Usage:
#   p2/scripts/detect-work.sh
#
# Environment:
#   ONLY_VERSION=26.7.3   consider just this version (workflow_dispatch)
#   IGNORE_BASELINE=1     consider tags predating activation (backfill)
#   FORCE=1               ignore "already published" checks (implies
#                         IGNORE_BASELINE); rebuilds and overwrites
#   SKIP_CRDB=1           don't emit CRDB work
#   SKIP_VANILLA=1        don't emit vanilla work
#
# Outputs (GITHUB_OUTPUT):
#   crdb_matrix     {"include":[{"version":..,"base":..}]}
#   vanilla_matrix  {"include":[{"version":..}]}
#   crdb_count / vanilla_count
#   has_work        true|false
#   released_matrix {"include":[{"version":..}]}  every in-scope tag this run,
#   released_count  regardless of whether anything still needs building. "Is
#                   this a new release?" is a different question from "do we
#                   still owe an image for it", and consumers that care about
#                   the release itself -- the content-marketing article -- must
#                   not be gated on leftover build work.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd git curl jq

FORCE=${FORCE:-0}
IGNORE_BASELINE=${IGNORE_BASELINE:-0}
[ "$FORCE" = "1" ] && IGNORE_BASELINE=1
ONLY_VERSION=${ONLY_VERSION:-}
[ -n "$ONLY_VERSION" ] && assert_version "$ONLY_VERSION"

group "Gathering state"
UPSTREAM=$(upstream_tags)
CRDB_BRANCHES=$(crdb_versions)
BASELINE=$(baseline_tags)
[ "$IGNORE_BASELINE" = "1" ] && BASELINE=""

if [ "${SKIP_VANILLA:-0}" = "1" ]; then
    VANILLA_PUBLISHED=""
else
    VANILLA_PUBLISHED=$(quay_tags "$VANILLA_IMAGE" | grep -E "$TAG_PATTERN" || true)
fi
[ "$FORCE" = "1" ] && VANILLA_PUBLISHED=""
[ "$FORCE" = "1" ] && FORCED_BRANCHES="" || FORCED_BRANCHES="$CRDB_BRANCHES"

log "upstream release tags:      $(printf '%s\n' "$UPSTREAM" | grep -c . || true)"
log "crdb branches in fork:      $(printf '%s\n' "$CRDB_BRANCHES" | grep -c . || true)"
log "baseline (out of scope):    $(printf '%s\n' "$BASELINE" | grep -c . || true)"
log "vanilla tags on quay:       $(printf '%s\n' "$VANILLA_PUBLISHED" | grep -c . || true)"
endgroup

crdb_reason() {
    local tag=$1 stream in_stream
    stream=$(stream_of "$tag")

    if is_dormant_stream "$stream"; then
        printf 'skip: stream %s is dormant (CRDB_DORMANT_STREAMS)\n' "$stream"; return 1
    fi
    if in_list "$tag" "$FORCED_BRANCHES"; then
        printf 'skip: %s_crdb already exists\n' "$tag"; return 1
    fi

    in_stream=$(printf '%s\n' "$CRDB_BRANCHES" | grep -E "^${stream//./\\.}\." || true)
    if [ -z "$in_stream" ] && [ "$CRDB_ADOPT_NEW_STREAMS" != "1" ]; then
        printf 'skip: stream %s is untracked and CRDB_ADOPT_NEW_STREAMS=0\n' "$stream"; return 1
    fi
    if [ -z "$in_stream" ]; then
        printf 'port: new stream %s, adopting\n' "$stream"; return 0
    fi
    printf 'port: stream %s is tracked\n' "$stream"; return 0
}

CRDB_ROWS=()
VANILLA_ROWS=()
RELEASED_ROWS=()
SUMMARY=()

group "Deciding"
while read -r tag; do
    [ -n "$tag" ] || continue
    if [ -n "$ONLY_VERSION" ] && [ "$tag" != "$ONLY_VERSION" ]; then continue; fi
    if in_list "$tag" "$BASELINE"; then continue; fi

    # Recorded before the "already published" checks below: this is the set of
    # releases in scope, not the set of things left to build.
    RELEASED_ROWS+=("$(jq -nc --arg v "$tag" '{version:$v}')")

    # --- vanilla ---
    if [ "${SKIP_VANILLA:-0}" = "1" ] || [ "$VANILLA_ENABLED" != "1" ]; then
        :
    elif in_list "$tag" "$VANILLA_PUBLISHED"; then
        log "$tag vanilla: skip, already on $VANILLA_IMAGE"
    else
        VANILLA_ROWS+=("$(jq -nc --arg v "$tag" '{version:$v}')")
        SUMMARY+=("| \`$tag\` | vanilla | build |")
        log "$tag vanilla: build"
    fi

    # --- crdb ---
    if [ "${SKIP_CRDB:-0}" = "1" ]; then continue; fi
    reason=$(crdb_reason "$tag") && want_crdb=1 || want_crdb=0
    if [ "$want_crdb" = "0" ]; then
        log "$tag crdb: $reason"
        continue
    fi
    if ! base=$(pick_crdb_base "$tag"); then
        warn "$tag crdb: no _crdb branch predates it; nothing to base a port on"
        SUMMARY+=("| \`$tag\` | crdb | **skipped** — no base branch |")
        continue
    fi
    CRDB_ROWS+=("$(jq -nc --arg v "$tag" --arg b "$base" '{version:$v,base:$b}')")
    SUMMARY+=("| \`$tag\` | crdb | port from \`${base}_crdb\` |")
    log "$tag crdb: $reason, base ${base}_crdb"
done <<< "$UPSTREAM"
endgroup

join_rows() {
    if [ "$#" -eq 0 ]; then echo '{"include":[]}'; else
        printf '%s\n' "$@" | jq -sc '{include:.}'
    fi
}

CRDB_MATRIX=$(join_rows "${CRDB_ROWS[@]+"${CRDB_ROWS[@]}"}")
VANILLA_MATRIX=$(join_rows "${VANILLA_ROWS[@]+"${VANILLA_ROWS[@]}"}")
RELEASED_MATRIX=$(join_rows "${RELEASED_ROWS[@]+"${RELEASED_ROWS[@]}"}")

emit crdb_matrix     "$CRDB_MATRIX"
emit vanilla_matrix  "$VANILLA_MATRIX"
emit released_matrix "$RELEASED_MATRIX"
emit crdb_count      "${#CRDB_ROWS[@]}"
emit vanilla_count   "${#VANILLA_ROWS[@]}"
emit released_count  "${#RELEASED_ROWS[@]}"
if [ "${#CRDB_ROWS[@]}" -gt 0 ] || [ "${#VANILLA_ROWS[@]}" -gt 0 ]; then
    emit has_work true
else
    emit has_work false
fi

if [ "${#SUMMARY[@]}" -gt 0 ]; then
    summary "### Work detected"
    summary ""
    summary "| version | image | action |"
    summary "|---|---|---|"
    printf '%s\n' "${SUMMARY[@]}" | while read -r l; do summary "$l"; done
else
    summary "### Nothing to do"
    summary ""
    summary "No upstream tags outside the baseline are missing an image or a \`_crdb\` branch."
fi
