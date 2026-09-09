# P12 acceptance

Build first, then run `test/remainder.unit.ps1` (pure) and
`test/selection-ui.ps1 -Strict -RemainderOnly -TokenOwner YOUR_ACTUAL_OWNER` locally.
The latter acquires the canonical shared suite token and retains it through verified descendant
exit, whole-format clipboard and touched-registry restoration. Do not use a peer's receipt.
All shells/files/notifications belong to the redirected private fixture; no real agents are used.

The combined selection fixture includes P7/P9/P10a/P10b/P11/P12. Full `test/run-all.ps1 -Strict`
is a disposable Windows CI gate only (#51), not a shared-desktop test command.

Automated acceptance covers broadcast delivery/exclusion and source readonly, targeted API input
and paste; live dashboard pixels, keyboard/mouse navigation, input isolation, validation and geometry;
notification badges/events/banner activation; workspace remapping/reopen history and clear/fallback
files, including locked-backup errors and a blocked clear marker. Disposable CI's migration fixture
also verifies that the marker alone prevents legacy re-adoption. Raw private byte sinks provide
positive keyboard/mouse input evidence. Every captured descendant must exit before
token release; a cleanup exception retains the lease even when test assertions fail.

Manual UX checks: readable fixed-strike preview clipping with each installed font; notice banner
on a tiny window; dashboard navigation with assistive tools; optional Windows notification balloon
under the user's own notification policy. Automated tests do not assert OS balloon visibility or
seize foreground to make it appear.

Known test follow-up: deterministic scheduling of an already-snapshotted save across `restore.clear`
is not fault-injected. The shared stamp/save-lock fence is reviewed, but ordinary clear acceptance
is not evidence of that exact race schedule.
