# shellcheck shell=bash
# Which account is active, where its state lives, and what to call it on screen.
#
# Nothing here reads the ledger. Attribution has to resolve before anything
# else, because every other file is partitioned by the answer.

# Prints the active account uuid. On any failure prints "unknown" and returns
# 1, so a caller can both use the value and notice that it is a fallback.
kairos_active_account() {
  kairos_uuid=""
  if kairos_have_jq && [ -f "$KAIROS_CLAUDE_JSON" ]; then
    kairos_uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$KAIROS_CLAUDE_JSON" 2>/dev/null)
  fi
  if [ -n "$kairos_uuid" ]; then
    printf '%s\n' "$kairos_uuid"
    return 0
  fi
  printf 'unknown\n'
  return 1
}

kairos_partition() {
  # The account uuid is read from a file on disk, so it reaches a path the same
  # way a session id does and gets the same treatment. One slash in it would
  # put an account's whole state outside the accounts directory.
  #
  # A rejected id fails the call rather than falling back to the shared safe
  # name. That name is also what a genuinely unreadable ~/.claude.json resolves
  # to, so accepting it here would pool a corrupt account's usage together with
  # every session that could not identify its account at all, and the whole
  # point of partitioning is that two accounts never share a meter.
  kairos_psafe=$(kairos_safe_id "${1:-unknown}") || return 1
  kairos_part="$KAIROS_HOME/accounts/$kairos_psafe"
  kairos_ensure_dir "$kairos_part" || return 1
  printf '%s\n' "$kairos_part"
}

kairos_meta_get() {
  if [ -f "$1/meta" ]; then
    # The file can disappear between the test and the read. Replacing a file is
    # not atomic on every platform this runs on, so a concurrent writer's
    # replacement leaves a window where it briefly does not exist. A missing
    # value is the right answer then, not an error on the user's terminal.
    awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1/meta" 2>/dev/null
  fi
  return 0
}

kairos_meta_set() {
  kairos_mdir=$1; kairos_mkey=$2; kairos_mval=$3
  kairos_ensure_dir "$kairos_mdir" || return 1

  # The whole read, update and replace runs under a lock of its own.
  #
  # Two writers without it read the same file, each append their key, and the
  # second replacement drops the first one's. Worse, the existence check and
  # the read are separate, so a writer that observes the file mid-replacement
  # would treat it as empty and write a single-key meta, discarding org_type,
  # rate_tier and first_seen. Losing first_seen changes which recorded refusals
  # are trusted to calibrate the account, which is not a cosmetic loss.
  #
  # A separate lock name from the meter's, so a refresh in progress never
  # blocks a metadata write or the other way round.
  kairos_wait_lock "$kairos_mdir" meta.lock || return 1

  kairos_mtmp="$kairos_mdir/meta.tmp.$$"
  if [ -f "$kairos_mdir/meta" ]; then
    if ! awk -F'\t' -v k="$kairos_mkey" '$1 != k' "$kairos_mdir/meta" > "$kairos_mtmp" 2>/dev/null; then
      rm -f "$kairos_mtmp"
      kairos_unlock "$kairos_mdir" meta.lock
      return 1
    fi
  else
    if ! : > "$kairos_mtmp"; then
      rm -f "$kairos_mtmp"
      kairos_unlock "$kairos_mdir" meta.lock
      return 1
    fi
  fi
  if ! printf '%s\t%s\n' "$kairos_mkey" "$kairos_mval" >> "$kairos_mtmp"; then
    rm -f "$kairos_mtmp"
    kairos_unlock "$kairos_mdir" meta.lock
    return 1
  fi
  if ! mv "$kairos_mtmp" "$kairos_mdir/meta" 2>/dev/null; then
    rm -f "$kairos_mtmp"
    kairos_unlock "$kairos_mdir" meta.lock
    return 1
  fi
  kairos_unlock "$kairos_mdir" meta.lock
  return 0
}

# Records what this account is. The email address is deliberately not among the
# fields read, and a test asserts it never reaches disk.
kairos_account_record() {
  kairos_ruuid=${1:-unknown}
  kairos_rdir=$(kairos_partition "$kairos_ruuid") || return 1
  kairos_rtype=unknown
  kairos_rtier=unknown
  if kairos_have_jq && [ -f "$KAIROS_CLAUDE_JSON" ]; then
    kairos_rtype=$(jq -r '.oauthAccount.organizationType // "unknown"' "$KAIROS_CLAUDE_JSON" 2>/dev/null)
    kairos_rtier=$(jq -r '.oauthAccount.organizationRateLimitTier // "unknown"' "$KAIROS_CLAUDE_JSON" 2>/dev/null)
  fi
  kairos_meta_set "$kairos_rdir" org_type "$kairos_rtype"
  kairos_meta_set "$kairos_rdir" rate_tier "$kairos_rtier"
  # first_seen marks the point from which this account's walls are trustworthy.
  # Anything before it could belong to a different subscription, so it is set
  # once and never moved.
  if [ -z "$(kairos_meta_get "$kairos_rdir" first_seen)" ]; then
    kairos_meta_set "$kairos_rdir" first_seen "$(kairos_now)"
  fi
  return 0
}

