# Control-API conformance — Task 6 of the product split.
#
# agliteterm's headline compatibility promise is that it speaks the agwintermctl dialect. This
# drives every verb in test/control-api.json through the REAL agwintermctl against a sandbox
# instance and checks the response SHAPE. The same spec and the same runner live in agwinterm and
# run against the full app, so "same control API" is enforced by both CIs rather than asserted in
# a README.
#
# Shape is the default; steps can also pin specific values and CLI exits.
# Machine-dependent shell text is not compared to a fixed snapshot.
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
. "$PSScriptRoot/suite-context.ps1"
Assert-LiteSuiteContext
. "$PSScriptRoot/suite-policy.ps1"
Assert-LiteSuitePolicy @('conformance')
. "$PSScriptRoot/selection-ui-env.ps1"
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
$env:AGWINTERM_WINDOW_ID = $null

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
# And for P3 (`session context`, `restore capture`; agwinterm #233, contract #235): a post-#233
# client answers `agwintermctl restore` with its usage line before any pipe is opened, while the
# 0.17.x client has no `restore` command at all (`unknown command`) and refuses `session context`
# on its own side the same way. On that client the three P3 steps (context set, context --clear,
# restore capture) would fail on the CLIENT's refusal and the two P3 errors would PASS on it - a
# refusal, but not the one the contract pins - so all five are skipped instead
# (test/control-honesty.ps1 and test/restore-matrix.ps1 use this probe).
$probe = (& $ctl restore --pipe 'conform-probe' --json 2>&1) -join ''
$cliHasP3 = $probe -match 'usage: agwintermctl restore'
# And for P4 (`session split --axis`, `session split close`, `session swap`, `session focus`;
# agwinterm #238, contract #240): a post-#238 client refuses `session swap <positional>` on its own
# side ("Nothing sent") before any pipe is opened; the 0.17.12 client has no `swap` at all and says
# `unknown session command`. A pre-P4 client drops `--axis` on the floor (so the `--axis diagonal`
# refusal would PASS as a plain split and the horizontal step would split vertical), and sends
# `split close` as a bad op - a refusal, but the client's, not the one the contract pins - so the
# P4 steps and errors are skipped on it instead (test/control-honesty.ps1 uses this probe).
$probe = (& $ctl session swap x --pipe 'conform-probe' --json 2>&1) -join ''
$cliHasP4 = $probe -match 'Nothing sent'
# And for P5 (`session overlay --pane`, `overlay copy` / `text`, `session text --all` / `--lines`;
# agwinterm #250, contract #252): a post-#250 client refuses `session overlay resize --pane left` on
# its own side ("Nothing sent") before any pipe is opened - a pane overlay is always full-pane; the
# 0.17.13 client drops `--pane` and sends a bare resize to a pipe that is not there. A pre-P5 client
# would drop `--pane` from the open too (the POPUP would open where a pane overlay was asked for, and
# the `text --pane left` step would then read it as ok), drop `--all`, and refuse `overlay copy` on
# its own side - so the P5 steps and errors are skipped on it instead (test/control-honesty.ps1
# uses this probe).
$probe = (& $ctl session overlay resize --pane left --pipe 'conform-probe' --json 2>&1) -join ''
$cliHasP5 = $probe -match 'Nothing sent'

