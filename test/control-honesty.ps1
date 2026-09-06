# Control API — the honesty batch (P2-lite): a call that answers `ok` does what was asked, and a
# call that will not do what was asked answers `ok:false` and leaves the world untouched.
#
# Every refusal here is asserted TWICE: the reply, and that nothing changed. "Nothing changed" is
# read from the world, not from the reply — the overlay popup's window handle and client rect,
# the tree, the pane's text — because a refusal that quietly did the thing anyway is the exact
# defect this batch exists to end. And every oracle is proved non-vacuous first: the popup finder
# has to find a popup that IS open before "no popup appeared" is allowed to mean anything.
#
# Driven through the REAL agwintermctl against a sandbox instance, under test/ui-lib.ps1's rules:
# --pipe <name>, a throwaway %LOCALAPPDATA%, nothing injected globally. Where a check needs the
# CLI's post-#226 behaviour (a client-side refusal of `--size-percent sixty`), the client is probed
# first and the check SKIPs on an older client (fails under -Strict) — the P1-lite pattern.
# Server-side decoding is checked through lite's OWN pipe with raw JSON lines, so the decoder is
# pinned independently of what any client happens to send.
param(
    [string]$Exe = "$PSScriptRoot\..\bin\agliteterm.exe",
    # CI passes -Strict: a suite that skips is reporting success while checking nothing.
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$fail = 0
$skipped = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "  PASS  $name" }
    else { $script:fail++; "  FAIL  $name$(if ($detail) { " — $detail" })" }
}
function Skip([string]$name, [string]$why) { $script:skipped++; "  SKIP  $name — $why" }

"== control-honesty =="

. "$PSScriptRoot\ui-lib.ps1"
$ctl = Get-CtlPath
if (-not $ctl) { "  SKIP  agwintermctl not found (set AGWINTERMCTL)"; exit ($Strict ? 1 : 0) }
$exe = Resolve-Lite $Exe
if (-not $exe) { "  SKIP  no build at $Exe"; exit ($Strict ? 1 : 0) }
"  using: $ctl"

