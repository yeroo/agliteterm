# P12-lite — remaining workspace and attention verbs

Boris authorized end-to-end delivery on 2026-09-09. Codex owns `agliteterm-p12`
(base 8a5fc12) and `agwinterm-p12-status` (base fe585d0). Claude remains unavailable;
reviewers are Codex-only. No release/tag, canonical contract expansion or image work.

## Scope and safety boundaries

- `broadcast on/off/toggle/state/get`: default off, runtime only. Human keyboard input fans
  out to live writable uncovered panes in the displayed session's workspace, including splits.
  Readonly and restart-reserved recipients refuse input. Popup/covered input stays targeted;
  paste, API typing, terminal replies and mouse reports never broadcast. A persistent visible
  warning must remain even with the status bar hidden. Invalid operations change nothing.
- `notify`: resolve a real session/pane, increment a distinct notification badge, emit a bounded
  event, show a clickable in-app banner and request a bounded tray balloon without stealing focus.
  Resolve again on click; no stale indices. `session.seen` and selecting the session clear the badge.
- `dashboard`: up to nine distinct visible-tree sessions, explicit selectors or MRU defaults.
  Live fixed-strike previews, clipped rather than zoomed; no PTY/emulator resize. Refuse nonzero
  font-size (Boris's no-zoom rule), malformed lists and unknown selectors without replacing a
  working dashboard. View-only navigation by arrows/Home/End/Enter/Space/Escape and mouse.
  No shell keyboard, paste, wheel or mouse leakage while the grid owns input; closed items are pruned.
  Expose `op=state` read-back for automation. Provide palette/keymap actions; preserve the existing
  Ctrl+Shift+D split binding rather than silently reassigning it.
- `restore.clear`: remove only this instance's saved state and automatic fallback/temp files,
  serialized against saves, fencing older snapshots. Keep live panes, pins and bindings unchanged.
  Retain a per-instance clear-intent marker to prevent legacy re-import. Later ordinary app saves
  may save them again; this is not a close-all or permanent
  disable operation. Report partial filesystem failures honestly, and never clear other instances.
- `workspace.move`: up/down/top/bottom, resolved and applied atomically, updating every workspace
  index (including hidden sessions, active/focused workspace and saved state). Invalid or ambiguous
  target/direction refuses; boundaries are no-ops. Numeric IDs remain order indices, documented.

## Acceptance and delivery

Pure tests cover operation parsing, reorder permutations and dashboard navigation/layout. Extend
the guarded selection fixture with P12-only and combined cases: actual posted keyboard input to
multiple private shells, targeted paste/API input, readonly/other-workspace/overlay exclusion;
notifications/badges/events/banner activation; live preview pixels, navigation/input isolation and
unchanged terminal geometry; workspace identity remapping/persistence; restore clear/fallback and
continued live panes. No real agents or shared user state may be test targets.

Acquire the canonical suite token before local integration and retain through owned-process exit,
clipboard/registry restoration and canceled launches. Full `run-all -Strict` only on disposable CI.
One full Codex-only revmux review, batched fixes and narrow confirmation when needed; additional
rounds require a concrete shipping blocker. Exact-head green CI before merge, implementation before
companion parity docs. Correct the old blanket parity claim: documented exclusions remain.
