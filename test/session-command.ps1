# Actual Lite session.new launch contract, only under the canonical owned-job supervisor.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/suite-context.ps1"
Assert-LiteSuiteContext
. "$PSScriptRoot/owned-window.ps1"
$commandArtifact=Join-Path $env:LOCALAPPDATA ('command-'+[guid]::NewGuid().ToString('N'))
$appDir=Join-Path $commandArtifact 'agliteterm';New-Item -ItemType Directory -Path $appDir|Out-Null
@{default='SafeCmd';profiles=@(@{name='SafeCmd';command='cmd.exe';args=@('/d','/q')})}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $appDir 'profiles.json')
$commandPipe=Get-LiteTestPipe 'command';$commandCtl=$env:AGLITETERM_TEST_REAL_CTL
$proc=$null;$failed=$false
function CommandRpc([string]$verb,$params,[string]$target,[switch]$AllowError){
    $client=[IO.Pipes.NamedPipeClientStream]::new('.',$commandPipe,[IO.Pipes.PipeDirection]::InOut)
    try{
        $client.Connect(1500)
        $writer=[IO.StreamWriter]::new($client);$writer.AutoFlush=$true;$reader=[IO.StreamReader]::new($client)
        $writer.WriteLine((@{cmd=$verb;args=$params;target=$target}|ConvertTo-Json -Compress -Depth 8))
        $read=$reader.ReadLineAsync();if(-not $read.Wait(15000)){throw 'Command RPC deadline exceeded'}
        $answer=$read.Result|ConvertFrom-Json
        if($AllowError){return $answer}
        if(-not $answer.ok){throw "$verb : $($answer.error)"};return $answer.result
    }finally{$client.Dispose()}
}
try{
    $proc=Start-Process $Exe -ArgumentList @('--pipe','command','--no-restore') -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$commandArtifact}
    [void]$proc.SafeHandle;$null=Get-OwnedLiteWindow $proc -Show
    $ready=$false
    for($try=0;$try-lt 60;$try++){
        try{$null=CommandRpc 'tree' @{} '';$ready=$true;break}catch{if($proc.HasExited){throw};Start-Sleep -Milliseconds 100}
    }
    if(-not $ready){throw 'Owned command window did not become ready'}
    . "$PSScriptRoot/session-command-cases.ps1"
}catch{$failed=$true;"Session command FAILED: $_"}
finally{
    if($proc){
        if(-not $proc.HasExited){[void]$proc.CloseMainWindow()}
        if(-not $proc.WaitForExit(5000)){$proc.Kill();if(-not $proc.WaitForExit(10000)){throw 'Owned command window did not exit'}}
        $proc.Dispose()
    }
}
if($failed){exit 1};exit 0
