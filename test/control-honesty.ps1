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

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LiteHonesty {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
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
$regSaved = @{}
foreach ($n in 'SidebarW', 'ShowSidebar') {
    $regSaved[$n] = if (Test-Path $regKey) { (Get-ItemProperty -Path $regKey -Name $n -ErrorAction SilentlyContinue).$n } else { $null }
}
function Restore-Reg {
    foreach ($n in 'SidebarW', 'ShowSidebar') {
        if ($null -ne $regSaved[$n]) { New-ItemProperty -Path $regKey -Name $n -Value ([int]$regSaved[$n]) -PropertyType DWord -Force | Out-Null }
        elseif (Test-Path $regKey) { Remove-ItemProperty -Path $regKey -Name $n -ErrorAction SilentlyContinue }
    }
}

try {
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
    [void][LiteUi]::PostMessageW($s.Hwnd, 0x0201, [IntPtr]1, (Pt ((TreeWidth) + 2) $midY))   # WM_LBUTTONDOWN on the splitter
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
    $line2 = 'tail  --end "q"'                     # after the newline: another run of spaces, no Enter
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
        Check 'and was NOT submitted (one trailing newline stripped, none invented)' (-not (OracleRows | Where-Object { $_ -match "'tail' is not recognized" }))
        # A second newline at the end IS the Enter: the draft runs, and cmd says so.
        $raw = Invoke-CtlStdin "`n" @('session', 'type', '--stdin', '--target', $oid)
        Check 'a text of two newlines (one stripped, one kept) presses Enter' ([bool](ConvertFrom-Json $raw).ok -and (Wait-Row { $_ -match "'tail' is not recognized" })) "raw: $raw, rows: $((OracleRows | Where-Object { $_ }) -join ' | ')"

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
