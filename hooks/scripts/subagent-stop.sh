#!/usr/bin/env bash
# SubagentStop: note which account paid for a subagent's transcript.
#
# Subagent transcripts are written to a subagents/ directory beside the parent
# and state no owner of their own. They are also the bulk of what is on disk:
# 1050 of 1216 files on the machine this was written against. Everything else
# kairos knows about ownership is reconstructed from the transcripts, and for
# these there is nothing in them to reconstruct it from.
#
# This hook is the exception. It fires inside the session that just spent the
# tokens, while the account paying for them is live, and its payload names the
# file. That is observed, not inferred, and it is the whole reason this hook
# exists.
#
# It deliberately does no metering. A subagent stops far more often than a
# turn does, and the next refresh reads the same bytes anyway, correctly
# attributed because of the line written here.
set -uo pipefail

KAIROS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$KAIROS_DIR/lib/common.sh"
kairos_config_load
# shellcheck source=/dev/null
. "$KAIROS_DIR/lib/account.sh"

kairos_have_jq || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

uuid=$(kairos_active_account) || true

# Both paths, because the parent is spending on this turn too and a session
# that has never reached a Stop hook would otherwise have no binding at all.
for kairos_key in agent_transcript_path transcript_path; do
  kairos_path=$(printf '%s' "$payload" | jq -r --arg k "$kairos_key" '.[$k] // empty' 2>/dev/null)
  [ -n "$kairos_path" ] || continue
  kairos_bind_path "$uuid" "$kairos_path" || true
done

exit 0
