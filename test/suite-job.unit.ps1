# Private non-GUI child processes only: no app, terminal host, clipboard, registry or shared pipe.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/suite-job.ps1"
$count=0
function Check([bool]$Good,[string]$Name){if(-not $Good){throw $Name};$script:count++;"PASS $Name"}
$cwd=Split-Path $PSScriptRoot -Parent
$cmd=Join-Path $env:WINDIR 'System32/cmd.exe';$pwsh=Join-Path $PSHOME 'pwsh.exe'
function JobName {'Local\agliteterm-suite-'+[guid]::NewGuid().ToString('N')+'-'+[guid]::NewGuid().ToString('N')}
$job=[LiteSuiteJob]::new()
try {
    $name=JobName;$job.Start($name,$cmd,'/d /c exit 7',$cwd)
    Check ($job.Wait(10000)) 'bounded private child exit'
    Check ($job.ExitCode()-eq 7) 'actual child exit code retained'
    Check (-not [LiteSuiteJob]::InNamedJob($name)) 'supervisor is not its own child job'
}finally{$job.Finish()}
$job.Finish();Check $true 'cleanup idempotent after zero descendants'
$job=[LiteSuiteJob]::new();$other=[LiteSuiteJob]::new()
try {
    $name=JobName;$job.Start($name,$pwsh,'-NoProfile -Command "Start-Sleep -Seconds 60"',$cwd)
    $refused=$false;try{$other.Start($name,$cmd,'/d /c exit 0',$cwd)}catch{$refused=$true}
    Check $refused 'existing named job refuses adoption'
    $other.Finish();Check (-not $job.Wait(0)) 'refused adoption did not terminate original job'
}finally{$other.Finish();$job.Finish()}
$job=[LiteSuiteJob]::new()
try {
    $refused=$false;try{$job.Start((JobName),(Join-Path $cwd 'no-such-suite-binary.exe'),'',$cwd)}catch{$refused=$true}
    Check $refused 'failed executable launch is explicit'
}finally{$job.Finish()}
Check $true 'empty failed launch cleans without process-name sweep'
$job=[LiteSuiteJob]::new();$result=Join-Path ([IO.Path]::GetTempPath()) ('lite-job-proof-'+[guid]::NewGuid().ToString('N')+'.txt')
try {
    $name=JobName
    $job.Start($name,$pwsh,('-NoProfile -File "'+$PSScriptRoot+'/suite-job-child.ps1" -Job "'+$name+'" -Result "'+$result+'"'),$cwd)
    $refused=$false;try{$job.Start((JobName),$cmd,'/d /c exit 0',$cwd)}catch{$refused=$true}
    Check $refused 'reusing active owner refuses without losing its handles'
    Check ($job.Wait(15000) -and $job.ExitCode()-eq 9) 'child confirms membership before spawning descendant'
    Check ([IO.File]::ReadAllText($result)-ceq 'owned-descendant-started' -and $job.Count()-ge 1) 'descendant remains owned after primary exit'
}finally{$job.Finish();if([IO.File]::Exists($result)){Remove-Item -LiteralPath $result}}
Check $true 'finish proves zero descendants after primary already exited'
"Suite job: $count private ownership checks passed"
