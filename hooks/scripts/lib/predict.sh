# shellcheck shell=bash
# What the next turn is likely to cost.
#
# The 75th percentile of recent turns, not the mean. An estimator centred on the
# middle is wrong exactly when being wrong is expensive, because it is the tail
# that puts a session through the wall.

KAIROS_TURN_WINDOW=8

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
  printf '%s\t%s\t%s\n' "$(kairos_now)" "$2" "$3" >> "$kairos_tdir/turns.tsv"
}

# Prefers this session's own recent turns, because a session's character is
# stable and differs a lot between them. Falls back to the account, then to a
# built-in default, so a cold start still answers.
kairos_predict() {
  kairos_puuid=${1:-unknown}
  kairos_psession=${2:-unknown}
  kairos_ppart=$(kairos_partition "$kairos_puuid") || { printf '%s\n' "$KAIROS_PREDICT_DEFAULT"; return 0; }
  kairos_pturns="$kairos_ppart/turns.tsv"
  if [ ! -s "$kairos_pturns" ]; then
    printf '%s\n' "$KAIROS_PREDICT_DEFAULT"
    return 0
  fi

  kairos_pvals=$(awk -F'\t' -v s="$kairos_psession" '$2 == s { print $3 }' "$kairos_pturns" | tail -n "$KAIROS_TURN_WINDOW")
  kairos_pcount=$(printf '%s\n' "$kairos_pvals" | grep -c '[0-9]')
  if [ "${kairos_pcount:-0}" -lt 3 ]; then
    kairos_pvals=$(awk -F'\t' '{ print $3 }' "$kairos_pturns" | tail -n "$KAIROS_TURN_WINDOW")
    kairos_pcount=$(printf '%s\n' "$kairos_pvals" | grep -c '[0-9]')
  fi
  if [ "${kairos_pcount:-0}" -lt 3 ]; then
    printf '%s\n' "$KAIROS_PREDICT_DEFAULT"
    return 0
  fi

  kairos_pest=$(printf '%s\n' "$kairos_pvals" | kairos_p75)
  if [ -z "$kairos_pest" ]; then
    printf '%s\n' "$KAIROS_PREDICT_DEFAULT"
  else
    printf '%s\n' "$kairos_pest"
  fi
}
