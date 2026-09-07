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
