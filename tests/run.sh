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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
