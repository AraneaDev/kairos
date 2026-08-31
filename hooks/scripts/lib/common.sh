# shellcheck shell=bash
# Paths, defaults and the few portability helpers. No domain logic lives here,
# so this file is safe to source from anything.

: "${KAIROS_HOME:=${HOME}/.claude/kairos}"
: "${KAIROS_CLAUDE_JSON:=${HOME}/.claude.json}"
: "${KAIROS_PROJECTS_DIR:=${HOME}/.claude/projects}"

: "${KAIROS_BLOCK_SECONDS:=18000}"
: "${KAIROS_LEDGER_WINDOW:=86400}"
: "${KAIROS_RESERVE:=3}"
: "${KAIROS_GATE:=1}"
: "${KAIROS_SEED_LOW:=4100000}"
: "${KAIROS_SEED_HIGH:=5700000}"
: "${KAIROS_PREDICT_DEFAULT:=60000}"

kairos_now() { date +%s; }

kairos_have_jq() { command -v jq >/dev/null 2>&1; }

# Byte size without stat, whose flags differ between GNU, BSD and Git Bash.
# wc -c is POSIX and behaves the same on all three.
kairos_size_of() {
  if [ -f "$1" ]; then
    wc -c < "$1" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

kairos_ensure_dir() {
  if [ ! -d "$1" ]; then
    mkdir -p "$1" 2>/dev/null || return 1
  fi
  return 0
}

# Optional user config, sourced if present. The explicit return keeps a missing
# file from becoming a non-zero exit under set -e.
kairos_config_load() {
  if [ -f "$KAIROS_HOME/config" ]; then
    # shellcheck source=/dev/null
    . "$KAIROS_HOME/config"
  fi
  return 0
}

# How long a lock may be held before another process may break it.
: "${KAIROS_LOCK_STALE_MIN:=2}"

# True when a lock directory is older than the stale window. Uses find -mmin
# rather than stat, whose flags differ between GNU, BSD and Git Bash.
kairos_lock_is_stale() {
  [ -n "$(find "$1" -prune -mmin "+$KAIROS_LOCK_STALE_MIN" 2>/dev/null)" ]
}

# mkdir is atomic on every platform this runs on, which flock is not: macOS
# ships without it. A caller that cannot take the lock skips its work and
# returns 0, because a skipped refresh costs nothing (the next prompt refreshes
# anyway) while a blocked prompt costs the user their turn.
kairos_try_lock() {
  kairos_lkdir="$1/lock"
  if mkdir "$kairos_lkdir" 2>/dev/null; then
    return 0
  fi
  if kairos_lock_is_stale "$kairos_lkdir"; then
    rm -rf "$kairos_lkdir" 2>/dev/null
    if mkdir "$kairos_lkdir" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

kairos_unlock() {
  rm -rf "${1}/lock" 2>/dev/null
  return 0
}
