#!/usr/bin/env bash
#
# Tests for the scope policy in detect-work.sh.
#
# Every decision the poller makes is a pure function of three lists -- upstream
# tags, the fork's _crdb branches, and what is already on quay -- so stubbing
# those via the P2_FAKE_* seams in lib.sh exercises the whole policy offline, in
# under a second, with no network and no Actions runner.
#
# Run:  p2/scripts/test-detect.sh
#
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0

# Baseline for the tests: pretend upstream is at 26.7.2 across the streams we
# actually track, which is the state at activation.
BASE_TAGS="26.2.16 26.4.12 26.4.13 26.4.14 26.4.15 26.6.5 26.6.6 26.7.0 26.7.1 26.7.2"
BASE_CRDB="26.2.13 26.4.12 26.6.5 26.6.6 26.7.0 26.7.1 26.7.2"

# run <upstream tags> <crdb branches> <baseline tags> <quay vanilla tags> [env...]
run() {
    local tags=$1 crdb=$2 baseline=$3 vanilla=$4; shift 4
    tr ' ' '\n' <<< "$tags"    > "$WORK/tags"
    tr ' ' '\n' <<< "$crdb"    > "$WORK/crdb"
    mkdir -p "$WORK/quay"
    tr ' ' '\n' <<< "$vanilla" > "$WORK/quay/phasetwo_keycloak"
    : > "$WORK/quay/phasetwo_keycloak-crdb"
    {
        echo "# test baseline"
        tr ' ' '\n' <<< "$baseline"
    } > "$WORK/baseline-tags.txt"

    # detect-work.sh reads the baseline from $P2_ROOT, so give it a root whose
    # p2/ is the real one except for the baseline file.
    rm -rf "$WORK/root"; mkdir -p "$WORK/root/p2"
    cp "$ROOT/p2/config.sh" "$WORK/root/p2/"
    cp -R "$ROOT/p2/scripts" "$WORK/root/p2/scripts"
    cp "$WORK/baseline-tags.txt" "$WORK/root/p2/baseline-tags.txt"

    env -i PATH="$PATH" HOME="$HOME" \
        P2_FAKE_UPSTREAM_TAGS="$WORK/tags" \
        P2_FAKE_CRDB_VERSIONS="$WORK/crdb" \
        P2_FAKE_QUAY_DIR="$WORK/quay" \
        GITHUB_OUTPUT="$WORK/out" \
        "$@" \
        bash "$WORK/root/p2/scripts/detect-work.sh" 2>"$WORK/log" || {
            echo "--- script failed ---"; cat "$WORK/log"; return 1; }
}

out() { sed -n "s/^$1=//p" "$WORK/out" | tail -1; }

check() {
    local name=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
        printf '  \033[32mok\033[0m   %s\n' "$name"; PASS=$((PASS+1))
    else
        printf '  \033[31mFAIL\033[0m %s\n       want: %s\n        got: %s\n' "$name" "$want" "$got"
        FAIL=$((FAIL+1))
    fi
}

# Compact rendering of a matrix so expectations read as data, not JSON.
crdb_got()    { out crdb_matrix    | jq -r '[.include[]|"\(.version)<-\(.base)"]|join(",")'; }
vanilla_got() { out vanilla_matrix | jq -r '[.include[]|.version]|join(",")'; }

echo
echo "policy: steady state"
run "$BASE_TAGS" "$BASE_CRDB" "$BASE_TAGS" "26.7.2"
check "no crdb work"    ""      "$(crdb_got)"
check "no vanilla work" ""      "$(vanilla_got)"
check "has_work false"  "false" "$(out has_work)"

echo
echo "policy: new patch tag in a tracked stream"
run "$BASE_TAGS 26.7.3" "$BASE_CRDB" "$BASE_TAGS" "26.7.2"
check "ports from 26.7.2" "26.7.3<-26.7.2" "$(crdb_got)"
check "builds vanilla"    "26.7.3"          "$(vanilla_got)"

echo
echo "policy: new patch tag in a dormant stream (26.4)"
run "$BASE_TAGS 26.4.16" "$BASE_CRDB" "$BASE_TAGS" "26.7.2"
check "no crdb port"   ""        "$(crdb_got)"
check "vanilla anyway" "26.4.16" "$(vanilla_got)"

echo
echo "policy: brand-new minor stream is adopted"
run "$BASE_TAGS 26.8.0" "$BASE_CRDB" "$BASE_TAGS" "26.7.2"
check "bases on newest overall" "26.8.0<-26.7.2" "$(crdb_got)"

