#!/usr/bin/env bash
# The README goes stale silently: a setting gets added and never written down,
# a count stops matching, a subcommand appears with no mention. All cheap to
# check, so they are checked rather than trusted.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

note() { printf '  %s\n' "$1"; }
bad() { printf '  MISMATCH %s\n' "$1"; status=1; }

# Every KAIROS_* setting that common.sh gives a default must appear in the
# README. The extraction is asserted below, because a pattern that silently
# matches nothing would turn this whole gate into a no-op that always passes.
settings=$(grep -o 'KAIROS_[A-Z_]*:=' "$ROOT/hooks/scripts/lib/common.sh" | sed 's/:=$//' | sort -u)
count=$(printf '%s\n' "$settings" | grep -c 'KAIROS_')
if [ "$count" -lt 5 ]; then
  bad "only $count settings extracted from common.sh, the pattern is broken"
else
  note "$count settings found in common.sh"
fi

for var in $settings; do
  if grep -q "$var" "$ROOT/README.md"; then
    note "documented $var"
  else
    bad "$var is not in the README"
  fi
done

# Every kairos.sh subcommand must appear in the README.
subs=$(awk '/^  [a-z]+\)$/ { gsub(/[ )]/, ""); print }' "$ROOT/tools/kairos.sh" | sort -u)
subcount=$(printf '%s\n' "$subs" | grep -c '[a-z]')
if [ "$subcount" -lt 3 ]; then
  bad "only $subcount subcommands extracted from kairos.sh, the pattern is broken"
else
  note "$subcount subcommands found in kairos.sh"
fi

for cmd in $subs; do
  if grep -q "kairos $cmd" "$ROOT/README.md"; then
    note "documented /kairos $cmd"
  else
    bad "/kairos $cmd is not in the README"
  fi
done

# The published assertion count must match what the suite actually runs.
claimed=$(grep -o 'tests-[0-9]*%20passing' "$ROOT/README.md" | grep -o '[0-9]*' | head -1)
actual=$(bash "$ROOT/tests/run.sh" 2>/dev/null | awk '/passed,/ { print $1 }')
if [ -z "$claimed" ]; then
  bad "the README has no test count badge"
elif [ "$claimed" = "$actual" ]; then
  note "assertion count matches ($actual)"
else
  bad "README claims $claimed assertions, the suite runs $actual"
fi

exit "$status"
