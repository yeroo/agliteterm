# qa/panes.md - "A pane overlay covers one pane and the other stays interactive" (P5), and the
# control-honesty case "overlay text reads the overlay; session text --target <pane> reads the shell
# under it". Drives a sandbox: one session renamed, split VERTICAL, a pane overlay opened on the
# RIGHT with a marker command that then sleeps, a marker typed into the LEFT pane while the overlay
# is up; reads the tree (`paneOverlays`), the overlay by its id and through `overlay text`, the shell
# UNDER the overlay by its own id, and the left shell; writes a PrintWindow capture of the window for
# the PR body; closes the slot and reads the world again.
#
# Usage: pwsh qa\fixtures\pane-overlay.ps1 [-Exe <agliteterm.exe>] [-Out <dir>]
#   -Out       where covered.png lands (default %TEMP%\agliteterm-pane-overlay).
# Run ALONE (test/ui-lib.ps1's rule: sandboxes share the desktop and the pty-host).
param([string]$Exe, [string]$Out = (Join-Path $env:TEMP 'agliteterm-pane-overlay'))

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'test\ui-lib.ps1')
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class OverlayCap {
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
    // The same capture as qa/fixtures/layout-restart.ps1: PrintWindow(PW_RENDERFULLCONTENT) into a
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
# The P5 client probe (test/conformance.ps1): a post-#250 client refuses `resize --pane` on its own
# side before any pipe; an older one drops `--pane` and fails to connect.
$probe = (& $ctl session overlay resize --pane left --pipe 'qa-p5o-probe' --json 2>&1) -join ''
if ($probe -notmatch 'Nothing sent') { "SKIP  the client at $ctl predates P5 (no `session overlay --pane`); set AGWINTERMCTL to a post-#250 build"; exit 0 }

$pipe = 'qa-p5o'
$ovMarker = 'P5-OVERLAY-MARKER'
$leftMarker = 'P5-LEFT-MARKER'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "  PASS  $name" } else { $script:fail++; "  FAIL  $name$(if ($detail) { " - $detail" })" }
}
function Tree($S) { (ConvertFrom-Json (Send-Ctl $S @('tree', '--json'))).result }
function Node($S, [string]$name) { foreach ($w in (Tree $S).workspaces) { foreach ($n in $w.sessions) { if ($n.name -eq $name) { return $n } } } }
function Words($n) { if ($null -eq $n.paneOverlays) { '' } else { (@($n.paneOverlays) -join ',') } }
function Flat($S, [string]$t) { [string](Get-PaneText $S $t) -replace '\s+', ' ' }
function Wait-Text($S, [string]$t, [string]$rx, [int]$ms = 10000) {
    for ($i = 0; $i -lt ($ms / 250); $i++) { if ((Flat $S $t) -match $rx) { return $true }; Start-Sleep -Milliseconds 250 }
    return $false
}
# The overlay's own shell: powershell.exe running the FTCS-wrapped command line, found by the marker.
function Overlay-Shells { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match "echo $ovMarker;" }) }
function Stop-OverlayShells { Overlay-Shells | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
function Save-Capture($S, [string]$name) {
    New-Item -ItemType Directory -Force $Out | Out-Null
    $S.Proc.Refresh()
    $h = $S.Proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { $h = $S.Hwnd }
    if ($h -eq [IntPtr]::Zero) { return '' }
    $bmp = [OverlayCap]::Capture($h)
    $png = Join-Path $Out $name
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return $png
}

Stop-OverlayShells
$s = Start-Sandbox -Exe $exe -Ctl $ctl -Pipe $pipe
try {
    "== setup =="
    $sid = [string](Get-CtlResult $s @('session', 'new', '--name', 'covered'))
    Check 'setup: covered exists' ([bool]$sid)
    Send-Ctl $s @('session', 'select', '--target', $sid) | Out-Null
    $sp = [string](Get-CtlResult $s @('session', 'split', 'on', '--target', $sid))
    Start-Sleep 4
    Check 'session split on answers the split shell''s id' ($sp -and $sp -ne $sid) $sp
    $n0 = Node $s 'covered'
    Check 'the tree''s split block: vertical, two panes, no paneOverlays' `
        ($n0.paneCount -eq 2 -and $n0.axis -eq 'vertical' -and (Words $n0) -eq '') ($n0 | ConvertTo-Json -Compress)
    $before = Save-Capture $s 'before.png'

    "== open --pane right =="
    $raw = Send-Ctl $s @('session', 'overlay', 'open', "echo $ovMarker;", 'Start-Sleep', '300', '--pane', 'right', '--target', $sid)
    $r = try { ConvertFrom-Json $raw } catch { $null }
    $ov = if ($r -and $r.ok) { [string]$r.result } else { '' }
    Check 'open --pane right answers ok with the overlay''s id: a session id of this instance, none of the known three' `
        ([bool]$ov -and $ov -like "$pipe-*" -and $ov -ne $sid -and $ov -ne $sp) "raw: $raw"
    Check 'the overlay id reads the overlay: its marker' (Wait-Text $s $ov $ovMarker) "text: $(Flat $s $ov)"
    $n1 = Node $s 'covered'
    Check 'tree: paneOverlays is ["right"], the split block unchanged' `
        ((Words $n1) -eq 'right' -and $n1.paneCount -eq 2 -and $n1.axis -eq 'vertical' -and [string]$n1.paneIds[1] -eq $sp) ($n1 | ConvertTo-Json -Compress)
    Check 'the shell UNDER the overlay is still there: the split shell''s id reads its prompt, not the overlay''s marker' `
        (-not ((Flat $s $sp) -match $ovMarker) -and (Flat $s $sp).Length -gt 0) "text: $(Flat $s $sp)"
    $ovText = [string](ConvertFrom-Json (Send-Ctl $s @('session', 'overlay', 'text', '--pane', 'right', '--target', $sid))).result.text
    Check 'overlay text --pane right is the overlay id''s session text, byte for byte' `
        ($ovText -eq [string](Get-PaneText $s $ov) -and $ovText -match $ovMarker) "overlay text: $($ovText -replace '\s+', ' ')"

    "== the left pane, typed into while the right is covered =="
    Send-Ctl $s @('session', 'type', "echo $leftMarker`r", '--target', $sid) | Out-Null
    Check 'the left pane is interactive: the marker typed by the session id reads back there' (Wait-Text $s $sid "$leftMarker\s*$leftMarker") "text: $(Flat $s $sid)"
    Check 'and neither the overlay nor the covered shell got it' (-not ((Flat $s $ov) -match $leftMarker) -and -not ((Flat $s $sp) -match $leftMarker))
    Check 'the process behind the slot is the overlay''s own shell, the wrapped command line on it' (@(Overlay-Shells).Count -eq 1) "count: $(@(Overlay-Shells).Count)"

    "== the capture =="
    Start-Sleep 1
    $png = Save-Capture $s 'covered.png'
    Check "the covered window captured to $png" ([bool]$png -and (Test-Path $png))

    "== close --pane right =="
    $raw = Send-Ctl $s @('session', 'overlay', 'close', '--pane', 'right', '--target', $sid)
    $r = ConvertFrom-Json $raw
    Check 'close --pane right answers closed' ([bool]$r.ok -and [string]$r.result -eq 'closed') "raw: $raw"
    Start-Sleep 1
    $n2 = Node $s 'covered'
    Check 'tree: paneOverlays is gone, the split intact' ((Words $n2) -eq '' -and $n2.paneCount -eq 2) ($n2 | ConvertTo-Json -Compress)
    $gone = $false
    for ($i = 0; $i -lt 24; $i++) { if (-not ((Send-Ctl $s @('session', 'text', '--target', $ov)) -match '"ok":true')) { $gone = $true; break }; Start-Sleep -Milliseconds 250 }
    Check 'the overlay''s id resolves nowhere afterwards' $gone
    $shellGone = $false
    for ($i = 0; $i -lt 40; $i++) { if (@(Overlay-Shells).Count -eq 0) { $shellGone = $true; break }; Start-Sleep -Milliseconds 250 }
    Check 'the process behind it is gone: no orphan' $shellGone
    Send-Ctl $s @('session', 'focus', 'right') | Out-Null
    Start-Sleep -Milliseconds 500
    Check 'the right pane shows its shell again: session text with slot 1 focused is the shell, not the overlay' `
        (-not ((Flat $s '') -match $ovMarker) -and (Flat $s '') -eq (Flat $s $sp)) "active: $(Flat $s '')"
    $after = Save-Capture $s 'after.png'
    Check "the uncovered window captured to $after" ([bool]$after -and (Test-Path $after))
    $raw = Send-Ctl $s @('session', 'overlay', 'text', '--pane', 'right', '--target', $sid)
    $r = ConvertFrom-Json $raw
    Check 'overlay text on the empty slot is refused naming the slot' (-not $r.ok -and [string]$r.error -eq 'no overlay: --pane right names which slot, and nothing is open in it') "raw: $raw"
}
finally {
    Stop-Sandbox $s
    Stop-OverlayShells
}
if ($fail) { "pane-overlay: $fail FAILED"; exit 1 }
"pane-overlay: all passed"
exit 0
