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
: "${KAIROS_PREDICT_DEFAULT:=60000}"
# Whether the read window was given explicitly, recorded before it is
# defaulted, so a config file that changes the retention ceiling can move the
# derived window with it without overriding a deliberate choice.
kairos_read_explicit=${KAIROS_TURNS_READ+yes}
: "${KAIROS_TURNS_KEEP:=200}"

# The read window must always exceed the largest file the trim permits. If it
# does not, a quiet session's turns can be pushed out of view by a busy one and
# the estimate silently comes from the wrong history. The trim keeps
# KAIROS_TURNS_KEEP and fires above twice that, so ten times leaves five times
# the headroom even when trims are being skipped.
: "${KAIROS_TURNS_READ:=$((KAIROS_TURNS_KEEP * 10))}"

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
  # The read window is derived from the retention ceiling, and the config file
  # is sourced after that derivation ran. A config that raises the ceiling
  # without this would leave the two equal, which is exactly the state that
  # lets a busy session push a quiet one out of view.
  [ -n "${kairos_read_explicit:-}" ] || KAIROS_TURNS_READ=$((KAIROS_TURNS_KEEP * 10))
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
    printf '%s\n' "$$" > "$kairos_lkdir/owner" 2>/dev/null
    return 0
  fi
  # Note which lock we are about to judge, before judging it.
  kairos_lkprev=$(cat "$kairos_lkdir/owner" 2>/dev/null)
  if kairos_lock_is_stale "$kairos_lkdir"; then
    # Claim by renaming rather than deleting. mv is atomic, so only one
    # claimant can take a given lock away.
    #
    # Renaming alone is not enough. Between judging the lock stale and moving
    # it, another process can complete its own takeover and create a fresh
    # lock, and the move would then steal that one, leaving two processes both
    # believing they hold it. Measured at two winners in ten five-way races.
    # So check that what we moved is the lock we judged, and put it back if it
    # is not.
    kairos_lkstale="$1/lock.stale.$$"
    if mv "$kairos_lkdir" "$kairos_lkstale" 2>/dev/null; then
      kairos_lkgot=$(cat "$kairos_lkstale/owner" 2>/dev/null)
      if [ "$kairos_lkgot" != "$kairos_lkprev" ]; then
        mv "$kairos_lkstale" "$kairos_lkdir" 2>/dev/null || rm -rf "$kairos_lkstale" 2>/dev/null
        return 1
      fi
      rm -rf "$kairos_lkstale" 2>/dev/null
      if mkdir "$kairos_lkdir" 2>/dev/null; then
        printf '%s\n' "$$" > "$kairos_lkdir/owner" 2>/dev/null
        return 0
      fi
    fi
  fi
  return 1
}

kairos_unlock() {
  # Only the owner releases. Without this, a process whose stale lock was taken
  # over by someone else would go on to delete the new owner's lock when it
  # finished.
  kairos_ulowner=$(cat "${1}/lock/owner" 2>/dev/null)
  if [ -n "$kairos_ulowner" ] && [ "$kairos_ulowner" != "$$" ]; then
    return 0
  fi
  rm -rf "${1}/lock" 2>/dev/null
  return 0
}

# A session id becomes a filename, so a value containing a slash writes outside
# the sessions directory: ../config reaches the state directory, and ../.. leaves
# KAIROS_HOME entirely. Ids are uuids in practice.
#
# An unsafe id is refused rather than rewritten. A rewritten id would still
# bind, quietly, to the wrong session, and binding the wrong session to the
# wrong account is the exact failure this whole partition scheme exists to
# prevent.
# Prints a usable name always, so a path built from it is never malformed, and
# signals through its exit status whether the id was genuinely valid. Callers
# that write something keyed by the id check that status: every rejected id
# maps to the same "unknown" name, so writing under it would let two unrelated
# sessions overwrite each other's binding.
kairos_safe_id() {
  case "${1:-}" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      printf 'unknown\n'
      return 1
      ;;
    *)
      printf '%s\n' "$1"
      return 0
      ;;
  esac
}
