param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('agliteterm-agent-unit-'+[guid]::NewGuid().ToString('N'))
& "$PSScriptRoot/build-fake-claude.ps1" -OutputDirectory $root
$fake=Join-Path $root 'claude.exe';$repo=Split-Path $PSScriptRoot -Parent
$shell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$helper=Join-Path $repo 'assets/agliteterm-claude-update.ps1'
$checks=0;$failed=0
function Check([string]$Name,[bool]$Ok){$script:checks++;if($Ok){"PASS $Name"}else{$script:failed++;"FAIL $Name"}}
foreach($mode in 'noop','fail','new','downgrade'){
    [IO.File]::WriteAllText((Join-Path $root 'version.txt'),'1.0.0')
    [IO.File]::WriteAllText((Join-Path $root 'update-mode.txt'),$mode)
    $receipt=Join-Path $root "$mode.json"
    $output=& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Executable $fake -Receipt $receipt -Nonce $mode 2>&1
    $code=$LASTEXITCODE
    if($mode-eq'fail'){Check 'failed update produces no restart receipt' ($code-ne 0 -and -not(Test-Path $receipt))}
    else{
        $r=Get-Content -Raw $receipt|ConvertFrom-Json
        Check "$mode update receipt authorizes only newer version" ($code-eq 0 -and $r.nonce-eq$mode -and $r.updated-eq($mode-eq'new'))
    }
}
$receipt=Join-Path $root 'existing.json';[IO.File]::WriteAllText($receipt,'KEEP')
$null=& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Executable $fake -Receipt $receipt -Nonce refuse 2>&1
Check 'updater never overwrites an existing receipt' ($LASTEXITCODE-ne 0 -and [IO.File]::ReadAllText($receipt)-ceq'KEEP')
# Parse every shipped integration asset with both supported PowerShell parsers; no script runs.
foreach($asset in Get-ChildItem (Join-Path $repo 'assets') -Filter 'agliteterm-*.ps1'){
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($asset.FullName,[ref]$tokens,[ref]$errors)
    Check "PowerShell parser: $($asset.Name)" ($errors.Count-eq 0)
    $parse="`$e=`$null;`$t=`$null;[void][Management.Automation.Language.Parser]::ParseFile('"+$asset.FullName.Replace("'","''")+"',[ref]`$t,[ref]`$e);if(`$e.Count){exit 1}"
    & $shell -NoProfile -NonInteractive -Command $parse
    Check "PS5.1 parser: $($asset.Name)" ($LASTEXITCODE-eq 0)
}
function Invoke-AgentFixture([string]$Body,[int]$Requests){
    $pipe='p11-agent-unit-'+[guid]::NewGuid().ToString('N')
    $server=[IO.Pipes.NamedPipeServerStream]::new($pipe,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
    $start=[Diagnostics.ProcessStartInfo]::new($shell);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $prefix="`$env:TERM_PROGRAM='agliteterm';`$env:AGWINTERM_SESSION_ID='private-test-pane';`$env:AGWINTERM_PIPE='$pipe';`$env:PATH='"+$root.Replace("'","''")+";'+`$env:PATH;"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix+$Body))
    $start.Arguments='-NoProfile -NonInteractive -EncodedCommand '+$encoded
    $client=$null;$answers=@();$accept=$null;$read=$null;$reader=$null
    $cancel=[Threading.CancellationTokenSource]::new()
    try {
        $accept=$server.WaitForConnectionAsync($cancel.Token);$client=[Diagnostics.Process]::Start($start);[void]$client.SafeHandle
        $stdout=$client.StandardOutput.ReadToEndAsync();$stderr=$client.StandardError.ReadToEndAsync()
        for($i=0;$i-lt$Requests;$i++){
            if(-not$accept.Wait(30000)){throw 'Fixture pipe connection timed out'}
            $reader=[IO.StreamReader]::new($server,[Text.Encoding]::UTF8,$true,1024,$true)
            $read=$reader.ReadLineAsync($cancel.Token).AsTask();if(-not$read.Wait(10000)){throw 'Fixture request timed out'}
            $answers+=($read.Result|ConvertFrom-Json);$reader.Dispose();$reader=$null
            if($answers[-1].cmd-eq'session.bind'){
                $writer=[IO.StreamWriter]::new($server,[Text.UTF8Encoding]::new($false),1024,$true);$writer.AutoFlush=$true
                $writer.WriteLine('{"ok":true,"result":"bound"}');$writer.Dispose()
            }
            $server.Disconnect()
            if($i+1-lt$Requests){$accept=$server.WaitForConnectionAsync($cancel.Token)}
        }
        if(-not$client.WaitForExit(30000)){throw 'Fixture subprocess did not exit'}
        if($client.ExitCode-ne0){throw "Fixture failed: $($stderr.Result)"}
        $script:unexpectedConnection=$Requests-eq 0 -and $accept.IsCompleted -and -not$accept.IsFaulted -and -not$accept.IsCanceled
        return $answers
    }finally{
        $cancel.Cancel()
        try{if($accept){$accept.GetAwaiter().GetResult()}}catch{}
        try{if($read){$read.GetAwaiter().GetResult()|Out-Null}}catch{}
        if($reader){$reader.Dispose()};$server.Dispose();$cancel.Dispose()
        if($client){if(-not$client.HasExited){$client.Kill();if(-not$client.WaitForExit(5000)){throw 'Owned fixture process did not exit'}};$client.Dispose()}
    }
}
$assets=Join-Path $repo 'assets'
$wrapper=(Join-Path $assets 'agliteterm-claude.ps1').Replace("'","''")
[IO.File]::WriteAllText((Join-Path $root 'immediate.txt'),'private fixture behavior')
$requests=@(Invoke-AgentFixture ". '$wrapper';claude;claude" 2)
$binding=$requests[0].args.agent
Check 'wrapper binds explicit generated UUID and reuses successful conversation' ($requests.Count-eq2 -and $requests[0].cmd-eq'session.bind' -and $requests[0].target-eq'private-test-pane' -and $binding-match'^claude --resume [0-9a-f-]{36}$' -and $requests[1].args.agent-eq$binding)
$log=@(Get-Content (Join-Path $root 'launch.log'))
Check 'wrapper first launch uses session-id, next uses resume, no implicit YOLO' ($log[-2]-match'--session-id' -and $log[-1]-match'--resume' -and ($log-join' ')-notmatch'dangerously-skip')
$explicit=[guid]::NewGuid().ToString()
$null=Invoke-AgentFixture ". '$wrapper';claude --resume $explicit" 0
Check 'explicit resume passes through without generated replacement UUID' ((Get-Content (Join-Path $root 'launch.log'))[-1]-match("--resume\t"+$explicit))
$null=Invoke-AgentFixture ". '$wrapper';claude --append-system-prompt '--session-id' $explicit;claude remote-control" 0
$log=@(Get-Content (Join-Path $root 'launch.log'))
Check 'wrapper leaves opaque arguments and new subcommands unchanged' ($log[-2]-match("--append-system-prompt\t--session-id\t"+$explicit+'$') -and $log[-1]-match'\tremote-control$')
$notify=(Join-Path $assets 'agliteterm-codex-notify.ps1').Replace("'","''")
$request=@(Invoke-AgentFixture "& '$notify' '{`"type`":`"agent-turn-complete`"}'" 1)
Check 'Codex completion notify uses exact event and pane' ($request[0].cmd-eq'session.status' -and $request[0].args.status-eq'completed' -and $request[0].target-eq'private-test-pane')
$null=Invoke-AgentFixture "& '$notify' '{`"type`":`"other`"}'" 0
Check 'unknown Codex event is inert (no pipe connection)' (-not$script:unexpectedConnection)
$prompt=(Join-Path $assets 'agliteterm-prompt.ps1').Replace("'","''")
$protocol=@'
$global:p11Claims=0;$global:p11Acks=0;$global:p11Receipts=0
$global:p11Offer=@{lease='77';deadline=[string][DateTime]::UtcNow.AddSeconds(20).ToFileTimeUtc();command='p11-command'}|ConvertTo-Json -Compress
function global:Invoke-AgLiteBridgeRequest([string]$Op,[string]$Lease='', [switch]$NoReply){
    if($Op-eq'claim'){$global:p11Claims++;if($global:p11Claims-eq 1){return};return [pscustomobject]@{ok=$true;result=$global:p11Offer}}
    if($Op-eq'ack'){$global:p11Acks++;if($global:p11Acks-eq 1){return};return [pscustomobject]@{ok=$true;result=$global:p11Offer}}
    if($Op-eq'received'){$global:p11Receipts++;return}
}
if((Get-AgLiteResume)-cne'p11-command' -or $global:p11Claims-ne 2 -or $global:p11Acks-ne 2 -or $global:p11Receipts-ne 1){throw 'Lost reply retry/receipt failed'}
if((Get-AgLiteResume) -or $global:p11Receipts-ne 1){throw 'Duplicate lease executed twice'}
$global:p11Offer=@{lease=[guid]::NewGuid().ToString();deadline=[string][DateTime]::UtcNow.AddSeconds(20).ToFileTimeUtc();command='new-ui-command'}|ConvertTo-Json -Compress
if((Get-AgLiteResume)-cne'new-ui-command' -or $global:p11Receipts-ne 2){throw 'Fresh UI authorization mistaken for old numeric reservation'}
$global:p11Offer=@{lease='78';deadline=[string][DateTime]::UtcNow.AddSeconds(-1).ToFileTimeUtc();command='expired'}|ConvertTo-Json -Compress
if(Get-AgLiteResume){throw 'Expired authorization executed'}
'@
$null=Invoke-AgentFixture (". '$prompt';"+$protocol) 0
Check 'prompt retries lost offer/ack, consumes once and refuses expired authorization' (-not$script:unexpectedConnection)
$readline=@'
$global:p11Reads=0;$global:p11Claims=0;$global:p11Executed=$false
function global:PSConsoleHostReadLine {$global:p11Reads++;'user draft preserved'}
'@
$boundary=@'
function global:Invoke-AgLiteBridgeRequest {}
function global:Get-AgLiteResume {$global:p11Claims++;if($global:p11Claims-eq 1){'$global:p11Executed=$true'}}
if((PSConsoleHostReadLine)-cne'$global:p11Executed=$true' -or $global:p11Executed -or $global:p11Reads-ne 0){throw 'Resume executed inside reader or draft reader entered'}
if((PSConsoleHostReadLine)-cne'user draft preserved' -or $global:p11Reads-ne 1){throw 'Ordinary custom reader not preserved'}
$claims=$global:p11Claims;$null=prompt
if($global:p11Claims-ne$claims){throw 'Rendering prompt claimed another command'}
'@
$null=Invoke-AgentFixture ($readline+"; . '$prompt';"+$boundary) 0
Check 'host boundary returns resume without executing it and preserves ordinary reader' (-not$script:unexpectedConnection)
"agent-scripts-unit: $checks checks, $failed failed; fake CLI only, artifacts $root"
if($failed){throw 'agent script unit checks failed'}
exit 0
