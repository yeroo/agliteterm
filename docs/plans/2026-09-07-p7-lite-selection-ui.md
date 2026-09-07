# P7-lite — selection by keyboard and mouse

Batch **P7** of the parity programme (agwinterm `docs/plans/2026-09-03-parity-batches.md:171-175`,
Wave 2, lite-only): "mark mode (Ctrl+Shift+M, arrows, Enter copies) · Select All · drag-autoscroll
past the pane edge · the posted `WM_MOUSEWHEEL` that never reaches lite's handler (harness finding,
0.17.11)". Same model as P6, different surface: UI work, so the tests post input to the sandbox
window instead of calling verbs. There is no sibling agwinterm PR; the reference is agwinterm's code
(`src/Agwinterm.Win32/Program.Input.cs` `ToggleMarkMode` / `MarkModeKey` / `MarkModeCopy` /
`SelectAll` / `SelectWord` / `SelectLine` / `SelAutoscrollTick` / `ClampSel`,
`Program.WndProc.cs` `WM_MOUSEWHEEL` / `WM_MOUSEMOVE` / `WM_LBUTTONDBLCLK`) and the rules below copy
it; where lite deliberately departs, the departure is named as a difference for
`docs/lite-parity.md`.

Decision 2 of the batch index (`:41`, Boris, 2026-09-07: **the alt screen is pinned to row 0**)
landed its first half in P6-lite — `selection all`'s range. This batch lands the second half:
**while the alt screen is up, the wheel and the drag no longer scroll into main-screen history**,
the view offset is 0 everywhere it is read, and `qa/product.md`'s "the alt screen scrolls back into
main-screen history" bullet goes away.

