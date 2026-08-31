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

echo
echo "lib/meter.sh: the ledger"
setup_env
# shellcheck source=/dev/null
. "$LIB/common.sh"
# shellcheck source=/dev/null
. "$LIB/account.sh"
# shellcheck source=/dev/null
. "$LIB/meter.sh"

acct="aaaaaaaa-1111-2222-3333-444444444444"
part=$(kairos_partition "$acct")
mkdir -p "$KAIROS_PROJECTS_DIR/proj"
cp "$ROOT/tests/fixtures/usage-basic.jsonl" "$KAIROS_PROJECTS_DIR/proj/a.jsonl"

kairos_refresh "$acct"
is "one ledger row per assistant message" "3" "$(wc -l < "$part/ledger.tsv" | tr -d ' ')"
is "billable excludes cache reads" "1110" "$(awk -F'\t' 'NR==1 {print $5}' "$part/ledger.tsv")"
is "rows are stamped with the account" "$acct" "$(awk -F'\t' 'NR==1 {print $2}' "$part/ledger.tsv")"
is "rows carry the session id" "s1" "$(awk -F'\t' 'NR==1 {print $3}' "$part/ledger.tsv")"
is "rows carry the model" "claude-opus-5" "$(awk -F'\t' 'NR==1 {print $4}' "$part/ledger.tsv")"
is "a fractional-second timestamp parses" "1788170400" "$(awk -F'\t' 'NR==1 {print $1}' "$part/ledger.tsv")"
is "the second row keeps its fractional timestamp" "1788170460" "$(awk -F'\t' 'NR==2 {print $1}' "$part/ledger.tsv")"

kairos_refresh "$acct"
is "a second refresh reads no bytes twice" "3" "$(wc -l < "$part/ledger.tsv" | tr -d ' ')"

printf '%s\n' '{"type":"assistant","sessionId":"s1","timestamp":"2026-08-31T10:03:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5000000,"output_tokens":5}}}' >> "$KAIROS_PROJECTS_DIR/proj/a.jsonl"
kairos_refresh "$acct"
is "an appended line is picked up" "4" "$(wc -l < "$part/ledger.tsv" | tr -d ' ')"
is "and only the new bytes were read" "10" "$(awk -F'\t' 'NR==4 {print $5}' "$part/ledger.tsv")"

printf '%s\n' '{"type":"assistant","sessionId":"s9","timestamp":"2026-08-31T10:04' >> "$KAIROS_PROJECTS_DIR/proj/a.jsonl"
kairos_refresh "$acct"
is "a half-written line is skipped, not fatal" "4" "$(wc -l < "$part/ledger.tsv" | tr -d ' ')"

# A file that shrank was replaced, so its cursor has to reset.
cp "$ROOT/tests/fixtures/usage-basic.jsonl" "$KAIROS_PROJECTS_DIR/proj/a.jsonl"
kairos_refresh "$acct"
is "a shrunken file is re-read from the start" "7" "$(wc -l < "$part/ledger.tsv" | tr -d ' ')"

# Pruning keeps the window bounded no matter how long kairos has been installed.
# Use kairos_now to make the test time-independent.
kairos_old_epoch=$(($(kairos_now) - KAIROS_LEDGER_WINDOW - 1000))
kairos_recent_epoch=$(($(kairos_now) - 1000))
{
  printf '%s\t%s\ts0\tm\t100\n' "$kairos_recent_epoch" "$acct"
  printf '%s\t%s\ts0\tm\t200\n' "$kairos_recent_epoch" "$acct"
  printf '%s\t%s\ts0\tm\t999\n' "$kairos_old_epoch" "$acct"
} >> "$part/ledger.tsv"
kairos_prune "$acct"
is "pruning drops rows outside the window" "9" "$(wc -l < "$part/ledger.tsv" | tr -d ' ')"

