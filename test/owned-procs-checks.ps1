# Pure checks of the ownership ledger in test/owned-procs.ps1: no window, no pipe, no suite token.
# They drive the ledger's functions with mocks that stand in for a pane (what gets typed, what the
# screen shows) and for a process handle (a Kill that throws, a wait that runs out), and with this
# very pwsh as the "shell" whose identity is on the line. The live suites prove the same functions
# against a real pane; these prove the boundaries a live run cannot reach on purpose: a stale answer
# on the screen, a reused pid, a stop that did not happen (Codex's read of #49, 2026-09-08).
param(
    [string]$Exe = '',   # accepted for run-all.ps1's sake; nothing here runs a build
    [switch]$Strict
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\owned-procs.ps1"

$script:fail = 0
function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { "  PASS  $name" } else { $script:fail++; "  FAIL  $name"; if ($detail) { "        $detail" } }
}

"== owned-procs checks (pure: no window, no token) =="

# --- A fresh challenge, answered or not -----------------------------------------------------------
# The screen a pane might show: an answer to some EARLIER challenge (a restored screen, a probe typed
# twice), a prompt, and the echo of whatever was just typed - which carries `$PID` unexpanded.
$stale = "AGWSHELL-deadbeef=77777|123456789|END`nPS C:\> "

# (a) an old answer is not an answer: the pane never printed this call's nonce.
$script:typed = @()
$threw = ''
try { Ask-PaneShell { param($t) $script:typed += $t } { $stale + $script:typed[0] } 600 | Out-Null } catch { $threw = $_.Exception.Message }
Check 'an old AGWSHELL answer on the screen is not an answer to this call''s challenge' ($threw -match 'never answered AGWSHELL-[0-9a-f]{8}=') "threw: '$threw'"
Check 'and the challenge was typed once, with a nonce of its own (not the old line''s)' ($script:typed.Count -eq 1 -and $script:typed[0] -match 'AGWSHELL-([0-9a-f]{8})=' -and $Matches[1] -ne 'deadbeef') "typed: $($script:typed -join ' / ')"
Check 'and the echo of the typed challenge on the screen did not pass for an answer' ($script:typed[0] -match '\$PID' -and -not (Find-ShellAnswer ($stale + $script:typed[0]) $Matches[1]))

# (b) a fresh answer that shows up late is taken - and it is the fresh one, not the old line above it.
$script:typed = @(); $script:reads = 0
$a = Ask-PaneShell { param($t) $script:typed += $t } {
    $script:reads++
    $n = if ($script:typed[0] -match 'AGWSHELL-([0-9a-f]{8})=') { $Matches[1] } else { 'none' }
    if ($script:reads -lt 3) { $stale + $script:typed[0] } else { $stale + $script:typed[0] + "`nAGWSHELL-$n=4242|999|END`nPS C:\> " }
} 3000
Check 'a fresh answer that arrives on the third read is taken, with ITS pid and birth' ($a.Pid -eq 4242 -and $a.BornUtcTicks -eq 999 -and $script:reads -eq 3) "pid $($a.Pid) born $($a.BornUtcTicks) after $($script:reads) reads"

# (c) the screen is rows: a narrow pane wraps the answer (CI's 36-column sandbox cut the birth at
# its 13th digit and the first row passed for the whole - the 5bab9f2 CI red). The first row alone is
# not an answer; the two rows together, wherever the wrap fell, are.
$wrapped = "AGWSHELL-cafe0001=6916|6392444783830   `n49130|END   `nPS C:\> "
Check 'the first row of a wrapped answer, its birth cut short, is not an answer' (-not (Find-ShellAnswer 'AGWSHELL-cafe0001=6916|6392444783830' 'cafe0001'))
$a = Find-ShellAnswer $wrapped 'cafe0001'
Check 'the wrapped answer is read whole: pid and the full 18-digit birth' ($a.Pid -eq 6916 -and $a.BornUtcTicks -eq 639244478383049130L) "pid $($a.Pid) born $($a.BornUtcTicks)"
$a = Find-ShellAnswer "AGWSH`nELL-cafe0001=69`n16|63924447838304913`n0|E`nND" 'cafe0001'
Check 'a wrap that fell inside the marker, the pid, the birth and the end still reads whole' ($a.Pid -eq 6916 -and $a.BornUtcTicks -eq 639244478383049130L) "pid $($a.Pid) born $($a.BornUtcTicks)"

