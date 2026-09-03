# Shared plumbing for the UI checks in qa/ — the ones that need a real window, real mouse buttons
# and a real modifier key, which no unit test can reach. Sibling of agwinterm's tests/ui/lib.ps1;
# the differences are lite's, and they are marked.
#
# Suite rules, and they are not negotiable:
#   - ALWAYS a sandbox instance: --pipe <name> and a throwaway %LOCALAPPDATA%. lite is plain Win32
#     and reads the environment, so the override really does isolate it — unlike agwinterm, where
#     .NET resolves the known folder and needs --app-id instead. Settings, though, live in
#     HKCU\Software\agliteterm and are NOT isolated: save and restore anything a case changes.
#   - NEVER inject global input. No keybd_event, no SendInput. Everything is PostMessage to this
#     instance's own window handles, so whatever the user is typing in stays untouched. Ctrl+C is the
#     one thing PostMessage cannot express alone (the modifier must be visible to GetKeyState), and
#     it is done by attaching to THIS instance's input queue and setting the shared key state.
#   - Capture with PrintWindow, never CopyFromScreen, which grabs whatever is on top.
#
# Dot-source this, then Start-Sandbox / Send-Ctl / Stop-Sandbox.

# One build output here (bin\agliteterm.exe) - the two-Release-roots trap is agwinterm's. The
# control client is an external dependency, resolved the way every other check resolves it.
. "$PSScriptRoot\ctl-path.ps1"

