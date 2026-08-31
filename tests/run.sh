#!/usr/bin/env bash
# Test suite for kairos. Plain bash, no framework, no dependency the plugin
# does not already need.
#
#   bash tests/run.sh
#
# Every test runs against a temp KAIROS_HOME, a temp fake ~/.claude.json and a
# temp projects directory, so a run never touches real state.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
LIB="$ROOT/hooks/scripts/lib"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }

is() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label" "$expected" "$actual"; fi
}

contains() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" "something containing '$needle'" "$haystack" ;;
  esac
}

asserts() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label" "exit 0" "non-zero exit"; fi
}

refutes() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$label" "non-zero exit" "exit 0"; else pass "$label"; fi
}

# A test environment is a temp tree standing in for the three real paths the
# plugin reads. Exported, because hook entrypoints run as separate processes.
setup_env() {
  KAIROS_TESTDIR=$(mktemp -d "${TMPDIR:-/tmp}/kairos-test.XXXXXX")
  export KAIROS_TESTDIR
  export KAIROS_HOME="$KAIROS_TESTDIR/state"
  export KAIROS_CLAUDE_JSON="$KAIROS_TESTDIR/claude.json"
  export KAIROS_PROJECTS_DIR="$KAIROS_TESTDIR/projects"
  mkdir -p "$KAIROS_HOME" "$KAIROS_PROJECTS_DIR"
  printf '{"oauthAccount":{"accountUuid":"aaaaaaaa-1111-2222-3333-444444444444","organizationType":"claude_pro","organizationRateLimitTier":"default_claude","emailAddress":"nobody@example.com"}}\n' > "$KAIROS_CLAUDE_JSON"
}

teardown_env() {
  [ -n "${KAIROS_TESTDIR:-}" ] && rm -rf "$KAIROS_TESTDIR"
  return 0
}

echo "harness"
setup_env
is "setup_env creates a state dir" "yes" "$([ -d "$KAIROS_HOME" ] && echo yes || echo no)"
is "setup_env writes a fake claude.json" "yes" "$([ -f "$KAIROS_CLAUDE_JSON" ] && echo yes || echo no)"
teardown_env

echo
echo "lib/common.sh"
setup_env
# shellcheck source=/dev/null
. "$LIB/common.sh"

is "KAIROS_HOME honours the environment" "$KAIROS_TESTDIR/state" "$KAIROS_HOME"
is "block length defaults to five hours" "18000" "$KAIROS_BLOCK_SECONDS"
is "the seeded band low edge" "4100000" "$KAIROS_SEED_LOW"
is "the seeded band high edge" "5700000" "$KAIROS_SEED_HIGH"

now=$(kairos_now)
case "$now" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) pass "kairos_now prints an epoch" ;;
  *) fail "kairos_now prints an epoch" "at least nine digits" "$now" ;;
esac

is "kairos_size_of on a missing file" "0" "$(kairos_size_of "$KAIROS_TESTDIR/nope")"
printf '12345' > "$KAIROS_TESTDIR/five"
is "kairos_size_of counts bytes" "5" "$(kairos_size_of "$KAIROS_TESTDIR/five")"

kairos_ensure_dir "$KAIROS_TESTDIR/a/b/c"
is "kairos_ensure_dir creates nested dirs" "yes" "$([ -d "$KAIROS_TESTDIR/a/b/c" ] && echo yes || echo no)"
asserts "kairos_ensure_dir is idempotent" kairos_ensure_dir "$KAIROS_TESTDIR/a/b/c"
teardown_env

echo
echo "lib/account.sh"
setup_env
# shellcheck source=/dev/null
. "$LIB/common.sh"
# shellcheck source=/dev/null
. "$LIB/account.sh"

is "reads the active account uuid" "aaaaaaaa-1111-2222-3333-444444444444" "$(kairos_active_account)"

part=$(kairos_partition "aaaaaaaa-1111-2222-3333-444444444444")
is "partition path" "$KAIROS_HOME/accounts/aaaaaaaa-1111-2222-3333-444444444444" "$part"
is "partition directory is created" "yes" "$([ -d "$part" ] && echo yes || echo no)"

