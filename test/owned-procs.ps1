# Ownership proofs for process teardown, shared by the suites that stop anything they did not get
# back from Start-Process.
#
# A suite may stop only a process it can PROVE it created: one it started itself (a Process object,
# whose pid it holds) or a descendant of one, proven hop by hop through Win32_Process.ParentProcessId
# with birth order - a child is born AFTER the parent it names, and (when the parent's exit is known)
# before that parent exited. Windows reuses pids, so a bare ParentProcessId match is a claim, not a
# proof; the birth bounds are what close it.
#
# What is NOT a proof: the exe name, its path, the command line (`--pipe rm-restart-named`), or "it
# appeared after my snapshot". Another agent running this same suite from its own worktree, or the
# user's own window, matches all four - and a machine-wide sweep on them killed a peer's sandbox
# mid-suite on 2026-09-07. Anything the proof does not cover is reported and left running;
# desktop-wide exclusivity between agents is the hub's suite token, not a kill list.
#
# Two things a pid alone never gives, and the helpers below do:
#  - the parent's EXIT bound. A relay cmd.exe lives a second; its pid can be reused by anything the
#    machine starts next, and a window that names the REUSED pid as its parent was born after the
#    relay died. Only a handle held on the relay while it lived knows when that was (Exit-Of).
#  - the kill through the handle that was checked. A proven row can go stale between the query and
#    the stop - the process exits, the pid is reused - so Stop-OwnedRow opens the pid, checks that the
#    handle's own birth is the row's, and terminates THAT handle; it never re-opens by pid to kill.

