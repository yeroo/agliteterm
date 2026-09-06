# qa/panes.md - "A split survives a restart", the P4 half: the LAYOUT comes back too. Drives a
# sandbox: one session renamed, split HORIZONTAL, a marker command running in each pane, one
# `restore capture`, then `session swap`; reads the STATE FILE (the L line beside the P, the K line by
# role), ends the window - killed by default, because the L line has to have been checkpointed by the
# save the swap itself triggered, there being no close - relaunches the same instance WITHOUT
# --no-restore, and reads the tree and the file again. The assertion is on the world after the
# restart: the axis is horizontal, the session's own shell sits in slot 1, the captured slot of each
# shell is on THAT shell (field 2 of K is the session's own shell, whatever its slot), and a
# PrintWindow capture of the restored window is written for the PR body.
#
# Usage: pwsh qa\fixtures\layout-restart.ps1 [-Exe <agliteterm.exe>] [-Graceful] [-Out <dir>]
#   -Graceful  ends the first window with a close instead of Stop-Process.
#   -Out       where restored.png lands (default %TEMP%\agliteterm-layout-restart).
# Run ALONE (test/ui-lib.ps1's rule: sandboxes share the desktop and the pty-host).
param([string]$Exe, [switch]$Graceful, [string]$Out = (Join-Path $env:TEMP 'agliteterm-layout-restart'))

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'test\ui-lib.ps1')
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class LayoutCap {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFO bi, uint usage, out IntPtr bits, IntPtr sec, uint off);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFO {
        public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount; public uint biCompression, biSizeImage;
        public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant; public uint colors;
    }
    // The same capture as qa/fixtures/context-row.ps1: PrintWindow(PW_RENDERFULLCONTENT) into a
    // top-down DIB, one copy into the Bitmap.
    public static Bitmap Capture(IntPtr h) {
        RECT r; GetWindowRect(h, out r);
        int w = r.R - r.L, hgt = r.B - r.T;
        var bi = new BITMAPINFO(); bi.biSize = 40; bi.biWidth = w; bi.biHeight = -hgt; bi.biPlanes = 1; bi.biBitCount = 32;
        IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), bits;
        IntPtr dib = CreateDIBSection(screen, ref bi, 0, out bits, IntPtr.Zero, 0);
        IntPtr old = SelectObject(mem, dib);
        PrintWindow(h, mem, 2);
        var bmp = new Bitmap(w, hgt, PixelFormat.Format32bppArgb);
        var d = bmp.LockBits(new Rectangle(0, 0, w, hgt), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        var row = new int[w];
        for (int y = 0; y < hgt; y++) { Marshal.Copy(bits + y * w * 4, row, 0, w); Marshal.Copy(row, 0, d.Scan0 + y * d.Stride, w); }
        bmp.UnlockBits(d);
        SelectObject(mem, old); DeleteObject(dib); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen);
        return bmp;
    }
}
'@ -ReferencedAssemblies @([System.Drawing.Bitmap].Assembly.Location, [System.Drawing.Color].Assembly.Location, 'System.Runtime.InteropServices')

$exe = Resolve-Lite $Exe
$ctl = Get-CtlPath
if (-not $ctl) { throw 'agwintermctl not found (set AGWINTERMCTL)' }
# The P4 client probe (test/control-honesty.ps1): a post-#238 client refuses `session swap <word>`
# on its own side before any pipe; an older one has no `swap` and drops `--axis` on the floor.
$probe = (& $ctl session swap x --pipe 'qa-p4r-probe' --json 2>&1) -join ''
if ($probe -notmatch 'Nothing sent') { "SKIP  the client at $ctl predates P4 (no `session swap`); set AGWINTERMCTL to a post-#238 build"; exit 0 }

