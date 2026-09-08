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

Broad review `01-initial` covered 174b3b1..5669da4: 4/4 Codex sources, no degradation, 7 major
code findings and 5 minor code/test findings; no open questions, pre-existing or immaterial entries.
All are accepted. The late-console-child and dropped-wrapper-option mechanisms were addressed in
fd02bc6 (the wrapper now decorates only bare calls, with documented passthrough for other argv).
The review-fix batch adds nested hook shape/matcher validation, retryable bridge offers/acknowledgements,
bounded cancellable interrupt I/O outside the agent mutex, updater exclusion beyond supervisor expiry,
modifier-aware leader dispatch, source-line diagnostics, ResumeThread failure handling and non-vacuous
leader/unknown-notify assertions. Final confirmation and exact-head CI remain required.

Self-review regression coverage at fd02bc6: combined local run
`selection-ui-20260908T210557-f4a554` passed 390/390; 29 retained descendants exited, clipboard and
touched registry restored, no queued launches; token generation 76 released. Focused generation 75
passed 51/51 and proved refusal for a late orphan attached to the same console. Pure tests after the
review fixes pass 87 command, 59 agent/I/O, 30 installer and 28 script checks. The next combined run
also exercises the actual five-minute update-supervision expiry; those pending results are not claimed.

Record the exact candidate, Codex-only revmux completeness/dispositions, combined local counts,
full Windows CI run and implementation/companion-doc PRs in the final PR delivery note. This document
does not claim those pending gates have passed. No release/tag is authorized or produced by P11.

Confirmation `02-after-fix` at cde398d had 2/2 healthy Codex sources, retaining 3 major lifecycle
defects: updater grandchildren surviving viewer close, unknown canceled-write completion, and numeric
authorization reuse after UI adoption. A hook-handler union validation gap was classified pre-existing
to that fix range but is still part of P11, so it is included rather than deferred. The next batch
owns updater descendants in a suspended-before-assignment native job (the overlay only views its log),
retains the input lease and duplicated I/O handle through actual cancellation completion, and uses a
GUID authorization independent of the numeric gate token. It also compare-publishes bindings so a late
receipt cannot overwrite a newer user value. Pure checks pass 61 agent/I/O, 37 installer and 28 script
cases. The preceding cde398d combined run passed 396/396, with 33 retained descendants exited and token
77 released after restoration; a new exact-candidate run and blocker-only confirmation remain required.

At eb4e7fb the combined suite passed 399/399; all 35 retained descendants exited, restoration passed,
no queued launches remained, and token 78 was released. Confirmation 03 reported 2/2 sources with no
degradation; adversarial returned zero findings (its event archive records source inspection).
Two confirmed defects remained: value-only publication missed a newer same-value/ABA binding clear,
and PowerShell's case-folded lookup accepted wrong-case hook schema keys. Both are included in the next
batch: per-pane binding generations cover every runtime binding writer and stale adoption/restart;
recognized hook key spellings are checked before destination writes. Regression tests cover the clear,
ABA, and seven wrong-case shapes including unchanged helper/profile/settings destinations. Pure checks
pass 63 agent/I/O and 44 installer cases. Final candidate CI and narrow confirmation remain required.

Confirmation 04 had no actionable findings; its pre-existing full-upstream-hook-schema coverage gap
is accepted as nonblocking follow-up #60, not silently labeled fixed. Both sources reported; the
zero-finding adversarial source has inspection events. However the e1b2310 local run failed one of
400 checks: after a previous YOLO, one pane acknowledged its update resume but returned to PowerShell's
fallback prompt without a live resumed agent. This was a real failed dispatch, not just a missing log
line. All 35 retained children exited and token 79 was released after verified restoration.

The next batch removes native execution from the prompt function: PSConsoleHostReadLine returns an
authorized command to the host's normal pipeline before invoking the prior reader for ordinary input.
It does not edit PSReadLine's draft. Only one interrupt is queued; an I/O completion cannot prove that
the console consumed a second Ctrl+C. Three successive native restarts now precede the two-pane update
test; failure records both pane screens and events. The fake's shared append log is serialized so
simultaneous launches cannot overwrite evidence. Unit coverage proves reader preservation, no execution
inside the boundary function, and no claim during prompt rendering (29 script checks pass).
