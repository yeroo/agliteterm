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

# A birth as CIM can say it: CIM keeps a creation time to the microsecond, a handle's StartTime to
# 100 ns, and WMI truncates (on this box handle - CIM is uniformly 0..9 ticks over every process).
# Cut to the microsecond the two name the same kernel time or they do not; there is no other
# tolerance - a birth one millisecond off is another process.
function UtcMicroTicks([datetime]$t) { $x = $t.ToUniversalTime().Ticks; $x - ($x % 10) }

# Open the process a proven row describes and check it is still THAT process: the handle's own
# StartTime must be the row's CreationDate, to the microsecond CIM carries (a reused pid is off by
# the life of the original). $null when it is gone or reused - it is not ours to touch.
function Open-Owned($row) {
    $p = Get-Process -Id ([int]$row.ProcessId) -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    try { Pin-Owned $p; $born = $p.StartTime } catch { return $null }
    if ((UtcMicroTicks $born) -ne (UtcMicroTicks $row.CreationDate)) { return $null }
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
# shell the suite's own is the shell itself: the suite types a FRESH challenge (a nonce this call
# made up) into the pane over the sandbox's own control pipe and reads back, off that pane's
# screen, the one line that answers THAT nonce with the shell's own pid AND its own start time
# (Ask-PaneShell). An answer to any earlier challenge - a screen restored from a previous run, a
# probe typed twice - names no nonce of this call and is not an answer; and the start time is what
# ties the pid to one process: the ledger admits the pid only if the process running under it now
# was born when the answer said (Register-OwnedShell), so a pid Windows reused since cannot be
# admitted on the strength of a line an earlier owner of it printed. A pid that came out of a pane
# of a window this run started, checked so, is that pane's shell, whatever process started it; the
# ledger pins it there and then (New-Tracked), and from that shell on the chain is
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
#
# A stop that did not happen is a FAILURE of the suite, not a note in its output: a kill that threw,
# a process still alive after the wait, a ledger walk that could not enumerate - each is recorded
# (Teardown-Failed) and the suite's verdict reads the record (Take-TeardownFailures) before it says
# PASS or "all passed". The stop helpers never throw: a teardown stage that dies must not take the
# stages after it (the sandbox, the registry) down with it, so they catch, record, and go on.
$script:ledgerWindows = @()     # the Process objects a suite started, pinned (their teardown goes through these)
$script:ledgerShells  = @{}     # "pid|birth" -> tracked shell that answered $PID in a pane of ours
$script:ledgerPings   = @{}     # "pid|birth" -> tracked PING.EXE child of a tracked shell

function Register-OwnedWindow($proc) { if ($proc) { Pin-Owned $proc; $script:ledgerWindows += $proc } }

# Keyed by pid AND birth: a dead hop's pid comes back on something else, and that something must
# get its own record, not be mistaken for the record whose pid it inherited.
function Ledger-Key($row) { "$($row.ProcessId)|$($row.CreationDate.Ticks)" }

# Teardown failures: what a stop helper could not do. Recorded, never thrown (a throw would skip
# the cleanup after it); the suite takes the record into its verdict. A stop helper that returns
# normally has therefore NOT necessarily stopped everything - the record says.
$script:teardownFailures = @()
function Teardown-Failed([string]$what) {
    $script:teardownFailures += $what
    "        TEARDOWN INCOMPLETE: $what"
}
# The failures recorded since the last take, and a clean slate for the next cell.
function Take-TeardownFailures { $f = @($script:teardownFailures); $script:teardownFailures = @(); $f }

# A fresh challenge each time, and the line the pane's shell prints to answer it: the nonce, its own
# pid, and its own start time (UTC ticks - the kernel's creation time of THAT process, which a reused
# pid does not inherit). The echo of the typed command carries `$PID` unexpanded and never matches
# the answer's shape (digits right after `=`); an answer to another nonce is not this call's.
function New-ShellNonce { -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
function Shell-Challenge([string]$nonce) {
    "[Console]::Out.WriteLine('AGWSHELL-$nonce=' + `$PID + '|' + (Get-Process -Id `$PID).StartTime.ToUniversalTime().Ticks)`n"
}
function Find-ShellAnswer([string]$text, [string]$nonce) {
    $m = [regex]::Matches($text, "(?m)^AGWSHELL-$nonce=(\d+)\|(\d+)\s*$")
    if ($m.Count) { @{ Pid = [int]$m[$m.Count - 1].Groups[1].Value; BornUtcTicks = [long]$m[$m.Count - 1].Groups[2].Value } } else { $null }
}

# Ask a pane for its shell's identity: $Type types one string into the pane, $Text reads the pane's
# screen back (both over the sandbox's own control pipe - that is what makes the answer the
# suite's). Returns @{ Pid; BornUtcTicks } - the answer to THIS call's nonce, nothing older - or
# throws, naming the screen, when none shows within $ms. Registers nothing: the identity is a fact
# about the pane; vouching for it is Register-OwnedShell.
function Ask-PaneShell([scriptblock]$Type, [scriptblock]$Text, [int]$ms = 8000) {
    $nonce = New-ShellNonce
    & $Type (Shell-Challenge $nonce)
    $seen = ''
    for ($k = 0; $k -lt ($ms / 200); $k++) {
        $seen = [string](& $Text)
        $a = Find-ShellAnswer $seen $nonce
        if ($a) { return $a }
        Start-Sleep -Milliseconds 200
    }
    throw "the pane never answered AGWSHELL-$nonce=<pid>|<born> within $ms ms; its screen: $seen"
}

# Track a shell by the identity its pane answered: the pid must be running NOW, pinned as the
# process the snapshot described (Open-Owned), and the PINNED handle's own StartTime must be the
# very ticks the answer carried - the shell read that value from the same kernel time through the
# same API, so it is equal or the pid has been reused and the answer was another process's. Nothing
# is admitted before that holds. Returns the ledger key.
function Register-OwnedShell([int]$ShellPid, [long]$BornUtcTicks) {
    $row = Get-ProcRow $ShellPid
    if (-not $row) { throw "the pane answered shell pid $ShellPid, which is not running" }
    $k = Ledger-Key $row
    $t = if ($script:ledgerShells.ContainsKey($k)) { $script:ledgerShells[$k] } else { New-Tracked $row }
    if (-not (Tracked-Alive $t)) { throw "shell pid $ShellPid could not be pinned as the process the snapshot described; nothing typed into it can be proven" }
    $handleBorn = $t.Proc.StartTime.ToUniversalTime().Ticks
    if ($handleBorn -ne $BornUtcTicks) {
        throw "the pane answered shell pid $ShellPid born at $BornUtcTicks, but the process pinned under pid $ShellPid was born at ${handleBorn}: a reused pid, not the shell that answered"
    }
    $script:ledgerShells[$k] = $t
    $k
}

# Ask and vouch in one step: the identity the pane answers this call's challenge with, registered.
function Register-PaneShell([scriptblock]$Type, [scriptblock]$Text, [int]$ms = 8000) {
    $a = Ask-PaneShell $Type $Text $ms
    Register-OwnedShell $a.Pid $a.BornUtcTicks
}

# One walk shell -> ping over a single process snapshot; every ping not yet on the ledger is tracked
# now, while it can still be pinned. Cheap enough to call from a 200 ms poll. Throws when the
# snapshot cannot be taken; the stop helpers catch that and record it.
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

# Stop one tracked ping through the handle that was checked when it was tracked, and wait for it to
# go. Anything short of "gone" is a recorded failure: a Kill that threw on a live process, a wait
# that ran out, a process still there afterwards.
function Stop-TrackedPing($t) {
    "        (stopping owned ping pid $($t.Pid): $($t.CommandLine))"
    try { $t.Proc.Kill() } catch { if (-not $t.Proc.HasExited) { Teardown-Failed "ping pid $($t.Pid): Kill threw: $($_.Exception.Message)"; return } }
    $waited = $false
    try { $waited = [bool]$t.Proc.WaitForExit(3000) } catch { Teardown-Failed "ping pid $($t.Pid): WaitForExit threw: $($_.Exception.Message)"; return }
    if (-not $waited -or -not $t.Proc.HasExited) { Teardown-Failed "ping pid $($t.Pid) is still alive after the stop" }
}

# Walk the ledger without throwing: a snapshot that cannot be taken is recorded, and what the ledger
# already holds is still stopped.
function Update-OwnedLedgerOrRecord {
    try { Update-OwnedLedger } catch { Teardown-Failed "could not walk the ledger's shells for their pings: $($_.Exception.Message)" }
}

# Stop the ledger's pings with a marker, each through its own handle. Then say what carried the
# marker and was left alone. Never throws; failures are on the record.
function Stop-OwnedPings([string]$n) {
    Update-OwnedLedgerOrRecord
    foreach ($t in @($script:ledgerPings.Values | Where-Object { $_.CommandLine -match "-n $n 127\.0\.0\.1" -and (Tracked-Alive $_) })) { Stop-TrackedPing $t }
    try { foreach ($line in Describe-ForeignPings $n) { "        (NOT stopping $line)" } } catch { "        (could not list foreign pings: $($_.Exception.Message))" }
}

# Every ping the ledger holds, whatever its marker: a teardown that runs after a throw does not know
# which markers the block got as far as typing. Only the ledger's, only through their handles.
# Never throws; failures are on the record.
function Stop-AllOwnedPings {
    Update-OwnedLedgerOrRecord
    foreach ($t in @($script:ledgerPings.Values | Where-Object { Tracked-Alive $_ })) { Stop-TrackedPing $t }
}