# --- The identity behind the answer ---------------------------------------------------------------
# This pwsh is the shell: its pid is running, and its start time is what a real answer would carry.
$me = Get-Process -Id $PID; Pin-Owned $me
$born = $me.StartTime.ToUniversalTime().Ticks

$script:ledgerShells = @{}
$k = Register-OwnedShell $PID $born
Check 'a pid whose process was born when the answer says is admitted' ($script:ledgerShells.Count -eq 1 -and $script:ledgerShells[$k].Pid -eq $PID) "key $k"

$script:ledgerShells = @{}
$threw = ''
try { Register-OwnedShell $PID ($born - 50000000) | Out-Null } catch { $threw = $_.Exception.Message }
Check 'the same pid with a birth 5 s off is refused as a reused pid, and nothing is admitted' ($threw -match 'reused pid' -and $script:ledgerShells.Count -eq 0) "threw: '$threw'"

# Exactness: the answer carries the kernel time to the tick, so one millisecond - or one tick - off
# is not this process (Codex's read of 5bab9f2: a 100 ms tolerance admitted a birth 1 ms wrong).
foreach ($off in @(@(10000, '1 ms'), @(1, '1 tick'))) {
    $threw = ''
    try { Register-OwnedShell $PID ($born - $off[0]) | Out-Null } catch { $threw = $_.Exception.Message }
    Check "the same pid with a birth $($off[1]) off is refused as a reused pid, and nothing is admitted" ($threw -match 'reused pid' -and $script:ledgerShells.Count -eq 0) "threw: '$threw'"
}

# The row and the handle: CIM says a birth to the microsecond, the handle to the tick. A row cut to
# the microsecond is this process; a row one microsecond earlier, or one millisecond off, is not.
function Fake-Row([long]$utcTicks) {
    [pscustomobject]@{ ProcessId = $PID; ParentProcessId = 1; CreationDate = [datetime]::new($utcTicks, [DateTimeKind]::Utc).ToLocalTime(); CommandLine = 'this pwsh' }
}
$cut = $born - ($born % 10)
$real = Get-ProcRow $PID
$realBorn = $real.CreationDate.ToUniversalTime().Ticks
Check 'the real CIM row of this process is its StartTime cut to the microsecond (0..9 ticks under it)' (($born - $realBorn) -ge 0 -and ($born - $realBorn) -le 9 -and $realBorn -eq $cut) "handle $born, row $realBorn"
Check 'a row carrying the birth cut to the microsecond opens this process' ([bool](Open-Owned (Fake-Row $cut)))
Check 'a row one microsecond earlier does not open it: not the same process' (-not (Open-Owned (Fake-Row ($cut - 10))))
Check 'a row one millisecond off does not open it either' (-not (Open-Owned (Fake-Row ($born + 10000))))

# The handle's identity is what is compared with the answer, not the row's: a row that is not the
# pinned process cannot be admitted even when the answer repeats that row's own birth.
$script:ledgerShells = @{}
$realGetProcRow = ${function:Get-ProcRow}
${function:Get-ProcRow} = { param([int]$ProcId) Fake-Row ($born + 10000) }
$threw = ''
try { Register-OwnedShell $PID ($born + 10000) | Out-Null } catch { $threw = $_.Exception.Message }
${function:Get-ProcRow} = $realGetProcRow
Check 'a snapshot row 1 ms off the pinned handle is refused even when the answer repeats that row''s birth' ($threw -match 'could not be pinned' -and $script:ledgerShells.Count -eq 0) "threw: '$threw'"

$threw = ''
try { Register-OwnedShell 2147483646 $born | Out-Null } catch { $threw = $_.Exception.Message }
Check 'a pid that is not running is refused' ($threw -match 'not running') "threw: '$threw'"

# End to end: the pane answers with THIS process's identity, and the ledger holds this process.
$script:ledgerShells = @{}; $script:typed = @()
$k = Register-PaneShell { param($t) $script:typed += $t } {
    $n = if ($script:typed[0] -match 'AGWSHELL-([0-9a-f]{8})=') { $Matches[1] } else { 'none' }
    $stale + $script:typed[0] + "`nAGWSHELL-$n=$PID|$born|END`nPS C:\> "
} 2000
Check 'Register-PaneShell admits the process that answered its own challenge, pinned' ($script:ledgerShells.Count -eq 1 -and (Tracked-Alive $script:ledgerShells[$k]) -and $script:ledgerShells[$k].Pid -eq $PID) "key $k"

