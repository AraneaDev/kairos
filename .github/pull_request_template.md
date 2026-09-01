## What changed

<!-- One or two sentences. What does this do that the repository did not do before? -->

## Why

<!-- The reason the change is worth making. Skip if it is obvious from the above. -->

## Checks

- [ ] `bash tests/run.sh` passes
- [ ] `bash tools/check-docs.sh` passes
- [ ] `shellcheck -S style -e SC1091 hooks/scripts/*.sh hooks/scripts/lib/*.sh tools/*.sh tests/run.sh` is clean
- [ ] New behaviour has a test, and that test was shown to fail before the change
- [ ] Nothing new guesses at a usage ceiling it has not observed
