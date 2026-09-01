<div align="center">

# kairos

**The right moment, caught before it passes.**
**kairos stops you before the usage limit does.**

[![Release](https://img.shields.io/github/v/release/AraneaDev/kairos?label=release&include_prereleases)](https://github.com/AraneaDev/kairos/releases)
[![Tool page](https://img.shields.io/badge/tool%20page-aranea--development.nl-0b7285)](https://aranea-development.nl/en/tools/kairos)
[![CI](https://img.shields.io/github/actions/workflow/status/AraneaDev/kairos/ci.yml?label=CI)](https://github.com/AraneaDev/kairos/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/tests-217%20passing-2b8a3e)](tests/run.sh)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-364fc7)](#requirements)
[![License](https://img.shields.io/github/license/AraneaDev/kairos?label=license&color=yellow)](./LICENSE)
[![Language](https://img.shields.io/github/languages/top/AraneaDev/kairos)](https://github.com/AraneaDev/kairos)
[![Last commit](https://img.shields.io/github/last-commit/AraneaDev/kairos?label=last%20commit)](https://github.com/AraneaDev/kairos/commits/main)
[![Conventional Commits](https://img.shields.io/badge/commits-conventional-fe5196?logo=conventionalcommits&logoColor=white)](https://www.conventionalcommits.org/)
[![Status](https://img.shields.io/badge/status-pre--release-orange)](#install)

</div>

> **Kairos** (καιρός) is the ancient Greek word for the right moment, as opposed
> to *chronos*, which is time merely passing. Personified, he is a young god with
> a long lock of hair over his forehead and nothing at all at the back of his
> head: you can catch him as he comes toward you, and never once he has gone by.

That is the whole problem this solves. A usage limit is only worth knowing about
before you reach it. Afterwards there is nothing left to take hold of, and the
five hours you wait are five hours whether you understood them or not.

Claude Code gives no warning before the five-hour usage limit. Work stops
mid-task, at a moment chosen by the limit rather than by you, and the only
notice is the failure itself:

```text
You've hit your session limit · resets 1:20pm (Europe/Amsterdam)
```

kairos watches how much of the window you have spent, predicts what your next
turn will cost, and stops the prompt before that turn takes you through the
wall. When it stops you it asks what to do rather than deciding for you.

```text
kairos: predicted ~95k. 210k left before the optimistic wall,
        resets in 2h41m.

  Max 20x (…a8c8) block looks clear.

  /kairos wait   hold, and tell me when the window resets
  /kairos go     send it anyway
  /kairos stop   drop it
  → to switch, run /login yourself
```

## What it knows, and what it does not

Nothing on your machine reports how much of the limit you have used, or where
the limit is. Both are reconstructed from the transcripts Claude Code already
writes.

That reconstruction is exact for consumption and inexact for the ceiling, so
kairos reports the ceiling as a range and says how much evidence is behind it:

```text
Max 20x (…eeffff)
  2.84M used · 53–72% of the wall · resets in 2h51m
  band 3.91M to 5.29M, from 1 recorded wall
  burn 1.33M/h over 2h08m of this block
  by model:
    claude-opus-5          2.10M
    claude-sonnet-5        740k
  3 turns recorded · next turn estimated at 510k
```

The band narrows as evidence accumulates. One recorded refusal gives a wide
range; three give a tighter one.

**An account kairos has never seen refused gets no band at all, and is never
gated.** It measures, reports and predicts, and stays out of your way until it
has observed a wall of that account's own:

```text
Max 20x (…eeffff)
  2.84M used · no ceiling recorded yet, so kairos will not interrupt
  resets in 2h51m
```

This is deliberate. An earlier version seeded a plausible range from observed
data, and that was wrong: real usage windows on the machine this was built
against reached 16.5M billable tokens with no refusal at all, while the seeded
range topped out at 5.7M. Those figures described one subscription, not the
shape of the limit. A guessed ceiling would interrupt constantly on a larger
plan while claiming to know something it never observed.

So kairos starts knowing nothing about a new account, and it cannot be
backfilled: nothing in the transcripts records which account paid for a
message. It gets better as it runs.

## Two subscriptions

If you hold more than one Claude plan and switch between them with `/login`,
kairos keeps them apart. Everything it records is partitioned by account, a
session follows the account that is actually paying even if you switch part way
through, and `kairos accounts` shows where each one stands:

```text
active Max 20x (…eea8c8)    2.84M used · 53–72% · resets in 2h55m · band from 1 wall
       Pro (…94f311)           12k used · 41–56% · block clear · band from 3 walls
```

A Max 5x and a Max 20x are told apart, because their ceilings differ by roughly
four times and telling them apart is the point. An account kairos has not seen
refused yet says so in place of a percentage, rather than showing a figure it
cannot support.

## Requirements

`bash` and `jq`. That is the whole list. If `jq` is missing kairos says so once
and then does nothing, rather than failing quietly.

```text
macOS           brew install jq
Debian/Ubuntu   sudo apt-get install jq
Windows         winget install jqlang.jq
```

## Install

```bash
claude plugin marketplace add https://aranea-development.nl/plugins/marketplace.json
claude plugin install kairos@aranea
```

Hooks are bound when a session starts, so start a new session before kairos
does anything. An already-running session will not pick it up.

## Commands

| Command | What it does |
| --- | --- |
| `kairos report` | The window, the band, the burn rate, the model split, the next-turn estimate. This is the default, so `/kairos` alone does the same. |
| `kairos accounts` | Every account kairos has seen, where each stands, and which is active. |
| `kairos alias <name>` | Give the active account a name of your own, used in place of the derived label. |
| `kairos wait` | Hold until the window resets, in a detached process that survives a closed terminal, then ring the terminal that armed it. Set `KAIROS_NOTIFY_CMD` for anything louder. |
| `kairos go` | Let the next prompt through, and print the one that was held so you can send it again. Spends itself once, then the gate re-arms. |
| `kairos stop` | Drop the stashed prompt. |
| `kairos calibrate` | Rescan every transcript for refusals kairos has not seen yet, and report what it found. |

## How the gate decides

It blocks when the room left before the optimistic edge of the band is less
than the predicted cost of the next turn times a reserve.

The prediction is the 75th percentile of your recent turns, not the mean. The
long tail of turns is what actually puts a session through a limit, so the
estimate leans high on purpose.

It gates against the **optimistic** edge, which means it stays quiet until even
a generous ceiling is threatened. kairos would rather let a first wall happen
than interrupt you wrongly for a month. Raise `KAIROS_RESERVE` if you want the
other trade.

## Settings

All optional, all environment variables. A file at `~/.claude/kairos/config` is
sourced if present.

| Variable | Default | Meaning |
| --- | --- | --- |
| `KAIROS_HOME` | `~/.claude/kairos` | Where kairos keeps its state |
| `KAIROS_CLAUDE_JSON` | `~/.claude.json` | Where it reads the active account from |
| `KAIROS_PROJECTS_DIR` | `~/.claude/projects` | Where it reads transcripts from |
| `KAIROS_GATE` | `1` | `0` disables blocking and leaves reporting intact |
| `KAIROS_RESERVE` | `3` | Turns of headroom the gate insists on |
| `KAIROS_BLOCK_SECONDS` | `18000` | Length of the usage window |
| `KAIROS_LEDGER_WINDOW` | `86400` | How much consumption history is kept |
| `KAIROS_PREDICT_DEFAULT` | `60000` | Estimate used before there is history to go on |
| `KAIROS_TURNS_KEEP` | `200` | Turns retained for the predictor |
| `KAIROS_TURNS_READ` | `KAIROS_TURNS_KEEP * 10` | Rows read when estimating, kept well above the retention ceiling so a busy session cannot push a quiet one out of view |
| `KAIROS_LOCK_STALE_MIN` | `2` | Minutes before an abandoned lock may be broken |
| `KAIROS_NOTIFY_CMD` | unset | Run when a wait finishes, for a desktop toast or a push |

## What it never does

- It never writes your account's email address to disk. The account uuid, plan
  type and rate tier only.
- It never blocks a prompt because something in kairos broke. Every uncertain
  path lets the prompt through. Being wrong about the budget is a nuisance;
  stopping your work because the meter failed is worse than having no meter.
- It never runs `/login` for you. It will say when another account looks clear,
  and leave the switch to you.

## Accuracy

The window model is not guesswork. Reconstructing chained five-hour windows
from transcript timestamps reproduces the reset times Claude's own refusals
state, to the minute.

Consumption counts `input_tokens + cache_creation_input_tokens + output_tokens`.
Cache reads are excluded, which was measured rather than assumed: weighting
them at zero fits the recorded refusals, and including them at any weight makes
the error four times worse. A meter that counted them would be wrong by roughly
a factor of a hundred.

## Development

`bash tests/run.sh` runs the suite. No framework, no dependency beyond `jq`.
`bash tools/check-docs.sh` holds this README to the code, and fails the build
when a setting, a subcommand or the test count drifts from it.

CI runs the suite on Linux, macOS and Windows, and again under bash 3.2 on
macOS. Two defects in this repository's history were reachable only on Windows,
so that column is not decoration.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Releases

Versioned with [semantic versioning](https://semver.org) and released by
[release-please](https://github.com/googleapis/release-please), which reads the
commit messages. Commits follow
[conventional commits](https://www.conventionalcommits.org): `feat:`, `fix:`,
`docs:`, `test:`, `ci:`, `refactor:`, `chore:`.

While the version is below `1.0.0`, a feature bumps the patch number and a
breaking change bumps the minor one, so the shape of the settings can still
settle without spending major versions on it.

Merging the Release PR tags the release as `v<version>` and updates
`plugin.json`, `version.txt`, the release manifest and the changelog together.
The release workflow then re-runs the suite against the released commit and
checks the tag matches what it released.

Versions and tags are not hand-edited. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT.
