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
$pipe=Get-LiteTestPipe 'omp-idle';$proc=$null;$otherProc=$null;$pending=$null;$failed=$false;$checks=0
$gateReceipt=$receipt
function Rpc([string]$cmd,[hashtable]$fields=@{},[string]$target=''){
    $reply=[LiteOmpOracle]::Call($pipe,$cmd,$target,($fields|ConvertTo-Json -Compress)).GetRawText()|ConvertFrom-Json
    if(-not $reply.ok){throw "$cmd refused: $($reply.error)"};return $reply.result
}
function Check([bool]$ok,[string]$what){if(-not $ok){throw $what};$script:checks++}
function Wait-For([scriptblock]$condition){for($i=0;$i-lt 80;$i++){if(& $condition){return};Start-Sleep -Milliseconds 100};throw 'Owned OMP condition timed out'}
function Set-ToolMode([string]$mode,[string]$tag){
    $script:gateReceipt=Join-Path $profile ($tag+'.txt')
    $ready=Join-Path $profile ($tag+'-ready.txt')
    $null=Rpc 'session.type' @{text="`$env:AGLITE_OMP_LIVE_MODE=$(Literal $mode);`$env:AGLITE_OMP_LIVE_RECEIPT=$(Literal $script:gateReceipt);[IO.File]::WriteAllText($(Literal $ready),'done')`r"} $id
    Wait-For {Test-Path $ready}
}
function Saved-Theme {
    # Read the actual suite-private shared value, not either window's cached configuration.
    return (Get-ItemProperty -LiteralPath ('Registry::HKEY_CURRENT_USER\'+(Get-LiteTestRegistryPath -RequireIsolation)) -Name OmpTheme).OmpTheme
}
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
    $null=Rpc 'session.type' @{text="`$VerbosePreference='Stop';`$env:AGLITE_OMP_LIVE_MODE='fail';[IO.File]::WriteAllText($(Literal $failureReady),'done')`r"} $id
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
    Set-ToolMode 'late' 'late-output'
    $cursor=(Rpc 'events').cursor
    $refusal=[LiteOmpOracle]::Call($pipe,'omp.set',$id,(@{name=$failedTheme;persist=$true}|ConvertTo-Json -Compress)).GetRawText()|ConvertFrom-Json
    Check (-not $refusal.ok -and $refusal.error-match 'outcome unknown') 'Overdue claimed initializer did not report unknown outcome'
    Wait-For {@((Rpc 'events' @{since="$cursor"}).events|Where-Object {$_.type-eq 'omp.theme' -and $_.info-match 'failed at before-apply'}).Count-gt 0}
    Check (-not(Test-Path $gateReceipt)) 'Late native output was evaluated'
    Check ((Saved-Theme)-ceq $theme) 'Late native output changed persisted theme'
    Set-ToolMode 'gate' 'policy-output'
    $pending=[LiteOmpOracle]::Begin($pipe,'omp.set',$id,(@{name=$failedTheme;persist=$true}|ConvertTo-Json -Compress))
    Wait-For {Test-Path ($gateReceipt+'.entered')}
    $null=Rpc 'session.readonly' @{op='on'} $id
    $null=Rpc 'session.readonly' @{op='off'} $id
    [IO.File]::WriteAllText($gateReceipt+'.release','release')
    $policy=$pending.GetAwaiter().GetResult().GetRawText()|ConvertFrom-Json;$pending=$null
    Check (-not $policy.ok -and $policy.error-match 'shell applied theme, but persistence refused') 'Restored readonly policy allowed stale persistence'
    Check ([IO.File]::ReadAllText($gateReceipt)-ceq $failedTheme) 'Policy test did not reach actual initialization'
    Check ((Saved-Theme)-ceq $theme) 'Policy ABA changed persisted theme'
    # A second real Lite process shares this suite's private registry, with an explicit safe profile.
    $otherPipe=Get-LiteTestPipe 'omp-other'
    $otherProc=Start-Process $Exe -ArgumentList @('--pipe','omp-other','--no-restore') -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$profile;APPDATA=$profile}
    [void]$otherProc.SafeHandle;$null=Get-OwnedLiteWindow $otherProc -Show
    $null=[LiteOmpOracle]::Call($otherPipe,'tree','', '{}')
    foreach($aba in $false,$true){
        if($aba){$null=Rpc 'config.set' @{key='omp-theme';value=$theme}}
        Set-ToolMode 'gate' ('competing-'+$aba)
        $pending=[LiteOmpOracle]::Begin($pipe,'omp.set',$id,(@{name=$failedTheme;persist=$true}|ConvertTo-Json -Compress))
        Wait-For {Test-Path ($gateReceipt+'.entered')}
        $other=[LiteOmpOracle]::Call($otherPipe,'config.set','',(@{key='omp-theme';value=$failedTheme}|ConvertTo-Json -Compress)).GetRawText()|ConvertFrom-Json
        Check $other.ok 'Competing window configuration failed'
        $expected=$failedTheme
        if($aba){
            $other=[LiteOmpOracle]::Call($otherPipe,'config.set','',(@{key='omp-theme';value=$theme}|ConvertTo-Json -Compress)).GetRawText()|ConvertFrom-Json
            Check $other.ok 'Competing window ABA restore failed';$expected=$theme
        }
        [IO.File]::WriteAllText($gateReceipt+'.release','release')
        $competing=$pending.GetAwaiter().GetResult().GetRawText()|ConvertFrom-Json;$pending=$null
        Check (-not $competing.ok -and $competing.error-match 'persistence refused') 'Delayed save overwrote a competing process'
        Check ((Saved-Theme)-ceq $expected) 'Shared registry lost the newer window configuration'
    }
    $null=Rpc 'session.readonly' @{op='on'} $id
    $refusal=[LiteOmpOracle]::Call($pipe,'omp.set',$id,(@{name=$theme}|ConvertTo-Json -Compress)).GetRawText()|ConvertFrom-Json
    Check (-not $refusal.ok -and $refusal.error-match 'writable') 'Readonly request was accepted'
    "OMP idle: $checks checks passed; real PSReadLine, native fake OMP, no foreground or clipboard"
}catch{$failed=$true;"OMP idle FAILED: $_";if($id){try{Rpc 'session.text' @{} $id}catch{}}}
finally{
    if($pending -and -not(Test-Path ($gateReceipt+'.release'))){[IO.File]::WriteAllText($gateReceipt+'.release','cleanup release')}
    if($pending){try{$null=$pending.GetAwaiter().GetResult()}catch{}}
    foreach($owned in @($otherProc,$proc)){if($owned){if(-not $owned.HasExited){[void]$owned.CloseMainWindow()};if(-not $owned.WaitForExit(5000)){$owned.Kill();if(-not $owned.WaitForExit(10000)){throw 'Owned OMP frame did not exit'}};$owned.Dispose()}}
}
if($failed){exit 1};exit 0
