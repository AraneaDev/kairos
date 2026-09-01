#!/usr/bin/env bash
# UserPromptSubmit: the gate.
#
# Exit 0 with nothing on stdout lets the prompt through. Anything printed to
# stdout here would be injected into the model's context, so the passing path
# stays silent. Exit 2 refuses the prompt and shows stderr to the user.
#
# Every uncertain branch passes. Being wrong about the budget is a nuisance;
# blocking work because the meter broke is worse than having no meter.
set -uo pipefail

KAIROS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$KAIROS_DIR/lib/common.sh"
kairos_config_load
for lib in account meter wall predict format; do
  # shellcheck source=/dev/null
  . "$KAIROS_DIR/lib/$lib.sh"
done

kairos_have_jq || exit 0

payload=$(cat 2>/dev/null || true)
session=$(printf '%s' "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
prompt=$(printf '%s' "$payload" | jq -r '.prompt // ""' 2>/dev/null)
[ -n "$session" ] || session="unknown"

# kairos's own commands are submitted as ordinary prompts, so without this the
# gate refuses the very commands its refusal message tells you to run, and the
# stash below overwrites the held prompt with the word you typed to rescue it.
# There is no recovery from inside the product once that happens.
case "$prompt" in
  /kairos*|kairos\ *) exit 0 ;;
esac

session=$(kairos_safe_id "$session")

bound=""
if [ -f "$KAIROS_HOME/sessions/$session" ]; then
  bound=$(cat "$KAIROS_HOME/sessions/$session" 2>/dev/null)
fi

# The live account decides which budget this prompt spends, not the binding
# written when the session started. A /login part way through a session moves
# it, and stop.sh already records the turn against whoever is live, so a gate
# reading a stale binding would weigh one subscription's spending against the
# other's ceiling. That is the precise failure this partitioning exists to
# prevent, and on a machine with a Pro and a Max plan the two ceilings differ
# by roughly four times.
#
# When the live account cannot be read at all, keep the existing binding
# rather than dropping the session into the unknown bucket.
if uuid=$(kairos_active_account); then
  if [ "$uuid" != "$bound" ]; then
    kairos_account_record "$uuid"
    if kairos_ensure_dir "$KAIROS_HOME/sessions"; then
      printf '%s\n' "$uuid" > "$KAIROS_HOME/sessions/$session" 2>/dev/null || true
    fi
  fi
else
  uuid=${bound:-unknown}
fi
part=$(kairos_partition "$uuid") || exit 0

start_turn() {
  printf '%s\t%s\n' "$(kairos_now)" "$session" > "$part/turn.start" 2>/dev/null || true
  exit 0
}

# An override spends itself, then the gate re-arms.
if [ -f "$part/pass.once" ]; then
  rm -f "$part/pass.once"
  start_turn
fi
[ "$KAIROS_GATE" = "1" ] || start_turn

kairos_refresh "$uuid"
kairos_prune "$uuid"

# shellcheck disable=SC2034  # bstart is read to consume the field
read -r bstart bend bused <<EOF
$(kairos_block "$uuid")
EOF
# shellcheck disable=SC2034  # blow is read to consume the field
read -r blow bhigh bconf <<EOF
$(kairos_band "$uuid")
EOF
predicted=$(kairos_predict "$uuid" "$session")

# An account that has never recorded a refusal has no ceiling to measure
# against, so kairos reports and stays out of the way. It earns the right to
# interrupt by observing a wall of this account's own, never by guessing one.
[ "$bconf" -gt 0 ] || start_turn

# Gate against the optimistic edge, so kairos stays quiet until even a generous
# ceiling is threatened. This lets a first wall happen rather than interrupting
# wrongly for a month, which is the trade the design chose on purpose.
remaining=$((bhigh - bused))
needed=$((predicted * KAIROS_RESERVE))
[ "$remaining" -lt "$needed" ] || start_turn

printf '%s' "$prompt" > "$part/stash" 2>/dev/null || true

now=$(kairos_now)
{
  printf 'kairos: predicted ~%s. %s left before the optimistic wall,\n' \
    "$(kairos_human "$predicted")" "$(kairos_human "$remaining")"
  printf '        resets in %s.\n\n' "$(kairos_duration $((bend - now)))"
  other=$(kairos_other_clear_account "$uuid")
  if [ -n "$other" ]; then
    printf '  %s block looks clear.\n\n' "$(kairos_account_label "$other")"
  fi
  printf '  /kairos wait   hold, and tell me when the window resets\n'
  printf '  /kairos go     send it anyway\n'
  printf '  /kairos stop   drop it\n'
  if [ -n "$other" ]; then
    printf '  → to switch, run /login yourself\n'
  fi
} >&2
exit 2
