#!/usr/bin/env bash
# The /kairos command. Everything the user can ask kairos directly.
set -uo pipefail

KAIROS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBDIR="$KAIROS_ROOT/hooks/scripts/lib"
# shellcheck source=/dev/null
. "$LIBDIR/common.sh"
kairos_config_load
for lib in account meter wall predict format waiter; do
  # shellcheck source=/dev/null
  . "$LIBDIR/$lib.sh"
done

if ! kairos_have_jq; then
  echo "kairos needs jq, which is not on PATH." >&2
  exit 1
fi

uuid=$(kairos_active_account) || true
# Establish the account before anything reads it. `first_seen` is the point
# from which this account's recorded refusals are trusted, and with it unset
# nothing is attributable at all, so an account whose hooks have never fired
# would otherwise stay permanently uncalibrated when driven from the CLI.
kairos_account_record "$uuid"

case "${1:-report}" in
  report)
    kairos_refresh "$uuid"
    kairos_prune "$uuid"
    kairos_report "$uuid"
    ;;
  accounts)
    kairos_refresh "$uuid"
    kairos_accounts_report "$uuid"
    ;;
  alias)
    shift
    if [ -z "${1:-}" ]; then
      echo "kairos: alias needs a name" >&2
      exit 1
    fi
    kairos_meta_set "$(kairos_partition "$uuid")" alias "$*"
    printf 'kairos: this account is now called "%s"\n' "$*"
    ;;
  wait)
    # shellcheck disable=SC2034  # only wend is used, the rest consume fields
    read -r wstart wend wused <<EOF
$(kairos_block "$uuid")
EOF
    if [ "$wend" -le "$(kairos_now)" ]; then
      echo "kairos: the window has already reset, nothing to wait for."
      exit 0
    fi
    kairos_waiter_arm "$uuid" "$wend"
    printf 'kairos: holding. You will be told in %s, when the window resets.\n' \
      "$(kairos_duration $((wend - $(kairos_now))))"
    ;;
  calibrate)
    kairos_refresh "$uuid"
    part=$(kairos_partition "$uuid")
    # A full rescan rather than the last day, since a wall stays useful as
    # calibration long after the ledger has rotated past it.
    kairos_harvest_walls "$uuid" -type f
    used=0
    [ -f "$part/walls.tsv" ] && used=$(wc -l < "$part/walls.tsv" | tr -d ' ')
    aside=0
    [ -f "$part/walls.unattributed.tsv" ] && aside=$(wc -l < "$part/walls.unattributed.tsv" | tr -d ' ')
    if [ "$used" = "1" ]; then
      printf 'kairos: 1 wall calibrating this account.\n'
    else
      printf 'kairos: %s walls calibrating this account.\n' "$used"
    fi
    # Reflowed to the width every view is drawn to, so the paragraph ends where
    # the report's rule ends rather than four columns past it.
    if [ "$aside" -gt 0 ]; then
      printf '        %s unattributed and not used. A refusal\n' "$aside"
      printf '        is set aside when it predates kairos on\n'
      printf '        this account, so it may belong to another\n'
      printf '        subscription, or when it is older than the\n'
      printf '        consumption history and there is nothing\n'
      printf '        left to measure it against.\n'
    fi
    printf '\n'
    kairos_report "$uuid"
    ;;
  go)
    kairos_gopart=$(kairos_partition "$uuid")
    # A held prompt is handed straight back to the model rather than printed
    # for the user to type again. This is the same move SessionStart already
    # makes when a wait comes due, and the two branches out of a refusal should
    # not differ in how much work they leave you.
    #
    # No one-shot pass is armed on this path, deliberately. The resumed request
    # runs inside the turn already in flight, so there is no next prompt to
    # consume the pass, and one left armed would wave through something
    # unrelated later without saying so.
    if [ -s "$kairos_gopart/stash" ]; then
      echo "kairos: the gate is open for this turn, and a prompt was held back."
      echo "Carry out the request below as if the user had just sent it."
      echo "Do not print it back to them first, and do not mention this notice."
      echo
      cat "$kairos_gopart/stash"
      echo
      rm -f "$kairos_gopart/stash"
    else
      : > "$kairos_gopart/pass.once"
      echo "kairos: nothing was held back, so the next prompt goes through and"
      echo "        the gate re-arms behind it."
    fi
    ;;
  stop)
    rm -f "$(kairos_partition "$uuid")/stash"
    echo "kairos: stashed prompt dropped."
    ;;
  *)
    printf 'kairos: unknown command "%s"\n' "${1:-}" >&2
    printf 'usage: kairos [report|accounts|alias <name>|wait|go|stop|calibrate]\n' >&2
    exit 1
    ;;
esac
