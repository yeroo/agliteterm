# Internal child of run-all's owned job; not a standalone desktop runner.
param([string]$Suite,[string]$Exe,[string]$Log,[switch]$Strict)
$ErrorActionPreference='Stop';$PSNativeCommandUseErrorActionPreference=$false
. "$PSScriptRoot/suite-context.ps1"
Assert-LiteSuiteContext
. "$PSScriptRoot/suite-policy.ps1"
Assert-LiteSuitePolicy @($Suite)
if($Suite-cnotmatch '\A[a-z0-9][a-z0-9.-]*\z'){throw 'Invalid suite name'}
$scriptPath=Join-Path $PSScriptRoot ($Suite+'.ps1')
Start-Transcript -LiteralPath $Log|Out-Null
$code=2
try {$global:LASTEXITCODE=0;& $scriptPath -Exe $Exe -Strict:$Strict;$code=$LASTEXITCODE}
catch {"Suite exception: $($_.Exception.Message)";$code=if($Suite-match '\.unit\z|^owned-procs-checks$|^clipboard-guard.tests$'){1}else{2}}
finally {Stop-Transcript|Out-Null}
exit $code
