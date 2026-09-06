# Persistence — the context row and the captured slot

`session context` and `restore capture`: lite's half of parity batch P3 (agwinterm #233, `qa/persistence.md`
there is the sibling). The verbs' replies and refusals are pinned by `test/control-honesty.ps1`; the
restart cells by `test/restore-matrix.ps1`. The cases here are the parts that need eyes: a run of
text a person can see is dimmed, sits after the name, and did not push the badges around.

**The rule:** the context is drawn, not stored in the label. A same-colour suffix on the label would
be "shown", not "shown dimmed", and it would widen the treeview's own hit-test and its rename EDIT.
So the label stays the name plus its status suffix, and the context is the third badge the row's
post-paint pass draws after it, clipped short of the unread pill and the flag pennant.

Setup for every case: sandbox instance per `qa/product.md`. The context verbs need a post-#233
`agwintermctl` (the released 1.0 client refuses `session context` client-side with `unknown session
command 'context'`; `$env:AGWINTERMCTL` points the checks at a dev build). Report SKIP on an older
client, never PASS.

```powershell
. test\ui-lib.ps1
$ctl = Get-CtlPath
$s   = Start-Sandbox -Exe (Resolve-Lite $null) -Ctl $ctl -Pipe 'qa1'
function Ctx([string[]]$rest) { Send-Ctl $s (@('session','context') + $rest) }
function Tree { (ConvertFrom-Json (Send-Ctl $s @('tree'))).result }
```

