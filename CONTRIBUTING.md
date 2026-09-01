# Contributing

## Getting set up

```bash
git clone https://github.com/AraneaDev/kairos.git
cd kairos
cp .githooks/pre-commit .githooks/pre-push .git/hooks/
```

Copy the hooks rather than pointing `core.hooksPath` at `.githooks/`. A tracked
hook only exists in the working tree while a branch containing it is checked
out, so it would be missing on exactly the branches that predate it.

`pre-commit` refuses a commit made directly on `main` and runs `bash -n` and
ShellCheck over the staged content of any shell script. `pre-push` refuses a
direct push to `main`. Both are guard rails rather than controls, and both can
be bypassed once with `--no-verify` when you mean it.

## Checks

```bash
bash tests/run.sh
bash tools/check-docs.sh
shellcheck -S style -e SC1091 \
  --enable=deprecate-which --enable=avoid-nullary-conditions \
  --enable=quote-safe-variables \
  hooks/scripts/*.sh hooks/scripts/lib/*.sh tools/*.sh tests/run.sh
```

CI runs the suite on Linux, macOS and Windows, and again under bash 3.2 on
macOS, which is what macOS still ships as `/bin/bash`. ShellCheck and the
documentation check run on Ubuntu only.

Do not skip the Windows run in your head. Two defects in this repository's
history were reachable only there: Git converts line endings on checkout, and
replacing a file is not atomic, so a concurrent writer can make one vanish
between an existence check and a read.

## Working on it

Work on a topic branch and open a pull request. `main` requires the checks
above, a linear history, and every review conversation resolved.

## Commit messages

Conventional commits, because `release-please` builds the changelog and the
next version number from them.

```text
feat: add the accounts view
fix: do not gate on a window that has already ended
docs: write the README and gate it against the code
test: prove a writer waits out the metadata replacement gap
```

`feat` and `fix` appear in the changelog and move the version. `chore` and
`style` are hidden. A `!` after the type, or a `BREAKING CHANGE:` trailer,
marks a break.

No em dashes, in code, comments, output strings or commit messages. A comma or
two short sentences instead.

## Releases

`release-please` keeps a Release PR up to date from the conventional commits on
`main`. Merging it writes `CHANGELOG.md`, bumps `version.txt` and
`.claude-plugin/plugin.json`, and cuts the tag and GitHub Release. The release
job then re-runs the suite and the documentation check against the released
commit, and asserts the tag matches the version in the manifest.

### If a Release PR turns up with no checks

GitHub does not start workflows for events raised by the built-in
`GITHUB_TOKEN`, so a Release PR opened with it arrives with no checks, and
`main` requires those checks before anything can merge. Close the Release PR
and reopen it once to start them, or set a `RELEASE_PLEASE_TOKEN` secret to a
personal access token so the event is raised by a real account.

## Rules that are enforced rather than asked for

- **Every `KAIROS_*` setting with a default must appear in the README**, and so
  must every `kairos` subcommand, and the test count badge must match what the
  suite actually runs. `tools/check-docs.sh` fails the build otherwise, and it
  asserts that its own extraction found a plausible number of settings, because
  a pattern that silently matches nothing would turn the whole gate into a
  no-op that always passes.
- **`bash` and `jq` only** at runtime, and bash 3.2 compatible: no associative
  arrays, no `${var^^}`, no `mapfile`.

## Rules that are not enforced but matter more

**A hook must never break the user's session.** Every uncertain path exits 0
and does nothing. Being wrong about the budget is a nuisance; stopping someone
mid-task because the meter failed is worse than having no meter.

**Prove a new test can fail before you keep it.** Change the code so the
property it names is violated, and watch that specific assertion go red. Nine
assertions in this project's history turned out not to test what their names
claimed, and every one was found by mutating the code rather than by reading
the test. A test that cannot fail is worse than no test, because it reads as
coverage. If an assertion cannot be made to fail without becoming flaky, say so
in a comment rather than shipping it: there is one of those in `tests/run.sh`
already, and it explains itself.

**Do not make the meter guess.** kairos reports a range for the ceiling because
it does not know the ceiling, and reports nothing at all for an account it has
never seen refused. If you find yourself adding a plausible default so the
output looks more confident, that is the mistake this design was built to
avoid.
