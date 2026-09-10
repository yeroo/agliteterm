# P17 acceptance

Local MSVC build and headless suites pass: targeting17, UI request state4015,
Wave3 112, configuration300, keymap/commands94, remainder3408, and both products'
conformance validators16 each. Targeting compiles the actual production resolver.

Local GUI attempt `selection-ui-20260909T202656-d50c5f` acquired token120 and
refused before launching because two existing full-app PTY hosts were present.
Zero Wave3 checks ran; no shared settings/clipboard were changed and no processes
were adopted or killed. Token120 released with no queued launch. This is NOT a
passing GUI result; disposable CI supplies the integration evidence below.

Tests exercise typed HUD and picker refusals, native controls and exact result
retention, nonactivation, workspace collapse/navigation, quick content routing and
hidden retention, and config boundaries. Real global-hotkey/foreground interaction
must not be forced on Boris's desktop. Cross-process answers, terminal UIA, images
and raster-font zoom are outside the stated lite boundary (docs/wave3.md).

Shipping requires healthy broad/final Codex-only review and exact-head green CI,
including shared conformance and run-all -Strict. No release/tag/install.

## Candidate evidence

Final confirmation was completed on 2026-09-10: revmux task `feat-p17-lite-wave3`,
round `04-final-confirmation`, scope `baaac5b..ac4896a`, exit 0, both Codex reviewers
reported with no degradation and no findings. Synthesis completed; verification had
no findings to process. This closes the earlier unfinished review gate; it does not
relabel those failed runs. Receipt: PR65 comment 5610410922. Final exact-head CI34408508506
passed before merge `bc741988`, including Wave3 GUI110 and full guarded UI575 checks.

- Lite `baaac5b`, CI34388447789: all strict checks passed; dedicated Wave3 GUI110
  and full guarded UI575 checks, both zero failures with verified cleanup.
- Canonical companion PR272 merged as `49328bced2d28b8cd7c8db34d527d8486aa63ec0`.
  Candidate `7c3357f` passed CI34388151034: conformance, Win32/clipboard/paste,
  HUD51, Quick57, Navigation51, Picker36, Core326 and Pty794.
- Broad review01: all four Codex sources completed. Final02 exhausted quota;
  retry03's two finders completed, but launcher shutdown hung. Original completed
  reports were recovered from durable session logs; final synthesis/verification
  did not run. Codex personally verified their one corroborated targeting defect
  and the outstanding canonical-main URL dependency, without another broad round.
- The final code fix preserves hidden split-pane prefixes while refusing cover
  prefixes, using the existing `isCoverLocked` distinction. The production resolver
  harness covers list order, exact identity, name fallthrough and quick refusal.
- The final workflow uses canonical main again. Fresh exact-head CI on this final
  fix/URL revision is required before PR65 merges; the earlier green run is not
  substituted for that gate. The PR and GitHub run record hold the final receipt.
