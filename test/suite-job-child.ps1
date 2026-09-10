param([string]$Job,[string]$Result)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/suite-job.ps1"
if(-not [LiteSuiteJob]::InNamedJob($Job)){exit 3}
$child=Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 60"' -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($Result,'owned-descendant-started')
$child.Dispose()
exit 9
