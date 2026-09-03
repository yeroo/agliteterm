# Control API — the read-only trio

`surface.cursor`, `statusChangedAt` on every `tree` node, and a truthful `ping` — which is what
`agwintermctl version` reports as the app. lite's half of parity batch P1; agwinterm's sibling is
its `qa/control-read.md`.

**The rule:** each reply describes the *live* thing it names — the caret where the window actually
paints it, the moment a status was actually written, the build that is actually running — so a
script can act on it without a second, independent check. `test/control-read.ps1` pins the shapes
and the arithmetic (the column moves by what was typed, the stamp moves on a re-assert); the cases
here are the parts that need eyes, or a real clock.

Setup for every case: sandbox instance per `qa/product.md`. No setting is changed. Every ctl call
goes through `Send-Ctl`, which clears the caller's `AGWINTERM_*` variables — a QA run starts inside
an agwinterm pane, and an untargeted verb would otherwise ask about the *caller's* session.

```powershell
. test\ui-lib.ps1
$ctl = Get-CtlPath
$s   = Start-Sandbox -Exe (Resolve-Lite $null) -Ctl $ctl -Pipe 'qa1'

function Tree      { (ConvertFrom-Json (Send-Ctl $s @('tree'))).result }
function Node($id) { Tree | ForEach-Object workspaces | ForEach-Object sessions | Where-Object { $_.id -eq $id } }
function Sid       { (Tree).workspaces[0].sessions[0].id }
function Col($t)   { (ConvertFrom-Json (Send-Ctl $s @('surface','cursor','--target',$t))).result }
```

`surface cursor` reached the CLI in agwinterm #221. An older `agwintermctl` refuses the verb on its
own side ("unknown command 'surface cursor'") before any pipe is opened; report the cursor case SKIP
then, never PASS.

**Last run:** 2026-09-03, agliteterm 0.17.14 against agwinterm's post-#221 `agwintermctl` — all
three cases pass, including the wide-glyph follow-up (column and painted caret both move two cells).

---

## The column `surface.cursor` reports is the caret the window paints

**Guards:** the whole point of the verb. A caller deciding "is that composer empty before I type
into it" compares one number against the column an empty composer parks the caret at. A stub
answering `0`, a value read once and cached, or a column counted in a different unit from the
renderer's (bytes, or cells of the wrong width) all pass a shape test and break that caller in
exactly the way the placeholder-string guess it replaces already did. `test/control-read.ps1`
already proves the arithmetic against `session text`; this case closes the last gap — that the
number is the cell the *painted* caret sits in, since `surface.cursor` and `paintPane` read the same
`info.cursorCol` and nothing but a picture proves they still do.

**Setup:** the first session at a prompt. Give it a moment to finish drawing before the first read —
a column caught mid-repaint is a race in the case, not a bug in the verb. Print a known prompt so the
caret's starting cell is not the machine's theme: type `function prompt { 'QA> ' }` followed by
Enter through `session type`, and wait for the new prompt.

Do not assume how the caret is painted. When another window holds the foreground the caret is a
static **hollow one-cell frame** (`FrameRect`); but a run started by an agent with nothing else on
the desktop taking the foreground leaves the sandbox window focused (it was, on 2026-09-03), and then
the caret is a **solid block blinking** at roughly half-second phases (`InvertRect`) — a single
capture lands in the off phase half the time and reports "no caret". Locate it blink-proof: write
DECTCEM off (`session write` of `ESC[?25l` — emulator only, the shell never sees it) and capture a
reference; write `ESC[?25h`; then capture ~8 frames ~130 ms apart and keep the one that differs most
from the reference. The differing pixels' bounding box is the caret cell (36 px for the frame, 96 for
the block at 8×12), and its width IS the cell width, so no font metric has to be known. No selection
may be live: the caret is not painted over one.

**Steps:**
1. Record `$c1 = Col (Sid)`. Capture the window with `PrintWindow` and locate the caret frame on the
   prompt row: `$x1` = its left edge, `$w` = its width.
2. `Send-Ctl $s @('session','type','abcdefghij','--target',(Sid))` — **no newline**, so this stays an
   unsubmitted draft at the prompt, which is the state the caller asks about. Wait ~1s.
3. Record `$c2 = Col (Sid)`. Capture again; `$x2` = the caret frame's left edge.
4. Send three Backspaces through the real key path — `[LiteUi]::Key($s.Hwnd, 8, 3)` — wait ~1s,
   record `$c3` and capture `$x3`. (Before 2026-09-03 that helper posted the keyup with lParam `1`;
   Windows translates such a keyup into a second `WM_CHAR`, lite forwarded the `0x08`, and PSReadLine
   read it as Ctrl+Backspace and killed the whole word — `$c3` came back at the prompt column. A
   harness artefact, fixed in `test/ui-lib.ps1`; a real keyboard never produced it.)