kairos_account_record "aaaaaaaa-1111-2222-3333-444444444444"
is "records the organisation type" "claude_pro" "$(kairos_meta_get "$part" org_type)"
is "records the rate tier" "default_claude" "$(kairos_meta_get "$part" rate_tier)"
is "never records the email address" "" "$(grep -c 'nobody@example.com' "$part/meta" 2>/dev/null | tr -d ' ' | sed 's/^0$//')"

is "labels a pro account" "Pro (…444444)" "$(kairos_account_label "aaaaaaaa-1111-2222-3333-444444444444")"
kairos_meta_set "$part" alias "work laptop"
is "an alias wins over the derived label" "work laptop" "$(kairos_account_label "aaaaaaaa-1111-2222-3333-444444444444")"
is "setting an alias preserves other keys" "claude_pro" "$(kairos_meta_get "$part" org_type)"

first=$(kairos_meta_get "$part" first_seen)
kairos_account_record "aaaaaaaa-1111-2222-3333-444444444444"
is "first_seen is written once and never moves" "$first" "$(kairos_meta_get "$part" first_seen)"

# Test concurrent writes to meta do not corrupt or lose keys.
# This uses genuinely separate bash processes so $$ varies per writer.
kairos_race_part="$KAIROS_TESTDIR/concurrent_meta"
kairos_ensure_dir "$kairos_race_part"
kairos_meta_set "$kairos_race_part" seed "seedvalue"

# Create a worker script that will be run as a separate process
kairos_worker="$KAIROS_TESTDIR/meta_worker.sh"
cat > "$kairos_worker" << 'WORKER_SCRIPT'
#!/bin/bash
LIB="$1"
DIR="$2"
KEY="$3"
VAL="$4"

. "$LIB/common.sh"
. "$LIB/account.sh"

kairos_meta_set "$DIR" "$KEY" "$VAL"
WORKER_SCRIPT
chmod +x "$kairos_worker"

# Launch multiple separate bash processes writing different keys
# Run this multiple times to increase likelihood of hitting race conditions
for kairos_race_round in 1 2 3; do
  # Launch concurrent writers as separate bash processes
  bash "$kairos_worker" "$LIB" "$kairos_race_part" "writer1_round$kairos_race_round" "val1" 2> "$KAIROS_TESTDIR/worker1_$kairos_race_round.err" &
  bash "$kairos_worker" "$LIB" "$kairos_race_part" "writer2_round$kairos_race_round" "val2" 2> "$KAIROS_TESTDIR/worker2_$kairos_race_round.err" &
  bash "$kairos_worker" "$LIB" "$kairos_race_part" "writer3_round$kairos_race_round" "val3" 2> "$KAIROS_TESTDIR/worker3_$kairos_race_round.err" &
  wait
done

# Verify no errors in worker output (old code would have "mv: cannot stat" errors)
kairos_race_errors=""
for kairos_race_err in "$KAIROS_TESTDIR"/worker*.err; do
  if [ -s "$kairos_race_err" ]; then
    kairos_race_errors="$kairos_race_errors\n$(cat "$kairos_race_err")"
  fi
done
is "concurrent writers produce no errors" "" "$kairos_race_errors"

# Verify meta file still exists
is "meta file still exists after concurrent writes" "yes" "$([ -f "$kairos_race_part/meta" ] && echo yes || echo no)"

# Verify pre-seeded key is still there
is "concurrent writes preserve pre-seeded keys" "seedvalue" "$(kairos_meta_get "$kairos_race_part" seed)"

# Verify all lines in meta are well-formed key<TAB>value pairs with no truncation
kairos_race_malformed=$(awk '!/^[^\t]+\t.+$/' "$kairos_race_part/meta" | wc -l | tr -d ' ')
is "all meta entries are well-formed key<TAB>value pairs" "0" "$kairos_race_malformed"

# The fallback path: no readable claude.json at all.
rm -f "$KAIROS_CLAUDE_JSON"
is "falls back to a named unknown account" "unknown" "$(kairos_active_account || true)"
refutes "and signals the fallback with a non-zero exit" kairos_active_account
teardown_env

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
