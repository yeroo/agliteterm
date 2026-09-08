# P11 acceptance and delivery evidence

The whole P11 is one delivery under Boris's 2026-09-08 instruction: no sub-batch approval pauses.
Implementation base: 174b3b1. No real Claude CLI or release installation is used by tests.

## Test boundary

- Pure: commands parser, agent identity/resume arguments/input lease, installer preservation and
  idempotence, fake updater version/receipt handling, script syntax and private-pipe wrapper/notify.
- Guarded: `test/selection-ui.ps1 -Strict -AgentIntegrationOnly -TokenOwner ACTUAL_OWNER`.
  Redirected app data, private compiled fake claude.exe and UUID registry subtree. The real user
  profile, Claude settings, Codex TOML and Environment Path are never installed or rewritten by tests.
- Combined: omit the filter to run P7/P9/P10a/P10b/P11 through the same ownership/restoration boundary.
- Full `test/run-all.ps1 -Strict` is a disposable Windows CI gate, not a shared-desktop command (#51).
- Cleanup retains process handles from proven live-parent/birth relationships, waits for exit after
  owned host teardown, restores touched registry values and the guarded clipboard snapshot, then
  releases the exact canonical suite token. An uncertain cleanup retains the token.

## Development evidence

Before final review: 86 command checks, 44 agent helper checks, 20 installer checks and 237 existing
configuration checks passed. Script fixture checks and full gates are tracked in the PR.

Focused live run `selection-ui-20260908T203639-aca308`: 47/47 passed. It proved all command modes,
leader timeout/key dispatch, refusal/invalid reload behavior, private CLI PATH install/remove,
two same-folder conversation identities, targeted YOLO, custom binding preservation, input leasing,
readonly cancellation, and failed/no-op/new-version update paths preserving permission modes.
All 23 retained descendant handles signalled exit; clipboard/touched registry restoration passed;
canonical suite token generation 73 released. Subsequent coverage adds palette and actual timeout.

The development fixture caught and fixed prompt-bridge re-entry after a previously resumed agent
exits. No fallback injection was added. Earlier failed fixture runs also restored state and released
their exact leases (generations 69–72); these failures are not presented as passing acceptance.

## Merge gates

Record the exact candidate, Codex-only revmux completeness/dispositions, combined local counts,
full Windows CI run and implementation/companion-doc PRs in the final PR delivery note. This document
does not claim those pending gates have passed. No release/tag is authorized or produced by P11.
