# Legacy test safety migration (#51)

The clipboard entry point delegates to `selection-ui.ps1 -ClipboardOnly`, preserving its
whole-format snapshot before the first probe, DPAPI recovery file, per-action sequence/owner/text
receipts, value-kind-preserving registry ledger, suite-token ownership and independent teardown.
It tests right-click paste into a mouse-reporting pane, real-child OSC 52 and DSR, drag/keyboard
copy and Ctrl+C interruption. Ledger reads/restoration refuse an unproven newer generation.
Paste itself cannot atomically exclude unrelated clipboard writers, so `-ClipboardOnly` refuses
local execution (including token-held runs). It requires disposable GitHub CI with no local hub.
The paste sink stores only a boolean comparison and exits immediately, never recording pasted text
or returning to a shell prompt that could execute additional pasted lines.

This is the first migration, not completion of #51. The remaining legacy control-honesty,
conformance, implicit registry writes and top-level runner still need equivalent guards. Those
entry points remain CI-only; this change does not authorize local `run-all`. Cleanup uncertainty
must retain the lease and recovery artifact rather than force restoration or broad process cleanup.

Validation: parser checks and the existing fake clipboard/registry/cleanup state-machine tests
run without touching the desktop. Actual clipboard acceptance runs on isolated CI until the
full migration is reviewed and the shared-suite protocol is complete.
