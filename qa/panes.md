# Panes

The right-hand pane and who owns it.

**The rule:** a split belongs to the SESSION, not to the window. Each visible session may own one
right-hand terminal; switching sessions shows that session's split, or no split at all. It closes
with its owner, and it comes back with its owner after a restart.

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

**Fails when:** the `P` line stops being written, or the parser's guard drops it wrongly. That guard
refuses ALL `P` lines when the number of `S` lines it counted does not match the number that parsed,
because a dropped `S` line slides every owner index onto the wrong session.