# The client probe. agwinterm #226 made the CLI refuse an unparseable --size-percent on its own
# side (exit 2, "needs a whole number"), before any pipe is opened; the 0.17.x client DROPS the
# flag instead and the server sees no size at all. The probe never needs a pipe either way.
$probe = (& $ctl session overlay open x --size-percent sixty --pipe 'honesty-probe' --json 2>&1) -join ''
$cliRefusesNonNumber = $probe -match 'whole number'
# The same probe for `sidebar width N`: a post-#226 client refuses `sidebar width wide` on its own
# side; the 0.17.x client has no width argument at all and sends `sidebar width 300` as a READ
# (op=width, the number dropped), which would make a set look like a read that happened to pass.
$probe = (& $ctl sidebar width wide --pipe 'honesty-probe' --json 2>&1) -join ''
$cliHasSidebarWidth = $probe -match 'whole number'
# And for `session type --stdin`: a post-#226 client refuses `--stdin` beside positional text on its
# own side ("one source for the text, not two"), before any pipe; the 0.17.x client has no such
# flag, takes it as a boolean and goes to the pipe with the positional.
$probe = ('x' | & $ctl session type --stdin positional --pipe 'honesty-probe' --json 2>&1) -join ''
$cliHasStdin = $probe -match 'one source'
# And for P3 (`session context`, `restore capture`): a post-#233 client answers `agwintermctl restore`
# with its usage line before any pipe; the 0.17.x client has no `restore` command at all and says
# `unknown command`. A pre-P3 client would send `session context` as an unknown session command
# client-side too, so the whole P3 block SKIPs on it rather than fail on the client's own refusal.
$probe = (& $ctl restore --pipe 'honesty-probe' --json 2>&1) -join ''
$cliHasP3 = $probe -match 'usage: agwintermctl restore'
# And for P4 (`session split --axis`, `session split close`, `session swap`, `session focus`;
# agwinterm #238, contract #240): a post-#238 client refuses `session swap <positional>` on its own
# side ("Nothing sent") before any pipe is opened; the 0.17.12 client has no `swap` at all and says
# `unknown session command`. A pre-P4 client would drop --axis and send `session focus` as an
# unknown command client-side, so the whole P4 block SKIPs on it rather than fail on the client.
$probe = (& $ctl session swap x --pipe 'honesty-probe' --json 2>&1) -join ''
$cliHasP4 = $probe -match 'Nothing sent'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LiteHonesty {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public POINT pt; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool PeekMessageW(out MSG m, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr DispatchMessageW(ref MSG m);
    // The "other app" for the #24 checks: a plain top-level window of THIS process (a STATIC control
    // needs no window procedure of its own), placed to the right of the sandbox.
    public static IntPtr MakeHolder(string title) {
        return CreateWindowExW(0, "STATIC", title, 0x10CF0000 /* WS_OVERLAPPEDWINDOW | WS_VISIBLE */, 900, 100, 320, 200, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }
    public static void Pump() { MSG m; while (PeekMessageW(out m, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref m); DispatchMessageW(ref m); } }
    public static uint PidOf(IntPtr h) { uint pid = 0; if (h != IntPtr.Zero) GetWindowThreadProcessId(h, out pid); return pid; }
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    // Give `h` (a window of this process) the foreground. A plain SetForegroundWindow is refused
    // when another process holds the foreground and the user has typed recently; attaching this
    // thread's input queue to the foreground thread's (the clipboard suite's trick) makes the
    // request come from the queue that owns the foreground, which is what a user's own click does.
    // Returns whether the foreground is h afterwards.
    public static bool TakeForeground(IntPtr h) {
        if (SetForegroundWindow(h) && GetForegroundWindow() == h) return true;
        IntPtr fg = GetForegroundWindow();
        uint pid; uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out pid);
        uint me = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
        try { BringWindowToTop(h); SetForegroundWindow(h); }
        finally { if (attached) AttachThreadInput(me, fgThread, false); }
        return GetForegroundWindow() == h;
    }
}
'@

# lite's popups share one window class; the overlay is told apart by its title. The dash is built
# from its code point so the check does not depend on how this file was decoded.
$overlayTitle = 'agliteterm ' + [char]0x2014 + ' overlay'
function OverlayHwnd { [LiteHonesty]::FindWindowW('AgwintermLitePopup', $overlayTitle) }
function Wait-Overlay([bool]$present, [int]$ms = 4000) {
    for ($i = 0; $i -lt ($ms / 100); $i++) {
        $h = OverlayHwnd
        if ($present -and $h -ne [IntPtr]::Zero) { return $h }
        if (-not $present -and $h -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        Start-Sleep -Milliseconds 100
    }
    return (OverlayHwnd)
}
function ClientSize([IntPtr]$h) {
    $r = New-Object LiteHonesty+RECT
    [void][LiteHonesty]::GetClientRect($h, [ref]$r)
    return @(($r.Right - $r.Left), ($r.Bottom - $r.Top))
}
# Wait for the popup's client width to reach $want (±$tol), for a resize that the UI thread applies
# from a posted message after the reply is written.
function Wait-ClientWidth([IntPtr]$h, [int]$want, [int]$tol, [int]$ms = 3000) {
    for ($i = 0; $i -lt ($ms / 100); $i++) {
        $w = (ClientSize $h)[0]
        if ([math]::Abs($w - $want) -le $tol) { return $w }
        Start-Sleep -Milliseconds 100
    }
    return (ClientSize $h)[0]
}
# One cell of tolerance in pixels. The popup is sized from the main window's CLIENT rect through
# AdjustWindowRectEx, so the expected mismatch is 0; the tolerance covers a frame metric rounding.
$tol = 16

$s = $null
function Overlay([string[]]$rest) { Send-Ctl $s (@('session', 'overlay') + $rest) }
function Tree { (ConvertFrom-Json (Send-Ctl $s @('tree'))).result }
function Nodes { Tree | ForEach-Object workspaces | ForEach-Object sessions }
# A raw newline-JSON request on lite's own pipe: what the server's decoder does with a value the
# CLI would never send (a JSON string, a float, a boolean) is a lite fact, and only a raw line
# can pin it.
function Send-Raw([string]$json) {
    $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $s.Pipe, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $c.Connect(3000)
        $enc = New-Object System.Text.UTF8Encoding($false)
        $w = New-Object System.IO.StreamWriter($c, $enc)
        $w.AutoFlush = $true
        $w.Write($json + "`n")
        $r = New-Object System.IO.StreamReader($c, $enc)
        return $r.ReadLine()
    } finally { $c.Dispose() }
}

# HKCU is NOT isolated by the sandbox (ui-lib's rules): the instance loads SidebarW/ShowSidebar
# from the real profile and every set, hide and show below writes them back. Both are saved here
# and put back in `finally`, whatever the checks did with them — and a value that was absent is
# removed again, not written as a default.
$regKey = 'HKCU:\Software\agliteterm'
# Key_Close too (P4): the close-chord checks bind it to Ctrl+Shift+W for this run only — keys are
# read once at launch, so it is seeded before the sandbox starts and put back (or removed) after.
$regSaved = @{}
foreach ($n in 'SidebarW', 'ShowSidebar', 'Key_Close') {
    $regSaved[$n] = if (Test-Path $regKey) { (Get-ItemProperty -Path $regKey -Name $n -ErrorAction SilentlyContinue).$n } else { $null }
}
function Restore-Reg {
    foreach ($n in 'SidebarW', 'ShowSidebar', 'Key_Close') {
        if ($null -ne $regSaved[$n]) { New-ItemProperty -Path $regKey -Name $n -Value ([int]$regSaved[$n]) -PropertyType DWord -Force | Out-Null }
        elseif (Test-Path $regKey) { Remove-ItemProperty -Path $regKey -Name $n -ErrorAction SilentlyContinue }
    }
}

try {
    if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
    New-ItemProperty -Path $regKey -Name Key_Close -Value 0x0357 -PropertyType DWord -Force | Out-Null   # 'W' | (CONTROL|SHIFT) << 8
    $s = Start-Sandbox -Exe $exe -Ctl $ctl -Pipe 'ctlhonesty'
    $sid = [string](Nodes | Select-Object -First 1).id
    if (-not $sid) { throw 'the sandbox has no session' }
    $mainClient = ClientSize $s.Hwnd
    Check 'the sandbox window has a client area to size against' ($mainClient[0] -gt 400 -and $mainClient[1] -gt 300) "client $($mainClient -join 'x')"

    # ---- session.overlay ------------------------------------------------------------------------
    "-- session.overlay --"
    Check 'no overlay popup exists at the start' ((OverlayHwnd) -eq [IntPtr]::Zero)

    # The positive control FIRST, so the finder is proved before any "nothing appeared" below.
    # `cmd /k` keeps a prompt up, so the popup stays open for as long as the checks need it - and
    # the command RUNS: the overlay session's id arrives as a `session`/`created` event (the
    # session is hidden from `tree`) and its text carries what the command printed. A command
    # with arguments used to be handed to the pty-host as an executable path, spawn nothing, and
    # leave an EMPTY popup behind an "overlay opened" (found by the QA case, P2-lite task 8).
    $ovMarker = 'overlay-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $cursor = [long](ConvertFrom-Json (Send-Ctl $s @('events'))).result.cursor
    $raw = Overlay @('open', 'cmd', '/k', "echo $ovMarker", '--size-percent', '40')
    $r = ConvertFrom-Json $raw
    Check 'open --size-percent 40 answers ok with a status string naming the percentage in effect' `
        ([bool]$r.ok -and $r.result -is [string] -and [string]$r.result -match '^overlay opened at \d+%$') "raw: $raw"
    $h40 = Wait-Overlay $true
    Check 'and a popup titled "agliteterm - overlay" appeared' ($h40 -ne [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $ovId = ''
    for ($i = 0; $i -lt 30 -and -not $ovId; $i++) {
        $ovId = [string](@((ConvertFrom-Json (Send-Ctl $s @('events', '--since', "$cursor"))).result.events | Where-Object { $_.type -eq 'session' -and $_.info -eq 'created' }) | Select-Object -Last 1).session
        if (-not $ovId) { Start-Sleep -Milliseconds 200 }
    }
    Check 'and the overlay session was created (its id arrived as a session/created event)' ([bool]$ovId) "events since $cursor`: $(Send-Ctl $s @('events', '--since', "$cursor"))"
    $ovSeen = $false
    for ($i = 0; $i -lt 50 -and -not $ovSeen; $i++) { if (([string](Get-PaneText $s $ovId)).Contains($ovMarker)) { $ovSeen = $true } else { Start-Sleep -Milliseconds 200 } }
    Check 'and the command RAN in it: `cmd /k echo <marker>` printed the marker into the overlay session' $ovSeen "overlay text: $(Get-PaneText $s $ovId)"
    $want40 = [int]($mainClient[0] * 0.4)
    $got = (ClientSize $h40)[0]
    Check "the popup's client width is 40% of the main window's (not the hard-coded 70%)" ([math]::Abs($got - $want40) -le $tol) "main client $($mainClient[0]), want ~$want40, got $got"
    $wantH40 = [int]($mainClient[1] * 0.4)
    $gotH = (ClientSize $h40)[1]
    Check 'and its client height is 40% too' ([math]::Abs($gotH - $wantH40) -le $tol) "main client height $($mainClient[1]), want ~$wantH40, got $gotH"

    # --- --size-percent is validated, not clamped, and a refusal touches nothing ---------------
    # With an overlay OPEN the oracle is strong: `open` replaces the popup, so an open that slipped
    # through would show up as a NEW handle (or a moved rect); the same handle with the same size
    # means nothing happened.
    $size40 = ClientSize $h40
    foreach ($bad in '0', '-5', '150') {
        $raw = Overlay @('open', 'cmd', '/k', '--size-percent', $bad)
        $r = ConvertFrom-Json $raw
        Check "--size-percent $bad is refused (ok:false)" (-not $r.ok) "raw: $raw"
        Check "and the refusal names the value and the range" ([string]$r.error -match [regex]::Escape($bad) -and [string]$r.error -match '1\.\.100') "error: $($r.error)"
        Start-Sleep -Milliseconds 700
        $now = OverlayHwnd
        Check "and the open popup is the same one, untouched" ($now -eq $h40 -and ((ClientSize $now) -join 'x') -eq ($size40 -join 'x')) "was $h40 $($size40 -join 'x'), now $now $((ClientSize $now) -join 'x')"
    }
    # A percentage under the 30x8-cell popup minimum: the popup cannot be that small, so the
    # minimum decides the size and the REPLY SAYS WHICH percentage is in effect. It used to echo
    # the number asked for while opening something several times bigger — the deleted clamp wearing
    # a different hat (revmux r1). Not a refusal: the shared contract runs `--size-percent 40` and
    # expects ok, and on a small window 40 is itself under the minimum; refusing would make lite
    # answer ok:false where agwinterm (a cover with no window frame) answers ok.
    $rawTiny = Overlay @('resize', '--size-percent', '1')
    $rTiny = ConvertFrom-Json $rawTiny
    Check '--size-percent 1 is accepted (a popup that small cannot exist; the minimum decides)' ([bool]$rTiny.ok) "raw: $rawTiny"
    Check 'and the reply reports the percentage IN EFFECT, not the 1 that was asked for' `
        ([string]$rTiny.result -match '^resized (\d+)%$' -and [int]$Matches[1] -gt 1) "result: $($rTiny.result)"
    $effPct = [int]$Matches[1]
    Start-Sleep -Milliseconds 900
    $gotMin = (ClientSize (OverlayHwnd))[0]
    $wantMin = [int]($mainClient[0] * $effPct / 100)
    Check 'and the popup really is the size the reply named' ([math]::Abs($gotMin - $wantMin) -le ([math]::Max($tol, 12))) "reported $effPct% (~$wantMin px), got $gotMin px"
    $raw = Overlay @('resize', '--size-percent', '40')   # back to the size the rest of the block assumes
    Wait-ClientWidth $h40 $size40[0] $tol | Out-Null

    if ($cliRefusesNonNumber) {
        # The client's half: a non-number never reaches the pipe. Run directly (not through Send-Ctl)
        # because the exit code and stderr ARE the check.
        foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
        $out = (& $ctl session overlay open cmd /k --size-percent sixty --pipe $s.Pipe --json 2>&1) -join ''
        $code = $LASTEXITCODE
        Check '--size-percent sixty is refused by the client, non-zero exit' ($code -ne 0 -and $out -match 'whole number') "exit $code, output: $out"
        Start-Sleep -Milliseconds 700
        Check 'and the open popup is the same one, untouched' ((OverlayHwnd) -eq $h40 -and ((ClientSize $h40) -join 'x') -eq ($size40 -join 'x'))
    } else {
        Skip '--size-percent sixty is refused by the client' 'this agwintermctl predates agwinterm #226 and drops a non-number silently - set AGWINTERMCTL to a newer build'
    }

    # --- resize moves the popup that is open, and reports the N asked for ----------------------
    $raw = Overlay @('resize', '--size-percent', '80')
    $r = ConvertFrom-Json $raw
    Check 'resize --size-percent 80 answers ok "resized 80%"' ([bool]$r.ok -and [string]$r.result -eq 'resized 80%') "raw: $raw"
    $want80 = [int]($mainClient[0] * 0.8)
    $got = Wait-ClientWidth $h40 $want80 $tol
    Check "and the popup's client width became 80% of the main window's" ([math]::Abs($got - $want80) -le $tol) "want ~$want80, got $got"
    Check 'the same popup, not a replacement' ((OverlayHwnd) -eq $h40)
    # 100 is the whole client area — the old min(0.95) clamp would have stopped short of it.
    $raw = Overlay @('resize', '--size-percent', '100')
    $r = ConvertFrom-Json $raw
    Check 'resize --size-percent 100 is accepted' ([bool]$r.ok -and [string]$r.result -eq 'resized 100%') "raw: $raw"
    $got = Wait-ClientWidth $h40 $mainClient[0] $tol
    Check "100 means the WHOLE client area, not 95% of it" ([math]::Abs($got - $mainClient[0]) -le $tol -and [math]::Abs((ClientSize $h40)[1] - $mainClient[1]) -le $tol) "main $($mainClient -join 'x'), popup $((ClientSize $h40) -join 'x')"
    # No flag: the default, and the reply says which value is in effect rather than echoing nothing.
    $raw = Overlay @('resize')
    $r = ConvertFrom-Json $raw
    Check 'resize with no flag answers with the default in effect ("resized 70%")' ([bool]$r.ok -and [string]$r.result -eq 'resized 70%') "raw: $raw"
    $want70 = [int]($mainClient[0] * 0.7)
    $got = Wait-ClientWidth $h40 $want70 $tol
    Check "and the popup is back at lite's 70% default" ([math]::Abs($got - $want70) -le $tol) "want ~$want70, got $got"
    $size70 = ClientSize $h40

    # The absent-flag path posts the number it REPORTS. Shrink the main window until the 30x8-cell
    # popup minimum is ABOVE 70 %, then resize with NO flag: the reply must name the raised
    # percentage and the popup must be that percentage on BOTH axes. Before this, the reply was
    # raised while the posted request carried 0, so openOverlay re-derived 70 % and only the binding
    # axis got the floor - a reply of "80%" for a popup 80 % wide and 70 % tall (revmux r3/r4).
    #
    # The width is DERIVED, not hard-coded: the reported minimum is ceil(30 * cellW * 100 / clientW),
    # so it lands in 71..100 only while clientW is between 30 and ~42.8 cells. A fixed 300 px sits
    # in that band for an 8 px cell and outside it for the shipped 10 px bitmap default, which made
    # this case skip - and a skip fails -Strict, so CI went red on a font metric (revmux r5). The
    # cell comes from the content region the session already has, the way the sidebar block does it,
    # and the target is 36 cells: the middle of the band for any cell size.
    $mainBefore = ClientSize $s.Hwnd
    # Inlined, not the ActiveCols / Sidebar helpers: those are defined further down the file, and a
    # PowerShell function does not exist until its definition has been executed.
    $colsNow = [int](Nodes | Where-Object { $_.active } | Select-Object -First 1).cols
    # The sidebar's SPAN, not its width: sidebarSpan() is 0 when the sidebar is hidden, and this
    # block runs before the suite normalises ShowSidebar - the sandbox inherits it from the real
    # profile, which ui-lib warns is not isolated. Subtracting a remembered width from a client that
    # does not have a sidebar in it gave a cell size that was wrong by ~25 %, and the hard Check
    # below then failed on inherited state rather than on the implementation (revmux r6).
    $sb = (ConvertFrom-Json (Send-Ctl $s @('sidebar', 'width'))).result
    $sbNow = if ($sb.visible) { [int]$sb.width + 5 } else { 0 }
    $cellW = if ($colsNow -gt 0) { ($mainBefore[0] - $sbNow) / [double]$colsNow } else { 0 }
    $frameW = 0   # window outer minus client, measured from the resize itself below
    if ($cellW -ge 4) {
        $wantClient = [int]([math]::Round(36 * $cellW))
        foreach ($attempt in 1..3) {
            $null = Send-Ctl $s @('window', 'resize', '--w', "$($wantClient + $frameW)", '--h', '780')
            Start-Sleep -Milliseconds 900
            $small = ClientSize $s.Hwnd
            $frameW = ($wantClient + $frameW) - $small[0]      # the frame, now measured
            if ([math]::Abs($small[0] - $wantClient) -le 4) { break }
        }
        $small = ClientSize $s.Hwnd
        $rawS = Overlay @('resize')
        $rS = ConvertFrom-Json $rawS
        Check 'a no-flag resize in a narrow window is accepted' ([bool]$rS.ok) "raw: $rawS"
        Check "and it reports a RAISED percentage, not lite's 70% default (client $($small -join 'x'), cell ~$([int]$cellW)px)" `
            ([string]$rS.result -match '^resized (\d+)%$' -and [int]$Matches[1] -gt 70) "result: $($rS.result)"
        if ([string]$rS.result -match '^resized (\d+)%$' -and [int]$Matches[1] -gt 70) {
            $pct = [int]$Matches[1]
            Start-Sleep -Milliseconds 900
            $pop = ClientSize (OverlayHwnd)
            $wantW = [int]($small[0] * $pct / 100); $wantH = [int]($small[1] * $pct / 100)
            Check 'and the popup is that percentage on BOTH axes, not 70% on the other one' `
                ([math]::Abs($pop[0] - $wantW) -le ([math]::Max($tol, 14)) -and [math]::Abs($pop[1] - $wantH) -le ([math]::Max($tol, 30))) `
                "reported $pct% of $($small -join 'x') (~$wantW x $wantH), popup $($pop -join 'x')"
        }
        Send-Ctl $s @('window', 'resize', '--w', "$($mainBefore[0] + $frameW)", '--h', "$($mainBefore[1] + 40)") | Out-Null
        Start-Sleep -Milliseconds 900
        $mainClient = ClientSize $s.Hwnd     # the outer size went in; the client that came back is what counts
    } else {
        Check 'the content region publishes a usable cell size for the narrow-window case' $false "cols $colsNow, client $($mainBefore -join 'x'), sidebar $sbNow"
    }
    $raw = Overlay @('resize', '--size-percent', '70')
    Wait-ClientWidth $h40 ([int]($mainClient[0] * 0.7)) $tol | Out-Null
    $size70 = ClientSize $h40

    $raw = Overlay @('resize', '--size-percent', '150')
    $r = ConvertFrom-Json $raw
    Check 'resize --size-percent 150 is refused' (-not $r.ok -and [string]$r.error -match '150' -and [string]$r.error -match '1\.\.100') "raw: $raw"
    Start-Sleep -Milliseconds 700
    Check 'and the popup did not move' (((ClientSize $h40) -join 'x') -eq ($size70 -join 'x')) "was $($size70 -join 'x'), now $((ClientSize $h40) -join 'x')"

    # --- open needs a command; the command is checked before the target --------------------------
    $raw = Overlay @('open')
    $r = ConvertFrom-Json $raw
    Check 'open with no command is refused' (-not $r.ok -and [string]$r.error -match 'needs a command' -and [string]$r.error -match 'nothing opened') "raw: $raw"
    Start-Sleep -Milliseconds 700
    Check 'and the open popup is the same one (no plain shell replaced it)' ((OverlayHwnd) -eq $h40 -and ((ClientSize $h40) -join 'x') -eq ($size70 -join 'x'))
    $raw = Overlay @('open', '--target', 'no-such-session')
    $r = ConvertFrom-Json $raw
    Check 'open with no command AND a bad target is refused for the command (checked first)' (-not $r.ok -and [string]$r.error -match 'needs a command') "raw: $raw"

    # --- a named target that resolves to nothing is refused for open, resize and close alike -----
    $noSession = 'no session matches that target; nothing opened, resized or closed'
    foreach ($act in @(@('open', 'cmd', '/k'), @('resize', '--size-percent', '50'), @('close'))) {
        $raw = Overlay ($act + @('--target', 'no-such-session'))
        $r = ConvertFrom-Json $raw
        Check "$($act[0]) --target no-such-session is refused with the shared wording" (-not $r.ok -and [string]$r.error -eq $noSession) "raw: $raw"
    }
    Start-Sleep -Milliseconds 700
    Check 'and the popup survived all three, unchanged' ((OverlayHwnd) -eq $h40 -and ((ClientSize $h40) -join 'x') -eq ($size70 -join 'x')) "hwnd $(OverlayHwnd) vs $h40, size $((ClientSize $h40) -join 'x')"
    # A target that DOES resolve is accepted whichever session it names: lite's overlay is one
    # popup over the main window, not a per-session cover. Pinned so the difference from agwinterm
    # is a written-down fact, not an accident.
    $raw = Overlay @('resize', '--size-percent', '60', '--target', $sid)
    $r = ConvertFrom-Json $raw
    Check 'resize --target <a real session> is accepted' ([bool]$r.ok -and [string]$r.result -eq 'resized 60%') "raw: $raw"
    $got = Wait-ClientWidth $h40 ([int]($mainClient[0] * 0.6)) $tol
    Check 'and applied' ([math]::Abs($got - [int]($mainClient[0] * 0.6)) -le $tol) "got $got"

    # --- an unknown action is refused and names the three; it used to OPEN ----------------------
    $raw = Overlay @('sideways')
    $r = ConvertFrom-Json $raw
    Check 'an unknown action is refused, naming open, close and resize' (-not $r.ok -and [string]$r.error -match 'sideways' -and [string]$r.error -match 'open' -and [string]$r.error -match 'close' -and [string]$r.error -match 'resize') "raw: $raw"
    Start-Sleep -Milliseconds 700
    Check 'and it did not open (or replace) anything' ((OverlayHwnd) -eq $h40)

    # --- close: honest about what it closed ------------------------------------------------------
    $raw = Overlay @('close', '--target', $sid)
    $r = ConvertFrom-Json $raw
    Check 'close --target <a real session> with an overlay open says "closed"' ([bool]$r.ok -and [string]$r.result -eq 'closed') "raw: $raw"
    $gone = Wait-Overlay $false
    Check 'and the popup is gone' ($gone -eq [IntPtr]::Zero -and -not [LiteHonesty]::IsWindow($h40))
    $raw = Overlay @('close')
    $r = ConvertFrom-Json $raw
    Check 'an untargeted close with nothing open is ok "no overlay" (the conformance step depends on it)' ([bool]$r.ok -and [string]$r.result -eq 'no overlay') "raw: $raw"
    $raw = Overlay @('close', '--target', $sid)
    $r = ConvertFrom-Json $raw
    Check 'close --target <a real session> with nothing open is ok "no overlay"' ([bool]$r.ok -and [string]$r.result -eq 'no overlay') "raw: $raw"
    $raw = Overlay @('close', '--target', 'no-such-session')
    $r = ConvertFrom-Json $raw
    Check 'close --target no-such-session with nothing open is STILL refused (the overlay you meant may be up)' (-not $r.ok -and [string]$r.error -eq $noSession) "raw: $raw"

    # --- resize with nothing open is a refusal, not a string ------------------------------------
    $raw = Overlay @('resize', '--size-percent', '50')
    $r = ConvertFrom-Json $raw
    Check 'resize with no overlay open is refused "open one first"' (-not $r.ok -and [string]$r.error -match 'no overlay to resize' -and [string]$r.error -match 'open one first') "raw: $raw"
    Start-Sleep -Milliseconds 500
    Check 'and nothing opened' ((OverlayHwnd) -eq [IntPtr]::Zero)

    # --- refusals with NOTHING open open nothing (the finder was proved above) ------------------
    foreach ($bad in '0', '-5', '150') {
        $raw = Overlay @('open', 'cmd', '/k', '--size-percent', $bad)
        $r = ConvertFrom-Json $raw
        Check "with nothing open, --size-percent $bad is refused" (-not $r.ok) "raw: $raw"
    }
    $raw = Overlay @('open')
    Check 'with nothing open, open with no command is refused' (-not (ConvertFrom-Json $raw).ok) "raw: $raw"
    Start-Sleep -Milliseconds 1500
    Check 'and no popup appeared for any of them' ((OverlayHwnd) -eq [IntPtr]::Zero)

    # --- the server's own decoder, through a raw line on the pipe --------------------------------
    # The CLI sends size-percent as a JSON number and refuses a non-number itself; what lite does
    # with a value the CLI would never send is still lite's contract, because the pipe is public.
    function RawOverlay([string]$sizeJson) {
        Send-Raw ('{"cmd":"session.overlay","target":"","args":{"action":"open","command":"cmd /k","size-percent":' + $sizeJson + '}}')
    }
    foreach ($case in @(@('"sixty"', 'a JSON string'), @('60.5', 'a float'), @('true', 'a boolean'), @('""', 'an empty string'), @('-5', 'a negative number'))) {
        $raw = RawOverlay $case[0]
        $r = ConvertFrom-Json $raw
        Check "raw size-percent $($case[1]) ($($case[0])) is refused by lite's decoder" (-not $r.ok -and [string]$r.error -match '1\.\.100') "raw: $raw"
    }
    Start-Sleep -Milliseconds 1000
    Check 'and none of them opened a popup' ((OverlayHwnd) -eq [IntPtr]::Zero)
    # Documented, not desired: lite's tiny reader keeps a number as its text and a string as its
    # content, so a QUOTED "60" is indistinguishable from 60 and is accepted. The CLI never sends a
    # string, so no caller reaches this; it is pinned so a change to the reader shows up here.
    $raw = RawOverlay '"60"'
    $r = ConvertFrom-Json $raw
    Check 'raw size-percent as the quoted string "60" is accepted (documented: the decoder cannot see the JSON kind)' ([bool]$r.ok) "raw: $raw"
    $hq = Wait-Overlay $true
    Check 'and opened a popup' ($hq -ne [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $got = (ClientSize $hq)[0]
    Check 'sized at 60%' ([math]::Abs($got - [int]($mainClient[0] * 0.6)) -le $tol) "want ~$([int]($mainClient[0] * 0.6)), got $got"
    Overlay @('close') | Out-Null
    Wait-Overlay $false | Out-Null

    # --- absent flag: the default popup, and the refusal wording points at omitting the flag ------
    $raw = Overlay @('open', 'cmd', '/k')
    $r = ConvertFrom-Json $raw
    Check 'open with no --size-percent answers ok' ([bool]$r.ok) "raw: $raw"
    $hd = Wait-Overlay $true
    Check 'and opened the default popup' ($hd -ne [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $got = (ClientSize $hd)[0]
    Check "sized at lite's 70% default" ([math]::Abs($got - [int]($mainClient[0] * 0.7)) -le $tol) "want ~$([int]($mainClient[0] * 0.7)), got $got"
    $raw = Overlay @('open', 'cmd', '/k', '--size-percent', '0')
    $r = ConvertFrom-Json $raw
    Check 'the size refusal says to omit the flag for the default' ([string]$r.error -match 'omit --size-percent') "error: $($r.error)"
    Overlay @('close') | Out-Null
    $gone = Wait-Overlay $false
    Check 'the default popup closed' ($gone -eq [IntPtr]::Zero)

    # --- 100 means the whole client area, and a popup closed by hand is gone to `resize` ----------
    # 100 on OPEN (resize 100 is pinned above): the popup's client is the main window's client on
    # both sides - the old min(0.95, ...) clamp would have made it 95 %. Then the popup is closed
    # the way the X button closes it (WM_CLOSE to the popup's own handle, this instance's window):
    # WM_DESTROY clears the overlay pointer on the UI thread, so a `resize` a moment later is
    # refused "open one first" and `close` answers "no overlay" - neither pretends the popup the
    # caller remembers is still up.
    $raw = Overlay @('open', 'cmd', '/k', '--size-percent', '100')
    $r = ConvertFrom-Json $raw
    Check 'open --size-percent 100 answers ok' ([bool]$r.ok) "raw: $raw"
    $h100 = Wait-Overlay $true
    Check 'and opened a popup' ($h100 -ne [IntPtr]::Zero)
    $got = Wait-ClientWidth $h100 $mainClient[0] $tol
    Check '100 on open means the WHOLE client area on both sides, not 95% of it' ([math]::Abs($got - $mainClient[0]) -le $tol -and [math]::Abs((ClientSize $h100)[1] - $mainClient[1]) -le $tol) "main $($mainClient -join 'x'), popup $((ClientSize $h100) -join 'x')"
    [void][LiteUi]::PostMessageW($h100, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE: what the X button sends, to the popup's own handle
    $gone = Wait-Overlay $false
    Check 'setup: the popup closed by hand is gone' ($gone -eq [IntPtr]::Zero -and -not [LiteHonesty]::IsWindow($h100))
    $raw = Overlay @('resize', '--size-percent', '50')
    $r = ConvertFrom-Json $raw
    Check 'resize on a popup the user closed by hand a moment ago is refused "open one first"' (-not $r.ok -and [string]$r.error -match 'no overlay to resize' -and [string]$r.error -match 'open one first') "raw: $raw"
    Check 'and nothing reopened' ((OverlayHwnd) -eq [IntPtr]::Zero)
    $raw = Overlay @('close')
    Check 'and close after the hand-close answers "no overlay", not "closed"' ([string](ConvertFrom-Json $raw).result -eq 'no overlay') "raw: $raw"

    # ---- sidebar ---------------------------------------------------------------------------------
    # The world here is the native SysTreeView32 child (the sidebar) — its window rect IS the
    # divider's position, and its visibility IS the toggle's state — plus the active session's grid
    # from `tree`, which is what a narrower content region has to change. The reply is never the
    # only witness.
    "-- sidebar --"
    function Sidebar([string[]]$rest) { Send-Ctl $s (@('sidebar') + $rest) }
    function TreeHwnd { [LiteHonesty]::FindWindowExW($s.Hwnd, [IntPtr]::Zero, 'SysTreeView32', $null) }
    function TreeWidth {
        $r = New-Object LiteHonesty+RECT
        [void][LiteHonesty]::GetWindowRect((TreeHwnd), [ref]$r)
        return ($r.Right - $r.Left)
    }
    function TreeVisible { [LiteHonesty]::IsWindowVisible((TreeHwnd)) }
    function StateVisible { [bool](ConvertFrom-Json (Send-Ctl $s @('window', 'state'))).result.sidebarVisible }
    function ActiveCols { [int](Nodes | Where-Object { $_.active } | Select-Object -First 1).cols }
    function Wait-TreeWidth([int]$want, [int]$ms = 3000) {
        for ($i = 0; $i -lt ($ms / 100); $i++) { if ((TreeWidth) -eq $want) { return $want }; Start-Sleep -Milliseconds 100 }
        return (TreeWidth)
    }
    function Wait-TreeVisible([bool]$want, [int]$ms = 3000) {
        for ($i = 0; $i -lt ($ms / 100); $i++) { if ((TreeVisible) -eq $want) { return $want }; Start-Sleep -Milliseconds 100 }
        return (TreeVisible)
    }
    # A set goes through the CLI when the client can express one. The 0.17.x client sends
    # `sidebar width 300` as a READ (it has no width argument), which would turn every set below
    # into a read that happens to pass; on that client the sets go through a raw line on lite's
    # pipe, so the SERVER is still pinned, and one SKIP records that the CLI path was not.
    function SidebarWidthSet([string]$n) {
        if ($cliHasSidebarWidth) { return (Sidebar @('width', $n)) }
        return (Send-Raw ('{"cmd":"sidebar","target":"","args":{"op":"width","width":' + $n + '}}'))
    }
    if (-not $cliHasSidebarWidth) { Skip 'sidebar width N through the CLI' 'this agwintermctl predates agwinterm #226 and sends `sidebar width N` as a read; the sets below use a raw pipe line - set AGWINTERMCTL to a newer build' }

    Check 'the sandbox has a SysTreeView32 sidebar child' ((TreeHwnd) -ne [IntPtr]::Zero)
    # Normalise: the sandbox loaded the REAL profile's SidebarW/ShowSidebar, which can be anything
    # in range. Shown, at the default 180, so every delta below is a known number.
    Sidebar @('show') | Out-Null
    Check 'setup: the sidebar is shown' ((Wait-TreeVisible $true) -eq $true)
    SidebarWidthSet '180' | Out-Null
    Check 'setup: the sidebar is 180 px wide' ((Wait-TreeWidth 180) -eq 180) "tree width $(TreeWidth)"
    Start-Sleep -Milliseconds 500

    # --- reads: `width` and `state` are objects, and they agree with the window -----------------
    $raw = Sidebar @('width')
    $r = ConvertFrom-Json $raw
    Check 'sidebar width (no value) answers an object with width and visible' ([bool]$r.ok -and $r.result -is [pscustomobject] -and $r.result.width -is [long] -and $r.result.visible -is [bool]) "raw: $raw"
    Check 'and no applied field on a read' ($null -eq $r.result.PSObject.Properties['applied']) "raw: $raw"
    Check 'and the width is the tree child''s actual width' ([int]$r.result.width -eq (TreeWidth)) "reply $($r.result.width), tree $(TreeWidth)"
    $raw = Sidebar @('state')
    $r = ConvertFrom-Json $raw
    Check 'sidebar state answers {visible, width}' ([bool]$r.ok -and $r.result.visible -eq $true -and [int]$r.result.width -eq 180) "raw: $raw"
    Check 'and agrees with window.state sidebarVisible' ((StateVisible) -eq $true)
    Check 'and `sidebar state` did not flip the sidebar (it used to toggle)' ((TreeVisible) -and (StateVisible))

    # --- set 300: the reply, the divider, and the content region all moved -----------------------
    $mainClient = ClientSize $s.Hwnd
    $cols0 = ActiveCols
    Check 'the active session reports its cols in `tree`' ($cols0 -gt 20) "cols $cols0"
    # The cell width is not published; derive it from the content region the session already has.
    $cw = [math]::Round(($mainClient[0] - 180 - 5) / [double]$cols0)
    $raw = SidebarWidthSet '300'
    $r = ConvertFrom-Json $raw
    Check 'sidebar width 300 answers width 300, visible, applied' ([bool]$r.ok -and [int]$r.result.width -eq 300 -and $r.result.visible -eq $true -and $r.result.applied -eq $true) "raw: $raw"
    Check 'and the tree child is 300 px wide' ((Wait-TreeWidth 300) -eq 300) "tree width $(TreeWidth)"
    Start-Sleep -Milliseconds 700
    $r2 = (ConvertFrom-Json (Sidebar @('state'))).result
    Check 'and sidebar state / window.state agree' ([int]$r2.width -eq 300 -and $r2.visible -eq $true -and (StateVisible)) "state: $($r2 | ConvertTo-Json -Compress)"
    $cols1 = ActiveCols
    $wantCols = [math]::Floor(($mainClient[0] - 300 - 5) / $cw)
    Check "and the content region moved: the active session's cols shrank by ~120/cw" ($cols1 -lt $cols0 -and [math]::Abs($cols1 - $wantCols) -le 1) "cols $cols0 -> $cols1, cell ~$cw px, want ~$wantCols"
    Check 'and HKCU SidebarW was persisted' ((Get-ItemProperty -Path $regKey -Name SidebarW).SidebarW -eq 300)

    # --- out of range is refused naming the range, and the divider did not move -----------------
    foreach ($bad in '89', '901', '0') {
        $raw = SidebarWidthSet $bad
        $r = ConvertFrom-Json $raw
        Check "sidebar width $bad is refused naming the value and 90..900" (-not $r.ok -and [string]$r.error -match "width $bad " -and [string]$r.error -match '90\.\.900' -and [string]$r.error -match 'Nothing changed') "raw: $raw"
    }
    Start-Sleep -Milliseconds 700
    Check 'and the tree child is still 300 px' ((TreeWidth) -eq 300) "tree width $(TreeWidth)"
    Check 'and `sidebar width` still reads 300' ([int](ConvertFrom-Json (Sidebar @('width'))).result.width -eq 300)

    # --- the second limit: a width that leaves no terminal is refused against the LIVE window ----
    # 600 is inside the range. In a 700-px window it leaves ~80 px for the terminal (under twenty
    # cells of any font); in the 1100-px sandbox it leaves ~480 and is accepted — the same number,
    # two answers, because the limit is the live client width and not a constant.
    [void][LiteUi]::SetWindowPos($s.Hwnd, [IntPtr]::Zero, 150, 100, 700, 700, 0x0004)
    Start-Sleep -Milliseconds 1200
    $narrow = ClientSize $s.Hwnd
    Check 'setup: the window is ~700 px wide' ($narrow[0] -lt 720 -and $narrow[0] -gt 600) "client $($narrow -join 'x')"
    $raw = SidebarWidthSet '600'
    $r = ConvertFrom-Json $raw
    Check 'sidebar width 600 in a 700-px window is refused for the content minimum' (-not $r.ok -and [string]$r.error -match '600' -and [string]$r.error -match '20-column' -and [string]$r.error -match 'Nothing changed') "raw: $raw"
    Check 'and the refusal names the window width, so the caller knows which limit hit' ([string]$r.error -match "$($narrow[0]) px window") "error: $($r.error)"
    Start-Sleep -Milliseconds 700
    Check 'and the tree child is still 300 px' ((TreeWidth) -eq 300) "tree width $(TreeWidth)"
    [void][LiteUi]::SetWindowPos($s.Hwnd, [IntPtr]::Zero, 150, 100, 1100, 700, 0x0004)
    Start-Sleep -Milliseconds 1200
    $raw = SidebarWidthSet '600'
    $r = ConvertFrom-Json $raw
    Check 'the same 600 in the 1100-px window is accepted' ([bool]$r.ok -and [int]$r.result.width -eq 600) "raw: $raw"
    Check 'and applied' ((Wait-TreeWidth 600) -eq 600) "tree width $(TreeWidth)"
    SidebarWidthSet '300' | Out-Null
    Check 'setup: back at 300' ((Wait-TreeWidth 300) -eq 300)

    # --- set while hidden: remembered and persisted, reported as not applied --------------------
    $raw = Sidebar @('hide')
    Check 'sidebar hide answers ok' ([bool](ConvertFrom-Json $raw).ok) "raw: $raw"
    Check 'and the tree child is hidden' ((Wait-TreeVisible $false) -eq $false)
    Check 'and window.state says so' (-not (StateVisible))
    $raw = SidebarWidthSet '250'
    $r = ConvertFrom-Json $raw
    Check 'sidebar width 250 while hidden answers width 250, visible:false, applied:false' ([bool]$r.ok -and [int]$r.result.width -eq 250 -and $r.result.visible -eq $false -and $r.result.applied -eq $false) "raw: $raw"
    Check 'and says the width is remembered, not applied' ([string]$r.result.note -match 'remembered, not applied' -and [string]$r.result.note -match 'sidebar show') "note: $($r.result.note)"
    Start-Sleep -Milliseconds 700
    Check 'and the sidebar stayed hidden' (-not (TreeVisible) -and -not (StateVisible))
    Check 'and HKCU SidebarW was persisted while hidden' ((Get-ItemProperty -Path $regKey -Name SidebarW).SidebarW -eq 250)
    $r2 = (ConvertFrom-Json (Sidebar @('state'))).result
    Check 'and sidebar state carries the remembered width beside visible:false' ([int]$r2.width -eq 250 -and $r2.visible -eq $false) "state: $($r2 | ConvertTo-Json -Compress)"
    Sidebar @('show') | Out-Null
    Check 'sidebar show brings it back' ((Wait-TreeVisible $true) -eq $true)
    Check 'at the remembered 250 px' ((Wait-TreeWidth 250) -eq 250) "tree width $(TreeWidth)"

    # --- an unknown op is refused and flips nothing; it used to toggle ---------------------------
    foreach ($op in 'bogus', 'sideways', 'width=300') {
        $before = StateVisible
        $raw = Sidebar @($op)
        $r = ConvertFrom-Json $raw
        Check "sidebar $op is refused naming the ops" (-not $r.ok -and [string]$r.error -match [regex]::Escape($op) -and [string]$r.error -match 'show\|hide\|toggle\|state\|width' -and [string]$r.error -match 'Nothing changed') "raw: $raw"
        Start-Sleep -Milliseconds 700
        Check "and the sidebar did not flip (visible before: $before)" ((StateVisible) -eq $before -and (TreeVisible) -eq $before)
    }
    Check 'and the width did not move either' ((TreeWidth) -eq 250)
    # The specific old bug: `show` on a shown sidebar toggled it off.
    Sidebar @('show') | Out-Null
    Start-Sleep -Milliseconds 700
    Check 'sidebar show on a shown sidebar leaves it shown' ((TreeVisible) -and (StateVisible))

    # --- on/off are show/hide; toggle toggles ---------------------------------------------------
    $raw = Sidebar @('off')
    Check 'sidebar off hides' ([bool](ConvertFrom-Json $raw).ok -and (Wait-TreeVisible $false) -eq $false) "raw: $raw"
    Sidebar @('off') | Out-Null
    Start-Sleep -Milliseconds 700
    Check 'sidebar off again stays hidden (an alias of hide, not a toggle)' (-not (TreeVisible))
    $raw = Sidebar @('on')
    Check 'sidebar on shows' ([bool](ConvertFrom-Json $raw).ok -and (Wait-TreeVisible $true) -eq $true) "raw: $raw"
    Sidebar @('on') | Out-Null
    Start-Sleep -Milliseconds 700
    Check 'sidebar on again stays shown' ((TreeVisible))
    Sidebar @('toggle') | Out-Null
    Check 'sidebar toggle hides' ((Wait-TreeVisible $false) -eq $false)
    Sidebar @('toggle') | Out-Null
    Check 'sidebar toggle shows' ((Wait-TreeVisible $true) -eq $true)
    Check 'and the width survived the toggles' ((TreeWidth) -eq 250) "tree width $(TreeWidth)"

    # --- the client's half, and the server's decoder ------------------------------------------
    if ($cliHasSidebarWidth) {
        foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
        $out = (& $ctl sidebar width wide --pipe $s.Pipe --json 2>&1) -join ''
        $code = $LASTEXITCODE
        Check 'sidebar width wide is refused by the client, non-zero exit' ($code -ne 0 -and $out -match 'whole number') "exit $code, output: $out"
        Start-Sleep -Milliseconds 500
        Check 'and the width did not move' ((TreeWidth) -eq 250)
    } else {
        Skip 'sidebar width wide is refused by the client' 'this agwintermctl predates agwinterm #226 - set AGWINTERMCTL to a newer build'
    }
    function RawSidebarWidth([string]$json) { Send-Raw ('{"cmd":"sidebar","target":"","args":{"op":"width","width":' + $json + '}}') }
    foreach ($case in @(@('"wide"', 'a JSON string'), @('300.5', 'a float'), @('true', 'a boolean'), @('""', 'an empty string'), @('-5', 'a negative number'))) {
        $raw = RawSidebarWidth $case[0]
        $r = ConvertFrom-Json $raw
        Check "raw width $($case[1]) ($($case[0])) is refused by lite's decoder" (-not $r.ok -and [string]$r.error -match '90\.\.900') "raw: $raw"
    }
    Start-Sleep -Milliseconds 700
    Check 'and none of them moved the divider' ((TreeWidth) -eq 250)
    # Documented, not desired (the same reader as --size-percent): a QUOTED "300" is accepted.
    $raw = RawSidebarWidth '"300"'
    $r = ConvertFrom-Json $raw
    Check 'raw width as the quoted string "300" is accepted (documented: the decoder cannot see the JSON kind)' ([bool]$r.ok -and [int]$r.result.width -eq 300) "raw: $raw"
    Check 'and applied' ((Wait-TreeWidth 300) -eq 300)

    # --- `sidebar width` while a splitter drag is in progress -------------------------------------
    # The drag and the set both write g_sidebarW and both lay out on the UI thread (the set is
    # posted), so nothing races: the set lands between two mouse moves, the next move overwrites
    # it, and the button-up saves what the DRAG ended at. What is owed is that, once the drag ends,
    # a read, the tree child and the saved setting all agree on the drag's number - the set's
    # `applied:true` was true for the moment it held. The drag is button and move messages POSTED
    # to the sandbox's own handle (ui-lib's rule), starting on the splitter.
    $midY = [int]((ClientSize $s.Hwnd)[1] / 2)
    function Pt([int]$x, [int]$y) { [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)) }
    # While the mouse is captured, Windows queues a synthetic WM_MOUSEMOVE at the REAL cursor's
    # position whenever the window under the cursor changes - on SetCapture (inside the button-down)
    # and again on every relayout the drag itself causes, since the tree/terminal boundary moves under
    # the cursor. With the physical mouse sitting over the sandbox, every posted move was overwritten
    # and the tree ended wherever the mouse sat (441 with the mouse at screen x 599; a pause after the
    # button-down was not enough). So, for the drag only, the sandbox's own window is moved out from
    # under the cursor (SetWindowPos on it is ui-lib's rule, no input is injected) and put back after.
    $curPt = New-Object LiteHonesty+POINT; [void][LiteHonesty]::GetCursorPos([ref]$curPt)
    $winRc = New-Object LiteHonesty+RECT; [void][LiteHonesty]::GetWindowRect($s.Hwnd, [ref]$winRc)
    $dragMoved = $false
    if ($curPt.X -ge $winRc.Left -and $curPt.X -lt $winRc.Right -and $curPt.Y -ge $winRc.Top -and $curPt.Y -lt $winRc.Bottom) {
        # Below the cursor if that keeps the window on the desktop, else to its right.
        $desk = New-Object LiteHonesty+RECT; [void][LiteHonesty]::GetWindowRect([LiteHonesty]::GetDesktopWindow(), [ref]$desk)
        $nx = $winRc.Left; $ny = $curPt.Y + 20
        if ($ny + 200 -gt $desk.Bottom) { $ny = $winRc.Top; $nx = $curPt.X + 20 }
        [void][LiteUi]::SetWindowPos($s.Hwnd, [IntPtr]::Zero, $nx, $ny, 0, 0, 0x0005)   # SWP_NOSIZE | SWP_NOZORDER
        Start-Sleep -Milliseconds 500
        $dragMoved = $true
    }
    [void][LiteUi]::PostMessageW($s.Hwnd, 0x0201, [IntPtr]1, (Pt ((TreeWidth) + 2) $midY))   # WM_LBUTTONDOWN on the splitter
    Start-Sleep -Milliseconds 300
    [void][LiteUi]::PostMessageW($s.Hwnd, 0x0200, [IntPtr]1, (Pt 340 $midY))                 # WM_MOUSEMOVE, button held
    Check 'setup: a splitter drag is in progress (the tree followed the mouse to 340)' ((Wait-TreeWidth 340) -eq 340) "tree width $(TreeWidth)"
    $raw = SidebarWidthSet '400'
    $r = ConvertFrom-Json $raw
    Check 'sidebar width 400 mid-drag answers ok, applied' ([bool]$r.ok -and [int]$r.result.width -eq 400 -and $r.result.applied -eq $true) "raw: $raw"
    [void][LiteUi]::PostMessageW($s.Hwnd, 0x0200, [IntPtr]1, (Pt 360 $midY))                 # the drag continues
    [void][LiteUi]::PostMessageW($s.Hwnd, 0x0202, [IntPtr]::Zero, (Pt 360 $midY))            # WM_LBUTTONUP ends it
    Check 'the drag wins: the tree child ends at the drag''s 360' ((Wait-TreeWidth 360) -eq 360) "tree width $(TreeWidth)"
    Check 'and `sidebar width` reads the same 360 - the reply and the divider agree once the drag ends' ([int](ConvertFrom-Json (Sidebar @('width'))).result.width -eq 360)
    Check 'and HKCU SidebarW is the drag''s 360 (the button-up saved last)' ((Get-ItemProperty -Path $regKey -Name SidebarW).SidebarW -eq 360)
    SidebarWidthSet '300' | Out-Null
    Check 'setup: back at 300' ((Wait-TreeWidth 300) -eq 300)
    if ($dragMoved) {   # the drag is over: the window goes back where every later coordinate expects it
        [void][LiteUi]::SetWindowPos($s.Hwnd, [IntPtr]::Zero, $winRc.Left, $winRc.Top, 0, 0, 0x0005)
        Start-Sleep -Milliseconds 500
    }
    # A raw request with no op at all: the CLI always sends one, but the pipe is public. Toggle,
    # which is what the CLI sends for a bare `sidebar` — pinned so the "" case is a written fact.
    $raw = Send-Raw '{"cmd":"sidebar","target":"","args":{}}'
    Check 'a raw sidebar request with no op toggles (what the CLI sends for a bare `sidebar`)' ([bool](ConvertFrom-Json $raw).ok -and (Wait-TreeVisible $false) -eq $false) "raw: $raw"
    Sidebar @('show') | Out-Null
    Wait-TreeVisible $true | Out-Null

    # No refusal above may have created a session: hidden sessions never show in `tree`, and the
    # visible count is what it was at the start.
    Check 'the tree still has exactly the sandbox first session' (@(Nodes).Count -eq 1) "nodes: $(@(Nodes).Count)"

    # ---- session.new: the caller's workspace, and the refused pair --------------------------------
    # The world here is `tree`: which workspace a new session appears under, which workspace is
    # active, and how many sessions exist. The caller is the pane that ran `session new` - the CLI
    # sends its AGWINTERM_SESSION_ID as `caller` (agwinterm #226) - so the CLI checks run with that
    # variable SET to a sandbox session's id, which is the one thing Send-Ctl exists to scrub.
    # A client that predates #226 never sends `caller`, and every bare create through it would land
    # in the active workspace - a pass for the wrong reason - so those checks are gated on the same
    # #226 marker the overlay checks use (the client-side `--size-percent sixty` refusal shipped in
    # the same PR as `caller`). The server's half is pinned through a raw line either way.
    "-- session.new --"
    $cliSendsCaller = $cliRefusesNonNumber
    function Send-CtlAs([string]$callerId, [string[]]$argv) {
        foreach ($v in 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
        $env:AGWINTERM_SESSION_ID = $callerId
        try { (& $ctl @argv --pipe $s.Pipe --json 2>&1) -join '' }
        finally { Remove-Item env:AGWINTERM_SESSION_ID -ErrorAction SilentlyContinue }
    }
    # Where `tree` files a session: the workspace id (lite's index), or $null when it is nowhere.
    function WsOf([string]$id) {
        foreach ($w in (Tree).workspaces) { foreach ($n in $w.sessions) { if ([string]$n.id -eq $id) { return [string]$w.id } } }
        return $null
    }
    function ActiveWs { [string]((Tree).workspaces | Where-Object { $_.active } | Select-Object -First 1).id }
    function NodeCount { @(Nodes).Count }
    # A created session shows in `tree` after a posted refresh; a refusal never shows at all.
    function Wait-Node([string]$id, [int]$ms = 4000) {
        for ($i = 0; $i -lt ($ms / 100); $i++) { if ($null -ne (WsOf $id)) { return $true }; Start-Sleep -Milliseconds 100 }
        return $false
    }

    # Setup: workspace B beside the sandbox's A (0); a session in B named distinctively, so the
    # name arm can be shown to be OFF; then A active again. `workspace new` makes the new one active
    # (that is one of the fifteen writers), which is why the select back to A is explicit.
    $wsA = ActiveWs
    Check 'setup: the sandbox starts in workspace 0 (A), active' ($wsA -eq '0') "active $wsA"
    $raw = Send-Ctl $s @('workspace', 'new', 'B')
    $wsB = [string](ConvertFrom-Json $raw).result
    Check 'setup: workspace new B answers its index' ($wsB -eq '1') "raw: $raw"
    $raw = Send-Ctl $s @('session', 'new', '--name', 'beta-agent', '--workspace', $wsB)
    $bId = [string](ConvertFrom-Json $raw).result
    Check 'setup: a session in B' ((Wait-Node $bId) -and (WsOf $bId) -eq $wsB) "id $bId, ws $(WsOf $bId)"
    # `workspace select` and `session select` take --target (a positional is silently "active").
    $raw = Send-Ctl $s @('workspace', 'select', '--target', $wsA)
    Start-Sleep -Milliseconds 500
    Check 'setup: A is the active workspace again (precondition: active is NOT where the caller is)' ((ConvertFrom-Json $raw).ok -and (ActiveWs) -eq $wsA) "raw: $raw, active $(ActiveWs)"
    $n0 = NodeCount

    if ($cliSendsCaller) {
        # --- a bare create from a pane in B lands in B, with A active ---------------------------
        $raw = Send-CtlAs $bId @('session', 'new', '--name', 'child-1')
        $r = ConvertFrom-Json $raw
        $c1 = [string]$r.result
        Check 'a bare `session new` from a pane in B answers ok with an id' ([bool]$r.ok -and $c1) "raw: $raw"
        Check "and `tree` files it in B, not in the active A" ((Wait-Node $c1) -and (WsOf $c1) -eq $wsB) "ws $(WsOf $c1), wanted $wsB"
        Check 'and A stayed the active workspace (a create does not move "active")' ((ActiveWs) -eq $wsA) "active $(ActiveWs)"
        # --- the regression: the user (or another agent) selects a session in A in between -------
        $raw = Send-Ctl $s @('session', 'select', '--target', $sid)
        Start-Sleep -Milliseconds 500
        Check 'setup: a session in A was selected, so "active" is A by a second route' ((ConvertFrom-Json $raw).ok -and (ActiveWs) -eq $wsA) "raw: $raw, active $(ActiveWs)"
        $raw = Send-CtlAs $bId @('session', 'new', '--name', 'child-2')
        $c2 = [string](ConvertFrom-Json $raw).result
        Check 'a second bare create from the same caller lands in B again (the redirect is gone)' ((Wait-Node $c2) -and (WsOf $c2) -eq $wsB) "ws $(WsOf $c2), wanted $wsB"
        # --- an explicit workspace beats the caller ------------------------------------------------
        $raw = Send-CtlAs $bId @('session', 'new', '--name', 'explicit-a', '--workspace', $wsA)
        $ea = [string](ConvertFrom-Json $raw).result
        Check '--workspace 0 from a caller in B lands in 0 (explicit wins)' ((Wait-Node $ea) -and (WsOf $ea) -eq $wsA) "ws $(WsOf $ea)"
        $wsAName = [string]((Tree).workspaces | Where-Object { [string]$_.id -eq $wsA } | Select-Object -First 1).name
        $raw = Send-CtlAs $bId @('session', 'new', '--name', 'explicit-name-a', '--workspace-name', $wsAName)
        $en = [string](ConvertFrom-Json $raw).result
        Check '--workspace-name of A from a caller in B lands in A (explicit wins)' ((Wait-Node $en) -and (WsOf $en) -eq $wsA) "raw: $raw, ws $(WsOf $en)"
        # --- a stale caller is not refused: it creates, in the active workspace ------------------
        $active = ActiveWs
        $raw = Send-CtlAs 'no-such-pane-0000' @('session', 'new', '--name', 'orphan-not')
        $r = ConvertFrom-Json $raw
        $st = [string]$r.result
        Check 'a stale caller id is NOT refused - the session is created' ([bool]$r.ok -and $st) "raw: $raw"
        Check "and it landed in the active workspace ($active)" ((Wait-Node $st) -and (WsOf $st) -eq $active) "ws $(WsOf $st)"
    } else {
        Skip 'a bare `session new` from a pane in B lands in B (through the CLI)' 'this agwintermctl predates agwinterm #226 and never sends `caller` - set AGWINTERMCTL to a newer build'
    }

    # --- no caller at all (the env scrubbed, as the conformance runner does): active, unchanged ---
    Send-Ctl $s @('workspace', 'select', '--target', $wsA) | Out-Null
    Start-Sleep -Milliseconds 300
    Check 'setup: A active' ((ActiveWs) -eq $wsA) "active $(ActiveWs)"
    $raw = Send-Ctl $s @('session', 'new', '--name', 'no-caller')
    $nc = [string](ConvertFrom-Json $raw).result
    Check 'a bare create with NO caller lands in the active workspace (the last answer, unchanged)' ((Wait-Node $nc) -and (WsOf $nc) -eq $wsA) "ws $(WsOf $nc)"

    # --- the server's half through raw lines: id only, never a name; a short prefix is nothing ---
    # `caller` rides inside args, where the CLI puts it (cargs is "args" on the wire).
    function RawNew([string]$name, [string]$callerJson) {
        Send-Raw ('{"cmd":"session.new","args":{"name":"' + $name + '","caller":' + $callerJson + '}}')
    }
    $raw = RawNew 'raw-by-id' ('"' + $bId + '"')
    $ri = [string](ConvertFrom-Json $raw).result
    Check 'raw: caller = B session id lands in B (the server reads args.caller)' ((Wait-Node $ri) -and (WsOf $ri) -eq $wsB) "raw: $raw, ws $(WsOf $ri)"
    Check 'and A is still active' ((ActiveWs) -eq $wsA)
    $raw = RawNew 'raw-by-name' '"beta-agent"'
    $rn = [string](ConvertFrom-Json $raw).result
    Check 'raw: caller = the B session NAME does not resolve - lands in active A (never the name arm)' ((Wait-Node $rn) -and (WsOf $rn) -eq $wsA) "raw: $raw, ws $(WsOf $rn)"
    $short = $bId.Substring(0, 3)
    $raw = RawNew 'raw-short-prefix' ('"' + $short + '"')
    $rs = [string](ConvertFrom-Json $raw).result
    Check "raw: a 3-char prefix '$short' does not resolve - lands in active A" ((Wait-Node $rs) -and (WsOf $rs) -eq $wsA) "raw: $raw, ws $(WsOf $rs)"
    $raw = Send-Raw ('{"cmd":"session.new","caller":"' + $bId + '","args":{"name":"raw-top-level"}}')
    $rt = [string](ConvertFrom-Json $raw).result
    Check 'raw: a top-level caller (a hand-written line) is honoured too - lands in B' ((Wait-Node $rt) -and (WsOf $rt) -eq $wsB) "raw: $raw, ws $(WsOf $rt)"
    $raw = RawNew 'raw-active-word' '"active"'
    $ra = [string](ConvertFrom-Json $raw).result
    Check 'raw: caller = "active" is a target word, not an id - lands in active A' ((Wait-Node $ra) -and (WsOf $ra) -eq $wsA) "raw: $raw, ws $(WsOf $ra)"

    # --- a caller that is a popup session (scratch here; quick and overlay are the same flag) ----
    # The quick, scratch and overlay sessions are hidden from `tree` and belong to no workspace a
    # caller could mean (their ws is whatever was active when the popup was first made), so a
    # `session new` from inside one resolves the caller and then falls through to the active
    # workspace - created, not refused, and visible in the tree. Scratch rather than quick: a
    # dismissed scratch pad is torn down, so this leaves no hidden session behind for the quick
    # terminal checks further down, which read the `created` event of a FRESH quick session.
    $cursor = [long](ConvertFrom-Json (Send-Ctl $s @('events'))).result.cursor
    Send-Raw '{"cmd":"session.scratch","target":"","args":{"op":"on"}}' | Out-Null
    Start-Sleep -Milliseconds 2500
    $scratchId = [string](@((ConvertFrom-Json (Send-Ctl $s @('events', '--since', "$cursor"))).result.events | Where-Object { $_.type -eq 'session' -and $_.info -eq 'created' }) | Select-Object -Last 1).session
    Check 'setup: the scratch popup is up, its session id is known, and it is hidden from tree' ([bool]$scratchId -and -not (Nodes | Where-Object { [string]$_.id -eq $scratchId })) "scratch id '$scratchId'"
    $raw = RawNew 'from-scratch' ('"' + $scratchId + '"')
    $rq = [string](ConvertFrom-Json $raw).result
    Check 'raw: caller = the scratch session id is created (not refused) and lands in active A' ((Wait-Node $rq) -and (WsOf $rq) -eq $wsA) "raw: $raw, ws $(WsOf $rq)"
    Send-Raw '{"cmd":"session.scratch","target":"","args":{"op":"off"}}' | Out-Null
    Start-Sleep -Milliseconds 500

    # --- the pair is refused before anything is created --------------------------------------------
    $n1 = NodeCount
    $twoSources = "session.new: --workspace '$wsA' and --workspace-name 'B' are two answers to one question; pass one of them. No session was created."
    $raw = Send-Ctl $s @('session', 'new', '--name', 'pair', '--workspace', $wsA, '--workspace-name', 'B')
    $r = ConvertFrom-Json $raw
    Check '--workspace with --workspace-name is refused with agwinterm''s wording' (-not $r.ok -and [string]$r.error -eq $twoSources) "raw: $raw"
    if ($cliSendsCaller) {
        $raw = Send-CtlAs $bId @('session', 'new', '--name', 'pair-caller', '--workspace', $wsA, '--workspace-name', 'B')
        $r = ConvertFrom-Json $raw
        Check 'the pair is refused with a caller too (the caller never breaks a tie)' (-not $r.ok -and [string]$r.error -eq $twoSources) "raw: $raw"
    }
    # Both unknown: the pair is refused first, before either value is looked up.
    $raw = Send-Ctl $s @('session', 'new', '--name', 'pair-unknown', '--workspace', '77', '--workspace-name', 'nowhere')
    $r = ConvertFrom-Json $raw
    Check 'the pair with two unknown values is refused as a pair (checked before either lookup)' (-not $r.ok -and [string]$r.error -match 'two answers to one question') "raw: $raw"
    Start-Sleep -Milliseconds 1000
    Check 'and no session was created by any of the three' ((NodeCount) -eq $n1) "nodes $n1 -> $(NodeCount)"
    Check 'and the tree has no session named pair*' (-not (Nodes | Where-Object { [string]$_.name -like 'pair*' }))
    # Unknown workspace refusals, unchanged from P1-lite: still refused, still nothing created.
    $raw = Send-Ctl $s @('session', 'new', '--name', 'nowhere', '--workspace', 'no-such-workspace')
    Check 'session new --workspace no-such-workspace is still refused' (-not (ConvertFrom-Json $raw).ok) "raw: $raw"
    Start-Sleep -Milliseconds 700
    Check 'and created nothing' ((NodeCount) -eq $n1) "nodes $n1 -> $(NodeCount)"

    # ---- session.type --stdin: the shared client against lite's decoder -------------------------
    # No server change rides with this: lite's handler already takes args.text, folds \n to \r and
    # refuses control bytes. What is owed is the proof that text the argv path cannot carry - a
    # quote, a newline, a run of spaces, a leading `--` - reaches the pane BYTE FOR BYTE through the
    # CLI's --stdin and lite's own JSON decoder (src/control.h), and that the argv path really does
    # lose it, silently, with an `ok` reply. The oracle is a `cmd /k` pane: cmd's `echo` prints its
    # argument verbatim (quotes and inner spaces kept), so the echoed row IS the bytes the shell
    # received; the second line carries no Enter (the reader strips exactly ONE trailing newline,
    # the one the pipe adds) and sits at the prompt as typed. A pane's rows are read TrimEnd'ed:
    # trailing blanks are the renderer's, and Clink (present on some machines) paints a hint after
    # the draft, so a draft is matched by Contains, never by EndsWith.
    "-- session.type --stdin --"
    $raw = Send-Ctl $s @('session', 'new', '--name', 'stdin-oracle', '--command', 'cmd /k')
    $oid = [string](ConvertFrom-Json $raw).result
    Check 'setup: a cmd /k pane to echo into' ((Wait-Node $oid)) "raw: $raw"
    function OracleRows { @(([string](Get-PaneText $s $oid)) -split "`n" | ForEach-Object { $_.TrimEnd() }) }
    function Wait-Row([scriptblock]$pred, [int]$ms = 6000) {
        for ($i = 0; $i -lt ($ms / 200); $i++) { if (OracleRows | Where-Object $pred) { return $true }; Start-Sleep -Milliseconds 200 }
        return [bool](OracleRows | Where-Object $pred)
    }
    Check 'setup: the cmd pane painted something (a banner or a prompt)' (Wait-Row { $_ -ne '' } 10000)
    Start-Sleep -Milliseconds 1500
    # A direct CLI call with a piped stdin, scrubbed like Send-Ctl (a suite run from inside a pane
    # would otherwise carry its own AGWINTERM_SESSION_ID as the default target).
    function Invoke-CtlStdin([string]$in, [string[]]$argv) {
        foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
        ($in | & $ctl @argv --pipe $s.Pipe --json 2>&1) -join ''
    }
    $line1 = 'echo --lead "quoted"  two-spaces'     # a leading --word, a quote, two consecutive spaces
    # A name nothing can resolve. `tail` was here, and it IS a real program on a GitHub runner
    # (Git for Windows puts tail.exe on PATH), so cmd ran it instead of answering "is not
    # recognized" and the oracle below tested the runner's PATH rather than the product
    # (found by CI on the first run that could execute these checks, after 0.17.11 shipped).
    $absent = 'zzz-no-such-cmd-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $line2 = "$absent  --end ""q"""                # after the newline: another run of spaces, no Enter
    $text = $line1 + "`n" + $line2
    $echoed = $line1.Substring(5)                  # what cmd's echo prints: everything after `echo `

    # --- first the argv path, word-split the way cmd and bash hand words over --------------------
    # The words reach the CLI one by one: the newline and the run of spaces are gone before the CLI
    # ever sees them (that is what word-splitting is), and `--lead` / `--end` are options to its
    # parser, not text. The call still answers ok - the loss is silent, which is the point of
    # --stdin. Enter afterwards so cmd echoes what did arrive; the pane never sees $line2 as such.
    $words = $text -split '\s+'
    $raw = Send-Ctl $s (@('session', 'type') + $words + @('--target', $oid))
    Check 'the same text as word-split argv answers ok ("typed") - the loss is silent' ([bool](ConvertFrom-Json $raw).ok) "raw: $raw"
    Start-Sleep -Milliseconds 800
    $draft = [string](OracleRows | Where-Object { $_ -match 'echo' } | Select-Object -Last 1)
    Check 'and what arrived is one line: no row carries the run of two spaces' ($draft -and -not (OracleRows | Where-Object { $_.Contains('  two-spaces') })) "draft row: [$draft]"
    Check 'nor the second line - the newline did not survive argv' (-not (OracleRows | Where-Object { $_.Contains($line2) })) "rows: $((OracleRows | Where-Object { $_ }) -join ' | ')"
    Send-Ctl $s @('session', 'type', "`n", '--target', $oid) | Out-Null
    Start-Sleep -Milliseconds 800

    if ($cliHasStdin) {
        # --- --stdin: the here-string, and both lines back byte for byte ------------------------
        $raw = Invoke-CtlStdin $text @('session', 'type', '--stdin', '--target', $oid)
        $r = ConvertFrom-Json $raw
        Check 'session type --stdin with a quote, a newline, two spaces and a leading -- answers ok "typed"' ([bool]$r.ok -and [string]$r.result -eq 'typed') "exit $LASTEXITCODE, raw: $raw"
        Check "the first line ran and cmd echoed its argument byte for byte: [$echoed]" (Wait-Row { $_ -eq $echoed }) "rows: $((OracleRows | Where-Object { $_ }) -join ' | ')"
        Check "the second line sits at the prompt as typed: [$line2]" (Wait-Row { $_.Contains($line2) }) "rows: $((OracleRows | Where-Object { $_ }) -join ' | ')"
        Check 'and was NOT submitted (one trailing newline stripped, none invented)' (-not (OracleRows | Where-Object { $_ -match 'is not recognized' }))
        # A second newline at the end IS the Enter: the draft runs, and cmd says so.
        $raw = Invoke-CtlStdin "`n" @('session', 'type', '--stdin', '--target', $oid)
        Check 'a text of two newlines (one stripped, one kept) presses Enter' ([bool](ConvertFrom-Json $raw).ok -and (Wait-Row { $_ -match 'is not recognized' })) "raw: $raw, rows: $((OracleRows | Where-Object { $_ }) -join ' | ')"

        # --- invalid UTF-8 from a file: refused by the CLI, and the pane received NOTHING ---------
        # `echo <marker> ` then a lone 0x80 then LF. The refusal is client-side (StdinText, agwinterm
        # #226); the lite half is that nothing reaches the pane - not the `echo <marker>` before the
        # bad byte, not a U+FFFD in its place. The marker is the oracle: a whole-text "unchanged"
        # compare is at the mercy of a prompt that paints late (a git-backed prompt takes seconds
        # here), while a marker that never appears cannot be confused with anything already there.
        # Redirected from a file so the bytes are exactly these: a PowerShell pipe would re-encode.
        $badMarker = 'bad-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $prefix = [Text.Encoding]::ASCII.GetBytes("echo $badMarker ")
        $bad = Join-Path $env:TEMP ('honesty-stdin-' + $badMarker + '.bin')
        [IO.File]::WriteAllBytes($bad, [byte[]]($prefix + @(0x80, 0x0A)))
        $so = "$bad.out"; $se = "$bad.err"
        foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
        $p = Start-Process -FilePath $ctl -ArgumentList @('session', 'type', '--stdin', '--target', $oid, '--pipe', $s.Pipe, '--json') `
                           -RedirectStandardInput $bad -RedirectStandardOutput $so -RedirectStandardError $se -NoNewWindow -Wait -PassThru
        $err = [string](Get-Content $se -Raw -ErrorAction SilentlyContinue)
        Check "a lone 0x80 on --stdin: non-zero exit, the refusal names byte offset $($prefix.Length) and 0x80" ($p.ExitCode -ne 0 -and $err -match "byte offset $($prefix.Length)\b" -and $err -match '0x80') "exit $($p.ExitCode), stderr: $err, stdout: $(Get-Content $so -Raw -ErrorAction SilentlyContinue)"
        Start-Sleep -Milliseconds 2000
        $rowsAfter = OracleRows
        Check 'and the pane received nothing - not the `echo <marker>` before the bad byte, not a U+FFFD' (-not ($rowsAfter | Where-Object { $_.Contains($badMarker) -or $_.Contains([string][char]0xFFFD) })) "rows: $(($rowsAfter | Where-Object { $_ }) -join ' | ')"
        Remove-Item $bad, $so, $se -ErrorAction SilentlyContinue

        # --- the quick terminal: no `quick type` verb; it is `session type --target <its id>` ------
        # `quick on` answers ok, not an id; the id arrives as a `session`/`created` event and the
        # session is hidden from `tree`. By id it is a target like any other (by NAME it is not - the
        # skill says so, and this pins it).
        $cursor = [long](ConvertFrom-Json (Send-Ctl $s @('events'))).result.cursor
        $raw = Send-Ctl $s @('quick', 'on')
        Check 'quick on answers ok (a string, not an id)' ([bool](ConvertFrom-Json $raw).ok) "raw: $raw"
        Start-Sleep -Milliseconds 2500
        $created = @((ConvertFrom-Json (Send-Ctl $s @('events', '--since', "$cursor"))).result.events | Where-Object { $_.type -eq 'session' -and $_.info -eq 'created' })
        $qid = [string]($created | Select-Object -Last 1).session
        $quickSid = $qid   # the quick session outlives its `off`; the P3 capture block needs this id again
        Check 'its session id arrived as a session/created event' ([bool]$qid) "events since $cursor`: $($created | ConvertTo-Json -Compress)"
        Check 'and that session is not in tree (hidden)' ($qid -and -not (Nodes | Where-Object { [string]$_.id -eq $qid }))
        $marker = 'quick-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $raw = Invoke-CtlStdin "echo $marker" @('session', 'type', '--stdin', '--target', $qid)
        Check 'session type --stdin --target <quick session id> answers ok' ([bool](ConvertFrom-Json $raw).ok) "raw: $raw"
        $seen = $false
        for ($i = 0; $i -lt 30; $i++) { if (([string](Get-PaneText $s $qid)).Contains($marker)) { $seen = $true; break }; Start-Sleep -Milliseconds 200 }
        Check 'and the quick pane shows the text' $seen "quick text: $(Get-PaneText $s $qid)"
        $raw = Send-Ctl $s @('session', 'type', 'x', '--target', 'quick')
        Check '--target quick (the NAME) is refused: hidden sessions are addressed by id only' (-not (ConvertFrom-Json $raw).ok) "raw: $raw"
        Send-Ctl $s @('quick', 'off') | Out-Null
        Start-Sleep -Milliseconds 500
    } else {
        Skip 'session type --stdin round-trips a quote, a newline, two spaces and a leading --' 'this agwintermctl predates agwinterm #226 and has no --stdin - set AGWINTERMCTL to a newer build'
        Skip 'a lone 0x80 on --stdin is refused and the pane receives nothing' 'no --stdin in this agwintermctl'
        Skip 'the quick terminal is typed into by its session id from the events stream' 'no --stdin in this agwintermctl'
    }

    # ---- #24: the window stops coming to the front on its own ----------------------------------
    # The report: an agent loop calling `quick on/off` and `session overlay open/close` kept popping
    # the lite window over whatever Boris was working in. Every one of those paths raised itself
    # with an unguarded SetForegroundWindow, and Windows GRANTS a background process the foreground
    # once the user's input has been quiet for the foreground-lock timeout - exactly when an agent
    # loop runs. Now a popup is raised only when this process already holds the foreground, and the
    # taskbar button flashes otherwise. The user's "other app" here is a plain top-level window of
    # THIS test process (its own window - no global input), given the foreground once; the oracle
    # is GetForegroundWindow sampled after every call, which must never belong to the sandbox's
    # process. Vacuity guard first: the popups DID appear, so the loop exercised the raise paths.
    # When the holder cannot take the foreground at all (someone is typing on this machine right
    # now), the section SKIPs rather than assert about a foreground it does not own.
    "-- #24: the foreground stays where the user left it --"
    $quickTitle = 'agliteterm ' + [char]0x2014 + ' quick'
    function QuickHwnd { [LiteHonesty]::FindWindowW('AgwintermLitePopup', $quickTitle) }
    function FgPid { [LiteHonesty]::PidOf([LiteHonesty]::GetForegroundWindow()) }
    $litePid = [uint32]$s.Proc.Id
    $fgBefore = [LiteHonesty]::GetForegroundWindow()   # whoever the user is in right now gets it back at the end
    $holder = [LiteHonesty]::MakeHolder('control-honesty: the window the user is working in')
    [LiteHonesty]::Pump()
    $held = $false
    for ($i = 0; $i -lt 10 -and -not $held; $i++) {
        $held = [LiteHonesty]::TakeForeground($holder)
        [LiteHonesty]::Pump()
        if (-not $held) { Start-Sleep -Milliseconds 200 }
    }
    $fgName = 'this test''s own window'
    if ($held) {
        $stolen = @()
        $quickSeen = $false
        for ($i = 1; $i -le 20; $i++) {
            Send-Ctl $s @('quick', 'on') | Out-Null
            Start-Sleep -Milliseconds 150; [LiteHonesty]::Pump()
            $q = QuickHwnd
            if ($q -ne [IntPtr]::Zero -and [LiteHonesty]::IsWindowVisible($q)) { $quickSeen = $true }
            if ((FgPid) -eq $litePid) { $stolen += "quick on #$i" }
            Send-Ctl $s @('quick', 'off') | Out-Null
            Start-Sleep -Milliseconds 150; [LiteHonesty]::Pump()
            if ((FgPid) -eq $litePid) { $stolen += "quick off #$i" }
        }
        Check 'setup: quick on showed its popup during the loop (the raise path was exercised)' $quickSeen
        Check 'quick on / off twenty times: the foreground never became the lite window or its popup' ($stolen.Count -eq 0) "taken at: $($stolen -join ', ')"
        $stolen = @()
        $overlaySeen = 0
        for ($i = 1; $i -le 5; $i++) {
            Overlay @('open', 'cmd.exe') | Out-Null
            if ((Wait-Overlay $true) -ne [IntPtr]::Zero) { $overlaySeen++ }
            Start-Sleep -Milliseconds 150; [LiteHonesty]::Pump()
            if ((FgPid) -eq $litePid) { $stolen += "overlay open #$i" }
            Overlay @('close') | Out-Null
            Wait-Overlay $false | Out-Null
            Start-Sleep -Milliseconds 150; [LiteHonesty]::Pump()
            if ((FgPid) -eq $litePid) { $stolen += "overlay close #$i" }
        }
        Check 'setup: session overlay open showed its popup five times (the raise path was exercised)' ($overlaySeen -eq 5) "seen $overlaySeen"
        Check 'session overlay open / close five times: the foreground never became the lite window or its popup' ($stolen.Count -eq 0) "taken at: $($stolen -join ', ')"
        Check "and the foreground is still $fgName, where the user left it" ([LiteHonesty]::GetForegroundWindow() -eq $holder) "foreground pid $(FgPid), lite is $litePid"

        # `window select`: the raise IS the verb's purpose, so it is still made - but Windows decides
        # whether a process that is not in the foreground gets it: refused while the user has typed
        # recently, granted once input has been quiet for the foreground-lock timeout. Neither can
        # be forced from here - LockSetForegroundWindow and AllowSetForegroundWindow are the right of
        # the process the user last typed INTO (ERROR_ACCESS_DENIED for everyone else, the holder
        # included), and a test never is that process. So the check is the property the verb owes:
        # the reply matches where the foreground actually went. Which branch ran is printed; on a
        # busy desktop it is the refusal (the report's case), on an idle one or in CI the grant.
        $raw = Send-Ctl $s @('window', 'select', $s.Pipe)
        $r = ConvertFrom-Json $raw
        $fgNow = [IntPtr]::Zero
        for ($i = 0; $i -lt 10; $i++) { $fgNow = [LiteHonesty]::GetForegroundWindow(); if ($fgNow -eq $s.Hwnd) { break }; Start-Sleep -Milliseconds 100 }
        if ($fgNow -eq $s.Hwnd) {
            "  (Windows GRANTED the raise - the desktop is idle - so the granted branch is what gets checked)"
            Check 'window select whose raise Windows granted answers selected' ([bool]$r.ok -and [string]$r.result -eq 'selected') "raw: $raw"
        } else {
            "  (Windows REFUSED the raise - someone typed recently - so the refused branch is what gets checked)"
            # Still ok, with a string that is NOT `selected`: the cross-product contract pins
            # window.select on an existing window as ok + string (agwinterm answers `selected`
            # unconditionally), and ok:false here would make one script behave differently against
            # the two products on a busy desktop. The truth is in the result; ok:false is "not found".
            Check 'window select on a window Windows would not raise answers ok with `not raised:` and says the raise was refused' ([bool]$r.ok -and [string]$r.result -ne 'selected' -and [string]$r.result -match '^not raised:' -and [string]$r.result -match 'refused') "raw: $raw"
            Check "and the foreground did not move from $fgName" ($fgNow -eq $holder) "foreground pid $(FgPid), lite is $litePid"
        }
        # The granted branch, forced: the lite window is GIVEN the foreground first (the test's own
        # gesture, as a click on it would be), after which its raise of itself is a hand-off inside
        # the process that owns the foreground, which Windows always allows.
        Check 'setup: the lite window was given the foreground' ([LiteHonesty]::TakeForeground($s.Hwnd)) "foreground pid $(FgPid), lite is $litePid"
        $raw = Send-Ctl $s @('window', 'select', $s.Pipe)
        Check 'window select on the window that holds the foreground answers selected' ([string](ConvertFrom-Json $raw).result -eq 'selected') "raw: $raw"
        Check 'and it is still in front' ([LiteHonesty]::GetForegroundWindow() -eq $s.Hwnd) "foreground pid $(FgPid), lite is $litePid"
    } else {
        foreach ($n in 'quick on / off twenty times: the foreground never became the lite window or its popup',
                       'session overlay open / close five times: the foreground never became the lite window or its popup',
                       'window select answers what the foreground says (selected, or `not raised:` with the refusal)',
                       'window select on the window that holds the foreground answers selected') {
            Skip $n "$fgName could not take the foreground (pid $(FgPid) holds it - is someone typing on this machine?), so nothing can be said about who steals it"
        }
    }
    # The foreground goes back to whoever had it before the holder took it - this test process is
    # the foreground process while the holder lives, so it may hand the foreground on; then the
    # holder goes.
    if ($fgBefore -ne [IntPtr]::Zero -and [LiteHonesty]::IsWindow($fgBefore)) { [void][LiteHonesty]::SetForegroundWindow($fgBefore) }
    [void][LiteHonesty]::DestroyWindow($holder)
    [LiteHonesty]::Pump()
    Start-Sleep -Milliseconds 300

    # ---- #23: a pane never collapses to 2 columns -----------------------------------------------
    # The report: a pane at 2 columns after the window sat minimised while an agent kept calling
    # session new / select / split over the pipe. A minimised window has a 0x0 client rect, and
    # paneGridSize answered max(2, negative) = 2 for it, which every pipe-thread caller pushed to
    # the pty-host: the shell reflowed at 2 columns and the pane never came back. The oracle is the
    # grid `tree` reports per session (cols): a session created or laid out while minimised keeps
    # a real grid, and after restore the shown pane's grid is what the SAME geometry gave before
    # the minimise. The minimise is ShowWindow on the sandbox's own handle - its window, not
    # global input - and `window state` confirms it took.
    "-- #23: a minimised window --"
    function Minimized { [bool](ConvertFrom-Json (Send-Ctl $s @('window', 'state'))).result.minimized }
    function Wait-Minimized([bool]$want, [int]$ms = 4000) {
        for ($i = 0; $i -lt ($ms / 100); $i++) { if ((Minimized) -eq $want) { return $want }; Start-Sleep -Milliseconds 100 }
        return (Minimized)
    }
    function ColsOf([string]$id) { [int](Nodes | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1).cols }
    Send-Ctl $s @('session', 'split', 'off') | Out-Null
    Start-Sleep -Milliseconds 500
    $aid = [string](Nodes | Where-Object { $_.active } | Select-Object -First 1).id
    $c0 = ColsOf $aid
    Check 'setup: the shown pane has a real grid to compare against (>= 20 columns)' ([bool]$aid -and $c0 -ge 20) "active $aid cols $c0"
    [void][LiteUi]::ShowWindow($s.Hwnd, 6)    # SW_MINIMIZE, on this instance's own handle
    Check 'setup: the sandbox is minimised (window state says so)' ((Wait-Minimized $true) -eq $true)
    Start-Sleep -Milliseconds 300
    # Created while minimised: there is no rect to size from, so the create uses the grid the
    # pane's session last had. It used to be 2x2, and the shell had reflowed at 2 columns before
    # the window was ever restored.
    $raw = Send-Ctl $s @('session', 'new', '--name', 'made-minimised')
    $nid = [string](ConvertFrom-Json $raw).result
    Check 'session new while minimised answers ok with an id' ((Wait-Node $nid)) "raw: $raw"
    Check "and the new session was created at the pane's last grid, not 2x2" ((ColsOf $nid) -eq $c0) "cols $(ColsOf $nid), expected $c0"
    $raw = Send-Ctl $s @('session', 'split', 'on')
    $splitId = [string](ConvertFrom-Json $raw).result
    Check "session split on while minimised answers ok with the split's id" ([bool](ConvertFrom-Json $raw).ok -and [bool]$splitId) "raw: $raw"
    $raw = Send-Ctl $s @('session', 'select', '--target', $aid)
    Check 'session select while minimised answers ok' ([bool](ConvertFrom-Json $raw).ok) "raw: $raw"
    Start-Sleep -Milliseconds 500
    $small = @(Nodes | Where-Object { [int]$_.cols -lt 20 })
    Check 'no session in the tree collapsed while minimised (every cols >= 20)' ($small.Count -eq 0) ('collapsed: ' + (($small | ForEach-Object { "$($_.id)=$($_.cols)" }) -join ' '))
    Check 'the selected session keeps the grid the window gave it before the minimise' ((ColsOf $aid) -eq $c0) "cols $(ColsOf $aid), expected $c0"
    # `sidebar width N` while minimised: a 0x0 client makes the live-width limit refuse EVERY value
    # in range, with advice ("widen the window") that no control verb can follow. It is remembered
    # instead, reported as not applied, and the first layout after the restore puts it in effect —
    # the same "do not act now" paneGridSize answers for a non-viable rect (revmux r1).
    $wBefore = [int](ConvertFrom-Json (Sidebar @('width'))).result.width
    $rawMinW = SidebarWidthSet '250'
    $rMinW = ConvertFrom-Json $rawMinW
    Check 'sidebar width 250 while minimised is accepted, not refused' ([bool]$rMinW.ok) "raw: $rawMinW"
    Check 'and it reports the width remembered but not applied' `
        ([int]$rMinW.result.width -eq 250 -and $rMinW.result.applied -eq $false -and [string]$rMinW.result.note -match 'minimis') "result: $($rMinW.result | ConvertTo-Json -Compress)"
    [void][LiteUi]::ShowWindow($s.Hwnd, 9)    # SW_RESTORE
    Check 'setup: the sandbox is restored' ((Wait-Minimized $false) -eq $false)
    Start-Sleep -Milliseconds 800
    $rAfter = ConvertFrom-Json (Sidebar @('width'))
    Check 'and after the restore the remembered width is the one in effect' ([int]$rAfter.result.width -eq 250) "result: $($rAfter.result | ConvertTo-Json -Compress)"
    # Hand the sidebar back: every cols check below compares against $c0, measured with the width
    # this block found, and a narrower sidebar is a wider terminal.
    SidebarWidthSet "$wBefore" | Out-Null
    Wait-TreeWidth $wBefore | Out-Null
    Start-Sleep -Milliseconds 400
    Start-Sleep -Milliseconds 1000
    Check 'after restore the shown pane has the same grid as before: same geometry, same cols' ((ColsOf $aid) -eq $c0) "cols $(ColsOf $aid), expected $c0"
    # The session split while minimised: showing it lays both its panes out from the rect the
    # window has NOW - each about half the width, one pixel and one floor apart from c0/2.
    Send-Ctl $s @('session', 'select', '--target', $nid) | Out-Null
    Start-Sleep -Milliseconds 1000
    $half = ColsOf $nid
    Check 'showing the split made while minimised gives its pane half the width, not 2' ($half -ge 20 -and $half -le [int][math]::Floor($c0 / 2) -and $half -ge [int][math]::Floor($c0 / 2) - 2) "cols $half, expected about $([int][math]::Floor($c0 / 2))"
    Send-Ctl $s @('session', 'split', 'off') | Out-Null
    Send-Ctl $s @('session', 'select', '--target', $aid) | Out-Null
    Start-Sleep -Milliseconds 500
    Check 'unsplit again, the pane is back at its full grid' ((ColsOf $aid) -eq $c0) "cols $(ColsOf $aid), expected $c0"

    # ---- P3: session.context ----------------------------------------------------------------------
    # One line of free text per session. The rules and the refusal wording are agwinterm's
    # SessionContexts, verbatim; every refusal is asserted twice (the reply, then the world through
    # `tree --json`), and the presence oracle is proved first: the key is ABSENT before a set, so
    # "absent after a clear" means something. The control-character and text+clear refusals go to
    # the pipe as raw JSON: the CLI refuses text beside --clear on its own side, and a tab inside a
    # command-line argument is a quoting accident waiting to happen, while a raw `\t` is exactly the
    # byte the decoder hands the verb.
    "-- P3: session.context --"
    if (-not $cliHasP3) {
        Skip 'session.context (the whole block)' "the client at $ctl predates P3 (no `restore` command)"
    } else {
        function Ctx([string[]]$rest) { Send-Ctl $s (@('session', 'context') + $rest) }
        function CtxNode([string]$id) { Nodes | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1 }
        function HasCtx([string]$id) { $n = CtxNode $id; [bool]($n -and $n.PSObject.Properties['context']) }
        function CtxOf([string]$id) { [string](CtxNode $id).context }
        $cid = [string](Get-CtlResult $s @('session', 'new', '--name', 'ctx-a'))
        Start-Sleep -Milliseconds 800
        Check 'setup: a fresh session for the context checks' ([bool]$cid -and [bool](CtxNode $cid)) "id '$cid'"
        Check 'before any set, the tree node has NO context key (absent = none, the presence oracle)' (-not (HasCtx $cid))

        # -- set / read-back --
        $raw = Ctx @('build pane', '--target', $cid); $r = ConvertFrom-Json $raw
        Check 'session context "build pane" answers ok with an OBJECT naming the session and the value in effect' `
            ([bool]$r.ok -and [string]$r.result.session -eq $cid -and [string]$r.result.context -eq 'build pane') "raw: $raw"
        Check 'and tree --json carries it as "context" on that node' ((CtxOf $cid) -eq 'build pane') "tree: $(CtxOf $cid)"
        $raw = Ctx @('  padded  ', '--target', $cid); $r = ConvertFrom-Json $raw
        Check 'leading and trailing whitespace is trimmed, and the reply is the trimmed value' ([bool]$r.ok -and [string]$r.result.context -eq 'padded') "raw: $raw"
        Check 'and the tree has the trimmed value' ((CtxOf $cid) -eq 'padded')
        $raw = Ctx @(('x' * 200), '--target', $cid); $r = ConvertFrom-Json $raw
        Check 'exactly 200 characters is accepted (the ceiling is inclusive)' ([bool]$r.ok -and ([string]$r.result.context).Length -eq 200) "raw: $($raw.Substring(0, [math]::Min(80, $raw.Length)))"

        # -- refusals: each leaves the 200 x's in place --
        $x200 = 'x' * 200
        $raw = Ctx @(('x' * 201), '--target', $cid); $r = ConvertFrom-Json $raw
        Check '201 characters is refused naming the count and the ceiling' `
            (-not $r.ok -and [string]$r.error -eq 'session context: 201 characters is over the ceiling of 200; the ceiling is a display budget (the title bar and the sidebar row draw the context beside the name). Nothing changed.') "raw: $raw"
        Check 'and the tree still has the 200' ((CtxOf $cid) -eq $x200)
        $raw = Ctx @(' ', '--target', $cid); $r = ConvertFrom-Json $raw
        Check 'a whitespace-only value is refused as blank, naming --clear as the way to remove one' `
            (-not $r.ok -and [string]$r.error -eq 'session context: the text is blank; a context is one line of printable text, and `session context --clear` removes one. Nothing changed.') "raw: $raw"
        Check 'and the tree still has the 200' ((CtxOf $cid) -eq $x200)
        $raw = Send-Raw ('{"cmd":"session.context","target":"' + $cid + '","args":{"context":""}}'); $r = ConvertFrom-Json $raw
        Check 'a raw present-but-empty "context":"" is the blank refusal, not a clear' (-not $r.ok -and [string]$r.error -match '^session context: the text is blank') "raw: $raw"
        Check 'and the tree still has the 200' ((CtxOf $cid) -eq $x200)
        $raw = Send-Raw ('{"cmd":"session.context","target":"' + $cid + '","args":{}}'); $r = ConvertFrom-Json $raw
        Check 'a raw request with neither text nor --clear is the blank refusal' (-not $r.ok -and [string]$r.error -match '^session context: the text is blank') "raw: $raw"
        $raw = Send-Raw ('{"cmd":"session.context","target":"' + $cid + '","args":{"context":"a\tb"}}'); $r = ConvertFrom-Json $raw
        Check 'a decoded tab is refused as a control character, naming U+0009 and offset 1' `
            (-not $r.ok -and [string]$r.error -eq 'session context: control character U+0009 at offset 1; a context is one line of printable text (no newline, tab or escape). Nothing changed.') "raw: $raw"
        Check 'and the tree still has the 200' ((CtxOf $cid) -eq $x200)
        $raw = Send-Raw ('{"cmd":"session.context","target":"' + $cid + '","args":{"context":"\u0001abc"}}'); $r = ConvertFrom-Json $raw
        Check 'a \u0001 at the start is refused naming U+0001 at offset 0' (-not $r.ok -and [string]$r.error -match 'U\+0001 at offset 0;') "raw: $raw"
        $raw = Send-Raw ('{"cmd":"session.context","target":"' + $cid + '","args":{"context":"  x\u0085"}}'); $r = ConvertFrom-Json $raw
        Check 'a trailing NEL (U+0085) is refused as a control character, not trimmed away (offset counts the untrimmed text)' `
            (-not $r.ok -and [string]$r.error -match 'U\+0085 at offset 3;') "raw: $raw"
        $raw = Send-Raw ('{"cmd":"session.context","target":"' + $cid + '","args":{"context":"ab\ud83d\ude80\tc"}}'); $r = ConvertFrom-Json $raw
        Check 'the offset is in UTF-16 code units (agwinterm string.Length): a tab after a surrogate pair is at offset 4' `
            (-not $r.ok -and [string]$r.error -match 'U\+0009 at offset 4;') "raw: $raw"
        $raw = Send-Raw ('{"cmd":"session.context","target":"' + $cid + '","args":{"context":"x","clear":true}}'); $r = ConvertFrom-Json $raw
        Check 'text beside --clear is refused with agwinterm TextAndClear wording' `
            (-not $r.ok -and [string]$r.error -eq 'session context: text and --clear cannot be combined (one says what the context is, the other that there is none). Nothing changed.') "raw: $raw"
        Check 'and the tree still has the 200' ((CtxOf $cid) -eq $x200)
        $raw = Ctx @('x', '--target', 'no-such-session-zzz'); $r = ConvertFrom-Json $raw
        Check 'an unknown target is refused with SessionContexts.NoSession wording' (-not $r.ok -and [string]$r.error -eq 'session not found; nothing changed') "raw: $raw"
        Check 'and the tree still has the 200' ((CtxOf $cid) -eq $x200)
        $raw = Ctx @('x', '--clear', '--target', $cid)   # not JSON: the CLI refuses before any pipe
        Check 'the CLI refuses text beside --clear on its own side (nothing sent)' ($raw -match 'cannot be combined' -and $raw -notmatch '"ok"') "raw: $raw"
        Check 'and the tree still has the 200' ((CtxOf $cid) -eq $x200)

        # -- a non-BMP character round-trips (jsonParseString recombines the surrogate pair) --
        $raw = Send-Raw ('{"cmd":"session.context","target":"' + $cid + '","args":{"context":"caf\u00e9 \ud83d\ude80 go"}}'); $r = ConvertFrom-Json $raw
        $rocket = 'caf' + [char]0xE9 + ' ' + [char]::ConvertFromUtf32(0x1F680) + ' go'
        Check 'a context with an accent and a non-BMP character is accepted and read back intact' ([bool]$r.ok -and [string]$r.result.context -eq $rocket) "raw: $raw"
        Check 'and the tree carries it intact' ((CtxOf $cid) -eq $rocket) "tree: $(CtxOf $cid)"

        # -- clear --
        $raw = Ctx @('--clear', '--target', $cid); $r = ConvertFrom-Json $raw
        Check 'session context --clear answers ok with "context":null (the key present, the value null)' `
            ([bool]$r.ok -and [string]$r.result.session -eq $cid -and $r.result.PSObject.Properties['context'] -and $null -eq $r.result.context) "raw: $raw"
        Check 'and the tree node has no context key any more' (-not (HasCtx $cid))
        $raw = Ctx @('--clear', '--target', $cid); $r = ConvertFrom-Json $raw
        Check '--clear on a session with no context is ok and null (idempotent)' ([bool]$r.ok -and $null -eq $r.result.context) "raw: $raw"

        # -- a rename leaves the context alone (two fields) --
        Ctx @('after rename', '--target', $cid) | Out-Null
        Send-Ctl $s @('session', 'rename', 'ctx-renamed', '--target', $cid) | Out-Null
        Start-Sleep -Milliseconds 300
        $n = CtxNode $cid
        Check 'session rename changes the name and leaves the context exactly as it was' ([string]$n.name -eq 'ctx-renamed' -and [string]$n.context -eq 'after rename') "node: $($n | ConvertTo-Json -Compress)"
        $raw = Ctx @('by name', '--target', 'ctx-renamed'); $r = ConvertFrom-Json $raw
        Check 'and the target resolves by the NEW name, the same resolution rename uses' ([bool]$r.ok -and [string]$r.result.session -eq $cid -and (CtxOf $cid) -eq 'by name') "raw: $raw"

        # -- a hidden session (a split shell) is refused: no row, no S line, no C slot --
        Send-Ctl $s @('session', 'select', '--target', $cid) | Out-Null
        Start-Sleep -Milliseconds 300
        $splitId = [string](Get-CtlResult $s @('session', 'split', 'on'))
        Start-Sleep -Milliseconds 800
        Check 'setup: session split answers the split shell id, which is not in the tree' ([bool]$splitId -and -not (CtxNode $splitId)) "split '$splitId'"
        $before = @(Nodes).Count
        $raw = Ctx @('hidden', '--target', $splitId); $r = ConvertFrom-Json $raw
        Check 'session context on the split shell is refused, naming the id and why (no row, no session line)' `
            (-not $r.ok -and [string]$r.error -eq "session context: '$splitId' is a split, scratch, overlay or quick pane; it has no sidebar row and no session line in the state file, so it has no context to set. Nothing changed.") "raw: $raw"
        Check 'and nothing appeared in the tree, and the owner kept its own context' (@(Nodes).Count -eq $before -and (CtxOf $cid) -eq 'by name')
        Send-Ctl $s @('session', 'split', 'off') | Out-Null
        Start-Sleep -Milliseconds 300

        # -- undo-close: the context rides on the ClosedSpec beside the name and comes back with it --
        # Ctrl+Shift+T is IDM_REOPEN (122 in main.cpp's command table) and there is no control verb
        # for it, so the WM_COMMAND is posted to the sandbox's OWN window handle - the message the
        # accelerator and the File menu send, never global input.
        Send-Ctl $s @('session', 'close', '--target', $cid) | Out-Null
        $gone = $false
        for ($i = 0; $i -lt 20; $i++) { if (-not (CtxNode $cid)) { $gone = $true; break }; Start-Sleep -Milliseconds 200 }
        Check 'setup: the session carrying a context was closed (gone from the tree)' $gone
        [void][LiteHonesty]::PostMessageW($s.Hwnd, 0x0111, [IntPtr]122, [IntPtr]::Zero)   # WM_COMMAND, IDM_REOPEN
        $re = $null
        for ($i = 0; $i -lt 25; $i++) { $re = Nodes | Where-Object { [string]$_.name -eq 'ctx-renamed' } | Select-Object -First 1; if ($re) { break }; Start-Sleep -Milliseconds 200 }
        Check 'Reopen Closed Session (IDM_REOPEN) brings the session back under its name' ([bool]$re) "nodes: $((Nodes | ForEach-Object name) -join ', ')"
        Check 'and with its context - the ClosedSpec carries both, so undo-close keeps what the row showed' ($re -and [string]$re.context -eq 'by name') "node: $($re | ConvertTo-Json -Compress)"
        if ($re) { Send-Ctl $s @('session', 'close', '--target', ([string]$re.id)) | Out-Null; Start-Sleep -Milliseconds 500 }
        Send-Ctl $s @('session', 'select', '--target', $aid) | Out-Null
        Start-Sleep -Milliseconds 300
    }

    # ---- P3: restore.capture ------------------------------------------------------------------------
    # Capture the foreground command of every real pane (or of one named pane) into a durable slot
    # NOW, save, and report per pane. The reply is agwinterm's RestoreCaptureReply object, the
    # refusal wording is agwinterm's verbatim, and every refusal is asserted twice: the reply, then
    # the world — `tree --json`'s capturedCommands AND the K line in the state file, since "nothing
    # saved" is a claim about the disk. The presence oracle is proved first (no node carries the key
    # and the file has no K line before the first capture). The foreground child is a `ping` typed
    # into the pane: a real process under the pane's shell, found by the same Toolhelp32 walk the
    # verb runs, and stopped again by its distinctive argument.
    "-- P3: restore.capture --"
    if (-not $cliHasP3) {
        Skip 'restore.capture (the whole block)' "the client at $ctl predates P3 (no `restore` command)"
    } else {
        # An empty element (a setup that answered no id) would make Send-Ctl throw and take the whole
        # suite down; answered as a refusal instead, so the check that reads it fails and names it.
        function Cap([string[]]$rest) {
            if (@($rest | Where-Object { -not $_ }).Count -gt 0) { return '{"ok":false,"error":"(test: an empty argument reached restore capture)"}' }
            Send-Ctl $s (@('restore', 'capture') + $rest)
        }
        function CapNode([string]$id) { Nodes | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1 }
        function CapsOf([string]$id) {   # the node's capturedCommands as "key=value;..." or '' when absent
            $n = CapNode $id
            if (-not $n -or -not $n.PSObject.Properties['capturedCommands']) { return '' }
            (@($n.capturedCommands.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';')
        }
        function AnyCaps { [bool](Nodes | Where-Object { $_.PSObject.Properties['capturedCommands'] }) }
        $stateFile = Join-Path $s.AppDir "agliteterm\sessions-$($s.Pipe).tsv"
        function KLines { @((Get-Content $stateFile -Raw) -split "`n" | Where-Object { $_ -like "K`t*" } | ForEach-Object { $_.TrimEnd("`r") }) }
        # The pings: `-n 3xx 127.0.0.1` is the marker each one is found and stopped by.
        function Ping-Procs([string]$n) { @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { $_.CommandLine -match "-n $n 127\.0\.0\.1" }) }
        function Wait-Ping([string]$n, [bool]$present, [int]$ms = 8000) {
            for ($i = 0; $i -lt ($ms / 200); $i++) { if ((@(Ping-Procs $n).Count -gt 0) -eq $present) { return $true }; Start-Sleep -Milliseconds 200 }
            return $false
        }
        function Stop-Ping([string]$n) { Ping-Procs $n | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; [void](Wait-Ping $n $false) }
        $capId = [string](Get-CtlResult $s @('session', 'new', '--name', 'cap-a'))
        Start-Sleep -Milliseconds 800
        Check 'setup: a fresh session for the capture checks' ([bool]$capId -and [bool](CapNode $capId)) "id '$capId'"
        Check 'before any capture, no node carries capturedCommands and the file has no K line (the presence oracle)' (-not (AnyCaps) -and @(KLines).Count -eq 0) "K: $(KLines -join ' / ')"
        Send-Ctl $s @('session', 'select', '--target', $capId) | Out-Null
        Start-Sleep -Milliseconds 300
        $capSplit = [string](Get-CtlResult $s @('session', 'split', 'on'))
        Start-Sleep -Milliseconds 1500
        Check 'setup: cap-a has a split shell, addressed by the id session split answered' ([bool]$capSplit -and -not (CapNode $capSplit)) "split '$capSplit'"
        Stop-Ping '303'; Stop-Ping '305'   # a leftover from an aborted run would be found under the wrong shell
        Send-Ctl $s @('session', 'type', "ping -n 303 127.0.0.1`n", '--target', $capId) | Out-Null
        Check 'setup: a ping is running under the cap-a shell' (Wait-Ping '303' $true)
        Start-Sleep -Milliseconds 500

        # -- the bare call: every real pane --
        $raw = Cap @(); $r = ConvertFrom-Json $raw
        $expectPanes = @(Nodes).Count + 1   # every visible session, plus cap-a's split
        Check 'restore capture answers ok with an OBJECT: captured 1, replayOnRestore false, panes an array' `
            ([bool]$r.ok -and [int]$r.result.captured -eq 1 -and $r.result.replayOnRestore -eq $false -and $r.result.panes -is [array]) "raw: $raw"
        Check 'panes lists every real pane: each visible session and the one split, each with pane/session/captured' `
            (@($r.result.panes).Count -eq $expectPanes -and -not ($r.result.panes | Where-Object { -not ($_.PSObject.Properties['pane'] -and $_.PSObject.Properties['session'] -and $_.PSObject.Properties['captured']) })) "panes: $(@($r.result.panes).Count), expected $expectPanes; raw: $raw"
        $mine = $r.result.panes | Where-Object { [string]$_.pane -eq $capId }
        Check 'the cap-a pane captured the ping command line, under its own session id' ([string]$mine.session -eq $capId -and [string]$mine.captured -match 'PING\.EXE" -n 303 127\.0\.0\.1$') "pane: $($mine | ConvertTo-Json -Compress)"
        $sp = $r.result.panes | Where-Object { [string]$_.pane -eq $capSplit }
        Check 'the split pane is listed under cap-a (session = the owner) with captured null' ([string]$sp.session -eq $capId -and $sp.PSObject.Properties['captured'] -and $null -eq $sp.captured) "pane: $($sp | ConvertTo-Json -Compress)"
        Check 'every other pane is null (idle shells; the shells themselves are denylisted)' (-not ($r.result.panes | Where-Object { [string]$_.pane -ne $capId -and $null -ne $_.captured })) "raw: $raw"
        Check 'tree --json reads it back as capturedCommands on the cap-a node, keyed by pane id, the idle split absent' ((CapsOf $capId) -match "^$([regex]::Escape($capId))=.*-n 303 127\.0\.0\.1$") "caps: $(CapsOf $capId)"
        Check 'and no other node carries the key' (@(Nodes | Where-Object { $_.PSObject.Properties['capturedCommands'] }).Count -eq 1)
        $k = @(KLines)
        Check 'the state file has ONE K line: index, the pane-0 command, an empty pane-1 field' (@($k).Count -eq 1 -and $k[0] -match "^K`t\d+`t[^`t]*-n 303 127\.0\.0\.1`t$") "K: $($k -join ' / ')"

        # -- two captures back to back: two clients at once, each answered from what it wrote, one
        # state file between them. The verb saves on the pipe thread, so two callers are two savers
        # on the same .tmp - g_saveLock serializes them; without it one publish fails or the file
        # interleaves, and the reply would describe a state that is not on disk. --
        $outs = @((New-TemporaryFile).FullName, (New-TemporaryFile).FullName)
        $procs = @(0, 1 | ForEach-Object { Start-Process -FilePath $ctl -ArgumentList @('restore', 'capture', '--pipe', $s.Pipe, '--json') -NoNewWindow -PassThru -RedirectStandardOutput $outs[$_] })
        $procs | ForEach-Object { [void]$_.WaitForExit(15000) }
        $both = @($outs | ForEach-Object { try { ConvertFrom-Json ((Get-Content $_ -Raw) -replace '\s+$', '') } catch { $null } })
        Remove-Item $outs -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500   # the refresh each one posted saves once more on the UI thread
        Check 'two concurrent captures both answer ok, each with the ping captured' (@($both).Count -eq 2 -and -not ($both | Where-Object { -not $_ -or -not $_.ok -or [int]$_.result.captured -ne 1 })) "replies: $($both | ConvertTo-Json -Compress -Depth 5)"
        $k = @(KLines)
        Check 'and the file has the one K line it had, intact, with no .tmp left beside it' (@($k).Count -eq 1 -and $k[0] -match "^K`t\d+`t[^`t]*-n 303 127\.0\.0\.1`t$" -and -not (Test-Path "$stateFile.tmp")) "K: $($k -join ' / '); tmp left: $(Test-Path "$stateFile.tmp")"
        Check 'and the tree still reads the slot back' ((CapsOf $capId) -match "-n 303 127\.0\.0\.1$") "caps: $(CapsOf $capId)"

        # -- one pane by id: the split --
        Send-Ctl $s @('session', 'type', "ping -n 305 127.0.0.1`n", '--target', $capSplit) | Out-Null
        Check 'setup: a second ping is running under the split shell' (Wait-Ping '305' $true)
        Start-Sleep -Milliseconds 500
        $raw = Cap @('--target', $capSplit); $r = ConvertFrom-Json $raw
        Check 'restore capture --target <split id> captures that ONE pane: one entry, pane = the split, session = cap-a' `
            ([bool]$r.ok -and @($r.result.panes).Count -eq 1 -and [string]$r.result.panes[0].pane -eq $capSplit -and [string]$r.result.panes[0].session -eq $capId -and [string]$r.result.panes[0].captured -match '-n 305 127\.0\.0\.1$' -and [int]$r.result.captured -eq 1) "raw: $raw"
        Check 'and the tree now carries both pane keys on the cap-a node' ((CapsOf $capId) -match "^$([regex]::Escape($capId))=.*-n 303 .*;$([regex]::Escape($capSplit))=.*-n 305 ") "caps: $(CapsOf $capId)"
        $k = @(KLines)
        Check 'and the K line carries both fields' (@($k).Count -eq 1 -and $k[0] -match "^K`t\d+`t[^`t]*-n 303 127\.0\.0\.1`t[^`t]*-n 305 127\.0\.0\.1$") "K: $($k -join ' / ')"
        # -- one pane by session NAME: the session's own shell --
        $raw = Cap @('--target', 'cap-a'); $r = ConvertFrom-Json $raw
        Check 'restore capture --target <session name> captures that session own shell only (pane 0)' `
            ([bool]$r.ok -and @($r.result.panes).Count -eq 1 -and [string]$r.result.panes[0].pane -eq $capId -and [string]$r.result.panes[0].captured -match '-n 303 ') "raw: $raw"

        # -- refusals: each leaves both slots and the file exactly as they are --
        $capsBefore = CapsOf $capId; $kBefore = (KLines) -join "`n"
        function World-Unchanged { ((CapsOf $capId) -eq $capsBefore) -and (((KLines) -join "`n") -eq $kBefore) }
        $raw = Cap @('--target', 'no-such-pane-zz'); $r = ConvertFrom-Json $raw
        Check 'an unknown target is refused in the verb own words, naming the target' `
            (-not $r.ok -and [string]$r.error -eq "restore capture: no pane or session matches 'no-such-pane-zz'. Nothing captured, nothing saved.") "raw: $raw"
        Check 'and no slot changed, no K line changed' (World-Unchanged) "caps: $(CapsOf $capId); K: $((KLines) -join ' / ')"
        $raw = Send-Raw '{"cmd":"restore.capture","target":""}'; $r = ConvertFrom-Json $raw
        Check 'a raw present-but-empty "target":"" is refused with EmptyTarget wording (not widened to every pane)' `
            (-not $r.ok -and [string]$r.error -eq 'restore capture: the target is empty. Omit --target to capture every real pane, or name one pane or session. Nothing captured, nothing saved.') "raw: $raw"
        Check 'and no slot changed, no K line changed' (World-Unchanged)
        $raw = (& $ctl restore capture --target '' --pipe $s.Pipe --json 2>&1) -join ''
        Check 'the CLI refuses an empty --target on its own side (nothing sent)' ($raw -match 'Nothing sent' -and $raw -notmatch '"ok"') "raw: $raw"
        Check 'and no slot changed, no K line changed' (World-Unchanged)
        # a cover pane: the scratch pad, hidden, no S line, no K slot; its id arrives as a created
        # event. Scratch rather than quick: a dismissed scratch pad is torn down, so `on` always
        # creates a fresh session and emits the event, while the quick session survives its own
        # `off` and a later `on` re-shows it silently (the stdin section above may have made one).
        $cursor = [long](ConvertFrom-Json (Send-Ctl $s @('events'))).result.cursor
        Send-Raw '{"cmd":"session.scratch","target":"","args":{"op":"on"}}' | Out-Null
        Start-Sleep -Milliseconds 2500
        $created = @((ConvertFrom-Json (Send-Ctl $s @('events', '--since', "$cursor"))).result.events | Where-Object { $_.type -eq 'session' -and $_.info -eq 'created' })
        $qid = [string]($created | Select-Object -Last 1).session
        Check 'setup: the scratch pad session id arrived as a session/created event, and it is hidden from tree' ([bool]$qid -and -not (CapNode $qid)) "events: $($created | ConvertTo-Json -Compress)"
        $raw = Cap @('--target', $qid); $r = ConvertFrom-Json $raw
        Check 'a scratch pane is refused with CoverPane wording (never restored, so no slot)' `
            (-not $r.ok -and [string]$r.error -eq "restore capture: '$qid' is a scratch/overlay/quick pane, which is never restored, so it has no restore slot to capture into. Nothing captured, nothing saved.") "raw: $raw"
        Check 'and no slot changed, no K line changed' (World-Unchanged)
        Send-Raw '{"cmd":"session.scratch","target":"","args":{"op":"off"}}' | Out-Null
        Start-Sleep -Milliseconds 500
        # the quick terminal, the other cover: it survives its own `off`, so the stdin section's
        # `quick on` may have made it already and a second `on` re-shows it without a created event -
        # the id is the event's when one arrives, else the one that section recorded.
        $cursor = [long](ConvertFrom-Json (Send-Ctl $s @('events'))).result.cursor
        Send-Ctl $s @('quick', 'on') | Out-Null
        Start-Sleep -Milliseconds 2000
        $created = @((ConvertFrom-Json (Send-Ctl $s @('events', '--since', "$cursor"))).result.events | Where-Object { $_.type -eq 'session' -and $_.info -eq 'created' })
        $quickId = if ($created) { [string]($created | Select-Object -Last 1).session } else { [string]$quickSid }
        Check 'setup: the quick session id is known, and it is hidden from tree' ([bool]$quickId -and -not (CapNode $quickId)) "quick '$quickId'"
        $raw = Cap @('--target', $quickId); $r = ConvertFrom-Json $raw
        Check 'a quick pane is refused with CoverPane wording too (hidden, never restored, so no slot)' `
            (-not $r.ok -and [string]$r.error -eq "restore capture: '$quickId' is a scratch/overlay/quick pane, which is never restored, so it has no restore slot to capture into. Nothing captured, nothing saved.") "raw: $raw"
        Check 'and no slot changed, no K line changed' (World-Unchanged)
        Send-Ctl $s @('quick', 'off') | Out-Null
        Start-Sleep -Milliseconds 500

        # -- a fresh capture replaces the checkpoint, including with nothing --
        Stop-Ping '303'
        $raw = Cap @(); $r = ConvertFrom-Json $raw
        $mine = $r.result.panes | Where-Object { [string]$_.pane -eq $capId }
        Check 'with the ping gone, a bare capture writes null into the cap-a pane and counts only the split' `
            ([bool]$r.ok -and $null -eq $mine.captured -and [int]$r.result.captured -eq 1) "raw: $raw"
        Check 'the tree keeps only the split key' ((CapsOf $capId) -match "^$([regex]::Escape($capSplit))=.*-n 305 ") "caps: $(CapsOf $capId)"
        $k = @(KLines)
        Check 'and the K line has an empty pane-0 field and the split command' (@($k).Count -eq 1 -and $k[0] -match "^K`t\d+`t`t[^`t]*-n 305 127\.0\.0\.1$") "K: $($k -join ' / ')"
        Stop-Ping '305'
        $raw = Cap @('--target', $capSplit); $r = ConvertFrom-Json $raw
        Check 'capturing the idle split by id writes null there too' ([bool]$r.ok -and $null -eq $r.result.panes[0].captured -and [int]$r.result.captured -eq 0) "raw: $raw"
        Check 'and with both slots empty the node has no capturedCommands key and the file no K line' (-not (AnyCaps) -and @(KLines).Count -eq 0) "caps: $(CapsOf $capId); K: $((KLines) -join ' / ')"

        # -- a capture while the pane's child is exiting: null or the command, never a crash --
        # A short ping is typed in and the pane is captured as fast as the pipe answers until the
        # ping is gone, and once more after. Every reply is ok, every value is one of the two truthful
        # answers (the command while it runs, null once it has gone), and the sandbox is still there
        # to say so - a pid that vanishes between the snapshot and the PEB read is the case.
        Stop-Ping '4'
        Send-Ctl $s @('session', 'type', "ping -n 4 127.0.0.1`n", '--target', $capId) | Out-Null
        Check 'setup: a 4-count ping is running under the cap-a shell' (Wait-Ping '4' $true)
        $replies = @(); $bad = @(); $sawCmd = 0; $sawNull = 0
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            $raw = Cap @('--target', $capId); $replies += $raw
            $r = try { ConvertFrom-Json $raw } catch { $null }
            if (-not $r -or -not $r.ok -or @($r.result.panes).Count -ne 1) { $bad += $raw }
            elseif ($null -eq $r.result.panes[0].captured) { $sawNull++ }
            elseif ([string]$r.result.panes[0].captured -match '-n 4 127\.0\.0\.1$') { $sawCmd++ }
            else { $bad += $raw }
            if (@(Ping-Procs '4').Count -eq 0 -and $sawNull -gt 0) { break }
        }
        Check "every capture across the child's exit answered ok with the command or null ($sawCmd command, $sawNull null, $(@($replies).Count) in all)" (@($bad).Count -eq 0 -and $sawCmd -ge 1 -and $sawNull -ge 1) "bad: $($bad -join ' / ')"
        Check 'the ping ended on its own and the last capture read null' (@(Ping-Procs '4').Count -eq 0 -and $sawNull -gt 0) "null seen $sawNull"
        Check 'and the sandbox is alive: ping answers and the process is running' ([bool](ConvertFrom-Json (Send-Ctl $s @('ping'))).ok -and -not $s.Proc.HasExited)
        Check 'and with the child gone the slot is empty again (no K line)' (-not (AnyCaps) -and @(KLines).Count -eq 0) "caps: $(CapsOf $capId); K: $((KLines) -join ' / ')"
        Send-Ctl $s @('session', 'split', 'off') | Out-Null
        Start-Sleep -Milliseconds 300
        Send-Ctl $s @('session', 'close', '--target', $capId) | Out-Null
        Start-Sleep -Milliseconds 500
        Send-Ctl $s @('session', 'select', '--target', $aid) | Out-Null
        Start-Sleep -Milliseconds 300
    }

    # ---- P4: splits — the axis, the target, the tree's split block, `session focus` ----------------
    # The axis is provable from the grid, no capture: a horizontal split gives each pane about half
    # the single-pane ROWS at the full COLUMN count, a vertical one half the columns at the full
    # rows. Every `session split` reply is a pane id read off state that exists (a bare string);
    # every refusal is agwinterm's sentence (SplitAxes.cs) and is asserted twice — the reply, then
    # the world through `tree --json`. `session focus` is judged by SLOT against the axis: the pair
    # that does not exist on the axis is refused naming it. A session not on screen can be split
    # without moving focus or selection (#230). Task 2 adds `split close` and the promotion, Task 3
    # `session swap`, to this block.
    "-- P4: splits --"
    if (-not $cliHasP4) {
        Skip 'P4 splits (the whole block)' "the client at $ctl predates P4 (no `session swap`)"
    } else {
        function Node([string]$id) { Nodes | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1 }
        function SplitBlock([string]$id) {   # "paneCount|paneIds|focusedPane|axis", or '' when the node has no split block
            $n = Node $id
            if (-not $n -or -not $n.PSObject.Properties['paneCount']) { return '' }
            "$($n.paneCount)|$(@($n.paneIds) -join ',')|$($n.focusedPane)|$($n.axis)"
        }
        function Cursor { [long](ConvertFrom-Json (Send-Ctl $s @('events'))).result.cursor }
        function EvSince([long]$cursor, [string]$type) { @((ConvertFrom-Json (Send-Ctl $s @('events', '--since', "$cursor"))).result.events | Where-Object { $_.type -eq $type }).Count }
        function HalfOf([int]$n, [int]$whole) { $n -le [math]::Floor($whole / 2) -and $n -ge [math]::Floor($whole / 2) - 2 }
        Send-Ctl $s @('session', 'split', 'off') | Out-Null
        Start-Sleep -Milliseconds 400
        $aid = [string](Nodes | Where-Object { $_.active } | Select-Object -First 1).id
        $n0 = Node $aid
        $c0 = [int]$n0.cols; $r0 = [int]$n0.rows
        Check 'setup: one active single-pane session with a real grid, and no split block on it' ([bool]$aid -and $c0 -ge 20 -and $r0 -ge 10 -and (SplitBlock $aid) -eq '') "active $aid ${c0}x${r0} block '$(SplitBlock $aid)'"
        # Validation before anything happens: the axis, the op (raw — the CLI refuses it first), the target.
        $raw = Send-Ctl $s @('session', 'split', 'on', '--axis', 'diagonal', '--target', $aid)
        $r = ConvertFrom-Json $raw
        Check 'split on --axis diagonal is refused naming both words' (-not $r.ok -and [string]$r.error -eq "axis 'diagonal' is not one of vertical (left/right panes) or horizontal (top/bottom panes); nothing was split") "raw: $raw"
        Check 'and nothing was split: no split block, the grid unchanged' ((SplitBlock $aid) -eq '' -and [int](Node $aid).cols -eq $c0) "block '$(SplitBlock $aid)' cols $((Node $aid).cols)"
        $raw = Send-Raw ('{"cmd":"session.split","target":"' + $aid + '","args":{"op":"Close"}}')
        $r = ConvertFrom-Json $raw
        Check 'a raw op outside on/off/toggle is refused, not treated as a toggle' (-not $r.ok -and [string]$r.error -match '^session split: unknown op Close ' -and [string]$r.error -match 'an unknown op is not a toggle') "raw: $raw"
        Check 'and nothing was split' ((SplitBlock $aid) -eq '') "block '$(SplitBlock $aid)'"
        $raw = Send-Ctl $s @('session', 'split', 'on', '--target', 'no-such-session-9999')
        Check 'split on an unknown target is refused' (-not (ConvertFrom-Json $raw).ok -and (SplitBlock $aid) -eq '') "raw: $raw"
        # A cover is no session to split (the scratch pad: created fresh by `on`, its id arrives as an event).
        $cur = Cursor
        Send-Raw '{"cmd":"session.scratch","target":"","args":{"op":"on"}}' | Out-Null
        Start-Sleep -Milliseconds 2500
        $created = @((ConvertFrom-Json (Send-Ctl $s @('events', '--since', "$cur"))).result.events | Where-Object { $_.type -eq 'session' -and $_.info -eq 'created' })
        $covId = [string]($created | Select-Object -Last 1).session
        Check 'setup: the scratch pad session id arrived as a session/created event' ([bool]$covId) "events: $($created | ConvertTo-Json -Compress)"
        $raw = Send-Ctl $s @('session', 'split', 'on', '--target', $covId)
        $r = ConvertFrom-Json $raw
        Check 'split on a scratch cover is refused as no session, naming its dismissing verb' (-not $r.ok -and [string]$r.error -eq "session split: '$covId' is a scratch/overlay/quick pane, not a session; ``session scratch off``, ``session overlay close`` or ``quick off`` dismiss those. Nothing was split.") "raw: $raw"
        Send-Raw '{"cmd":"session.scratch","target":"","args":{"op":"off"}}' | Out-Null
        Start-Sleep -Milliseconds 500
        Check 'and no session gained a split block' (@(Nodes | Where-Object { $_.PSObject.Properties['paneCount'] }).Count -eq 0)
        # A horizontal split: rows halve, cols stay; the node gains the split block; `tree` fires.
        $cur = Cursor
        $raw = Send-Ctl $s @('session', 'split', 'on', '--axis', 'horizontal', '--target', $aid)
        $r = ConvertFrom-Json $raw
        $sid = [string]$r.result
        Check 'split on --axis horizontal answers ok with the split pane id, a bare string' ([bool]$r.ok -and $sid -and $sid -ne $aid -and $sid -ne 'ok') "raw: $raw"
        Start-Sleep -Milliseconds 800
        $n1 = Node $aid
        Check 'the node gains the split block: paneCount 2, paneIds [session, split], focusedPane 0, axis horizontal' ((SplitBlock $aid) -eq "2|$aid,$sid|0|horizontal") "block '$(SplitBlock $aid)'"
        Check 'and its pane has about half the rows at the full width: the axis, read off the grid' ([int]$n1.cols -eq $c0 -and (HalfOf ([int]$n1.rows) $r0)) "grid $($n1.cols)x$($n1.rows), single was ${c0}x${r0}"
        Check 'the split emitted a tree event' ((EvSince $cur 'tree') -ge 1)
        Check 'the split shell has no node of its own' ($null -eq (Node $sid))
        $raw = Send-Ctl $s @('session', 'split', 'on', '--target', $aid)
        Check 'split on when already split answers the slot-1 pane id and changes nothing' ([string](ConvertFrom-Json $raw).result -eq $sid -and (SplitBlock $aid) -eq "2|$aid,$sid|0|horizontal") "raw: $raw, block '$(SplitBlock $aid)'"
        $raw = Send-Ctl $s @('session', 'split', 'on', '--target', $sid)
        Check "split on targeting the split shell's own id lands on its owner" ([string](ConvertFrom-Json $raw).result -eq $sid -and (SplitBlock $aid) -eq "2|$aid,$sid|0|horizontal") "raw: $raw"
        # focus: each word by slot, judged against the axis.
        foreach ($w in @('right', 'left')) {
            $raw = Send-Ctl $s @('session', 'focus', $w)
            $r = ConvertFrom-Json $raw
            Check "focus $w on a horizontal split is refused naming the axis" (-not $r.ok -and [string]$r.error -eq "'$w' names no pane on a horizontal split (top/bottom panes); use top, bottom, primary, split or other") "raw: $raw"
        }
        Check 'and the focus did not move' ((SplitBlock $aid) -eq "2|$aid,$sid|0|horizontal") "block '$(SplitBlock $aid)'"
        $raw = Send-Ctl $s @('session', 'focus', 'bottom')
        Start-Sleep -Milliseconds 300
        Check 'focus bottom moves the focus to slot 1' ([bool](ConvertFrom-Json $raw).ok -and (SplitBlock $aid) -eq "2|$aid,$sid|1|horizontal") "raw: $raw, block '$(SplitBlock $aid)'"
        Check 'and the session node stays active with its split pane focused (no node was, before P4)' ([bool](Node $aid).active)
        $raw = Send-Ctl $s @('session', 'focus')
        Start-Sleep -Milliseconds 300
        Check 'focus with no word is `other`: back to slot 0' ((SplitBlock $aid) -eq "2|$aid,$sid|0|horizontal") "raw: $raw, block '$(SplitBlock $aid)'"
        foreach ($pair in @(@('split', 1), @('primary', 0), @('top', 0))) {
            Send-Ctl $s @('session', 'focus', $pair[0]) | Out-Null
            Start-Sleep -Milliseconds 200
            Check "focus $($pair[0]) lands on slot $($pair[1])" ((SplitBlock $aid) -eq "2|$aid,$sid|$($pair[1])|horizontal") "block '$(SplitBlock $aid)'"
        }
        $raw = Send-Ctl $s @('session', 'focus', 'sideways')
        Check 'focus with a word outside the list is refused naming the list' (-not (ConvertFrom-Json $raw).ok -and [string](ConvertFrom-Json $raw).error -eq "focus 'sideways' is not one of primary, split, left, right, top, bottom or other") "raw: $raw"
        # Re-orient live: cols halve, rows come back, `tree` fires; the other pair is refused now.
        $cur = Cursor
        $raw = Send-Ctl $s @('session', 'split', 'on', '--axis', 'vertical', '--target', $aid)
        Start-Sleep -Milliseconds 800
        $n2 = Node $aid
        Check 'split on --axis vertical on the split session re-orients it live and answers the slot-1 id' ([string](ConvertFrom-Json $raw).result -eq $sid -and (SplitBlock $aid) -eq "2|$aid,$sid|0|vertical") "raw: $raw, block '$(SplitBlock $aid)'"
        Check 'and now the pane has about half the columns at the full height' ([int]$n2.rows -eq $r0 -and (HalfOf ([int]$n2.cols) $c0)) "grid $($n2.cols)x$($n2.rows), single was ${c0}x${r0}"
        Check 'the re-orientation emitted a tree event' ((EvSince $cur 'tree') -ge 1)
        $raw = Send-Ctl $s @('session', 'focus', 'top')
        Check 'focus top on a vertical split is refused naming the axis' (-not (ConvertFrom-Json $raw).ok -and [string](ConvertFrom-Json $raw).error -eq "'top' names no pane on a vertical split (left/right panes); use left, right, primary, split or other") "raw: $raw"
        Send-Ctl $s @('session', 'focus', 'right') | Out-Null
        Start-Sleep -Milliseconds 200
        Check 'focus right on a vertical split lands on slot 1' ((SplitBlock $aid) -eq "2|$aid,$sid|1|vertical") "block '$(SplitBlock $aid)'"
        # A session NOT on screen can be split; the displayed session, its focus and the selection stay.
        $raw = Send-Ctl $s @('session', 'new', '--name', 'p4-offscreen')
        $oid = [string](ConvertFrom-Json $raw).result
        Check 'setup: a second session' ((Wait-Node $oid)) "raw: $raw"
        Send-Ctl $s @('session', 'select', '--target', $aid) | Out-Null
        Send-Ctl $s @('session', 'focus', 'right') | Out-Null
        Start-Sleep -Milliseconds 300
        $raw = Send-Ctl $s @('session', 'split', 'on', '--target', 'p4-offscreen')
        $osid = [string](ConvertFrom-Json $raw).result
        Start-Sleep -Milliseconds 500
        Check 'split on a session not on screen, by name, answers its split pane id' ([bool](ConvertFrom-Json $raw).ok -and $osid -and $osid -ne $oid) "raw: $raw"
        Check 'and its node carries the split block: vertical by default, focusedPane 0' ((SplitBlock $oid) -eq "2|$oid,$osid|0|vertical") "block '$(SplitBlock $oid)'"
        Check 'while the displayed session, its focus and the selection did not move (#230)' ([bool](Node $aid).active -and -not [bool](Node $oid).active -and (SplitBlock $aid) -eq "2|$aid,$sid|1|vertical") "a '$(SplitBlock $aid)' active $((Node $aid).active), offscreen active $((Node $oid).active)"
        Send-Ctl $s @('session', 'select', '--target', $oid) | Out-Null
        Start-Sleep -Milliseconds 800
        $n3 = Node $oid
        Check 'selecting it shows its split: half the columns, its own shell focused' ([bool]$n3.active -and (HalfOf ([int]$n3.cols) $c0) -and (SplitBlock $oid) -eq "2|$oid,$osid|0|vertical") "grid $($n3.cols)x$($n3.rows) block '$(SplitBlock $oid)'"
        # off: the survivor's id; a tree event and NO session event (the split shell was never a session).
        $cur = Cursor
        $raw = Send-Ctl $s @('session', 'split', 'off', '--target', $osid)
        Start-Sleep -Milliseconds 600
        Check "split off by the split shell's id answers the survivor's pane id (the session's)" ([string](ConvertFrom-Json $raw).result -eq $oid) "raw: $raw"
        Check 'and the split block is gone, the pane back at the full width' ((SplitBlock $oid) -eq '' -and [int](Node $oid).cols -eq $c0) "block '$(SplitBlock $oid)' cols $((Node $oid).cols)"
        Check 'the unsplit emitted a tree event (it emitted nothing before P4)' ((EvSince $cur 'tree') -ge 1)
        Check 'and no session event: the split shell was never a session' ((EvSince $cur 'session') -eq 0)
        $raw = Send-Ctl $s @('session', 'split', 'off', '--target', $oid)
        Check 'split off when already single still answers the pane id' ([string](ConvertFrom-Json $raw).result -eq $oid) "raw: $raw"
        $raw = Send-Ctl $s @('session', 'focus')
        Check 'focus on a one-pane session is refused' (-not (ConvertFrom-Json $raw).ok -and [string](ConvertFrom-Json $raw).error -eq 'session is not split (one pane); nothing to focus') "raw: $raw"
        # Hand the world back the way the blocks below expect it.
        Send-Ctl $s @('session', 'close', '--target', $oid) | Out-Null
        Start-Sleep -Milliseconds 400
        Send-Ctl $s @('session', 'select', '--target', $aid) | Out-Null
        Send-Ctl $s @('session', 'split', 'off', '--target', $aid) | Out-Null
        Start-Sleep -Milliseconds 400
        # ---- Task 2: `session split close`, the promotion, and every route into the primitive ----
        # THE SESSION-ID RULE: a session id names the session's OWN shell; closing that shell — by
        # `split close` on it, by the close chord on it while focused, or by its process exiting —
        # PROMOTES the survivor: the session keeps its id, name and row, and both the session id and
        # the survivor's own pane id reach the surviving shell. A promotion is not a session close:
        # `tree` fires, `session closed` does not. Each refusal is agwinterm's sentence
        # (SplitCloseReply.cs) and closes nothing.
        function Wait-PaneText([string]$id, [string]$needle, [int]$ms = 12000) {
            $deadline = [DateTime]::Now.AddMilliseconds($ms)
            do { if (([string](Get-PaneText $s $id)) -match [regex]::Escape($needle)) { return $true }; Start-Sleep -Milliseconds 250 } while ([DateTime]::Now -lt $deadline)
            $false
        }
        function Wait-Single([string]$id, [int]$ms = 8000) {   # the node is there and its split block is gone
            $deadline = [DateTime]::Now.AddMilliseconds($ms)
            do { if ((Node $id) -and (SplitBlock $id) -eq '') { return $true }; Start-Sleep -Milliseconds 250 } while ([DateTime]::Now -lt $deadline)
            $false
        }
        function Mark([string]$id, [string]$marker) {   # a comment line typed and entered: visible in the pane, runs nothing
            Send-Ctl $s @('session', 'type', "# $marker", '--target', $id) | Out-Null
            Send-Ctl $s @('session', 'type', "`n", '--target', $id) | Out-Null
            Wait-PaneText $id $marker
        }
        function SplitOn { $r = ConvertFrom-Json (Send-Ctl $s @('session', 'split', 'on', '--target', $aid)); Start-Sleep -Milliseconds 800; [string]$r.result }
        $before = NodeCount
        $raw = Send-Ctl $s @('session', 'split', 'close', '--target', $aid)
        $r = ConvertFrom-Json $raw
        Check 'split close on a one-pane session is refused naming `session close`' (-not $r.ok -and [string]$r.error -eq "split close: session '$aid' has one pane, so there is no split to close; ``session close`` closes the session. Nothing closed.") "raw: $raw"
        Check 'and nothing closed: the session is there, single' ([bool](Node $aid) -and (SplitBlock $aid) -eq '' -and (NodeCount) -eq $before)
        $raw = Send-Ctl $s @('session', 'split', 'close', '--target', 'no-such-session-9999')
        Check 'split close on an unknown target is refused naming it' (-not (ConvertFrom-Json $raw).ok -and [string](ConvertFrom-Json $raw).error -eq "split close: no pane or session matches 'no-such-session-9999'. Nothing closed.") "raw: $raw"
        $cur = Cursor
        Send-Raw '{"cmd":"session.scratch","target":"","args":{"op":"on"}}' | Out-Null
        Start-Sleep -Milliseconds 2500
        $created = @((ConvertFrom-Json (Send-Ctl $s @('events', '--since', "$cur"))).result.events | Where-Object { $_.type -eq 'session' -and $_.info -eq 'created' })
        $covId = [string]($created | Select-Object -Last 1).session
        $raw = Send-Ctl $s @('session', 'split', 'close', '--target', $covId)
        Check 'split close on a scratch cover is refused as no side of a split, naming its dismissing verb' ([bool]$covId -and -not (ConvertFrom-Json $raw).ok -and [string](ConvertFrom-Json $raw).error -eq "split close: '$covId' is a scratch/overlay/quick pane, not a side of a split; ``session scratch off``, ``session overlay close`` or ``quick off`` dismiss those. Nothing closed.") "raw: $raw"
        Check 'and nothing closed: no session event beyond the created one, the node count unchanged' ((EvSince $cur 'session') -eq 1 -and (NodeCount) -eq $before)
        Send-Raw '{"cmd":"session.scratch","target":"","args":{"op":"off"}}' | Out-Null
        Start-Sleep -Milliseconds 500
        # The promotion: close the session's OWN shell by the session id.
        $sid = SplitOn
        Check 'setup: split again, focus on slot 0' ([bool]$sid -and (SplitBlock $aid) -eq "2|$aid,$sid|0|vertical") "block '$(SplitBlock $aid)'"
        Check 'setup: a marker typed into each shell reads back under its own id' ((Mark $aid 'p4-mk-owner-1') -and (Mark $sid 'p4-mk-split-1')) "owner: $(Get-PaneText $s $aid)`nsplit: $(Get-PaneText $s $sid)"
        $cur = Cursor
        $raw = Send-Ctl $s @('session', 'split', 'close', '--target', $aid)
        Start-Sleep -Milliseconds 800
        Check "split close --target <session id> closes the session's OWN shell and answers the survivor's pane id" ([string](ConvertFrom-Json $raw).result -eq $sid) "raw: $raw"
        Check 'the promotion: the node keeps the session id, its split block is gone, the pane is at the full width' ([bool](Node $aid) -and (SplitBlock $aid) -eq '' -and $null -eq (Node $sid) -and [int](Node $aid).cols -eq $c0 -and (NodeCount) -eq $before) "block '$(SplitBlock $aid)' cols $((Node $aid).cols) nodes $(NodeCount)"
        Check 'the survivor answers session text under the session id AND under its own pane id' (((Get-PaneText $s $aid) -match 'p4-mk-split-1') -and ((Get-PaneText $s $sid) -match 'p4-mk-split-1')) "by session id: $(Get-PaneText $s $aid)"
        Check "and the closed shell is gone: its marker is nowhere" (-not ((Get-PaneText $s $aid) -match 'p4-mk-owner-1'))
        Check 'a promotion is not a session close: tree fired, session closed did not' ((EvSince $cur 'tree') -ge 1 -and (EvSince $cur 'session') -eq 0) "tree $(EvSince $cur 'tree') session $(EvSince $cur 'session')"
        Check 'the node is active, its survivor focused, not marked exited' ([bool](Node $aid).active -and -not [bool](Node $aid).exited)
        Check 'session type by the session id reaches the survivor' ((Mark $aid 'p4-typed-after') -and (Wait-PaneText $sid 'p4-typed-after' 2000))
        # A later `split on` mints a fresh pane id beside the survivor's own: paneIds [survivor, new].
        $sid2 = SplitOn
        Check "a later split on mints a fresh pane id: paneIds [the survivor's own, new], focus on slot 0" ([bool]$sid2 -and $sid2 -ne $sid -and $sid2 -ne $aid -and (SplitBlock $aid) -eq "2|$sid,$sid2|0|vertical") "block '$(SplitBlock $aid)'"
        # The symmetric close: the split shell by its own id; the promoted shell survives again.
        $cur = Cursor
        $raw = Send-Ctl $s @('session', 'split', 'close', '--target', $sid2)
        Start-Sleep -Milliseconds 800
        Check "split close --target <split shell id> closes that shell and answers the survivor's pane id" ([string](ConvertFrom-Json $raw).result -eq $sid -and (SplitBlock $aid) -eq '' -and [bool](Node $aid)) "raw: $raw, block '$(SplitBlock $aid)'"
        Check 'the survivor still answers under both ids; tree fired, no session event' (((Get-PaneText $s $sid) -match 'p4-mk-split-1') -and ((Get-PaneText $s $aid) -match 'p4-mk-split-1') -and (EvSince $cur 'tree') -ge 1 -and (EvSince $cur 'session') -eq 0)
        # No target: the focused pane of the displayed session, what the close chord closes.
        $sid3 = SplitOn
        Send-Ctl $s @('session', 'focus', 'split') | Out-Null
        Start-Sleep -Milliseconds 400
        $raw = Send-Ctl $s @('session', 'split', 'close')
        Start-Sleep -Milliseconds 800
        Check 'split close with no target closes the FOCUSED pane (slot 1 here) and answers the survivor' ([string](ConvertFrom-Json $raw).result -eq $sid -and (SplitBlock $aid) -eq '') "raw: $raw, block '$(SplitBlock $aid)'"
        $sid4 = SplitOn
        Send-Ctl $s @('session', 'focus', 'primary') | Out-Null
        Start-Sleep -Milliseconds 400
        $raw = Send-Ctl $s @('session', 'split', 'close')
        Start-Sleep -Milliseconds 800
        Check "split close with no target and slot 0 focused closes the session's own shell: a promotion, the split shell survives" ([string](ConvertFrom-Json $raw).result -eq $sid4 -and (SplitBlock $aid) -eq '' -and [bool](Node $aid) -and (NodeCount) -eq $before) "raw: $raw, block '$(SplitBlock $aid)'"
        # The close chord (Key_Close = Ctrl+Shift+W, seeded before launch) closes the FOCUSED pane only.
        $sid5 = SplitOn
        Send-Ctl $s @('session', 'focus', 'split') | Out-Null
        Start-Sleep -Milliseconds 400
        $cur = Cursor
        [LiteUi]::Chord($s.Hwnd, 0x57, $true)
        Check 'the close chord on the focused split shell closes that pane only: the session stays, single, no session event' ((Wait-Single $aid) -and (NodeCount) -eq $before -and (EvSince $cur 'session') -eq 0 -and (EvSince $cur 'tree') -ge 1) "block '$(SplitBlock $aid)' nodes $(NodeCount)"
        $sid6 = SplitOn
        Send-Ctl $s @('session', 'focus', 'primary') | Out-Null
        Start-Sleep -Milliseconds 400
        $cur = Cursor
        [LiteUi]::Chord($s.Hwnd, 0x57, $true)
        Check "the close chord on the focused OWN shell of a split closes that pane only: the session keeps its id, the split shell survives" ((Wait-Single $aid) -and (NodeCount) -eq $before -and (EvSince $cur 'session') -eq 0 -and [bool](ConvertFrom-Json (Send-Ctl $s @('session', 'text', '--target', $sid6))).ok) "block '$(SplitBlock $aid)' nodes $(NodeCount)"
        Check 'and the next split lists the survivor first' ((SplitOn) -and (SplitBlock $aid) -match "^2\|$sid6,")
        Send-Ctl $s @('session', 'split', 'off', '--target', $aid) | Out-Null
        Start-Sleep -Milliseconds 500
        # A split side whose shell EXITS collapses to the survivor within the settle (agwinterm collapses too).
        $sid7 = SplitOn
        Check 'setup: the split shell is up' (Mark $sid7 'p4-mk-split-7')
        $cur = Cursor
        Send-Ctl $s @('session', 'type', 'exit', '--target', $sid7) | Out-Null
        Send-Ctl $s @('session', 'type', "`n", '--target', $sid7) | Out-Null
        Check 'a split shell whose process exits collapses to the survivor: the session, single; tree fired, no session event' ((Wait-Single $aid) -and (NodeCount) -eq $before -and (EvSince $cur 'tree') -ge 1 -and (EvSince $cur 'session') -eq 0) "block '$(SplitBlock $aid)' nodes $(NodeCount)"
        $sid8 = SplitOn
        Check 'setup: a marker in the split shell' (Mark $sid8 'p4-mk-split-8')
        $cur = Cursor
        Send-Ctl $s @('session', 'type', 'exit', '--target', $aid) | Out-Null
        Send-Ctl $s @('session', 'type', "`n", '--target', $aid) | Out-Null
        Check "the session's OWN shell exiting promotes the survivor: the node keeps its id, session text by it reaches the survivor, not exited" ((Wait-Single $aid) -and ((Get-PaneText $s $aid) -match 'p4-mk-split-8') -and -not [bool](Node $aid).exited -and (EvSince $cur 'session') -eq 0) "text: $(Get-PaneText $s $aid)"
        # `session close` on the split shell's id: that shell, an unsplit (its pre-P4 meaning), now with `tree`.
        $sid9 = SplitOn
        $cur = Cursor
        $raw = Send-Ctl $s @('session', 'close', '--target', $sid9)
        Start-Sleep -Milliseconds 800
        Check "session close --target <split shell id> closes that shell: the session stays, single" ([bool](ConvertFrom-Json $raw).ok -and (SplitBlock $aid) -eq '' -and [bool](Node $aid) -and (NodeCount) -eq $before) "raw: $raw, block '$(SplitBlock $aid)'"
        Check 'and it emitted tree, not session closed: the split shell was never a session' ((EvSince $cur 'tree') -ge 1 -and (EvSince $cur 'session') -eq 0)
        # A session NOT on screen: its own shell closed by split close promotes it there; nothing moves (#230).
        $o2 = [string](ConvertFrom-Json (Send-Ctl $s @('session', 'new', '--name', 'p4-offscreen2'))).result
        Check 'setup: a second session' (Wait-Node $o2)
        Send-Ctl $s @('session', 'select', '--target', $aid) | Out-Null
        Start-Sleep -Milliseconds 300
        $os2 = [string](ConvertFrom-Json (Send-Ctl $s @('session', 'split', 'on', '--target', $o2))).result
        Start-Sleep -Milliseconds 500
        $raw = Send-Ctl $s @('session', 'split', 'close', '--target', 'p4-offscreen2')
        Start-Sleep -Milliseconds 800
        Check 'split close by NAME on a session not on screen promotes it there: its node keeps its id, single, the survivor answered' ([string](ConvertFrom-Json $raw).result -eq $os2 -and (SplitBlock $o2) -eq '' -and [bool](Node $o2)) "raw: $raw, block '$(SplitBlock $o2)'"
        Check 'while the displayed session and the selection did not move (#230)' ([bool](Node $aid).active -and -not [bool](Node $o2).active)
        Send-Ctl $s @('session', 'select', '--target', $o2) | Out-Null
        Start-Sleep -Milliseconds 800
        Check 'selecting it shows the survivor at the full width, its name kept' ([bool](Node $o2).active -and [int](Node $o2).cols -eq $c0 -and [string](Node $o2).name -eq 'p4-offscreen2') "grid $((Node $o2).cols) name '$((Node $o2).name)'"
        $cur = Cursor
        Send-Ctl $s @('session', 'close', '--target', $o2) | Out-Null
        Start-Sleep -Milliseconds 500
        Check 'session close on the promoted session closes it (the survivor shell, by its own host id): session closed fired' ($null -eq (Node $o2) -and (EvSince $cur 'session') -ge 1 -and (NodeCount) -eq $before)
        Send-Ctl $s @('session', 'select', '--target', $aid) | Out-Null
        Start-Sleep -Milliseconds 400
    }

    # ---- #23: two persisted values that cannot coexist ------------------------------------------
    # SidebarW (one value for every instance) and WinW-<instance> are each valid on their own; a
    # sidebar saved at 900 from a wide monitor and a window rect saved at 700 on the laptop meet at
    # the first WM_SIZE, and the layout used to honour the sidebar and hand the terminal a negative
    # width - the first session was CREATED at 2x2. This needs a fresh instance, so the main
    # sandbox is stopped first (its shutdown save lands before the seed) and a second one starts
    # on its own pipe, whose geometry values are unique to it and removed in `finally`.
    "-- #23: SidebarW 900 in a 600 px window --"
    Stop-Sandbox $s; $s = $null
    $pipe23 = 'ctlhonesty23'
    if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
    foreach ($kv in @(@('SidebarW', 900), @('ShowSidebar', 1), @("WinX-$pipe23", 150), @("WinY-$pipe23", 100), @("WinW-$pipe23", 600), @("WinH-$pipe23", 600), @("WinMax-$pipe23", 0))) {
        New-ItemProperty -Path $regKey -Name $kv[0] -Value ([int]$kv[1]) -PropertyType DWord -Force | Out-Null
    }
    $s = Start-Sandbox -Exe $exe -Ctl $ctl -Pipe $pipe23 -Width 600 -Height 600
    $aid = [string](Nodes | Where-Object { $_.active } | Select-Object -First 1).id
    Check 'setup: the 600 px sandbox has a session' ([bool]$aid)
    $client = ClientSize $s.Hwnd
    Check 'setup: its client is under 600 px wide' ($client[0] -gt 0 -and $client[0] -lt 600) "client $($client -join 'x')"
    $w = (ConvertFrom-Json (Sidebar @('width'))).result
    Check 'the sidebar started clamped: `sidebar width` reads under 900 and the tree is that wide' ([int]$w.width -lt 900 -and [int]$w.width -ge 90 -and (Wait-TreeWidth ([int]$w.width)) -eq [int]$w.width) "width $($w | ConvertTo-Json -Compress), tree $(TreeWidth)"
    Check 'and the first session was created beside it with at least 20 columns, not 2x2' ([int]$w.width + 5 -lt $client[0] -and (ColsOf $aid) -ge 20) "cols $(ColsOf $aid) in a $($client[0]) px client"
    $log23 = Join-Path $s.AppDir "agliteterm\agliteterm-$pipe23.log"
    $logLine = if (Test-Path $log23) { Get-Content $log23 | Where-Object { $_ -match 'sidebar width 900 leaves under 20 columns' } | Select-Object -First 1 }
    Check 'and the log says which value gave way, and that it was not saved' ([bool]$logLine -and $logLine -match 'not saved') "log: $log23`n$logLine"
    Check 'HKCU SidebarW is still 900: a narrow window does not overwrite the preference' ((Get-ItemProperty -Path $regKey -Name SidebarW).SidebarW -eq 900)
}
finally {
    if ($s) { Stop-Sandbox $s }
    # The capture block's pings (a check that threw leaves them running for minutes under a shell
    # that is about to be killed); found by the marker argument, never by name alone.
    Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { $_.CommandLine -match '-n (30[35]|4) 127\.0\.0\.1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # The second sandbox's geometry values are its own; they were seeded here, so they go.
    foreach ($n in 'WinX', 'WinY', 'WinW', 'WinH', 'WinMax') {
        if (Test-Path $regKey) { Remove-ItemProperty -Path $regKey -Name "$n-ctlhonesty23" -ErrorAction SilentlyContinue }
    }
    # After the sandbox exits: its own shutdown save (if any) must not land after the restore.
    Restore-Reg
}

if ($fail) { "control-honesty: $fail failed"; exit 1 }
if ($skipped -and $Strict) { "control-honesty: $skipped skipped under -Strict"; exit 1 }
"control-honesty: all passed$(if ($skipped) { " ($skipped skipped)" })"
exit 0
