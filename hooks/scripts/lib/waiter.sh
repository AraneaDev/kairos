# shellcheck shell=bash
# Waiting out a block, without holding the terminal hostage.
#
# The wait happens in a detached process, so closing the terminal or shutting
# the lid does not lose it. What survives a reboot is the wake time on disk, and
# readiness is decided by the clock rather than by trusting a leftover file.

kairos_waiter_arm() {
  kairos_wauuid=${1:-unknown}
  kairos_wawake=${2:-0}
  kairos_wapart=$(kairos_partition "$kairos_wauuid") || return 1
  kairos_waiter_clear "$kairos_wauuid"
  # A wait that cannot record its wake time is a wait nobody will be told about,
  # so it fails loudly rather than printing a holding message that is not true.
  printf '%s\n' "$kairos_wawake" > "$kairos_wapart/waiter.wake" 2>/dev/null || return 1
  kairos_wascript="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/waiter-run.sh"
  [ -f "$kairos_wascript" ] || { rm -f "$kairos_wapart/waiter.wake"; return 1; }
  nohup bash "$kairos_wascript" "$kairos_wauuid" "$kairos_wawake" >/dev/null 2>&1 &
  kairos_wapid=$!
  if ! printf '%s\n' "$kairos_wapid" > "$kairos_wapart/waiter.pid" 2>/dev/null; then
    kill "$kairos_wapid" >/dev/null 2>&1 || true
    rm -f "$kairos_wapart/waiter.wake"
    return 1
  fi
  return 0
}

# What the detached process does once the wait is over. Split out so the test
# suite can call it directly instead of sleeping through a block.
#
# Firing means the wait actually completed, so it stamps the wake time to now.
# Readiness stays a question for the clock alone, which is what makes it
# survive a reboot that leaves files behind but no process.
kairos_waiter_fire() {
  kairos_wfuuid=${1:-unknown}
  kairos_wfpart=$(kairos_partition "$kairos_wfuuid") || return 1
  : > "$kairos_wfpart/waiter.fired"
  kairos_now > "$kairos_wfpart/waiter.wake"
  # The detached waiter has its own stderr sent to /dev/null, so a bell written
  # here would never be heard. Write to the terminal that armed the wait, when
  # there is still one to write to.
  if [ -w /dev/tty ]; then
    printf '\007kairos: the usage window has reset.\n' > /dev/tty 2>/dev/null || true
  else
    printf '\007' >&2
  fi
  if [ -n "${KAIROS_NOTIFY_CMD:-}" ]; then
    sh -c "$KAIROS_NOTIFY_CMD" >/dev/null 2>&1 || true
  fi
  return 0
}

# True when the window has rolled over and there is something to offer back.
kairos_waiter_ready() {
  kairos_wruuid=${1:-unknown}
  kairos_wrpart="$KAIROS_HOME/accounts/$kairos_wruuid"
  [ -f "$kairos_wrpart/stash" ] || return 1
  [ -f "$kairos_wrpart/waiter.wake" ] || return 1
  kairos_wrwake=$(cat "$kairos_wrpart/waiter.wake" 2>/dev/null)
  [ -n "$kairos_wrwake" ] || return 1
  [ "$(kairos_now)" -ge "$kairos_wrwake" ] || return 1
  return 0
}

kairos_waiter_clear() {
  kairos_wcpart="$KAIROS_HOME/accounts/${1:-unknown}"
  # Kill the detached sleeper before dropping its files, or a cancelled wait
  # leaves a process sleeping out a five-hour block for nothing.
  if [ -f "$kairos_wcpart/waiter.pid" ]; then
    kairos_wcpid=$(cat "$kairos_wcpart/waiter.pid" 2>/dev/null)
    # Only signal a process that is still the waiter this file names. Pids are
    # reused, and a stale file plus a recycled pid would mean killing something
    # of the user's that has nothing to do with kairos.
    if [ -n "$kairos_wcpid" ] && ps -p "$kairos_wcpid" -o args= 2>/dev/null | grep -q 'waiter-run\.sh'; then
      kill "$kairos_wcpid" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$kairos_wcpart/waiter.wake" "$kairos_wcpart/waiter.pid" "$kairos_wcpart/waiter.fired"
  return 0
}
