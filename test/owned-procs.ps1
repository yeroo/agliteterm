# Ownership proofs for process teardown, shared by the suites that stop anything they did not get
# back from Start-Process.
#
# A suite may stop only a process it can PROVE it created: one it started itself (a Process object,
# whose pid it holds), a pane shell that ANSWERED its own pid on the screen of a window the suite
# started (the ledger below), or a descendant of one of those, proven hop by hop through Win32_Process.ParentProcessId
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
    $t = @{ Pid = [int]$row.ProcessId; ParentPid = [int]$row.ParentProcessId; Born = $row.CreationDate; CommandLine = $row.CommandLine; Proc = (Open-Owned $row); Gone = [datetime]::MaxValue }
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
# ONE per machine, spawned by the first window that needed it and SHARED by every window after -
# the user's own, a peer's sandbox) to start the shell over ConPTY. So the host's children are not
# a proof of anything: a second window opened mid-run has its shells under the same host, and a
# walk window -> host -> shell would claim them (Codex's read of #49, 2026-09-08). What proves a
# shell the suite's own is the shell itself: the suite types `AGWSHELL=$PID` into the pane over the
# sandbox's own control pipe and reads the answer back off that pane's screen (Register-PaneShell).
# A pid that came out of a pane of a window this run started is that pane's shell, whatever process
# started it; the ledger pins it there and then (New-Tracked), and from that shell on the chain is
# proven hop by hop as before - a ping is a PING.EXE child of a tracked shell, born after it and
# before it exited. A shell that was never registered (a second window's, a peer's) has no record,
# and nothing under it is ever the suite's. The proof has to be taken WHILE the chain is alive: a
# graceful close kills the shell and orphans the ping, which from then on names a dead pid that
# nothing can vouch for - so a shell is registered before anything is typed into it, and the
# ledger walks shell -> ping each time it is asked, remembering every ping as a New-Tracked record
# (a pinned handle, whose exit time keeps bounding the record after the process is gone). A ping
# the ledger never saw alive under a shell of ours - a leftover of an aborted run, a peer's sandbox
# typing the same marker, the user's own window - is reported and left running; Stop-OwnedPings
# stops only what the ledger holds, and through the handle it holds. The marker (`-n 311 127.0.0.1`)
# tells the suite's pings apart from each other; it is never the proof that one is the suite's.
$script:ledgerWindows = @()     # the Process objects a suite started, pinned (their teardown goes through these)
$script:ledgerShells  = @{}     # "pid|birth" -> tracked shell that answered $PID in a pane of ours
$script:ledgerPings   = @{}     # "pid|birth" -> tracked PING.EXE child of a tracked shell

function Register-OwnedWindow($proc) { if ($proc) { Pin-Owned $proc; $script:ledgerWindows += $proc } }

# Keyed by pid AND birth: a dead hop's pid comes back on something else, and that something must
# get its own record, not be mistaken for the record whose pid it inherited.
function Ledger-Key($row) { "$($row.ProcessId)|$($row.CreationDate.Ticks)" }

# The line a pane's shell prints when asked for its pid, and the pid read back off the screen: the
# answer line only (`AGWSHELL=` followed by digits to the end of the line), never the echo of the
# command that asked, which carries `$PID` unexpanded. $null when the screen does not show one yet.
$script:shellPidProbe = "[Console]::Out.WriteLine('AGWSHELL=' + `$PID)`n"
function Find-ShellPid([string]$text) {
    $m = [regex]::Matches($text, '(?m)^AGWSHELL=(\d+)\s*$')
    if ($m.Count) { [int]$m[$m.Count - 1].Groups[1].Value } else { $null }
}

# Track a shell by the pid it answered in a pane of ours. The row must be alive now: a pid the pane
# printed a moment ago and that is gone already is not a shell anything can be typed into.
function Register-OwnedShell([int]$ShellPid) {
    $row = Get-ProcRow $ShellPid
    if (-not $row) { throw "the pane answered shell pid $ShellPid, which is not running" }
    $k = Ledger-Key $row
    if (-not $script:ledgerShells.ContainsKey($k)) { $script:ledgerShells[$k] = New-Tracked $row }
    if (-not (Tracked-Alive $script:ledgerShells[$k])) { throw "shell pid $ShellPid could not be pinned; nothing typed into it can be proven" }
    $k
}

# Ask a pane for its shell's pid and register it: $Type types one string into the pane, $Text reads
# the pane's screen back (both over the sandbox's own control pipe - that is what makes the answer
# the suite's). Throws, naming the screen, when no answer shows within $ms.
function Register-PaneShell([scriptblock]$Type, [scriptblock]$Text, [int]$ms = 8000) {
    & $Type $script:shellPidProbe
    $seen = ''
    for ($k = 0; $k -lt ($ms / 200); $k++) {
        $seen = [string](& $Text)
        $shellPid = Find-ShellPid $seen
        if ($shellPid) { return (Register-OwnedShell $shellPid) }
        Start-Sleep -Milliseconds 200
    }
    throw "the pane never answered AGWSHELL=<pid> within $ms ms; its screen: $seen"
}

# One walk shell -> ping over a single process snapshot; every ping not yet on the ledger is tracked
# now, while it can still be pinned. Cheap enough to call from a 200 ms poll.
function Update-OwnedLedger {
    $all = @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'")
    foreach ($sh in @($script:ledgerShells.Values)) {
        $exit = Tracked-Exit $sh
        foreach ($g in @($all | Where-Object { [int]$_.ParentProcessId -eq $sh.Pid -and $_.CreationDate -gt $sh.Born -and $_.CreationDate -lt $exit })) {
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

# Every ping the ledger holds, whatever its marker: a teardown that runs after a throw does not know
# which markers the block got as far as typing. Only the ledger's, only through their handles.
function Stop-AllOwnedPings {
    Update-OwnedLedger
    foreach ($t in @($script:ledgerPings.Values | Where-Object { Tracked-Alive $_ })) {
        "        (stopping owned ping pid $($t.Pid): $($t.CommandLine))"
        try { $t.Proc.Kill(); [void]$t.Proc.WaitForExit(3000) } catch { "        (could not stop pid $($t.Pid): $($_.Exception.Message))" }
    }
}
