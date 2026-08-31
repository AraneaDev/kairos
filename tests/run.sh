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

# The fallback path: no readable claude.json at all.
rm -f "$KAIROS_CLAUDE_JSON"
is "falls back to a named unknown account" "unknown" "$(kairos_active_account || true)"
refutes "and signals the fallback with a non-zero exit" kairos_active_account
teardown_env

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