# Test locking: lock can be taken, second attempt fails, re-acquired after unlock
if kairos_try_lock "$part"; then pass "lock can be taken"; else fail "lock can be taken" "success" "failure"; fi
if kairos_try_lock "$part"; then fail "second lock attempt fails" "failure" "success"; else pass "second lock attempt fails"; fi
kairos_unlock "$part"
if kairos_try_lock "$part"; then pass "lock can be taken again after unlock"; else fail "lock can be taken again after unlock" "success" "failure"; fi
kairos_unlock "$part"

# Test stale lock: create a lock, age it, then break and re-acquire it
mkdir "$part/lock"
touch -t "$(date -u -d '3 minutes ago' +%Y%m%d%H%M.%S 2>/dev/null || date -u -v-3M +%Y%m%d%H%M.%S)" "$part/lock" 2>/dev/null || true
if kairos_try_lock "$part"; then pass "stale lock is broken and re-acquired"; else fail "stale lock is broken and re-acquired" "success" "failure"; fi
kairos_unlock "$part"

# Test kairos_refresh with held lock
mkdir "$part/lock"
kairos_refresh "$acct"
is "kairos_refresh returns 0 with held lock" "9" "$(wc -l < "$part/ledger.tsv" | tr -d ' ')"
kairos_unlock "$part"

# Test kairos_prune with held lock
mkdir "$part/lock"
kairos_ledger_before=$(wc -l < "$part/ledger.tsv" | tr -d ' ')
kairos_prune "$acct"
kairos_ledger_after=$(wc -l < "$part/ledger.tsv" | tr -d ' ')
is "kairos_prune with held lock leaves ledger unchanged" "$kairos_ledger_before" "$kairos_ledger_after"
kairos_unlock "$part"

# Concurrency regression: multiple processes calling kairos_refresh should not overcount
kairos_worker="$KAIROS_TESTDIR/refresh_worker.sh"
cat > "$kairos_worker" << 'WORKER_SCRIPT'
#!/bin/bash
ROOT="$1"
KAIROS_HOME="$2"
KAIROS_PROJECTS_DIR="$3"
KAIROS_CLAUDE_JSON="$4"
ACCT="$5"

LIB="$ROOT/hooks/scripts/lib"
. "$LIB/common.sh"
. "$LIB/account.sh"
. "$LIB/meter.sh"

kairos_refresh "$ACCT" 2>/dev/null
WORKER_SCRIPT
chmod +x "$kairos_worker"

# Clear ledger for a clean concurrency test
rm -f "$part/ledger.tsv" "$part/cursors.tsv" "$part/cursors.new."*

# Launch multiple refresh processes
for kairos_i in 1 2 3 4 5; do
  bash "$kairos_worker" "$ROOT" "$KAIROS_HOME" "$KAIROS_PROJECTS_DIR" "$KAIROS_CLAUDE_JSON" "$acct" 2>"$KAIROS_TESTDIR/worker_$kairos_i.err" &
done
wait

# Verify no errors
kairos_worker_errors=""
for kairos_err in "$KAIROS_TESTDIR"/worker_*.err; do
  if [ -s "$kairos_err" ]; then
    kairos_worker_errors="$kairos_worker_errors $(cat "$kairos_err")"
  fi
done
is "concurrent refresh produces no stderr" "" "$kairos_worker_errors"

# Should have exactly 3 rows (one per assistant message), not 15 (3x5 processes)
is "concurrent refresh does not overcount" "3" "$(wc -l < "$part/ledger.tsv" | tr -d ' ')"

teardown_env

echo
echo "lib/meter.sh: blocks"
setup_env
# shellcheck source=/dev/null
. "$LIB/common.sh"
# shellcheck source=/dev/null
. "$LIB/account.sh"
# shellcheck source=/dev/null
. "$LIB/meter.sh"

acct="bbbb"
part=$(kairos_partition "$acct")