**Expect:**
- `$c2 - $c1 -eq 10` and `$c3 -eq $c2 - 3` — the number moves by what was typed, and **back**;
- `$x2 - $x1 -eq 10 * $w` and `$x2 - $x3 -eq 3 * $w` — the painted caret moved by the same number
  of cells, in the same direction;
- `$x1 - $c1 * $w`, `$x2 - $c2 * $w` and `$x3 - $c3 * $w` are all the **same** number — the pane's
  left edge, where the `Q` of `QA> ` starts. That equality is the case: the column reported and the
  cell painted are the same coordinate, not two counters that happen to move together;
- `$c2` is a JSON number in the raw reply (`{"ok":true,"result":14}`), not a string.

**Fails when:** `surface.cursor` stops reading `emu_info` under `g_lock` and answers from a cached
snapshot; the renderer starts drawing the caret from anything other than `info.cursorCol`; or the
column starts counting bytes instead of cells (type a wide glyph such as `日` as a follow-up — the
column and the frame both move by two cells, or neither does).

**Cleanup:** enough Backspaces to empty the line before the next case types into it.

---

## `statusChangedAt` goes back *down* after re-asserting the same status

**Guards:** `tree --json` reports `"status":"active"` with no age, so nothing could tell a working
agent from one whose hook died forty minutes ago. The decision under test is that the stamp is
written on **every** `session.status` write, not only when the value changes: a hook re-asserting
`active` every 30 s is exactly the liveness signal being asked for. Someone will eventually read
that as a bug and "fix" it into change-only — which reports the age of the *first* write and makes a
healthy agent look dead. `test/control-read.ps1` proves the stamp moves forward across a 2 s gap;
this case watches the **age** with a real clock, over a gap long enough that a collapsed repeat
could not hide inside a second's rounding.

**Steps:**
1. `Send-Ctl $s @('session','status','active','--target',(Sid))`. Read the node; record
   `$t1 = (Node (Sid)).statusChangedAt` and `$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()`.
2. Wait 12 s. Read the node again; record `$t2` and the age `$age2 = now - $t2`.
3. `Send-Ctl $s @('session','status','active','--target',(Sid))` — the **same** status,
   deliberately. Wait ~1 s; record `$t3` and `$age3`.
4. `Send-Ctl $s @('session','status','idle','--target',(Sid))`; record `$t4`.
5. `Send-Ctl $s @('session','new','--name','virgin')` — a session no hook ever writes to — and
   read its node from `Tree` by name.

**Expect:**
- `$now - $t1` is between 0 and 5 — seconds, not milliseconds, and not the epoch;
- `$t2 -eq $t1` and `$age2 -ge 10` — an untouched status does not drift forward, and the age
  really grew (take both from the same read);
- `$t3 -gt $t2` and `$age3 -le 5` — **the age went back down** after re-asserting the same status.
  This is the assertion the case exists for;
- `$t4 -ge $t3`, and the field is present on **every** session node, including one created with
  `session new --name virgin` that never set a status — for that one the value is within a few
  seconds of its creation, not `0` and not absent.

**Fails when:** the stamp in `ctlDispatch`'s `session.status` branch moves under an "only if
changed" guard, or `tree` starts omitting the field for the default status.

---

## `version` names the sandbox's pipe and the build that is running

**Guards:** `agwintermctl version` (agwinterm #221) reports the app serving the pipe from `ping`'s
reply. lite used to answer a hard-coded `agliteterm 0.1` whatever was running, so `version` would
have named a build that does not exist — and a QA run reads that line to know which binary it is
testing. Three `agwintermctl.exe` can coexist on a machine and none need be on `PATH`; the `cli`
half is agwinterm's business, the `app` half is lite's.

**Steps:** run the CLI **directly**, not through `Send-Ctl` (which forces `--json`), with the
caller's `AGWINTERM_*` variables cleared, and keep the exit code:

```powershell
$out  = & $ctl version --pipe $s.Pipe 2>&1 | Out-String
$code = $LASTEXITCODE
$ping = (ConvertFrom-Json (Send-Ctl $s @('ping'))).result
$ver  = (Select-String -Path installer\agliteterm.iss -Pattern '#define AppVersion "([^"]+)"').Matches[0].Groups[1].Value
```

**Expect:**
- `$code -eq 0`;
- two lines, one starting `cli ` and one starting `app `, in that order;
- the `app` line contains `\\.\pipe\qa1` — the sandbox's pipe, not the default `agliteterm` — and
  contains `$ping` verbatim;
- `$ping -eq "agliteterm $ver"` — the product and the version the build compiled in, which is the
  installer's `AppVersion`. Read it from the `.iss`, not from the exe's own About box: the point is
  that the app does not get to describe itself from a literal;
- `--json` against the same pipe parses with `app.available` `$true`, `app.version -eq $ping` and
  `app.pipe -eq 'qa1'`.

**Fails when:** `ping` goes back to a literal, or `build.ps1` stops compiling the installer's
version in.

**Cleanup:** `Stop-Sandbox $s`, always in a `finally`.
