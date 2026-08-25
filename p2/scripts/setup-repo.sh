#!/usr/bin/env bash
#
# Switch the automation on. Reports by default; changes nothing without --apply.
#
# There is a trap here worth understanding before running it. This fork carries
# all 21 of upstream's workflows, and they are all marked active. Actions is
# disabled at the repository level, which is the only reason none of them has
# ever run. Turning Actions on without doing anything else would make any human
# push to a *_crdb branch trigger a full Keycloak CI run: GitHub reads workflow
# files for a `push` event from the *pushed branch*, not the default branch, and
# upstream's ci.yml triggers on push to every branch except main. (Our own pushes
# use GITHUB_TOKEN, which by design does not trigger workflows.)
#
# So the order below matters, and it is the opposite of what seems natural:
#
#   1. Enable Actions.
#   2. Disable every workflow that is not one of ours -- immediately, in the same
#      run. This has to happen while `main` is still the default branch: the
#      workflow list GitHub will let you disable is indexed from the default
#      branch, so moving the default to p2-ci first risks de-indexing upstream's
#      21 workflows and leaving no handle to switch them off. That risk is
#      permanent; the window opened by step 1 is a few seconds.
#   3. Point the default branch at p2-ci. Scheduled and dispatched workflows only
#      run from the default branch, so this is what makes our workflows -- and
#      only ours -- the ones that fire.
#
# The step-1 window is small and doubly mitigated: `schedule` is the only trigger
# that could fire unprompted, and nothing pushes during a setup run.
#
# Usage:
#   p2/scripts/setup-repo.sh              # report what would change
#   p2/scripts/setup-repo.sh --apply      # do it
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd gh git jq

APPLY=0
BRANCH="p2-ci"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  APPLY=1; shift ;;
        --branch) BRANCH=${2:?}; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

REPO=${P2_REPO:-p2-inc/keycloak}
CHANGES=0
step() { CHANGES=$((CHANGES+1)); printf '\033[1;36m[%d]\033[0m %s\n' "$CHANGES" "$*"; }
would() { [ "$APPLY" = "1" ] && return 1 || return 0; }

gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"

# Checked before anything is changed: bailing out here after enabling Actions
# would leave the repository in the one state we are trying to avoid -- Actions
# on, upstream's workflows live, default branch still main.
git ls-remote --exit-code --heads "https://github.com/${REPO}.git" "refs/heads/$BRANCH" >/dev/null 2>&1 \
    || die "branch '$BRANCH' does not exist in $REPO -- push it before running this"

log "repository: $REPO"
[ "$APPLY" = "1" ] && warn "--apply given: changes WILL be made" \
                   || log "report only -- re-run with --apply to make changes"
echo

# --- 1. Actions enabled ---------------------------------------------------
ACTIONS_ENABLED=$(gh api "repos/$REPO/actions/permissions" --jq .enabled)
if [ "$ACTIONS_ENABLED" = "true" ]; then
    log "Actions is already enabled"
else
    step "enable Actions"
    if ! would; then
        gh api -X PUT "repos/$REPO/actions/permissions" \
            -F enabled=true -f allowed_actions=all >/dev/null
        log "Actions enabled"
    fi
fi

