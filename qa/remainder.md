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

`test/state-fence.unit.ps1` compiles the production clear and save-publication bodies against
private file/lock fakes. It deterministically orders an old snapshot after clear, a newer save
before clear's I/O lock, and a fresh save after clear. It also covers marker failures and partial
deletion: only a durable clear fences old snapshots, including when some deletes fail. This is
schedule/logic coverage, not a claim to simulate Windows filesystem durability.

`test/reopen.unit.ps1` compiles the production reopen body and create/attach destination wiring
with a fake host wait. Undo-close retains a process-local workspace identity across rename,
reorder and index shifts; deletion falls back to the first workspace, without treating a new
same-name workspace as the old one. Persisted workspace indexes and the TSV schema are unchanged.
An overlapping creator cannot steal the newly reopened session's selection.

The killed-repaint restore cell types its marker once, then uses bounded read-only polling before
the kill and after adoption. A pre-kill deadline is a readiness failure, not evidence against adoption.
`test/restore-readiness.unit.ps1` tests delayed output, deadline diagnostics and failed reads without
launching a terminal. The complete restore matrix remains disposable-CI-only under the rule above.
