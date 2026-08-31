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
