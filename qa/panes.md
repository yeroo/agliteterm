# Panes

The second pane and who owns it.

**The rule:** a split belongs to the SESSION, not to the window. Each visible session may own one
second terminal, beside it (`vertical` = left/right panes, the default) or below it (`horizontal`
= top/bottom); switching sessions shows that session's split, or no split at all. It closes with
its owner, and it comes back with its owner after a restart, on the same axis and in the same order.

**The words:** a SLOT is a position (slot 0 = left/top, slot 1 = right/bottom), an ID is a shell.
`session swap` exchanges the slots and nothing else. A session id names the session's own shell
while it exists; when that shell is closed the survivor becomes the session (same id, name, flag,
context, sidebar row) and keeps its own pane id.

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
for the PR body. `-Graceful` closes instead of kills. Run alone.

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
and carries no split block; the sidebar row is unchanged (name, flag, dimmed context). The events
hold `tree` and NOT `session`/`closed`. `session text --target <session id>` and `session text
--target <split shell's id>` both read the marker. The Reopen Closed Session row (bind it in the sandbox profile) reopens nothing.

**Fails when:** `closeSplitSide` on the owner goes through `closeSessionAt` (a `ClosedSpec` push and
a `session closed` event), the field move skips a field, or a site reports the pane through `id`
where `paneId` was meant.
