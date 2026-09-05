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