# Two blocks: three rows, then a six-hour gap, then two more.
{
  printf '1000000\t%s\ts1\tm\t100\n' "$acct"
  printf '1001000\t%s\ts1\tm\t200\n' "$acct"
  printf '1002000\t%s\ts1\tm\t300\n' "$acct"
  printf '1015000\t%s\ts1\tm\t250\n' "$acct"
  printf '1023600\t%s\ts2\tm\t400\n' "$acct"
  printf '1024000\t%s\ts2\tm\t500\n' "$acct"
} > "$part/ledger.tsv"

read -r bstart bend bused <<EOF
$(kairos_block "$acct")
EOF
is "a gap of five hours opens a new block" "1023600" "$bstart"
is "a block ends five hours after it opens" "1041600" "$bend"
is "only the current block is counted" "900" "$bused"

# A recorded refusal states the true boundary, and beats the computed one.
printf '1024100\t950\t1030000\n' > "$part/walls.tsv"
read -r bstart bend bused <<EOF
$(kairos_block "$acct")
EOF
is "a recorded refusal overrides the computed end" "1030000" "$bend"
is "and shifts the start to match" "1012000" "$bstart"
is "consumption is recounted over the corrected block" "1150" "$bused"

# A refusal whose window has already ended describes a past window, not this
# one, and must not be allowed to move the block backwards and hide usage.
printf '901000\t50\t920000\n' > "$part/walls.tsv"
read -r bstart bend bused <<EOF
$(kairos_block "$acct")
EOF
is "a refusal from an ended window is ignored" "1041600" "$bend"
is "and the real consumption is still counted" "900" "$bused"

# The pick must not depend on how walls.tsv happens to be ordered.
{
  printf '901000\t50\t920000\n'
  printf '1024100\t950\t1030000\n'
} > "$part/walls.tsv"
read -r bstart bend bused <<EOF
$(kairos_block "$acct")
EOF
is "the applicable refusal wins regardless of file order" "1030000" "$bend"

# The failure the wall-window test exists to prevent: a refusal recorded
# recently, whose stated reset has nonetheless already passed. Selecting on the
# hit time alone accepts it, drags the window back and hides real consumption.
printf '1024100\t50\t1020000\n' > "$part/walls.tsv"
read -r bstart bend bused <<EOF
$(kairos_block "$acct")
EOF
is "a recent refusal stating a passed reset is ignored" "1041600" "$bend"
is "so recent usage is not hidden by it" "900" "$bused"

# Two refusals can both still cover the latest activity if the window rolled
# and a second was recorded. The later reset is the server's more recent word,
# so it wins. Selecting the earlier one would shorten the countdown.
{
  printf '1024100\t50\t1030000\n'
  printf '1024200\t60\t1035000\n'
} > "$part/walls.tsv"
read -r bstart bend bused <<EOF
$(kairos_block "$acct")
EOF
is "the later of two applicable refusals wins" "1035000" "$bend"

# A ledger of nothing but garbage has nothing to report, and must not render
# as a window beginning at the epoch.
rm -f "$part/walls.tsv"
printf 'not-a-number\tx\ty\tz\tw\n' > "$part/ledger.tsv"
is "a ledger of garbage reports nothing, not 1970" "0	0	0" "$(kairos_block "$acct")"

# Continuous work must roll into a new window when the old one expires. This is
# the case a gap-only rule gets wrong: without chaining, a long working day is
# reported as one window whose reset time is already in the past.
{
  printf '2000000\t%s\ts1\tm\t100\n' "$acct"
  printf '2010000\t%s\ts1\tm\t100\n' "$acct"
  printf '2020000\t%s\ts1\tm\t100\n' "$acct"
  printf '2030000\t%s\ts1\tm\t700\n' "$acct"
} > "$part/ledger.tsv"
read -r bstart bend bused <<EOF
$(kairos_block "$acct")
EOF
is "continuous work rolls into a fresh window" "2019600" "$bstart"
is "whose end is five hours past that start" "2037600" "$bend"
is "counting only what the fresh window holds" "800" "$bused"

