#!/usr/bin/env bash
# Stop: the turn is over, so record what it actually cost.
#
# This is the only place a true turn cost is known, and the predictor is built
# entirely from what this writes.
set -uo pipefail

KAIROS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$KAIROS_DIR/lib/common.sh"
kairos_config_load
# shellcheck source=/dev/null
. "$KAIROS_DIR/lib/account.sh"
# shellcheck source=/dev/null
. "$KAIROS_DIR/lib/meter.sh"
# shellcheck source=/dev/null
. "$KAIROS_DIR/lib/predict.sh"

payload=$(cat 2>/dev/null || true)
session=""
if kairos_have_jq && [ -n "$payload" ]; then
  session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
fi

uuid=$(kairos_active_account) || true
part=$(kairos_partition "$uuid") || exit 0
session=$(kairos_safe_id "$session")
marker="$part/turn.start.$session"
[ -f "$marker" ] || exit 0

# Claim the marker by renaming it. mv is atomic within a directory, so if two
# Stop hooks race, exactly one gets the turn and the other finds nothing to do.
# Reading and then deleting would let both read the same marker and record the
# turn twice, which does not error, it just quietly biases every later
# prediction.
claimed="$marker.claimed.$$"
mv "$marker" "$claimed" 2>/dev/null || exit 0
# mv preserves mtime, so without this the claim inherits the turn's start time
# and a long turn's claim looks stale the moment it is created. The sweep in
# session-start.sh ages claims from this touch, not from the turn.
touch "$claimed" 2>/dev/null

started=$(awk -F'\t' 'NR == 1 { print $1 }' "$claimed")
marked_session=$(awk -F'\t' 'NR == 1 { print $2 }' "$claimed")
rm -f "$claimed"
[ -n "$started" ] || exit 0

# A marker whose epoch is not a number would make the comparison below fall
# back to string semantics and silently score the turn as free. Recording
# nothing is the honest outcome; recording zero would poison the predictor.
case "$started" in
  ''|*[!0-9]*) exit 0 ;;
esac

[ -n "$session" ] || session=$marked_session

kairos_refresh "$uuid"
kairos_prune "$uuid"

spent=0
if [ -f "$part/ledger.tsv" ]; then
  spent=$(awk -F'\t' -v s="$started" -v sess="$session" \
    '$1 >= s && $3 == sess { t += $5 } END { printf "%d", t + 0 }' "$part/ledger.tsv")
fi
kairos_record_turn "$uuid" "$session" "$spent"
exit 0
