# Canonical desktop lease, private registry/profile/host namespace, exact owned job per suite.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict,
      [string]$TokenOwner=$env:AGLITETERM_TEST_OWNER,[string[]]$Suite)
$ErrorActionPreference='Stop';$PSNativeCommandUseErrorActionPreference=$false
$all=@('suite-policy.unit','suite-job.unit','suite-ctl.unit','suite-supervisor.unit','test-registry.unit','targeting.unit','paste.unit','restore-readiness.unit','state-fence.unit','reopen.unit','ui-request.unit','conformance-validator.unit','wave3.unit','remainder.unit','commands.unit','agent-integration.unit','installers.unit','agent-scripts.unit','configuration.unit','driving.unit','owned-procs-checks','registry-guard.unit','clipboard-guard.tests','clipboard-receipt.unit','selection-clipboard.unit','log-basics','log-restore','log-focus-font','log-rotation','diagnose','migration','restore-matrix','conformance','clipboard','agbf-packs','control-read','control-honesty','selection-ui')
$all=@('omp-idle','control-transport.unit','focus-status.unit','control-honesty-clipboard.unit','readline-status.unit','overlay-command.unit')+$all
$supported=$all+@('stress') # manual expensive stress remains explicit-only
if($Suite){foreach($name in $Suite){if($name-cnotin $supported){throw "Unknown suite: $name"}}}else{$Suite=$all}
. "$PSScriptRoot/suite-policy.ps1"
Assert-LiteSuitePolicy $Suite
$Exe=(Resolve-Path -LiteralPath $Exe).Path
$root=Split-Path $PSScriptRoot -Parent
$run=[guid]::NewGuid().ToString('N');$artifact=Join-Path $root ('.revmux/suite-'+$run)
New-Item -ItemType Directory -Path $artifact|Out-Null
$hub='C:/Users/boris/AI/bin/suite-token.py';$lease=$null;$cleanup=$true;$failed=@();$job=$null;$registryCreated=$false
$registryRoot='Software\agliteterm-tests\'+$run;$ownerNonce=[guid]::NewGuid().ToString('N')
$saved=@{};foreach($name in 'AGLITETERM_TEST_RUN','AGLITETERM_TEST_JOB','AGLITETERM_TEST_RECEIPT','AGLITETERM_TEST_CTL','AGLITETERM_TEST_REAL_CTL','LOCALAPPDATA','AGWINTERM_SESSION_ID','AGWINTERM_PANE_ID','AGWINTERM_WINDOW_ID','AGWINTERM_PIPE'){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
Start-Transcript -LiteralPath (Join-Path $artifact 'supervisor.log')|Out-Null
try {
    if($env:AI_HUB -and [IO.Path]::GetFullPath($env:AI_HUB).TrimEnd('\')-ine 'C:\Users\boris\AI'){throw 'Do not redirect the canonical suite token store'}
    if(Test-Path -LiteralPath $hub){
        if([string]::IsNullOrWhiteSpace($TokenOwner)){throw 'Local suites require -TokenOwner (actual agent identity)'}
        try{
            $raw=& python $hub acquire --owner $TokenOwner --run ('lite-suite-'+$run) --worktree $root --holder-pid $PID --purpose 'Owned isolated Lite integration suites'
            $acquireExit=$LASTEXITCODE
            $state=$raw|ConvertFrom-Json
            if($state.ok-isnot [bool]){throw 'Malformed canonical acquisition response'}
            if($state.ok){
                if($state.held-isnot [bool] -or -not $state.held -or
                   $state.owner-isnot [string] -or $state.owner-cne $TokenOwner -or
                   $state.run_id-isnot [string] -or $state.run_id-cne ('lite-suite-'+$run) -or
                   $state.token-isnot [string] -or $state.token-cnotmatch '\A[0-9a-f]{64}\z' -or
                   ($state.generation-isnot [int] -and $state.generation-isnot [long]) -or $state.generation-lt 1 -or
                   $state.worktree-isnot [string] -or [string]::IsNullOrWhiteSpace($state.worktree) -or
                   [IO.Path]::GetFullPath($state.worktree).TrimEnd('\','/')-ine [IO.Path]::GetFullPath($root).TrimEnd('\','/')){
                    throw 'Incomplete or mismatched canonical acquisition receipt; do not launch'
                }
            }
        }catch{
            $cleanup=$false # malformed identity cannot authorize release; retain evidence if storage permits
            try{$raw|Set-Content -LiteralPath (Join-Path $artifact 'acquisition.raw.json')}catch{}
            throw
        }
        # Establish ownership in memory before ANY fallible artifact write. A storage failure
        # before launch then releases this valid unused lease from finally instead of losing it.
        if($state.ok){$lease=$state}
        $raw|Set-Content -LiteralPath (Join-Path $artifact 'acquisition.raw.json')
        if(-not $state.ok){throw "Suite token unavailable: $raw"}
        $receipt=Join-Path $artifact 'lease.json'
        $lease|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $receipt
        # A complete receipt can be the only supported recovery handle. Preserve it before
        # classifying contradictory process status; retain the lease without launching/releasing.
        if($acquireExit-ne 0){$cleanup=$false;throw 'Canonical helper returned conflicting status; receipt retained for recovery'}
        $env:AGLITETERM_TEST_RECEIPT=$receipt
    }elseif($env:CI-ne 'true'){throw 'Canonical suite token helper unavailable'}
    . "$PSScriptRoot/suite-job.ps1"
    if($env:AGLITETERM_TEST_RUN){throw 'Nested test supervisors are not supported'}
    . "$PSScriptRoot/ctl-path.ps1"
    $realCtl=Get-CtlPath
    if(-not $realCtl){throw 'The real agwintermctl is required'}
    & "$PSScriptRoot/build-suite-ctl.ps1" -Output $artifact
    $env:AGLITETERM_TEST_CTL=Join-Path $artifact 'suite-ctl.exe'
    $env:AGLITETERM_TEST_REAL_CTL=[IO.Path]::GetFullPath($realCtl)
    . "$PSScriptRoot/suite-registry.ps1"
    $key=[LiteSuiteRegistry]::Create($run);$registryCreated=$true
    try{$key.SetValue('SupervisorOwner',$ownerNonce,[Microsoft.Win32.RegistryValueKind]::String)}finally{$key.Dispose()}
    $env:AGLITETERM_TEST_RUN=$run
    $profile=Join-Path $artifact 'profile';New-Item -ItemType Directory -Path $profile|Out-Null
    $env:LOCALAPPDATA=$profile
    foreach($name in 'AGWINTERM_SESSION_ID','AGWINTERM_PANE_ID','AGWINTERM_WINDOW_ID','AGWINTERM_PIPE'){[Environment]::SetEnvironmentVariable($name,$null)}
    foreach($name in $Suite){
        $env:AGLITETERM_TEST_JOB='Local\agliteterm-suite-'+$run+'-'+[guid]::NewGuid().ToString('N')
        $log=Join-Path $artifact ($name+'.log');$job=[LiteSuiteJob]::new();$code=2
        try{
            $args_='-NoProfile -File "'+$PSScriptRoot+'/invoke-suite.ps1" -Suite "'+$name+'" -Exe "'+$Exe+'" -Log "'+$log+'"'+$(if($Strict){' -Strict'}else{''})
            $job.Start($env:AGLITETERM_TEST_JOB,(Join-Path $PSHOME 'pwsh.exe'),$args_,$root)
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while(-not $job.Wait(1000)){if($watch.Elapsed.TotalMinutes-ge 30){throw 'Suite deadline exceeded; clipboard/cleanup state requires recovery'}}
            $code=$job.ExitCode()
            if($code-notin 0,1){$cleanup=$false}
        }catch{$cleanup=$false;throw}
        finally{
            try{$job.Finish();$job=$null;"Owned job for $name has zero descendants"}catch{$cleanup=$false;throw}
        }
        if(Test-Path -LiteralPath $log){Get-Content -LiteralPath $log|Write-Host}
        if($code-ne 0){$failed+=$name}
        if($code-notin 0,1){throw "Suite $name exited with unproven cleanup ($code); no further children launched"}
    }
}catch{$failed+='supervisor';"FAILED: $($_.Exception.Message)"}
finally{
    if($job){try{$job.Finish();$job=$null}catch{$cleanup=$false;"Owned job cleanup incomplete: $_"}}
    if($registryCreated -and -not $job){
        try{
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryRoot)
            try{if(-not $key -or $key.GetValue('SupervisorOwner')-cne $ownerNonce){throw 'Private registry ownership marker changed'}}finally{if($key){$key.Dispose()}}
            if($registryRoot-cne ('Software\agliteterm-tests\'+$run) -or $run-cnotmatch '\A[0-9a-f]{32}\z'){throw 'Private registry target validation failed'}
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryRoot,$false)
            'Removed only this run private registry namespace; personal preference keys were not targeted.'
        }catch{$cleanup=$false;"Private registry cleanup incomplete: $_"}
    }
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    if($lease -and $cleanup){
        try{
            $raw=& python $hub release --owner $lease.owner --token $lease.token --cleanup-confirmed
            $releaseExit=$LASTEXITCODE
            $raw|Set-Content -LiteralPath (Join-Path $artifact 'release.json')
            $state=$raw|ConvertFrom-Json
            if($releaseExit-ne 0 -or $state.ok-isnot [bool] -or -not $state.ok -or
               $state.held-isnot [bool] -or $state.held -or
               ($state.released_generation-isnot [int] -and $state.released_generation-isnot [long]) -or
               $state.released_generation-ne $lease.generation){$cleanup=$false}
        }catch{$cleanup=$false;"Canonical lease release is unproven: $_"}
    }
    "Lite suite supervisor: failed=$($failed-join ','); cleanup=$cleanup; artifacts=$artifact"
    Stop-Transcript|Out-Null
}
if(-not $cleanup){exit 2};if($failed.Count){exit 1};'all requested lite checks passed';exit 0
