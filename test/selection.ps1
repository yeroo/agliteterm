# A selection must cover the text the user highlighted — or be gone.
#
# Buffer-absolute rows renumber when scrollback eviction drops the oldest lines. A selection that
# ignores that keeps naming the same NUMBERS while the text under them moves, so the highlight, the
# `session copy` verb and Ctrl+C all quietly return something the user never selected. That is worse
# than losing the selection, because nothing looks wrong.
#
#   1. output that scrolls        -> the same text is still selected
#   2. eviction past the cap      -> the selection is dropped, not shifted onto a stranger's text
#   3. entering the alt screen    -> dropped (a different buffer entirely)
#   4. Ctrl+C after output        -> copies the selection rather than interrupting the shell
#
# Suite rules: sandbox instance, throwaway %LOCALAPPDATA%, PostMessage only. Ctrl+C attaches to the
# instance's input queue because a posted WM_KEYDOWN cannot make GetKeyState see the modifier —
# still nothing injected globally.
param(
    [string]$Exe = "$PSScriptRoot\..\bin\agliteterm.exe",
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "  PASS  $name" }
    else { $script:fail++; "  FAIL  $name$(if ($detail) { " — $detail" })" }
}

"== selection =="

. "$PSScriptRoot\ctl-path.ps1"
$ctl = Get-CtlPath
if (-not $ctl) { "  SKIP  agwintermctl not found (set AGWINTERMCTL)"; exit ($Strict ? 1 : 0) }
if (-not (Test-Path $Exe)) { "  SKIP  no build at $Exe"; exit ($Strict ? 1 : 0) }

$pipe = 'selchk'
foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') {
    Remove-Item "env:$v" -ErrorAction SilentlyContinue
}
function Ctl { param([string[]]$a) (& $ctl @a --pipe $pipe --json 2>&1) -join '' }
function Sel { (Ctl @('session', 'copy') | ConvertFrom-Json).result }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SelIn {
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] s);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] s);
    static IntPtr Pt(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
    public static void Drag(IntPtr h, int x1, int y1, int x2, int y2) {
        PostMessageW(h, 0x0201, (IntPtr)1, Pt(x1, y1));
        for (int i = 1; i <= 8; i++) {
            PostMessageW(h, 0x0200, (IntPtr)1, Pt(x1 + (x2 - x1) * i / 8, y1 + (y2 - y1) * i / 8));
            System.Threading.Thread.Sleep(40);
        }
        PostMessageW(h, 0x0202, IntPtr.Zero, Pt(x2, y2));
        System.Threading.Thread.Sleep(250);
    }
    public static void CtrlKey(IntPtr h, int vk) {
        uint me = GetCurrentThreadId(), it = GetWindowThreadProcessId(h, IntPtr.Zero);
        AttachThreadInput(me, it, true);
        var st = new byte[256];
        GetKeyboardState(st);
        st[0x11] = 0x80; st[0xA2] = 0x80;
        SetKeyboardState(st);
        PostMessageW(h, 0x0100, (IntPtr)vk, (IntPtr)1);
        System.Threading.Thread.Sleep(400);
        st[0x11] = 0; st[0xA2] = 0;
        SetKeyboardState(st);
        PostMessageW(h, 0x0101, (IntPtr)vk, (IntPtr)1);
        AttachThreadInput(me, it, false);
    }
}
'@

$clipOk = $false
try {
    Set-Clipboard -Value 'agliteterm-selection-probe'
    $clipOk = ((Get-Clipboard -Raw) -eq 'agliteterm-selection-probe')
} catch { $clipOk = $false }
if (-not $clipOk) { "  NOTE  this machine has no usable clipboard - the Ctrl+C assertion will skip" }

