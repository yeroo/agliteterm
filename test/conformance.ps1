# Control-API conformance — Task 6 of the product split.
#
# agliteterm's headline compatibility promise is that it speaks the agwintermctl dialect. This
# drives every verb in test/control-api.json through the REAL agwintermctl against a sandbox
# instance and checks the response SHAPE. The same spec and the same runner live in agwinterm and
# run against the full app, so "same control API" is enforced by both CIs rather than asserted in
# a README.
#
# Shape, not values: "session.text returns a string" is a contract; "it returns exactly these
# bytes" is a snapshot of one machine's shell prompt.
#
# Suite rules (shared with the rest of the checks):
#   - always a sandbox instance (--pipe <name>); never the default instance, which owns real state
#   - never inject global input — every action goes through the control pipe
param(
    [string]$Exe = "$PSScriptRoot\..\bin\agliteterm.exe",
    [string]$Spec = "$PSScriptRoot\control-api.json",
    # CI passes -Strict: a suite that skips is reporting success while checking nothing,
    # which is worse than not running it at all. Locally a skip is the right answer.
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "  PASS  $name" }
    else { $script:fail++; "  FAIL  $name$(if ($detail) { " — $detail" })" }
}

"== conformance =="

. "$PSScriptRoot\ctl-path.ps1"
$ctl = Get-CtlPath
if (-not $ctl) { "  SKIP  agwintermctl not found (set AGWINTERMCTL)"; exit ($Strict ? 1 : 0) }
"  using: $(Split-Path $ctl -Leaf) from $(Split-Path $ctl -Parent)"

# NOT back into $Spec: that parameter is typed [string], and PowerShell is case-insensitive, so
# assigning the parsed object to $spec would silently ConvertTo-String it — $contract.steps then reads
# as $null and the whole run "passes" having checked nothing. Which it did, once.
# agwintermctl defaults its target to $AGWINTERM_SESSION_ID when none is given — which is the whole
# point of that variable, and a trap here: this runner is itself launched from a terminal session,
# so an untargeted verb would aim at the DEVELOPER's session id, which the sandbox instance has
# never heard of ("session not found"). CI would pass and a local run would fail, or worse.
$env:AGWINTERM_SESSION_ID = $null
$env:AGWINTERM_PANE_ID = $null
$env:AGWINTERM_PIPE = $null

$contract = Get-Content $Spec -Raw | ConvertFrom-Json
$pipe = 'conform'
$vars = @{}
$checked = 0
$skipped = 0

# The client probe (the P1-lite pattern, test/control-read.ps1): a step the CLI at hand cannot
# SEND is skipped, not passed. A post-#226 agwintermctl refuses `sidebar width wide` on its own
# side ("needs a whole number") before any pipe is opened; the 0.17.x client has no width argument
# and sends `sidebar width 300` as a READ - so the set step would pass as a read that happened to
# have the right shape, and the `sidebar width 5` refusal would come back ok. Under -Strict a skip
# is a failure, which is the release gate until agwinterm tags the release that carries #226.
$probe = (& $ctl sidebar width wide --pipe 'conform-probe' --json 2>&1) -join ''
$cliHasSidebarWidth = $probe -match 'whole number'
function Needs-NewClient($argv) {
    $a = [string[]]@($argv)
    return ($a.Count -eq 3 -and $a[0] -eq 'sidebar' -and $a[1] -eq 'width' -and $a[2] -match '^\d+$' -and -not $cliHasSidebarWidth)
}
function Skip([string]$name, [string]$why) { $script:skipped++; "  SKIP  $name — $why" }

# Substitute {captured} values into an argument list.
function Expand-Args($argv) {
    $out = @()
    foreach ($a in $argv) {
        $s = [string]$a
        foreach ($k in $vars.Keys) { $s = $s.Replace("{$k}", $vars[$k]) }
        $out += $s
    }
    # The comma is load-bearing: PowerShell unwraps a one-element array on return, and splatting a
    # bare string spreads its CHARACTERS — @('ping') reached agwintermctl as "p i n g".
    return ,[string[]]$out
}

# One control call. Returns the parsed envelope, or $null when the output was not JSON at all —
# which is itself a contract violation worth reporting distinctly from ok:false.
function Invoke-Ctl($argv) {
    $argv = [string[]]@($argv)          # same unwrapping trap on the way in
    $out = (& $ctl @argv --pipe $pipe --json 2>&1) -join "`n"
    try { return $out | ConvertFrom-Json } catch { return [pscustomobject]@{ __raw = $out } }
}

