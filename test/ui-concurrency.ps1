# Real concurrent control clients plus sidebar paints; isolated supervisor only, no clipboard/input.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict)
$ErrorActionPreference='Stop';$PSNativeCommandUseErrorActionPreference=$false
. "$PSScriptRoot/suite-context.ps1"
Assert-LiteSuiteContext
. "$PSScriptRoot/owned-window.ps1"
Add-Type -Path "$PSScriptRoot/ui-concurrency.cs"
$profile=Join-Path $env:LOCALAPPDATA ('ui-concurrency-'+[guid]::NewGuid().ToString('N'))
$appDir=Join-Path $profile 'agliteterm';New-Item -ItemType Directory -Path $appDir|Out-Null
@{default='SafeCmd';profiles=@(@{name='SafeCmd';command='cmd.exe';args=@('/d','/q')})}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $appDir 'profiles.json')
$name='ui-concurrency';$pipe=Get-LiteTestPipe $name;$proc=$null;$failed=$false
try {
    $proc=Start-Process $Exe -ArgumentList @('--pipe',$name,'--no-restore') -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$profile}
    [void]$proc.SafeHandle
    $null=Get-OwnedLiteWindow $proc -Show # exact launched frame, SW_SHOWNOACTIVATE only
    $ready=$false
    for($i=0;$i-lt 60;$i++){
        try{$null=[LiteConcurrencyProbe]::Call($pipe,'ping','',$null);$ready=$true;break}catch{if($proc.HasExited){throw};Start-Sleep -Milliseconds 100}
    }
    if(-not $ready){throw 'Owned concurrency window control did not become ready'}
    $count=[LiteConcurrencyProbe]::Run($pipe)
    if($count-lt 100){throw "Too few concurrency checks: $count"}
    "UI concurrency: $count checks passed; three mutation clients and a tree reader, no clipboard or foreground transfer"
}catch{$failed=$true;"UI concurrency FAILED: $_"}
finally{
    if($proc){
        if(-not $proc.HasExited){[void]$proc.CloseMainWindow()}
        if(-not $proc.WaitForExit(5000)){$proc.Kill();if(-not $proc.WaitForExit(10000)){throw 'Owned concurrency frame did not exit'}}
        $proc.Dispose()
    }
}
if($failed){exit 1};exit 0
