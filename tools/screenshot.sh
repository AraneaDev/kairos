#!/usr/bin/env bash
# The README shows what kairos looks like. Screenshots taken by hand go stale
# the moment a column moves, and nobody notices until someone installs the
# thing and finds it does not match the picture. So they are generated from the
# code, from a fixture rather than from real usage, and CI checks them for
# drift the same way it checks the README's prose.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/docs/screenshots"
CHECK=no
TEXT=no
CAPTURE=no
ONLY=
case "${1:-}" in
  --check)   CHECK=yes ;;
  --text)    TEXT=yes ;;
  --capture) CAPTURE=yes; ONLY=${2:-} ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "screenshot: needs jq, which is not on PATH." >&2
  exit 1
fi

# A fixed clock and a fixed fixture. Every number in every image is derived
# from these, so the same commit renders the same bytes on any machine.
NOW=1756742400
FIX=$(mktemp -d) || exit 1
trap 'rm -rf "$FIX"' EXIT
export KAIROS_NOW="$NOW"
export KAIROS_HOME="$FIX/kairos"
export KAIROS_CLAUDE_JSON="$FIX/claude.json"
export KAIROS_PROJECTS_DIR="$FIX/projects"
mkdir -p "$KAIROS_HOME" "$KAIROS_PROJECTS_DIR"

BIG=aaaaaaaa-1111-2222-3333-4444eea8c8
SMALL=bbbbbbbb-1111-2222-3333-44494f3110
IDLE=cccccccc-1111-2222-3333-44441c0de7
# The organisation fields matter: a live session re-records the active account
# from this file on startup, and without them it would overwrite the seeded
# tier and every view would label the account "account".
printf '{"oauthAccount":{"accountUuid":"%s","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x"}}\n' \
  "$BIG" > "$KAIROS_CLAUDE_JSON"

# A capture session runs with the status line turned off. It is drawn outside
# the cropped region anyway, but it carries the real account's real percentages
# and this repository is public, so it is switched off rather than trusted to
# stay out of frame.
printf '{"statusLine":{"type":"command","command":"true"}}\n' > "$FIX/settings.json"

LIBDIR="$ROOT/hooks/scripts/lib"
# shellcheck source=/dev/null
. "$LIBDIR/common.sh"
kairos_config_load
for lib in account meter wall predict format waiter; do
  # shellcheck source=/dev/null
  . "$LIBDIR/$lib.sh"
done

seed_account() {
  # $1 uuid, $2 rate tier, $3 organisation type. Both are set after the record,
  # which reads them from the account file and would otherwise mark every
  # fixture account unknown.
  kairos_account_record "$1"
  kairos_meta_set "$(kairos_partition "$1")" rate_tier "$2"
  kairos_meta_set "$(kairos_partition "$1")" org_type "$3"
}

START=$((NOW - 7680))
seed_account "$BIG" default_claude_max_20x claude_max
BPART=$(kairos_partition "$BIG")
{
  printf '%s\t%s\ts1\tclaude-opus-5\t2100000\n' "$START" "$BIG"
  printf '%s\t%s\ts1\tclaude-sonnet-5-20250929\t740000\n' "$((NOW - 900))" "$BIG"
} > "$BPART/ledger.tsv"
printf '%s\t5000000\t%s\n' "$((START - 86400))" "$((START - 68400))" > "$BPART/walls.tsv"
printf '%s\ts1\t480000\n%s\ts1\t610000\n%s\ts1\t530000\n' \
  "$START" "$((NOW - 3600))" "$((NOW - 900))" > "$BPART/turns.tsv"

seed_account "$SMALL" default_claude claude_pro
SPART=$(kairos_partition "$SMALL")
printf '%s\t%s\ts2\tclaude-sonnet-5\t96000\n' "$((NOW - 3600))" "$SMALL" > "$SPART/ledger.tsv"
printf '1\t320000\t2\n1\t336000\t2\n1\t344000\t2\n' > "$SPART/walls.tsv"

# A third account whose window has already ended, so the accounts view shows a
# clear block beside two live ones and the gate has somewhere to point at.
seed_account "$IDLE" default_claude_max_5x claude_max
IPART=$(kairos_partition "$IDLE")
printf '%s\t%s\ts3\tclaude-opus-5\t1900000\n' "$((NOW - 90000))" "$IDLE" > "$IPART/ledger.tsv"
printf '%s\t4100000\t%s\n' "$((NOW - 172800))" "$((NOW - 154800))" > "$IPART/walls.tsv"

# The capture carries the colours Claude Code actually printed, so rendering it
# means understanding them. That is a job with enough parsing in it to live in
# a file of its own rather than inside a quoted heredoc.
render_svg() { LC_ALL=C awk -f "$ROOT/tools/screenshot-svg.awk"; }

DEST="$OUT"
[ "$CHECK" = yes ] && DEST="$FIX/out"
mkdir -p "$DEST"

ENVPASS="KAIROS_NOW='$KAIROS_NOW' KAIROS_HOME='$KAIROS_HOME' KAIROS_CLAUDE_JSON='$KAIROS_CLAUDE_JSON' KAIROS_PROJECTS_DIR='$KAIROS_PROJECTS_DIR'"

