# shellcheck shell=bash
# The meter. Reconstructs consumption from the transcripts, because nothing
# local reports it.
#
# Two things here are load-bearing and easy to undo by accident:
#
#   1. cache_read_input_tokens is NOT part of the sum. Measured against three
#      recorded refusals, weighting it at zero fits; including it at any weight
#      widens the spread across those refusals from 1.38x to over 4x.
#   2. Timestamps carry fractional seconds, which fromdateiso8601 rejects, so
#      they are stripped first.

KAIROS_EXTRACT_JQ='
fromjson?
| select(.message.usage != null)
| [ (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
    (.sessionId // "unknown"),
    (.message.model // "unknown"),
    ( (.message.usage.input_tokens // 0)
    + (.message.usage.cache_creation_input_tokens // 0)
    + (.message.usage.output_tokens // 0) ) ]
| @tsv'

# Appends everything written to the transcripts since the last call.
#
# Only files touched inside the ledger window are considered, which is also the
# only window a five-hour block can fall in, so the scan stays small however
# many transcripts have accumulated.
kairos_refresh() {
  kairos_ruuid=${1:-unknown}
  kairos_have_jq || return 0
  [ -d "$KAIROS_PROJECTS_DIR" ] || return 0
  kairos_rdir=$(kairos_partition "$kairos_ruuid") || return 0
  kairos_try_lock "$kairos_rdir" || return 0
  kairos_rcur="$kairos_rdir/cursors.tsv"
  kairos_rled="$kairos_rdir/ledger.tsv"
  kairos_rnew="$kairos_rdir/cursors.new.$$"
  : > "$kairos_rnew"

  find "$KAIROS_PROJECTS_DIR" -name '*.jsonl' -mmin -1440 2>/dev/null | while IFS= read -r kairos_f; do
    kairos_size=$(kairos_size_of "$kairos_f")
    kairos_off=0
    if [ -f "$kairos_rcur" ]; then
      kairos_off=$(awk -F'\t' -v p="$kairos_f" '$1 == p { print $2; exit }' "$kairos_rcur")
    fi
    [ -n "$kairos_off" ] || kairos_off=0
    # Smaller than we last saw means the file was replaced or truncated.
    if [ "$kairos_size" -lt "$kairos_off" ]; then kairos_off=0; fi
    if [ "$kairos_size" -eq "$kairos_off" ]; then
      printf '%s\t%s\n' "$kairos_f" "$kairos_size" >> "$kairos_rnew"
      continue
    fi
    tail -c "+$((kairos_off + 1))" "$kairos_f" 2>/dev/null \
      | jq -R -r "$KAIROS_EXTRACT_JQ" 2>/dev/null \
      | awk -F'\t' -v a="$kairos_ruuid" 'NF == 4 { print $1 "\t" a "\t" $2 "\t" $3 "\t" $4 }' \
      >> "$kairos_rled"
    printf '%s\t%s\n' "$kairos_f" "$kairos_size" >> "$kairos_rnew"
  done

  # Carry forward cursors for files the scan did not revisit, so a transcript
  # that goes quiet for a day is not re-read when it wakes up.
  if [ -f "$kairos_rcur" ]; then
    awk -F'\t' 'NR == FNR { seen[$1] = 1; next } !($1 in seen)' \
      "$kairos_rnew" "$kairos_rcur" > "$kairos_rnew.carry"
    cat "$kairos_rnew.carry" >> "$kairos_rnew"
    rm -f "$kairos_rnew.carry"
  fi
  mv "$kairos_rnew" "$kairos_rcur"
  kairos_unlock "$kairos_rdir"
  return 0
}

kairos_prune() {
  kairos_puuid=${1:-unknown}
  kairos_pdir=$(kairos_partition "$kairos_puuid") || return 0
  kairos_try_lock "$kairos_pdir" || return 0
  kairos_pled="$kairos_pdir/ledger.tsv"
  [ -f "$kairos_pled" ] || { kairos_unlock "$kairos_pdir"; return 0; }
  kairos_pcut=$(( $(kairos_now) - KAIROS_LEDGER_WINDOW ))
  if awk -F'\t' -v c="$kairos_pcut" '$1 >= c' "$kairos_pled" > "$kairos_pled.tmp.$$"; then
    mv "$kairos_pled.tmp.$$" "$kairos_pled"
  else
    rm -f "$kairos_pled.tmp.$$"
  fi
  kairos_unlock "$kairos_pdir"
  return 0
}

# Where the current five-hour block starts and ends, and what has been spent
# inside it. Prints "start<TAB>end<TAB>consumed".
#
# A window runs exactly five hours from where it opened, and the next one opens
# at the first message after the previous expired, floored to ten minutes. That
# is not a guess: reconstructing windows this way reproduces two of the three
# recorded resets on this machine to the minute, and the ten-minute floor is
# the granularity the server itself reports resets on.
#
# Chaining is the part that is easy to get wrong. An earlier version opened a
# window only after an idle gap of five hours, which meant a fourteen-hour
# working day was reported as one window with a reset time already in the past.
#
# When a refusal has been recorded inside the window, its resetsAt replaces the
# computed boundary, because the server's word beats arithmetic.
kairos_block() {
  kairos_buuid=${1:-unknown}
  kairos_bdir=$(kairos_partition "$kairos_buuid") || { printf '0\t0\t0\n'; return 0; }
  kairos_bled="$kairos_bdir/ledger.tsv"
  if [ ! -s "$kairos_bled" ]; then
    printf '0\t0\t0\n'
    return 0
  fi

  kairos_bres=$(sort -n "$kairos_bled" | awk -F'\t' -v gap="$KAIROS_BLOCK_SECONDS" '
    {
      # Skip anything that is not a positive integer epoch. awk would coerce a
      # garbage field to 0, which sets start to a literal 0 rather than leaving
      # it unset, and the window would render as 1970 instead of reporting
      # nothing to report.
      if ($1 !~ /^[0-9]+$/ || $1 + 0 <= 0) next
      if (start == "" || $1 >= start + gap) start = $1 - ($1 % 600)
      n++
      ts[n] = $1
      amt[n] = $5
    }
    END {
      if (start == "") { print "0\t0\t0"; exit }
      total = 0
      for (i = 1; i <= n; i++) if (ts[i] >= start) total += amt[i]
      printf "%d\t%d\t%d\n", start, start + gap, total
    }')

  kairos_bstart=$(printf '%s' "$kairos_bres" | cut -f1)
  kairos_bend=$(printf '%s' "$kairos_bres" | cut -f2)
  kairos_bused=$(printf '%s' "$kairos_bres" | cut -f3)

  kairos_bwalls="$kairos_bdir/walls.tsv"
  if [ -s "$kairos_bwalls" ] && [ "$kairos_bstart" -gt 0 ]; then
    kairos_blast=$(awk -F'\t' '$1 ~ /^[0-9]+$/ && $1 + 0 > m { m = $1 } END { printf "%d", m + 0 }' "$kairos_bled")
    # A refusal states the window [resets_at - gap, resets_at). Trust it only
    # when that window still holds the most recent activity, which is what
    # makes it the current window rather than one that has already ended.
    #
    # Without that test a stale or clock-skewed row moves the block into the
    # past and drops real consumption from the count. This function feeds the
    # gate, so usage it fails to see is a wall nobody warned you about.
    #
    # Picking by the largest qualifying resets_at rather than by file order,
    # so the answer does not depend on how walls.tsv happens to be sorted.
    kairos_breset=$(awk -F'\t' -v gap="$KAIROS_BLOCK_SECONDS" -v last="$kairos_blast" '
      $3 ~ /^[0-9]+$/ && $3 - gap <= last && last < $3 { print $3 }' "$kairos_bwalls" | sort -n | tail -1)
    if [ -n "$kairos_breset" ]; then
      kairos_bend=$kairos_breset
      kairos_bstart=$((kairos_breset - KAIROS_BLOCK_SECONDS))
      kairos_bused=$(awk -F'\t' -v s="$kairos_bstart" -v e="$kairos_bend" \
        '$1 >= s && $1 <= e { t += $5 } END { printf "%d", t + 0 }' "$kairos_bled")
    fi
  fi

  # A window that has already ended is not the current one. Reconstructing from
  # row timestamps alone cannot see that, and the consequence is severe: after a
  # window resets, the gate would keep weighing yesterday's spending against the
  # ceiling and refuse every prompt. That state is self sustaining, because a
  # refused prompt produces no assistant message, so no new row can ever arrive
  # to open the next window, and it would persist until pruning finally drops
  # the stale rows up to a day later.
  #
  # Nothing has been spent in the current window until something is written to
  # it, so say exactly that.
  if [ "$kairos_bend" -le "$(kairos_now)" ]; then
    printf '0\t0\t0\n'
    return 0
  fi

  printf '%s\t%s\t%s\n' "$kairos_bstart" "$kairos_bend" "$kairos_bused"
}
