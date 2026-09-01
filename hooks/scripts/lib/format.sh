# shellcheck shell=bash
# Turning integers into something worth reading.

# Every view is drawn to one width, so a report, an accounts table and the gate
# all rule off at the same column. Fixed rather than read from the terminal:
# a constant is the same in a test as it is in a pane, and 56 is narrow enough
# that nothing wraps in a split.
KAIROS_WIDTH=56
KAIROS_BAR=18

kairos_human() {
  awk -v n="${1:-0}" 'BEGIN {
    if (n >= 1000000) { printf "%.2fM\n", n / 1000000 }
    else if (n >= 1000) { printf "%dk\n", int(n / 1000) }
    else { printf "%d\n", n }
  }'
}

kairos_duration() {
  awk -v s="${1:-0}" 'BEGIN {
    if (s < 0) s = 0
    h = int(s / 3600); m = int((s % 3600) / 60)
    if (h > 0) { printf "%dh%02dm\n", h, m }
    else if (m > 0) { printf "%dm\n", m }
    else { printf "%ds\n", s }
  }'
}

kairos_pct() {
  awk -v v="${1:-0}" -v o="${2:-0}" 'BEGIN { if (o <= 0) print 0; else printf "%d\n", (v * 100) / o }'
}

# Characters, not bytes. Account labels carry an ellipsis and the rules are
# drawn from a box character, so printf's own %-*s padding counts three where
# the terminal shows one. Deleting UTF-8 continuation bytes leaves exactly one
# byte per character, which every locale then counts the same way.
kairos_width() {
  kairos_wtext=$(printf '%s' "${1:-}" | LC_ALL=C tr -d '\200-\277')
  printf '%s' "${#kairos_wtext}"
}

# Text, then spaces out to a column.
kairos_pad() {
  kairos_pn=$(( ${2:-0} - $(kairos_width "${1:-}") ))
  [ "$kairos_pn" -lt 0 ] && kairos_pn=0
  printf '%s%*s' "${1:-}" "$kairos_pn" ''
}

# A line of rule. Counted rather than measured, so it is drawn to the same
# width whether or not awk understands the character it is drawing.
kairos_rule() {
  awk -v n="${1:-0}" 'BEGIN { for (i = 0; i < n; i++) printf "─"; print "" }'
}

# The identity of a view on the left, its clock on the right, ruled off.
kairos_head() {
  printf '%s%s\n' "$(kairos_pad "${1:-}" $(( KAIROS_WIDTH - $(kairos_width "${2:-}") )))" "${2:-}"
  kairos_rule "$KAIROS_WIDTH"
}

# One share of a whole. A model that was used at all gets at least one cell,
# because rounding a real three percent down to an empty bar says it was never
# used, which is not what the ledger recorded.
kairos_bar() {
  awk -v v="${1:-0}" -v t="${2:-0}" -v w="${3:-18}" 'BEGIN {
    f = (t > 0) ? int((v * w / t) + 0.5) : 0
    if (f < 1 && v > 0) f = 1
    if (f > w) f = w
    for (i = 0; i < f; i++) printf "█"
    for (i = f; i < w; i++) printf "░"
    print ""
  }'
}

# The body of /kairos. Every number here is derived, and the ceiling is always a
# range, because it is not known to better than that.
kairos_report() {
  kairos_ruuid=${1:-unknown}
  kairos_rpart=$(kairos_partition "$kairos_ruuid") || return 1

  read -r kairos_rstart kairos_rend kairos_rused <<EOF
$(kairos_block "$kairos_ruuid")
EOF
  read -r kairos_rlow kairos_rhigh kairos_rconf <<EOF
$(kairos_band "$kairos_ruuid")
EOF
  kairos_rnow=$(kairos_now)

  if [ "$kairos_rstart" -eq 0 ]; then
    printf '%s\n' "$(kairos_account_label "$kairos_ruuid")"
    printf '  nothing recorded for this account yet\n'
    return 0
  fi

  kairos_relapsed=$((kairos_rnow - kairos_rstart))
  kairos_rburn=0
  if [ "$kairos_relapsed" -gt 0 ]; then
    kairos_rburn=$(awk -v u="$kairos_rused" -v e="$kairos_relapsed" 'BEGIN { printf "%d", (u * 3600) / e }')
  fi

  kairos_head "$(kairos_account_label "$kairos_ruuid")" \
    "resets in $(kairos_duration $((kairos_rend - kairos_rnow)))"

  if [ "$kairos_rconf" -eq 0 ]; then
    # No refusal has ever been recorded for this account, so there is no
    # ceiling to measure against. Saying "0%" here would read as "nothing
    # spent", which is the opposite of the truth, so say what is actually
    # the case: kairos is watching but will not interrupt yet.
    printf '  %-8s %s\n' used "$(kairos_human "$kairos_rused")"
    printf '  %-8s %s\n' ceiling 'none recorded yet · kairos will not interrupt'
  else
    if [ "$kairos_rconf" -eq 1 ]; then
      kairos_rwalls="wall"
    else
      kairos_rwalls="walls"
    fi
    printf '  %-8s %s · %s–%s%% of the wall\n' used \
      "$(kairos_human "$kairos_rused")" \
      "$(kairos_pct "$kairos_rused" "$kairos_rhigh")" \
      "$(kairos_pct "$kairos_rused" "$kairos_rlow")"
    printf '  %-8s %s to %s, from %s recorded %s\n' ceiling \
      "$(kairos_human "$kairos_rlow")" "$(kairos_human "$kairos_rhigh")" \
      "$kairos_rconf" "$kairos_rwalls"
  fi
  printf '  %-8s %s/h over %s of this block\n' burn \
    "$(kairos_human "$kairos_rburn")" "$(kairos_duration "$kairos_relapsed")"

  kairos_report_models "$kairos_rpart" "$kairos_rstart"

  if [ -s "$kairos_rpart/turns.tsv" ]; then
    kairos_rturns=$(wc -l < "$kairos_rpart/turns.tsv" | tr -d ' ')
    if [ "$kairos_rturns" = "1" ]; then
      kairos_rword="turn"
    else
      kairos_rword="turns"
    fi
    printf '\n  %s %s · next turn ~%s\n' \
      "$kairos_rturns" "$kairos_rword" "$(kairos_human "$(kairos_predict "$kairos_ruuid" unknown)")"
  fi
}

