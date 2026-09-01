<div align="center">

# Kairos

**The right moment, caught before it passes.**
**Kairos stops you before the usage limit does.**

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

Kairos watches how much of the window you have spent, predicts what your next
turn will cost, and stops the prompt before that turn takes you through the
wall. When it stops you it asks what to do, and leaves the choice with you.

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
Kairos reports the ceiling as a range and says how much evidence is behind it:

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

**An account Kairos has never seen refused gets no band at all, and is never
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

So Kairos starts knowing nothing about a new account, and it cannot be
backfilled: nothing in the transcripts records which account paid for a
message. It gets better as it runs.

## Two subscriptions

If you hold more than one Claude plan and switch between them with `/login`,
Kairos keeps them apart. Everything it records is partitioned by account, a
session follows the account that is actually paying even if you switch part way
through, and `kairos accounts` shows where each one stands:

```text
active Max 20x (…eea8c8)    2.84M used · 53–72% · resets in 2h55m · band from 1 wall
       Pro (…94f311)           12k used · 41–56% · block clear · band from 3 walls
```

A Max 5x and a Max 20x are told apart, because their ceilings differ by roughly
four times and telling them apart is the point. An account Kairos has not seen
refused yet says so in place of a percentage it cannot support.

## Requirements

`bash` and `jq`. That is the whole list. If `jq` is missing Kairos says so once
and then does nothing. It never fails quietly.

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

Hooks are bound when a session starts, so start a new session before Kairos
does anything. An already running session will not pick it up.

### If the install fails on port 22

Claude Code clones a plugin from its GitHub repository over SSH. On a machine
with no SSH key for GitHub, or with outbound port 22 blocked, the install stops
here:

```text
Failed to clone repository: ssh: connect to host github.com port 22: Connection timed out
fatal: Could not read from remote repository.
Please make sure you have the correct access rights and the repository exists.
```

The message points at access rights. This repository is public, so what failed
is the transport. Adding the marketplace succeeds either way, because that
clone uses HTTPS, which is why other plugins from the same marketplace install
on such a machine while this one does not.

Tell git to reach GitHub over HTTPS, then install again:

```bash
git config --global --add url."https://github.com/".insteadOf "git@github.com:"
git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
```

That rewrites outgoing GitHub SSH URLs and nothing else, so it takes nothing
away on a machine that could not use them in the first place. To undo it:

```bash
git config --global --unset-all url."https://github.com/".insteadOf
```

### Where it works

This is a Claude Code plugin, and it runs wherever Claude Code itself runs: the
terminal, the IDE extensions, and the **Code** tab of the desktop app. The
**Chat** and **Cowork** tabs are not Claude Code and have no hooks, so nothing
here reaches them. Cloud sessions on the web read hooks from the repository and
from managed settings rather than from your `~/.claude`, so a personal install
does not apply there either.

### Windows: WSL and the desktop app are separate installs

Claude Code in WSL and the desktop app on Windows do not share a home
directory. WSL has `~/.claude`, Windows has `C:\Users\<you>\.claude`. Install
on one side and the other has nothing installed, and that goes for `jq` and for
everything Kairos has learned about your accounts, which lives under the same
home. On macOS and Linux there is one home directory, so one install covers
everything.

Install on each side you actually use. In WSL, on Debian or Ubuntu:

```bash
sudo apt-get install jq
claude plugin marketplace add https://aranea-development.nl/plugins/marketplace.json
claude plugin install kairos@aranea
```

On Windows:

```powershell
winget install jqlang.jq
claude plugin marketplace add https://aranea-development.nl/plugins/marketplace.json
claude plugin install kairos@aranea
```

The desktop app's plugin browser lists what your configured marketplaces
already offer and cannot add one, so the marketplace step is what makes the
plugin appear there at all. Those commands need the standalone CLI, which is a
separate installation from the desktop app. Without it, type the same two steps
as slash commands in a **Local** session in the Code tab:

```text
/plugin marketplace add https://aranea-development.nl/plugins/marketplace.json
/plugin install kairos@aranea
```

Restart the desktop app after installing `jq`. It reads Windows environment
variables when it launches and never reads your PowerShell profile, so a `PATH`
that winget changed underneath a running app does not reach it. Until it does,
every hook exits without doing anything.

Pick **Local** for the session environment. Plugins do not load in the desktop
app's WSL sessions, which is Anthropic's limitation rather than this plugin's.

## Commands

