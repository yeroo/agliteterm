# Clipboard + host actions.
#
# The emulator performs no side effects of its own: it QUEUES them and the host drains them after
# each feed. lite never drained, and the cost was bigger than it looks — OSC 52 clipboard writes
# were dropped, and so was every REPLY the terminal owed a program that asked it a question,
# because a query answer is a host action too. This check exists so that never silently returns.
#
# It also covers the two clipboard bindings that make lite behave like the full app: right-click
# pastes even while a TUI is grabbing the mouse (Claude Code holds mouse mode on for its whole
# run, which is exactly when pasting matters), and Ctrl+C copies a selection without ever taking
# the interrupt away when there is nothing selected.
#
# Suite rules: sandbox instance, throwaway %LOCALAPPDATA%, and NO global input injection —
# everything is PostMessage to this instance's own window. Ctrl+C is the one case PostMessage
# cannot express on its own (the modifier has to be visible to GetKeyState), so the check attaches
# to the instance's input queue and sets the shared key state. Still nothing injected globally:
# whatever window the user is typing in is untouched.
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

"== clipboard =="

. "$PSScriptRoot\ctl-path.ps1"
$ctl = Get-CtlPath
if (-not $ctl) { "  SKIP  agwintermctl not found (set AGWINTERMCTL)"; exit ($Strict ? 1 : 0) }
if (-not (Test-Path $Exe)) { "  SKIP  no build at $Exe"; exit ($Strict ? 1 : 0) }

$pipe = 'clipchk'
foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') {
    Remove-Item "env:$v" -ErrorAction SilentlyContinue
}
function Ctl { param([string[]]$a) (& $ctl @a --pipe $pipe --json 2>&1) -join '' }
function Screen { (Ctl @('session', 'text') | ConvertFrom-Json).result }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClipIn {
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
    public static void Click(IntPtr h, uint down, uint up, int x, int y) {
        PostMessageW(h, down, (IntPtr)1, Pt(x, y));
        System.Threading.Thread.Sleep(60);
        PostMessageW(h, up, IntPtr.Zero, Pt(x, y));
    }
    public static void Drag(IntPtr h, int x1, int y1, int x2, int y2) {
        PostMessageW(h, 0x0201, (IntPtr)1, Pt(x1, y1));            // WM_LBUTTONDOWN
        for (int i = 1; i <= 6; i++) {
            int x = x1 + (x2 - x1) * i / 6, y = y1 + (y2 - y1) * i / 6;
            PostMessageW(h, 0x0200, (IntPtr)1, Pt(x, y));          // WM_MOUSEMOVE, MK_LBUTTON
            System.Threading.Thread.Sleep(30);
        }
        PostMessageW(h, 0x0202, IntPtr.Zero, Pt(x2, y2));          // WM_LBUTTONUP
    }
    /// <summary>A keystroke whose modifier the target's GetKeyState can actually see.</summary>
    public static void CtrlKey(IntPtr h, int vk) {
        uint me = GetCurrentThreadId(), it = GetWindowThreadProcessId(h, IntPtr.Zero);
        AttachThreadInput(me, it, true);
        var st = new byte[256];
        GetKeyboardState(st);
        st[0x11] = 0x80; st[0xA2] = 0x80;                          // VK_CONTROL, VK_LCONTROL
        SetKeyboardState(st);
        PostMessageW(h, 0x0100, (IntPtr)vk, (IntPtr)1);            // WM_KEYDOWN
        System.Threading.Thread.Sleep(400);
        st[0x11] = 0; st[0xA2] = 0;
        SetKeyboardState(st);
        PostMessageW(h, 0x0101, (IntPtr)vk, (IntPtr)1);            // WM_KEYUP
        AttachThreadInput(me, it, false);
    }
}
'@

# Can this machine use the clipboard at all? A CI runner in a non-interactive window station
# cannot, and that is a fact about the runner, not a bug in lite. The clipboard-dependent checks
# say SKIP rather than FAIL there — but they are NOT silently dropped: the note is printed, and
# the query-reply check (which needs no clipboard) still runs, so the suite is never reporting
# success having checked nothing.
$clipOk = $false
try {
    Set-Clipboard -Value 'agliteterm-clipboard-probe'
    $clipOk = ((Get-Clipboard -Raw) -eq 'agliteterm-clipboard-probe')
} catch { $clipOk = $false }
if (-not $clipOk) { "  NOTE  this machine has no usable clipboard - clipboard assertions will skip" }

$root = Join-Path $env:TEMP ("clip-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root -Force | Out-Null
$dsrPs1 = Join-Path $root 'dsr.ps1'
@'
$e = [char]27
[Console]::Write("$e[6n")
$r = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 2000 -and $r.Count -eq 0) {
    while ([Console]::KeyAvailable) { $r += [int][char][Console]::ReadKey($true).KeyChar }
    Start-Sleep -Milliseconds 50
}
Write-Host "DSR=<$($r -join ',')>"
'@ | Set-Content $dsrPs1 -Encoding UTF8
$markerPs1 = Join-Path $root 'marker.ps1'
@'
1..40 | ForEach-Object { Write-Host 'COPY-ME-MARKER' }
'@ | Set-Content $markerPs1 -Encoding UTF8
$savedClip = try { Get-Clipboard -Raw } catch { '' }   # the machine's clipboard is the user's, not ours
$p = $null