# --- A stop that did not happen is a failure, not a note ------------------------------------------
# A stand-in for a pinned handle: the flags say how it misbehaves.
function New-FakeProc([bool]$killThrows, [bool]$exitsOnKill, [bool]$waitReturns) {
    $o = [pscustomobject]@{ HasExited = $false; Kills = 0; KillThrows = $killThrows; ExitsOnKill = $exitsOnKill; WaitReturns = $waitReturns }
    $o | Add-Member ScriptMethod Kill { $this.Kills++; if ($this.ExitsOnKill) { $this.HasExited = $true }; if ($this.KillThrows) { throw 'Access is denied' } }
    $o | Add-Member ScriptMethod WaitForExit { param($ms) $this.WaitReturns }
    $o
}
function Plant-FakePing($proc) {
    $script:ledgerShells = @{}
    $script:ledgerPings = @{ '424242|1' = @{ Pid = 424242; ParentPid = 1; Born = (Get-Date); CommandLine = 'fake PING.EXE -n 399 127.0.0.1'; Proc = $proc; Gone = [datetime]::MaxValue } }
    [void](Take-TeardownFailures)
}

$f = New-FakeProc $true $false $false
Plant-FakePing $f
$out = @(Stop-AllOwnedPings)
$tf = @(Take-TeardownFailures)
Check 'Kill throws on a live process: Stop-AllOwnedPings returns, and the failure is on the record' ($tf.Count -eq 1 -and $tf[0] -match 'pid 424242' -and $tf[0] -match 'Kill threw' -and $tf[0] -match 'denied') "record: $($tf -join ' / ')"
Check 'and the output line says TEARDOWN INCOMPLETE' (($out -join "`n") -match 'TEARDOWN INCOMPLETE: ping pid 424242') "out: $($out -join ' / ')"

$f = New-FakeProc $false $false $false
Plant-FakePing $f
[void](Stop-AllOwnedPings)
$tf = @(Take-TeardownFailures)
Check 'Kill returns but the wait runs out and the process is still there: a recorded failure' ($f.Kills -eq 1 -and $tf.Count -eq 1 -and $tf[0] -match 'still alive after the stop') "record: $($tf -join ' / ')"

$f = New-FakeProc $false $true $true
Plant-FakePing $f
[void](Stop-AllOwnedPings)
$tf = @(Take-TeardownFailures)
Check 'a stop that worked records nothing' ($f.Kills -eq 1 -and $tf.Count -eq 0) "record: $($tf -join ' / ')"

$f = New-FakeProc $true $true $true
Plant-FakePing $f
[void](Stop-AllOwnedPings)
$tf = @(Take-TeardownFailures)
Check 'Kill throws on a process that had just exited (the race): not a failure' ($f.Kills -eq 1 -and $tf.Count -eq 0) "record: $($tf -join ' / ')"

Check 'Take-TeardownFailures hands the record over once: the second take is empty' (@(Take-TeardownFailures).Count -eq 0)

# The ledger walk itself dies (the process snapshot cannot be taken): recorded, and what the ledger
# already holds is still stopped - by both stop helpers, and neither throws.
$f = New-FakeProc $false $true $true
Plant-FakePing $f
function Get-CimInstance { throw 'CIM is down' }
$threw = ''
try { $out = @(Stop-AllOwnedPings) } catch { $threw = $_.Exception.Message }
$tf = @(Take-TeardownFailures)
Check 'enumeration throws: Stop-AllOwnedPings does not, records it, and still stops what the ledger held' (-not $threw -and $f.Kills -eq 1 -and $tf.Count -eq 1 -and $tf[0] -match 'could not walk' -and $tf[0] -match 'CIM is down') "threw: '$threw'; record: $($tf -join ' / ')"
$f = New-FakeProc $false $true $true
Plant-FakePing $f
$threw = ''
try { $out = @(Stop-OwnedPings '399') } catch { $threw = $_.Exception.Message }
$tf = @(Take-TeardownFailures)
Check 'enumeration throws: Stop-OwnedPings does not either, stops the marker''s ping, and says it could not list foreign pings' (-not $threw -and $f.Kills -eq 1 -and $tf.Count -eq 1 -and (($out -join "`n") -match 'could not list foreign pings')) "threw: '$threw'; out: $($out -join ' / ')"
Remove-Item Function:Get-CimInstance
$script:ledgerPings = @{}; $script:ledgerShells = @{}

if ($script:fail) { "owned-procs-checks: $($script:fail) failed"; exit 1 }
"owned-procs-checks: all passed"
exit 0