function Resolve-Lite([string]$explicit) {
    foreach ($c in @($explicit, (Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\agliteterm.exe'))) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LiteUi {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] s);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] s);

    static IntPtr Pt(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }

    /// <summary>Press, drag, release. Client coordinates, like the button messages carry.</summary>
    public static void Drag(IntPtr h, int x1, int y1, int x2, int y2) {
        PostMessageW(h, 0x0201, (IntPtr)1, Pt(x1, y1));
        for (int i = 1; i <= 8; i++) {
            PostMessageW(h, 0x0200, (IntPtr)1, Pt(x1 + (x2 - x1) * i / 8, y1 + (y2 - y1) * i / 8));
            System.Threading.Thread.Sleep(40);
        }
        PostMessageW(h, 0x0202, IntPtr.Zero, Pt(x2, y2));
        System.Threading.Thread.Sleep(250);
    }

    /// <summary>As Drag, but HOLDS the button outside the pane for holdMs first. Drag-autoscroll only
    /// ticks while the button is down and the cursor is off the pane: release too early and its 50ms
    /// timer never runs, so a check that means to exercise it silently exercises nothing.</summary>
    public static void DragHold(IntPtr h, int x1, int y1, int x2, int y2, int holdMs) {
        PostMessageW(h, 0x0201, (IntPtr)1, Pt(x1, y1));
        for (int i = 1; i <= 8; i++) {
            PostMessageW(h, 0x0200, (IntPtr)1, Pt(x1 + (x2 - x1) * i / 8, y1 + (y2 - y1) * i / 8));
            System.Threading.Thread.Sleep(40);
        }
        for (int i = 0; i < holdMs / 100; i++) {
            PostMessageW(h, 0x0200, (IntPtr)1, Pt(x2, y2));
            System.Threading.Thread.Sleep(100);
        }
        PostMessageW(h, 0x0202, IntPtr.Zero, Pt(x2, y2));
        System.Threading.Thread.Sleep(250);
    }

    public static void Click(IntPtr h, int button, int x, int y) {
        uint down = button == 2 ? 0x0204u : 0x0201u, up = button == 2 ? 0x0205u : 0x0202u;
        PostMessageW(h, down, (IntPtr)(button == 2 ? 2 : 1), Pt(x, y));
        System.Threading.Thread.Sleep(120);
        PostMessageW(h, up, IntPtr.Zero, Pt(x, y));
        System.Threading.Thread.Sleep(300);
    }

    /// <summary>WM_MOUSEWHEEL carries SCREEN coordinates, unlike the button messages.</summary>
    public static void Wheel(IntPtr h, int cx, int cy, int notches) {
        var p = new POINT(); p.X = cx; p.Y = cy; ClientToScreen(h, ref p);
        for (int i = 0; i < notches; i++) {
            PostMessageW(h, 0x020A, (IntPtr)(120 << 16), Pt(p.X, p.Y));
            System.Threading.Thread.Sleep(60);
        }
        System.Threading.Thread.Sleep(300);
    }

    // WM_KEYUP's lParam must carry the previous-state (bit 30) and transition (bit 31) flags, as a
    // real keyboard's does. Posted with lParam 1 - a keydown-shaped lParam - Windows translates the
    // keyup into a SECOND WM_CHAR, which lite (having swallowed the keydown's) forwards to the shell:
    // for Backspace that is 0x08, which PSReadLine reads as Ctrl+Backspace and kills the whole word.
    const int KeyUpLParam = unchecked((int)0xC0000001);

    /// <summary>A key with no modifiers, n times.</summary>
    public static void Key(IntPtr h, int vk, int times) {
        for (int i = 0; i < times; i++) {
            PostMessageW(h, 0x0100, (IntPtr)vk, (IntPtr)1);
            PostMessageW(h, 0x0101, (IntPtr)vk, (IntPtr)KeyUpLParam);
            System.Threading.Thread.Sleep(30);
        }
        System.Threading.Thread.Sleep(250);
    }

    /// <summary>Ctrl (+Shift) + key. A posted WM_KEYDOWN cannot make GetKeyState see the modifier,
    /// so this attaches to the target's input queue and sets the shared state for the duration —
    /// scoped to this instance, nothing injected globally.</summary>
    /// <summary>Any modifier combination. A posted WM_MOUSEWHEEL does not reach lite's handler, so
    /// scrollback is driven from the keyboard (Shift+PageUp/PageDown) instead.</summary>
    public static void KeyMods(IntPtr h, int vk, bool ctrl, bool shift, int times) {
        uint me = GetCurrentThreadId(), it = GetWindowThreadProcessId(h, IntPtr.Zero);
        AttachThreadInput(me, it, true);
        var st = new byte[256]; GetKeyboardState(st);
        if (ctrl)  { st[0x11] = 0x80; st[0xA2] = 0x80; }
        if (shift) { st[0x10] = 0x80; st[0xA0] = 0x80; }
        SetKeyboardState(st);
        for (int i = 0; i < times; i++) {
            PostMessageW(h, 0x0100, (IntPtr)vk, (IntPtr)1);
            System.Threading.Thread.Sleep(120);
            PostMessageW(h, 0x0101, (IntPtr)vk, (IntPtr)KeyUpLParam);
            System.Threading.Thread.Sleep(80);
        }
        st[0x11] = 0; st[0xA2] = 0; st[0x10] = 0; st[0xA0] = 0;
        SetKeyboardState(st);
        AttachThreadInput(me, it, false);
        System.Threading.Thread.Sleep(300);
    }

    public static void Chord(IntPtr h, int vk, bool shift) {
        uint me = GetCurrentThreadId(), it = GetWindowThreadProcessId(h, IntPtr.Zero);
        AttachThreadInput(me, it, true);
        var st = new byte[256]; GetKeyboardState(st);
        st[0x11] = 0x80; st[0xA2] = 0x80;                      // VK_CONTROL, VK_LCONTROL
        if (shift) { st[0x10] = 0x80; st[0xA0] = 0x80; }       // VK_SHIFT, VK_LSHIFT
        SetKeyboardState(st);
        PostMessageW(h, 0x0100, (IntPtr)vk, (IntPtr)1);
        System.Threading.Thread.Sleep(400);
        st[0x11] = 0; st[0xA2] = 0; st[0x10] = 0; st[0xA0] = 0;
        SetKeyboardState(st);
        PostMessageW(h, 0x0101, (IntPtr)vk, (IntPtr)KeyUpLParam);
        AttachThreadInput(me, it, false);
        System.Threading.Thread.Sleep(300);
    }
}
'@

<#
.SYNOPSIS Launch an isolated agliteterm and wait until its control pipe answers.
#>
function Start-Sandbox {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Ctl,
          [Parameter(Mandatory)][string]$Pipe, [int]$Width = 1100, [int]$Height = 700)

    $home_ = Join-Path $env:TEMP ("$Pipe-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $home_ | Out-Null

    # A check must never inherit the pane it is being RUN from, or `session type` lands in the
    # caller's own terminal instead of the sandbox. Start-Process -Environment ADDS to the inherited
    # block, it does not replace it - so the updater's test seam is scrubbed here as well, or a
    # shell that was testing the updater makes the sandbox answer `ping` with a made-up version.
    foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE', 'AGWINTERM_VERSION_OVERRIDE') {
        Remove-Item "env:$v" -ErrorAction SilentlyContinue
    }

    $p = Start-Process $Exe -ArgumentList @('--pipe', $Pipe, '--no-restore') -PassThru `
                            -Environment @{ LOCALAPPDATA = $home_ }
    $s = [pscustomobject]@{ Proc = $p; Ctl = $Ctl; Pipe = $Pipe; AppDir = $home_; Hwnd = [IntPtr]::Zero }
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 500
        if ((Send-Ctl $s @('ping')) -match '"ok":true') { break }
    }
    Start-Sleep 5
    $s.Hwnd = $p.MainWindowHandle
    if ($s.Hwnd -ne [IntPtr]::Zero) {
        # A maximised window makes every coordinate in every case depend on the monitor.
        if ([LiteUi]::IsZoomed($s.Hwnd)) { [void][LiteUi]::ShowWindow($s.Hwnd, 9); Start-Sleep 1 }
        [void][LiteUi]::SetWindowPos($s.Hwnd, [IntPtr]::Zero, 150, 100, $Width, $Height, 0x0004)
        Start-Sleep 2
    }
    return $s
}

<#
.SYNOPSIS Re-attach to a sandbox this session already launched.
An agent runs a case file across several shell invocations and shell state does not survive them,
while the instance does. This rebuilds the handle object from the running process, found by the
--pipe it was launched with, so the next step can carry on driving the same window.
#>
function Connect-Sandbox {
    param([Parameter(Mandatory)][string]$Ctl, [Parameter(Mandatory)][string]$Pipe)
    $proc = Get-CimInstance Win32_Process -Filter "Name = 'agliteterm.exe'" |
            Where-Object { $_.CommandLine -match "--pipe\s+$([regex]::Escape($Pipe))(\s|$)" } |
            Select-Object -First 1
    if (-not $proc) { throw "no sandbox instance is running on pipe '$Pipe'" }
    $p = Get-Process -Id $proc.ProcessId
    [pscustomobject]@{ Proc = $p; Ctl = $Ctl; Pipe = $Pipe; Hwnd = $p.MainWindowHandle; AppDir = $null }
}

function Stop-Sandbox {
    param([Parameter(Mandatory)]$S)
    if ($S.Proc -and -not $S.Proc.HasExited) { $S.Proc.CloseMainWindow() | Out-Null; Start-Sleep 3 }
    if ($S.Proc -and -not $S.Proc.HasExited) { Stop-Process -Id $S.Proc.Id -Force }
    if ($S.AppDir) { Remove-Item $S.AppDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Send-Ctl {
    param([Parameter(Mandatory)]$S, [Parameter(Mandatory)][string[]]$Argv)
    # EVERY call, not just at launch. A verb with no --target resolves the CALLER's session from
    # these variables, and a QA run is itself started from inside an agwinterm pane: leave them set
    # and `session text` answers about a session the sandbox has never heard of (empty), while
    # `session type` is accepted and discarded. Nothing errors, and a whole suite goes green having
    # driven nothing at all.
    foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') {
        Remove-Item "env:$v" -ErrorAction SilentlyContinue
    }
    (& $S.Ctl @Argv --pipe $S.Pipe --json 2>&1) -join ''
}

function Get-CtlResult {
    param([Parameter(Mandatory)]$S, [Parameter(Mandatory)][string[]]$Argv)
    $raw = Send-Ctl $S $Argv
    try { (ConvertFrom-Json $raw).result } catch { '' }
}

function Get-PaneText { param([Parameter(Mandatory)]$S, [string]$Target)
    if ($Target) { Get-CtlResult $S @('session', 'text', '--target', $Target) }
    else { Get-CtlResult $S @('session', 'text') }
}

function Get-PaneSelection { param([Parameter(Mandatory)]$S) Get-CtlResult $S @('session', 'copy') }

<#
.SYNOPSIS Write a .ps1 into $Dir and return a path safe to type into a shell.
Forward slashes throughout: a Windows path typed through `session type` is fine with them, and it
keeps backslash escapes out of every quoted string in the checks.
#>
function New-ScriptFile {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Name,
          [Parameter(Mandatory)][string[]]$Lines)
    $path = Join-Path $Dir $Name
    $Lines | Set-Content $path -Encoding UTF8
    return $path.Replace([char]92, '/')
}
