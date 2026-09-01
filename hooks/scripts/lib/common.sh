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

# KAIROS_NOW pins the clock. Nothing in normal use sets it: it exists so the
# generated screenshots render the same durations on every machine, which is
# what lets CI check them for drift instead of trusting them.
kairos_now() {
  if [ -n "${KAIROS_NOW:-}" ]; then
    printf '%s\n' "$KAIROS_NOW"
  else
    date +%s
  fi
}

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
  kairos_lkdir="$1/${2:-lock}"
  if mkdir "$kairos_lkdir" 2>/dev/null; then
    printf '%s\n' "$$" > "$kairos_lkdir/owner" 2>/dev/null
    return 0
  fi

  # Note which lock we are about to judge, before judging it.
  kairos_lkprev=$(cat "$kairos_lkdir/owner" 2>/dev/null)
  kairos_lock_is_stale "$kairos_lkdir" || return 1

  # Takeovers are serialised through a separate claim directory, and the lock
  # itself is never moved.
  #
  # An earlier version claimed by renaming the lock aside and renaming it back
  # if it turned out to be someone's fresh lock. Renaming back into a path that
  # now exists nests the directory inside it instead of restoring it, and both
  # processes then believe they hold the lock. Moving a lock you might not own
  # is the mistake; this never moves one.
  kairos_lkclaim="$kairos_lkdir.claim"
  if ! mkdir "$kairos_lkclaim" 2>/dev/null; then
    kairos_lock_is_stale "$kairos_lkclaim" || return 1
    rm -rf "$kairos_lkclaim" 2>/dev/null
    mkdir "$kairos_lkclaim" 2>/dev/null || return 1
  fi

  # With the claim held, re-read the owner. A change means another claimant
  # took over between our judgement and now, so theirs is a fresh lock and not
  # ours to remove.
  kairos_lknow=$(cat "$kairos_lkdir/owner" 2>/dev/null)
  if [ "$kairos_lknow" != "$kairos_lkprev" ]; then
    rm -rf "$kairos_lkclaim" 2>/dev/null
    return 1
  fi

  rm -rf "$kairos_lkdir" 2>/dev/null
  if mkdir "$kairos_lkdir" 2>/dev/null; then
    printf '%s\n' "$$" > "$kairos_lkdir/owner" 2>/dev/null
    rm -rf "$kairos_lkclaim" 2>/dev/null
    return 0
  fi
  rm -rf "$kairos_lkclaim" 2>/dev/null
  return 1
}

# Waits for a lock rather than giving up, for the few callers that must not
# skip their work. Bounded, because a hook that never returns is worse than a
# meter that misses one update.
kairos_wait_lock() {
  kairos_wltries=0
  while ! kairos_try_lock "$1" "${2:-lock}"; do
    kairos_wltries=$((kairos_wltries + 1))
    if [ "$kairos_wltries" -ge 100 ]; then
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
  return 0
}

kairos_unlock() {
  kairos_uldir="$1/${2:-lock}"
  # Only the owner releases. Without this, a process whose stale lock was taken
  # over by someone else would go on to delete the new owner's lock when it
  # finished.
  kairos_ulowner=$(cat "$kairos_uldir/owner" 2>/dev/null)
  if [ -n "$kairos_ulowner" ] && [ "$kairos_ulowner" != "$$" ]; then
    return 0
  fi
  rm -rf "$kairos_uldir" 2>/dev/null
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
