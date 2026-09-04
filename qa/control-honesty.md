# Control API — the honesty batch

`session overlay open --size-percent N`, `sidebar width N`, and the two popup verbs an agent loop
calls all day (`quick on`/`off`, `session overlay open`/`close`). lite's half of parity batch P2
(agwinterm #226, `qa/control-honesty.md` there is the sibling), with lite's own #24 riding along.

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

**Last run:** not yet — Task 8 of `docs/plans/2026-09-04-p2-lite-mirror.md` runs these against the
branch build with agwinterm's post-#226 `agwintermctl`; record the date, the build and the client
here when it does.

---

## The popup is the size asked for

**Guards:** `session overlay open` read `args.size` while the CLI has always sent `size-percent`, so
every `--size-percent N` anyone ever passed to lite was ignored and the hard-coded 70 % popup opened
— and the call answered `ok`. The fix reads the right key and validates it 1..100; `resize` is new.
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
