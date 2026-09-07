# Control API — the honesty batch

`session overlay open --size-percent N`, `sidebar width N`, and the two popup verbs an agent loop
calls all day (`quick on`/`off`, `session overlay open`/`close`). lite's half of parity batch P2
(agwinterm #226, `qa/control-honesty.md` there is the sibling), with lite's own #24 riding along.
P5 (agwinterm #250) adds the pane slot — `session overlay open <cmd> --pane left|right` and the
reads on it (`result`, `copy`, `text`) — and the last case here is its picture: which surface each
read really answers about.

**The rule:** a call that answers `ok` did *what was asked*, and a call that will not do it answers
`ok:false` and leaves the world untouched. `test/control-honesty.ps1` pins every reply and every
"nothing changed" it can read from the world (window handles, client rects, the tree, the pane's
text); the cases here are the parts that need eyes — a popup that is visibly the size asked for, a
divider that visibly moved, and a window that visibly did **not** come over the one being typed
in.

Setup for every case: sandbox instance per `qa/product.md`. Every ctl call goes through `Send-Ctl`,
which clears the caller's `AGWINTERM_*` variables. The sidebar case writes a setting; it says so
and restores it.

```powershell
. test\ui-lib.ps1
$ctl = Get-CtlPath
$s   = Start-Sandbox -Exe (Resolve-Lite $null) -Ctl $ctl -Pipe 'qa1'

function Overlay([string[]]$rest) { Send-Ctl $s (@('session','overlay') + $rest) }
function Sidebar([string[]]$rest) { Send-Ctl $s (@('sidebar') + $rest) }
function Tree    { (ConvertFrom-Json (Send-Ctl $s @('tree'))).result }
function Active  { Tree | ForEach-Object workspaces | ForEach-Object sessions | Where-Object { $_.active } }
```

`--size-percent` as a strict number, `sidebar width N` as a set, and the `caller` field reached the
CLI in agwinterm #226. An older `agwintermctl` drops a non-number `--size-percent` silently and
sends `sidebar width 300` as a *read*; report the affected steps SKIP on such a client, never PASS.
`test/control-honesty.ps1` shows the probe (`sidebar width wide` refused client-side with "whole
number" is the post-#226 tell).

**Last run:** 2026-09-04, branch `feat/p2-lite-mirror` (build v0.17.14 from `./build.ps1`, at the
commit that fixes the empty overlay), agwinterm dev `agwintermctl` 1.0.0+5bd7033 (post-#226).
Captures with `PrintWindow(PW_RENDERFULLCONTENT)` — it shows the popup's content, so a popup that
captures **black** is an empty popup, which is what the first run of case 1 saw.
- *The popup is the size asked for*: the first run **found a bug** — the popup was the right size
  and empty, because `cmd /k` (any command with arguments) had been handed to the pty-host as an
  executable path and spawned nothing behind `overlay opened` (Guards, below). After the fix:
  PASS — 40 % gave a 433x256 client of the 1084x641 main client with the Clink banner and the
  echoed marker in it; 150 was refused with the same handle at the same rect; `resize 80` made the
  same handle 867x512; `closed` then `no overlay`; `resize` with nothing open refused.
- *The divider moved*: PASS — 300 moved the tree child 120 px and the active session's cols 112 →
  97 (−15 at the 8 px cell) with the `x` line wrapped beside the sidebar, nothing under it;
  `sideways`, `5` and `901` refused with a capture pixel-identical to step 2's; 240 set while
  hidden answered `applied:false` and was the width on `show`; 480 refused in the 484 px client
  ("would leave 0 px for the terminal … under the 20-column minimum (160 px at this font)") and
  applied in the 1084 px one. One observation, not this case's oracle: the status bar's grid text
  stayed at `102 × 49` throughout — it is refreshed only with the tree, filed as #25.
- *The window did NOT come to the front*: the automated form ran and passed (`test/control-honesty.ps1`,
  a holder window of the test's own process: the 20× `quick` loop and the 5× overlay loop never
  took the foreground; `window select` answered `not raised:` on this busy desktop and `selected`
  once given the foreground). The Notepad-and-eyes form was **not run** — it needs a person's hands
  off the keyboard for a minute and the machine was in use — so that half is a SKIP, not a pass.

---

## The popup is the size asked for

**Guards:** `session overlay open` read `args.size` while the CLI has always sent `size-percent`, so
every `--size-percent N` anyone ever passed to lite was ignored and the hard-coded 70 % popup opened
— and the call answered `ok`. The fix reads the right key and validates it 1..100; `resize` is new.
This case's first run (2026-09-04) caught a second lie the rect checks could not: `cmd /k` — any
command with arguments — was passed to the pty-host as an executable path, spawned nothing, and the
popup opened at the right size and **empty** behind `overlay opened`; the command now runs through
PowerShell `-NoExit -Command`, as `session new --command` does, and the suite reads the marker it
prints back out of the overlay session.
The automated check measures the popup's client rect against the main window's, which is the
number; this case is the picture, because the number a `GetClientRect` gives and the popup a person
sees can part ways (a popup drawn off-screen, a popup behind the main window, a second popup left
from the refused call) and only a capture shows that.

**Setup:** the sandbox at its fixed 1100x700. Note the main window's client size:
`[LiteUi]::GetClientRect` on `$s.Hwnd`, or `(ConvertFrom-Json (Send-Ctl $s @('window','state'))).result`
for `w`/`h` of the whole window.

**Steps:**
1. `Overlay @('open','cmd','/k','--size-percent','40')`. Wait ~1 s. Capture the **screen region of
   the main window** with `PrintWindow` on the popup — `FindWindowW('AgwintermLitePopup',
   'agliteterm — overlay')` is its handle (the class is shared with quick and scratch; the title tells
   them apart) — and note its rect with `GetWindowRect`.
2. `Overlay @('open','cmd','/k','--size-percent','150')`. Wait ~1 s. Find the popup again.
3. `Overlay @('resize','--size-percent','80')`. Wait ~1 s. Capture again.
4. `Overlay @('close')`, then `Overlay @('close')` once more.
5. `Overlay @('resize','--size-percent','50')` with nothing open.

**Expect:**
- after step 1: one popup, centred over the main window, whose client width and height are each
  40 % of the main window's client (±16 px) — visibly a **small** popup with a `cmd` prompt in it,
  not the old two-thirds one. The reply was `ok` with a status string;
- after step 2: the reply is `ok:false`, its `error` names `150` and `1..100`, and the popup is the
  **same handle at the same rect** — nothing opened, nothing moved, no second popup anywhere on the
  desktop;
- after step 3: the reply is `resized 80%`, and the popup — same handle — is now 80 % of the main
  client on each side; the capture shows it grew and stayed centred;
- step 4: `closed`, then `no overlay` — both `ok`; the popup is gone;
- step 5: `ok:false`, "no overlay to resize on that target; open one first".

**Fails when:** the dispatcher goes back to reading `args.size`; the clamp returns to
`openOverlay` (a `150` would then open at 95 % and answer `ok`); `resize` falls through to `open`
(a new handle appears in step 3); or the popup is created on a thread other than the UI thread's
posted message (the rect comes out at the previous size for one call).

**Cleanup:** `Overlay @('close')`.

---

## The divider moved

**Guards:** `sidebar width 300` used to **toggle the sidebar** and answer `ok` — the op table was
"`on`, `off`, anything else means toggle". The fix is an explicit table and a real `width`, and the
automated check reads the tree child's rect and the active session's `cols`. This case is for what
those two numbers cannot show: that the divider is where the reply says, that the terminal text
re-wrapped beside it rather than being painted under it, and that a refused op left the picture
identical.

**Setup:** **writes HKCU** `Software\agliteterm\SidebarW` and `ShowSidebar` — save both before
(`Get-ItemProperty`, they may be absent) and restore in a `finally`, absent values removed rather
than written as defaults. Then `Sidebar @('show')`, `Sidebar @('width','180')`, wait ~1 s, and type
a long line into the active session so there is text to watch re-wrap:
`Send-Ctl $s @('session','type', ('echo ' + ('x' * 200) + "`r"), '--target', (Active).id)`.

**Steps:**
1. Capture the main window (`PrintWindow`). Note `$c1 = (Active).cols`.
2. `Sidebar @('width','300')`. Wait ~1 s. Capture. Note `$c2 = (Active).cols`.
3. `Sidebar @('sideways')`. Wait ~1 s. Capture.
4. `Sidebar @('width','5')`, then `Sidebar @('width','901')`. Capture.
5. `Sidebar @('hide')`, `Sidebar @('width','240')`, `Sidebar @('show')`. Wait ~1 s. Capture.
6. Shrink the sandbox to a narrow window — `SetWindowPos` on `$s.Hwnd` to 500 px wide (its own
   window, no global input) — wait, then `Sidebar @('width','480')`. Capture. Widen it back to
   1100 and repeat the same call.

**Expect:**
- step 2: the reply is `{width:300, visible:true, applied:true}`; the capture shows the splitter
  120 px further right than in step 1, the tree wider, and the `xxx…` line wrapped at a **narrower**
  column — `$c2 - $c1` is about `-120 / cellWidth` (15 columns at an 8 px cell) — with no text
  painted under the sidebar;
- step 3: `ok:false` naming `sideways` and the five ops (`show|hide|toggle|state|width`), and the
  capture is **pixel-identical** to step 2's: the sidebar did not flip, the divider did not move;
- step 4: both `ok:false`, each naming the value and `90..900`; still identical to step 2's capture;
- step 5: the set while hidden answers `applied:false` with a note; the capture after `show` has
  the divider at 240 — the remembered width took effect on `show`, and `sidebar width` reads 240;
- step 6: in the 500 px window the reply is `ok:false` and says how many pixels `480` would leave
  for the terminal and that it is under the 20-column minimum; the divider stayed put and the pane
  still shows at least 20 columns of the `x` line. In the 1100 px window the same `480` is `ok` and
  applied.

**Fails when:** `wantOn` comes back for this verb (step 3 flips the sidebar); the range refusal
starts clamping (step 4 moves the divider to 90 or 900); the set calls `relayout()` from the pipe
thread instead of posting (the picture updates late or the window hangs); or the 20-column check is
dropped (step 6 in the narrow window gives the terminal 2 columns — this is #23's trigger).

**Cleanup:** `Sidebar @('width','180')`, then the registry restore in `finally`.

---

## The window did NOT come to the front while an agent loop ran

**Guards:** lite's own #24. Every popup path — `quick on`, `quick off`, `session overlay open`,
the popup's close — called `SetForegroundWindow` unguarded, and Windows *grants* a background
process the foreground once the user's input has been quiet for the foreground-lock timeout, which
is exactly when an agent loop runs: the window kept popping over whatever Boris was typing in. The
fix raises only when this process already holds the foreground (a hand-off between lite and its
own popup) and flashes the taskbar button otherwise; `window select`, whose purpose is the raise,
still tries and **says whether Windows granted it**. The automated check holds the foreground with a
window of the test's own process and samples `GetForegroundWindow` after every call. This case is
the one that needs a person: a real app in front, real hands off the keyboard for the loop, and the
eyes that see whether lite came up — or only its taskbar button blinked.

**Setup:** the sandbox up. Open a **real other app** — Notepad is fine — and click into it so it
holds the foreground and the caret. Keep the sandbox window *visible* on the desktop beside it (not
behind Notepad), so a raise would be seen and a non-raise is not hidden by z-order. Record which
window is in front: `[LiteUi]::GetForegroundWindow()` (or the `PidOf` helper in
`test/control-honesty.ps1`) should be Notepad's.

**Steps:**
1. Hands off. From a *third* place (the QA runner's own pane, which must not be the foreground
   either — start the loop with a 5 s delay and click into Notepad during it), run twenty times:
   `Send-Ctl $s @('quick','on')`, wait 150 ms, `Send-Ctl $s @('quick','off')`, wait 150 ms. Watch.
2. Then five times: `Overlay @('open','cmd','/k')`, wait 300 ms, `Overlay @('close')`, wait 300 ms.
   Watch.
3. Type a few characters into Notepad, then immediately `Send-Ctl $s @('window','select','qa1')`
   and note the reply and where the foreground is.
4. Now click the **sandbox** window so lite holds the foreground, and repeat `window select qa1`.
5. Leave lite in front; `Send-Ctl $s @('quick','on')`, then `Send-Ctl $s @('quick','off')`.

**Expect:**
- steps 1–2: the quick popup and the overlay **appear** each time (owned windows sit above their
  owner even without activation) and disappear again, and Notepad's caret **never stops blinking**
  — the foreground stays with Notepad the whole time. lite's taskbar button flashes (amber) on
  the first `quick on`, and after the loop `GetForegroundWindow()` is still Notepad's handle. If
  lite came to the front even once, the case fails;
- step 3: because someone typed a moment ago, Windows refuses the raise: the reply is `ok` with a
  result starting `not raised:` — it says the window was "not brought to the front" and that the
  raise was "refused" — and the foreground is still Notepad. Still `ok`, because the window exists
  and the request was made: that is the shape the cross-product contract pins, and the full app
  answers `selected` there unconditionally; lite answers `selected` only when it is true. (On an
  idle desktop — nothing typed for a few seconds — Windows grants it instead, the reply is
  `selected`, and lite is in front: both branches are correct as long as the **reply matches where
  the foreground actually went**; that agreement is the case.)
- step 4: `selected`, and lite stays in front — a raise of the window that already holds the
  foreground is always allowed;
- step 5: the quick popup comes up **focused** (lite held the foreground, so the hand-off to its
  own popup is made — `quick on` from the keyboard still behaves as before), and on `quick off`
  the main window is in front again with no flash.

**Fails when:** `raiseIfAllowed` / `showPopupRaised` lose the foreground-process check; a popup is
shown with `SW_SHOW` when the foreground is elsewhere (activation is a second road to the
foreground, under the same idle-timeout rule — the popup would come up focused and Notepad's caret
would stop); the popup's `WM_CLOSE`/`WM_DESTROY` regain their `SetForegroundWindow(g_hwnd)`; or
`window select` goes back to answering `selected` unconditionally (step 3's reply would disagree
with the foreground).

**Cleanup:** close Notepad; `Stop-Sandbox $s`, always in a `finally`.

---

## `overlay text` reads the overlay; `session text --target <pane>` reads the shell under it

**Guards:** the surface rule of P5-lite (`docs/plans/completed/2026-09-07-p5-lite-mirror.md`, the vocabulary
section): while a pane overlay is open, `--target active` on the focused pane (on a SURFACE verb —
`text`, `type`, `copy`; a session verb's `active` is the session under it, a pane verb's the pane's
shell, revmux r1) and the
overlay's own id reach the OVERLAY, and the pane's own id reaches the shell UNDERNEATH. The first run of the
automated block found the reader lying about both: `dumpBufferRange` read `paintPane`'s snapshot of
the grid, which is refreshed only when THAT session is painted, so a shell under an overlay answered
its last painted screen as `ok` and an overlay on a session not on screen answered empty as `ok`.
The reader now reads the emulator's live grid. `test/control-honesty.ps1` pins the three reads
against markers; this case is the eyes: that what `overlay text` returns is what the right box
SHOWS, and what `session text --target <pane>` returns is what the box shows once the overlay is
closed — a command typed into the covered shell really ran there, unseen.

**Setup:** the sandbox, one session, `session split on`; note the session id `$sid` and the split
shell's id `$sp` (the reply). Every ctl call through `Send-Ctl`.

**Steps:**
1. `Overlay @('open','echo P5-HONEST-OV;','Start-Sleep','300','--pane','right','--target',$sid)`;
   keep the reply as `$ov`. Wait ~2 s.
2. `Send-Ctl $s @('session','type',"echo P5-HONEST-UNDER`r",'--target',$sp)` — the shell under the
   overlay, by its own id. Wait ~1 s.
3. Read four ways: `Overlay @('text','--pane','right','--target',$sid)`;
   `Send-Ctl $s @('session','text','--target',$ov)`; `Send-Ctl $s @('session','text','--target',$sp)`;
   `Send-Ctl $s @('session','focus','right')` then `Send-Ctl $s @('session','text')`.
4. `Overlay @('text','--pane','right','--lines','2','--target',$sid)`.
5. Capture the main window with `PrintWindow`.
6. `Overlay @('close','--pane','right','--target',$sid)`. Wait ~1 s. `Send-Ctl $s @('session','text','--target',$sp)`;
   `Overlay @('text','--pane','right','--target',$sid)`. Capture again.

**Expect:**
- step 3: `overlay text` answers `{"text": …}` and its `text` equals the overlay id's `session text`
  byte for byte; both hold `P5-HONEST-OV` and NOT `P5-HONEST-UNDER`. The split shell's id holds
  `P5-HONEST-UNDER` and NOT `P5-HONEST-OV`. The bare `session text` with slot 1 focused is the
  overlay's text (the surface), not the shell's;
- step 4: exactly two lines, the last two of the overlay's buffer (its marker and what follows);
- step 5: the RIGHT box shows `P5-HONEST-OV`, no `P5-HONEST-UNDER`
  anywhere in the window, the `overlay` badge in the right box's corner; the left box its own prompt;
- step 6: `closed`. The split shell's id now reads `P5-HONEST-UNDER` at its prompt — the command
  typed while covered ran in the shell underneath — and the second capture shows exactly that in
  the right box, the badge gone. `overlay text --pane right` is refused `no overlay: --pane right
  names which slot, and nothing is open in it` (`ok:false`, not an empty `text`).

**Fails when:** `readSurfaceText` goes back to the painted snapshot (step 3's shell read is stale
after the split's relayout, or the overlay reads empty); `resolveTarget` answers `surfaceOf` for a
pane id (the shell can no longer be read while covered); `focusedSession()` stops returning the
surface (step 3's bare read is the shell); or an empty slot's `text` answers `ok` with `""`.

**Last run:** 2026-09-07, branch `feat/p5-lite-mirror`, dev `agwintermctl` (post-#250): the four
reads and the two captures are what `qa/fixtures/pane-overlay.ps1` drives (its markers are the
panes case's; the covered-shell read is `session text --target <split id>` holding its prompt and
not the overlay's marker), PASS; the capture is `docs/img/qa-p5-pane-overlay.png`.
