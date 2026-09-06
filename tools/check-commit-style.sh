#!/usr/bin/env bash
# One definition of what a commit subject may look like.
#
# `release-please` reads the commit history to build the changelog and choose
# the next version, so a subject it cannot parse is not a style slip: the change
# silently misses the changelog, and a fix that should have moved the version
# leaves it where it was.
#
# This repository squash merges, so the subject `release-please` eventually
# reads is the pull request title, not any of the commits inside it. That is why
# CI checks the title and the commit-msg hook checks what you type locally, and
# why both call this one script rather than each carrying its own idea of the
# rule. Commit e2728f9 reached `main` as "Redraw every view, and generate the
# README screenshots from real sessions" with no type at all, which is exactly
# the miss this prevents.
#
#   tools/check-commit-style.sh "fix: stop gating on a window that has ended"
#   tools/check-commit-style.sh --file .git/COMMIT_EDITMSG
set -uo pipefail

# The types CONTRIBUTING.md documents, plus the rest of the conventional set.
# `feat` and `fix` move the version; the others are recorded or hidden.
KAIROS_TYPES='build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test'

kairos_style_usage() {
  printf 'usage: check-commit-style.sh <subject> | --file <path>\n' >&2
  exit 2
}

# No argument is a caller that got it wrong; an empty argument is a message
# with nothing in it, which is a different thing and not this script's to judge.
# Both look identical through "${1:-}", so the count is what separates them.
[ "$#" -gt 0 ] || kairos_style_usage

kairos_subject=
case "$1" in
  --file)
    [ -n "${2:-}" ] || kairos_style_usage
    [ -f "$2" ] || { printf 'check-commit-style: no such file: %s\n' "$2" >&2; exit 2; }
    # The subject is the first line of what will be kept. A message being
    # edited carries git's comments above it, and a template can push the real
    # subject further down still.
    kairos_subject=$(grep -v '^#' "$2" | sed '/^[[:space:]]*$/d' | head -1)
    ;;
  *) kairos_subject=$1 ;;
esac

# Nothing to judge. An empty message aborts the commit on its own, and saying
# so twice helps nobody.
[ -n "$kairos_subject" ] || exit 0

# Git writes these itself, or writes them to be consumed by a later rebase.
# None of them reach `main` in a form release-please reads.
case "$kairos_subject" in
  'Merge '*|'Revert "'*|'fixup!'*|'squash!'*|'amend!'*) exit 0 ;;
esac

kairos_fail() {
  printf '\n  %s\n\n' "$1" >&2
  printf '    %s\n\n' "$kairos_subject" >&2
  printf '  Conventional commits, because release-please builds the changelog\n' >&2
  printf '  and the next version number from them:\n\n' >&2
  printf '    feat: add the accounts view\n' >&2
  printf '    fix: do not gate on a window that has already ended\n' >&2
  printf '    docs(readme): link the project site\n' >&2
  printf '    feat!: a break, or use a BREAKING CHANGE: trailer\n\n' >&2
  printf '  Types: %s\n\n' "$(printf '%s' "$KAIROS_TYPES" | tr '|' ' ')" >&2
  exit 1
}

# A type, an optional scope, an optional ! for a break, then ": " and something
# to say. Anchored at both ends so a subject that merely mentions a type
# somewhere does not pass.
if ! printf '%s' "$kairos_subject" \
  | grep -Eq "^(${KAIROS_TYPES})(\([a-z0-9][a-z0-9._/-]*\))?!?: .+"; then
  kairos_fail "This subject does not start with a conventional commit type."
fi

# CONTRIBUTING.md: no em dashes, in code, comments, output strings or commit
# messages. A comma or two short sentences instead.
case "$kairos_subject" in
  *—*) kairos_fail "This subject contains an em dash. Use a comma, or two sentences." ;;
esac

exit 0
