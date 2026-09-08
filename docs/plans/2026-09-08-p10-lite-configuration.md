# P10-lite — configuration surface

Codex-owned plan under Boris's 2026-09-08 delivery delegation; Claude is unavailable. Base:
P9-lite main `190e514`. Worktree `C:/Users/boris/source/agliteterm-p10`, branch
`feat/p10-lite-configuration`. No edits to Claude's worktrees or real user preferences.

## Delivery split

P10a (this PR) establishes one validated registry-backed setting definition and seven verbs:
`config.get/list/set`, `theme.list/set`, `settings.open`, `keymap.reload`. It adds configurable
replica scrollback and copy-on-select. P10b remains explicit follow-up work: font targeting and
catalog-size semantics, custom profile storage/reload, OMP catalog/application, and opt-in replay
of captured commands. P9's find bar, divider drag and image backgrounds are not swept into P10a.
P10 as a whole is not complete when P10a ships.

## Contract and decisions

- Supported config keys are defined once, with registry name/type and validation. `get` returns
  the current instance's value; `list` returns `key = value` lines for supported keys only.
  `set` persists only that key and replies with the value in effect. Unknown/missing/invalid keys
  or values refuse `ok:false`; never save an inert unsupported setting. Changes apply to this
  instance; other running instances retain their state, while subsequent launches read HKCU.
- Keys: theme (auto/light/dark/classic), custom-colors, foreground/background (#RRGGBB), dos-palette,
  sidebar-font-size (0 or6..24), show-sidebar/toolbar/status, flag-view, right-click-paste,
  copy-on-ctrl-c, copy-on-select, scrollback-lines (0..1000000). Booleans accept true/false/on/off/1/0.
  Numbers are strict decimal integers, no signs/fractions/overflow. Preserve existing defaults.
- Settings and theme effects run on the UI thread. Pipe threads enqueue reference-counted requests
  without holding g_lock; bounded waits cancel still-pending requests. A request already executing
  at timeout reports an unknown outcome requiring read-back, never a false nothing-changed claim.
  Queue storage owns requests, not raw message pointers; timed-out queued work is removed.
- Persist before applying; failure preserves runtime state. Each setter writes one registry value,
  never a broad saveColors snapshot. Existing Properties/Keyboard dialogs edit snapshots, so mutation
  verbs refuse while the frame is modal-disabled. Reads remain allowed. No lost dialog edits.
- theme.list exposes lite's existing UI modes, not agwinterm's full terminal-theme catalog.
  theme.set validates a mode and uses the same setter. Unknown names refuse theme not found.
- settings.open queues Properties and says settings open requested (not proof it became visible).
  Repeated requests during a modal dialog refuse; no nested Properties dialogs from the API.
- keymap.reload clears stale in-memory bindings, seeds defaults, reads the registry, preserves
  explicit zero and reports keymap reloaded. Reload does not delete registry values. Keyboard
  dialog-open refusal avoids overwriting an in-progress edit.
- scrollback-lines defaults to the core's existing 5000. It applies to newly created replicas,
  including fresh split/popups and adopted/failed surfaces created after the change, not existing
  buffers. Reply names new surfaces. Bind agwcore_emu_set_scrollback at existing ABI18, configure
  before feeding any bytes, cover both emu_new sites. No host cap change or live history eviction.
  Positive caps retain the core's batched eviction (up to 512 additional history rows); zero
  disables history immediately for the new replica. Tests must exceed the batching threshold.
- copy-on-select defaults true, matching lite's release-copy behavior. False suppresses mouse
  release and selection.finalize clipboard writes; finalize says finalized (copy-on-select off).
  Explicit selection.copy, keyboard mark Enter/Ctrl+C and copy commands remain available.
- No new shared conformance steps: canonical config/theme are explicitly outside its floor.
  Record product differences in README/skill text and parity tracker after merge.

## Implementation and acceptance

1. Pure config definitions/validation and table-driven unit tests: every type, bounds, absent,
   malformed, overflow, unsupported, canonical read-back and all keys covered.
2. UI-marshaled config handler, exact single-value persistence, effects and refusal paths;
   no g_lock held across UI waits or pty I/O. Key reload starts from defaults each time.
3. Bind/seed emulator scrollback in both creation paths; copy-on-select gates both automatic
   writers while preserving explicit-copy behavior.
4. Guarded live fixture: every key read/write, invalid requests leave state unchanged, untouched
   sentinel registry value remains intact, persistence/restart, new-vs-existing scrollback,
   theme mode/read-back and pixel effect, key deletion/explicit zero reload, modal refusal,
   copy-on-select on/off on frame/popup/API-finalize with positive copy controls.
5. Acquire canonical suite token before any local UI test; save each touched registry type/data,
   whole-format clipboard receipts and owned-process handles. Hold through verified cleanup and
   release exact receipt. Full legacy run-all runs only on disposable CI until lite #51 is fixed.
6. Build, unit tests, guarded live acceptance, full Strict CI. One full Codex-only revmux review,
   batched fixes, one narrow confirmation when needed. No cosmetic review loops. Merge exact
   tested head only after gates; Boris retains release/tag authority.

## Execution

- P10a implementation is present. Local MSVC build, 142 configuration unit checks, 30 driving
  unit checks and the mirrored contract check pass. Guarded combined live acceptance and
  independent Codex-only review are in progress; full disposable Windows Strict CI gates merge.
- P10b is not implemented by this plan's PR. Final evidence and review dispositions belong in
  the PR, so a documentation-only evidence update does not restart the review loop.
