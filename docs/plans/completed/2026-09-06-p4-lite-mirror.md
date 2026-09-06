# P4-lite — splits get their full shape, the agliteterm half

The agliteterm half of batch **P4** of the parity programme (agwinterm
`docs/plans/2026-09-03-parity-batches.md`). agwinterm shipped its half as PR #238 on 2026-09-06
(plan: agwinterm `docs/plans/completed/2026-09-06-p4-splits.md`, with FOUR revmux rounds of
findings — read it first, the vocabulary section and the four round notes above all; every rule
below was made there and lite copies it, it does not re-decide it), followed by the contract PR
#240. `tools/check-contract.ps1` is red on `main` right now for exactly the three steps and two
refusals that PR adds; that is the gate, and it goes green when this merges.

**The swap is in** (Boris, 2026-09-06: "swap included") — the batch index and `lite-parity.md`
left it to this plan, and the answer is implement, not defer. The `session swap` step is NOT in the
contract yet (agwinterm deliberately left it out until lite decided); it is added to BOTH copies in
the sibling contract PRs after this merges, the way #240 followed #238.

Four verbs and one rule, all on one subsystem — a session's two panes. In lite a pane IS a
`Session`: a split is one extra `Session` marked `hidden`, named by its owner's `splitId`, drawn
beside it by a hard 50/50 halving (`src/main.cpp:1463-1473`). Nothing in that model changes; this
batch adds an axis, an order, a way to close either side, and the words the tree and the replies
use for them. The one representational addition is `Session::paneId` (below): it is what lets the
session id stay on the session when its own shell is the one that closes.

## The vocabulary, fixed before anything is written

Copied, not re-decided, from the agwinterm plan:

- **`vertical` = left/right panes** — lite's only layout today, and the default of a session never
  split; **`horizontal` = top/bottom panes.** The axis names the ARRANGEMENT, never the divider.
  Case-sensitive, the wire spelling; `Horizontal` or `h` is refused naming both words. Stated once in
  the code (a comment beside `Session::axis`), once in the skill, once in `docs/state-file.md`; the
  stale header comment at `src/main.cpp:6` ("vertical split") happens to already use agterm's word.
- **A slot is a position, an id is a shell.** Slot 0 is the left/top box, slot 1 the right/bottom
  box. `primary` / `left` / `top` name slot 0, `split` / `right` / `bottom` name slot 1 (the
  left/right pair exists on a vertical split only, top/bottom on a horizontal one; the wrong pair
  is refused naming the axis). Today slot 0 is always the owner's shell and slot 1 the hidden
  shell; **a swap exchanges the slots and nothing else**.
- **A swap moves panes, never ids.** An agent holding a pane id keeps reaching the same shell after
  a swap. Reply `{"session","paneIds":[slot 0, slot 1],"focusedPane","axis"}` — the session's
  split block after the swap.
- **THE SESSION-ID RULE, by condition** (agwinterm `ISessionHost.SplitClose`, quoted here in
  lite's terms and nowhere else in full — every other site points here): a session id names the
  session's own shell (the owner's — pane 0 of a fresh session; after a swap, whichever slot it sits
  in) while that shell exists; WHENEVER that shell is the one that closes — whatever closed it:
  `split close` on it, the close chord on it while focused, any slot-1 close after a swap (`split
  off`, `toggle`, a bare `session split`, the Split / Unsplit key, menu and palette rows — slot 1
  is the owner then), or its process exiting — the surviving shell becomes the session (it keeps
  the session id, name, workspace, flag, context and sidebar row; it keeps ITS OWN pane id) and the
  session id names it. The one thing a promotion does not survive is a KILL-and-relaunch: the `D`
  line records shells (`paneId`), the survivor is adopted by its shell's id and comes back under
  it (revmux r1).
  A later `split on` mints a fresh pane id for the new hidden shell. **Lite's one difference from
  agwinterm's sentence**: agwinterm's session id names the FOCUSED pane while no pane carries it;
  lite has no per-session pane resolution — a session id always names the session's own shell, the
  split's shell is reached only by its own id. Recorded in `lite-parity.md`, not silently.
