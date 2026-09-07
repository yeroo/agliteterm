# P6-lite — `selection.*`, the agliteterm half

Batch **P6** of the parity programme (agwinterm `docs/plans/2026-09-03-parity-batches.md`, Wave 2,
lite-only): the four selection verbs agwinterm has answered since 0.15 and lite refuses as
`unknown command … (lite subset)`. agwinterm's half is already shipped — there is no sibling
agwinterm PR for this batch; the reference is its code (`src/Agwinterm.Win32/Program.ControlHost.cs`
`SelectionAll` … `SelectionFinalize`, `Program.Input.cs` `SelectAll` / `CopySelection` /
`FinalizeSelection` / `ClampSel`) and the rules below copy it, they do not re-decide it. The
batch index calls this the sharpest gap in `docs/lite-parity.md` ("lite has `session.copy` but no
way to **make**, clear or finalise one") and sizes it small: the selection model (`g_sel`, keyed by
the surface a drag hit) already exists behind `session.copy`, `overlay copy` and the mouse.

Decision 2 of the batch index is answered and lands here in its first half: **the alt screen is
pinned to row 0**, agwinterm's way. `selection all` on the alt screen selects the app's screen
only — never the main-screen history that lite still composes above it. The second half (the
wheel and the drag stop scrolling into main-screen history while the alt screen is up, drag
autoscroll, the popup painting a selection) is **P7-lite**, not this batch.

