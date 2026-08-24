#!/usr/bin/env bash
#
# Regenerate p2/baseline-tags.txt from the upstream tag list as it stands now.
#
# Only run this when re-activating the automation from scratch. Running it
# routinely would silently mark every pending tag as already handled -- the
# opposite of what the file is for.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd git

OUT="$P2_ROOT/p2/baseline-tags.txt"

if [ -f "$OUT" ] && [ "${FORCE:-0}" != "1" ]; then
    warn "$OUT already exists."
    warn "Overwriting marks every currently-pending tag as already handled."
    warn "Re-run with FORCE=1 if that is really what you want."
    exit 1
fi

log "snapshotting upstream release tags"
{
    sed -n '1,/^# *Generated/p' "$OUT" 2>/dev/null | sed '$d' || true
    printf '#\n# Generated %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    upstream_tags
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
log "wrote $(grep -cvE '^\s*(#|$)' "$OUT") tags to $OUT"