# Records that a transcript belongs to an account, on the word of a hook.
#
# Every Claude Code hook payload carries transcript_path, and SubagentStop also
# carries agent_transcript_path. A hook fires inside the session that is
# spending, while the account paying for it is live, so what it records is
# observed rather than reconstructed, and it is the only attribution here that
# is. It matters most for the subagent transcripts, which state no owner of
# their own and are the bulk of the files on disk.
#
# Not authoritative over a marker inside the file, though. A binding names a
# file as a whole, and a session that spans a /login changes hands part way
# through, which only the markers can express.
kairos_bind_path() {
  kairos_bpacct=$(kairos_safe_id "${1:-}") || return 1
  kairos_bppath=${2:-}
  [ -n "$kairos_bppath" ] || return 1
  # The path becomes the first field of a TSV record. One containing a tab or a
  # newline would split into two records and bind some unrelated file, so it is
  # refused rather than trimmed.
  case "$kairos_bppath" in
    *"$(printf '\t')"*) return 1 ;;
    *"
"*) return 1 ;;
  esac
  kairos_ensure_dir "$KAIROS_HOME" || return 1
  kairos_bpfile="$KAIROS_HOME/paths.tsv"

  # The overwhelmingly common case is a binding that already says this, and it
  # is worth answering without taking a lock or rewriting the file: these hooks
  # run on every prompt and every turn.
  if [ -f "$kairos_bpfile" ] \
    && [ "$(awk -F'\t' -v p="$kairos_bppath" '$1 == p { print $2; exit }' "$kairos_bpfile" 2>/dev/null)" = "$kairos_bpacct" ]; then
    return 0
  fi

  kairos_wait_lock "$KAIROS_HOME" paths.lock || return 1
  kairos_bptmp="$kairos_bpfile.tmp.$$"
  if [ -f "$kairos_bpfile" ]; then
    # Bindings for transcripts that no longer exist are dropped as we pass, so
    # the file tracks the machine rather than growing for the life of it.
    if ! awk -F'\t' -v p="$kairos_bppath" '$1 != p && $1 != "" { print }' "$kairos_bpfile" 2>/dev/null \
      | while IFS="$(printf '\t')" read -r kairos_bpp kairos_bpa; do
          [ -f "$kairos_bpp" ] && printf '%s\t%s\n' "$kairos_bpp" "$kairos_bpa"
        done > "$kairos_bptmp"; then
      rm -f "$kairos_bptmp"
      kairos_unlock "$KAIROS_HOME" paths.lock
      return 1
    fi
  elif ! : > "$kairos_bptmp"; then
    rm -f "$kairos_bptmp"
    kairos_unlock "$KAIROS_HOME" paths.lock
    return 1
  fi
  printf '%s\t%s\n' "$kairos_bppath" "$kairos_bpacct" >> "$kairos_bptmp"
  mv "$kairos_bptmp" "$kairos_bpfile" 2>/dev/null || rm -f "$kairos_bptmp"
  kairos_unlock "$KAIROS_HOME" paths.lock
  return 0
}

kairos_account_label() {
  kairos_luuid=$(kairos_safe_id "${1:-unknown}")
  kairos_ldir="$KAIROS_HOME/accounts/$kairos_luuid"
  kairos_lalias=$(kairos_meta_get "$kairos_ldir" alias)
  if [ -n "$kairos_lalias" ]; then
    printf '%s\n' "$kairos_lalias"
    return 0
  fi
  # The tier is what actually distinguishes two subscriptions: a Max 5x and a
  # Max 20x share organizationType "claude_max" and have very different
  # ceilings. Observed values are like "default_claude_max_20x" and
  # "default_claude", so match on the fragment rather than the whole string.
  case "$(kairos_meta_get "$kairos_ldir" rate_tier)" in
    *max_20x*) kairos_lname="Max 20x" ;;
    *max_5x*) kairos_lname="Max 5x" ;;
    *)
      case "$(kairos_meta_get "$kairos_ldir" org_type)" in
        claude_pro) kairos_lname="Pro" ;;
        claude_max) kairos_lname="Max" ;;
        ""|unknown) kairos_lname="account" ;;
        *) kairos_lname=$(kairos_meta_get "$kairos_ldir" org_type) ;;
      esac
      ;;
  esac
  printf '%s (…%s)\n' "$kairos_lname" "$(printf '%s' "$kairos_luuid" | tail -c 6)"
}