**Last run:** 2026-09-05, branch `feat/p3-lite-mirror` (build v0.17.14 from `./build.ps1` at the
task-2 commit), agwinterm dev `agwintermctl` (post-#233, `restore` answers its usage line).
- *The context is drawn dimmed after the name*: PASS — `qa/fixtures/context-row.ps1` drove it.
  `alpha` (flagged, unread 1) got `reviewing the P3 diff`; `gamma` got a 96-character context.
  The before/after `PrintWindow` diff was confined to the two rows to the right of their labels;
  the amber pennant and the red pill counted the same pixels (41 and 183) in both captures; the
  three rows stayed 18 px apart; `gamma`'s run ends in `…` before the pill's place. Capture:
  `docs/img/qa-p3-context-row.png`.
- *The persisted half* (2026-09-05, task-6 build, dev `agwintermctl`): PASS both ways —
  `qa/fixtures/persistence-restart.ps1` 19/19 after a graceful close and 19/19 after `-Kill`. The
  file read between the windows had `C\t1\treviewing the P3 diff`, then `P\t1\t…`, then
  `K\t1\t\t"C:\Windows\system32\PING.EXE" -n 311 127.0.0.1` and `K\t2\t"…PING.EXE" -n 311
  127.0.0.1\t`, in that order; after the relaunch `alpha` carried its context and one
  `capturedCommands` key (the rebuilt split's id, `qa-p3r-4` graceful / `qa-p3r-5` killed), `beta`
  its own; the log said `1 of 1 context(s) restored` and `2 captured command slot(s) restored from
  2 K line(s), 0 dropped`. Two things the first draft of the fixture got wrong, now in the case: the
  slot is the command line as the process reports it, and the sandbox's default session makes three
  listed sessions, not two.

---

## The context is drawn dimmed after the name

**Guards:** the first cut of the batch had the row's post-paint notification requested only for
flagged or unread rows, so a plain row with a context drew nothing and `tree --json` said it had
one. The run is requested for every row with a context now. The clip edge is computed from the
pill's measured width BEFORE anything is drawn, so a long context stops short of the pill instead of
running under it.

**Setup:** three sessions `alpha`, `beta`, `gamma`; `beta` selected. Flag `alpha` (`session flag on
--target <alpha>`) and give it an unread count (`session type "echo one`r" --target <alpha>` while
`beta` is on screen — the FTCS prompt wrap marks the command done, and `alpha` is not visible).
Read `flagged: true` and `unread: 1` for `alpha` from `Tree` before going on: a row with no badges
proves nothing about badges.

**Steps:**
1. Capture the main window (`PrintWindow`, `PW_RENDERFULLCONTENT`).
2. `Ctx @('reviewing the P3 diff', '--target', $alpha)` — expect
   `{"session":"<alpha>","context":"reviewing the P3 diff"}`.
3. `Ctx @('a context long enough that it cannot fit in a 180 px sidebar row and must be cut with an ellipsis', '--target', $gamma)`.
4. Wait ~1 s. Capture again. Diff the two captures.

**Expect:** in the second capture `alpha`'s row reads `alpha` in the row colour, then a gap, then
`reviewing the P3 diff` in the theme's secondary-text colour (light 110, dark 150 grey); the same
face and size as the name. `gamma`'s row reads `gamma` then its context cut with `…` before the
badge column. `beta`'s row is unchanged. The diff's bounding box lies to the RIGHT of the two
labels and inside their two rows; every pixel of the pennant and the pill is identical in both
captures (count the amber `245,194,66` and the red `205,72,58` pixels in the sidebar — same
numbers, same places); the rows are the same height and at the same y as before (the third row did
not move). Selecting `alpha` then pressing F2 opens the rename EDIT over the NAME only — the
context is not in it.

**Fails when:** the context is appended to the label string (it turns the row colour, moves into
the rename EDIT, and pushes nothing — the badges are drawn from the right edge — but the
"dimmed" is gone); the post-paint pass stops being requested for context-only rows; the clip edge
is computed before the pill is measured (the run walks under the pill); a `context` written on a
pipe thread is read in the paint without `g_lock`.

**Proven to discriminate:** yes — the first build of the run drew nothing for a context-only row
(the notification was flag/unread-gated) and this case's diff came back "captures identical" for
`gamma`; the run appeared once the gate included the context.
---

## The persisted half: a restart brings the context and the slot back, and the file says so

**Guards:** the `C` and `K` lines are positional (the session's index among the `S` lines) and are
refused wholesale when the `S` count does not add up, the `P` guard's rule; `K` is written after
`P` by convention — it sits with the `P` lines it describes — not by requirement: the reader
collects every line type in file order and applies them in its own fixed order, so a `K` above a
`P` restores identically (`docs/state-file.md` and the save comment in `saveSessionState` say the same). A restore that put the
slot on the wrong pane, or dropped it because the split came back a moment later, would answer a
`tree` that disagrees with the reply the caller kept. `test/restore-matrix.ps1` pins the cells
(`context-graceful`, `context-killed`, `capture-graceful`, `capture-killed`, `capture-split`, the
seeded `context-bad-line`, `context-count-mismatch`, `context-stray-index`, `pre-p3-file`); this case
is the same journey with the FILE read by a person between the two windows.

**Setup:** `qa/fixtures/persistence-restart.ps1` drives it end to end (`-Kill` for the crash
variant); by hand, the steps are below. Two sessions `alpha` and `beta`, `alpha` split; a context
on `alpha`; a marker command (`ping -n 311 127.0.0.1`) typed into `alpha`'s split pane and into
`beta`, so one session has a slot on pane 1 only and the other on pane 0 only.

**Steps:**
1. `session context "reviewing the P3 diff" --target <alpha>`; type the marker into the split and
   into `beta`; wait ~3 s; `restore capture`. Expect `captured: 2`, `replayOnRestore: false`, and
   every pane listed — the sandbox's default session, `alpha`, its split and `beta` — with the split
   and `beta` holding the marker and the other two `null`. The slot is the command line as the
   PROCESS reports it (`"C:\Windows\system32\PING.EXE" -n 311 127.0.0.1`), not the text typed.
2. Open `<sandbox LOCALAPPDATA>\agliteterm\sessions-<pipe>.tsv` (the reply was written after the
   save, so the file already has it). Expect, after the `S` lines: `C\t<alpha idx>\treviewing the P3
   diff`, then `P\t<alpha idx>\t…` for the split, then `K\t<alpha idx>\t\t"C:\Windows\system32\PING.EXE" -n 311 127.0.0.1`
   (pane 0 empty, pane 1 the marker — the command line as the PROCESS reports it, as step 1 says,
   never the text typed) and `K\t<beta idx>\t"C:\Windows\system32\PING.EXE" -n 311 127.0.0.1\t`
   (the reverse). Match on the argument tail (`-n 311 127.0.0.1`), which is what the fixture does.
3. Close the window (File → Exit, or `CloseMainWindow`; with `-Kill`, end the process instead).
   Relaunch the same instance: same `--pipe`, same `LOCALAPPDATA`, **without** `--no-restore`.
4. `tree --json`. Expect `alpha` with `"context":"reviewing the P3 diff"` and one
   `capturedCommands` key that is NOT `alpha`'s new id (it is the rebuilt split's) holding the marker;
   `beta` with no `context` key and `capturedCommands` keyed by its own new id; three sessions
   listed (the default one, `alpha`, `beta`), not four (the split is a pane).
5. Read the file again after the restart's own save: the same `C` line and both `K` lines, re-written
   against the new `S` order with the same fields.

**Expect:** every line of step 2 present in the order `C`, `P`, `K`; every key of step 4 back on
the right session and the right pane after the restart; `agliteterm-<pipe>.log` naming the
context and the slots it restored, and nothing about a dropped line.

**Fails when:** a `K` line whose pane-1 field names a split the file has no `P` line for is hung
on the owner's own pane instead of dropped with the warning; the `C` or `K` set survives a session
count that disagrees with the `S` lines (the `P` guard's rule);
the split's slot lands on the owner's own pane (one `capturedCommands` key, but it is the session's
id); a context is appended to the label and comes back as part of the name; the reply is written
before the save (kill the window right after `restore capture` with `-Kill`: the file must already
hold the `K` lines); an older file with no `C`/`K` stops restoring (`pre-p3-file` in the matrix).

**Proven to discriminate:** not by a failing build yet — the matrix cells were written beside the
code and were green on their first run against it. The seeded cells discriminate by construction:
`context-bad-line` feeds a `C` line holding U+0001 and demands the session WITHOUT a context plus
the drop in the log, which a build that skipped load-time validation cannot satisfy;
`context-count-mismatch` feeds a broken `S` line and demands no context on the surviving session,
which a build without the count guard hangs on it. Fill this in the first time the case catches
something.
