# The session stress: run by hand before a LOCK change is reviewed, not by run-all.ps1 (it is slow,
# and it proves the absence of a hang, which no per-verb check can).
#
# Shape (P1-lite r5, and again for P2-lite's #23, whose hostResize hold spans the pty-host round
# trip): against one sandbox, at the same time -
#   - two CREATORS, each making 40 sessions over the pipe (80 in all), one of them into a workspace
#     it creates, both selecting and splitting as they go;
#   - a DELETER closing the sessions the creators make as fast as it sees them in `tree`;
#   - a STREAMING pane, a shell printing lines the whole time, so the reader thread is busy under
#     g_lock while the pipe threads resize;
#   - and this script RESIZING and MINIMISING the window on the UI thread's path (WM_SIZE ->
#     syncPaneSizes -> hostResize) - its own handle, never global input - against the pipe
#     threads' hostResize (session.select / split / new).
# Completion is the result: every worker finishes, the process is alive, `ping` and `tree` still
# answer, no shown session sits under 20 columns, and the whole thing fits the time budget. A hang
# on g_lock, a deadlock between a pipe thread and the UI thread, or a pane collapsed by a lost
# resize each fail one of those.
#
# Usage: ./test/stress.ps1 [-Exe bin\agliteterm.exe] [-Sessions 80] [-BudgetSec 300]
param(
    [string]$Exe = "$PSScriptRoot\..\bin\agliteterm.exe",
    [int]$Sessions = 80,
    [int]$BudgetSec = 300
)

$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "  PASS  $name" } else { $script:fail++; "  FAIL  $name$(if ($detail) { " — $detail" })" }
}

"== stress: $Sessions sessions, two creators + a deleter + a streaming pane + a resizing window =="
. "$PSScriptRoot\ui-lib.ps1"
$ctl = Get-CtlPath
if (-not $ctl) { "  SKIP  agwintermctl not found (set AGWINTERMCTL)"; exit 1 }
$exe = Resolve-Lite $Exe
if (-not $exe) { "  SKIP  no build at $Exe"; exit 1 }
"  using: $ctl"

