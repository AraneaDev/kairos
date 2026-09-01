# Changelog

## [0.0.5](https://github.com/AraneaDev/kairos/compare/v0.0.4...v0.0.5) (2026-09-01)


### Documentation

* show each view once, as a picture rather than twice ([#10](https://github.com/AraneaDev/kairos/issues/10)) ([93e67f1](https://github.com/AraneaDev/kairos/commit/93e67f1f1d563d0c1a41ef21be5e2f1b6e2bb00d))

## [0.0.4](https://github.com/AraneaDev/kairos/compare/v0.0.3...v0.0.4) (2026-09-01)


### Documentation

* link the project site from the readme ([#7](https://github.com/AraneaDev/kairos/issues/7)) ([c1e769f](https://github.com/AraneaDev/kairos/commit/c1e769f62b43bbff658bc18a4aa34820e9aa1848))

## [0.0.3](https://github.com/AraneaDev/kairos/compare/v0.0.2...v0.0.3) (2026-09-01)


### Documentation

* add the install, troubleshooting and platform sections the house README has ([#5](https://github.com/AraneaDev/kairos/issues/5)) ([380aec2](https://github.com/AraneaDev/kairos/commit/380aec2e9af68e42e61572c696dce741fbad1122))

## [0.0.2](https://github.com/AraneaDev/kairos/compare/v0.0.1...v0.0.2) (2026-09-01)


### Features

* add common paths, defaults and portability helpers ([87b46af](https://github.com/AraneaDev/kairos/commit/87b46afd34622c9ab09b9e9259fb08d27ef0a27d))
* add the kairos report and its slash command ([0fc04da](https://github.com/AraneaDev/kairos/commit/0fc04da975b54d6cd37940b2786b06d3c8955e23))
* bind each session to the account that pays for it ([b307a5d](https://github.com/AraneaDev/kairos/commit/b307a5df0d30a1f1f1a591fcf0d2deed5557b107))
* block a prompt that would put the session through the wall ([a670370](https://github.com/AraneaDev/kairos/commit/a67037080a17e745814aacdf1838357f05ac21c5))
* build an incremental ledger from the transcripts ([666af10](https://github.com/AraneaDev/kairos/commit/666af10d38139c1999f54224b2083212710377fe))
* estimate the next turn from the p75 of recent turns ([bf95aa5](https://github.com/AraneaDev/kairos/commit/bf95aa554ba23a77d5367f31d92be819d60aed39))
* harvest refusals and derive a confidence band from them ([ae57237](https://github.com/AraneaDev/kairos/commit/ae5723746d9e4029c07e1dcc50a7b48228a7a65c))
* list known accounts and tell subscription tiers apart ([2d31540](https://github.com/AraneaDev/kairos/commit/2d31540b293ac40b6e30d1aee49acaa203e9bcc5))
* reconstruct the five-hour block from gaps and refusals ([20ff481](https://github.com/AraneaDev/kairos/commit/20ff48100e655077f75644fd6556b91c6d0a3cef))
* record the true cost of each completed turn ([87352cc](https://github.com/AraneaDev/kairos/commit/87352cc5faaf296c074d570594ea3a058d97bdc9))
* rescan history for walls and add the session summary ([c7a9a08](https://github.com/AraneaDev/kairos/commit/c7a9a08e68854ccc2203c875bb27417dcc335b14))
* resolve the active account and partition state by it ([8a00188](https://github.com/AraneaDev/kairos/commit/8a00188fc5f21f6aac9e7ee06b765b4606ae93ae))
* wait out a block in the background and offer the prompt back ([5f692b9](https://github.com/AraneaDev/kairos/commit/5f692b9e12c8dc1c17d22f87d6566721773c93dc))


### Fixes

* add locking to prevent concurrent meter race conditions ([627560e](https://github.com/AraneaDev/kairos/commit/627560e18da16fd7125824085650d77b19ec05b2))
* address CodeRabbit review, from lock ownership to account id paths ([1ae7ef5](https://github.com/AraneaDev/kairos/commit/1ae7ef53c0292fe2b64f86109c2d8dd87267c82a))
* address the whole-branch review, from the lock-out down to tests that could not fail ([e1142d5](https://github.com/AraneaDev/kairos/commit/e1142d544dc6bf24a92a18a5d23ca55aea05cb3a))
* bound reads to prevent race condition, lock trim operation only ([4453084](https://github.com/AraneaDev/kairos/commit/44530849fb5e4a983d6b37cc4171438cfb2598ff))
* distrust stale walls.tsv rows and stop garbage ledgers rendering as 1970 ([cbb5384](https://github.com/AraneaDev/kairos/commit/cbb5384b5c1df8c0a9cc07813bd834d6cccb7a41))
* do not gate on a window that has already ended, and never gate kairos commands ([09e3250](https://github.com/AraneaDev/kairos/commit/09e3250ed19cffe0f5e89345aa9b5b1d3c181efe))
* guard the band against malformed rows and unattributed refusals ([3614a53](https://github.com/AraneaDev/kairos/commit/3614a53a4a809001856c58a35e33f7e2b3dcc5a2))
* harden band fallback and replace two assertions that could not fail ([aebc553](https://github.com/AraneaDev/kairos/commit/aebc5531026ee724d2975bfefbe03e5e7f2640d7))
* increase read window to prevent quiet sessions being pushed out of view ([daef0bd](https://github.com/AraneaDev/kairos/commit/daef0bdb7c30bfa4bebf0b8b8fde13975b1f2a69))
* never report a window fraction without a ceiling, and get plurals right ([0369c0e](https://github.com/AraneaDev/kairos/commit/0369c0e1355d08d20992f5c02dd1d33609aab9b2))
* pin line endings to LF and strip carriage returns from parsed transcripts ([56c8841](https://github.com/AraneaDev/kairos/commit/56c8841f9ea3c08c0f154a70fb6d300eb4a1e287))
* refuse a partition for a rejected account id instead of pooling it ([05e3579](https://github.com/AraneaDev/kairos/commit/05e357937e0bb04b1ffbca3a6fe91c00038500dd))
* sanitise session ids, validate integers, trim turns.tsv, floor zero estimates ([2b98ad5](https://github.com/AraneaDev/kairos/commit/2b98ad555e13b31de609578c0eded4a723778410))
* say plainly there is no ceiling for an uncalibrated account ([534bad6](https://github.com/AraneaDev/kairos/commit/534bad6e16d447e130c92845ba26ea6c6f35277a))
* serialise metadata writes and never move a lock during takeover ([d6ddab3](https://github.com/AraneaDev/kairos/commit/d6ddab33b169a16a5ac02ae4190399e69dd421fd))
* session id sanitization, claim age measurement, and long-turn test ([465b83e](https://github.com/AraneaDev/kairos/commit/465b83eef15cc7332cc337abfe8c21ed0c042a17))
* set aside walls with no history to measure, and stop calling unmetered accounts clear ([bea5a6f](https://github.com/AraneaDev/kairos/commit/bea5a6f80fbc60195d2d6ccc75f81ecdf4efd241))
* tolerate a meta file that vanishes mid-read where replace is not atomic ([837a5ac](https://github.com/AraneaDev/kairos/commit/837a5ac53efda6cd17b049237057bd002e1af3ed))
* use atomic marker claim and validate epoch is numeric ([ffb0a7e](https://github.com/AraneaDev/kairos/commit/ffb0a7ec358983b594cfeda4e5cdd138f372c7ec))
* use process-specific temp files in kairos_meta_set to prevent concurrent write corruption ([92078e2](https://github.com/AraneaDev/kairos/commit/92078e283a4f8b54b9a066855f4074db9f409cc4))


### Documentation

* write the README, wire the session summary and gate the docs ([c558329](https://github.com/AraneaDev/kairos/commit/c5583292be5267652986cf0c62473660b832defb))


### Tests

* add proper concurrent write test using separate processes to catch race condition ([5c6d022](https://github.com/AraneaDev/kairos/commit/5c6d02274ecaf9453342a38fbadff02b2a77acac))
* add regression coverage for wall-selection logic ([641c16d](https://github.com/AraneaDev/kairos/commit/641c16dd20a15fd024262d83a922f697de7d1413))
* prove a writer waits out the metadata replacement gap ([e22cce2](https://github.com/AraneaDev/kairos/commit/e22cce2b40bb9f0718252582ee6cef25ddc8bc26))

## Changelog
