#!/usr/bin/env bash
# SessionStart: work out which account is paying, and bring the meter up to
# date before the first prompt needs an answer.
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
. "$KAIROS_DIR/lib/wall.sh"

payload=$(cat 2>/dev/null || true)
session=""
if kairos_have_jq && [ -n "$payload" ]; then
  session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
fi
[ -n "$session" ] || session="unknown"
session=$(kairos_safe_id "$session")

uuid=$(kairos_active_account) || true
kairos_account_record "$uuid"

kairos_ensure_dir "$KAIROS_HOME/sessions" || exit 0
printf '%s\n' "$uuid" > "$KAIROS_HOME/sessions/$session"

# A Stop hook killed between claiming a turn marker and deleting it leaves the
# claimed file behind. It is inert, nothing ever reads it, but it should not
# accumulate forever on a long lived machine, and the start of a session is the
# natural moment to clear what an earlier one abandoned.
#
# stop.sh touches each claim as it makes it, so this age is measured from the
# claim itself. Without that touch the claim would inherit the turn's start
# time and a long turn's live claim could be swept while it was still in use.
find "$(kairos_partition "$uuid")" -name 'turn.start.claimed.*' -mmin +60 \
  -exec rm -f {} + 2>/dev/null

kairos_refresh "$uuid"
kairos_prune "$uuid"
kairos_harvest_walls "$uuid"
exit 0