# A real session, driven through a pty, photographed. This is the only part
# that needs Claude Code installed and costs anything to run, which is why its
# output is committed: every other mode works from the committed capture, so
# CI and anyone rendering the images pays nothing and needs nothing installed.
capture_live() {
  kairos_sock="kairos-shot-$$"
  tmux -L "$kairos_sock" kill-server 2>/dev/null
  tmux -L "$kairos_sock" new-session -d -x 100 -y 44 -c "$FIX" \
    "$ENVPASS claude --plugin-dir '$ROOT' --allowedTools Bash --settings '$FIX/settings.json'" || return 1
  settle 12

  for kairos_send in "$@"; do
    tmux -L "$kairos_sock" send-keys -t 0 "$kairos_send"
    settle 2
    tmux -L "$kairos_sock" send-keys -t 0 Enter
    # Long enough for a turn to come back. There is no machine-readable "done"
    # in a TUI, so this waits rather than polls for a marker that might change.
    settle 40
    # Claude Code collapses a tool result past a few lines, and what it hides is
    # the whole table. Expanding it puts the real bytes on screen rendered by
    # Claude Code itself, rather than leaving them to the model to retype.
    tmux -L "$kairos_sock" send-keys -t 0 C-o
    settle 4
  done

  # Scrollback included: an exchange taller than the pane would otherwise be
  # cropped by the terminal before this ever gets to crop it on purpose.
  tmux -L "$kairos_sock" capture-pane -e -p -S - -t 0
  tmux -L "$kairos_sock" kill-server 2>/dev/null
}

settle() { kairos_n=0; while [ "$kairos_n" -lt "$1" ]; do kairos_n=$((kairos_n + 1)); command sleep 0.5; done; }

crop_exchange() { LC_ALL=C awk -v marker="$1" -f "$ROOT/tools/screenshot-crop.awk"; }

shot() {
  # $1 name of a committed capture
  if [ "$TEXT" = yes ]; then
    printf '\n== %s ==\n' "$1"
    strip_ansi < "$OUT/$1.ansi"
    return 0
  fi
  render_svg < "$OUT/$1.ansi" > "$DEST/$1.svg"
  printf '%s\n' "$DEST/$1.svg"
}

strip_ansi() { LC_ALL=C sed -E $'s/\033\[[0-9;?]*[A-Za-z]//g; s/\033\][^\a]*\a//g' ; }

# --capture drives the real thing. Everything else works from what it wrote.
if [ "$CAPTURE" = yes ]; then
  if ! command -v claude >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    echo "screenshot: --capture needs claude and tmux on PATH." >&2
    exit 1
  fi
  mkdir -p "$OUT"

  # The command is addressed the way a user addresses it, plugin and all.
  # Each view costs a turn to photograph, so naming one re-takes just that one
  # rather than making a single wrong frame expensive to correct.
  wanted() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

  if wanted report; then
    # Addressed the way a user addresses it, plugin id and all.
    capture_live "/kairos:kairos" | crop_exchange "/kairos:kairos" > "$OUT/report.ansi"
    printf '%s\n' "$OUT/report.ansi"
  fi

  if wanted accounts; then
    capture_live "/kairos:kairos accounts" | crop_exchange "/kairos:kairos" > "$OUT/accounts.ansi"
    printf '%s\n' "$OUT/accounts.ansi"
  fi

  # The gate only shows itself when a turn would go through the wall, so it
  # needs a state the other two views must not be drawn in: the same account,
  # most of its window already spent. This one costs nothing to capture, since
  # the hook refuses the prompt before it ever reaches the model.
  wanted gate || exit 0
  printf '%s\t%s\ts1\tclaude-opus-5\t5450000\n' "$START" "$BIG" > "$BPART/ledger.tsv"
  # Anchored on the refusal rather than on the prompt: a blocked prompt never
  # becomes a message, so the terminal never echoes it to crop from.
  capture_live "finish the refactor and run the suite" \
    | crop_exchange "kairos: this turn" > "$OUT/gate.ansi"
  printf '%s\n' "$OUT/gate.ansi"
  exit 0
fi

# Every other mode renders the committed captures. No Claude, no network, no
# session: the images are a pure function of files that are in the repository.
for name in report accounts gate; do
  if [ ! -f "$OUT/$name.ansi" ]; then
    printf 'screenshot: %s.ansi is missing, run tools/screenshot.sh --capture\n' "$name" >&2
    exit 1
  fi
  shot "$name"
done

if [ "$CHECK" = yes ]; then
  status=0
  for name in report accounts gate; do
    if [ ! -f "$OUT/$name.svg" ]; then
      printf 'MISSING %s.svg, run tools/screenshot.sh\n' "$name" >&2
      status=1
    elif ! diff -q "$OUT/$name.svg" "$DEST/$name.svg" >/dev/null 2>&1; then
      printf 'STALE   %s.svg was not rendered from %s.ansi, run tools/screenshot.sh\n' "$name" "$name" >&2
      status=1
    else
      printf 'ok      %s.svg matches its capture\n' "$name"
    fi
  done

  # The images being a faithful rendering of the capture says nothing about the
  # capture still being a faithful picture of the code. That is the drift that
  # actually matters: a column moves, the README keeps showing the old one. So
  # the views are printed from the same fixture and every line is looked for in
  # what was photographed.
  for pair in "report:report" "accounts:accounts"; do
    name=${pair%%:*}
    view=${pair##*:}
    shot_text=$(eval "$ENVPASS bash '$ROOT/tools/screenshot-view.sh' $view" 2>&1)
    shot_seen=$(strip_ansi < "$OUT/$name.ansi")
    missing=0
    while IFS= read -r want; do
      [ -n "$(printf '%s' "$want" | tr -d '[:space:]')" ] || continue
      case "$shot_seen" in
        *"$want"*) ;;
        *) missing=$((missing + 1)) ;;
      esac
    done <<EOF
$shot_text
EOF
    if [ "$missing" -gt 0 ]; then
      printf 'STALE   %s.ansi no longer shows what %s prints (%s lines differ),\n' \
        "$name" "$view" "$missing" >&2
      printf '        run tools/screenshot.sh --capture\n' >&2
      status=1
    else
      printf 'ok      %s.ansi still matches the code\n' "$name"
    fi
  done

  exit "$status"
fi