$root = Join-Path $env:TEMP ("selchk-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root -Force | Out-Null
# DISTINCT content per line: identical lines would let a selection that shifted onto different rows
# pass as unchanged, which is the exact defect being tested for.
'1..40 | ForEach-Object { Write-Host "MARKER-$_-xxxxxxxxxxxxxxxx" }' | Set-Content (Join-Path $root 'marker.ps1') -Encoding UTF8
'1..40 | ForEach-Object { Write-Host "noise-$_" }'                   | Set-Content (Join-Path $root 'noise.ps1') -Encoding UTF8
# Past the core's 5000-line cap plus its batched-trim slack, so eviction really happens.
'1..6000 | ForEach-Object { Write-Host "flood-$_" }'                 | Set-Content (Join-Path $root 'flood.ps1') -Encoding UTF8
# Holds the alt screen for a few seconds, so the check runs while it is actually active.
"[Console]::Write([char]27 + '[?1049h'); Start-Sleep 5; [Console]::Write([char]27 + '[?1049l')" |
    Set-Content (Join-Path $root 'alt.ps1') -Encoding UTF8
$savedClip = try { Get-Clipboard -Raw } catch { '' }
$p = $null
try {
    $p = Start-Process $Exe -ArgumentList @('--pipe', $pipe, '--no-restore') -PassThru -Environment @{ LOCALAPPDATA = $root }
    for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 500; if ((Ctl @('ping')) -match '"ok":true') { break } }
    Start-Sleep 5
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { "  FAIL  no window"; exit 1 }
    if ([SelIn]::IsZoomed($h)) { [void][SelIn]::ShowWindow($h, 9); Start-Sleep 1 }
    [void][SelIn]::SetWindowPos($h, [IntPtr]::Zero, 150, 100, 1000, 600, 0x0004)
    Start-Sleep 2

    Ctl @('session', 'type', "& '$root\marker.ps1'`r") | Out-Null
    Start-Sleep 3
    [SelIn]::Drag($h, 300, 120, 900, 400)
    $orig = Sel
    Check 'a drag makes a selection' ([bool]$orig)

    Ctl @('session', 'type', "& '$root\noise.ps1'`r") | Out-Null
    Start-Sleep 4
    # Non-empty, not merely equal: two empty strings compare equal, so a drag that selected nothing
    # would let this pass while proving the opposite of what it claims.
    Check 'follows its text when output scrolls' ($orig -and ((Sel) -eq $orig)) "was [$($orig.Length)] now [$((Sel).Length)]"

    # The alt screen FIRST, while the shell is known to be at a clean prompt. Ctrl+C below can
    # leave the command line cancelled, and a case that depends on the previous one running cleanly
    # fails for reasons that have nothing to do with selections.
    #
    # Driven from a file that HOLDS the alt screen open: typed as two commands, the shell's own
    # prompt redraw lands in between and the buffer is back before the check runs.
    Ctl @('session', 'type', "& '$root\alt.ps1'`r") | Out-Null
    Start-Sleep 3
    Check 'dropped on entering the alt screen' ([string]::IsNullOrEmpty((Sel))) "still selected"
    Start-Sleep 7   # let alt.ps1 restore the main screen

    # Ctrl+C copies, with output having streamed in between - the report this all started from.
    Ctl @('session', 'type', "& '$root\marker.ps1'`r") | Out-Null
    Start-Sleep 3
    [SelIn]::Drag($h, 300, 120, 900, 400)
    $sel2 = Sel
    Check 'a selection was made for the Ctrl+C case' ([bool]$sel2)
    Ctl @('session', 'type', "& '$root\noise.ps1'`r") | Out-Null
    Start-Sleep 4
    if ($clipOk) {
        Set-Clipboard -Value 'SENTINEL'; Start-Sleep -Milliseconds 250
        [SelIn]::CtrlKey($h, 0x43)
        Start-Sleep 2
        Check 'Ctrl+C copies it after output arrived' ((Get-Clipboard -Raw) -eq $sel2) "clipboard differs from the selection"
    } else { "  SKIP  Ctrl+C copies it after output arrived (no clipboard)" }

    # Eviction: the selected lines fall out of scrollback entirely.
    Ctl @('session', 'type', "& '$root\marker.ps1'`r") | Out-Null
    Start-Sleep 3
    [SelIn]::Drag($h, 300, 120, 900, 400)
    Check 'a second selection was made' ([bool](Sel))
    Ctl @('session', 'type', "& '$root\flood.ps1'`r") | Out-Null
    Start-Sleep 25
    Check 'dropped once its lines are evicted' ([string]::IsNullOrEmpty((Sel))) "still selected: [$(Sel)]"
}
finally {
    if ($p -and -not $p.HasExited) { $p.CloseMainWindow() | Out-Null; Start-Sleep 3 }
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    if ($savedClip) { Set-Clipboard -Value $savedClip }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail) { "selection: $fail failed"; exit 1 }
"selection: all passed"
exit 0