function Test-Shape($resp, [string]$kind, $fields) {
    if ($null -eq $resp -or $resp.PSObject.Properties.Name -contains '__raw') { return "not JSON: $($resp.__raw)" }
    if (-not $resp.ok) { return "ok:false — $($resp.error)" }
    $r = $resp.result
    switch ($kind) {
        'string' { if ($r -isnot [string]) { return "result is $($r.GetType().Name), expected string" } }
        'integer' {
            # A whole number on the wire, as a JSON number: not "7", not 7.5, not null. surface.cursor
            # is why this kind exists - a bare integer is the reply agterm and agwinterm share, and
            # ConvertFrom-Json turns it into [int]/[long]; a string means a product started quoting
            # it, a [double] means a fraction crept in, and $null means the field was dropped.
            if ($null -eq $r) { return "result is null, expected integer" }
            if ($r -is [string]) { return "result is a string, expected a bare integer" }
            if ($r -isnot [int] -and $r -isnot [long]) { return "result is $($r.GetType().Name), expected integer" }
        }
        'object' {
            if ($r -isnot [psobject]) { return "result is not an object" }
            foreach ($f in $fields) { if ($r.PSObject.Properties.Name -notcontains $f) { return "result is missing '$f'" } }
        }
        'array' {
            if ($r -isnot [Array]) { return "result is not an array" }
            if ($r.Count -gt 0) {
                foreach ($f in $fields) { if ($r[0].PSObject.Properties.Name -notcontains $f) { return "elements are missing '$f'" } }
            }
        }
    }
    return $null
}

$p = Start-Process $Exe -ArgumentList @('--pipe', $pipe, '--no-restore') -PassThru
try {
    # Wait for the pipe rather than sleeping a guessed amount: the first verb failing because the
    # app had not finished starting would look exactly like a broken verb.
    $up = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        if ((Invoke-Ctl @('ping')).ok) { $up = $true; break }
    }
    Check 'the sandbox instance answers' $up
    if (-not $up) { throw 'instance never came up' }

    foreach ($step in $contract.steps) {
        if ($step.setup) {
            # "window.new:name" — a step that needs a subject it must create itself.
            $parts = $step.setup -split ':', 2
            if ($parts[0] -eq 'window.new') { Invoke-Ctl @('window', 'new', '--name', $parts[1]) | Out-Null; Start-Sleep -Seconds 6 }
        }
        $argv = Expand-Args $step.args
        if (Needs-NewClient $argv) { Skip "$($step.verb) ($($argv -join ' '))" 'this agwintermctl predates agwinterm #226 and sends `sidebar width N` as a read - set AGWINTERMCTL to a newer build'; continue }
        $resp = Invoke-Ctl $argv
        $why = Test-Shape $resp $step.result $step.fields
        Check $step.verb ($null -eq $why) $why
        $checked++
        if (-not $why -and $step.capture) { $vars[$step.capture] = [string]$resp.result }
        if ($step.settle) { Start-Sleep -Seconds $step.settle }
    }

    # --- the env contract -----------------------------------------------------------------------
    # The AGWINTERM_* variables are what the agent skill, the status hooks and agwintermctl-inside-a-
    # session read. They are the reason the rename kept the old prefix, so they are part of the
    # contract rather than an implementation detail — and they are asked of the SHELL, not of the
    # app, because what matters is that the child process actually received them.
    $envSession = [string](Invoke-Ctl @('session', 'new', '--name', 'conf-env')).result
    Start-Sleep -Seconds 4
    foreach ($v in $contract.sessionEnv) {
        Invoke-Ctl @('session', 'type', "echo [$v=`$env:$v]`r", '--target', $envSession) | Out-Null
        Start-Sleep -Seconds 2
        $text = [string](Invoke-Ctl @('session', 'text', '--target', $envSession)).result
        # The shell echoes the VALUE back, so a set variable prints as [NAME=something]; an unset
        # one prints as [NAME=] — which is why the pattern demands at least one character.
        Check "session env $v" ($text -match "\[$v=[^\]]+\]") 'not set in the session shell'
    }

    # --- refusals -------------------------------------------------------------------------------
    # A script branches on ok, so a bad target must come back as a refusal — not a crash, and not a
    # cheerful ok:true that did nothing.
    foreach ($e in $contract.errors) {
        if (Needs-NewClient $e.args) { Skip "refuses: $($e.args -join ' ')" 'this agwintermctl predates agwinterm #226 and sends `sidebar width N` as a read - set AGWINTERMCTL to a newer build'; continue }
        $resp = Invoke-Ctl (Expand-Args $e.args)
        $isRefusal = ($null -ne $resp) -and ($resp.PSObject.Properties.Name -notcontains '__raw') -and (-not $resp.ok) -and $resp.error
        Check "refuses: $($e.args -join ' ')" $isRefusal
    }
}
finally {
    # Close ONLY what this run created, by name, through the pipe — never by enumerating processes.
    # A blanket "stop every agliteterm" here would close the windows the developer is working in,
    # which is the exact accident this suite's rules exist to prevent.
    try {
        $wins = (Invoke-Ctl @('window', 'list')).result
        foreach ($w in $wins) {
            if ($w.name -like 'conf-*') { Invoke-Ctl @('window', 'close', $w.name) | Out-Null }
        }
    } catch { }
    $p.CloseMainWindow() | Out-Null
    Start-Sleep -Seconds 3
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}
# A conformance suite that checks nothing must never report success. This is the guard for the
# failure that actually happened: a silent empty run.
if ($checked + $skipped -lt $contract.steps.Count) {
    "conformance: only $checked of $($contract.steps.Count) verbs were exercised"
    exit 1
}
if ($fail) { "conformance: $fail FAILED"; exit 1 }
if ($skipped -and $Strict) { "conformance: $skipped skipped under -Strict"; exit 1 }
"conformance: all passed$(if ($skipped) { " ($skipped skipped)" })"
exit 0
