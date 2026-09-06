# shellcheck shell=bash
# Refusals are the only ground truth about where the wall is, so they are
# harvested and kept. Everything the band knows comes from here.

# A refusal carries the owner of the transcript it was written in, resolved the
# same way the meter resolves a usage row: the most recent ownerAccountUuid at
# or before it, and otherwise by the session it was written under.
#
# Emits hit, reset, owner and session; the owner is left empty for the caller
# to place, because placing it needs the session map.
# $l is jq's own variable, so this stays single quoted.
# shellcheck disable=SC2016
KAIROS_WALL_JQ='
foreach (inputs | fromjson? | select(type == "object")) as $l ({o: ""};
  .o = ($l.ownerAccountUuid // .o)
  | .r = (try (
      if ($l.quotaLimits.status == "rejected"
          and $l.quotaLimits.rateLimitType == "five_hour") then
        [ ($l.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
          $l.quotaLimits.resetsAt,
          .o,
          ($l.sessionId // "") ]
      else null end) catch null);
  .r // empty | @tsv)'

# Sets aside walls recorded before attribution existed, once.
#
# Until the session map, every refusal in every transcript was credited to
# whichever account happened to be reading, so on a machine with more than one
# subscription a recorded wall may belong to either of them. There is no way to
# tell after the fact which, and a wall is what grants kairos the right to
# interrupt: one wrong entry is enough to refuse every prompt for a window, and
# nothing prunes walls.tsv, so it would do that forever.
#
# They are moved rather than deleted, and to a file the dedup does not consult,
# so a rescan re-derives the real ones under the new rules and nothing is lost
# in the meantime. An account left with no walls does not gate at all, which is
# the safe direction and exactly what the design asks for: kairos earns the
# right to interrupt by observing a refusal of its own.
#
# A machine with one account was never ambiguous and is left alone.
kairos_walls_migrate() {
  kairos_gmark="$KAIROS_HOME/walls.attributed"
  [ -f "$kairos_gmark" ] && return 0
  kairos_ensure_dir "$KAIROS_HOME" || return 1
  kairos_gn=0
  for kairos_gd in "$KAIROS_HOME"/accounts/*/; do
    [ -d "$kairos_gd" ] || continue
    kairos_gn=$((kairos_gn + 1))
  done
  if [ "$kairos_gn" -ge 2 ]; then
    for kairos_gd in "$KAIROS_HOME"/accounts/*/; do
      [ -s "$kairos_gd/walls.tsv" ] || continue
      cat "$kairos_gd/walls.tsv" >> "$kairos_gd/walls.superseded.tsv" 2>/dev/null \
        && rm -f "$kairos_gd/walls.tsv"
    done
  fi
  : > "$kairos_gmark" 2>/dev/null
  return 0
}

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
  kairos_walls_migrate
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
  # The session map, written by the meter. awk is given it by name below, and a
  # name that does not exist is a fatal error there rather than an empty input.
  kairos_wmap="$KAIROS_HOME/owners.tsv"
  [ -f "$kairos_wmap" ] || : > "$kairos_wmap" 2>/dev/null

  # Carriage returns are stripped rather than assumed absent. A transcript
  # written with CRLF leaves one on the last field, and this one is a reset
  # timestamp that goes straight into arithmetic, where a stray CR is not a
  # wrong answer but a hard error. Dedup is done here rather than with
  # sort -u so the pipeline depends on one less external tool.
  #
  # One jq per file rather than one over the concatenation, because the owner
  # has to be carried within a file and must not leak across the boundary
  # between two.
  #
  # A refusal belonging to another account is dropped: it is not this account's
  # evidence in any sense, and the account that does own it records it when it
  # next runs.
  #
  # A refusal nothing can place is marked orphan and set aside. It is tempting
  # to credit it to whoever is reading, and that is what the old code did to
  # every refusal, but a wall is the one thing that grants kairos the right to
  # interrupt: the same refusal read by two accounts becomes a ceiling for both,
  # and the smaller plan's ceiling then blocks every prompt on the larger one.
  #
  # Two conditions, both required. There has to be ownership information on
  # this machine at all, or there is nothing to be ambiguous against and no way
  # a single-account machine would ever calibrate. And there has to be more
  # than one account, or there is only one candidate and crediting the reader
  # is simply correct. /kairos calibrate rescans transcripts far older than the
  # map covers, and on a one-account machine those must still count.
  kairos_wmulti=0
  for kairos_wa in "$KAIROS_HOME"/accounts/*/; do
    [ -d "$kairos_wa" ] || continue
    kairos_wmulti=$((kairos_wmulti + 1))
  done
  [ "$kairos_wmulti" -ge 2 ] || kairos_wmulti=0
  find "$KAIROS_PROJECTS_DIR" -name '*.jsonl' "$@" 2>/dev/null \
    | while IFS= read -r kairos_wf; do
        jq -n -R -r "$KAIROS_WALL_JQ" < "$kairos_wf" 2>/dev/null
      done \
    | tr -d '\r' \
    | awk -F'\t' -v a="$kairos_wuuid" -v m="$kairos_wmap" -v multi="$kairos_wmulti" '
        FILENAME == m { own[$1] = $2; mapped = 1; next }
        NF == 4 {
          o = $3
          if (o == "") o = own[$4]
          if (o == "") { if (mapped && multi) tag = "orphan"; else tag = "own"; o = a }
          else tag = "own"
          if (o != a) next
          if (seen[$2]++) next
          print $1 "\t" $2 "\t" tag
        }' "$kairos_wmap" - > "$kairos_wraw"

  while IFS="$(printf '\t')" read -r kairos_whit kairos_wreset kairos_wtag; do
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
    #
    # A wall whose consumption comes out as zero is kept the same way. The
    # ledger only ever covers a day, so any refusal older than that has no
    # rows left to count and would otherwise be written as a ceiling of zero,
    # which the band then silently discards. Recording it here keeps calibrate
    # honest: it can say what it found and what it could not use, instead of
    # counting rows the band will not.
    if [ "$kairos_wtag" = "orphan" ] || [ "$kairos_whit" -lt "$kairos_wseen" ] || [ "${kairos_wused:-0}" -le 0 ]; then
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
