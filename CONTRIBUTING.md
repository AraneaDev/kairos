# Contributing

## Running the suite

```bash
bash tests/run.sh
```

Plain bash, no framework, no dependency beyond what the plugin itself needs.
Every test runs against a temporary `KAIROS_HOME`, a temporary fake
`~/.claude.json` and a temporary projects directory, so a run never touches
real state.

## Before you open a pull request

```bash
bash tests/run.sh
bash tools/check-docs.sh
shellcheck -S style -e SC1091 \
  --enable=deprecate-which --enable=avoid-nullary-conditions \
  --enable=quote-safe-variables \
  hooks/scripts/*.sh hooks/scripts/lib/*.sh tools/*.sh tests/run.sh
```

CI runs all three on Linux, macOS and Windows, and additionally runs the suite
under bash 3.2 on macOS, which is what macOS still ships as `/bin/bash`.

## Rules that are enforced rather than asked for

- **Every `KAIROS_*` setting with a default must appear in the README**, and so
  must every `kairos` subcommand, and the test count badge must match what the
  suite actually runs. `tools/check-docs.sh` fails the build otherwise.
- **`bash` and `jq` only** at runtime, and bash 3.2 compatible: no associative
  arrays, no `${var^^}`, no `mapfile`.
- **No em dashes**, in code, comments, output strings or commit messages. A
  comma or two short sentences instead.

## Rules that are not enforced but matter more

**A hook must never break the user's session.** Every uncertain path exits 0
and does nothing. Being wrong about the budget is a nuisance; stopping someone
mid-task because the meter failed is worse than having no meter.

**Prove a new test can fail before you keep it.** Change the code so the
property it names is violated, and watch that specific assertion go red. Eight
assertions in this project's history turned out not to test what their names
claimed, and every one was found by mutating the code rather than by reading
the test. A test that cannot fail is worse than no test, because it reads as
coverage.

**Do not make the meter guess.** kairos reports a range for the ceiling because
it does not know the ceiling, and reports nothing at all for an account it has
never seen refused. If you find yourself adding a plausible default so the
output looks more confident, that is the mistake this design was built to
avoid.
