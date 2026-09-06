# shellcheck shell=bash
# The meter. Reconstructs consumption from the transcripts, because nothing
# local reports it.
#
# Three things here are load-bearing and easy to undo by accident:
#
#   1. cache_read_input_tokens is NOT part of the sum. Measured against three
#      recorded refusals, weighting it at zero fits; including it at any weight
#      widens the spread across those refusals from 1.38x to over 4x.
#   2. Timestamps carry fractional seconds, which fromdateiso8601 rejects, so
#      they are stripped first.
#   3. A row belongs to the account that was live when the transcript was
#      written, which is not necessarily the account reading it. See
#      kairos_refresh.

# Extracts usage rows, carrying the owning account forward as it goes.
#
# Claude Code writes ownerAccountUuid on its bridge-session lines, interleaved
# through the file rather than only at the top, so a session that spans a
# /login records both accounts in order. Each usage line therefore belongs to
# the most recent marker at or before it.
#
# A file with no marker leaves the owner empty for the caller to resolve, and
# that is the common case rather than the exception: subagent transcripts are
# written to a subagents/ directory carrying no marker at all, and on the
# machine this was found on they were 1050 of 1216 transcripts. They do carry
# the parent's session id, so kairos_refresh places them through the session
# map rather than guessing.
#
# Emits two record kinds: R for a usage row, O each time an owner is stated,
# carrying the session it was stated for.
#
# select(type == "object") because a transcript line that is valid JSON but not
# an object (a bare string, say) would otherwise abort the whole stream on the
# first field access, taking the carried owner with it.
# $l and $dflt are jq's own variables, so this stays single quoted.
# shellcheck disable=SC2016
KAIROS_EXTRACT_JQ='
foreach (inputs | fromjson? | select(type == "object")) as $l ({o: $dflt};
  .o = ($l.ownerAccountUuid // .o)
  | .m = ($l.ownerAccountUuid != null)
  | .r = (try (
      if ($l.message.usage // null) != null then
        [ "R",
          ($l.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
          .o,
          ($l.sessionId // "unknown"),
          ($l.message.model // "unknown"),
          ( ($l.message.usage.input_tokens // 0)
          + ($l.message.usage.cache_creation_input_tokens // 0)
          + ($l.message.usage.output_tokens // 0) ) ]
      else null end) catch null);
  ( if .m then ["O", ($l.sessionId // ""), .o] else empty end ), (.r // empty)
  | @tsv)'

# Folds any pre-existing per-account cursors into the global one, once.
#
# Without this the first refresh after an upgrade finds no global cursor, reads
# every transcript from the start and counts a day of history a second time.
# The highest offset any account reached is the right one to carry forward:
# those bytes have already been ledgered by somebody, and reading them again
# would inflate the very window the gate measures.
kairos_cursor_migrate() {
  kairos_cmfile="$KAIROS_HOME/cursors.tsv"
  [ -f "$kairos_cmfile" ] && return 0
  kairos_ensure_dir "$KAIROS_HOME" || return 1
  kairos_cmtmp="$KAIROS_HOME/cursors.migrate.$$"
  : > "$kairos_cmtmp" 2>/dev/null || return 1
  for kairos_cmold in "$KAIROS_HOME"/accounts/*/cursors.tsv; do
    [ -f "$kairos_cmold" ] || continue
    cat "$kairos_cmold" >> "$kairos_cmtmp" 2>/dev/null
  done
  # Owner is left empty: nothing in the old format recorded it, and an empty
  # owner falls back to the reading account exactly as an unmarked file does.
  if awk -F'\t' '$1 != "" && $2 ~ /^[0-9]+$/ { if ($2 + 0 > off[$1]) off[$1] = $2 + 0 }
    END { for (p in off) printf "%s\t%d\t\n", p, off[p] }' "$kairos_cmtmp" > "$kairos_cmtmp.out" 2>/dev/null; then
    mv "$kairos_cmtmp.out" "$kairos_cmfile" 2>/dev/null
  fi
  rm -f "$kairos_cmtmp" "$kairos_cmtmp.out"
  return 0
}

# Appends everything written to the transcripts since the last call, routing
# each row to the account that owned it when it was written.
#
# The cursor is global, deliberately. An earlier version kept it inside the
# account partition, which meant that after a /login every transcript looked
# unread to the new partition: the whole file was replayed into it and stamped
# with the new account. On the machine this was found on that put 6.8M tokens
# of one subscription's spending into the other's ledger, and let a Pro refusal
# be recorded as a Max ceiling of 2.96M. The gate then measured an inflated
# figure against a ceiling four times too low and refused every prompt for the
# rest of the window.
#
# So the bytes of a transcript are read exactly once, by whichever account gets
# there first, and attribution comes from the transcript rather than from the
# reader.
#
# Only files touched inside the ledger window are considered, which is also the
# only window a five-hour block can fall in, so the scan stays small however
# many transcripts have accumulated.
kairos_refresh() {
  kairos_ruuid=${1:-unknown}
  kairos_have_jq || return 0
  [ -d "$KAIROS_PROJECTS_DIR" ] || return 0
  kairos_ensure_dir "$KAIROS_HOME" || return 0
  kairos_cursor_migrate
  # A single lock for the cursor, because the whole point is that two accounts
  # never read the same bytes.
  kairos_try_lock "$KAIROS_HOME" cursors.lock || return 0
  kairos_rcur="$KAIROS_HOME/cursors.tsv"
  kairos_rnew="$KAIROS_HOME/cursors.new.$$"
  kairos_rrows="$KAIROS_HOME/rows.$$"
  kairos_rmarks="$KAIROS_HOME/marks.$$"
  : > "$kairos_rnew"
  : > "$kairos_rrows"
  : > "$kairos_rmarks"

  find "$KAIROS_PROJECTS_DIR" -name '*.jsonl' -mmin -1440 2>/dev/null | while IFS= read -r kairos_f; do
    kairos_size=$(kairos_size_of "$kairos_f")
    kairos_off=0
    kairos_owner=""
    if [ -f "$kairos_rcur" ]; then
      kairos_off=$(awk -F'\t' -v p="$kairos_f" '$1 == p { print $2; exit }' "$kairos_rcur")
      kairos_owner=$(awk -F'\t' -v p="$kairos_f" '$1 == p { print $3; exit }' "$kairos_rcur")
    fi
    [ -n "$kairos_off" ] || kairos_off=0
    # Nothing carried from a previous read, so fall to what a hook observed
    # about this file. Left empty when no hook has seen it either, which leaves
    # the rows to be placed by session below.
    if [ -z "$kairos_owner" ] && [ -f "$KAIROS_HOME/paths.tsv" ]; then
      kairos_owner=$(awk -F'\t' -v p="$kairos_f" '$1 == p { print $2; exit }' \
        "$KAIROS_HOME/paths.tsv" 2>/dev/null)
    fi
    # The owner in force where the last read stopped, carried because the
    # markers sit near the top of a file and an incremental read usually
    # contains none at all. Empty when the file has never stated one, which
    # leaves the row to be placed by session below.
    # Smaller than we last saw means the file was replaced or truncated.
    if [ "$kairos_size" -lt "$kairos_off" ]; then kairos_off=0; kairos_owner=""; fi
    if [ "$kairos_size" -eq "$kairos_off" ]; then
      printf '%s\t%s\t%s\n' "$kairos_f" "$kairos_size" "$kairos_owner" >> "$kairos_rnew"
      continue
    fi
    # Bounded by the size captured above, not read to whatever the current end
    # of the file happens to be. Claude Code is often flushing a turn's final
    # message while this runs, and anything appended between the size capture
    # and this read would be ingested now and ingested again next time, because
    # the cursor written below records the older size. A double counted row
    # both blocks prompts that should pass and, if it lands inside a refusal
    # window, permanently inflates that wall's recorded consumption.
    kairos_rchunk="$KAIROS_HOME/chunk.$$"
    tail -c "+$((kairos_off + 1))" "$kairos_f" 2>/dev/null \
      | head -c "$((kairos_size - kairos_off))" 2>/dev/null \
      | jq -n -R -r --arg dflt "$kairos_owner" "$KAIROS_EXTRACT_JQ" 2>/dev/null \
      | tr -d '\r' > "$kairos_rchunk"
    awk -F'\t' '$1 == "R" && NF == 6 { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' \
      "$kairos_rchunk" >> "$kairos_rrows"
    awk -F'\t' '$1 == "O" && NF == 3 && $2 != "" && $3 != "" { print $2 "\t" $3 }' \
      "$kairos_rchunk" >> "$kairos_rmarks"
    kairos_last=$(awk -F'\t' '$1 == "O" && NF == 3 { o = $3 } END { print o }' "$kairos_rchunk")
    [ -n "$kairos_last" ] || kairos_last=$kairos_owner
    rm -f "$kairos_rchunk"
    printf '%s\t%s\t%s\n' "$kairos_f" "$kairos_size" "$kairos_last" >> "$kairos_rnew"
  done

  # Which account each session belongs to, remembered across refreshes.
  #
  # This is what places the subagent transcripts, and it has to be persisted:
  # a subagent file can be read in a later refresh than the one that saw its
  # parent's marker, and the parent may not have been written to since.
  # Later statements win, so a session that changes hands is remembered as its
  # most recent owner.
  kairos_rmap="$KAIROS_HOME/owners.tsv"
  # awk is given this file by name in both passes below, and a name that does
  # not exist is a fatal error there, not an empty input.
  [ -f "$kairos_rmap" ] || : > "$kairos_rmap" 2>/dev/null
  if [ -s "$kairos_rmarks" ]; then
    if awk -F'\t' 'NF == 2 { m[$1] = $2 } END { for (k in m) print k "\t" m[k] }' \
      "$kairos_rmap" "$kairos_rmarks" > "$kairos_rmap.tmp.$$" 2>/dev/null; then
      mv "$kairos_rmap.tmp.$$" "$kairos_rmap" 2>/dev/null
    else
      rm -f "$kairos_rmap.tmp.$$"
    fi
  fi
  rm -f "$kairos_rmarks"

  # Rows the file itself did not place are placed by session, and only then by
  # the account doing the reading.
  #
  # Falling back to the reader is right for a ledger row even though it is
  # wrong for a wall. A row credited to the wrong account overstates that
  # account's usage, which makes the gate fire early; a wall credited to the
  # wrong account understates its ceiling, which makes the gate fire always.
  # Undercounting is the direction that lets a limit arrive unannounced, so a
  # row is always counted somewhere.
  if awk -F'\t' -v d="$kairos_ruuid" -v m="$kairos_rmap" '
    FILENAME == m { own[$1] = $2; next }
    NF == 5 {
      o = $2
      if (o == "") o = own[$3]
      if (o == "") o = d
      print $1 "\t" o "\t" $3 "\t" $4 "\t" $5
    }' "$kairos_rmap" "$kairos_rrows" > "$kairos_rrows.placed" 2>/dev/null; then
    mv "$kairos_rrows.placed" "$kairos_rrows"
  else
    rm -f "$kairos_rrows.placed"
  fi

  # Each owner's rows go into that owner's ledger. The append needs no further
  # lock: the cursor lock taken above is held for the whole call, and
  # kairos_prune takes that same lock, so no rewrite of a ledger can interleave
  # with these appends. Waiting on each account's own lock here would be worse
  # than useless, because the cursor has already moved past these bytes and a
  # caller that gave up would drop the rows for good.
  #
  # An owner that fails kairos_partition is a corrupt transcript, and its rows
  # are dropped rather than pooled under the shared fallback name, which is the
  # same judgement kairos_partition itself makes.
  awk -F'\t' 'NF == 5 { print $2 }' "$kairos_rrows" | sort -u | while IFS= read -r kairos_ro; do
    [ -n "$kairos_ro" ] || continue
    kairos_rodir=$(kairos_partition "$kairos_ro") || continue
    awk -F'\t' -v o="$kairos_ro" 'NF == 5 && $2 == o' "$kairos_rrows" >> "$kairos_rodir/ledger.tsv"
  done
  rm -f "$kairos_rrows"

  # Carry forward cursors for files the scan did not revisit, so a transcript
  # that goes quiet for a day is not re-read when it wakes up.
  if [ -f "$kairos_rcur" ]; then
    awk -F'\t' 'NR == FNR { seen[$1] = 1; next } !($1 in seen)' \
      "$kairos_rnew" "$kairos_rcur" > "$kairos_rnew.carry"
    cat "$kairos_rnew.carry" >> "$kairos_rnew"
    rm -f "$kairos_rnew.carry"
  fi
  mv "$kairos_rnew" "$kairos_rcur"
  kairos_unlock "$KAIROS_HOME" cursors.lock
  return 0
}

# Trims the ledger to the retention window.
#
# Takes the global cursor lock as well as this account's, because a refresh
# appends to ledgers it does not hold the partition lock for. Without the
# shared lock a prune could read the ledger, have a refresh append underneath
# it, and then replace the file with its pre-append copy, silently deleting
# turns the gate is about to be asked to weigh.
kairos_prune() {
  kairos_puuid=${1:-unknown}
  kairos_pdir=$(kairos_partition "$kairos_puuid") || return 0
  kairos_try_lock "$KAIROS_HOME" cursors.lock || return 0
  if ! kairos_try_lock "$kairos_pdir"; then
    kairos_unlock "$KAIROS_HOME" cursors.lock
    return 0
  fi
  kairos_pled="$kairos_pdir/ledger.tsv"
  if [ ! -f "$kairos_pled" ]; then
    kairos_unlock "$kairos_pdir"
    kairos_unlock "$KAIROS_HOME" cursors.lock
    return 0
  fi
  kairos_pcut=$(( $(kairos_now) - KAIROS_LEDGER_WINDOW ))
  if awk -F'\t' -v c="$kairos_pcut" '$1 >= c' "$kairos_pled" > "$kairos_pled.tmp.$$"; then
    mv "$kairos_pled.tmp.$$" "$kairos_pled"
  else
    rm -f "$kairos_pled.tmp.$$"
  fi
  kairos_unlock "$kairos_pdir"
  kairos_unlock "$KAIROS_HOME" cursors.lock
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
