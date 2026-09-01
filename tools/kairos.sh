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
  go)
    : > "$(kairos_partition "$uuid")/pass.once"
    echo "kairos: the next prompt goes through, then the gate re-arms."
    ;;
  stop)
    rm -f "$(kairos_partition "$uuid")/stash"
    echo "kairos: stashed prompt dropped."
    ;;
  *)
    printf 'kairos: unknown command "%s"\n' "${1:-}" >&2
    printf 'usage: kairos [report|accounts|alias <name>|wait|go|stop]\n' >&2
    exit 1
    ;;
esac