# --- 2. upstream workflows off -------------------------------------------
# Everything whose file is not .github/workflows/p2-*.yml. Listing needs Actions
# enabled, so on a first --apply run this happens after step 2.
if [ "$ACTIONS_ENABLED" = "true" ] || [ "$APPLY" = "1" ]; then
    # while-read rather than mapfile: this script gets run from a developer's
    # Mac, where bash is still 3.2 and mapfile does not exist.
    FOREIGN=()
    while IFS= read -r row; do
        [ -n "$row" ] && FOREIGN+=("$row")
    done < <(gh api --paginate "repos/$REPO/actions/workflows" \
        --jq '.workflows[] | select(.path | test("\\.github/workflows/p2-") | not)
              | select(.state == "active") | "\(.id)\t\(.name)"' 2>/dev/null || true)
    if [ "${#FOREIGN[@]}" -eq 0 ]; then
        log "no active non-p2 workflows"
    else
        step "disable ${#FOREIGN[@]} upstream workflow(s)"
        for row in "${FOREIGN[@]+"${FOREIGN[@]}"}"; do
            id=${row%%$'\t'*}; name=${row#*$'\t'}
            if would; then
                echo "      - $name"
            else
                gh api -X PUT "repos/$REPO/actions/workflows/$id/disable" >/dev/null \
                    && echo "      disabled: $name" \
                    || warn "could not disable: $name"
            fi
        done
    fi
else
    warn "cannot list workflows until Actions is enabled; re-run after --apply"
fi

# --- 3. default branch ----------------------------------------------------
CURRENT_DEFAULT=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)
if [ "$CURRENT_DEFAULT" = "$BRANCH" ]; then
    log "default branch is already '$BRANCH'"
else
    step "default branch: '$CURRENT_DEFAULT' -> '$BRANCH'"
    if would; then
        echo "      (main stays a pristine upstream mirror; only the default pointer moves)"
    else
        gh api -X PATCH "repos/$REPO" -f default_branch="$BRANCH" >/dev/null
        log "default branch is now '$BRANCH'"
    fi
fi

# --- 4. secrets ----------------------------------------------------------
# Reported, never set: these are credentials and belong in a human's hands.
#
# Organization secrets count and are the established pattern here -- the Quay
# credentials phasetwo-containers pushes with are org-level, not repo-level. They
# are also invisible to this check unless the token carries admin:org, so a
# repo-level miss is reported as "not repo-level", never as "missing". Getting
# that wrong would send someone off to re-set secrets that are already working.
echo
log "required secrets:"
HAVE=$(gh secret list --repo "$REPO" --json name --jq '.[].name' 2>/dev/null || true)
ORG=${REPO%%/*}
# Keyed on exit status, not on emptiness: `gh api --jq` prints the API error
# body to *stdout* on a 403, so a permission failure looks like a populated
# list of one very strange secret name.
if ORG_HAVE=$(gh api "orgs/$ORG/actions/secrets" --jq '.secrets[].name' 2>/dev/null); then
    ORG_VISIBLE=1
else
    ORG_VISIBLE=0
    ORG_HAVE=""
    log "organization secrets are not readable with this token (needs admin:org)."
    log "Anything below marked '?' may already be set on the $ORG org."
fi
missing=0
# repo | org | unknown | MISSING -- "unknown" only when the org cannot be read.
secret_state() {
    local name=$1
    in_list "$name" "$HAVE"     && { echo repo; return; }
    in_list "$name" "$ORG_HAVE" && { echo org;  return; }
    [ "$ORG_VISIBLE" = "0" ] && { echo unknown; return; }
    echo missing
}
report_secret() {
    local name=$1 why=$2 state=$3
    case "$state" in
        repo)    printf '      \033[32mset\033[0m      %-26s %s\n' "$name" "$why" ;;
        org)     printf '      \033[32mset\033[0m      %-26s %s (org secret)\n' "$name" "$why" ;;
        unknown) printf '      \033[33m?\033[0m        %-26s %s (not repo-level; check the %s org)\n' \
                     "$name" "$why" "$ORG" ;;
        *)       printf '      \033[31mMISSING\033[0m  %-26s %s\n' "$name" "$why"
                 missing=$((missing+1)) ;;
    esac
}
check_secret() {
    report_secret "$1" "$2" "$(secret_state "$1")"
}
check_secret QUAY_USERNAME    "push images to quay.io"
check_secret QUAY_ROBOT_TOKEN "push images to quay.io"
# Either auth method works; the workflow passes both and the unset one is empty.
# Either auth method works; the workflow passes both and the unset one is empty.
AI_WHY="or CLAUDE_CODE_OAUTH_TOKEN -- resolve ports that need judgement"
a=$(secret_state ANTHROPIC_API_KEY); b=$(secret_state CLAUDE_CODE_OAUTH_TOKEN)
case "$a $b" in
    *repo*)    report_secret ANTHROPIC_API_KEY "$AI_WHY" repo ;;
    *org*)     report_secret ANTHROPIC_API_KEY "$AI_WHY" org ;;
    *unknown*) report_secret ANTHROPIC_API_KEY "$AI_WHY" unknown ;;
    *)         report_secret ANTHROPIC_API_KEY "$AI_WHY" missing ;;
esac
[ "$missing" -gt 0 ] && echo && warn "$missing secret(s) not set anywhere. Set them with:" \
    && echo "      gh secret set QUAY_USERNAME --repo $REPO" \
    && echo "      gh secret set QUAY_ROBOT_TOKEN --repo $REPO" \
    && echo "      gh secret set ANTHROPIC_API_KEY --repo $REPO"

# --- 5. what to do next --------------------------------------------------
echo
if would && [ "$CHANGES" -gt 0 ]; then
    log "$CHANGES change(s) pending. Re-run with --apply."
else
    log "configuration is in place."
fi
cat <<'NEXT'

Once the secrets are set, verify without publishing anything:

  # what would the poller do right now?
  gh workflow run p2-upstream-poll.yml -f dry_run=true
  # a full port + build + CockroachDB smoke test, publishing nothing
  gh workflow run p2-crdb-release.yml -f version=26.7.2 -f dry_run=true

Then, for a real end-to-end push, pick a tag that has no branch yet, or
re-publish one that does:

  gh workflow run p2-vanilla-release.yml -f version=26.7.2
NEXT