# The split across models, as bars. Kept apart from the report because it is
# the one part with a column layout of its own to work out.
kairos_report_models() {
  kairos_mpart=${1:-}
  kairos_mstart=${2:-0}
  [ -s "$kairos_mpart/ledger.tsv" ] || return 0

  # The dated build of a model is the same model. Stripping the suffix before
  # the totals are summed keeps two builds of one model on one row rather than
  # splitting the share between them.
  kairos_mrows=$(awk -F'\t' -v s="$kairos_mstart" '
    $1 >= s {
      m = $4
      sub(/-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/, "", m)
      t[m] += $5
    }
    END { for (m in t) printf "%s %d\n", m, t[m] }' "$kairos_mpart/ledger.tsv" | sort -k2 -rn)

  # The window can start after every row the ledger holds, which leaves nothing
  # to show. A heading over an empty table is worse than no heading.
  [ -n "$kairos_mrows" ] || return 0

  kairos_mtotal=0
  kairos_mnamew=16
  while read -r kairos_mn kairos_mv; do
    [ -n "$kairos_mn" ] || continue
    kairos_mtotal=$((kairos_mtotal + kairos_mv))
    [ "${#kairos_mn}" -gt "$kairos_mnamew" ] && kairos_mnamew=${#kairos_mn}
  done <<EOF
$kairos_mrows
EOF

  printf '\n'
  while read -r kairos_mn kairos_mv; do
    [ -n "$kairos_mn" ] || continue
    printf '  %-*s  %s  %6s  %3s%%\n' \
      "$kairos_mnamew" "$kairos_mn" \
      "$(kairos_bar "$kairos_mv" "$kairos_mtotal" "$KAIROS_BAR")" \
      "$(kairos_human "$kairos_mv")" \
      "$(kairos_pct "$kairos_mv" "$kairos_mtotal")"
  done <<EOF
$kairos_mrows
EOF
}

# Every account kairos has seen, and where each one stands. For anyone holding
# two subscriptions this is what turns switching into a decision.
kairos_accounts_report() {
  kairos_aactive=${1:-}
  [ -d "$KAIROS_HOME/accounts" ] || return 0
  kairos_anow=$(kairos_now)

  # The label column is sized from the labels themselves. An alias is whatever
  # the user chose to call the account, and a fixed column would either cut it
  # or leave every row after it hanging off its own alignment.
  kairos_anamew=18
  for kairos_adir in "$KAIROS_HOME/accounts"/*; do
    [ -d "$kairos_adir" ] || continue
    kairos_aw=$(kairos_width "$(kairos_account_label "$(basename "$kairos_adir")")")
    [ "$kairos_aw" -gt "$kairos_anamew" ] && kairos_anamew="$kairos_aw"
  done

  printf '  %s %6s   %s%s\n' "$(kairos_pad account "$kairos_anamew")" \
    used "$(kairos_pad 'of wall' 9)" window
  kairos_rule "$KAIROS_WIDTH"

  for kairos_adir in "$KAIROS_HOME/accounts"/*; do
    [ -d "$kairos_adir" ] || continue
    kairos_auuid=$(basename "$kairos_adir")
    # shellcheck disable=SC2034  # kairos_astart is read to consume the field
    read -r kairos_astart kairos_aend kairos_aused <<EOF
$(kairos_block "$kairos_auuid")
EOF
    read -r kairos_alow kairos_ahigh kairos_aconf <<EOF
$(kairos_band "$kairos_auuid")
EOF
    kairos_amark="  "
    [ "$kairos_auuid" = "$kairos_aactive" ] && kairos_amark="▸ "
    if [ "$kairos_aend" -gt "$kairos_anow" ]; then
      kairos_awhen="resets in $(kairos_duration $((kairos_aend - kairos_anow)))"
    else
      kairos_awhen="block clear"
    fi
    # An account with no recorded wall has no fraction to show. Printing zero
    # percent here would read as "nothing spent" beside a real used figure,
    # which is the same untruth the report and the summary already avoid.
    if [ "$kairos_aused" -eq 0 ]; then
      # A block with nothing spent in it has no fraction either. "0-0%" reads
      # as a measurement that came back zero, when the truth is that there was
      # nothing to measure.
      kairos_ashare="no spend"
    elif [ "${kairos_aconf:-0}" -eq 0 ]; then
      kairos_ashare="no wall"
    else
      kairos_ashare="$(kairos_pct "$kairos_aused" "$kairos_ahigh")–$(kairos_pct "$kairos_aused" "$kairos_alow")%"
    fi
    printf '%s%s %6s   %s%s\n' "$kairos_amark" \
      "$(kairos_pad "$(kairos_account_label "$kairos_auuid")" "$kairos_anamew")" \
      "$(kairos_human "$kairos_aused")" \
      "$(kairos_pad "$kairos_ashare" 9)" "$kairos_awhen"
  done
}

# Another known account whose block has already ended, if there is one. Knowing
# this needs no login: that partition records what was spent and when, and time
# keeps moving, so a block whose end has passed is clear even though nothing has
# been written to it since.
kairos_other_clear_account() {
  kairos_oactive=${1:-}
  [ -d "$KAIROS_HOME/accounts" ] || return 0
  kairos_onow=$(kairos_now)
  for kairos_odir in "$KAIROS_HOME/accounts"/*; do
    [ -d "$kairos_odir" ] || continue
    kairos_ouuid=$(basename "$kairos_odir")
    [ "$kairos_ouuid" = "$kairos_oactive" ] && continue
    [ "$kairos_ouuid" = "unknown" ] && continue
    # shellcheck disable=SC2034  # only kairos_oend is used, the rest consume fields
    read -r kairos_ostart kairos_oend kairos_oused <<EOF
$(kairos_block "$kairos_ouuid")
EOF
    # kairos_block reports zeros both for an account whose window has ended and
    # for one that was never metered at all, so the block alone cannot tell them
    # apart. The ledger can: an account with no consumption recorded is not
    # clear, it is unknown, and suggesting a switch to it would be a guess
    # dressed as a fact.
    [ -s "$KAIROS_HOME/accounts/$kairos_ouuid/ledger.tsv" ] || continue
    if [ "$kairos_oend" -le "$kairos_onow" ]; then
      printf '%s\n' "$kairos_ouuid"
      return 0
    fi
  done
  return 0
}

# The closing line, in the register claude-timestamp uses for its own.
kairos_summary_line() {
  kairos_suuid=${1:-unknown}
  kairos_spart=$(kairos_partition "$kairos_suuid") || return 1
  # shellcheck disable=SC2034  # only kairos_sused is used, the rest consume fields
  read -r kairos_sstart kairos_send kairos_sused <<EOF
$(kairos_block "$kairos_suuid")
EOF
  # shellcheck disable=SC2034  # kairos_sconf is read to consume the field
  read -r kairos_slow kairos_shigh kairos_sconf <<EOF
$(kairos_band "$kairos_suuid")
EOF
  kairos_sturns=0
  if [ -f "$kairos_spart/turns.tsv" ]; then
    kairos_sturns=$(wc -l < "$kairos_spart/turns.tsv" | tr -d ' ')
  fi
  if [ "$kairos_sturns" = "1" ]; then
    kairos_sword="turn"
  else
    kairos_sword="turns"
  fi
  # Without a recorded wall there is no window fraction to report, and printing
  # "0 to 0 percent" here would tell the reader they spent nothing on the way
  # out of a session where they spent plenty.
  if [ "${kairos_sconf:-0}" -eq 0 ]; then
    printf 'kairos: %s billable over %s %s, no ceiling recorded yet.\n' \
      "$(kairos_human "$kairos_sused")" "$kairos_sturns" "$kairos_sword"
  else
    printf 'kairos: %s billable over %s %s, %s–%s%% of the window.\n' \
      "$(kairos_human "$kairos_sused")" "$kairos_sturns" "$kairos_sword" \
      "$(kairos_pct "$kairos_sused" "$kairos_shigh")" \
      "$(kairos_pct "$kairos_sused" "$kairos_slow")"
  fi
}
