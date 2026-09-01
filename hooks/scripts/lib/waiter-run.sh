#!/usr/bin/env bash
# The detached half of the waiter. Sleeps out the block, then fires.
set -uo pipefail
KAIROS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$KAIROS_DIR/common.sh"
# shellcheck source=/dev/null
. "$KAIROS_DIR/account.sh"
# shellcheck source=/dev/null
. "$KAIROS_DIR/waiter.sh"

uuid=${1:-unknown}
wake=${2:-0}
remaining=$((wake - $(kairos_now)))
if [ "$remaining" -gt 0 ]; then
  sleep "$remaining"
fi
kairos_waiter_fire "$uuid"