# Window starts floor to ten minutes, which is the granularity the server
# reports resets on.
printf '3000517\t%s\ts1\tm\t5\n' "$acct" > "$part/ledger.tsv"
read -r bstart bend bused <<EOF
$(kairos_block "$acct")
EOF
is "a window start floors to ten minutes" "3000000" "$bstart"

# An empty ledger must be answerable, not an error.
rm -f "$part/ledger.tsv" "$part/walls.tsv"
is "an empty ledger reports zeroes" "0	0	0" "$(kairos_block "$acct")"
teardown_env

echo
echo "lib/wall.sh"
setup_env
# shellcheck source=/dev/null
. "$LIB/common.sh"
# shellcheck source=/dev/null
. "$LIB/account.sh"
# shellcheck source=/dev/null
. "$LIB/meter.sh"
# shellcheck source=/dev/null
. "$LIB/wall.sh"

acct="cccc"
part=$(kairos_partition "$acct")
kairos_meta_set "$part" first_seen 1

is "an uncalibrated account reports no band at all" "0	0	0" "$(kairos_band "$acct")"

mkdir -p "$KAIROS_PROJECTS_DIR/proj"
cp "$ROOT/tests/fixtures/refusal.jsonl" "$KAIROS_PROJECTS_DIR/proj/r.jsonl"
# Consumption inside the refused block, so the wall has a value to record.
{
  printf '1788160000\t%s\ts1\tm\t2000000\n' "$acct"
  printf '1788170000\t%s\ts1\tm\t2000000\n' "$acct"
} > "$part/ledger.tsv"

kairos_harvest_walls "$acct"
is "repeated refusals collapse to one wall" "1" "$(wc -l < "$part/walls.tsv" | tr -d ' ')"
is "a weekly refusal is not recorded as a five-hour wall" "0" "$(grep -c '1787220000' "$part/walls.tsv" | tr -d ' ')"
is "the wall records what was consumed" "4000000" "$(awk -F'\t' 'NR==1 {print $2}' "$part/walls.tsv")"
is "the wall records the stated reset" "1788175200" "$(awk -F'\t' 'NR==1 {print $3}' "$part/walls.tsv")"

kairos_harvest_walls "$acct"
is "harvesting twice does not duplicate a wall" "1" "$(wc -l < "$part/walls.tsv" | tr -d ' ')"

is "one wall gives a wide band around it" "3400000	4600000	1" "$(kairos_band "$acct")"

printf '1788200000\t4200000\t1788210000\n' >> "$part/walls.tsv"
printf '1788300000\t4400000\t1788310000\n' >> "$part/walls.tsv"
is "three walls tighten the band" "3800000	4620000	3" "$(kairos_band "$acct")"

# A wall from before this account was ever seen cannot be trusted to be its own.
rm -f "$part/walls.tsv"
kairos_meta_set "$part" first_seen 1788999999
kairos_harvest_walls "$acct"
is "a wall predating first_seen is not used" "0" "$([ -s "$part/walls.tsv" ] && wc -l < "$part/walls.tsv" | tr -d ' ' || echo 0)"
is "but it is kept aside" "1" "$(wc -l < "$part/walls.unattributed.tsv" | tr -d ' ')"

# A malformed row must not be able to move the band or count toward
# confidence. A zero low edge with confidence above zero is a band the gate
# would act on, derived from a row that says nothing.
printf '100\t4000000\t200\n101\tbogus\t201\n' > "$part/walls.tsv"
is "a malformed wall row is ignored by the band" "3400000	4600000	1" "$(kairos_band "$acct")"
printf '100\t4000000\t200\n101\t4200000\t201\n102\t4400000\t202\n\n' > "$part/walls.tsv"
is "a blank line neither lowers the floor nor inflates confidence" "3800000	4620000	3" "$(kairos_band "$acct")"
printf '100\tbogus\t200\n' > "$part/walls.tsv"
is "walls that are all malformed leave the account uncalibrated" "0	0	0" "$(kairos_band "$acct")"
rm -f "$part/walls.tsv"