$pipe = 'qa-p4r'
# Two markers, one per shell: the slot holds the command line as the PROCESS reports it, so the
# checks match the arguments, never the typed text.
$ownRx = '-n 317 127\.0\.0\.1'
$splitRx = '-n 318 127\.0\.0\.1'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "  PASS  $name" } else { $script:fail++; "  FAIL  $name$(if ($detail) { " - $detail" })" }
}
function Tree($S) { (ConvertFrom-Json (Send-Ctl $S @('tree', '--json'))).result }
function Node($S, [string]$name) { foreach ($w in (Tree $S).workspaces) { foreach ($n in $w.sessions) { if ($n.name -eq $name) { return $n } } } }
function StateLines([string]$dir) { Get-Content (Join-Path $dir "agliteterm\sessions-$pipe.tsv") }
function Wait-Alive($S) { for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 500; if ((Send-Ctl $S @('ping')) -match '"ok":true') { return $true } }; return $false }
function Marker-Procs { Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -match '-n 31[78] 127' } }
function Stop-Markers { Marker-Procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
function Wait-Markers { for ($i = 0; $i -lt 40; $i++) { if (@(Marker-Procs).Count -ge 2) { return $true }; Start-Sleep -Milliseconds 200 }; return $false }

Stop-Markers
$s = Start-Sandbox -Exe $exe -Ctl $ctl -Pipe $pipe
$p2 = $null
try {
    "== setup =="
    $keeper = [string](Get-CtlResult $s @('session', 'new', '--name', 'layout-keeper'))
    Check 'setup: layout-keeper exists' ([bool]$keeper)
    $split = [string](Get-CtlResult $s @('session', 'split', 'on', '--axis', 'horizontal', '--target', $keeper))
    Start-Sleep 4
    Check 'session split on --axis horizontal answers the split shell''s id' ($split -and $split -ne $keeper) $split
    $n0 = Node $s 'layout-keeper'
    Check 'the tree''s split block: horizontal, the session''s own shell in slot 0' `
        ($n0.axis -eq 'horizontal' -and [string]$n0.paneIds[0] -eq $keeper -and [string]$n0.paneIds[1] -eq $split) ($n0 | ConvertTo-Json -Compress)

    Send-Ctl $s @('session', 'type', "ping -n 317 127.0.0.1`r", '--target', $keeper) | Out-Null
    Send-Ctl $s @('session', 'type', "ping -n 318 127.0.0.1`r", '--target', $split) | Out-Null
    Check 'setup: a marker runs under each shell' (Wait-Markers)
    Start-Sleep 1
    # Untargeted: `--target <id>` captures that ONE pane (the P3 rule), and both slots are wanted.
    $cap = Send-Ctl $s @('restore', 'capture')
    $capR = (ConvertFrom-Json $cap).result
    Check 'restore capture reports each marker under its own pane id' `
        (($capR.panes | Where-Object { $_.pane -eq $keeper }).captured -match $ownRx -and
         ($capR.panes | Where-Object { $_.pane -eq $split }).captured -match $splitRx) $cap

    $sw = Send-Ctl $s @('session', 'swap', '--target', $keeper)
    $swR = (ConvertFrom-Json $sw).result
    Check 'session swap answers the split block reversed, the axis kept' `
        ($swR.session -eq $keeper -and [string]$swR.paneIds[0] -eq $split -and [string]$swR.paneIds[1] -eq $keeper -and $swR.axis -eq 'horizontal') $sw
    Start-Sleep 3
    Check 'after the swap each id still reaches its own shell' `
        ((Get-PaneText $s $keeper) -match 'ping -n 317' -and (Get-PaneText $s $split) -match 'ping -n 318')

    "== the file, before the restart =="
    $lines = StateLines $s.AppDir
    $lines | ForEach-Object { "  $_" }
    $idx = -1; $i = 0
    foreach ($l in $lines) { if ($l -like "S`t*") { if (($l -split "`t")[2] -eq 'layout-keeper') { $idx = $i }; $i++ } }
    Check 'a P line names layout-keeper''s split' (@($lines | Where-Object { $_ -like "P`t$idx`t*" }).Count -eq 1)
    Check 'an L line beside it: horizontal, order 1' ($lines -contains "L`t$idx`thorizontal`t1")
    Check 'the K line is by ROLE: field 2 the session''s own marker, field 3 the split''s, whatever the slots' `
        (@($lines | Where-Object { $_ -match "^K`t$idx`t[^`t]*$ownRx`t[^`t]*$splitRx$" }).Count -eq 1)

    "== restart ($(if ($Graceful) { 'graceful' } else { 'killed' })) =="
    if ($Graceful) { $s.Proc.CloseMainWindow() | Out-Null } else { Stop-Process -Id $s.Proc.Id -Force }
    for ($i = 0; $i -lt 40 -and -not $s.Proc.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    Check 'the first window is gone' $s.Proc.HasExited
    if ($Graceful) { Stop-Markers }

    $scrub = 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE', 'AGWINTERM_VERSION_OVERRIDE'
    $saved = @{}
    foreach ($v in $scrub) { $saved[$v] = [Environment]::GetEnvironmentVariable($v); Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    try { $p2 = Start-Process $exe -ArgumentList @('--pipe', $pipe) -PassThru -Environment @{ LOCALAPPDATA = $s.AppDir } }
    finally { foreach ($v in $scrub) { if ($null -ne $saved[$v]) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) } } }
    $s2 = [pscustomobject]@{ Proc = $p2; Ctl = $ctl; Pipe = $pipe; AppDir = $null; Hwnd = [IntPtr]::Zero }
    Check 'the relaunch answers' (Wait-Alive $s2)
    Start-Sleep 6

    "== the tree, after the restart =="
    $n2 = Node $s2 'layout-keeper'
    "  layout-keeper: $($n2 | ConvertTo-Json -Compress)"
    Check 'layout-keeper is back split' ($n2 -and $n2.paneCount -eq 2)
    Check 'the axis is horizontal' ($n2.axis -eq 'horizontal')
    Check 'the order survived: the session''s own shell sits in slot 1' ([string]$n2.paneIds[1] -eq [string]$n2.id -and [string]$n2.paneIds[0] -ne [string]$n2.id)
    $caps = $n2.capturedCommands
    Check 'the K slots landed on the right shells: the session''s own marker on its id, the split''s on the split' `
        ($caps -and $caps.([string]$n2.id) -match $ownRx -and $caps.([string]$n2.paneIds[0]) -match $splitRx) ($caps | ConvertTo-Json -Compress)
    Send-Ctl $s2 @('session', 'select', '--target', $n2.id) | Out-Null
    Start-Sleep 2
    $a = (Send-Ctl $s2 @('session', 'text', '--target', [string]$n2.paneIds[0]))
    Check 'both restored shells are live (session text answers under each pane id)' `
        ($a -match '"ok":true' -and (Send-Ctl $s2 @('session', 'text', '--target', [string]$n2.id)) -match '"ok":true')

    "== the file, after the restart's own save =="
    $lines2 = StateLines $s.AppDir
    $lines2 | ForEach-Object { "  $_" }
    Check 'the L line is re-written: horizontal, order 1' (@($lines2 | Where-Object { $_ -match "^L`t\d+`thorizontal`t1$" }).Count -eq 1)
    Check 'the K line is re-written by role' (@($lines2 | Where-Object { $_ -match "^K`t\d+`t[^`t]*$ownRx`t[^`t]*$splitRx$" }).Count -eq 1)
    $log = Get-Content (Join-Path $s.AppDir "agliteterm\agliteterm-$pipe.log") -Raw
    "  log lines: " + (($log -split "`n" | Where-Object { $_ -match 'layout|split' }) -join "`n  log lines: ")

    "== the capture =="
    $p2.Refresh()
    $h = $p2.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        New-Item -ItemType Directory -Force $Out | Out-Null
        $bmp = [LayoutCap]::Capture($h)
        $png = Join-Path $Out 'restored.png'
        $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        Check "the restored window captured to $png" (Test-Path $png)
    } else { Check 'the restored window has a handle to capture' $false }
}
finally {
    if ($p2 -and -not $p2.HasExited) { $p2.CloseMainWindow() | Out-Null; Start-Sleep 3 }
    if ($p2 -and -not $p2.HasExited) { Stop-Process -Id $p2.Id -Force }
    if (-not $s.Proc.HasExited) { Stop-Process -Id $s.Proc.Id -Force }
    Stop-Markers
    Remove-Item $s.AppDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { "layout-restart: $fail FAILED"; exit 1 }
"layout-restart: all passed"
exit 0