P6-lite's Post-Completion hands this batch its list verbatim: "the wheel/drag pin on the alt screen
(`hitTest`, `paintPane`'s `off`, `scrollFocused`: `alt ? 0 : scrollOff`), drag autoscroll,
double-/triple-click, the popup painting a selection (lifting difference (c)), mark mode."

This batch builds on **P6-lite** (PR #45, head `af737e7`, not merged at the time of writing):
`selectAllOf`, `paneOf`, `postClipboardUtf8`, the locked `selection.*` arms, the `Sel selection`
snapshot in `paintPane`. Execution: branch `feat/p7-lite-selection-ui` **from `af737e7`** in a new
worktree `C:\Users\boris\source\agliteterm-p7` (leave `agliteterm-p6` on its branch for #45's
remaining rounds); rebase onto `main` once #45 merges, before the PR is marked ready. **All line
numbers below are on `af737e7`.**

## Overview

Six things, one invariant. The invariant is P6's, now applied to every reader and writer of the
view offset:

> **THE PIN.** While a surface's alt screen is up, its view offset is 0: `paintPane` composes no
> history above the grid, `hitTest` maps a click to `historyCount + row`, `selection all` starts at
> `historyCount`, and no input path — the wheel, the popup's wheel, `KB_SCROLLUP`/`KB_SCROLLDN`,
> drag-autoscroll, mark mode's Up — writes a non-zero `scrollOff` there. The highlight and the
> clipboard read the same cells, and neither can name a main-screen line.

Stated once, in the comment above the one helper that computes the offset (Task 1); every other
site says "THE PIN" and calls the helper. (P4's lesson: a rule copied into prose at N sites is N
chances to drift — put the condition in one place and quote its NAME everywhere.)

1. **The pin for the wheel and the drag** (Task 1). A helper `viewOff(Session*, const FfiEmuInfo&)`
   = `info.isAltScreen ? 0 : min(s->scrollOff, historyCount)`; `paintPane` :3853-3854 and
   `hitTest` :4184 use it; `scrollFocused` :4436 and the popup's `WM_MOUSEWHEEL` :5987-5989 return
   without writing while the alt screen is up (agwinterm `Program.WndProc.cs:577`
   `if (p.S.Emulator.IsAltScreen) return IntPtr.Zero;` — the offset is not accumulated, "an offset
   accumulated here would never be rendered, and silently move where clicks land"). Also: the wheel
   scrolls the surface **under the pointer**, not the focused pane — today `OnMouseWheel` :6613
   hit-tests the pointer for `mouseReport` and then :6614 scrolls `focusedSession()`, so in a split
   the wheel over the unfocused pane scrolls the other one (agwinterm `:571-582` scrolls the pane
   under the pointer). A wheel that lands on no pane (sidebar, splitter) does nothing.
   `KB_SCROLLUP`/`KB_SCROLLDN` :4757-4758 stay on the focused pane (keys go to focus) and obey THE PIN.
2. **Drag-autoscroll** (Task 2). Dragging past the top or bottom edge of the pane scrolls it one line
   per 50 ms tick and extends the selection to the row that scrolled in; on the alt screen the
   selection extends to the top/bottom visible row and stops (agwinterm `Program.Input.cs:957-961`).
   Timer id **3** (`kSelAutoTimer`; 1 and 2 are taken — :565, :572; `OnTimer` :6747 dispatches by id).
3. **Double- and triple-click** (Task 3). Double-click selects the word under the pointer,
   triple-click the whole visible line; both copy on release (lite's rule: selected with the mouse →
   copied on release). Word = a run of cells that are not space/NUL (agwinterm `SelectWord`
   `Program.Input.cs:873-891` with `word-delimiters` empty, its default `TerminalConfig.cs:109`; lite
   has no such knob — difference (g)).
4. **Mark mode** (Task 4). Ctrl+Shift+M enters keyboard selection anchored at the caret; arrows,
   Home/End move the focus end; Enter or Ctrl+C copies and exits keeping the highlight; Esc exits and
   clears; Ctrl+Shift+M exits and clears; every other key is swallowed while on. `MARK` is shown in
   the status bar while on. Bound by default; rebindable (File → Keyboard).
5. **Select All** (Task 4). Ctrl+Shift+A selects the focused surface's whole buffer — P6's
   `selectAllOf` :4319 — highlight only, no copy (agwinterm `SelectAll` `Program.Input.cs:926-936`
   never copies). Bound by default; rebindable. Palette entries for both.
6. **The popup paints a selection** (Task 5). `paintPopup` :5945 passes `-1` ("no selection span");
   the popup family (overlay, quick, scratch) gets the same drag, double/triple-click, wheel-pin and
   paint as a pane, and P6's refusal `the popup paints no selection` :9616-9617 is lifted:
   `selection all --target <popup id>` answers `selected all`, the overlay popup's `copy` returns the
   text (README:154-156's "always `no selection`" sentence goes). Difference (c) is retired.

**The posted `WM_MOUSEWHEEL` finding** (Task 0, first). Three places say a posted wheel never reaches
lite's handler (`qa/selection.md:148-150`, `qa/product.md:91-93`, `test/ui-lib.ps1:112-113`).
Discovery says the claim was made with a TUI up, where `mouseReport` :6613 legitimately forwards the
wheel to the app (the TUI holds mouse mode), and `[LiteUi]::Wheel` (`test/ui-lib.ps1:84`) has **no
caller in any suite** — the claim was never checked on the main screen. Task 0 checks it on the main
screen with a plain shell (no mouse mode) BEFORE anything else is built: if the wheel reaches
`scrollFocused`, the three sentences are corrected (they are simply wrong) and every scroll check in
this batch is automated with `[LiteUi]::Wheel`; if it does not, find out why in `OnMouseWheel`
:6600 (a posted message carries no `GetKeyState` context and `WM_MOUSEWHEEL` needs no modifier, so
there is no obvious reason) and fix the cause. Either way, `ui-lib.ps1:112-113`'s second half
("scrollback is driven from the keyboard (Shift+PageUp/PageDown) instead") is wrong on both screens
— `VK_PRIOR` :4835 encodes `ESC[5;2~` for the app; lite's scrollback keys are the unbound-by-default
`KB_SCROLLUP`/`KB_SCROLLDN` — and is rewritten with what is true.

Nothing here is persisted except the two new key bindings (the existing `HKCU\Software\agliteterm`
`Key_*` store); nothing emits an event.

## Context (from discovery)

All in `src/main.cpp` unless said (line numbers on `af737e7`, the P6 branch tip):

- `struct Sel` :1105-1129, `g_sel` :1130. `pane` (drag boundary, -1 none; P6: `paneOf` :4305 gives
  0 for an undisplayed target), `sess` (the SURFACE — the identity), `active` (drag in progress),
  `aRow/aCol` anchor, `bRow/bCol` end (**`bCol` is exclusive**; agwinterm's `SelFocCol` is inclusive —
  every range copied from agwinterm is `+1` on the end column), `epoch`, `alt`. `has()` :1117 is false
  while the ends coincide; `bound()` :1122; `norm` :1125.
- `LockG` :1086 (recursive). Every `g_sel` touch under it; `paintPane` snapshots `Sel selection =
  g_sel` :3871 under the hold and paints from the copy.
- `syncSelection` :4198-4216: drops on alt/main crossing :4208, renumbers on eviction :4209-4215.
- `selectionText` :4218; `setClipboardUtf8` :4273 (UI thread only); `postClipboardUtf8` :1940 (the
  posted road, `HA_CLIP`); `copySelection` :4297 (content test `find_first_not_of("\r\n ")`);
  `paneOf` :4305; `selectAllOf` :4319-4330 (the alt range `first = isAltScreen ? historyCount : 0`).
- `paintPane` :3844: `off` :3853-3854 (**clamps and writes back `s->scrollOff = off`**), the viewport
  composition :3856-3862, the highlight :3958-3973 (`selected = pane >= 0 && selection.isFor(s)`),
  the cursor :3974 (suppressed while `selected`, and while `off != 0`).
- `hitTest` :4168-4188: rect test :4175 returns false outside every pane (a drag that leaves the pane
  is simply ignored — `OnMouseMove` :6665 `hitTest(...) && pane == g_sel.pane`), `absRow` :4184.
- `mouseReport` :4403 (`cb` 0/1/2 buttons, 64/65 wheel; returns false when the app reports no mouse).
- `scrollFocused` :4436-4446 — the focused pane, clamp `0..historyCount`.
- `OnMouseWheel` :6600-6615 (palette :6601, `ScreenToClient` :6611, `mouseReport` :6613,
  `scrollFocused(±3)` :6614); `OnLButtonDown` :6616-6647 (splitter, palette, then under one `LockG`
  the hit-test, `mouseReport`, `g_sel = {…}` :6638-6640, `SetCapture` :6641); `OnMouseMove` :6648-6677
  (splitter drag, `mouseReport` motion, then the extend :6659-6675); `OnLButtonUp` :6678-6697
  (`releasedText` captured under the hold, `ReleaseCapture` unconditional, copy on release :6695-6696).
  Frame class :6483 has `CS_DBLCLKS`; there is **no `MSG_WM_LBUTTONDBLCLK`** in the map :6489-6528.
- Timers: `kCaretTimer = 1` :565, `kRelayoutTimer = 2` :572; `OnTimer` :6747 (`kRelayoutTimer` first,
  then `if (id != kCaretTimer) return;`). `SetTimer` at :1738, :1803, :10639 only.
- Keys: `KB_*` enum :978-980 (`KB_COUNT` last), `kKbInfo` :982-994 (label + registry name),
  `g_keys` :995, the one seeded default :2815 `g_keys[KB_PALETTE] = MAKEWORD('P', CONTROL|SHIFT)`,
  load :2818, save :2828 (the Keyboard dialog `g_kbCtl[KB_COUNT]` grows with the enum). Dispatch:
  `handleKeyDown` :4768 → binding match (`mods` + `MAKEWORD(vk, mods)` → `runKbAction` :4740);
  Ctrl+C / Ctrl+Shift+C :4808-4820; arrows → CSI :4827; `VK_PRIOR`/`VK_NEXT` → `~5`/`~6` :4835.
  Palette table `kPalActions` :1150 (`label, IDM, KB_*, -1`), shortcut column live from `g_keys` :4145.
- Status bar: `updateStatus` :4875; parts `{120, 360, 470, -1}` :10662 — part 2 is `cols × rows`;
  `[LiteHonesty]::StatusPart` reads a part (`test/control-honesty.ps1:721`, :744).
- Popups: `paintPopup` :5937 → `paintPane(mem, rc, s, -1, true)` :5945; `popupProc` :5950: no
  `WM_LBUTTONDOWN`/`WM_MOUSEMOVE`/`WM_LBUTTONUP` at all, `WM_MOUSEWHEEL` :5987-5989 (no
  `mouseReport`, no clamp to `historyCount`, `max(0, …)` only). P6's refusal :9616-9617.
- The remap's surface-verb exclusion list :8659-8660 (no new verbs here; unchanged).
- Harness: `test/ui-lib.ps1` — `Drag` :48, **`DragHold`** :61 (ported from agwinterm for autoscroll,
  "release too early and its 50ms timer never runs"; no caller yet), `Click` :75, **`Wheel`** :84,
  `Key` :100, `KeyMods` :114, `Chord` :133 (Ctrl(+Shift)+vk with the input queue attached so
  `GetKeyState` sees the modifier — what Ctrl+Shift+M / Ctrl+Shift+A need). `test/control-honesty.ps1`
  `[LiteHonesty]` :77-165 (`TakeForeground` :118, `StatusPart`), `Restore-Reg` :227.
  `test/clipboard.ps1` `[ClipIn]` :44-89 and its save/restore of the clipboard.
- agwinterm reference lines: mark mode `Program.Input.cs:784-848` (`_markMode` :784,
  `ToggleMarkMode` :786-799 — anchor at the caret :793-794, `MarkModeKey` :802-838 — reconcile-or-die
  :808, bounds :814 `minLine = alt ? hist : 0, maxLine = hist + rows - 1`, the key table :817-826,
  viewport follow :829-835 with the alt early-return :832, `MarkModeCopy` :842-848 copies with
  `clear: false`, exits, keeps the highlight); dispatch `:1142` before everything but the popup menu;
  `SelectAll` :926-936; `SelectWord` :873-891; `SelectLine` :893-897; autoscroll `Program.cs:214-220`
  (`SelAutoTimer = 7`, 50 ms), arming `Program.WndProc.cs:516-533` (`_selAutoDir` :523, the
  vertically clamped focus :525), tick `Program.Input.cs:950-967`; wheel `Program.WndProc.cs:540-584`;
  double/triple click `Program.WndProc.cs:407-411`, :451-467 (400 ms, `_clickCount`); the bounds test
  `tests/Agwinterm.Core.Tests/SelectionBoundsTests.cs`; QA `qa/selection.md:131-178` (three cases:
  autoscroll cannot walk into the other screen's history, Select All on the alt screen, mark-mode Up
  stops at the top of the alt screen) and `:94` (wheel on the alt screen changes nothing).

### Vocabulary

- **surface**: what a pane shows (P5's `surfaceOf`) — the shell, or its overlay while one is open;
  the popup family (overlay, quick, scratch) are surfaces with their own windows.
- **view offset**: rows the surface is scrolled up into history; `viewOff()` is THE PIN's one reader.
- **focus end**: `bRow/bCol` — the end a drag or mark mode moves; the anchor is `aRow/aCol`.
- **visible row**: `historyCount - viewOff + r`, `r` in `0..rows-1`.

### lite-parity differences (for agwinterm `docs/lite-parity.md`, the docs PR after merge)

P6's (a), (b), (d), (e) stand; (c) is **retired** by Task 5 and (e) is **closed** by Task 1 (the
wheel and the drag are pinned too; `qa/product.md`'s alt-screen bullet is deleted). New:

- **(f)** Ctrl+Shift+M turns mark mode **off** as well as on. In agwinterm the chord is swallowed
  while mark mode is on (`MarkModeKey` `:826` `default: return true`), so its off branch (`:788`) is
  reachable only from the palette — an agwinterm defect (file it there: follow-up issue). Lite does
  what the label says; the contract is not involved (no verb).
- **(g)** no `word-delimiters` knob: a double-click word is a run of non-blank cells (agwinterm's
  default). A knob is P10's (configuration surface).
- **(h)** mark mode shows `MARK` in the status bar's size part while on; agwinterm shows a toast on
  entry and nothing persistent. Lite has no toast; a mode the user can be in must be visible.
- **(i)** wheel speed is 3 lines per notch, fixed; agwinterm's `scroll-speed` (1–10) is P10's.
- Not a difference: Shift+arrows in mark mode do nothing in either product (agwinterm's entry toast
  promises "Shift+arrows by word/line" and does not implement it — `MarkModeKey` reads no shift).
  Lite's status text promises nothing it does not do.

## Constraints

- Sandbox instance per `qa/product.md` (`--pipe`, throwaway profile, `--no-restore`); PostMessage
  into the sandbox's own hwnd only — never `SendInput`/`keybd_event`; `PrintWindow` for captures.
- The clipboard and `HKCU\Software\agliteterm` are shared with the user's real app and every other
  sandbox: a test that writes either saves it first and restores it in `finally`, and asserts on a
  marker string it planted. The new `Key_MarkMode` / `Key_SelectAll` values are registry values:
  a test that binds or clears them restores them.
- **The hub suite token** (`C:\Users\boris\AI\docs\shared-resource-protocol.md`, `AGENTS.md`):
  every interactive suite or probe run acquires it first (`python C:\Users\boris\AI\bin\suite-token.py
  acquire --owner codex-agwinterm --run <id> --worktree <path> --holder-pid <pid of the pwsh running
  the suite>`, exit 0 AND `ok:true`), releases it after teardown and the clipboard/registry restore,
  and mails the other agent a release report (run id, hash, counts, teardown, restorations). Never
  run a suite while the other agent holds the token; a lost token = stop and ask.
- Every `g_sel` touch under `LockG`; no `SendMessage` from a pipe thread into the UI thread; post.
  The autoscroll tick and the mark-mode keys run on the UI thread and still take the hold (the reader
  thread evicts under it).
- Explicit `git add` paths; `.ralphex/` and `.revmux/` are never committed; commit trailers per
  the executor's session.
- Build only when no suite is running in the tree (`./build.ps1` overwrites the exe the suite is
  driving); never build while the other agent's suite runs anywhere (the token).
- Do not edit `C:\Users\boris\source\agliteterm` (Claude's tree) or `agliteterm-p6` once #45's
  rounds are done there; the P7 worktree is the only tree this batch writes.

## Testing Strategy

A new suite **`test/selection-ui.ps1 -Strict`** (registered in `test/run-all.ps1`'s list and so in
CI's `run-all -Strict`), dot-sourcing `ui-lib.ps1`, driving ONE sandbox through `[LiteUi]` posts
and reading the world through `session copy` / `Get-Clipboard` / `[LiteHonesty]::StatusPart` /
`session text`. Fixtures: a script that prints `MARKER-1..N` (N > rows, so some scroll into history),
and one that enters the alt screen (`\e[?1049h`), paints distinct text (`ALT-r` per row) and waits —
WITHOUT enabling mouse reporting (that is the point of Task 0). Every assertion names the rule it
pins ("THE PIN: …", "release copies: …"). Checks, in order:

- **Task 0**: main screen, posted wheel up 3 notches → `PrintWindow` shows older history;
  wheel down → identical cell-region capture. `session text` reads the whole buffer and cannot
  observe scrolling; `surface cursor` reports only a column. Alt screen: wheel up 10 → unchanged capture (`session copy` after
  `selection all` has no `MARKER-`). This is the check that replaces `qa/selection.md`'s MANUAL case.
- **Split**: two panes, focus left, wheel over the RIGHT → the right scrolls, the left does not.
- **Drag-autoscroll** (`DragHold` from inside the pane to y = pane top − 20, hold 1500 ms): the
  selection's first row is older than the top visible row was (`session copy` contains a `MARKER-`
  that was not on screen); the view scrolled (`PrintWindow` shows it); release copies to the
  clipboard the same text. On the alt screen: the same drag-hold → `session copy` starts at the top
  visible row (`ALT-0`) and contains no `MARKER-`. Below the bottom edge:
  symmetric, stops at the last row.
- **Double-click** on a word of `MARKER-7 word two` → `session copy` is exactly that word; the
  clipboard equals it (release copies). **Triple-click** → the whole line, trailing spaces trimmed.
  Double-click on a blank cell → no selection, clipboard untouched.
- **Mark mode**: plant a clipboard marker; `Chord('M', shift)` → `StatusPart(2)` ends with `MARK`;
  `Key(VK_RIGHT, 5)`, `Key(VK_DOWN, 1)` → `session copy` is the caret's cell to five cells right and
  one row down (seed a known caret with VT; the cursor API has no row); `Key(VK_RETURN)` → the clipboard
  equals `session copy`, `session copy` still non-empty (kept), `MARK` gone. Again with `Esc` →
  `session copy` `""`, clipboard untouched. Again with `Chord('M', shift)` twice → off, `""`.
  While on, `Key('X')` reaches no shell (`session text` unchanged after 300 ms). Alt screen: enter
  mark mode, `Key(VK_UP, 40)` → `session copy` has no `MARKER-` and starts at `ALT-0` (THE PIN, mark
  mode's door). A key that arrives after the app switched screens: mark mode is gone (`MARK` absent,
  `session copy` `""`) and the key was NOT swallowed.
- **Select All**: `Chord('A', shift)` → `session copy` holds every `MARKER-` line and the live grid;
  clipboard untouched (no copy); on the alt screen → no `MARKER-`, starts at `ALT-0`.
- **Bindings**: `Key_MarkMode` cleared in the registry (restored in `finally`) → `Chord('M', shift)`
  does nothing (no `MARK`); set to Ctrl+Shift+K → that chord enters. The palette and the Keyboard
  dialog are out of the harness's reach: assert the registry round-trip and the chord only.
- **Popup**: `session overlay open <command>` WITHOUT `--pane` → `[LiteUi]::Drag` on the overlay's hwnd
  (`Wait-Overlay`) → `overlay copy` returns the dragged text; `selection all --target <overlay id>`
  → `selected all`, `overlay copy` returns everything; wheel in the overlay on its alt screen →
  nothing. `PrintWindow` of the overlay shows an inverted band where the highlight is (compare two
  captures: before and after `selection all` differ; after `selection clear` equals before).
- **Refusals that stay**: `selection all --target nonsense` still `ok:false`; a wheel over the
  sidebar changes no pane.
- `qa/selection.md`: the MANUAL case `:139-165` is rewritten as **Wheel on the alt screen changes
  nothing** (automated now; keep it as the human-readable statement of THE PIN with the suite's check
  name); add agwinterm's three cases (`qa/selection.md:131-178` there) with lite's wording; delete
  `:10-12` ("lite has none of those features").
- `test/run-all.ps1 -Strict` green; `tools/check-contract.ps1` green (no contract change);
  `test/control-honesty.ps1`'s P6 section: the popup refusal check flips to the new answer.

## Progress Tracking

- [x] Task 0: the posted wheel verified on the main screen; viewport oracle corrected
- [x] Task 1: THE PIN — `viewOff`, wheel under the pointer, popup wheel, `KB_SCROLL*`
- [x] Task 2: drag-autoscroll (timer 3)
- [x] Task 3: double- and triple-click
- [x] Task 4: mark mode, Select All, bindings, palette, status bar
- [x] Task 5: the popup paints a selection; difference (c) retired
- [x] Task 6: tests (`test/selection-ui.ps1`), qa cases
- [x] Task 7: docs
- [ ] Task 8: [Final] verify acceptance criteria

## Implementation Steps

### Task 0: the posted wheel

Build `af737e7` (or the P7 branch at its first commit), start a sandbox, plain shell, print 200
lines, post wheel at a point inside the pane and compare `PrintWindow` cell-region captures.
Record the outcome in this plan (Technical Details) with the check's name. If the wheel reaches:
rewrite `test/ui-lib.ps1:112-113`, `qa/product.md:91-93`, `qa/selection.md:148-150` — the finding was
"a wheel posted at a TUI holding mouse mode is forwarded to the TUI", which is correct behaviour, not
a harness limit. If it does not reach: the cause is a bug in this batch's scope; fix it in Task 1 and
say what it was.

### Task 1: THE PIN

- `static int viewOff(Session* s, const FfiEmuInfo& info)` next to `paintPane`, with THE PIN's
  comment (the only statement of the condition). `paintPane` :3853-3854 → `int off = viewOff(s,
  info); s->scrollOff = off;` (the write-back stays: an offset accumulated before the app switched
  screens is dropped, so leaving the alt screen shows the live grid, not a stale offset — agwinterm's
  output handler resets it on every scroll generation anyway, `Program.Sessions.cs:98`). `hitTest`
  :4184 → `viewOff`. `selectAllOf` :4325 already agrees (`first`); leave it, cite THE PIN in its
  comment instead of "Wheel/drag hitTest and scrollOff are P7's work".
- `scrollFocused` :4436 → `scrollSurface(Session* s, int deltaRows)`: return without writing when
  `info.isAltScreen`; `scrollFocused` calls it with `focusedSession()`; `OnMouseWheel` :6614 calls it
  with the surface under the pointer (`hitTest` gives the pane; `surfaceOf(g_sessions[g_pane[pane]])`
  under the hold), or does nothing when the pointer is on no pane. `KB_SCROLLUP`/`DN` :4757 unchanged
  (they go through `scrollFocused`).
- Popup `WM_MOUSEWHEEL` :5987-5989 → `scrollSurface(s, ±3)` (gains the clamp and THE PIN; the
  `InvalidateRect(h)` stays — the popup is its own window).
- `qa/product.md:86-93` deleted; `:84-85` (scrollback not configurable) stays.

### Task 2: drag-autoscroll

- `static const UINT_PTR kSelAutoTimer = 3;` beside :572 with the comment at :561-562 extended ("three
  timers"); `kSelAutoMs = 50`. State: `static int g_selAutoDir = 0;` (−1 above, +1 below, 0 off),
  `static int g_selMouseX = 0;`.
- `OnMouseMove` :6659-6675: while `g_sel.active` and `MK_LBUTTON`, a pointer outside the selection's
  pane rect (`paneRect(g_sel.pane, …)`) is mapped to the nearest cell: row clamped to the top/bottom
  visible row, column clamped to `0..cols` (a new `cellAt(pane, x, y, &absRow, &col)` that clamps,
  used by `hitTest` for the inside case too, so there is one mapping); the vertical side sets
  `g_selAutoDir` and arms `SetTimer(g_hwnd, kSelAutoTimer, kSelAutoMs, nullptr)`; back inside →
  `g_selAutoDir = 0; KillTimer`. `g_selMouseX = pt.x` on every move (agwinterm `:525`: horizontal
  moves register out of bounds).
- `OnTimer` :6747: `kSelAutoTimer` → `selAutoTick()`: under `LockG`, bail (and kill the timer) unless
  `g_sel.active` and the pane still shows `g_sel.sess`; `syncSelection()`; if dropped, bail; read
  `info`; on the main screen `s->scrollOff = clamp(s->scrollOff - g_selAutoDir, 0, historyCount)`
  (one line per tick), on the alt screen no write (THE PIN); the focus end = the top visible row
  (dir −1) or the bottom (dir +1) at the column from `g_selMouseX`; `Invalidate`.
- `OnLButtonUp` :6678: `g_selAutoDir = 0; KillTimer(kSelAutoTimer)` before the copy. `killSession`
  :2369 and the other `g_sel.clear()` sites need nothing — the tick bails on `!active`.
- `test/ui-lib.ps1:58-60` `DragHold`'s "50ms" now names lite's own timer; say so.

### Task 3: double- and triple-click

- `MSG_WM_LBUTTONDBLCLK(OnLButtonDblClk)` in the map :6489-6528. Handler: splitter/palette/sidebar →
  return; `mouseReport(…, 0, true, false)` → the app gets a press (a mouse-mode app sees a second
  click, agwinterm's `:402` order); else under `LockG`: hit-test, the word span at `(absRow, col)`
  from the cell row (`emu_copy_history_row` / the live grid, as `selectionText` :4218 reads them):
  `a` = first cell of the run, `b` = one past the last (blank = space or NUL, `rune == ' ' ||
  rune == 0`); nothing on a blank cell; `g_sel = { pane, ss, false, absRow, a, absRow, b, evicted,
  alt }`; record the double-click time, surface and point. Keep `active = true` through the actual
  corresponding button-up; the shared release handler copies then, not during button-down.
- Triple: `OnLButtonDown` :6616: when `GetTickCount() - g_lastClickMs < GetDoubleClickTime()` and
  `g_clickCount == 2` → the whole visible line `{absRow, 0, absRow, cols}`, `g_clickCount = 3`,
  `active = true`, copy on the corresponding button-up; else begin a normal drag.
- Lite's rule stays "selected with the mouse → copied on release", including double/triple-click.

### Task 4: mark mode, Select All

- `KB_MARK`, `KB_SELECTALL` appended before `KB_COUNT` :980; `kKbInfo` rows `{ L"Mark Mode (keyboard
  select)", L"Key_MarkMode" }`, `{ L"Select All", L"Key_SelectAll" }`; seeded defaults beside :2815:
  `MAKEWORD('M', CONTROL|SHIFT)`, `MAKEWORD('A', CONTROL|SHIFT)` (the registry overrides, cleared =
  0, as `KB_PALETTE`). Palette rows in `kPalActions` :1150 (`IDM` 0, like the focus rows) — and the
  Edit menu beside `IDM_COPY` :5115 (new `IDM_*` ids for both, so the menu and the palette run one
  action).
- `runKbAction` :4740: `KB_MARK → toggleMarkMode()`, `KB_SELECTALL → { LockG lk; Session* s =
  focusedSurface(); if (s) selectAllOf(s); }` (`focusedSurface` = `surfaceOf(focusedShell())` or the
  focused popup — the same resolution `--target active` uses for a surface verb, THE RULE :8659;
  reuse its helper, do not write a second one).
- `static bool g_markMode = false;` `toggleMarkMode()`: off → on: under `LockG`, `s =
  focusedSurface()`, `info`, anchor = the caret: `absRow = historyCount + cursorRow` (THE PIN: on the
  alt screen that is the caret's row; on the main screen it is the live grid's row — agwinterm `:793`
  `hist - (alt ? 0 : clamp(ScrollOffset)) + row`; lite's caret row is a live-grid row, so
  `historyCount + cursorRow` on both screens), `g_sel = { pane, s, false, absRow, cursorCol, absRow,
  cursorCol, evicted, alt }`; `g_markMode = true`; on → off: `g_markMode = false; g_sel.clear()`
  (difference (f)); `updateStatus()`; `Invalidate`.
- `handleKeyDown` :4768, first thing after the palette branch: `if (g_markMode) return markModeKey(vk)`.
  `markModeKey`: under `LockG`: `syncSelection()`; if `!g_sel.bound()` → `g_markMode = false;
  updateStatus(); return false` (the key is NOT swallowed — the mode ended before it arrived; agwinterm
  `:808` swallows that key; lite lets it through: the user pressed it at a shell). Bounds `minRow =
  alt ? historyCount : 0`, `maxRow = historyCount + rows - 1`, `0..cols` for the exclusive end:
  `VK_LEFT/RIGHT` → `bCol ∓/± 1` clamped; `VK_UP/DOWN` → `bRow ∓/± 1` clamped; `VK_HOME` → `bCol =
  0`; `VK_END` → `bCol = cols`; `VK_RETURN`, and `'C'` with Ctrl → `copySelection()` (content rule
  :4298), `g_markMode = false` (highlight kept); `VK_ESCAPE` → off + clear; `'M'` with Ctrl+Shift →
  off + clear; anything else → swallowed (`return true`). Viewport follow on the main screen only:
  if `bRow < historyCount - viewOff` → `scrollOff = historyCount - bRow`; if `bRow >= historyCount -
  viewOff + rows` → `scrollOff = max(0, historyCount + rows - 1 - bRow)`; alt: nothing (THE PIN).
  `updateStatus(); Invalidate` after every key.
- The mode ends (clear + `updateStatus`) wherever the focused surface changes: `g_focus` writes
  :2111, :2129, :2601, :2628, :4755-4756, :6633, :6710, :9566, :10490 and the session-switch path —
  put it in ONE helper `endMarkMode()` and call it from a single choke point if there is one (the
  paint path notices `g_sel.sess != focusedSurface()`? no — a paint must not mutate state; find the
  choke point in discovery and name it in the commit message). Output does not end it.
- `updateStatus` :4875 part 2: `"%u × %u"` + `"  ·  MARK"` while `g_markMode`. `g_swallowChar`
  :996 must be set when a mark-mode key is swallowed so its `WM_CHAR` is dropped (`OnKey` :6552 does
  that from `handleKeyDown`'s return — verify the popup's `WM_KEYDOWN` :5971 path does the same).

### Task 5: the popup paints a selection

- `paintPopup` :5945 → `paintPane(mem, rc, s, kPopupPane, true)` with `static const int kPopupPane =
  2;` — a `pane` value the frame never hit-tests (0/1 are the slots); `g_sel.pane == kPopupPane`
  means "lives in a popup window". `paneOf` :4305 → `kPopupPane` for a popup session.
- `popupProc` :5950 gains `WM_LBUTTONDOWN` / `WM_MOUSEMOVE` / `WM_LBUTTONUP` / `WM_LBUTTONDBLCLK`
  (class needs `CS_DBLCLKS`) that call the SAME helpers as the frame (`beginDrag(surface, pane,
  rect, x, y)`, `extendDrag`, `endDrag`, the word/line select) with the popup's client rect and its
  hwnd for `SetCapture`/`Invalidate`; `cellAt` takes the rect, not the pane index. The autoscroll
  timer for a popup drag: `SetTimer` on the popup hwnd with the same id, the tick shared (the tick
  finds the window from `g_sel.pane == kPopupPane`).
- P6's refusal :9616-9617 removed; `selection all --target <popup id>` → `selectAllOf`; the overlay
  popup's `copy` arm :9062 returns the text when `g_sel.isFor(ov)` (it already does — the refusal
  was only ever `kOverlayNoSelection` when nothing was selected, which stays for that case).
- The overlay `copy` sentence in the skill (`src/main.cpp` skill string: grep `always` near
  `no selection`), README:154-156, `qa/control-honesty.md`'s overlay case, and P6's plan difference
  (c): retired, each says the popup now takes a drag and `selection all`.

### Task 6: tests

`test/selection-ui.ps1` per Testing Strategy; `run-all.ps1` list; the P6 popup-refusal check in
`control-honesty.ps1` flipped. `qa/selection.md` cases. Every check name states the rule.

### Task 7: docs

- Skill (the agent-facing text in `main.cpp`): the keys sentence gains "Ctrl+Shift+M mark mode ·
  Ctrl+Shift+A select all · double/triple-click = word/line · drag past the edge auto-scrolls"
  (agwinterm `AgentSkill.cs:162`'s shape) — with lite's "all rebindable" note.
- README: the Clipboard bullet :62-68 (mark mode, Select All, double/triple-click, autoscroll, the
  wheel on the alt screen); the keys paragraph :56-59 (two more seeded defaults beside Ctrl+Shift+P);
  :154-156 (popup `copy`); the verb count is unchanged.
- `qa/product.md`: `:75` deleted; `:86-93` deleted (Task 1); the "As of" line bumped.
- `qa/selection.md`: per Testing Strategy.
- `test/ui-lib.ps1:58-60`, `:112-113`: per Task 0 / Task 2.
- This plan: Progress, the Task 0 finding, the round records.
- For the agwinterm docs PR after merge (not this repo): `docs/lite-parity.md:296-304` rows Mark
  mode / Select All / Drag-autoscroll / Wheel → removed; `:224-225` (the popup paints no selection)
  → removed; the P6 differences list gains (f)–(i), retires (c), closes (e); the batch index P7 →
  shipped; an agwinterm follow-up issue for difference (f) (Ctrl+Shift+M swallowed in mark mode) and
  `Keymap.cs:97-101` (mark_mode missing from the starter keymap's action list).

### Task 8: [Final] verify acceptance criteria

- `./build.ps1` clean; `test/run-all.ps1 -Strict` green under the token; `tools/check-contract.ps1`
  green; `git status` shows no `.ralphex/`/`.revmux/`.
- revmux rounds until a round has no Major/Critical; each fix commit gets its own narrow round; the
  round records go in this plan. Mail Claude (`claude-agwinterm`) the review-request with the hash
  when round 1 starts and every fix hash after; fold his findings.
- PR against `main` (draft until #45 merges and the rebase is clean), body with the live evidence:
  the suite transcript, `PrintWindow` captures of a highlight in a pane and in the popup, the Task 0
  finding.

## Technical Details

- **Implementation choices:** `endMarkModeIfMoved()` is the fallback before key routing and on
  UI status/caret-timer updates, because focus writes have no single choke point. It reconciles
  both surface identity and screen generation before a key can be swallowed. Popup focus/hide
  paths invoke it too. Painting does not make focus decisions. Mouse helpers share rectangle,
  viewport mapping, capture and timer ownership between frame and popup HWNDs.
- **Initial UI evidence:** 32 checks passed in `selection-ui-20260907T225558-2f9fa0`; generation
  13 released after owned window/host exit and clipboard/registry verification. The prior run
  stopped at a transient clipboard read failure (12 checks, generation 12); a bounded read retry
  fixed the test harness. Further split/popup-family/boundary checks and review are pending.
- **Expanded harness correction:** WinForms/OLE test clipboard writes could leave a delayed-render
  owner on the test thread while posted-input helpers blocked that thread. Runs at generations
  15/16 observed empty clipboard reads and delayed popup startup (41/34 checks, 3/2 failures).
  Test marker/read operations now use native clipboard cmdlets, while original rich formats are
  still materialized and restored/verified in cleanup. Popup readiness uses a bounded wait.
  The repeat passes Ctrl+C, both drag directions, alt-screen bounds, split pointer targeting,
  popup/quick/scratch release-copy, and cleared/rebound mark bindings. Every attempt retained
  ownership through teardown and released only after its cleanup report.
  Run `selection-ui-20260907T230524-1f5193`: **46 checks, 0 failures**, generation 17 released.
  Fresh build `p7-build-20260907T230717` passed; generation 18 released. The canonical contract
  check passed (`contract: in step with agwinterm`). Popup/mark and Select All binding extensions
  are in the next 50-check verification run.
- **Full-suite constraint:** this worktree still inherits P6's unsafe legacy cleanup paths.
  Do not run the whole desktop suite until Claude's separately owned cleanup repair is safely
  integrated; token ownership does not authorize killing another user's window or shared host.
  The P7 harness performs no sweeps: it holds direct process handles, refuses pre-existing
  lite/host instances, checks residue without killing unknown processes, restores state, then
  releases its exact token. Local callers may supply `AGLITETERM_TEST_RECEIPT` to borrow their
  still-live receipt through all child tests; isolated CI has no hub helper.

- **Why one helper for the offset.** P6's difference (e) existed because three readers of
  `scrollOff` (`paintPane`, `hitTest`, `selectAllOf`) each stated the alt rule or did not; agwinterm's
  own history (`SelectionBoundsTests.cs:14-17`: one rule "reached three times by three different
  doors") is the warning. `viewOff` is the door.
- **Why double/triple-click stay active until release.** A complete word/line range is painted at
  button-down, but the clipboard must remain unchanged until the matching button-up. The shared
  release handler enforces this rather than copying early in the double-click handler.
- **Why mark mode's end is a choke point, not nine sites.** Nine `g_focus` writes plus the popup's
  focus override; a mode left on after a focus change swallows the user's keys at the new surface —
  the worst failure this batch can ship. Find the one place every focus change passes through (the
  paint reads `g_focus`; the choke point must be a write path) and end it there; if none exists,
  `endMarkModeIfMoved()` at the top of `handleKeyDown` (compare `g_sel.sess` to `focusedSurface()`)
  is the fallback, and it must be named as such in the plan.
- **`bCol` exclusive.** Every range from agwinterm is `SelFocCol + 1` here; `VK_END` is `cols`, a
  word is `[a, b)`, a line is `[0, cols)`; `selectAllOf` :4326 already does `(int)info.cols`.
- **Timer id 3.** `OnTimer` :6747 checks `kRelayoutTimer` then `kCaretTimer`; add the third case
  before the caret's `return`.
- **Task 0 finding (2026-09-07):** posted wheel reaches the unmodified P6 main-screen handler.
  Baseline source `af737e7` (plan commit `aef0c8d`), local native assets from the P6 build. Three
  upward notches moved the first visible marker from 153 to 144; three downward notches restored
  the view exactly. `PrintWindow` region: 723 pixels changed upward, 0 differed after returning.
  Run `p7-wheel-20260907T223349`, generation 8, both checks PASS; owned window/host exited,
  instance geometry restored, clipboard untouched, token released. Earlier probe iterations
  corrected a helper assembly reference, a wrong HWND and a blank-region pixel comparison;
  each released only after cleanup. Evidence: `.revmux/p7-wheel-20260907T223349/`.
  **Testing correction:** contrary to the draft above, `session text` returns the WHOLE buffer,
  never the composed viewport; scrolling does not change it. Keep this API contract unchanged.
  Use `PrintWindow` and selections at known cells for all viewport assertions below/above.
  `surface cursor` returns only a column, not a row; mark-mode fixtures must seed a known caret.

## Post-Completion

- agwinterm docs PR: `docs/lite-parity.md`, the batch index P6+P7 shipped, differences (a)–(i).
- agwinterm follow-up issues: difference (f) (Ctrl+Shift+M swallowed in mark mode; `Keymap.cs:97-101`).
- P10-lite carries: `CopyOnSelect`, `word-delimiters`, `scroll-speed`, scrollback size.
- Release: lite 0.17.x after merge (Boris tags).