This batch builds on **P5-lite** (PR #40, merged as `d03695a`): THE RULE for `--target active`,
the remap's surface-verb exclusion list, `surfaceOf`, `focusedShell`, `splitOwnerOf`, the pane
overlays a selection can live in. Execution uses `feat/p6-lite-selection` in
`C:\Users\boris\source\agliteterm-p6`, branched directly from merged `main` at `d03695a`.

## Overview

Four verbs, all **surface verbs** under THE RULE (they act on `g_sel`, which is keyed by the
surface a drag hits): an empty target / `active` is the focused pane's surface — its pane overlay
while one is open, the popup while that is focused — exactly as `session copy` resolves it;
`--target <overlay id>` reaches the overlay (that is how `session overlay copy --pane X` gets a
selection through the API, agwinterm's `Copy_NoSelection_ThenSelectionAllOnTheOverlay_ReturnsItsText`);
`--target <split shell id>` reaches that shell (P4's meaning); `--target <session id>` on a split
reaches the shell in slot 0. Every reply is a **bare string** (`ctlOkStr`) with agwinterm's exact
words; an unresolved target is refused the way every lite verb refuses it (`ok:false`,
`session not found` / the ambiguity sentence) — see difference (a).

- **`selection all [--target ID]`** — select the target's whole buffer: every history row and the
  live grid, column 0 of the first row to the last column of the last row, linear (there is no
  block selection in lite). Reply `selected all`; `empty` when the buffer has no cells
  (`historyCount + rows == 0` or `cols == 0`, or the target has no emulator). On the **alt screen**
  the range starts at `historyCount`, not 0 — the app's screen only (`alt = true` in `g_sel`, so
  the app's return to the main screen drops it, `syncSelection`'s rule) — and the reply is still
  `selected all`: it selected all of what that screen shows. The selection replaces whatever
  selection existed anywhere (lite has one, window-wide), the way a drag does; it is painted where
  the target is on screen and merely readable (`session copy --target`) where it is not (a shell
  under an overlay, a session in another workspace) — see Technical Details for the `pane` field.
- **`selection copy [--target ID]`** — put the selection's text on the Windows clipboard and clear
  the highlight (agwinterm's `CopySelection(p)` default `clear: true`). Reply `copied N chars` (N =
  the length of the text put on the clipboard, CRLF-joined, trailing spaces trimmed per line — what
  `session copy` returns); `no selection` when the target has none (the window's selection belongs
  to another surface, or there is none); `nothing to copy` when the selection is live but its cells
  hold no text — a TUI blanked them — in which case the clipboard is left alone but the highlight
  is still cleared (agwinterm's `CopySelection` clears regardless of content). The clipboard write
  lands on the UI thread (posted, `HA_CLIP`'s road); the reply counts what was posted — difference (d).
- **`selection clear [--target ID]`** — drop the selection if it is the target's; repaint. Reply
  `cleared` always, with nothing selected there or not (agwinterm: `ClearSel` is unconditional).
  A selection that belongs to a **different** surface is left alone: `clear` on session B does not
  take A's highlight away.
- **`selection finalize [--target ID]`** — run the path a mouse-up runs: the copy-on-select copy,
  highlight kept. Lite's rule is "selected with the mouse → copied on release", unconditional (the
  README's Clipboard bullet; there is no `CopyOnSelect` knob), so this is `copySelection()` without
  the clear: reply `finalized (copied)` when text landed on the clipboard, `finalized (empty)` when
  the selection is absent or blank (clipboard untouched). agwinterm's third reply,
  `finalized (copy-on-select off)`, is never given — difference (b). Like agwinterm's, this is a
  scripting/testing hook and is left out of the skill's verb list; the CLI already accepts it.

Nothing here is persisted, nothing emits an event (agwinterm emits none for selections either);
the only side-effects are the repaint and, for `copy` / `finalize`, the clipboard.

**The popup family (overlay, quick and scratch).** `paintPopup` draws no selection and `hitTest`
never enters these popups; the overlay popup's `copy` is "always `no selection`" (skill, README).
A verb that could plant an invisible
selection there breaks the rule this batch inherits from agwinterm's `ClampSel` — *the highlight
and the clipboard read the same cells*. So `selection all` on the popup (by its id or as `active`
while it is focused) is **refused**: `the popup paints no selection` — one sentence, `ok:false`;
`clear` answers `cleared` (nothing can be there), `copy` `no selection`, `finalize`
`finalized (empty)`. Difference (c); P7-lite may lift it by painting one.

## Context (from discovery)

All in `src/main.cpp` unless said (line numbers on `83cffde`, the P5 branch tip):

- **`struct Sel` / `g_sel`** :1105-1130 — one selection window-wide, keyed by `sess` (the
  **surface**: `OnLButtonDown` :6598 stores `surfaceOf(g_sessions[si])`), `pane` used only by
  paint (:3948, `g_sel.pane == pane`) and to reject a cross-pane drag (:6628); rows are
  buffer-absolute (history first, then the live grid), `bCol` is an exclusive end column;
  `epoch` = the session's `evicted` when taken; `alt` = the screen it was taken on;
  `has()` needs `pane >= 0 && sess && (aRow != bRow || aCol != bCol)`. Every touch is under
  `g_lock` (`LockG` :1088, a recursive CRITICAL_SECTION) except the read at :9550 — see Task 1.
- **`syncSelection`** :4187-4204 — drops the selection on a screen switch (`alt` mismatch) and
  when its rows were evicted; renumbers otherwise. **`selectionText()`** :4207-4258 — no argument,
  reads the global; one `LockG` across reconcile and extraction; reads the LIVE emulator (history
  rows via `emu_copy_history_row`, the grid via one `emu_copy_grid`) so a shell under an overlay
  still answers; CRLF join, trailing spaces trimmed. **`copySelection()`** :4286-4291 — the
  content test (`find_first_not_of("\r\n ")`), then `setClipboardUtf8` :4262 which is **UI thread
  only** (`OpenClipboard(g_hwnd)`; the comment says a reader thread posts across). The road across
  is `PostMessageW(g_hwnd, WM_APP_HOSTACT, HA_CLIP, new std::string(text))` :1960, consumed at
  `OnHostAction` :6851-6855. Mouse-up copies unconditionally at :6653 ("auto-copy on release
  (convention)"); Ctrl+C at :4770-4779 behind `g_copyOnCtrlC` :1136 / registry :2803.
- **Clearing sites**: `killSession` :2362, `unlistOverlayLocked` :2389, `syncSelection` ×3,
  `OnLButtonDown`'s overwrite :6602, `closeSplitSide`'s `pane = 0` fix-up :2593.
- **The buffer's geometry**: `FfiEmuInfo` :77-87 — `cols, rows, isAltScreen, historyCount,
  scrollGeneration`; total rows = `historyCount + rows`. `hitTest` :4157-4178 and `paintPane`
  :3846-3852 compose `historyCount - scrollOff + r`, on the alt screen too (the qa/product.md
  difference P7 removes; this batch does not touch `scrollOff`).
- **Dispatcher**: `ctlDispatch` :8339+; the `active` remap and its comment :8580-8612 — the
  exclusion list at :8603-8604 is THE surface-verb list; `session.copy` :9548-9551 (`isFor` then
  `selectionText()`), `session.paste` :9553; `overlay copy`'s pane arm :8954 and popup arm :9006
  (`kOverlayNoSelection` :7394); `resolveTarget` :7616; `indexOfSession` :2086; `focusedSession`
  :1651, `focusedShell` :1662, `surfaceOf` :1650, `splitOwnerOf` :7555, `isCoverLocked` :7522;
  `g_pane` :1098; `g_overlaySession` / `g_overlayHwnd` (the popup); unknown verb :9900.
- **The skill** `kSkillMarkdown`: the surface-verb sentence :8031, the `copy --pane X` paragraph
  :8079-8083 (says the verb does not touch the clipboard), the popup sentence ~:8126, the verb
  inventory :8270, the NOT list :8298 (contains `selection *` — comes out).
- **README.md**: the Clipboard bullet :62-68, "48 verbs" :69-70 (→ 52), the overlay `copy` bullet
  :152-156 ("the popup's `copy` is always `no selection`"), THE RULE :161-167.
- **qa/product.md**: helper table :57-59 (`Get-PaneSelection` → `session copy`), :75 ("No mark
  mode, no Select All, no drag-autoscroll"), :76-83 — the "No `selection.*` control verbs" bullet
  is **duplicated verbatim**; both copies go. **qa/selection.md** :9-11 says lite has no Select
  All. **qa/control-honesty.md** :223+ (the overlay case: the model for a case that discriminates
  which surface answered).
- **Tests**: `test/ui-lib.ps1` (`Start-Sandbox`, `Send-Ctl`, `Get-CtlResult`, `Get-PaneSelection`
  :244, `[LiteUi]::Drag/Click` — PostMessage into the sandbox's own hwnd); `test/control-honesty.ps1`
  (`Check`, `Skip`, `Send-Raw`, `Node`/`Wait-Node`, `Overlay`, the doctrine at :1-15: every refusal
  asserted twice, reply and world); `test/run-all.ps1` :17 (the suite list; `clipboard.ps1` is the
  model for a mouse-made selection + clipboard assertion, :171-201); `test/conformance.ps1` +
  `test/control-api.json` = agwinterm's `tests/conformance/control-api.json` byte for byte;
  `tools/check-contract.ps1` fails on any drift either way.
- **The contract has no `selection.*` steps** (52 steps; the only mention is `session.copy`'s
  note). So lite's copy is NOT edited in this batch (it would report drift and fail CI); the four
  steps are added canonically in agwinterm after this merges (Post-Completion), then `-Update`.
- **agwinterm's replies** (`Program.ControlHost.cs:759-792`), all `ok:true` bare strings:
  `all` → `selected all` | `empty`; `copy` → `copied N chars` | `no selection` | `nothing to copy`;
  `clear` → `cleared`; `finalize` → `finalized (copied)` | `finalized (empty)` |
  `finalized (copy-on-select off)`; every one also `no session` as an **ok** result (the four
  arms in `ControlServer.cs:305-308` skip the `RefusePrefix` unwrap) — lite does not copy that.
- **agwinterm's alt-screen rule** (`Program.Input.cs` `ClampSel` :723-751): `minLine = alt ? hist
  : 0`; `qa/selection.md` there has the case "Select All on the alt screen takes only the alt
  screen" (run `selection all` with a TUI up, read `session copy`: non-empty, no `MARKER-`).

### Vocabulary

- **surface verb** — THE RULE's list grows by four: `session type` / `write` / `output` / `text`
  / `copy` / `paste`, `surface cursor`, `session overlay`, **`selection all` / `copy` / `clear` /
  `finalize`**. Every copy of the list is updated together (the remap's exclusion list, the remap
  comment, the skill :8031, README :163-165, `qa/control-honesty.md`, the P5 plan's vocabulary
  bullet is history and stays).
- **the selection's owner** — the surface `g_sel.sess` names. A verb with a target reads or
  writes the selection only when `g_sel.isFor(target)`; `all` replaces the owner.

### lite-parity differences (for agwinterm `docs/lite-parity.md`, the docs PR after merge)

- **(a)** an unresolved target is refused `ok:false` (`session not found`, or the ambiguity
  sentence) as on every lite verb; agwinterm answers `ok:true` `no session` on these four — an
  agwinterm defect to fix there (follow-up issue; the contract steps then pin `ok:false`).
- **(b)** `selection finalize` never answers `finalized (copy-on-select off)`: lite's
  release-copies rule has no off switch (a `CopyOnSelect` knob is P10's, the configuration surface).
- **(c)** `selection all` on any popup (overlay, quick or scratch) is refused `the popup paints no selection`; agwinterm's
  covers take a selection. P7-lite paints one and lifts this.
- **(d)** `selection copy`'s clipboard write is posted to the UI thread; the reply counts the text
  posted. A caller reading the clipboard right after waits for the window's next message (the
  suites' 300 ms).
- **(e)** the alt-screen pin covers the VERB here; the wheel and the drag still reach main-screen
  history until P7-lite (qa/product.md's last bullet stands until then, narrowed).

The reply's N also differs on non-ASCII text: lite counts UTF-8 bytes, agwinterm UTF-16 code
units. This counting convention is detailed below and must accompany the five differences in
the follow-up parity documentation.

## Constraints

- Sandbox instance per `qa/product.md` (`--pipe`, throwaway profile, `--no-restore`); PostMessage
  into the sandbox's own hwnd only — never `SendInput`/`keybd_event`; `PrintWindow` for captures.
- The clipboard is system-wide: a test that writes it saves it first and restores it after (the
  same rule as `HKCU\Software\agliteterm`), and asserts on a marker string it planted.
- Every `g_sel` touch under `LockG`; no `SendMessage` from a pipe thread into the UI thread (a
  UI thread waiting on `g_lock` behind a pipe thread that holds it is the deadlock); post.
- Explicit `git add` paths; `.ralphex/` and `.revmux/` are never committed; commit trailers per
  the executor's session.
- Build only when no suite is running in the tree (`./build.ps1` overwrites the exe the suite is
  driving).

## Testing Strategy

- `test/control-honesty.ps1 -Strict` gains a **`selection.*`** section next to the `session copy`
  / overlay checks, every refusal asserted twice (reply + world via `session copy`, `Get-Clipboard`,
  `tree --json`): `all` → `selected all` and `session copy` returns every fixture line incl. one
  scrolled into history; `copy` → `copied N chars`, the clipboard holds exactly `session copy`'s
  previous text, `session copy` now `""` (cleared); `copy` again → `no selection`, clipboard
  unchanged; `clear` with nothing → `cleared`; `all` on A then `clear --target B` → `cleared` and A
  still selected; `finalize` → `finalized (copied)` with the highlight kept (`session copy`
  non-empty), then `clear`, `finalize` → `finalized (empty)`, clipboard unchanged; `all --target
  <overlay id>` → `overlay copy --pane X` returns the overlay's text and `session copy --target
  <shell id>` is `""`; `all --target active` with an overlay open selects in the overlay
  (`window state`/`overlay copy` see it), and after `overlay close`, in the shell; `all --target
  <popup id>` refused, popup `copy` still `no selection`; `all --target nonsense` → `ok:false`
  `session not found` and the existing selection untouched; the raw-JSON `Send-Raw` form of one
  verb (the decoder pinned without the client); the **alt screen**: a script that prints
  `MARKER-n` lines, enters the alt screen (`\e[?1049h`) and paints distinct text, then `selection
  all` + `session copy`: non-empty, no `MARKER-`; leave the alt screen → `session copy` is `""`
  (dropped by `syncSelection`); a blanked selection: `all` on a session whose alt screen is
  cleared (`\e[2J`) → `copy` answers `nothing to copy`, clipboard unchanged, highlight cleared;
  a second copy answers `no selection`. Reselect for blank finalize: it alone keeps the highlight.
- `qa/selection.md` gains the markdown case **Select All on the alt screen takes only the alt
  screen** (agwinterm's wording), and **`selection copy` reads what is highlighted** (a drag, then
  the verb, then `Get-Clipboard` equals the highlighted lines).
- `test/run-all.ps1 -Strict` green (the `log-focus-font` posted-click checks are a known flake
  under the parallel run — rerun alone).
- `tools/check-contract.ps1` stays green — the contract is not edited here.
- No unit test for the range (lite has no test host): the honesty alt-screen check IS the
  regression test for `minRow = alt ? historyCount : 0`; say so in the check's name.

## Progress Tracking

- [x] Task 1: the arms, the remap list, `session.copy`'s locked read
- [x] Task 2: the alt-screen range and the `pane` field
- [x] Task 3: honesty checks + qa cases
- [x] Task 4: docs — skill, README, qa/product.md, qa/selection.md
- [ ] Task 5: [Final] verify acceptance criteria

## Implementation Steps

### Task 1: the four arms

- Add `cmd != "selection.all" && cmd != "selection.copy" && cmd != "selection.clear" && cmd !=
  "selection.finalize"` to the remap's exclusion list at :8603-8604, and the four names to the
  remap comment's parenthetical list of surface verbs.
- Beside `session.copy` (:9548), one block per verb, every `g_sel` read or write under one
  `LockG hold`; the `!target` refusal first (`targetWhy.empty() ? "session not found" : targetWhy`,
  the neighbour's sentence). While there, put `session.copy`'s `g_sel.isFor(target)` read under
  the hold too (:9550 is the one unlocked touch of `g_sel` in the file; `selectionText()` takes
  the recursive lock again, which is fine).
- `selection.all`: `selectAllOf(Session* target)` (a static beside `copySelection`): under the
  hold, refuse `g_overlaySession`, `g_quickSession` and `g_scratchSession`; `emu_info`; `total = historyCount +
  rows`; `if (!target->emu || total == 0 || cols == 0) → "empty"`; `first = isAltScreen ?
  historyCount : 0`; `g_sel = { paneOf(target), target, false, first, 0, total - 1, cols,
  target->evicted, isAltScreen != 0 }`; `InvalidateRect(g_hwnd, nullptr, FALSE)` (safe from any
  thread); `"selected all"`.
- `selection.copy`: under the hold `syncSelection()`, `if (!g_sel.isFor(target)) → "no
  selection"`; `t = selectionText()`; content test → `"nothing to copy"` (clear highlight, leave clipboard);
  else post `HA_CLIP` with `new std::string(t)`; if accepted, `g_sel.clear()`, invalidate, reply
  `"copied " + t.size() + " chars"`. Factor the post into `postClipboardUtf8(std::string)` and
  make the reader-thread site :1960 call it. Failed enqueue frees the payload and refuses without clearing.
- `selection.clear`: under the hold `if (g_sel.isFor(target)) { g_sel.clear(); invalidate }`;
  `"cleared"`.
- `selection.finalize`: as `copy` without the clear: `"finalized (copied)"` / `"finalized (empty)"`
  (absent OR blank).
- `paneOf(Session*)`: the slot `p` whose displayed shell (`g_sessions[g_pane[p]]`) or its surface
  is the target; `0` when neither (Task 2 says why that is safe).

### Task 2: the alt-screen range and the `pane` field

- The range rule lives in ONE place — a comment on `selectAllOf` quoting agwinterm's `ClampSel`:
  on the main screen the selectable range starts at 0; on the alt screen at `historyCount`, because
  the history belongs to the other screen and the app's screen is what the user sees — and the
  clipboard must read the same cells as the highlight.
- **The `pane` field.** Paint tests `g_sel.pane == pane` besides `isFor(s)`; a session is shown in
  at most one slot, so `isFor(s)` alone identifies the pane and `pane` is a fix-up burden
  (`closeSplitSide` :2593 resets it on a promotion; a swap leaves it stale). Drop the `pane == pane`
  equality test from paint (:3948), while retaining `pane >= 0` to exclude popup paint calls,
  so a selection made by the verb on a session that later lands in slot 1
  is painted where the session is — otherwise it would be copyable and invisible, the invariant
  this batch imports. Keep `pane` for the drag's cross-pane rejection (:6628) and `has()`. Record
  the change in Technical Details; the P4 promotion fix-up stays to move an active drag's boundary.
- `hitTest` / `scrollOff` on the alt screen are NOT touched (P7-lite). Say so in the comment.

### Task 3: tests

- The honesty section per Testing Strategy, placed after the P5 overlay checks so `$ovt` / the
  overlay helpers are in scope; a fixture script printing `MARKER-1..MARKER-60` (more than the
  sandbox's rows, so at least one row is history) then a distinct `SELECT-ME` line; the alt-screen
  fixture via `[char]27 + '[?1049h'` etc. from a `New-ScriptFile`. Save `Get-Clipboard` at the
  start of the section, `Set-Clipboard` it back in the section's teardown (also on failure — the
  section is wrapped so the restore runs).
- Name each check by the rule it pins, e.g. `selection all on the alt screen takes the app's
  screen only (minRow = historyCount; revert it and MARKER- lines appear)`.
- `qa/selection.md`: the two markdown cases; `qa/product.md`: the helper table gains the four
  verbs.

### Task 4: docs

- Skill: :8031 the surface-verb sentence; :8079-8083 the contrast — `overlay copy` reads and
  does not touch the clipboard, `selection copy` writes it and clears the highlight; ~:8126 the
  popup sentence gains "and `selection all` on it is refused"; :8270 the inventory gains
  `agwintermctl selection all|copy|clear` (finalize is a testing hook, as in agwinterm's skill);
  :8298 `selection *` leaves the NOT list.
- README: the Clipboard bullet gains the API way (`selection all` / `copy` / `clear`; `copy`
  writes the clipboard and clears the highlight); "48 verbs" → "52 verbs"; :152-156 the popup
  sentence; :163-165 THE RULE's surface-verb list.
- qa/product.md: :75 becomes "No mark mode, no drag-autoscroll; Select All exists only as the
  `selection all` verb (no chord)"; both copies of the `selection.*` bullet replaced by one bullet
  stating (a)–(e); the last bullet narrowed to the wheel and the drag.
- qa/selection.md :9-11: lite now has Select All by verb; mark mode, drag-autoscroll and the
  `scrollback-lines = 0` case stay agwinterm's.
- This plan: a **What revmux round N found** record per round, in the P5 plan's shape; the
  differences list kept exact (the docs PR copies it).

### Task 5: [Final] Verify acceptance criteria

- `./build.ps1` clean; `test/control-honesty.ps1 -Strict` green; `test/run-all.ps1 -Strict` green;
  `tools/check-contract.ps1` green; every copy of the surface-verb list identical (grep
  `surface cursor` and `selection all` across `src/main.cpp README.md qa/*.md docs/plans/*.md`);
  `selection *` absent from the skill's NOT list; the clipboard and `HKCU\Software\agliteterm`
  restored after the suite (compare before/after).
- PR body: what each verb answers, the five differences, the honesty count, the alt-screen check
  named, screenshots optional (the highlight after `selection all` in a split, one pane).

**What revmux round 1 found** (`.revmux/tasks/p6-lite-selection/01-initial`, `dbad2b4`,
comprehensive, all four sources reported): **two code Majors**, one mechanism: the popup guard
only named the overlay while quick and scratch share `paintPopup`, and removing the pane equality
also removed the popup's `-1` sentinel. A live probe confirmed both other popup kinds answered
`selected all`. All three now refuse; main-pane paint still follows the surface through a swap,
while the negative sentinel suppresses popup highlights and selection-based cursor suppression.
Three Minors: the promotion comment now explains the still-live drag boundary, the popup comment
has its sentinel back, and mouse-up snapshots the dragged text under the same lock that ends the
drag, so a concurrent `selection all` on B cannot make A's release copy B. One pre-existing finding
was fixed in the same seam: paint now snapshots selection together with its viewport under the
emulator lock, and uses that snapshot for highlight and cursor.

The first strict honesty run passed all 27 new P6 checks but failed three existing P5 checks
after assuming a background popup had focus. The setup now posts `WM_SETFOCUS` to a PID-checked
sandbox popup before the close command, without taking the real foreground. Additional checks
cover quick/scratch refusal by id and active, popup-active refusal, wrong-owner copy/finalize,
and non-ASCII byte counts. PrintWindow captures confirmed the highlight moves with its shell
through a swap and disappears after clear; that case is now recorded in `qa/selection.md`.

**What revmux round 2 found** (`.revmux/tasks/p6-lite-selection/02-after-fix`, `8a04c01`,
final): no findings, both sources reported without degradation. The independent Claude Code
re-review confirmed the popup and locking fixes but caught a mistake in this plan: agwinterm's
`CopySelection(clear: true)` clears even a blank selection. Copy now follows that rule;
Finalize alone retains a blank selection. Tests reselect between those cases and explicitly
check that a second blank Copy answers `no selection`.

Both Copy and Finalize can return `ok:false` with
`the clipboard write could not be queued; selection unchanged` if the UI enqueue fails.
This preserves the selection for retry; queue refusal is source-reviewed, not fault-injected.

## Technical Details

- `Sel` gains nothing; `selection all` fills it the way `OnLButtonDown` :6599-6604 does (one
  hold, `epoch` and `alt` read in the same hold as the rows).
- The reply counts `t.size()` (bytes of UTF-8 after CRLF join and trimming); agwinterm counts
  UTF-16 code units of the same text. A difference only on non-ASCII text — say so in the
  README's sentence (`copied N chars` = the text `session copy` returns, N its length).
- Main-pane paint keys on `isFor(s)` after Task 2; `pane >= 0` preserves the popup sentinel.
  `g_sel.pane` remains the drag's field. Paint snapshots selection with the viewport under the
  same lock, and mouse-up snapshots the released text before another surface can replace it.
- `postClipboardUtf8` is the one cross-thread road to the clipboard (OSC 52 and `selection
  copy` / `finalize`); `setClipboardUtf8` stays UI-thread-only and says so.
- No event, no persistence, no `tree` field.

Execution notes: the clipboard helper frees its payload if `PostMessageW` refuses it; the verb
then refuses without clearing the selection. The mouse-move `active` test now shares its hold
with the update, and mouse-up relies on the locked extraction's content test instead of reading
`g_sel.has()` unlocked. The alt-screen test injects exact VT with `session.write` after real
fixture output establishes history, so no shell prompt races a screen switch or blanking.

## Post-Completion

- agwinterm: contract PR adding the four steps to `tests/conformance/control-api.json` (after
  both sides answer; shapes `"result": "string"`), header count updated; then lite
  `tools/check-contract.ps1 -Update`. Follow-up issue in agwinterm for difference (a) (`no session`
  as `ok:true`), fixed with the contract PR so the steps can pin `ok:false`.
- agwinterm `docs/lite-parity.md`: the "Selection — the sharpest gap" entry removed, the verb
  count 45 → 41, differences (a)–(e) recorded; the batch index's P6 row marked shipped, decision 2
  struck (already done for the answer).
- Release: lite 0.17.16 when Boris calls it (with P5, if #40 is still unreleased).
- **P7-lite** carries: the wheel/drag pin on the alt screen (`hitTest`, `paintPane`'s `off`,
  `scrollFocused`: `alt ? 0 : scrollOff`), drag autoscroll, double-/triple-click, the popup
  painting a selection (lifting difference (c)), mark mode.
