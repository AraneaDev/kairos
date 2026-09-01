#!/usr/bin/env bash
# One view, printed to stdout, for tools/screenshot.sh to photograph. A script
# rather than a function because the capture runs it as its own command, and
# because the gate is itself a hook script that has to be invoked as one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBDIR="$ROOT/hooks/scripts/lib"
# shellcheck source=/dev/null
. "$LIBDIR/common.sh"
kairos_config_load
for lib in account meter wall predict format waiter; do
  # shellcheck source=/dev/null
  . "$LIBDIR/$lib.sh"
done

uuid=$(kairos_active_account) || true

case "${1:-report}" in
  report)
    kairos_report "$uuid"
    ;;
  accounts)
    kairos_accounts_report "$uuid"
    ;;
  gate)
    # The gate refuses on stderr and exits 2, which is the whole point of it,
    # so both are expected here rather than treated as a failure.
    printf '{"session_id":"shot","prompt":"finish the refactor and run the suite"}' \
      | bash "$ROOT/hooks/scripts/user-prompt-submit.sh" 2>&1 || true
    ;;
  *)
    echo "screenshot-view: unknown view \"${1:-}\"" >&2
    exit 1
    ;;
esac