# An account kairos has never recorded has no point from which its walls can
# be trusted, so every historical refusal is set aside rather than believed.
fresh="ffff-unseen"
fpart=$(kairos_partition "$fresh")
kairos_harvest_walls "$fresh"
is "with no first_seen, nothing is attributable" "0" "$([ -s "$fpart/walls.tsv" ] && wc -l < "$fpart/walls.tsv" | tr -d ' ' || echo 0)"

# A wall landing in the same second as first_seen belongs to this account.
seen="ffff-exact"
spart=$(kairos_partition "$seen")
kairos_meta_set "$spart" first_seen 1788172097
kairos_harvest_walls "$seen"
is "a wall exactly at first_seen is attributed" "1" "$(wc -l < "$spart/walls.tsv" | tr -d ' ')"
teardown_env

echo
echo "lib/predict.sh"
setup_env
# shellcheck source=/dev/null
. "$LIB/common.sh"
# shellcheck source=/dev/null
. "$LIB/account.sh"
# shellcheck source=/dev/null
. "$LIB/predict.sh"

is "p75 of four values takes the third" "30" "$(printf '10\n20\n30\n40\n' | kairos_p75)"
is "p75 of one value is that value" "7" "$(printf '7\n' | kairos_p75)"
is "p75 ignores input order" "30" "$(printf '40\n10\n30\n20\n' | kairos_p75)"
is "p75 of nothing is empty" "" "$(printf '' | kairos_p75)"

acct="dddd"
is "a cold account falls back to the default" "60000" "$(kairos_predict "$acct" s1)"

kairos_record_turn "$acct" s1 100
kairos_record_turn "$acct" s1 200
is "fewer than three turns still falls back" "60000" "$(kairos_predict "$acct" s1)"

kairos_record_turn "$acct" s1 300
kairos_record_turn "$acct" s1 4000
is "four turns in this session gives their p75" "300" "$(kairos_predict "$acct" s1)"

is "a cold session borrows the account history" "300" "$(kairos_predict "$acct" s-new)"

# Only the last eight turns count, so an old spike stops dominating.
i=0
while [ "$i" -lt 8 ]; do kairos_record_turn "$acct" s1 500; i=$((i + 1)); done
is "only the last eight turns are used" "500" "$(kairos_predict "$acct" s1)"

# p75 leans high without being dragged to the top: one spike moves the estimate
# off the median, but a single outlier does not become the estimate.
part=$(kairos_partition "$acct")
: > "$part/turns.tsv"
kairos_record_turn "$acct" s2 10
kairos_record_turn "$acct" s2 10
kairos_record_turn "$acct" s2 10
kairos_record_turn "$acct" s2 1000
is "a single spike does not become the estimate" "10" "$(kairos_predict "$acct" s2)"

# A malformed billable must not become the prediction. Filtering it leaves
# too few usable turns, so the estimate falls back rather than inventing one.
zpart=$(kairos_partition "zz-malformed")
printf '1\ts1\t100\n2\ts1\t200\n3\ts1\t9999abc\n' > "$zpart/turns.tsv"
is "a malformed turn cannot become the estimate" "60000" "$(kairos_predict zz-malformed s1)"

# A zero estimate would disable the gate, since the caller multiplies it by
# the reserve and zero always looks affordable.
printf '1\ts1\t0\n2\ts1\t0\n3\ts1\t0\n4\ts1\t0\n' > "$zpart/turns.tsv"
is "an all-zero history floors to the default" "60000" "$(kairos_predict zz-malformed s1)"

# A tab in a session id would shift the other fields and put billable in the
# wrong column.
tpart=$(kairos_partition "zz-tab")
kairos_record_turn "zz-tab" "$(printf 'a\tb')" 123
is "a tabbed session id still writes three fields" "3" "$(awk -F'\t' 'NR==1 {print NF}' "$tpart/turns.tsv")"
is "and the billable lands in the third" "123" "$(awk -F'\t' 'NR==1 {print $3}' "$tpart/turns.tsv")"

