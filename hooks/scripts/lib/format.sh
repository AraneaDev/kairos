# shellcheck shell=bash
# Turning integers into something worth reading.

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

# The body of /kairos. Every number here is derived, and the band is always a
# range, because the ceiling is not known to better than that.
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
  kairos_relapsed=$((kairos_rnow - kairos_rstart))
  [ "$kairos_rstart" -gt 0 ] || kairos_relapsed=0
  kairos_rburn=0
  if [ "$kairos_relapsed" -gt 0 ]; then
    kairos_rburn=$(awk -v u="$kairos_rused" -v e="$kairos_relapsed" 'BEGIN { printf "%d", (u * 3600) / e }')
  fi

  printf '%s\n' "$(kairos_account_label "$kairos_ruuid")"
  if [ "$kairos_rstart" -eq 0 ]; then
    printf '  nothing recorded for this account yet\n'
    return 0
  fi
  if [ "$kairos_rconf" -eq 1 ]; then
    kairos_rwalls="wall"
  else
    kairos_rwalls="walls"
  fi
  if [ "$kairos_rconf" -eq 0 ]; then
    # No refusal has ever been recorded for this account, so there is no
    # ceiling to measure against. Saying "0%" here would read as "nothing
    # spent", which is the opposite of the truth, so say what is actually
    # the case: kairos is watching but will not interrupt yet.
    printf '  %s used · no ceiling recorded yet, so kairos will not interrupt\n' \
      "$(kairos_human "$kairos_rused")"
    printf '  resets in %s\n' "$(kairos_duration $((kairos_rend - kairos_rnow)))"
  else
    printf '  %s used · %s–%s%% of the wall · resets in %s\n' \
      "$(kairos_human "$kairos_rused")" \
      "$(kairos_pct "$kairos_rused" "$kairos_rhigh")" \
      "$(kairos_pct "$kairos_rused" "$kairos_rlow")" \
      "$(kairos_duration $((kairos_rend - kairos_rnow)))"
    printf '  band %s to %s, from %s recorded %s\n' \
      "$(kairos_human "$kairos_rlow")" "$(kairos_human "$kairos_rhigh")" \
      "$kairos_rconf" "$kairos_rwalls"
  fi
  printf '  burn %s/h over %s of this block\n' \
    "$(kairos_human "$kairos_rburn")" "$(kairos_duration "$kairos_relapsed")"

  if [ -s "$kairos_rpart/ledger.tsv" ]; then
    printf '  by model:\n'
    awk -F'\t' -v s="$kairos_rstart" '$1 >= s { t[$4] += $5 } END { for (m in t) printf "    %s %d\n", m, t[m] }' \
      "$kairos_rpart/ledger.tsv" | sort -k2 -rn | while read -r kairos_rm kairos_rv; do
        printf '    %-22s %s\n' "$kairos_rm" "$(kairos_human "$kairos_rv")"
      done
  fi

  if [ -s "$kairos_rpart/turns.tsv" ]; then
    kairos_rturns=$(wc -l < "$kairos_rpart/turns.tsv" | tr -d ' ')
    printf '  %s turns recorded · next turn estimated at %s\n' \
      "$kairos_rturns" "$(kairos_human "$(kairos_predict "$kairos_ruuid" unknown)")"
  fi
}

# Every account kairos has seen, and where each one stands. For anyone holding
# two subscriptions this is what turns switching into a decision.
kairos_accounts_report() {
  kairos_aactive=${1:-}
  [ -d "$KAIROS_HOME/accounts" ] || return 0
  kairos_anow=$(kairos_now)
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
    kairos_amark="       "
    [ "$kairos_auuid" = "$kairos_aactive" ] && kairos_amark="active "
    if [ "$kairos_aend" -gt "$kairos_anow" ]; then
      kairos_awhen="resets in $(kairos_duration $((kairos_aend - kairos_anow)))"
    else
      kairos_awhen="block clear"
    fi
    printf '%s%-18s %8s used · %s–%s%% · %s · band from %s wall(s)\n' \
      "$kairos_amark" "$(kairos_account_label "$kairos_auuid")" \
      "$(kairos_human "$kairos_aused")" \
      "$(kairos_pct "$kairos_aused" "$kairos_ahigh")" \
      "$(kairos_pct "$kairos_aused" "$kairos_alow")" \
      "$kairos_awhen" "$kairos_aconf"
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
    if [ "$kairos_oend" -le "$kairos_onow" ]; then
      printf '%s\n' "$kairos_ouuid"
      return 0
    fi
  done
  return 0
}
