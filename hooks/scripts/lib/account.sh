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
  kairos_mtmp="$kairos_mdir/meta.tmp.$$"
  # Copying the existing keys is a read that races with another writer's
  # replacement of the same file. On Windows replacing a file is not atomic, so
  # meta can vanish for an instant and the read fails. Retry rather than write a
  # meta missing every key the read did not get, and treat a file that is still
  # gone on the last attempt as an empty one.
  kairos_mtries=0
  while :; do
    if [ ! -f "$kairos_mdir/meta" ]; then
      : > "$kairos_mtmp" || { rm -f "$kairos_mtmp"; return 1; }
      break
    fi
    if awk -F'\t' -v k="$kairos_mkey" '$1 != k' "$kairos_mdir/meta" > "$kairos_mtmp" 2>/dev/null; then
      break
    fi
    kairos_mtries=$((kairos_mtries + 1))
    if [ "$kairos_mtries" -ge 5 ]; then
      : > "$kairos_mtmp" || { rm -f "$kairos_mtmp"; return 1; }
      break
    fi
  done
  printf '%s\t%s\n' "$kairos_mkey" "$kairos_mval" >> "$kairos_mtmp" || { rm -f "$kairos_mtmp"; return 1; }
  mv "$kairos_mtmp" "$kairos_mdir/meta" || { rm -f "$kairos_mtmp"; return 1; }
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