| Command | What it does |
| --- | --- |
| `kairos report` | The window, the band, the burn rate, the model split, the next-turn estimate. This is the default, so `/kairos` alone does the same. |
| `kairos accounts` | Every account Kairos has seen, where each stands, and which is active. |
| `kairos alias <name>` | Give the active account a name of your own, used in place of the derived label. |
| `kairos wait` | Hold until the window resets, in a detached process that survives a closed terminal, then ring the terminal that armed it. Set `KAIROS_NOTIFY_CMD` for anything louder. |
| `kairos go` | Let the next prompt through, and print the one that was held so you can send it again. Spends itself once, then the gate re-arms. |
| `kairos stop` | Drop the stashed prompt. |
| `kairos calibrate` | Rescan every transcript for refusals Kairos has not seen yet, and report what it found. |

## How the gate decides

It blocks when the room left before the optimistic edge of the band is less
than the predicted cost of the next turn times a reserve.

The prediction is the 75th percentile of your recent turns. The long tail is
what actually puts a session through a limit, so the estimate leans high on
purpose.

It gates against the **optimistic** edge, which means it stays quiet until even
a generous ceiling is threatened. Kairos would rather let a first wall happen
than interrupt you wrongly for a month. Raise `KAIROS_RESERVE` if you want the
other trade.

## Settings

All optional, all environment variables. A file at `~/.claude/kairos/config` is
sourced if present.

| Variable | Default | Meaning |
| --- | --- | --- |
| `KAIROS_HOME` | `~/.claude/kairos` | Where Kairos keeps its state |
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
- It never blocks a prompt because something in Kairos broke. Every uncertain
  path lets the prompt through. Being wrong about the budget is a nuisance;
  stopping your work because the meter failed is worse than having no meter.
- It never runs `/login` for you. It will say when another account looks clear,
  and leave the switch to you.

## When something is wrong

Run `/kairos`. It prints what the plugin currently believes, and that is usually
enough to tell the three quiet failures apart.

**"nothing recorded for this account yet"** means no consumption has been read.
Either `jq` is missing, or the hooks are not bound because the session was
already running when you installed. Start a new session and look again.

**"no ceiling recorded yet, so Kairos will not interrupt"** is not a fault. It
is the normal state for an account that has never hit a limit while Kairos was
watching, and it will stay that way until one happens. Kairos measures and
reports throughout, and only starts gating once it has a wall of that account's
own to measure against. `kairos calibrate` rescans your whole transcript history
for refusals it has not seen yet, which is worth doing once after installing.

**A figure that looks wrong** is worth checking against `kairos accounts`. If
you use more than one plan, the number you are looking at belongs to whichever
account is active now, and the other one is listed beside it.

Nothing here can break a session. The only deliberate non-zero exit in the
whole plugin is the gate refusing a prompt; every other path exits 0 and does
nothing, so a Kairos that is confused goes quiet rather than getting in your
way. If a prompt
was ever blocked and you want it back, the text is held and `/kairos go` prints
it.

## How it works

Four hooks, all of them harness-only, so none of this costs model context.

| Hook | Job |
| --- | --- |
| `SessionStart` | Resolve the paying account, bind the session to it, bring the meter up to date, harvest any refusals |
| `UserPromptSubmit` | Follow a mid-session account switch, predict the turn, block or let it through |
| `Stop` | Record what the turn actually cost, and harvest a refusal if one just happened |
| `SessionEnd` | Print the closing line |

Consumption is read incrementally. A cursor per transcript records how many
bytes have been counted, so a refresh reads only what was appended since, and
the ledger it writes is pruned to a day. Everything is partitioned by account
uuid under `~/.claude/kairos/accounts/`, which is also where the recorded
refusals and the turn history live.

A turn is opened by the prompt that started it and closed by `Stop`, so its cost
is measured once rather than accumulated as messages arrive. The marker naming
that turn is claimed by renaming it, which is atomic, so two Stop hooks racing
for the same turn cannot both record it.

## Platform notes

Tested on Linux, macOS and Windows on every push, and again under bash 3.2 on
macOS, which is what macOS still ships as `/bin/bash`.

Two defects in this repository's history were reachable only on Windows, which
is why that column is not decoration. Git converts line endings on checkout, and
a carriage return riding on a numeric field is not a wrong number but an
arithmetic error. And replacing a file is not atomic there, so a concurrent
writer can make one vanish between an existence check and a read. Both are
handled, and both were found by CI rather than by reasoning.

## Accuracy

The window model is not guesswork. Reconstructing chained five-hour windows
from transcript timestamps reproduces the reset times Claude's own refusals
state, to the minute.

Consumption counts `input_tokens + cache_creation_input_tokens + output_tokens`.
Cache reads are excluded, and that came out of measurement. Weighting them at
zero fits the recorded refusals, and including them at any weight makes the
error four times worse. A meter that counted them would be wrong by roughly
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
