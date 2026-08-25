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

# --- 4. credentials ------------------------------------------------------
# Reported, never set: these are credentials and belong in a human's hands.
#
# They live in environments, not in repo- or organization-wide secrets. This fork
# carries every one of upstream's workflows on every *_crdb branch, two of them
# pull_request_target, so a repo-wide secret is readable by anything that ever
# runs here -- including a workflow upstream adds later that the disable step
# above has never seen. An environment secret is readable only by a job that
# declares that environment, and only on the branch its policy allows.
#
# So a repo-wide secret existing is a finding here, not a pass.
echo
log "credentials:"
missing=0
for e in agent publish; do
    names=$(gh secret list --repo "$REPO" --env "$e" --json name \
        --jq '[.[].name]|join(", ")' 2>/dev/null || true)
    if [ -n "$names" ]; then
        printf '      \033[32mset\033[0m      env %-10s %s\n' "$e" "$names"
    else
        printf '      \033[31mMISSING\033[0m  env %-10s no secrets set -- see README.md\n' "$e"
        missing=$((missing+1))
    fi
done

REPO_WIDE=$(gh api "repos/$REPO/actions/secrets" --jq '.total_count' 2>/dev/null || echo "?")
if [ "$REPO_WIDE" = "0" ]; then
    printf '      \033[32mok\033[0m       %-14s no repo-wide secrets\n' ""
else
    printf '      \033[31mFINDING\033[0m  %-14s %s repo-wide secret(s): readable by ANY workflow\n' \
        "" "$REPO_WIDE"
    warn "Repo-wide secrets defeat the environment scoping. Move them into the"
    warn "'agent' or 'publish' environment and delete the repo-level copies."
    missing=$((missing+1))
fi

# Organization secrets need admin:org to enumerate, so this cannot be asserted
# from here. It is worth stating because revoking the org grant is the step that
# actually removed the exposure, and it is easy to re-add by accident.
log "organization grant: not checkable without admin:org -- confirm"
log "$(printf '%s' "${REPO}") is NOT in the repository access list for the"
log "$(printf '%s' "${REPO%%/*}") org's QUAY_*/ANTHROPIC secrets."

[ "$missing" -gt 0 ] && echo && warn "$missing credential problem(s) above."

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