try {
    $p = Start-Process $Exe -ArgumentList @('--pipe', $pipe, '--no-restore') -PassThru -Environment @{ LOCALAPPDATA = $root }
    for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 500; if ((Ctl @('ping')) -match '"ok":true') { break } }
    Start-Sleep 5
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { "  FAIL  no window"; exit 1 }
    if ([ClipIn]::IsZoomed($h)) { [void][ClipIn]::ShowWindow($h, 9); Start-Sleep 1 }
    [void][ClipIn]::SetWindowPos($h, [IntPtr]::Zero, 150, 100, 1000, 600, 0x0004)
    Start-Sleep 2

    # --- right-click paste, with the app grabbing the mouse exactly as a TUI does ---------------
    Ctl @('session', 'type', "`$e=[char]27; [Console]::Write(`"`$e[?1000h`$e[?1006h`")`r") | Out-Null
    Start-Sleep 2
    if ($clipOk) {
        Set-Clipboard -Value 'echo PASTED_OK'; Start-Sleep -Milliseconds 250
        [ClipIn]::Click($h, 0x0204, 0x0205, 500, 300)      # WM_RBUTTONDOWN / WM_RBUTTONUP
        Start-Sleep 2
        $t = Screen
        Check 'right-click pastes into a mouse-reporting app' ($t -match 'PASTED_OK')
    } else { "  SKIP  right-click pastes into a mouse-reporting app (no clipboard)" }
    Ctl @('session', 'type', "`r") | Out-Null
    Start-Sleep 2
    Ctl @('session', 'type', "`$e=[char]27; [Console]::Write(`"`$e[?1000l`$e[?1006l`")`r") | Out-Null
    Start-Sleep 2

    # --- OSC 52: the program writes the clipboard ----------------------------------------------
    if ($clipOk) {
        Set-Clipboard -Value 'SENTINEL-BEFORE-OSC52'; Start-Sleep -Milliseconds 250
        Ctl @('session', 'type', "`$e=[char]27; [Console]::Write(`"`$e]52;c;aGVsbG8gZnJvbSBvc2M1Mg==`$([char]7)`")`r") | Out-Null
        Start-Sleep 3
        $c = Get-Clipboard -Raw
        Check 'an OSC 52 write reaches the Windows clipboard' ($c -eq 'hello from osc52') "clipboard is [$c]"
    } else { "  SKIP  an OSC 52 write reaches the Windows clipboard (no clipboard)" }

    # --- a query gets its answer ----------------------------------------------------------------
    # DSR cursor-position, read back from stdin inside the session. Undrained, the reply was never
    # sent at all and a program that waits for one waits forever.
    #
    # Run it from a FILE. A long single-line probe full of quotes and backticks is the documented
    # way to lose a command in transit through `session type` - on a CI runner this one was echoed
    # onto the command line and never executed at all.
    Ctl @('session', 'type', "& '$dsrPs1'`r") | Out-Null
    Start-Sleep 6
    $t = Screen
    # 27,91 = ESC [ ; 82 = 'R'. A drained reply reads 27,91,<row>,59,<col>,82.
    Check 'a DSR query is answered' ($t -match 'DSR=<27,91[\d,]*,82>') "screen tail: $($t.Substring([Math]::Max(0, $t.Length - 200)))"

    # --- Ctrl+C with a selection copies ---------------------------------------------------------
    # FILL the screen with the marker rather than printing it once: any rectangle inside the
    # terminal then contains it, so the check cannot fail on the cell height, the prompt, or how
    # much the runner's shell had already scrolled.
    Ctl @('session', 'type', "& '$markerPs1'`r") | Out-Null
    Start-Sleep 3
    # Start the drag past the SIDEBAR, not at a fixed x. The sidebar's width is persisted in HKCU,
    # which is shared with every other suite and with the user's own agliteterm (test/ui-lib.ps1), so
    # a hard-coded 200 lands inside a sidebar any wider than ~195 and the drag selects nothing - which
    # is exactly what conformance's `sidebar width 260` step caused once the client could send it.
    $sbSpan = 0
    try {
        $sbr = (ConvertFrom-Json (Ctl @('sidebar', 'width'))).result
        if ($sbr.visible) { $sbSpan = [int]$sbr.width + 5 }
    } catch { $sbSpan = 0 }
    $dragX = [Math]::Max(200, $sbSpan + 40)
    [ClipIn]::Drag($h, $dragX, 80, 960, 555)
    Start-Sleep 1
    if ($clipOk) {
        # Overwrite what auto-copy-on-release already put there, so only Ctrl+C can restore it.
        Set-Clipboard -Value 'SENTINEL-BEFORE-CTRL-C'; Start-Sleep -Milliseconds 250
        [ClipIn]::CtrlKey($h, 0x43)
        Start-Sleep 2
        $c = Get-Clipboard -Raw
        Check 'Ctrl+C copies the selection' ($c -like '*COPY-ME-MARKER*') "clipboard is [$c]"
    } else { "  SKIP  Ctrl+C copies the selection (no clipboard)" }

    # --- ...and with nothing selected, the shell still gets its interrupt ------------------------
    Ctl @('session', 'type', 'x') | Out-Null
    Start-Sleep 1
    [ClipIn]::Click($h, 0x0201, 0x0202, 600, 400)   # a plain click clears the selection
    Start-Sleep 1
    $before = Screen
    [ClipIn]::CtrlKey($h, 0x43)
    Start-Sleep 2
    $after = Screen
    Check 'Ctrl+C with nothing selected still reaches the shell' ($after.Length -gt $before.Length) `
        "screen unchanged; tail: $($after.Substring([Math]::Max(0, $after.Length - 200)))"
}
finally {
    if ($p -and -not $p.HasExited) { $p.CloseMainWindow() | Out-Null; Start-Sleep 3 }
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    if ($savedClip) { Set-Clipboard -Value $savedClip }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail) { "clipboard: $fail failed"; exit 1 }
"clipboard: all passed"
exit 0
