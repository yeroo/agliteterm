# qa/persistence.md - "The persisted half: a restart brings the context and the slot back". Drives
# a sandbox: two sessions, a split, a context on one, a marker command running in two panes, one
# `restore capture`; then reads the STATE FILE and the tree, closes the window gracefully, relaunches
# the same instance WITHOUT --no-restore, and reads both again. The assertion is on the world after
# the restart - the file's C/P/K lines and what `tree --json` says - not on the verbs' replies.
#
# Usage: pwsh qa\fixtures\persistence-restart.ps1 [-Exe <agliteterm.exe>] [-Kill]
#   -Kill  ends the first window with Stop-Process instead of a close, the crash the capture is for.
# Run ALONE (test/ui-lib.ps1's rule: sandboxes share the desktop and the pty-host).
param([string]$Exe, [switch]$Kill)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'test\ui-lib.ps1')

$exe = Resolve-Lite $Exe
$ctl = Get-CtlPath
if (-not $ctl) { throw 'agwintermctl not found (set AGWINTERMCTL)' }
$probe = (& $ctl restore --pipe 'qa-p3r-probe' --json 2>&1) -join ''
if ($probe -notmatch 'usage: agwintermctl restore') { "SKIP  the client at $ctl predates P3 (no `restore` command); set AGWINTERMCTL to a post-#233 build"; exit 0 }

$pipe = 'qa-p3r'
$marker = 'ping -n 311 127.0.0.1'
# The slot holds the command line as the PROCESS reports it ("C:\Windows\system32\PING.EXE" -n 311
# 127.0.0.1), not the text that was typed, so the checks match the arguments, never the whole line.
$markerRx = '-n 311 127\.0\.0\.1'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "  PASS  $name" } else { $script:fail++; "  FAIL  $name$(if ($detail) { " - $detail" })" }
}
function Tree($S) { (ConvertFrom-Json (Send-Ctl $S @('tree', '--json'))).result }
function Node($S, [string]$name) { foreach ($w in (Tree $S).workspaces) { foreach ($n in $w.sessions) { if ($n.name -eq $name) { return $n } } } }
function StateLines([string]$dir) { Get-Content (Join-Path $dir "agliteterm\sessions-$pipe.tsv") }
function Wait-Ping($S) { for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 500; if ((Send-Ctl $S @('ping')) -match '"ok":true') { return $true } }; return $false }
function Stop-Markers { Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -match '311' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }

