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
    # `cmd /k` keeps a prompt up, so the popup stays open for as long as the checks need it.
    $raw = Overlay @('open', 'cmd', '/k', '--size-percent', '40')
    $r = ConvertFrom-Json $raw
    Check 'open --size-percent 40 answers ok with a status string' ([bool]$r.ok -and $r.result -is [string]) "raw: $raw"
    $h40 = Wait-Overlay $true
    Check 'and a popup titled "agliteterm - overlay" appeared' ($h40 -ne [IntPtr]::Zero)
    Start-Sleep -Milliseconds 500
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
    # A raw request with no op at all: the CLI always sends one, but the pipe is public. Toggle,
    # which is what the CLI sends for a bare `sidebar` — pinned so the "" case is a written fact.
    $raw = Send-Raw '{"cmd":"sidebar","target":"","args":{}}'
    Check 'a raw sidebar request with no op toggles (what the CLI sends for a bare `sidebar`)' ([bool](ConvertFrom-Json $raw).ok -and (Wait-TreeVisible $false) -eq $false) "raw: $raw"
    Sidebar @('show') | Out-Null
    Wait-TreeVisible $true | Out-Null

    # No refusal above may have created a session: hidden sessions never show in `tree`, and the
    # visible count is what it was at the start.
    Check 'the tree still has exactly the sandbox first session' (@(Nodes).Count -eq 1) "nodes: $(@(Nodes).Count)"
}
finally {
    if ($s) { Stop-Sandbox $s }
    # After the sandbox exits: its own shutdown save (if any) must not land after the restore.
    Restore-Reg
}

if ($fail) { "control-honesty: $fail failed"; exit 1 }
if ($skipped -and $Strict) { "control-honesty: $skipped skipped under -Strict"; exit 1 }
"control-honesty: all passed$(if ($skipped) { " ($skipped skipped)" })"
exit 0