# The write and read paths must agree on what an empty session id means. The
# other session's turns are here so the account-wide fallback would give a
# different answer, which is what makes this assertion able to fail.
kairos_record_turn "zz-empty" "s-other" 900
kairos_record_turn "zz-empty" "s-other" 900
kairos_record_turn "zz-empty" "s-other" 900
kairos_record_turn "zz-empty" "" 111
kairos_record_turn "zz-empty" "" 222
kairos_record_turn "zz-empty" "" 333
is "an empty session id is readable back" "333" "$(kairos_predict zz-empty "")"

# The turns file must not grow without bound, since the gate scans it on
# every prompt.
kpart=$(kairos_partition "zz-keep")
i=0
while [ "$i" -lt 25 ]; do KAIROS_TURNS_KEEP=5 kairos_record_turn "zz-keep" s1 10; i=$((i + 1)); done
is "the turns file is trimmed as it grows" "yes" "$([ "$(wc -l < "$kpart/turns.tsv" | tr -d ' ')" -le 10 ] && echo yes || echo no)"

# A quiet session's own history must not be pushed out of the read window by a
# busy session's turns. Answering with another session's number would
# under-predict, which is the direction that lets a wall arrive unwarned.
xpart=$(kairos_partition "zz-crosstalk")
i=0
while [ "$i" -lt 3 ]; do printf '1\tsessA\t50000\n' >> "$xpart/turns.tsv"; i=$((i + 1)); done
i=0
while [ "$i" -lt 20 ]; do printf '2\tsessB\t100\n' >> "$xpart/turns.tsv"; i=$((i + 1)); done
is "a busy session cannot push a quiet one out of view" "50000" \
  "$(KAIROS_TURNS_KEEP=5 KAIROS_TURNS_READ=50 kairos_predict zz-crosstalk sessA)"
teardown_env

echo
echo "hooks/stop.sh"
setup_env
# shellcheck source=/dev/null
. "$LIB/common.sh"
# shellcheck source=/dev/null
. "$LIB/account.sh"

acct="aaaaaaaa-1111-2222-3333-444444444444"
part=$(kairos_partition "$acct")

# A turn that began at a recent time and spent 700 across three ledger rows, with a row
# from another session and a row from before the turn that must not be counted.
kairos_turn_start=$(kairos_now)
printf '%s\ts9\n' "$kairos_turn_start" > "$part/turn.start"
{
  printf '%s\t%s\ts9\tm\t9999\n' $((kairos_turn_start - 100)) "$acct"
  printf '%s\t%s\ts9\tm\t200\n' $((kairos_turn_start + 10)) "$acct"
  printf '%s\t%s\ts8\tm\t5555\n' $((kairos_turn_start + 20)) "$acct"
  printf '%s\t%s\ts9\tm\t500\n' $((kairos_turn_start + 30)) "$acct"
} > "$part/ledger.tsv"

echo '{"session_id":"s9"}' | bash "$ROOT/hooks/scripts/stop.sh" >/dev/null 2>&1
is "the turn is recorded" "1" "$(wc -l < "$part/turns.tsv" | tr -d ' ')"
is "only this session's rows since the turn began are counted" "700" "$(awk -F'\t' 'NR==1 {print $3}' "$part/turns.tsv")"
is "the marker is consumed" "no" "$([ -f "$part/turn.start" ] && echo yes || echo no)"

echo '{"session_id":"s9"}' | bash "$ROOT/hooks/scripts/stop.sh" >/dev/null 2>&1
is "a second stop with no marker records nothing" "1" "$(wc -l < "$part/turns.tsv" | tr -d ' ')"

is "stop always exits zero" "0" "$(echo '{}' | bash "$ROOT/hooks/scripts/stop.sh" >/dev/null 2>&1; echo $?)"

