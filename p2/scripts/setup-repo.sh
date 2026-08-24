#!/usr/bin/env bash
#
# Switch the automation on. Reports by default; changes nothing without --apply.
#
# There is a trap here worth understanding before running it. This fork carries
# all 21 of upstream's workflows, and they are all marked active. Actions is
# currently disabled at the repository level, which is the only reason none of
# them has ever run. Turning Actions on without doing anything else would:
#
#   - start upstream's nightly schedules on this fork, and
#   - make any human push to a *_crdb branch trigger a full Keycloak CI run,
#     because ci.yml triggers on push to every branch except main.
#
# So the order below matters:
#
#   1. Point the default branch at p2-ci, while Actions is still off. Scheduled
#      and dispatched workflows only come from the default branch, and p2-ci does
#      not contain upstream's workflows -- so this alone stops the cron problem,
#      with zero risk while Actions is off.
#   2. Enable Actions.
#   3. Disable every workflow that is not one of ours. This covers the push
#      triggers, which are evaluated from the pushed branch rather than the
#      default one. (Our own pushes use GITHUB_TOKEN, which by design does not
#      trigger workflows, but a human pushing a branch by hand would.)
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

log "repository: $REPO"
[ "$APPLY" = "1" ] && warn "--apply given: changes WILL be made" \
                   || log "report only -- re-run with --apply to make changes"
echo

# --- 1. default branch ----------------------------------------------------
CURRENT_DEFAULT=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)
if ! git ls-remote --exit-code --heads "https://github.com/${REPO}.git" "refs/heads/$BRANCH" >/dev/null 2>&1; then
    die "branch '$BRANCH' does not exist in $REPO -- push it before running this"
fi
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

# --- 2. Actions enabled ---------------------------------------------------
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

# --- 3. upstream workflows off -------------------------------------------
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

# --- 4. secrets ----------------------------------------------------------
# Reported, never set: these are credentials and belong in a human's hands.
echo
log "required secrets:"
HAVE=$(gh secret list --repo "$REPO" --json name --jq '.[].name' 2>/dev/null || true)
missing=0
check_secret() {
    local name=$1 why=$2 optional=${3:-}
    if in_list "$name" "$HAVE"; then
        printf '      \033[32mset\033[0m      %-26s %s\n' "$name" "$why"
    elif [ -n "$optional" ]; then
        printf '      \033[33mmissing\033[0m  %-26s %s (optional)\n' "$name" "$why"
    else
        printf '      \033[31mMISSING\033[0m  %-26s %s\n' "$name" "$why"
        missing=$((missing+1))
    fi
}
check_secret QUAY_USERNAME    "push images to quay.io"
check_secret QUAY_ROBOT_TOKEN "push images to quay.io"
# Either auth method works; the workflow passes both and the unset one is empty.
if in_list ANTHROPIC_API_KEY "$HAVE" || in_list CLAUDE_CODE_OAUTH_TOKEN "$HAVE"; then
    printf '      \033[32mset\033[0m      %-26s %s\n' "ANTHROPIC_API_KEY" \
        "or CLAUDE_CODE_OAUTH_TOKEN -- resolve ports that need judgement"
else
    printf '      \033[31mMISSING\033[0m  %-26s %s\n' "ANTHROPIC_API_KEY" \
        "or CLAUDE_CODE_OAUTH_TOKEN -- resolve ports that need judgement"
    missing=$((missing+1))
fi
[ "$missing" -gt 0 ] && echo && warn "$missing secret(s) missing. Set them with:" \
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
