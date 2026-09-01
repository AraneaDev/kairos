# shellcheck shell=bash
# What the next turn is likely to cost.
#
# The 75th percentile of recent turns, not the mean. An estimator centred on the
# middle is wrong exactly when being wrong is expensive, because it is the tail
# that puts a session through the wall.

KAIROS_TURN_WINDOW=8

# A session id becomes a TSV field, so a tab or a newline in one would shift
# the other fields or forge a whole row. Ids are uuids in practice; this makes
# the file format safe regardless, and makes the write and read paths agree on
# what an empty id means.
kairos_clean_session() {
  kairos_cs=$(printf '%s' "${1:-}" | tr -d '\t\n\r')
  [ -n "$kairos_cs" ] || kairos_cs=unknown
  printf '%s' "$kairos_cs"
}

# Nearest-rank 75th percentile of the numbers on stdin. Empty input prints
# nothing, which callers treat as "no answer" rather than as zero.
kairos_p75() {
  sort -n | awk '
    { a[NR] = $1 }
    END {
      if (NR == 0) exit
      i = int(0.75 * NR + 0.999999)
      if (i < 1) i = 1
      if (i > NR) i = NR
      print a[i]
    }'
}

kairos_record_turn() {
  kairos_tdir=$(kairos_partition "${1:-unknown}") || return 1
  kairos_tfile="$kairos_tdir/turns.tsv"
  printf '%s\t%s\t%s\n' "$(kairos_now)" "$(kairos_clean_session "$2")" "$3" >> "$kairos_tfile"

  # Only the most recent turns ever matter, but the account-wide fallback reads
  # across sessions, so keep a generous tail rather than the window itself.
  # Trimming only once the file has grown past twice the target costs one
  # rewrite per KAIROS_TURNS_KEEP turns instead of one on every turn.
  kairos_tlines=$(wc -l < "$kairos_tfile" 2>/dev/null | tr -d '[:space:]')
  [ -n "$kairos_tlines" ] || return 0
  if [ "$kairos_tlines" -gt $((KAIROS_TURNS_KEEP * 2)) ]; then
    # The append above is atomic. The trim is a read, a rewrite and a rename,
    # so two of them at once would fight. Skipping when the lock is held costs
    # nothing, because the next turn trims instead.
    #
    # A turn appended by another process between the tail and the mv is still
    # lost. That is accepted: it is one row out of KAIROS_TURNS_KEEP feeding a
    # percentile of eight, and closing it would mean every append blocking on
    # a lock, which risks losing a turn outright when a lock is stale held.
    # Reads are bounded by KAIROS_TURNS_READ, which is deliberately far larger
    # than this ceiling, so a skipped trim costs disk rather than correctness.
    if kairos_try_lock "$kairos_tdir"; then
      if tail -n "$KAIROS_TURNS_KEEP" "$kairos_tfile" > "$kairos_tfile.tmp.$$" 2>/dev/null; then
        mv "$kairos_tfile.tmp.$$" "$kairos_tfile"
      fi
      rm -f "$kairos_tfile.tmp.$$"
      kairos_unlock "$kairos_tdir"
    fi
  fi
  return 0
}

# Prefers this session's own recent turns, because a session's character is
# stable and differs a lot between them. Falls back to the account, then to a
# built-in default, so a cold start still answers.
kairos_predict() {
  kairos_puuid=${1:-unknown}
  kairos_psession=$(kairos_clean_session "$2")
  kairos_ppart=$(kairos_partition "$kairos_puuid") || { printf '%s\n' "$KAIROS_PREDICT_DEFAULT"; return 0; }
  kairos_pturns="$kairos_ppart/turns.tsv"
  if [ ! -s "$kairos_pturns" ]; then
    printf '%s\n' "$KAIROS_PREDICT_DEFAULT"
    return 0
  fi

  kairos_pvals=$(tail -n "$KAIROS_TURNS_READ" "$kairos_pturns" 2>/dev/null \
    | awk -F'\t' -v s="$kairos_psession" '$2 == s && $3 ~ /^[0-9]+$/ { print $3 }' \
    | tail -n "$KAIROS_TURN_WINDOW")
  kairos_pcount=$(printf '%s\n' "$kairos_pvals" | grep -c '^[0-9][0-9]*$')
  if [ "${kairos_pcount:-0}" -lt 3 ]; then
    kairos_pvals=$(tail -n "$KAIROS_TURNS_READ" "$kairos_pturns" 2>/dev/null \
      | awk -F'\t' '$3 ~ /^[0-9]+$/ { print $3 }' \
      | tail -n "$KAIROS_TURN_WINDOW")
    kairos_pcount=$(printf '%s\n' "$kairos_pvals" | grep -c '^[0-9][0-9]*$')
  fi
  if [ "${kairos_pcount:-0}" -lt 3 ]; then
    printf '%s\n' "$KAIROS_PREDICT_DEFAULT"
    return 0
  fi

  kairos_pest=$(printf '%s\n' "$kairos_pvals" | kairos_p75)
  # A zero estimate is not a cheap turn, it is a blind gate: the caller
  # multiplies this by the reserve, and zero always looks affordable however
  # little budget is left. Fall back rather than answer with something that
  # cannot protect anyone.
  if [ -z "$kairos_pest" ] || [ "$kairos_pest" -le 0 ] 2>/dev/null; then
    printf '%s\n' "$KAIROS_PREDICT_DEFAULT"
  else
    printf '%s\n' "$kairos_pest"
  fi
}