$pipe = 'ctlstress'
$s = $null
$jobs = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $s = Start-Sandbox -Exe $exe -Ctl $ctl -Pipe $pipe
    function Tree { (ConvertFrom-Json (Send-Ctl $s @('tree'))).result }
    function Nodes { Tree | ForEach-Object workspaces | ForEach-Object sessions }
    Check 'setup: the sandbox answers tree with one session' (@(Nodes).Count -eq 1)

    # The streaming pane: a shell that prints a numbered 70-column line without pause for the
    # whole run. -NoExit keeps it a pane afterwards, which is what `session new --command` gives.
    $raw = Send-Ctl $s @('session', 'new', '--name', 'stream', '--command', '1..400000 | ForEach-Object { "line $_ " + ("x" * 60) }')
    $streamId = [string](ConvertFrom-Json $raw).result
    Check 'setup: the streaming pane was created' ([bool](ConvertFrom-Json $raw).ok -and $streamId) "raw: $raw"
    Start-Sleep -Milliseconds 1500
    $t0 = Get-PaneText $s $streamId
    Start-Sleep -Milliseconds 1500
    Check 'setup: the streaming pane is streaming (its text changed over 1.5 s)' ((Get-PaneText $s $streamId) -ne $t0)

    # Workers are separate processes (Start-Job), each with the CLI and the pipe name; each scrubs
    # the caller variables the way Send-Ctl does, so a bare `session new` lands in the active
    # workspace and not "next to" a pane the job does not have.
    $half = [int]($Sessions / 2)
    $creator = {
        param($ctl, $pipe, $n, $tag, $extra)
        foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
        $ok = 0; $ids = @()
        for ($i = 1; $i -le $n; $i++) {
            $args = @('session', 'new', '--name', "$tag-$i") + $extra
            $raw = (& $ctl @args --pipe $pipe --json 2>&1) -join ''
            try { $r = ConvertFrom-Json $raw } catch { $r = $null }
            if ($r -and $r.ok) { $ok++; $ids += [string]$r.result }
            if ($i % 5 -eq 0 -and $ids.Count) { & $ctl session select --target $ids[-1] --pipe $pipe --json 2>&1 | Out-Null }
            if ($i % 4 -eq 0) { & $ctl session split on --pipe $pipe --json 2>&1 | Out-Null }
            if ($i % 4 -eq 2) { & $ctl session split off --pipe $pipe --json 2>&1 | Out-Null }
        }
        [pscustomobject]@{ tag = $tag; ok = $ok; asked = $n }
    }
    $deleter = {
        param($ctl, $pipe, $seconds, $keep)
        foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
        $closed = 0; $idle = 0
        $end = (Get-Date).AddSeconds($seconds)
        while ((Get-Date) -lt $end) {
            $raw = (& $ctl tree --pipe $pipe --json 2>&1) -join ''
            try { $t = (ConvertFrom-Json $raw).result } catch { $t = $null }
            $victims = @($t | ForEach-Object workspaces | ForEach-Object sessions | Where-Object { [string]$_.name -match '^s[ab]-\d+$' })
            if (-not $victims.Count) { $idle++; if ($idle -ge $keep) { break }; Start-Sleep -Milliseconds 300; continue }
            $idle = 0
            foreach ($v in $victims) {
                $r = (& $ctl session close --target ([string]$v.id) --pipe $pipe --json 2>&1) -join ''
                if ($r -match '"ok":true') { $closed++ }
            }
        }
        [pscustomobject]@{ tag = 'deleter'; closed = $closed }
    }
    $jobs += Start-Job -ScriptBlock $creator -ArgumentList $ctl, $pipe, $half, 'sa', @()
    $jobs += Start-Job -ScriptBlock $creator -ArgumentList $ctl, $pipe, ($Sessions - $half), 'sb', @('--workspace-name', 'stress-b', '--create-workspace')
    # The deleter stops after 15 empty polls in a row (nothing left to close) or the budget.
    $jobs += Start-Job -ScriptBlock $deleter -ArgumentList $ctl, $pipe, $BudgetSec, 15

    # Meanwhile the UI thread's resize path: the window alternates between two widths, and sits
    # minimised for a moment every so often, while the pipe threads create, select and split.
    $wide = $true; $tick = 0
    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -and $sw.Elapsed.TotalSeconds -lt $BudgetSec) {
        $tick++
        if ($tick % 7 -eq 0) {
            [void][LiteUi]::ShowWindow($s.Hwnd, 6)    # SW_MINIMIZE, this instance's own handle
            Start-Sleep -Milliseconds 400
            [void][LiteUi]::ShowWindow($s.Hwnd, 9)    # SW_RESTORE
        } else {
            $wide = -not $wide
            [void][LiteUi]::SetWindowPos($s.Hwnd, [IntPtr]::Zero, 150, 100, ($wide ? 1100 : 800), ($wide ? 700 : 550), 0x0004)
        }
        Start-Sleep -Milliseconds 300
    }
    $elapsed = [int]$sw.Elapsed.TotalSeconds
    $stuck = @($jobs | Where-Object { $_.State -eq 'Running' })
    Check "every worker finished within the $BudgetSec s budget (took $elapsed s)" ($stuck.Count -eq 0) "still running: $(($stuck | ForEach-Object Name) -join ', ')"
    $stuck | Stop-Job
    $results = $jobs | Receive-Job
    $jobs | Remove-Job -Force
    $jobs = @()
    $made = ($results | Where-Object { $_.tag -in 'sa', 'sb' } | Measure-Object -Property ok -Sum).Sum
    $closed = ($results | Where-Object { $_.tag -eq 'deleter' }).closed
    "  creators made $made of $Sessions, the deleter closed $closed"
    Check "the creators made all $Sessions sessions (each answered ok)" ($made -eq $Sessions) "made $made"
    Check 'the deleter closed most of them while they were being made' ($closed -ge ($Sessions * 0.8)) "closed $closed"

    # The world afterwards: alive, answering, and no pane collapsed by a resize that was lost.
    [void][LiteUi]::ShowWindow($s.Hwnd, 9)
    [void][LiteUi]::SetWindowPos($s.Hwnd, [IntPtr]::Zero, 150, 100, 1100, 700, 0x0004)
    Start-Sleep -Milliseconds 1500
    Check 'the process is still alive' (-not $s.Proc.HasExited)
    $raw = Send-Ctl $s @('ping')
    Check 'ping still answers ok' ($raw -match '"ok":true') "raw: $raw"
    Send-Ctl $s @('session', 'split', 'off') | Out-Null
    Send-Ctl $s @('session', 'select', '--target', $streamId) | Out-Null
    Start-Sleep -Milliseconds 1000
    $nodes = @(Nodes)
    Check 'tree still answers, with the streaming pane in it' ($nodes.Count -ge 1 -and ($nodes | Where-Object { [string]$_.id -eq $streamId }))
    $small = @($nodes | Where-Object { [int]$_.cols -lt 20 })
    Check 'no session in the tree sits under 20 columns (no resize was lost)' ($small.Count -eq 0) ('collapsed: ' + (($small | ForEach-Object { "$($_.id)=$($_.cols)" }) -join ' '))
    $t1 = Get-PaneText $s $streamId
    Start-Sleep -Milliseconds 1500
    Check 'the streaming pane is still streaming afterwards (the reader thread is not stuck)' ((Get-PaneText $s $streamId) -ne $t1 -or ([string]$t1).Contains('line 400000'))
    $log = Join-Path $s.AppDir "agliteterm\agliteterm-$pipe.log"
    $refused = if (Test-Path $log) { @(Get-Content $log | Where-Object { $_ -match 'not accepted by the pty-host' }) } else { @() }
    "  pty-host refused resizes rolled back (the retry path): $($refused.Count)"
}
finally {
    if ($jobs.Count) { $jobs | Stop-Job -ErrorAction SilentlyContinue; $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }
    if ($s) { Stop-Sandbox $s }
}

if ($fail) { "stress: $fail failed"; exit 1 }
"stress: all passed"
exit 0
