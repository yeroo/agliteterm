# Control API — the read-only trio (P1-lite): `surface.cursor`, `statusChangedAt` on every `tree`
# node, and a truthful `ping` (which is what `agwintermctl version` reports as the app).
#
# Every case here checks that the NUMBER IS RIGHT, not merely well-shaped. A cursor column that is
# always 0 passes a shape test and breaks the caller in exactly the way the verb exists to prevent:
# an agent asks "is that composer empty before I type into it", and the caret column is its answer.
# Shape is pinned as well (test/conformance.ps1 does the cross-product half), because the
# bare-integer reply is the contract agwinterm and agterm share.
#
# Driven through the REAL agwintermctl against a sandbox instance, under test/ui-lib.ps1's rules:
# --pipe <name>, a throwaway %LOCALAPPDATA%, nothing injected globally. `surface cursor` reached the
# CLI in agwinterm #221; an older client refuses the verb locally, before any pipe is opened, and
# this check says so and skips (fails under -Strict) rather than reporting the app broken.
param(
    [string]$Exe = "$PSScriptRoot\..\bin\agliteterm.exe",
    # CI passes -Strict: a suite that skips is reporting success while checking nothing.
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "  PASS  $name" }
    else { $script:fail++; "  FAIL  $name$(if ($detail) { " — $detail" })" }
}

"== control-read =="

. "$PSScriptRoot\ui-lib.ps1"
$ctl = Get-CtlPath
if (-not $ctl) { "  SKIP  agwintermctl not found (set AGWINTERMCTL)"; exit ($Strict ? 1 : 0) }
$exe = Resolve-Lite $Exe
if (-not $exe) { "  SKIP  no build at $Exe"; exit ($Strict ? 1 : 0) }
"  using: $ctl"
# The client refuses a verb it does not know on its own side, so this probe never needs a pipe.
$probe = (& $ctl surface cursor --pipe 'ctlread-probe' --json 2>&1) -join ''
if ($probe -match "unknown command 'surface cursor'") {
    "  SKIP  this agwintermctl predates agwinterm #221 and has no 'surface cursor' - set AGWINTERMCTL to a newer build"
    exit ($Strict ? 1 : 0)
}

$s = $null
function Tree { (ConvertFrom-Json (Send-Ctl $s @('tree'))).result }
function Nodes { Tree | ForEach-Object workspaces | ForEach-Object sessions }
function Node([string]$id) { Nodes | Where-Object { $_.id -eq $id } }
function CursorRaw([string]$t) { Send-Ctl $s @('surface', 'cursor', '--target', $t) }
# Through the parser, and as a number: an [int] cast on a string "7" would also give 7, which is
# exactly the wrong thing to hide, so the type is asserted separately below and never coerced here.
function Col([string]$t) {
    $r = ConvertFrom-Json (CursorRaw $t)
    if (-not $r.ok) { throw "surface cursor --target $t refused: $($r.error)" }
    return $r.result
}
function IsInteger($v) { ($v -is [long] -or $v -is [int]) -and $v -isnot [string] }
function Text([string]$t) { [string](Get-PaneText $s $t) }
function LastLine([string]$t) {
    $lines = @((Text $t) -split "`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count) { return $lines[-1] } else { return '' }
}
# A column caught mid-repaint is a race in the check, not a bug in the verb: wait for the shell's
# prompt to be on screen before reading anything. "On screen" is judged by the screen SETTLING,
# not by what the prompt looks like — the sandbox runs the machine's real profile, and a prompt
# theme that ends in '#' on its own line is as valid as 'PS ...>'.
function Wait-Prompt([string]$t) {
    $prev = ''; $same = 0
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $now = (Text $t).Trim()
        if ($now -ne '' -and $now -eq $prev) { if (++$same -ge 3) { return $true } } else { $same = 0 }
        $prev = $now
    }
    return $false
}
function NewSession([string]$name) { [string](ConvertFrom-Json (Send-Ctl $s @('session', 'new', '--name', $name))).result }