- **`off` destroys the split shell** (agterm hides it) — unchanged, already recorded. `off` closes
  SLOT 1: before a swap the hidden shell (today's behaviour exactly), after a swap the owner's shell
  (a promotion). `session split close --target <id>` is the same destruction with a target — its
  new capability is closing EITHER side, which no verb and no key can do today
  (`closeSessionAt:2236` kills the split with its owner; `closeFocused:2314` unsplits when the
  split is focused and closes the WHOLE session when the owner is).

## Overview

- **`session split [on|off|toggle] [--axis vertical|horizontal] [--target <id>]` — replies with a
  PANE ID, a bare string.** `on` = the slot-1 pane's id, ALSO when the session was already split
  (agwinterm: "by position, not history" — after a swap that is the owner's pane id); `off` = the
  survivor's id, also when already single; `toggle` = whichever it produced. Today (`:7911-7947`)
  `on` already answers the id, `off` answers the literal `"ok"` and posts `IDM_SPLIT` so nothing is
  available to return, and `--target` is ignored (always `g_pane[0]`). Now: the target is honoured
  (a session id, either pane's id, a prefix, a name → the session that shell belongs to; a cover —
  quick / scratch / overlay — is refused with nothing split, the `restore.capture` wording); a
  non-displayed session can be split (the hidden shell exists and shows when the session is
  selected; focus does not move — #230); the unsplit is done inline under the same rules as the
  `on` arm so the reply is read off state that exists. `--axis` on an already-split session
  re-orients it live; omitted keeps the current one; a session never split defaults to vertical.
- **An axis.** `Session::axis` on the owner (`bool horizontal`, spelled as the two words at the
  wire), consulted in ONE place for geometry (`paneRect`) and one for paint (the divider,
  `paint:3723-3730`, the only hard-coded vertical outside `paneRect`). `hitTest`, `paneGridSize`,
  `syncPaneSizes`, `InvalidateCaret` follow for free through `paneRect`. Survives restore as the
  **`L` line** (Technical Details). Reported by `tree --json` inside the split block — always when
  split, like `focusedPane`.
- **The tree gains the split block.** A split session's node emits `paneCount: 2`,
  `paneIds: [slot 0 id, slot 1 id]`, `focusedPane: <slot>` and `axis` — agwinterm's keys, its
  spellings, present exactly when the session is split (a single session emits none of them, as
  agwinterm's does not). The hidden shell stays skipped as a node (`:7282`). `capturedCommands`
  stays keyed by pane id, which is what it was — the comment at `:7309-7314` that promised
  `paneIds` "in P9" is rewritten: it arrived here.
- **`session split close [--target <id>]`** — close the targeted pane, EITHER side; the survivor
  takes the whole width or height and the focus. No target / `active` = the focused pane of the
  displayed session (what the close chord closes). A session id = the session's own shell (the
  rule above). Reply: the survivor's pane id. Refused, each with nothing closed: an unknown
  target; a cover; a ONE-PANE session naming `session close` (a `split close` that closed the
  session would be the silent-success class one verb over). agwinterm's refusal sentences,
  verbatim (`SplitCloseReply.cs`).
- **`session swap [--target <id>]`** — exchange the slots: `swapped = !swapped` on the owner,
  focus follows the pane (the shell being typed into is still the one being typed into, on the
  other side — in lite that is `g_focus` unchanged, since `g_focus` indexes owner/split, not
  slots), axis kept, ids kept, name/context/flag/slots/`K` slots untouched. Reply the object above.
  Refused with nothing moved: an unknown target; a cover; a one-pane session ("nothing to
  exchange; `session split on` makes a split"). agwinterm's sentences (`SwapReply.cs`).
- **`session focus [primary|split|left|right|top|bottom|other]`** (new verb; agwinterm's
  `session.focus`, active session only, default `other`). Refused: a one-pane session ("session is
  not split (one pane); nothing to focus"); a word outside the list; the pair that does not exist
  on the session's axis, naming the axis (agwinterm `SplitAxes.TryFocusIndex`, its sentences). The
  keybindings `KB_FOCUSL` / `KB_FOCUSR` (`:4371-4372`) and the palette rows become slot-based
  ("Focus Left Pane" = slot 0, which after a swap is the split shell) and axis-aware in name
  (Left/Right on a vertical split, Top/Bottom on a horizontal one — or keep the two rows and
  document that they mean slot 0/1; choose, and say so in the README).
- **Every structural change emits `tree`**: split, unsplit, close of either side, swap, re-orient.
  The unsplit path (`toggleSplit:2334-2344`) emits nothing today — an existing hole, closed here.

## Context (from discovery)

- `struct Session` `src/main.cpp:340-409`: `id`, `name`, `ws`, `splitId` (`:357-361`, "only a
  visible session owns one; the shell it names is hidden"), `hidden` (`:365`, split shell OR
  quick / scratch / overlay cover — the discriminator is "some visible session's `splitId` names
  it", `:7836-7841`), `flagged`, `context`, `capturedCmd`, `app/cwd/args`, `childPid`, `exited`.
  No axis, no ratio, no order, no per-session focus (`:7826-7827` says so).
- Window state `:1052-1053`: `g_pane[2]` = session INDICES per pane (`g_pane[1] = -1` = no split),
  `g_focus` = 0/1. `g_pane[0]` must index a VISIBLE session — `selectPrimary` `:1973`, `refreshTree`
  `:4537`, `saveSessionState`, `resolveSplitForPrimary` `:1956` all assume it. That is why a swap is
  a flag read inside `paneRect`, never `std::swap(g_pane[0], g_pane[1])`.
- `paneRect` `:1463-1473` — the one geometry choke point; `paint` `:3717-3730` loops both panes
  and draws the divider `{pr0.right, top, pr0.right+2, bottom}`; `hitTest` `:3821-3842`;
  `InvalidateCaret` `:6174`; `syncPaneSizes` `:1699-1719`; `paneGridSize` `:1481`.
- `toggleSplit` `:2319-2349` (UI path: spawns, `hidden = true`, `splitId`, `g_pane[1]`, `g_focus =
  1`; unsplit inline: kill + erase + fix `g_pane[0]`, NO event); `closeSessionAt` `:2230-2298`
  (owner→split cascade `:2236-2243`; split→owner `splitId` clear `:2247`; `ClosedSpec` push unless
  hidden `:2248-2251`; events `:2260-2262`; `g_pane` fix-up `:2263-2266`; `g_userEmptied`
  `:2269-2287`); `closeFocused` `:2314-2317`; `session.close` `:7591-7604` (`g_pane[1] == i2 →
  toggleSplit()` else `closeSessionAt`). Keys are ALL unbound by default (`:930-951`, HKCU
  `Key_Close/Key_Split/Key_FocusL/Key_FocusR`); `IDM_CLOSE` / `IDM_SPLIT` from the menu.
- A shell's exit only sets `exited = true` (`:1885`) — a split side that exits stays on screen as
  "(exited)"; agwinterm collapses to the survivor (`OnPaneProcessExited`, agterm #121).
- `resolveTarget` `:6802-6822`: empty/`active` → `focusedSession()` (may be the hidden shell); exact
  id; id prefix ≥ 4; case-insensitive NAME among non-hidden; ambiguity refused. Resolved ONCE at
  `:7461-7462`; every write site re-checks `indexOfSession(target) < 0` under `LockG` (`:7778`,
  `:7833` — the #21 class). `session.context` `:7787` and `restore.capture` `:7835-7841` refuse a
  hidden target explicitly.
- Ids: minted in `newSession` `:1980-1985` (`<prefix>-<seq>`); the shell env sets
  `AGWINTERM_SESSION_ID` AND `AGWINTERM_PANE_ID` to the same value (`:2050-2051`, re-stamped on
  the id-collision retry inside `newSession` `:2066-2067` — never on adoption: an adopted shell is
  a running process whose environment is never rewritten; the skill says so `:6944-6947`). Ids are NOT stable across a graceful
  restart (`test/restore-matrix.ps1:117-121`); the `P` line carries no id (`:8414`); split shells
  are recreated, never adopted (`:8691-8710`).
- `tree` `:7270-7338`: hidden skipped `:7282`; `active` = `g_pane[g_focus] == i2` (`:7288` — with
  the split focused NO node reads active today; fix: a node is active when the displayed session is
  it, whichever of its panes has focus); presence convention `:7303-7308`.
- State file: writer `:2832-2923` (`S` first, hidden skipped `:2855`, `savedOrder` `:2852`; `P`
  per owner `:2895-2911`, `P <ownerIdx> <app> <cwd> <args...>` — the tail is variable-length;
  emission order `F D C P K A` `:2918-2923`); parser `:8382-8436` (`P` `:8414`; unknown line types
  ignored `:8404`); the wholesale count guard `:8446-8450` cloned for `C` `:8453` and `K` `:8474`,
  per-line range drops `:8460/:8479`; `struct SplitSpec` `:8359`; restore split loop
  `:8691-8710`, `K` re-attach `:8718-8728`, final `g_pane[0] = firstIdx; g_focus = 0;
  resolveSplitForPrimary()` `:8743-8747`. `docs/state-file.md:24` (`P` row), `:47-70` (rules).
- Sidebar `refreshTree` `:4517+`: one row per visible session (`:4558`); `focusIdx = g_pane[g_focus]`
  `:4537` — with the split focused NO row highlights (fix alongside `active`: highlight the
  displayed session's row whichever pane has focus); `toggleFlag` `:5904` refuses hidden; tree
  click → `selectPrimary(i)` `:6548`.
- Events `emitEvent` `:6716-6722` (`session` created/closed, `status`, `tree`); `newSession` emits
  created + tree `:2155-2156`; `closeSessionAt` emits closed + tree `:2260-2262`; the unsplit path
  and `session.select` emit nothing.
- Skill `kSkillMarkdown` `:6930-7226` (splits section `:7024-7046`; verb index `:7188-7196`);
  `README.md:50`, `:66-115` (the verb count at `:67`), `:148-205` (state file), `:232-245`;
  `docs/state-file.md`; `qa/panes.md` (three cases: follows the session / closes with it / survives
  a restart); `qa/product.md` sandbox rules.
- Tests: `test/control-api.json` (mirrored, refreshed ONLY by `tools/check-contract.ps1 -Update`,
  never hand-edited); `test/conformance.ps1` (probes `:60-70`, `Needs-NewClient` `:81-90`, capture
  `:168`, the `checked + skipped == steps` guard `:220-223`); `test/control-honesty.ps1` (probes
  `:40-61`, banner + `Check` blocks; split usage to copy `:1109-1178`, hidden-target refusal
  `:1273-1284`, the `restore.capture` block `:1332-1484`); `test/restore-matrix.ps1` (`Cell`
  `:153`, `Seeded` `:239`, `Signature` `:116-133`; split cells `:555-595`, `:1004-1027`, seeded
  P-guard cells `:1069-1090`); `test/run-all.ps1` order.
- Versions: `installer/agliteterm.iss:6` `AppVersion "0.17.14"` is the single source; `ping`
  answers it. CI: `.github/workflows/ci.yml:46` `check-contract` between build and suites; the
  suites run `-Strict` with `AGWINTERMCTL=<workspace>\bin\agwintermctl.exe` — the RELEASED CLI, so
  every P4 check SKIPs (= fails under `-Strict`) until agwinterm tags the release that carries
  #238 + #240 (0.17.13 — Boris tags). Red by design until then, one email per push; same as
  P3-lite before 0.17.12.

## Constraints

- **Do not hand-edit `test/control-api.json`.** Refresh it with `tools/check-contract.ps1 -Update`
  once; the swap step lands in the sibling contract PRs (both repos) after this merges.
- **Every `session split` reply is a bare string (a pane id); `swap` is the one object.** The
  shipped `split off` conformance step (`"result":"string"`) is untouched.
- **Additive only, one new line type `L`**, written only when a split session's layout differs from
  the default (horizontal, or swapped, or both) so a vertical unswapped tree writes the exact
  bytes 0.17.14 writes. Unknown line types are ignored by 0.17.14 (`docs/state-file.md:47`), so
  a downgrade loses the layout, not the split (the `P` line is untouched). Validated on load: the
  axis is exactly `vertical` / `horizontal`, anything else → vertical; the order is exactly `0` /
  `1`, anything else → 0; an `L` for an owner with no `P` line is dropped (named in the log); the
  wholesale count guard cloned once more.
- **Pane ids never move** — by a split, a close, a swap, or a promotion. `Session::paneId` is set
  once in `attachSession` (= `id`; `newSession` reaches it by create-then-attach, restore's adoption calls it directly — a failed-spec placeholder has neither) and never written again; a promotion writes `id`, never `paneId`.
  Sites that report a PANE (the split reply, `restore.capture`'s `panes[].pane`, `capturedCommands`
  keys, `paneIds`, the events that name a pane) use `paneId`; sites that report a SESSION (the tree
  node's `id`, `session` in replies, `session closed` events) use `id`. `resolveTarget` matches
  exact `paneId` too (after exact `id`, before the prefixes; prefixes on both).
- **A promotion is not a session close**: no `ClosedSpec` push (the session did not close — undo
  would resurrect a session that is still there), no `session closed` event (the session is
  there), a `tree` event (the node lost its split block). The owner's shell is killed the way the
  unsplit path kills the split shell.
- **The `K` line stays by ROLE, as today**: field 2 is the owner's shell, field 3 the split shell's,
  whatever the order on screen (the `L` line carries the order). Say so in `docs/state-file.md`. A promotion moves the survivor's `capturedCmd` with its
  object (it is the shell's), so the promoted session's `K` field 2 is the survivor's slot.
- **Refusals leave the world untouched**; a target is resolved once, and every write re-checks
  `indexOfSession` under `LockG` (#21). A verb on a non-displayed session must not move focus or
  selection (#230). Nothing that runs on the control-pipe thread writes `g_focus` without the
  `InvalidateRect` + `WM_APP_REFRESHTREE` pair `session.status` uses (`:7587-7588`); the split /
  close / promotion themselves run on the UI thread the way the `on` arm does today (`:7919-7920`
  explains the pattern) — copy it, do not post-and-return.
- **Refusal sentences are agwinterm's, verbatim**: `SplitAxes.Refusal` (axis), `SplitAxes.OpRefusal`
  (op), `SplitAxes.TryFocusIndex` (focus), `SplitAxes.NotSplit`, `SplitCloseReply.*`, `SwapReply.*`
  — the honesty suite greps for phrases and the contract's error steps pass on any `ok:false`, so
  the wording is for the human reading two products, not for the machine; still, one spelling.
- **No ABI change, no pty-host protocol change** (`tools/check-abi.ps1`).
- **HKCU\Software\agliteterm is shared with the user's real app** — any test that writes it
  restores it (ui-lib's rule). Sandbox rules of `qa/product.md` in full: `--pipe`, throwaway
  profile, `--no-restore` never against real data, `PrintWindow` never `CopyFromScreen`, never
  `keybd_event` / `SendInput` — PostMessage to the app's own handles.

## Testing Strategy

- **Conformance** — `tools/check-contract.ps1 -Update`, then `test/conformance.ps1 -Strict`
  passes every step and refusal against a P4 `agwintermctl` (the dev build at agwinterm
  `src/Agwinterm.Ctl/bin/Release/net10.0-windows/agwintermctl.exe`, set `AGWINTERMCTL`). A third
  client probe `$cliHasP4` (a post-#238 client refuses `session swap <positional>` on its own side
  with "Nothing sent" before any pipe; a 0.17.12 client says `unknown` — pick the shape that
  distinguishes them and never opens a pipe) SKIPs `split --axis`, `split close`, `swap`, `focus`
  on an older client, the `Needs-NewClient` way. The `checked + skipped == steps` guard still holds.
- **Honesty** — a `# --- P4: splits ---` block in `test/control-honesty.ps1`, guarded by
  `$cliHasP4`: `split on --axis horizontal` → both panes' `rows` in the tree are about half the
  single-pane rows and `cols` are the full width (the axis is provable from the grid, no capture);
  `--axis diagonal` refused, tree unchanged; `on` when split answers slot 1's id and changes
  nothing; `swap` → `paneIds` reversed, `focusedPane` follows, `cols/rows` per id unchanged, and
  `session type --target <id>` + `session text --target <id>` proves each id still reaches the
  same shell (a marker typed before the swap is read back after it under the same id); `swap` on a
  single session refused; `split close --target <owner's id>` → the session's node keeps its id,
  `paneIds` gone, the survivor answers `session text` under BOTH the session id and its own pane
  id, `session closed` NOT in `events`, `tree` is; `split close --target <split's id>` symmetric;
  `split close` on a single session refused naming `session close`; `focus` — each word, the wrong
  pair refused naming the axis, one-pane refused; `session split off` after a swap closes the
  owner's shell and the session keeps its id; the close chord on the focused pane of a split
  closes that pane only (PostMessage of the bound key to the app window — bind it in the sandbox
  profile's HKCU for the test and restore); a split side whose shell exits (`exit` typed into it)
  collapses to the survivor within the settle; every one of those emits `tree`.
- **Restore matrix** — `Cell` cells `axis-graceful`, `axis-killed` (the killed one proves the `L`
  line was checkpointed at write time), `swap-killed` (order and the `K` slots survive by role);
  `Seeded` cells: an `L` with a bad axis word restores vertical; an `L` for an owner without a `P`
  drops with a log line; an `L` with the count mismatch is refused wholesale with the guard's
  sentence; a vertical unswapped split writes NO `L` line (byte-exact against the P3-lite fixture).
- **Migration / downgrade** — nothing to run: unknown line types are ignored; say so in the
  `docs/state-file.md` row.
- **QA** — `qa/panes.md` gains: a horizontal split stacks (`PrintWindow`, the divider is a
  horizontal hairline at half height); `swap` exchanges contents, not geometry (two captures, the
  divider position identical, the focused-pane marker on the other side); a promotion keeps the
  sidebar row (name, flag, context) and the tree id.
- Each task's checks pass before the next task starts; `test/run-all.ps1 -Strict` green with the
  dev CLI before the PR.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope

## Implementation Steps

### Task 1: the two fields, the slot map, and `session split` that honours its target
- [x] `Session::paneId` (set in `attachSession` beside `id`, never written again), `Session::horizontal`
      (bool; the two words at the wire through two helpers `axisWord(const Session*)` /
      `parseAxis(const std::string&, bool* out)`), `Session::swapped` (bool). A comment beside
      `horizontal` states the vocabulary once (the sentence in this plan's vocabulary section).
- [x] `slotOf(pane)` / `paneOfSlot(slot)` on the displayed owner: `swapped ? 1 - x : x`. `paneRect`
      takes a PANE (owner = 0, split = 1) as today and computes the rect of its SLOT on the owner's
      axis; the divider in `paint` is drawn on the axis; `hitTest` maps a point to the pane in that
      slot. Everything else follows through `paneRect`.
- [x] `session split`: resolve `--target` (a hidden shell → its owner via the `splitId` walk; a
      cover refused with the `restore.capture` wording; unknown refused); `--axis` parsed before
      anything happens (refused naming both words, nothing split); `op` validated (`on|off|toggle`
      exact — an unknown op is refused, not a toggle, agwinterm's `OpRefusal` sentence); `on` on a
      split session with `--axis` re-orients live; the unsplit runs inline on the UI thread through
      the Task 2 primitive and answers the survivor's `paneId`; `on` answers slot 1's `paneId`.
- [x] `tree`: the split block (`paneCount`, `paneIds` in slot order, `focusedPane` as a slot,
      `axis`), `active` and the sidebar highlight fixed for a focused split; `session closed` /
      `tree` events as the constraints say.
- [x] `session focus` (new verb) + the two keybindings / palette rows slot-based.
      ➕ Task 1 notes: the two rows are KEPT (Key_FocusL / Key_FocusR unchanged, so bindings survive),
      relabelled "Focus Left / Top Pane" (slot 0) and "Focus Right / Bottom Pane" (slot 1) — named
      for both axes rather than relabelled live; the README sentence lands with Task 5. The unsplit
      is `unsplitSession(owner)` (a `tree` event, no `ClosedSpec`, no `session closed`), which Task 2
      folds into `closeSplitSide`. The honesty block `-- P4: splits --` and the `$cliHasP4` probe
      (`session swap x` → "Nothing sent") are in; Tasks 2/3/5 extend the block.

### Task 2: one primitive closes either side
- [x] `closeSplitSide(Session* owner, bool closeOwner)` on the UI thread: `closeOwner == false` is
      today's unsplit (`toggleSplit`'s second half, moved here, now with a `tree` event);
      `closeOwner == true` is the promotion — the survivor object takes `id`, `name`, `ws`,
      `flagged`, `context`, `horizontal`, the owner's position in `g_sessions` (exchange the two
      pointers so the sidebar order and `g_pane[0]` are unchanged), `hidden = false`,
      `swapped = false`, `splitId` cleared; its `paneId` and `capturedCmd` stay; the owner's object
      is killed and erased the way the split shell is today (no `ClosedSpec`, no `session closed`);
      `g_pane[1] = -1`, `g_focus = 0`, `syncPaneSizes`, invalidate, `WM_APP_REFRESHTREE`, save,
      `emitEvent("tree")`.
- [x] Route through it: `toggleSplit`'s unsplit (closes SLOT 1); `session split off`; `closeFocused`
      (the focused PANE, either side — a one-pane session still closes the session); `session.close`
      on the split shell's id (unchanged meaning: that shell); a split side's process exit (posted
      to the UI thread; `exited` on a one-pane session stays visible as today).
- [x] `session split close [--target]`: resolution per the vocabulary section; the three refusals
      with agwinterm's sentences; reply the survivor's `paneId`.
      ➕ Task 2 notes: the primitive runs INLINE on whichever thread calls it (the control-pipe
      thread for the verbs, the UI thread for the keys, the menu and a shell's exit), the way
      `closeSessionAt` and the `on` arm do — "on the UI thread" in the checkbox meant "not
      post-and-return", and it is not. Everything structural (the field moves, the pointer
      exchange, the erase, the `g_pane` fix-up, the `tree` event) happens under ONE hold of
      `g_lock` BEFORE the victim's shell is killed, so the exit its reader then reports finds a
      pointer that is no longer listed. The save is `refreshTree`'s (posted `WM_APP_REFRESHTREE`),
      as for every other structural change. Two consequences the plan did not spell out: (1) the
      pty-host knows a SHELL by its pane id, so the resize and kill requests now key on `paneId`
      (before this they keyed on `id`, which after a promotion names another shell); (2) a shell's
      exit is reported to the UI thread by a new `WM_APP_PANEEXIT` (lParam = the `Session*`),
      judged against the list under `g_lock` — a one-pane session's exit still shows as
      "(exited)". The honesty block covers every route: the three refusals, the promotion under
      both ids, `split on` after it (`paneIds` = [survivor, new]), the symmetric close, no-target
      on either focused slot, the close chord on either side (Key_Close seeded to Ctrl+Shift+W in
      HKCU before the sandbox launches, restored after), both sides' shells exiting, `session
      close` on the split shell's id, and a promotion off-screen by name (#230).
      ➕ Harness: `test/restore-matrix.ps1` now scrubs `AGWINTERM_SESSION_ID` / `AGWINTERM_PANE_ID` /
      `AGWINTERM_PIPE` at the top the way conformance does — run from inside an agwinterm pane, its
      untargeted `session split on` calls aimed at the developer's own pane id and the
      `capture-split` cell failed with "session not found" (the `split-with-session` cell's split
      silently failed the same way and its assertion never noticed). All twelve suites green under
      `-Strict` with the P4 dev CLI after the fix.

### Task 3: `session swap`
- [x] `swapped = !swapped` on the owner under the UI-thread pattern; reply
      `{"session","paneIds","focusedPane","axis"}` read back after the flip; the refusals.
- [x] `focus` words and `on`-when-split follow slots (they do by construction — add the checks).
      ➕ Task 3 notes: the flip is one field write under `g_lock`, with the `tree` event and the reply
      read back under the same hold (`splitBlockFields`, now shared with the tree's node so the two
      cannot disagree); the relayout (`syncPaneSizes`, only when displayed) and the invalidate run
      outside it, `closeSplitSide`'s order. `g_focus` is untouched — it indexes owner/split, so the
      focus follows the pane with no code. Resolution and the four refusals are `split close`'s shape
      with `SwapReply.cs`'s sentences. The honesty block proves a swap moves panes, never ids, with
      markers typed under each id before the swap and read back under the same id after it; every
      focus word by slot on a swapped session; `split on` when split answering the session's own
      pane id after a swap; no-target `split close` closing the focused split shell in slot 0; `split
      off` after a swap promoting; a swap by name off-screen (#230). One thing the checks had to
      learn: after Task 2's promotions the session id names a shell whose pane id is not the session
      id, so `paneIds` is compared against the pane id read off the tree, not `$aid` — the rule,
      demonstrated by the suite's own history. The `L` line (Task 4) is what makes the order survive
      a restart; until then a swap is in memory and in the tree only.

### Task 4: the `L` line
- [x] Writer: after the `P` lines, before `K`, `L\t<ownerIdx>\t<axis>\t<0|1>` for each split
      owner whose layout is not vertical-unswapped. Parser: `struct LayoutSpec`, the count guard,
      the no-`P` drop, the two validations. Restore: apply after the split loop. `docs/state-file.md`:
      the row, the by-role note on `K`, the downgrade sentence; `README.md` state-file section.
- [x] `test/restore-matrix.ps1` cells (Testing Strategy).
      ➕ Task 4 notes: the two validations are per FIELD and per line, done where the line is read
      (a bad axis word restores vertical, a bad order digit restores 0, each named in the log with
      the offending word) — a bad field loses that field, never the line and never the split. The
      no-`P` drop is the parser's (it sees the whole P set); the restore side has its own drop for a
      `P` line whose shell would not start ("restore: layout for session 'x' dropped - its split was
      not restored"), so a layout never lands on a lone session where the next `split on` would
      silently pick it up. The wholesale guard is the SAME comparison as P's, so a refused P set
      takes the L set with it. The `L` is written only when the split shell exists (the layout
      describes the pair); `horizontal` on a lone session stays in memory for its next `split on`
      but is not persisted. The matrix's `Signature` now carries the split block as `%axis:order`
      (order derived from "is paneIds[0] the session's id", because ids are fresh after a graceful
      restart — the same reason K is compared by value); the pre-existing `capture-split` cell's
      regex absorbed it unchanged. Nine cells: `axis-graceful`, `axis-killed` (the `L` was
      checkpointed by the save the split itself triggered), `swap-killed` (order 1 AND the `K`
      slots by role, `^cmd0;cmd1` unchanged around `%vertical:1`), and seeded `layout-bad-words`,
      `layout-no-p`, `layout-stray-index`, `layout-count-mismatch`, `layout-split-failed`,
      `layout-default-no-l` (the second run's file has exactly the P3 line-type shape `V1 W S D P
      A` — the shape, not the bytes, because the D ids and live cwd differ run to run). All twelve
      suites green under `-Strict` with the P4 dev CLI.

### Task 5: docs, trackers, tests
- [x] Skill: the splits section rewritten around the four verbs, the vocabulary, the session-id
      rule in full (quoted from this plan), the verb index; `README.md` (verb count, the Scriptable
      bullet, the keys); `qa/panes.md`; agwinterm `docs/lite-parity.md` "Splits as sessions"
      paragraph rewritten (swap implemented; the one sentence lite's session-id rule differs by;
      `restore`/`active`/promotion notes) — in the agwinterm repo, a docs PR after this merges
      (drafted in the notes below; not committed here — the other repo, after the merge).
- [x] `tools/check-contract.ps1 -Update`; conformance probe; the honesty block; `run-all -Strict`.
      ➕ Task 5 notes: the skill's "A second pane" section is now the vocabulary paragraph, the
      session-id rule quoted in full with lite's one difference, the four verbs with every refusal
      class, the events rule and the two slot-based keys; `AGWINTERM_PANE_ID` is explained as
      parting from the session id after a promotion; `restore capture`'s "left/right pane" wording
      is gone (keyed by `paneIds`); the verb index lists `split [on|off|toggle|close]|swap|focus`.
      README: 48 verbs (the dispatcher's `cmd ==` set, 45 + `session.focus`, `session.split.close`,
      `session.swap`), the Terminals bullet names the axes, the keys sentence says the two focus
      rows are slot 0 / slot 1 for both axes, the Scriptable bullet carries the P4 paragraph, the
      Tests paragraph names the #238 probe. `qa/panes.md`: the intro carries the words, plus the
      three cases (a horizontal split stacks and re-orients live; a swap exchanges contents, not
      geometry, and the ids keep reaching their shells; a promotion keeps the sidebar row and the
      tree id, with `tree` and no `session closed`). Contract: `-Update` brought the two P4 steps
      (`split on --axis horizontal --target {beta}` capturing `{pane}`, `split close --target
      {pane}`), the `off` note and the two refusals; `check-contract` is green. Conformance: the
      `$cliHasP4` probe (`session swap x` → "Nothing sent") and a `Needs-NewClient` rule that skips
      `split` with `--axis` or `close`, `swap` and `focus` on a pre-#238 client — that client drops
      `--axis` on the floor, so the `diagonal` refusal would PASS as a plain split and the
      horizontal step would split vertical; the `{pane}`-carrying close step skips with them. All
      P4 steps and refusals pass under `-Strict` with the dev CLI, and SKIP (not fail) with the
      released 0.17.10 CLI in `bin/`. The honesty block was complete after Tasks 1–3 (every item of
      the Testing Strategy list has a check); nothing to add. `run-all -Strict` green, twelve suites.
      ➕ The `lite-parity.md` "Splits as sessions" paragraph, for the agwinterm docs PR:
      "lite models a split as a hidden session; agwinterm models panes inside a session. Behaviour
      matches — a split belongs to its session, closes with it, restores with it, axis and order
      included (an `L` line beside the `P`) — and the internal shape stays different. P4-lite
      implemented `session swap` after all: the hidden session is drawn in the owner's other slot,
      so a swap is one flag read where the two panes are laid out and hit-tested; no tree identity
      moves, no id moves, the `K` line stays by role. `session split close` on the session's own
      shell promotes the hidden session's object into the session's place (same id, name,
      workspace, flag, context, sidebar row; its own pane id kept — `Session::paneId`, set once and
      never written), with a `tree` event and no `session closed` — agwinterm's `[B]` picture. The
      one sentence the session-id rule differs by: agwinterm's session id names the FOCUSED pane
      while no pane carries it; lite's always names the session's own shell, and the split's shell
      is reached only by its own id (no per-session pane resolution). `session close <split
      shell's id>` is a pre-P4 divergence in lite's favour: it closes that shell (an unsplit) where
      agwinterm answers `session not found` for a pane id. `tree`: a lite node is `active` when the
      displayed session is it, whichever pane has focus; the split's shell has no node. Restore:
      split shells are recreated, never adopted, ids are fresh after a graceful restart, and the
      `L` line puts the axis and order back onto the recreated pair. A split side whose shell
      exits collapses to the survivor in both products; a one-pane session's exit stays on screen
      as `(exited)` in lite."

### Task 6: [Final] Verify acceptance criteria
- [x] `test/run-all.ps1 -Strict` green with `AGWINTERMCTL` = the P4 dev CLI; `check-contract` green
      against agwinterm `main`; a sandbox session split horizontal, swapped, saved, killed, restored
      with the layout intact and both `K` slots on the right shells (a screenshot in the PR body).
      (dev client — agwinterm `main` at `dc0a2c6`, #240's contract, the post-#238 `agwintermctl`
      whose `session swap x` says "Nothing sent": every suite green, twelve suites, 693 PASS, 0 SKIP,
      0 FAIL, exit 0; the matrix's 54 cells all pass; `.ralphex/runall-task6.log`. `check-contract`:
      "in step with agwinterm" against the raw `main` file. ➕ The combined drive is
      `qa/fixtures/layout-restart.ps1`, the P3 `persistence-restart.ps1` shape: one session split
      `--axis horizontal`, a ping in each shell, an untargeted `restore capture`, `session swap`, the
      file read (`P 1`, `L 1 horizontal 1`, `K 1 <own ping> <split ping>` — by role, the own shell's
      command in field 2 while it sits in slot 1), the window KILLED, relaunched without
      `--no-restore`: the tree's block is `axis:horizontal`, `paneIds:[<fresh split>, <own>]` (the
      own shell adopted live from the host, the split rebuilt — the log's "1 of 1 split layout(s)
      restored"), `capturedCommands` keyed by the two pane ids with each ping on the shell that ran
      it, both ids answer `session text`, the file re-written with the same `L` and `K`, and a
      `PrintWindow` capture of the restored window: 20/20 killed and 20/20 `-Graceful`. The first
      run of the fixture failed its own K checks because it captured with `--target <owner>`, which
      captures that ONE pane by the P3 rule — the fixture was wrong, not the product. The screenshot
      is `%TEMP%\agliteterm-layout-restart\restored.png` (a copy at
      `.ralphex/layout-restart-task6.png`, untracked): the sidebar row `layout-keeper`, the empty
      fresh split shell on top, the adopted own shell with its ping replies below, the status bar
      "2 sessions". `qa/panes.md`'s restart case names the fixture.)
- [x] The plan's notes carry what each revmux round found (the P3-lite pattern).
      (the rounds run in ralphex's review phase AFTER the task loop ends, one revmux round per review
      iteration under `.revmux/tasks/ralphex-2026-09-06-p4-lite-mirror/`; each round's findings and
      the fix commit they led to are appended below as "**What revmux round N found**", the way
      `docs/plans/completed/2026-09-05-p3-lite-mirror.md` carries its two. No round has run yet at
      the time of this line — the item is satisfied by that routine, not by a round that already
      happened.)

**What revmux round 1 found** (`.revmux/tasks/p4-lite-mirror/01-initial`, full branch at
`57d4abc`): two Majors, both the same shape — a pre-P4 site that used `id` where the shell's id
was meant, harmless while the two were equal and wrong for a promoted session, the one object
whose `id` and `paneId` differ: (1) `restore capture`'s stale-entry re-check compared the
snapshot's pane id against `s->id`, so every promoted session was silently dropped (a targeted
capture answered `captured 0, panes []`); (2) the `D` line wrote `s->id`, so a relaunch after a
kill could not adopt a promoted session's shell (it relaunched a fresh one and left the live
shell orphaned in the host). Both fixed by using `paneId` — and the second one is a documented
consequence now: after a kill-restart a promoted session comes back under its shell's id (the
rule above, `docs/state-file.md`, the skill). The Constraints' site list said "every site that
hands a shell's identity to the pty-host" and the audit missed the two that do it indirectly
(through the state file, and through a snapshot). Eight Minors, all fixed: the live
re-orientation never scheduled a save (a kill lost the new axis); a promotion left `g_sel.pane`
at 1 (the survivor's selection invisible and its cursor suppressed); the skill's env-ids bullet
said the two variables "part" after a promotion — nothing rewrites a shell's environment, they
stay equal and `AGWINTERM_SESSION_ID` names the shell then; three "right-hand" comments; the
rule stated by a list of four paths in the skill / README / this plan where `toggle`, a bare
`session split` and the Split key reach the same state (agwinterm r3's Major, the same class —
now by condition everywhere); "Close Session" on the close chord, palette and File menu when it
closes a PANE on a split (agwinterm's "Close Pane / Session"; the sidebar row keeps "Close
Session" and closes the session); README's "which `off` and the close chord could not" (the
chord can, since P4); "set once in `newSession`" → `attachSession`. Left as the round filed
them, neither a Minor: the concurrent-`split on` race on `splitId` (Pre-existing — both paths
take the same shape as before); `atoi` on the `L` owner index (Immaterial — the file's
convention for every positional line, P, C, K, O, A). New checks: honesty — the re-orientation is saved (the `L` line gone
after a return to vertical), `restore capture` on a promoted session (targeted and untargeted,
the pane under its own id), the `D` line names the survivor's shell; matrix — `axis-relive-killed`
and `promote-killed` (adopted by the shell's id, the marker back, the id after = the shell's).

**What revmux round 2 found** (`02-after-fix`, the r1 fix commit `bfcf671`): no Major. Five
Minors, two Pre-existing, all fixed. The one worth the next batch's attention: the skill's new
lookup recipe ("the node whose `paneIds` contains `$AGWINTERM_PANE_ID`, or whose `id` equals it")
could not work for the promoted session it was written for — a promoted session is single, so its
node carried no `paneIds`, and its `id` is the closed shell's. The r1 fix stated a recipe without
running it. Fixed at the source, not in the prose: a promoted session's node now carries `paneIds`
alone (`[<its shell's id>]`, no `paneCount`) — `paneIds` is present exactly when the session's pane
ids are not simply `[id]`; a lite-only key in a lite-only state, so in every state agwinterm can be
in the node shape is still agwinterm's. The same shape once more, in `callerWorkspace`
(pre-existing since P2's caller rule): the caller of `session new` is a SHELL's id, and two shells
hold an id that is no node's `id` — a split shell (hidden; it now answers with its owner's
workspace) and a promoted survivor (found by the `paneId` arm now) — both used to fall through to
the active workspace. The rest: the `g_sel.pane` reset sat inside `if (displayed)` — the selection
is per-session and survives a switch, so an off-screen promotion over the pipe still stranded it
(moved out, keyed on the survivor pointer); the r1 note above said "nine Minors, seven fixed" for
eight and eight; the PR body still carried the four-path rule and `newSession`; `qa/panes.md`'s
rule sentence now points at the vocabulary section for the exception; the Constraints' "re-stamped
on adoption" named the id-collision retry (nothing rewrites a running shell's environment); the
re-orientation honesty check asserted only that the `L` line was gone, never that it had been there
(present asserted after the horizontal split now). New checks: a plain single node has no
`paneIds`; the promoted node's `paneIds` is `[survivor]` with no `paneCount`; a bare `session new`
from the split shell and from the promoted survivor lands in the session's workspace with another
one active.

## Technical Details

- **Why `paneId` and not "the promoted session takes the survivor's id".** The alternative renames
  the session under every agent holding it (`session close S` stops working after a `split close`
  on S's own shell) and diverges from agwinterm, where the session keeps S and `paneIds` becomes
  `[B]`. With `paneId`, the tree shows S with `paneIds:[B]`, `--target S` and `--target B` both
  reach the surviving shell, and a later `split on` gives `[B, C]` — agwinterm's picture exactly.
  The cost is one field and the site list in Constraints; the risk is a site that reports a pane
  through `id` — the honesty checks that read the survivor under both ids are the guard.
- **Why an `L` line and not a fifth `P` field.** `P`'s tail is `args...` (`:8416`): a 0.17.14
  reader would launch the split shell with `horizontal` as its first argument. A new line type
  costs nothing on a downgrade.
- **Why the swap is a flag in `paneRect`.** `g_pane[0]` must stay the visible session's index for
  five callers; the swap is purely where two known shells are drawn and hit. `g_focus` keeps
  indexing owner/split, so "focus follows the pane" needs no code.
- **What a swap does NOT persist through**: ids (fresh after a graceful restart, as everything in
  lite); the `L` line restores the order and the axis onto the recreated pair.
- **`session close` on the split shell's id** is unchanged: lite closes that shell (an unsplit,
  now through the Task 2 primitive); agwinterm's `session close` resolves SESSIONS only and answers
  "session not found" for a pane id (`Program.Sessions.cs` `Find`). A pre-P4 divergence in lite's
  favour (the id reaches the shell it names); recorded in `lite-parity.md`, not changed here.

## Post-Completion

- Sibling PRs: the `session swap` conformance step + refusal in agwinterm's `control-api.json`,
  then `-Update` here; the `lite-parity.md` rewrite in agwinterm.
- Release: lite's installer stays `0.17.14` until Boris calls the number; agwinterm 0.17.13 is what
  turns this PR's CI green.
- P5 (pane-scoped overlays) must consult the slot map when it anchors an overlay to a pane.