# Two Stop hooks racing for one marker must record the turn once, not twice.
# Separate processes, because a backgrounded function shares the parent's PID
# and would not exercise the claim at all.
racepart=$(kairos_partition "$acct")
: > "$racepart/turns.tsv"
race_now=$(kairos_now)
printf '%s\ts9\n' "$race_now" > "$racepart/turn.start"
printf '%s\t%s\ts9\tm\t500\n' "$((race_now + 5))" "$acct" > "$racepart/ledger.tsv"
worker="$KAIROS_TESTDIR/stopworker.sh"
printf '#!/usr/bin/env bash\necho %s | bash %s >/dev/null 2>&1\n' \
  "'{\"session_id\":\"s9\"}'" "$ROOT/hooks/scripts/stop.sh" > "$worker"
bash "$worker" & bash "$worker" & bash "$worker" &
wait
is "racing stop hooks record the turn once" "1" "$(wc -l < "$racepart/turns.tsv" | tr -d ' ')"

# A malformed marker must record nothing rather than scoring a real turn as
# free, which would poison the predictor with a value that never happened.
: > "$racepart/turns.tsv"
printf 'not-an-epoch\ts9\n' > "$racepart/turn.start"
printf '%s\t%s\ts9\tm\t500\n' "$(kairos_now)" "$acct" > "$racepart/ledger.tsv"
echo '{"session_id":"s9"}' | bash "$ROOT/hooks/scripts/stop.sh" >/dev/null 2>&1
is "a malformed marker records nothing, not a free turn" "0" \
  "$([ -s "$racepart/turns.tsv" ] && wc -l < "$racepart/turns.tsv" | tr -d ' ' || echo 0)"
rm -f "$racepart/turn.start"
teardown_env

echo
echo "hooks/session-start.sh"
setup_env
# shellcheck source=/dev/null
. "$LIB/common.sh"
# shellcheck source=/dev/null
. "$LIB/account.sh"

acct="aaaaaaaa-1111-2222-3333-444444444444"
out=$(echo '{"session_id":"sX"}' | bash "$ROOT/hooks/scripts/session-start.sh" 2>/dev/null)
is "the session is bound to the active account" "$acct" "$(cat "$KAIROS_HOME/sessions/sX" 2>/dev/null)"
is "the account meta is recorded" "claude_pro" "$(kairos_meta_get "$KAIROS_HOME/accounts/$acct" org_type)"
is "first_seen is set on binding" "yes" "$([ -n "$(kairos_meta_get "$KAIROS_HOME/accounts/$acct" first_seen)" ] && echo yes || echo no)"
is "nothing is printed when there is no stash" "" "$out"

# An abandoned claim file is swept once it is old enough to be nobody's.
sweeppart=$(kairos_partition "$acct")
: > "$sweeppart/turn.start.claimed.999"
touch -t 202601010000 "$sweeppart/turn.start.claimed.999" 2>/dev/null
: > "$sweeppart/turn.start.claimed.888"
echo '{"session_id":"sS"}' | bash "$ROOT/hooks/scripts/session-start.sh" >/dev/null 2>&1
is "an old abandoned claim is swept" "no" "$([ -f "$sweeppart/turn.start.claimed.999" ] && echo yes || echo no)"
is "a fresh claim is left alone" "yes" "$([ -f "$sweeppart/turn.start.claimed.888" ] && echo yes || echo no)"
rm -f "$sweeppart/turn.start.claimed.888"

is "session start exits zero with an unreadable claude.json" "0" \
  "$(rm -f "$KAIROS_CLAUDE_JSON"; echo '{"session_id":"sY"}' | bash "$ROOT/hooks/scripts/session-start.sh" >/dev/null 2>&1; echo $?)"
is "and falls back to the unknown partition" "unknown" "$(cat "$KAIROS_HOME/sessions/sY" 2>/dev/null)"
teardown_env

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
