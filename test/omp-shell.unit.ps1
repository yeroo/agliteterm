param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$out=Join-Path $repo 'bin/omp-shell-unit';New-Item -ItemType Directory -Force $out|Out-Null
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$tool=Join-Path $out 'oh-my-posh.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 /D_CRT_SECURE_NO_WARNINGS `"$PSScriptRoot/omp-tool-stub.cpp`" /Fe:`"$tool`" /Fo:`"$out/omp-tool-stub.obj`""
if($LASTEXITCODE-ne 0){throw 'OMP fake tool compile failed'}
$body=@'
$ErrorActionPreference='Stop'
$global:__agliteOmpSupported=$false
. '__OMP__'
$global:__aglitePromptAsset='__PROMPT__';$global:__agwLiteReadLine={};$global:__agwLiteWrap=$true
function global:Get-Command {param($Name,$CommandType,$ErrorAction) if($Name-cne 'oh-my-posh'){throw 'Unexpected discovery'};[pscustomobject]@{Source='__TOOL__'};[pscustomobject]@{Source='C:\must-not-use-second-PATH-entry.exe'}}
function global:Test-AgLiteOmpIdle {return $global:idle}
function global:Invoke-AgLiteOmpRequest {
    param($Op,$Extra)
    $global:requests.Add($Op)
    if($Op-eq 'omp-claim'){return @{ok=$true;result=($global:offer|ConvertTo-Json -Compress)}}
    if($Op-eq 'omp-result'){$global:reported=$Extra.success;return @{ok=$true}}
    throw 'Unexpected bridge mutation'
}
$checks=0
foreach($verbose in 'SilentlyContinue','Stop'){$VerbosePreference=$verbose
foreach($prior in $true,$false){foreach($mode in 'same','change','fail','error','draft','expired','late','duplicate'){
    $global:idle=$mode-ne 'draft';$global:ompApplied=0;$global:reported=$null
    $global:requests=[Collections.Generic.List[string]]::new()
    $global:offer=@{lease=[guid]::NewGuid().ToString('D');path="C:\test's theme.omp.json";deadline=[Environment]::TickCount64+30000}
    if($mode-eq 'expired'){$global:offer.deadline=[Environment]::TickCount64-1}
    if($mode-eq 'late'){$global:offer.deadline=[Environment]::TickCount64+500}
    $global:__agliteOmpExecuted=if($mode-eq 'duplicate'){$global:offer.lease}else{''}
    $env:AGLITE_OMP_UNIT_MODE=$mode
    function global:prompt {'ORIGINAL'}
    $beforePrompt=$function:prompt;$global:LASTEXITCODE=37
    $beforeErrors=@($global:Error)
    if($prior){$null=$true}else{Microsoft.PowerShell.Utility\Write-Error 'prior user error' -ErrorAction Ignore}
    Invoke-AgLiteOmpIdle
    if($LASTEXITCODE-ne 37 -or $global:Error.Count-ne $beforeErrors.Count){throw "Status/error history changed: $mode"};$checks++
    for($i=0;$i-lt $beforeErrors.Count;$i++){if(-not [object]::ReferenceEquals($beforeErrors[$i],$global:Error[$i])){throw 'Error identity changed'}};$checks++
    $applied=$mode-in 'same','change'
    if($global:ompApplied-ne [int]$applied){throw "Unexpected execution: $mode"};$checks++
    if($mode-eq 'draft'){if($global:requests.Count-ne 0){throw 'Draft contacted bridge'}}
    elseif($mode-eq 'duplicate'){if($global:requests.Count-ne 1){throw 'Duplicate sent result or applied'}}
    elseif($global:reported-ne $applied -or $global:requests.Count-ne 2){throw "Wrong result: $mode"};$checks++
    if($mode-ne 'change' -and -not [object]::ReferenceEquals($beforePrompt,$function:prompt)){throw "Unchanged prompt rewrapped: $mode"};$checks++
    if($mode-eq 'change' -and $global:__agwLiteP.ToString()-notmatch 'OMP-CHANGED'){throw 'New prompt not wrapped'};$checks++
}}}
"OMP shell handler: $checks checks passed; native fake tool, no shell host/profile/clipboard"
'@
$body=$body.Replace('__OMP__',(Join-Path $repo 'assets/agliteterm-omp.ps1').Replace("'","''")).Replace('__PROMPT__',(Join-Path $repo 'assets/agliteterm-prompt.ps1').Replace("'","''")).Replace('__TOOL__',$tool.Replace("'","''"))
$shell=(Get-Command pwsh -ErrorAction Stop).Source
$start=[Diagnostics.ProcessStartInfo]::new($shell);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
$child=[Diagnostics.Process]::Start($start)
try{
    $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(30000)){throw 'Private OMP fixture deadline exceeded'}
    $stdout.Result
    if($child.ExitCode-ne 0){throw $stderr.Result}
}finally{
    if(-not $child.HasExited){$child.Kill();if(-not $child.WaitForExit(5000)){throw 'Owned OMP fixture failed to exit'}}
    $child.Dispose()
}
