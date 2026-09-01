#!/usr/bin/env bash
# SessionEnd: one closing line on where the window stands.
#
# Like every hook here, it exits 0 whatever happens. A summary is a courtesy,
# and a courtesy must never be the reason a session ends badly.
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

uuid=$(kairos_active_account) || true
kairos_refresh "$uuid"
kairos_prune "$uuid"

# Nothing spent means nothing worth saying.
# shellcheck disable=SC2034  # only sused is used, the rest consume fields
read -r sstart send sused <<EOF
$(kairos_block "$uuid")
EOF
[ "${sused:-0}" -gt 0 ] || exit 0

kairos_summary_line "$uuid" 2>/dev/null || true
exit 0
