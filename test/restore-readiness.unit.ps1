param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'restore-matrix.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw $errors}
$function=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq 'Wait-ScreenMarker'},$true)
if(-not $function){throw 'Production readiness function missing'}
. ([scriptblock]::Create($function.Extent.Text))
$ctl='Readiness-FakeCli';$script:calls=0;$script:readyAfter=3;$script:code=0
function Readiness-FakeCli {
    if($args[0]-ne 'session' -or $args[1]-ne 'text'){throw 'Readiness must not type or mutate'}
    $script:calls++;$global:LASTEXITCODE=$script:code
    if($script:calls-ge $script:readyAfter){'ready-marker'}else{'not ready'}
}
$result=Wait-ScreenMarker 'private' 'pane' 'ready-marker' -PollMs 0
if(-not $result.Seen -or $script:calls-ne 3){throw 'Delayed marker was not observed through reads alone'}
$script:calls=0;$script:readyAfter=999
$result=Wait-ScreenMarker 'private' 'pane' 'ready-marker' -TimeoutMs 0 -PollMs 0
if($result.Seen -or $script:calls-ne 1 -or $result.Text-ne 'not ready'){throw 'Deadline must return last diagnostic without retrying input'}
$script:calls=0;$script:readyAfter=1;$script:code=1
$result=Wait-ScreenMarker 'private' 'pane' 'ready-marker' -TimeoutMs 0 -PollMs 0
if($result.Seen){throw 'A failed text command cannot prove readiness even if its error mentions the marker'}
'restore-readiness: 3 checks passed; no app or shared state touched'
exit 0
