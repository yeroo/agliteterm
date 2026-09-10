param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict)
$ErrorActionPreference='Stop';$PSNativeCommandUseErrorActionPreference=$false
. "$PSScriptRoot/suite-context.ps1";Assert-LiteSuiteContext
. "$PSScriptRoot/owned-window.ps1"
Add-Type -Path "$PSScriptRoot/omp-idle.cs"
$profile=Join-Path $env:LOCALAPPDATA ('omp-idle-'+[guid]::NewGuid().ToString('N'))
$appDir=Join-Path $profile 'agliteterm';$toolDir=Join-Path $profile 'tool'
New-Item -ItemType Directory -Path $appDir,$toolDir|Out-Null
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$PSScriptRoot/omp-live-tool.cpp`" /Fe:`"$toolDir/oh-my-posh.exe`" /Fo:`"$toolDir/omp-live-tool.obj`""
if($LASTEXITCODE-ne 0){throw 'OMP live fake tool compile failed'}
$receipt=Join-Path $profile 'applied.txt';$completed=Join-Path $profile 'completed.txt';$draftSink=Join-Path $profile 'draft-must-not-run.txt'
$theme=Join-Path $profile "test's theme.omp.json";[IO.File]::WriteAllText($theme,'{}')
$asset=Join-Path (Split-Path ([IO.Path]::GetFullPath($Exe))) 'agliteterm-prompt.ps1'
function Literal([string]$s){return "'"+$s.Replace("'","''")+"'"}
$setup="Import-Module PSReadLine; Set-PSReadLineOption -HistorySaveStyle SaveNothing -HistorySavePath $(Literal (Join-Path $profile 'history.txt')); `$env:PATH=$(Literal $toolDir)+';'+`$env:PATH; `$env:AGLITE_OMP_LIVE_RECEIPT=$(Literal $receipt); `$env:AGLITE_OMP_LIVE_MODE='slow'; function global:prompt {'OMP-BASELINE> '}; . $(Literal $asset)"
$setup='$VerbosePreference="Continue"; '+$setup
$setup="`$env:AGLITE_OMP_DRAFT=$(Literal $draftSink); "+$setup
$pwsh=(Get-Command pwsh -ErrorAction Stop).Source
@{default='SafeOmp';profiles=@(@{name='SafeOmp';command=$pwsh;args=@('-NoLogo','-NoProfile','-NoExit','-Command',$setup);cwd=$profile})}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $appDir 'profiles.json')
$pipe=Get-LiteTestPipe 'omp-idle';$proc=$null;$pending=$null;$failed=$false;$checks=0
function Rpc([string]$cmd,[hashtable]$fields=@{},[string]$target=''){
    $reply=[LiteOmpOracle]::Call($pipe,$cmd,$target,($fields|ConvertTo-Json -Compress)).GetRawText()|ConvertFrom-Json
    if(-not $reply.ok){throw "$cmd refused: $($reply.error)"};return $reply.result
}
function Check([bool]$ok,[string]$what){if(-not $ok){throw $what};$script:checks++}
function Wait-For([scriptblock]$condition){for($i=0;$i-lt 80;$i++){if(& $condition){return};Start-Sleep -Milliseconds 100};throw 'Owned OMP condition timed out'}
try {
    $proc=Start-Process $Exe -ArgumentList @('--pipe','omp-idle','--no-restore') -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$profile;APPDATA=$profile}
    [void]$proc.SafeHandle;$null=Get-OwnedLiteWindow $proc -Show
    $id=[string](Rpc 'tree').workspaces[0].sessions[0].id
    Wait-For {@((Rpc 'events').events|Where-Object {$_.type-eq 'omp.ready' -and $_.session-eq $id}).Count-gt 0}
    Check (-not(Test-Path $receipt)) 'Tool applied before a request'
    $answer=Rpc 'omp.set' @{name=$theme;persist=$true} $id
    Check ($answer-match 'theme applied' -and [IO.File]::ReadAllText($receipt)-ceq $theme) 'Exact theme not applied in idle reader'
    Check ((Rpc 'config.get' @{key='omp-theme'})-ceq $theme) 'Successful application not persisted'
    $null=Rpc 'session.type' @{text="[IO.File]::WriteAllText($(Literal $completed),'done')`r"} $id
    Wait-For {Test-Path $completed}
    $answer=Rpc 'omp.set' @{name=$theme} $id
    Check ($answer-match 'theme applied') 'Completed prior input incorrectly prohibits live switching'
    $failedTheme=Join-Path $profile 'must-not-apply.omp.json';[IO.File]::WriteAllText($failedTheme,'{}')
    $failureReady=Join-Path $profile 'failure-ready.txt'
    $null=Rpc 'session.type' @{text="`$env:AGLITE_OMP_LIVE_MODE='fail';[IO.File]::WriteAllText($(Literal $failureReady),'done')`r"} $id
    Wait-For {Test-Path $failureReady}
    $refusal=[LiteOmpOracle]::Call($pipe,'omp.set',$id,(@{name=$failedTheme;persist=$true}|ConvertTo-Json -Compress)).GetRawText()|ConvertFrom-Json
    Check (-not $refusal.ok -and $refusal.error-match 'failed at native') 'Native failure was reported as application success'
    Check ([IO.File]::ReadAllText($receipt)-ceq $theme) 'Failed native tool output was evaluated'
    Check ((Rpc 'config.get' @{key='omp-theme'})-ceq $theme) 'Failed initialization changed persisted theme'
    $draft="[IO.File]::WriteAllText(`$env:AGLITE_OMP_DRAFT,'BAD'); "
    $null=Rpc 'session.type' @{text=$draft} $id
    Start-Sleep -Milliseconds 150
    $refusal=[LiteOmpOracle]::Call($pipe,'omp.set',$id,(@{name=$theme;persist=$true}|ConvertTo-Json -Compress)).GetRawText()|ConvertFrom-Json
    Check (-not $refusal.ok -and $refusal.error-match 'empty editing buffer was not acknowledged') 'Draft did not refuse unambiguously'
    Check (-not(Test-Path $draftSink)) 'Single-line separator draft was submitted'
    $null=Rpc 'session.type' @{text=[string][char]3;'allow-control'=$true} $id
    Start-Sleep -Milliseconds 300
    $gateReady=Join-Path $profile 'gate-ready.txt'
    $null=Rpc 'session.type' @{text="`$env:AGLITE_OMP_LIVE_MODE='gate';[IO.File]::WriteAllText($(Literal $gateReady),'done')`r"} $id
    Wait-For {Test-Path $gateReady}
    $pending=[LiteOmpOracle]::Begin($pipe,'omp.set',$id,(@{name=$theme}|ConvertTo-Json -Compress))
    Wait-For {Test-Path ($receipt+'.entered')}
    $null=Rpc 'session.type' @{text=$draft} $id
    [IO.File]::WriteAllText($receipt+'.release','release')
    $concurrent=$pending.GetAwaiter().GetResult().GetRawText()|ConvertFrom-Json;$pending=$null
    Check (-not(Test-Path $draftSink)) 'Concurrent input was submitted by initialization'
    Check ($concurrent.ok) 'Claimed initialization failed with concurrently queued input'
    Wait-For {(Rpc 'session.text' @{} $id).Contains($draft.TrimEnd())}
    Check (-not(Test-Path $draftSink)) 'Queued draft was lost or executed'
    $null=Rpc 'session.type' @{text=[string][char]3;'allow-control'=$true} $id
    $null=Rpc 'session.readonly' @{op='on'} $id
    $refusal=[LiteOmpOracle]::Call($pipe,'omp.set',$id,(@{name=$theme}|ConvertTo-Json -Compress)).GetRawText()|ConvertFrom-Json
    Check (-not $refusal.ok -and $refusal.error-match 'writable') 'Readonly request was accepted'
    "OMP idle: $checks checks passed; real PSReadLine, native fake OMP, no foreground or clipboard"
}catch{$failed=$true;"OMP idle FAILED: $_";if($id){try{Rpc 'session.text' @{} $id}catch{}}}
finally{
    if($pending -and -not(Test-Path ($receipt+'.release'))){[IO.File]::WriteAllText($receipt+'.release','cleanup release')}
    if($pending){try{$null=$pending.GetAwaiter().GetResult()}catch{}}
    if($proc){if(-not $proc.HasExited){[void]$proc.CloseMainWindow()};if(-not $proc.WaitForExit(5000)){$proc.Kill();if(-not $proc.WaitForExit(10000)){throw 'Owned OMP frame did not exit'}};$proc.Dispose()}
}
if($failed){exit 1};exit 0