# Sidebar width is a real SET. Restore it between fixtures even in the supervisor's private
# registry namespace, so subsequent geometry cases do not inherit this contract step's width.
. "$PSScriptRoot/test-registry-path.ps1"
$regKey = 'HKCU:\'+(Get-LiteTestRegistryPath)
$savedSidebar = if (Test-Path $regKey) { (Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue).SidebarW } else { $null }
# The reason a step cannot be SENT by the client at hand, or $null when it can. A skip names the
# client's shortfall, not the step's, so the fix (set AGWINTERMCTL) is in the message.
function Needs-NewClient($argv) {
    $a = [string[]]@($argv)
    if ($a.Count -eq 3 -and $a[0] -eq 'sidebar' -and $a[1] -eq 'width' -and $a[2] -match '^\d+$' -and -not $cliHasSidebarWidth) {
        return 'this agwintermctl predates agwinterm #226 and sends `sidebar width N` as a read - set AGWINTERMCTL to a newer build'
    }
    if ($a.Count -ge 2 -and -not $cliHasP3 -and (($a[0] -eq 'session' -and $a[1] -eq 'context') -or ($a[0] -eq 'restore' -and $a[1] -eq 'capture'))) {
        return 'this agwintermctl predates agwinterm #233 and refuses `session context` / `restore capture` on its own side - set AGWINTERMCTL to a newer build'
    }
    if ($a.Count -ge 2 -and -not $cliHasP4 -and $a[0] -eq 'session' -and
        (($a[1] -eq 'split' -and ($a -contains '--axis' -or ($a.Count -ge 3 -and $a[2] -eq 'close'))) -or $a[1] -eq 'swap' -or $a[1] -eq 'focus')) {
        return 'this agwintermctl predates agwinterm #238 and drops `--axis` / refuses `split close`, `swap`, `focus` on its own side - set AGWINTERMCTL to a newer build'
    }
    if ($a.Count -ge 2 -and -not $cliHasP5 -and $a[0] -eq 'session' -and
        (($a[1] -eq 'overlay' -and ($a -contains '--pane' -or ($a.Count -ge 3 -and $a[2] -in 'copy', 'text'))) -or
         ($a[1] -eq 'text' -and ($a -contains '--all' -or $a -contains '--lines')))) {
        return 'this agwintermctl predates agwinterm #250 and drops --pane / --all and refuses overlay copy / text on its own side - set AGWINTERMCTL to a newer build'
    }
    return $null
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
function Invoke-CtlRaw($argv, $InputText = $null) {
    $start=[Diagnostics.ProcessStartInfo]::new($ctl)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    foreach($arg in @($argv)+@('--pipe',$pipe,'--json')){$start.ArgumentList.Add([string]$arg)}
    $child=[Diagnostics.Process]::new();$child.StartInfo=$start
    try {
        if(-not $child.Start()){throw 'CLI did not start'}
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        if($null -ne $InputText){$child.StandardInput.Write([string]$InputText)}
        $child.StandardInput.Close()
        if(-not $child.WaitForExit(30000)){$child.Kill($true);$child.WaitForExit();throw 'CLI timed out'}
        $script:ctlExit=$child.ExitCode;$script:ctlError=$stderr.GetAwaiter().GetResult();$out=$stdout.GetAwaiter().GetResult()
        try{return $out|ConvertFrom-Json}catch{return [pscustomobject]@{__raw=$out}}
    }finally{$child.Dispose()}
}

function Invoke-Ctl($argv,$InputText=$null) {
    if($argv.Count-ge 2 -and $argv[0]-eq 'selection' -and $argv[1]-in @('copy','finalize')){
        $capture=@{Reply=$null}
        Invoke-SelectionClipboardCopy $conformanceClipboard { $capture.Reply=Invoke-CtlRaw $argv $InputText } { '' } ([Func[bool]]{
            $p -and -not $p.HasExited -and [SelectionUi]::ClipboardOwnedBy($p.Id)
        })
        return $capture.Reply
    }
    Invoke-CtlRaw $argv $InputText
}
# Session creation is acknowledged before the full UI publishes the target. Retry reads only.
function Wait-Session([string]$Id, [switch]$Prompt) {
    $deadline=[DateTime]::UtcNow.AddSeconds(45)
    do {
        $probe=Invoke-Ctl @('session','text','--target',$Id)
        if($probe.ok -and (-not $Prompt -or [string]$probe.result -match '(?m)^PS [^\r\n]*>')){return $true}
        Start-Sleep -Milliseconds 250
    } while([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Test-Shape($resp, [string]$kind, $fields, [bool]$Payload = $false) {
    if ($null -eq $resp -or $resp.PSObject.Properties.Name -contains '__raw') { return "not JSON: $($resp.__raw)" }
    if (-not $Payload -and -not $resp.ok) { return "ok:false — $($resp.error)" }
    $r = $resp.result
    if ($Payload) { $r = $resp }
    switch ($kind) {
        'string' { if ($r -isnot [string]) { return "result is not a string" } }
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

$p=$null;$conformanceClipboard=$null;$cleanupOk=$true
try {
    $conformanceClipboard=Save-SelectionClipboard (Join-Path $env:LOCALAPPDATA ('conformance-'+[guid]::NewGuid().ToString('N')+'.dpapi'))
    $p = Start-Process $Exe -ArgumentList @('--pipe', $pipe, '--no-restore') -WindowStyle Hidden -PassThru
    [void]$p.SafeHandle
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
        $why = Needs-NewClient $argv
        if ($why) { Skip "$($step.verb) ($($argv -join ' '))" $why; continue }
        $resp = Invoke-Ctl $argv $step.stdin
        $payload=$step.output -eq 'payload'
        $why = Test-Shape $resp $step.result $step.fields $payload
        if($null -ne $step.exit -and $script:ctlExit -ne $step.exit){$why="exit $script:ctlExit, expected $($step.exit): $script:ctlError"}
        $value=$resp.result
        if($payload){$value=$resp}
        if(-not $why -and $step.values){foreach($property in $step.values.PSObject.Properties){if($value.($property.Name) -cne $property.Value){$why="unexpected $($property.Name) value";break}}}
        Check $step.verb ($null -eq $why) $why
        $checked++
        if (-not $why -and $step.capture) { $vars[$step.capture] = if($step.captureField){[string]$value.($step.captureField)}else{[string]$value} }
        if (-not $why -and $step.verb -in 'session.new','session.duplicate') {
            Check "$($step.verb) target published" (Wait-Session ([string]$value))
        }
        if ($step.settle) { Start-Sleep -Seconds $step.settle }
    }

    # --- the env contract -----------------------------------------------------------------------
    # The AGWINTERM_* variables are what the agent skill, the status hooks and agwintermctl-inside-a-
    # session read. They are the reason the rename kept the old prefix, so they are part of the
    # contract rather than an implementation detail — and they are asked of the SHELL, not of the
    # app, because what matters is that the child process actually received them.
    $envSession = [string](Invoke-Ctl @('session', 'new', '--name', 'conf-env')).result
    if (-not (Wait-Session $envSession -Prompt)) { throw 'Environment session prompt did not become ready' }
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
        $why = Needs-NewClient $e.args
        if ($why) { Skip "refuses: $($e.args -join ' ')" $why; continue }
        $resp = Invoke-Ctl (Expand-Args $e.args)
        $isRefusal = ($null -ne $resp) -and ($resp.PSObject.Properties.Name -notcontains '__raw') -and (-not $resp.ok) -and $resp.error
        Check "refuses: $($e.args -join ' ')" $isRefusal
    }
}
finally {
    $cleanupOk=Invoke-SelectionCleanup {
    # Close ONLY what this run created, by name, through the pipe — never by enumerating processes.
    # A blanket "stop every agliteterm" here would close the windows the developer is working in,
    # which is the exact accident this suite's rules exist to prevent.
    try {
        $wins = (Invoke-Ctl @('window', 'list')).result
        foreach ($w in $wins) {
            if ($w.name -like 'conf-*') { Invoke-Ctl @('window', 'close', $w.name) | Out-Null }
        }
    } catch { }
    if($p -and -not $p.HasExited){
        $p.CloseMainWindow()|Out-Null
        if(-not $p.WaitForExit(5000)){$p.Kill();if(-not $p.WaitForExit(10000)){throw 'Owned conformance window did not exit'}}
    }
    } {
        # This key belongs to the supervisor namespace, not personal preferences.
        if ($null -ne $savedSidebar) { Set-ItemProperty -Path $regKey -Name SidebarW -Value $savedSidebar -Type DWord }
        elseif (Test-Path $regKey) { Remove-ItemProperty -Path $regKey -Name SidebarW -ErrorAction SilentlyContinue }
    } {
        if($conformanceClipboard){Restore-SelectionClipboard $conformanceClipboard}
    }
    if(-not $cleanupOk){exit 2}
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