echo
echo "policy: brand-new major stream is adopted"
run "$BASE_TAGS 27.0.0" "$BASE_CRDB" "$BASE_TAGS" "26.7.2"
check "bases on newest overall" "27.0.0<-26.7.2" "$(crdb_got)"

echo
echo "policy: same-stream base beats a globally newer one"
run "$BASE_TAGS 26.6.7" "$BASE_CRDB" "$BASE_TAGS" "26.7.2"
check "26.6.7 bases on 26.6.6, not 26.7.2" "26.6.7<-26.6.6" "$(crdb_got)"

echo
echo "policy: already-published work is skipped independently"
run "$BASE_TAGS 26.7.3" "$BASE_CRDB 26.7.3" "$BASE_TAGS" "26.7.2"
check "crdb skipped (branch exists)" ""       "$(crdb_got)"
check "vanilla still built"          "26.7.3" "$(vanilla_got)"
run "$BASE_TAGS 26.7.3" "$BASE_CRDB" "$BASE_TAGS" "26.7.2 26.7.3"
check "vanilla skipped (on quay)" ""              "$(vanilla_got)"
check "crdb still ported"         "26.7.3<-26.7.2" "$(crdb_got)"

echo
echo "policy: pre-release tag shapes are ignored"
run "$BASE_TAGS 26.8.0-rc1 nightly 999.0.0-SNAPSHOT 26.8.0.Final" "$BASE_CRDB" "$BASE_TAGS" "26.7.2"
check "no crdb work"    "" "$(crdb_got)"
check "no vanilla work" "" "$(vanilla_got)"

echo
echo "policy: two new tags in one stream, ascending, one generation at a time"
run "$BASE_TAGS 26.7.3 26.7.4" "$BASE_CRDB" "$BASE_TAGS" "26.7.2"
check "both queued in order" "26.7.3<-26.7.2,26.7.4<-26.7.2" "$(crdb_got)"
check "vanilla both in order" "26.7.3,26.7.4"                 "$(vanilla_got)"
# Once 26.7.3_crdb lands, re-resolving picks it up as the base for 26.7.4.
run "$BASE_TAGS 26.7.3 26.7.4" "$BASE_CRDB 26.7.3" "$BASE_TAGS" "26.7.2 26.7.3"
check "26.7.4 now bases on 26.7.3" "26.7.4<-26.7.3" "$(crdb_got)"

echo
echo "dispatch: ONLY_VERSION restricts, IGNORE_BASELINE backfills"
run "$BASE_TAGS 26.7.3 26.7.4" "$BASE_CRDB" "$BASE_TAGS" "26.7.2" ONLY_VERSION=26.7.4
check "only the named version" "26.7.4<-26.7.2" "$(crdb_got)"
run "$BASE_TAGS" "$BASE_CRDB" "$BASE_TAGS" "26.7.2" ONLY_VERSION=26.4.15 IGNORE_BASELINE=1
check "baselined tag reachable, dormant still blocks crdb" "" "$(crdb_got)"
check "baselined tag builds vanilla"                       "26.4.15" "$(vanilla_got)"

echo
echo "dispatch: FORCE overrides the already-published checks"
run "$BASE_TAGS" "$BASE_CRDB" "$BASE_TAGS" "26.7.2" ONLY_VERSION=26.7.2 FORCE=1
check "rebuilds an existing crdb branch" "26.7.2<-26.7.1" "$(crdb_got)"
check "rebuilds an existing image"       "26.7.2"          "$(vanilla_got)"

echo
echo "policy: un-dormanting a stream picks the in-stream base"
run "$BASE_TAGS 26.4.16" "$BASE_CRDB" "$BASE_TAGS" "26.7.2" CRDB_DORMANT_STREAMS=
check "26.4.16 bases on 26.4.12" "26.4.16<-26.4.12" "$(crdb_got)"

echo
echo "policy: review/ branches never look like published ports"
# open-review-pr.sh creates review/<version>_crdb, which the '*_crdb' glob in
# fork_crdb_versions matches. Only TAG_PATTERN keeps it out of the version list;
# if that ever loosened, an in-review port would read as already published and
# the poller would skip it, or worse be picked as a base.
run "$BASE_TAGS 26.7.3" "$BASE_CRDB review/26.7.3 review/26.6.9" "$BASE_TAGS" "26.7.2"
check "review refs ignored, real base chosen" "26.7.3<-26.7.2" "$(crdb_got)"

echo
echo "policy: adoption can be switched off"
run "$BASE_TAGS 26.8.0" "$BASE_CRDB" "$BASE_TAGS" "26.7.2" CRDB_ADOPT_NEW_STREAMS=0
check "new stream not adopted" "" "$(crdb_got)"

echo
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
