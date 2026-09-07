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

# Stop a process this suite owns (a proven row), by pid, best effort; prints what it did.
function Stop-OwnedRow($row, [string]$why) {
    "        (stopping $why pid $($row.ProcessId): $($row.CommandLine))"
    Stop-Process -Id $row.ProcessId -Force -ErrorAction SilentlyContinue
}