try {
    $s = Start-Sandbox -Exe $exe -Ctl $ctl -Pipe 'ctlread'
    $sid = [string](Nodes | Select-Object -First 1).id
    if (-not $sid) { throw 'the sandbox has no session' }
    Check 'the first session reaches a prompt' (Wait-Prompt $sid) "screen: $(Text $sid)"

    # --- ping names the build that is running, and version repeats it ---------------------------
    # `agwintermctl version` (agwinterm #221) reports the app serving the pipe FROM ping's reply.
    # lite used to answer a hard-coded "agliteterm 0.1" whatever was running, so `version` would
    # have named a build that does not exist. The truth is the installer's AppVersion: build.ps1
    # compiles exactly that string in, so the check reads it from the same place rather than
    # trusting the exe about itself. (Start-Sandbox does not pass AGWINTERM_VERSION_OVERRIDE, the
    # updater's test seam, so the sandbox reports its compiled version.)
    $iss = Join-Path (Split-Path $PSScriptRoot -Parent) 'installer\agliteterm.iss'
    $m = Select-String -Path $iss -Pattern '#define AppVersion "([^"]+)"'
    $appVer = if ($m) { $m.Matches[0].Groups[1].Value } else { '' }
    Check 'the installer script names a version' ([bool]$appVer) "no AppVersion in $iss"
    $raw = Send-Ctl $s @('ping')
    $r = ConvertFrom-Json $raw
    $ping = [string]$r.result
    Check 'ping answers ok with a string' ([bool]$r.ok -and $r.result -is [string]) "raw: $raw"
    Check 'ping names the product' ($ping -match '^agliteterm ') "got [$ping]"
    Check 'ping names the version the build printed, not a literal' ($ping -eq "agliteterm $appVer") "expected [agliteterm $appVer], got [$ping]"
    # The CLI's own verb, run directly (Send-Ctl forces --json; the text form and the exit code are
    # part of what is being checked). The CLI half is agwinterm's; the only lite-side fact is that
    # the app line carries ping's string against the SANDBOX pipe, not the default one.
    foreach ($v in 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID', 'AGWINTERM_PIPE') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    $vout = (& $ctl version --pipe $s.Pipe 2>&1 | Out-String)
    $vcode = $LASTEXITCODE
    Check 'agwintermctl version exits 0 against the sandbox' ($vcode -eq 0) "exit $vcode; output: $vout"
    $appLine = ($vout -split "`r?`n" | Where-Object { $_ -match '^app ' } | Select-Object -First 1)
    Check 'version prints an app line' ([bool]$appLine) "output: $vout"
    Check 'the app line carries the string ping answered' ($appLine -and $appLine.Contains($ping)) "line [$appLine], ping [$ping]"
    Check "the app line names the sandbox's pipe" ($appLine -and $appLine.Contains("\\.\pipe\$($s.Pipe)")) "line [$appLine]"
    Check 'the app line does not say unavailable' ($appLine -and $appLine -notmatch 'unavailable') "line [$appLine]"
    $vj = $null
    try { $vj = (& $ctl version --pipe $s.Pipe --json 2>&1 | Out-String) | ConvertFrom-Json } catch { }
    Check 'version --json reports the app available with that version' ($vj -and $vj.app.available -eq $true -and [string]$vj.app.version -eq $ping -and [string]$vj.app.pipe -eq $s.Pipe) "json: $($vj | ConvertTo-Json -Compress)"

    # --- the reply is a bare JSON integer -------------------------------------------------------
    $raw = CursorRaw $sid
    $r = ConvertFrom-Json $raw
    Check 'surface cursor answers ok' ([bool]$r.ok) "raw: $raw"
    # {"ok":true,"result":7} — no {"col":7}, no "7". The exact wire form both products emit.
    Check 'the wire form is {"ok":true,"result":<int>}' ($raw -match '^\{"ok":true,"result":\d+\}$') "raw: $raw"
    Check 'the result parses as a number, not a string' (IsInteger $r.result) "result is $($r.result.GetType().Name)"

    # --- the number is the prompt's width, not 0 mistaken for "no answer" -----------------------
    $c0 = Col $sid
    Check 'a fresh pane reports the prompt column, not 0' ($c0 -gt 0) "column $c0; screen: $(LastLine $sid)"

    # --- it moves by exactly what was typed, and back -------------------------------------------
    # No newline: an unsubmitted draft at the prompt is the state the caller actually asks about.
    Send-Ctl $s @('session', 'type', 'abcdefgh', '--target', $sid) | Out-Null
    Start-Sleep -Milliseconds 1500
    $c1 = Col $sid
    Check 'typing 8 cells moves the column by 8' ($c1 - $c0 -eq 8) "before $c0, after $c1"
    # Anchored to the screen: the caret must sit immediately after the text it typed. The typed
    # text's POSITION rather than the line's length, because a prediction or a right-hand prompt
    # segment legitimately paints to the right of the caret.
    $line = LastLine $sid
    $at = $line.IndexOf('abcdefgh')
    Check 'the column is where the screen shows the caret' ($at -ge 0 -and $c1 -eq $at + 8) "column $c1, text at $at in [$line]"
    Send-Ctl $s @('session', 'type', 'xyz', '--target', $sid) | Out-Null
    Start-Sleep -Milliseconds 1500
    $c2 = Col $sid
    Check 'three more cells: three more columns' ($c2 - $c1 -eq 3) "before $c1, after $c2"
    # Three deletes (0x7f is what the Backspace key sends), through session type with the byte
    # allowed. A counter that only ever grows passes everything above this line.
    Send-Ctl $s @('session', 'type', ([string][char]0x7f * 3), '--allow-control', '--target', $sid) | Out-Null
    Start-Sleep -Milliseconds 1500
    $c3 = Col $sid
    Check 'and it moves BACK on delete' ($c3 -eq $c1) "expected $c1, got $c3"
    Send-Ctl $s @('session', 'type', ([string][char]0x7f * 8), '--allow-control', '--target', $sid) | Out-Null
    Start-Sleep -Milliseconds 1000

    # --- a miss is a refusal, not a 0 -----------------------------------------------------------
    $raw = CursorRaw 'no-such-session'
    $r = ConvertFrom-Json $raw
    Check 'an unknown target is refused (ok:false)' (-not $r.ok -and [bool][string]$r.error) "raw: $raw"

    # --- the deferred wrap: the answer can EQUAL the width ---------------------------------------
    # session write feeds the emulator only, never the shell, so the caret can be placed exactly.
    # CUF 999 clamps to the last column, which yields the width without asking the window for it.
    $wid = NewSession 'wrap'
    Check 'a session for the wrap case' ([bool]$wid)
    Check 'the wrap session reaches a prompt' (Wait-Prompt $wid) "screen: $(Text $wid)"
    Send-Ctl $s @('session', 'write', ("`r" + [char]27 + '[999C'), '--target', $wid) | Out-Null
    Start-Sleep -Milliseconds 500
    $cols = (Col $wid) + 1
    Check 'the pane is wider than a prompt' ($cols -gt 20) "width $cols"
    Send-Ctl $s @('session', 'write', ("`r" + ('x' * $cols)), '--target', $wid) | Out-Null
    Start-Sleep -Milliseconds 500
    $atEnd = Col $wid
    # ONE PAST the last cell: a caller that indexes with this number without clamping is off the grid.
    Check 'after printing into the last column the answer equals the pane width' ($atEnd -eq $cols) "width $cols, column $atEnd"
    Send-Ctl $s @('session', 'write', 'x', '--target', $wid) | Out-Null
    Start-Sleep -Milliseconds 500
    $wrapped = Col $wid
    Check 'the next print wraps to column 1' ($wrapped -eq 1) "column $wrapped"

    # --- a pane whose shell has exited still answers; a session gone from the tree does not ------
    $did = NewSession 'dead'
    Check 'a session for the exited case' ([bool]$did)
    Check 'the dead-to-be session reaches a prompt' (Wait-Prompt $did) "screen: $(Text $did)"
    Send-Ctl $s @('session', 'type', "exit`r", '--target', $did) | Out-Null
    $exited = $false
    for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 500; $n = Node $did; if ($n -and $n.exited) { $exited = $true; break } }
    # Prove the premise: a shell that ignored `exit` would make the next check a duplicate.
    Check 'the shell exited (tree says so)' $exited
    $raw = CursorRaw $did
    $r = ConvertFrom-Json $raw
    # A dead child does not un-address the pane: the grid is still there, and a caller deciding
    # whether to type must get a number here, not an error.
    Check 'a pane whose shell has exited still reports its caret' ([bool]$r.ok -and (IsInteger $r.result)) "raw: $raw"

    Send-Ctl $s @('session', 'close', '--target', $did) | Out-Null
    Start-Sleep -Milliseconds 1500
    Check 'the closed session left the tree' (-not (Node $did))
    $raw = CursorRaw $did
    $r = ConvertFrom-Json $raw
    Check 'a session gone from the tree is refused, not answered from a stale handle' (-not $r.ok) "raw: $raw"

    # --- statusChangedAt: the age of the last status WRITE, on every tree node --------------------
    # `tree` says "status":"active" and nothing about how long ago; this field is what tells a
    # working agent from one whose hook died forty minutes ago. Epoch SECONDS, a JSON number.
    function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    function Stamp([string]$id) { (Node $id).statusChangedAt }
    function SetStatus([string]$id, [string]$st) {
        $r = ConvertFrom-Json (Send-Ctl $s @('session', 'status', $st, '--target', $id))
        if (-not $r.ok) { throw "session status $st --target $id refused: $($r.error)" }
    }
    $fresh = NewSession 'stamp'
    Check 'a session for the statusChangedAt cases' ([bool]$fresh)
    Start-Sleep -Milliseconds 500
    # On the wire as a bare number, not "1756900000" - the same shape agwinterm emits.
    $rawTree = Send-Ctl $s @('tree')
    Check 'tree carries statusChangedAt as a JSON number' ($rawTree -match '"id":"' + [regex]::Escape($fresh) + '"[^}]*"statusChangedAt":\d+') "raw: $rawTree"
    $n = Node $fresh
    Check 'the field is present on a session that never set a status' ($null -ne $n.statusChangedAt -and (IsInteger $n.statusChangedAt)) "node: $($n | ConvertTo-Json -Compress)"
    Check 'and its status is still the default' ($n.status -eq 'idle') "status: $($n.status)"
    # Seeded at creation: the session reports its OWN age rather than 0 (or 1970).
    $t0 = Stamp $fresh
    Check 'a never-written stamp is within a minute of now, not 0' ([math]::Abs((Now) - $t0) -le 60) "stamp $t0, now $(Now)"
    # Every node, not only the new one: the first session never set a status either.
    Check 'the first session (never written) carries it too' ((IsInteger (Stamp $sid)) -and [math]::Abs((Now) - (Stamp $sid)) -le 60) "stamp $(Stamp $sid)"

    # Writing a status makes the age small.
    Start-Sleep -Seconds 2
    SetStatus $fresh 'active'
    Start-Sleep -Milliseconds 300
    $t1 = Stamp $fresh
    Check 'setting a status stamps it now' ([math]::Abs((Now) - $t1) -le 5) "stamp $t1, now $(Now)"
    Check 'the status itself was written' ((Node $fresh).status -eq 'active')
    Check 'and the stamp did not move backwards' ($t1 -ge $t0) "seed $t0, after write $t1"

    # THE re-assert rule. Back-dating is not reachable from outside, so prove it with time: the
    # same status written again 2 s later must move the stamp FORWARD. Equal would mean repeats
    # are collapsed, which reports the age of the first write and makes a healthy agent - a hook
    # re-asserting `active` every 30 s - look dead. Exactly the decision someone will later
    # mistake for a bug.
    Start-Sleep -Seconds 2
    SetStatus $fresh 'active'
    Start-Sleep -Milliseconds 300
    $t2 = Stamp $fresh
    Check 're-asserting the SAME status moves the stamp forward (repeats are not collapsed)' ($t2 -gt $t1) "first write $t1, re-assert $t2"
    Check 'the re-assert stamp is now-ish' ([math]::Abs((Now) - $t2) -le 5) "stamp $t2, now $(Now)"

    # The age belongs to the pane whose status the node shows: writing one session's status must
    # not touch another's stamp.
    $other = Stamp $sid
    Start-Sleep -Seconds 1
    SetStatus $fresh 'blocked'
    Start-Sleep -Milliseconds 300
    Check "another session's stamp is untouched by this one's write" ((Stamp $sid) -eq $other) "before $other, after $(Stamp $sid)"
    Check 'a different status stamps as well' ((Stamp $fresh) -ge $t2 -and (Node $fresh).status -eq 'blocked') "stamp $(Stamp $fresh)"
    Send-Ctl $s @('session', 'close', '--target', $fresh) | Out-Null
}
finally {
    if ($s) { Stop-Sandbox $s }
}

if ($fail) { "control-read: $fail failed"; exit 1 }
"control-read: all passed"
exit 0
