#!/usr/bin/env bash
# The /kairos command. Everything the user can ask kairos directly.
set -uo pipefail

KAIROS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBDIR="$KAIROS_ROOT/hooks/scripts/lib"
# shellcheck source=/dev/null
. "$LIBDIR/common.sh"
kairos_config_load
for lib in account meter wall predict format; do
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
  *)
    printf 'kairos: unknown command "%s"\n' "${1:-}" >&2
    printf 'usage: kairos [report]\n' >&2
    exit 1
    ;;
esac
