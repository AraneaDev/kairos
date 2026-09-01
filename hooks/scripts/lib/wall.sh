# shellcheck shell=bash
# Refusals are the only ground truth about where the wall is, so they are
# harvested and kept. Everything the band knows comes from here.

KAIROS_WALL_JQ='
fromjson?
| select(.quotaLimits.status == "rejected" and .quotaLimits.rateLimitType == "five_hour")
| [ (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601), .quotaLimits.resetsAt ]
| @tsv'

# Scans transcripts for five-hour refusals and records each as a wall.
#
# Defaults to files touched in the last day, which is what a session needs.
# Pass a different find predicate for a full rescan, which is what
# /kairos calibrate does.
kairos_harvest_walls() {
  kairos_wuuid=${1:-unknown}
  shift 2>/dev/null || true
  kairos_have_jq || return 0
  [ -d "$KAIROS_PROJECTS_DIR" ] || return 0
  kairos_wdir=$(kairos_partition "$kairos_wuuid") || return 0
  kairos_try_lock "$kairos_wdir" || return 0
  kairos_wled="$kairos_wdir/ledger.tsv"
  kairos_wfile="$kairos_wdir/walls.tsv"
  kairos_wunattr="$kairos_wdir/walls.unattributed.tsv"
  kairos_wseen=$(kairos_meta_get "$kairos_wdir" first_seen)
  # An account whose first_seen was never written has no point from which its
  # walls can be trusted, so nothing is attributable yet. Defaulting to 0 would
  # do the opposite and calibrate off refusals that may belong to another
  # subscription entirely.
  [ -n "$kairos_wseen" ] || kairos_wseen=$(kairos_now)

  if [ "$#" -gt 0 ]; then
    set -- "$@"
  else
    set -- -mmin -1440
  fi

  kairos_wraw="$kairos_wdir/.walls.raw.$$"
  find "$KAIROS_PROJECTS_DIR" -name '*.jsonl' "$@" -exec cat {} + 2>/dev/null \
    | jq -R -r "$KAIROS_WALL_JQ" 2>/dev/null \
    | sort -u -k2,2n > "$kairos_wraw"

  while IFS="$(printf '\t')" read -r kairos_whit kairos_wreset; do
    [ -n "$kairos_wreset" ] || continue
    # One wall per reset, however many messages reported it.
    if [ -f "$kairos_wfile" ] && awk -F'\t' -v r="$kairos_wreset" '$3 == r { found = 1 } END { exit !found }' "$kairos_wfile"; then
      continue
    fi
    if [ -f "$kairos_wunattr" ] && awk -F'\t' -v r="$kairos_wreset" '$3 == r { found = 1 } END { exit !found }' "$kairos_wunattr"; then
      continue
    fi
    kairos_wstart=$((kairos_wreset - KAIROS_BLOCK_SECONDS))
    kairos_wused=0
    if [ -f "$kairos_wled" ]; then
      kairos_wused=$(awk -F'\t' -v s="$kairos_wstart" -v e="$kairos_wreset" \
        '$1 >= s && $1 <= e { t += $5 } END { printf "%d", t + 0 }' "$kairos_wled")
    fi
    # A wall from before this account was first seen may belong to a different
    # subscription entirely. Kept, reported, never used to calibrate.
    if [ "$kairos_whit" -lt "$kairos_wseen" ]; then
      printf '%s\t%s\t%s\n' "$kairos_whit" "$kairos_wused" "$kairos_wreset" >> "$kairos_wunattr"
    else
      printf '%s\t%s\t%s\n' "$kairos_whit" "$kairos_wused" "$kairos_wreset" >> "$kairos_wfile"
    fi
  done < "$kairos_wraw"
  rm -f "$kairos_wraw"
  kairos_unlock "$kairos_wdir"
  return 0
}

# The band this account's ceiling is believed to lie in, as "low high count".
#
# Never a single number. Three recorded refusals on the machine this was
# designed against spanned 1.38x, so a bare percentage would be inventing
# precision. The margin narrows once there are enough walls to average out.
kairos_band() {
  kairos_nuuid=${1:-unknown}
  kairos_ndir=$(kairos_partition "$kairos_nuuid") || { printf '0\t0\t0\n'; return 0; }
  kairos_nfile="$kairos_ndir/walls.tsv"
  # No walls means no band. Not a guessed one.
  #
  # An earlier version seeded 4.1M to 5.7M here, from the three refusals
  # recorded on the machine this was designed against. Reconstructing every
  # window in that same history showed windows reaching 16.5M without any
  # refusal at all, so those three figures describe one subscription and not
  # the shape of the limit. A seeded band would have made kairos block
  # constantly on a larger plan while claiming to know something it did not.
  #
  # Callers treat a confidence of 0 as "do not gate". kairos measures and
  # reports from the first minute, and earns the right to interrupt only once
  # this account has recorded a refusal of its own.
  if [ ! -s "$kairos_nfile" ]; then
    printf '0\t0\t0\n'
    return 0
  fi
  awk -F'\t' '
    # Only a positive integer consumption is a usable wall. awk coerces a blank
    # or malformed row to 0, which would drag the low edge to zero while still
    # counting toward confidence: a band the gate acts on, derived from a row
    # that says nothing.
    $2 ~ /^[0-9]+$/ && $2 + 0 > 0 {
      if (n == 0 || $2 < lo) lo = $2
      if (n == 0 || $2 > hi) hi = $2
      n++
    }
    END {
      if (n == 0) { print "0\t0\t0"; exit }
      margin = (n >= 3) ? 0.05 : 0.15
      printf "%d\t%d\t%d\n", lo * (1 - margin), hi * (1 + margin), n
    }' "$kairos_nfile"
}
