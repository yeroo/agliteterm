# Panes

The second pane and who owns it.

**The rule:** a split belongs to the SESSION, not to the window. Each visible session may own one
second terminal, beside it (`vertical` = left/right panes, the default) or below it (`horizontal`
= top/bottom); switching sessions shows that session's split, or no split at all. It closes with
its owner, and it comes back with its owner after a restart, on the same axis and in the same order.

**The words:** a SLOT is a position (slot 0 = left/top, slot 1 = right/bottom), an ID is a shell.
`session swap` exchanges the slots and nothing else. A session id names the session's own shell
while it exists; whenever that shell is the one that closes the survivor becomes the session (same
id, name, flag, context, sidebar row) and keeps its own pane id — the rule in full, with its one
exception (a kill-and-relaunch brings a promoted session back under its shell's id), is the
plan's vocabulary section (`docs/plans/completed/2026-09-06-p4-lite-mirror.md`).

**A covered pane (P5):** a pane may hold a PANE OVERLAY — `session overlay open <cmd> --pane
left|right` — one more hidden session drawn in that pane's box instead of its shell, badged
`overlay`, and the pane's SURFACE while it is open (keys, the mouse, `--target active` reach
it; the pane's own id reaches the shell underneath). `left` is slot 0 and `right` slot 1
whatever the axis; the slot moves with its shell on a swap and dies with its pane. The rule in
full is the P5-lite plan's vocabulary section (`docs/plans/2026-09-07-p5-lite-mirror.md`);
the popup over the whole window is the session-wide slot and is unchanged.

Setup for every case: sandbox instance per `qa/product.md`.

---

## The split follows the session

**Guards:** `g_pane[1]` used to be window state, so it kept whatever shell it had while the left pane
changed under it. Switching sessions left the previous session's right-hand terminal beside the new
one, and a session that never had a split appeared to have one. Fixed in 0.17.13.

**Setup:** two sessions, `alpha` and `beta`.

**Steps:**
1. Select `beta`, `session split on`, and print a distinct line into each of its two panes.
2. Select `alpha`.
3. Select `beta` again.

**Expect:** with `beta` selected the window shows **two** panes; with `alpha` selected, **one**;
selecting `beta` again brings its split back with its text still in it. Read the pane count from a
`PrintWindow` capture - `session text` answers about one pane, so it cannot tell you how many there
are, and a case that asks it will pass whatever happens.

**Fails when:** any path that changes the main pane stops going through `selectPrimary()`, or
`resolveSplitForPrimary()` stops consulting `Session::splitId`.

**Proven to discriminate:** yes - captured before the fix (both sessions showed beta's split) and
after (alpha shows one pane).

---

## A split closes with its session

**Guards:** a split shell is hidden - no tree row, no name - so one that outlives its owner is a
running process nothing can reach or kill. It is also what `restore-matrix` now asserts: with the
owner gone the window is empty, which is a deliberate empty and must be written.

**Steps:** with only one session, `session split on`, then close that session.

**Expect:** the window empties (both shells gone). The state file records the empty rather than
keeping the closed session.

**Fails when:** `closeSessionAt` stops closing `splitId`'s shell.

---

## A split survives a restart

**Guards:** split shells were never persisted, so a restart silently dropped them - the session came
back alone with no indication anything was missing. Added in 0.17.13 as a `P` line naming its owner
by position among the `S` lines.

**Setup:** start lite WITHOUT `--no-restore` (this case is about restore), one session renamed
`has-split`, `session split on`, and something printed in the split.

**Steps:** confirm the state file has a `P` line, close the window, start it again.

**Expect:** the restored window shows two panes with `has-split` in the sidebar and **one** session
in the status bar (the split shell stays hidden). `session split on` returns the restored split's id,
and typing into that id reaches a live shell.

The shell is fresh, not the old one: only `S` lines carry host ids, so a split is recreated rather
than adopted. Its scrollback does not come back - the pane does.

**The layout half (P4):** `qa/fixtures/layout-restart.ps1` drives it end to end - split
`--axis horizontal`, a marker command in each shell, one `restore capture`, a `session swap`, then
the window killed (the `L` line has to have been checkpointed by the save the swap triggered; there
is no close) and relaunched. After the restart the tree's split block says `horizontal` with the
session's own shell in slot 1, each captured slot sits on the shell that ran it (`K` is by role,
field 2 the session's own shell whatever its slot), both shells answer `session text`, and a
`PrintWindow` capture of the restored window lands in `%TEMP%\agliteterm-layout-restart\restored.png`
for the PR body (the 2026-09-06 run is `docs/img/qa-p4-layout-restart.png`). `-Graceful` closes instead of kills. Run alone.

**Fails when:** the `P` line stops being written, or the parser's guard drops it wrongly. That guard
refuses ALL `P` lines when the number of `S` lines it counted does not match the number that parsed,
because a dropped `S` line slides every owner index onto the wrong session.

---

## A horizontal split stacks

**Guards:** the axis is a flag on the owner read in ONE place for geometry (`paneRect`) and one for
paint (the divider). A path that computed the rect on its own would put the second pane beside the
first whatever the axis said, and `tree` would still report `horizontal` - the grid proves the
arrangement, the capture proves the divider.

**Setup:** one session, wide enough for the two halves to be told apart.

**Steps:**
1. `session split on --axis horizontal` and print a distinct line into each pane.
2. Capture the window with `PrintWindow`.
3. `session split on --axis vertical` on the same session (re-orients it live); capture again.

**Expect:** after step 1 the divider is a horizontal hairline at about half the content height and
the two lines sit one ABOVE the other, each pane the full width; `tree --json` shows
`axis: "horizontal"` on the node and each pane's `rows` about half of a single pane's. After step 3
the same two shells sit side by side, the divider vertical at about half the width, `axis:
"vertical"`, and nothing was re-spawned - the lines printed in step 1 are still there.

**Fails when:** `paneRect` stops consulting `Session::horizontal`, or the divider in `paint` is
drawn on a hard-coded vertical, or a re-orient goes through the spawn path.

---

## A swap exchanges contents, not geometry

**Guards:** a swap is a flag read inside `paneRect`, never an exchange of `g_pane[0]` and
`g_pane[1]`, because five callers need `g_pane[0]` to stay the visible session. The failure this
case discriminates is a swap that moved the divider, resized a pane, or moved an id: a marker typed
under each id before the swap must read back under the same id after it.

**Setup:** one session, `session split on`, a distinct marker printed into each pane (`echo LEFT`
in the session's own shell, `echo RIGHT` in the split shell, by their ids).

**Steps:**
1. Focus the session's own shell (`session focus primary`). Capture with `PrintWindow`.
2. `session swap`. Capture again.
3. `session text --target <session id>` and `session text --target <split id>`.

**Expect:** the two captures have the divider at the SAME x; the marker texts have changed sides;
the focused-pane marker (the caret) is on the other side, in the pane holding `LEFT` - the shell
being typed into is still the one being typed into. The reply of step 2 is `{session, paneIds:
[<split id>, <session id>], focusedPane: 1, axis: "vertical"}`. Step 3 reads `LEFT` under the
session id and `RIGHT` under the split id, exactly as before the swap. `session focus left` now
lands on the split shell (slot 0).

**Fails when:** a swap exchanges `g_pane[0]`/`g_pane[1]` (the sidebar highlight and the save follow
the wrong session), `paneRect` ignores `swapped`, or the pane-id resolution follows the slot.

---

## A promotion keeps the sidebar row and the tree id

**Guards:** when the session's OWN shell is the one closed, the survivor takes the session over:
`id`, name, workspace, flag, context and the sidebar row move onto the split shell's object, and
its pane id stays. A `session closed` event, a `ClosedSpec` for undo, or a renamed sidebar row
would each mean the session was closed rather than promoted - and undo would resurrect a session
that is still there.

**Setup:** one session renamed `keeper`, flagged, with a context set; `session split on`; a marker
printed in the split shell.

**Steps:**
1. Note the session id from `tree --json` and the split shell's id (the `split on` reply).
2. `session split close --target <session id>` (the session's own shell).
3. `tree --json`; `events --since <cursor taken before step 2>`; look at the sidebar row.

**Expect:** the reply of step 2 is the split shell's id. The window shows ONE pane at the full width
with the marker still in it. The tree node keeps the session id, `keeper`, its flag and context,
carries no `paneCount`, `focusedPane` or `axis`, and carries `paneIds` holding the split shell's id
alone (the survivor's own pane id — the one single node whose pane id is not its `id`); the
sidebar row is unchanged (name, flag, dimmed context). The events
hold `tree` and NOT `session`/`closed`. `session text --target <session id>` and `session text
--target <split shell's id>` both read the marker. The Reopen Closed Session row (bind it in the sandbox profile) reopens nothing.

**Fails when:** `closeSplitSide` on the owner goes through `closeSessionAt` (a `ClosedSpec` push and
a `session closed` event), the field move skips a field, or a site reports the pane through `id`
where `paneId` was meant.

---

## A pane overlay covers one pane and the other stays interactive

**Guards:** gate 1 of P5-lite: a pane overlay is IN-WINDOW — one more hidden `Session` hung on the
shell it covers (`Session::overlay`), painted in the pane's box by `paint`'s pane loop asking
`surfaceOf(shell)` for what to draw there — not a popup sized to the pane rect. A popup is framed,
floats off the box after a window move, is raised only when the process holds the foreground, and
its `g_focusOverride` takes EVERY keystroke, so the sibling pane could not stay interactive — the
rule's one hard property. The automated block (`test/control-honesty.ps1`, `# ---- P5: pane
overlays ----`) reads every surface through the pipe; this case is the picture: the overlay drawn
in the RIGHT box and nowhere else, the divider where it was, the LEFT box showing what was typed
into it while the overlay was up, and the `overlay` badge framed in the right box's top-right
corner. `qa/fixtures/pane-overlay.ps1` drives it end to end and writes the capture; run alone.

**Setup:** one session named `covered`, `session split on` (vertical), wide enough for both boxes
to be read.

**Steps:**
1. `session overlay open "echo P5-OVERLAY-MARKER; Start-Sleep 300" --pane right --target <session
   id>`; keep the reply (the overlay's id).
2. `session type "echo P5-LEFT-MARKER`r" --target <session id>` — the left pane's shell, typed into
   while the right pane is covered.
3. `tree --json`; `session text --target <overlay id>`; `session text --target <split shell's id>`;
   `session overlay text --pane right --target <session id>`.
4. Capture the main window with `PrintWindow`.
5. `session overlay close --pane right --target <session id>`; `tree --json`; `session focus right`
   then `session text`.

**Expect:** step 1 answers a session id of this instance (`<pipe>-<seq>`) that is none of the three
ids already known — an id, not the popup's status word. Step 3: `paneOverlays` is `["right"]` on the
node and the split block (`paneCount`, `paneIds`, `axis`) is unchanged; the overlay's id reads
`P5-OVERLAY-MARKER`; the split shell's id reads its own prompt and NOT the marker — the shell is
still there underneath; `overlay text --pane right` is byte for byte the overlay id's text. The left
pane read by the session id holds `P5-LEFT-MARKER`. The capture: the LEFT box shows the typed marker
at its prompt with the caret after it, the RIGHT box shows
`P5-OVERLAY-MARKER` with no prompt after it (the command is sleeping), the divider sits between them
at the same x as before the open, the word `overlay` is framed in the right box's top-right corner,
and there is NO framed popup over the window. Step 5: `closed`; `paneOverlays` is absent from the
node; the right box shows the split shell again (`session text` with slot 1 focused is the shell's
prompt, the overlay's marker gone) and the overlay's id resolves nowhere. The 2026-09-07 run of the
fixture is `docs/img/qa-p5-pane-overlay.png`.

**Fails when:** `paint`'s loop stops asking `surfaceOf` (the shell paints under the overlay's
session); `openPaneOverlay` reaches `openOverlay` (a framed popup appears, the left pane stops
taking keys — the marker never lands); `syncPaneSizes` / `paneGridSize` size the overlay to the
window instead of the box (the overlay's lines wrap at the wrong width, or overrun the divider);
or the badge is drawn from the popup's title path (no `overlay` word in the box).