$s = Start-Sandbox -Exe $exe -Ctl $ctl -Pipe $pipe
$p2 = $null
try {
    "== setup =="
    $alpha = [string](Get-CtlResult $s @('session', 'new', '--name', 'alpha'))
    $beta  = [string](Get-CtlResult $s @('session', 'new', '--name', 'beta'))
    Send-Ctl $s @('session', 'select', '--target', $alpha) | Out-Null
    $split = [string](Get-CtlResult $s @('session', 'split'))
    Start-Sleep 4
    Check 'setup: alpha, beta and alpha''s split exist' ($alpha -and $beta -and $split)

    $ctx = Send-Ctl $s @('session', 'context', 'reviewing the P3 diff', '--target', $alpha)
    Check 'session context on alpha answers the value in effect' ($ctx -match '"context":"reviewing the P3 diff"') $ctx
    Send-Ctl $s @('session', 'type', "$marker`r", '--target', $split) | Out-Null
    Send-Ctl $s @('session', 'type', "$marker`r", '--target', $beta) | Out-Null
    Start-Sleep 3
    $cap = Send-Ctl $s @('restore', 'capture')
    "  capture reply: $cap"
    $capR = (ConvertFrom-Json $cap).result
    Check 'restore capture reports the marker under alpha''s split and under beta, alpha''s own pane null' `
        (($capR.panes | Where-Object { $_.pane -eq $split }).captured -match $markerRx -and
         ($capR.panes | Where-Object { $_.pane -eq $beta }).captured -match $markerRx -and
         $null -eq ($capR.panes | Where-Object { $_.pane -eq $alpha }).captured) $cap
    Check 'replayOnRestore is false' ($capR.replayOnRestore -eq $false)

    "== the file, before the restart =="
    $lines = StateLines $s.AppDir
    $lines | ForEach-Object { "  $_" }
    $sIdx = @{}; $i = 0
    foreach ($l in $lines) { if ($l -like "S`t*") { $sIdx[($l -split "`t")[2]] = $i; $i++ } }
    Check 'a C line carries alpha''s context at alpha''s S index' ($lines -contains "C`t$($sIdx['alpha'])`treviewing the P3 diff")
    Check 'a P line names alpha''s split' (@($lines | Where-Object { $_ -like "P`t$($sIdx['alpha'])`t*" }).Count -eq 1)
    Check 'alpha''s K line has an empty pane 0 and the marker in pane 1' (@($lines | Where-Object { $_ -match "^K`t$($sIdx['alpha'])`t`t[^`t]*$markerRx$" }).Count -eq 1)
    Check 'beta''s K line has the marker in pane 0 and an empty pane 1' (@($lines | Where-Object { $_ -match "^K`t$($sIdx['beta'])`t[^`t]*$markerRx`t$" }).Count -eq 1)
    $kAt = [array]::IndexOf($lines, ($lines | Where-Object { $_ -like "K`t*" } | Select-Object -First 1))
    $pAt = [array]::IndexOf($lines, ($lines | Where-Object { $_ -like "P`t*" } | Select-Object -First 1))
    $cAt = [array]::IndexOf($lines, ($lines | Where-Object { $_ -like "C`t*" } | Select-Object -First 1))
    Check 'order: C before P before K' ($cAt -lt $pAt -and $pAt -lt $kAt)

    "== restart ($(if ($Kill) { 'killed' } else { 'graceful' })) =="
    if ($Kill) { Stop-Process -Id $s.Proc.Id -Force } else { $s.Proc.CloseMainWindow() | Out-Null }
    for ($i = 0; $i -lt 40 -and -not $s.Proc.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    Check 'the first window is gone' $s.Proc.HasExited
    if (-not $Kill) { Stop-Markers }   # a graceful close ends the shells; the ping is a child of one, so this is belt and braces

    $scrub = 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE', 'AGWINTERM_VERSION_OVERRIDE'
    $saved = @{}
    foreach ($v in $scrub) { $saved[$v] = [Environment]::GetEnvironmentVariable($v); Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    try { $p2 = Start-Process $exe -ArgumentList @('--pipe', $pipe) -PassThru -Environment @{ LOCALAPPDATA = $s.AppDir } }
    finally { foreach ($v in $scrub) { if ($null -ne $saved[$v]) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) } } }
    $s2 = [pscustomobject]@{ Proc = $p2; Ctl = $ctl; Pipe = $pipe; AppDir = $null; Hwnd = [IntPtr]::Zero }
    Check 'the relaunch answers' (Wait-Ping $s2)
    Start-Sleep 6

    "== the tree, after the restart =="
    $a2 = Node $s2 'alpha'; $b2 = Node $s2 'beta'
    "  alpha: $($a2 | ConvertTo-Json -Compress)"
    "  beta:  $($b2 | ConvertTo-Json -Compress)"
    Check 'alpha is back with its context' ($a2 -and $a2.context -eq 'reviewing the P3 diff')
    Check 'beta is back with no context key' ($b2 -and ($b2.PSObject.Properties.Name -notcontains 'context'))
    $a2caps = if ($a2.capturedCommands) { @($a2.capturedCommands.PSObject.Properties) } else { @() }
    Check 'alpha''s slot came back on its split (one key, not the session''s own id, holding the marker)' `
        ($a2caps.Count -eq 1 -and $a2caps[0].Name -ne $a2.id -and $a2caps[0].Value -match $markerRx) ($a2.capturedCommands | ConvertTo-Json -Compress)
    Check 'beta''s slot came back on its own pane' ($b2.capturedCommands -and $b2.capturedCommands.($b2.id) -match $markerRx) ($b2.capturedCommands | ConvertTo-Json -Compress)
    Check 'the split is a pane, not a listed session (the sandbox''s default session, alpha and beta; no fourth)' (@((Tree $s2).workspaces | ForEach-Object { $_.sessions }).Count -eq 3)

    "== the file, after the restart's own save =="
    $lines2 = StateLines $s.AppDir
    $lines2 | ForEach-Object { "  $_" }
    Check 'the C line is re-written' (@($lines2 | Where-Object { $_ -like "C`t*`treviewing the P3 diff" }).Count -eq 1)
    Check 'both K lines are re-written with the same fields' ((@($lines2 | Where-Object { $_ -match "^K`t\d+`t`t[^`t]*$markerRx$" }).Count -eq 1) -and (@($lines2 | Where-Object { $_ -match "^K`t\d+`t[^`t]*$markerRx`t$" }).Count -eq 1))
    $log = Get-Content (Join-Path $s.AppDir "agliteterm\agliteterm-$pipe.log") -Raw
    Check 'the log names the restore of the context and the slots' ($log -match 'context' -and $log -match 'capture')
    "  log lines: " + (($log -split "`n" | Where-Object { $_ -match 'context|capture' }) -join "`n  log lines: ")
}
finally {
    if ($p2 -and -not $p2.HasExited) { $p2.CloseMainWindow() | Out-Null; Start-Sleep 3 }
    if ($p2 -and -not $p2.HasExited) { Stop-Process -Id $p2.Id -Force }
    if (-not $s.Proc.HasExited) { Stop-Process -Id $s.Proc.Id -Force }
    Stop-Markers
    Remove-Item $s.AppDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { "persistence-restart: $fail FAILED"; exit 1 }
"persistence-restart: all passed"
exit 0