# The live Win32_Process row of one pid (nothing once it has exited).
function Get-ProcRow([int]$ProcId) { Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" }

# The live children of a process, proven: they name it as parent AND were born after it. When the
# parent's exit time is known, born before that too - a child that names a dead pid it cannot have
# had as a parent is a reused pid. $Name narrows to one image name (e.g. 'cmd.exe').
function Get-OwnedChildren([int]$ParentPid, [datetime]$ParentBorn, [string]$Name = '', [datetime]$ParentExit = [datetime]::MaxValue) {
    $f = "ParentProcessId=$ParentPid"
    if ($Name) { $f += " AND Name='$Name'" }
    @(Get-CimInstance Win32_Process -Filter $f | Where-Object { $_.CreationDate -gt $ParentBorn -and $_.CreationDate -lt $ParentExit })
}

# Hold a handle on a Process object for the rest of its life. A Get-Process object opens and closes
# a handle per call - by pid, so each call could land on a different process; touching SafeHandle
# makes it keep one, and from then on StartTime, HasExited, ExitTime and Kill all go through THAT
# handle, whatever the pid comes to mean. (Refresh() keeps it; Close()/Dispose() would drop it.)
function Pin-Owned($proc) { if ($proc) { [void]$proc.SafeHandle } }

# When a pinned process exited, or MaxValue while it is alive: the upper bound for its children.
function Exit-Of($proc) { if ($proc -and $proc.HasExited) { $proc.ExitTime } else { [datetime]::MaxValue } }

# Open the process a proven row describes and check it is still THAT process: the handle's own
# StartTime must be the row's CreationDate (the two agree to a millisecond; a reused pid is off by
# the life of the original). $null when it is gone or reused - it is not ours to touch.
function Open-Owned($row) {
    $p = Get-Process -Id ([int]$row.ProcessId) -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    try { Pin-Owned $p; $born = $p.StartTime } catch { return $null }
    if ([math]::Abs(($born - $row.CreationDate).TotalMilliseconds) -gt 100) { return $null }
    $p
}

# A proven row remembered past its life: pid, birth, and a pinned handle while there was one to take.
# Exit-Of the handle bounds its children; without a handle (it was gone before it could be pinned)
# the moment it was seen gone is the bound - it had exited by then, so nothing born later is its child.
function New-Tracked($row) {
    $t = @{ Pid = [int]$row.ProcessId; Born = $row.CreationDate; CommandLine = $row.CommandLine; Proc = (Open-Owned $row); Gone = [datetime]::MaxValue }
    if (-not $t.Proc) { $t.Gone = Get-Date }
    $t
}
function Tracked-Exit($t) { if ($t.Proc) { Exit-Of $t.Proc } else { $t.Gone } }
function Tracked-Alive($t) { [bool]$t.Proc -and -not $t.Proc.HasExited }

# Stop a process this suite owns (a proven row): through a handle checked against the row, or not at
# all. Prints what it did, or why it did nothing.
function Stop-OwnedRow($row, [string]$why) {
    $p = Open-Owned $row
    if (-not $p) { "        (NOT stopping $why pid $($row.ProcessId): gone, or its pid reused by a process that is not ours)"; return }
    "        (stopping $why pid $($row.ProcessId): $($row.CommandLine))"
    try { $p.Kill() } catch { "        (could not stop pid $($row.ProcessId): $($_.Exception.Message))" }
}

# --- The ledger: a foreground child typed into a pane (the capture suites' pings) -----------------
#
# A pane's shell is not the lite window's child. The window asks the pty-host (agwinterm-ptyhost.exe,
# ONE per machine, spawned by the first window that needed it) to start the shell over ConPTY, so a
# `ping` typed into a pane is proven window -> host -> shell -> ping, one Get-OwnedChildren hop each.
# The proof has to be taken WHILE the chain is alive: a graceful close kills the shell and orphans
# the ping, which from then on names a dead pid that nothing can vouch for. So a suite registers
# every window it starts (Register-OwnedWindow), and the ledger walks the chain each time it is
# asked, remembering every hop as a New-Tracked record - a pinned handle, whose exit time keeps
# bounding the next hop after the process is gone. A ping the ledger never saw alive under a shell
# of ours - a leftover of an aborted run, a peer's sandbox typing the same marker, the user's own
# window - is reported and left running; Stop-OwnedPings stops only what the ledger holds, and
# through the handle it holds. The marker (`-n 311 127.0.0.1`) tells the suite's pings apart from
# each other; it is never the proof that one is the suite's.
$script:ledgerWindows = @()     # the Process objects a suite started, pinned
$script:ledgerHosts   = @{}     # "pid|birth" -> tracked pty-host spawned by one of those windows
$script:ledgerShells  = @{}     # "pid|birth" -> tracked child of a tracked host (a pane's shell)
$script:ledgerPings   = @{}     # "pid|birth" -> tracked PING.EXE child of a tracked shell

function Register-OwnedWindow($proc) { if ($proc) { Pin-Owned $proc; $script:ledgerWindows += $proc } }

# Keyed by pid AND birth: a dead hop's pid comes back on something else, and that something must
# get its own record, not be mistaken for the record whose pid it inherited.
function Ledger-Key($row) { "$($row.ProcessId)|$($row.CreationDate.Ticks)" }

# One walk down the chain over a single process snapshot; every hop not yet on the ledger is tracked
# now, while it can still be pinned. Cheap enough to call from a 200 ms poll.
function Update-OwnedLedger {
    $all = @(Get-CimInstance Win32_Process)
    function Kids([int]$ParentPid, [datetime]$ParentBorn, [string]$Name, [datetime]$ParentExit) {
        @($all | Where-Object { [int]$_.ParentProcessId -eq $ParentPid -and (-not $Name -or $_.Name -eq $Name) -and
                               $_.CreationDate -gt $ParentBorn -and $_.CreationDate -lt $ParentExit })
    }
    foreach ($w in $script:ledgerWindows) {
        $born = try { $w.StartTime } catch { continue }
        foreach ($h in Kids $w.Id $born 'agwinterm-ptyhost.exe' (Exit-Of $w)) {
            $k = Ledger-Key $h; if (-not $script:ledgerHosts.ContainsKey($k)) { $script:ledgerHosts[$k] = New-Tracked $h }
        }
    }
    foreach ($h in @($script:ledgerHosts.Values)) {
        foreach ($c in Kids $h.Pid $h.Born '' (Tracked-Exit $h)) {
            $k = Ledger-Key $c; if (-not $script:ledgerShells.ContainsKey($k)) { $script:ledgerShells[$k] = New-Tracked $c }
        }
    }
    foreach ($sh in @($script:ledgerShells.Values)) {
        foreach ($g in Kids $sh.Pid $sh.Born 'PING.EXE' (Tracked-Exit $sh)) {
            $k = Ledger-Key $g; if (-not $script:ledgerPings.ContainsKey($k)) { $script:ledgerPings[$k] = New-Tracked $g }
        }
    }
}

# The ledger's pings that carry a marker and are still alive (tracked records: Pid, Born, Proc).
function Get-OwnedPings([string]$n) {
    Update-OwnedLedger
    @($script:ledgerPings.Values | Where-Object { $_.CommandLine -match "-n $n 127\.0\.0\.1" -and (Tracked-Alive $_) })
}

# Pings carrying the marker that the ledger cannot vouch for: one line each, for the report or the
# error that says why a cell could not find its own.
function Describe-ForeignPings([string]$n) {
    @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { $_.CommandLine -match "-n $n 127\.0\.0\.1" } |
        Where-Object { -not $script:ledgerPings.ContainsKey((Ledger-Key $_)) } |
        ForEach-Object { "ping pid $($_.ProcessId) (parent pid $($_.ParentProcessId), born $($_.CreationDate.ToString('HH:mm:ss.fff'))) carries -n $n but is not under a shell this run can prove its own" })
}

# Stop the ledger's pings with a marker, each through the handle that was checked when it was
# tracked; wait for each to go. Then say what carried the marker and was left alone.
function Stop-OwnedPings([string]$n) {
    foreach ($t in Get-OwnedPings $n) {
        "        (stopping owned ping pid $($t.Pid): $($t.CommandLine))"
        try { $t.Proc.Kill(); [void]$t.Proc.WaitForExit(3000) } catch { "        (could not stop pid $($t.Pid): $($_.Exception.Message))" }
    }
    foreach ($line in Describe-ForeignPings $n) { "        (NOT stopping $line)" }
}
