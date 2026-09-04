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

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LiteHonesty {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
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

    # No refusal above may have created a session: hidden sessions never show in `tree`, and the
    # visible count is what it was at the start.
    Check 'the tree still has exactly the sandbox first session' (@(Nodes).Count -eq 1) "nodes: $(@(Nodes).Count)"
}
finally {
    if ($s) { Stop-Sandbox $s }
}

if ($fail) { "control-honesty: $fail failed"; exit 1 }
if ($skipped -and $Strict) { "control-honesty: $skipped skipped under -Strict"; exit 1 }
"control-honesty: all passed$(if ($skipped) { " ($skipped skipped)" })"
exit 0
