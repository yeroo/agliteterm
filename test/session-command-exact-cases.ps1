# agliteterm #79: an explicit empty PowerShell argv stays exact across duplicate and Reopen Closed, and an
# ordinary profile PowerShell session keeps its wrapper. Lite-only: the mirrored session-command-cases.ps1
# is shared with agwinterm and stays as it is. Dot-sourced by session-command.ps1, after the mirrored
# cases: CommandRpc, CommandText, $proc and $commandArtifact come from there.
#
# The command line is READ OFF THE PROCESS, never inferred from the screen. The pane's shell answers a
# fresh-nonce challenge with its own pid and birth time (owned-procs.ps1, #49); the birth is matched to
# the process record, so a reused pid cannot answer for it; only then is CommandLine read.
. "$PSScriptRoot/owned-procs.ps1"
if (-not ('LiteReopenCommand' -as [type])) { Add-Type @'
using System; using System.Runtime.InteropServices;
public static class LiteReopenCommand { [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l); }
'@ }

$exactIds = @()
$exactWrapper = '(^|\s)-(EncodedCommand|NoLogo|NoExit)\b'

function ExactCheck([bool]$ok, [string]$name, [string]$detail) {
    if (-not $ok) { throw "$name : $detail" }
    $script:commandChecks++
    "PASS $name"
}

function ExactCommandLine([string]$id) {
    $answer = Ask-PaneShell { param($t) $null = CommandRpc 'session.type' @{ text = $t } $id } { CommandText $id } 20000
    $row = Get-CimInstance Win32_Process -Filter "ProcessId=$($answer.Pid)"
    if (-not $row) { throw "session $id answered pid $($answer.Pid), which is not running" }
    if ((UtcMicroTicks $row.CreationDate) -ne ($answer.BornUtcTicks - ($answer.BornUtcTicks % 10))) {
        throw "session $id answered pid $($answer.Pid), but that pid is now a different process"
    }
    [string]$row.CommandLine
}

function ExactTreeIds { @((CommandRpc 'tree' @{} '').workspaces | ForEach-Object { $_.sessions } | ForEach-Object { [string]$_.id }) }

try {
    # The #79 repro: `session new --command-mode direct --command powershell.exe`, zero arguments.
    $exact = [string](CommandRpc 'session.new' @{ command = 'powershell.exe'; 'command-mode' = 'direct'; 'no-select' = $true; cwd = $commandArtifact; name = 'exact-empty' } '')
    $exactIds += , $exact
    $line = ExactCommandLine $exact
    ExactCheck ($line -notmatch $exactWrapper) 'explicit empty PowerShell argv starts with no wrapper' $line

    $dup = [string](CommandRpc 'session.duplicate' @{} $exact)
    $exactIds += , $dup
    $line = ExactCommandLine $dup
    ExactCheck ($line -notmatch $exactWrapper) 'duplicate keeps an explicit empty argv exact' $line

    # Reopen Closed: close the duplicate, then send IDM_REOPEN to this owned window only - the message the
    # accelerator and the File menu send, never global input.
    $before = ExactTreeIds
    $null = CommandRpc 'session.close' @{} $dup
    for ($try = 0; $try -lt 50 -and (ExactTreeIds) -contains $dup; $try++) { Start-Sleep -Milliseconds 100 }
    ExactCheck (-not ((ExactTreeIds) -contains $dup)) 'setup: the duplicate is closed' "tree still lists $dup"
    $frame = Get-OwnedLiteWindow $proc
    [void][LiteReopenCommand]::PostMessageW($frame, 0x0111, [IntPtr]122, [IntPtr]::Zero)   # WM_COMMAND, IDM_REOPEN
    $reopened = $null
    for ($try = 0; $try -lt 80 -and -not $reopened; $try++) {
        Start-Sleep -Milliseconds 100
        $reopened = @(ExactTreeIds | Where-Object { $before -notcontains $_ }) | Select-Object -First 1
    }
    ExactCheck ([bool]$reopened) 'setup: Reopen Closed brought the session back' 'no new session appeared'
    $exactIds += , $reopened
    $line = ExactCommandLine $reopened
    ExactCheck ($line -notmatch $exactWrapper) 'Reopen Closed keeps an explicit empty argv exact' $line

    # The existing behaviour that must not change: a PowerShell profile with no args gets its wrapper.
    $wrapped = [string](CommandRpc 'session.new' @{ profile = 'WrappedPwsh'; 'no-select' = $true; cwd = $commandArtifact; name = 'wrapped-profile' } '')
    $exactIds += , $wrapped
    $line = ExactCommandLine $wrapped
    ExactCheck ($line -match '-EncodedCommand') 'ordinary PowerShell profile starts with its wrapper' $line

    $wrappedDup = [string](CommandRpc 'session.duplicate' @{} $wrapped)
    $exactIds += , $wrappedDup
    $line = ExactCommandLine $wrappedDup
    ExactCheck ($line -match '-EncodedCommand') 'duplicate keeps the ordinary wrapper' $line
} finally {
    foreach ($id in $exactIds) { if ($id) { $null = CommandRpc 'session.close' @{} $id -AllowError } }
}
