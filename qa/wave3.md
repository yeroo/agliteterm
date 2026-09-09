# P17 acceptance

Local MSVC build and headless model suites pass: Wave3 112, configuration 300,
keymap/commands 94. The guarded Wave3 fixture is part of strict run-all in CI.

Local GUI attempt `selection-ui-20260909T202656-d50c5f` acquired token120 and
refused before launching because two existing full-app PTY hosts were present.
Zero Wave3 checks ran; no shared settings/clipboard were changed and no processes
were adopted or killed. Token120 released with no queued launch. This is NOT a
passing GUI result; disposable CI is the remaining integration gate.

Tests exercise typed HUD and picker refusals, native controls and exact result
retention, nonactivation, workspace collapse/navigation, quick content routing and
hidden retention, and config boundaries. Real global-hotkey/foreground interaction
must not be forced on Boris's desktop. Cross-process answers, terminal UIA, images
and raster-font zoom are outside the stated lite boundary (docs/wave3.md).

Shipping requires healthy broad/final Codex-only review and exact-head green CI,
including shared conformance and run-all -Strict. No release/tag/install.
