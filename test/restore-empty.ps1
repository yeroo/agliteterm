# Narrow restore regression with a private NoProfile-equivalent cmd shell, never user PowerShell.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/suite-context.ps1";Assert-LiteSuiteContext
$privateProfile=Join-Path $env:LOCALAPPDATA ('restore-empty-'+[guid]::NewGuid().ToString('N'))
$appDir=Join-Path $privateProfile 'agliteterm';New-Item -ItemType Directory -Path $appDir|Out-Null
@{default='SafeCmd';profiles=@(@{name='SafeCmd';command='cmd.exe';args=@('/d','/q')})}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $appDir 'profiles.json')
$env:LOCALAPPDATA=$privateProfile
& "$PSScriptRoot/restore-matrix.ps1" -Exe $Exe -Strict:$Strict -Only guard-after-empty
exit $LASTEXITCODE
