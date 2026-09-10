param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$asset=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../assets/agliteterm-prompt.ps1'))
$shells=@((Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'))
$pwsh=(Get-Command pwsh -ErrorAction SilentlyContinue).Source
if($pwsh){$shells+=$pwsh}elseif($Strict){throw 'PowerShell 7 required for both-version status checks'}
$body=@'
$ErrorActionPreference='Stop'
$global:observed=$null;$global:readerCalls=0;$global:resumeOffer=$null
function global:PSConsoleHostReadLine {
    $status=$?
    $global:observed=@{status=$status;exit=$LASTEXITCODE;arg=$args[0]}
    $global:readerCalls++;'untouched user draft'
}
. '__ASSET__'
function global:Invoke-AgLiteBridgeRequest {Microsoft.PowerShell.Utility\Write-Error 'mock bridge error' -ErrorAction Ignore}
function global:Get-AgLiteResume {return $global:resumeOffer}
foreach($prior in $true,$false){foreach($resume in $false,$true){
    $global:resumeOffer=if($resume){'$global:mustNotExecute=1'}else{$null}
    $global:mustNotExecute=0;$global:observed=$null;$global:readerCalls=0;$global:LASTEXITCODE=37
    $before=$Error.Count
    if($prior){$null=$true}else{Microsoft.PowerShell.Utility\Write-Error 'previous user command failure' -ErrorAction Ignore}
    $result=PSConsoleHostReadLine 'opaque-argument'
    if($Error.Count-ne $before){throw 'Readline polluted error records'}
    if($LASTEXITCODE-ne 37){throw 'Readline changed actual native exit code'}
    if($global:mustNotExecute-ne 0){throw 'Reader executed a command'}
    if($resume){if($result-cne '$global:mustNotExecute=1' -or $global:readerCalls-ne 0){throw 'Resume entered draft reader or changed command'}}
    else{if($result-cne 'untouched user draft' -or $global:readerCalls-ne 1 -or $global:observed.status-ne $prior -or $global:observed.exit-ne 37 -or $global:observed.arg-cne 'opaque-argument'){throw ('Reader boundary changed: '+($global:observed|ConvertTo-Json -Compress))}}
    [Console]::WriteLine('PASS prior='+$prior+' resume='+$resume)
}}
'@
$body=$body.Replace('__ASSET__',$asset.Replace("'","''"))
foreach($shell in $shells){
    $start=[Diagnostics.ProcessStartInfo]::new($shell);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $child=[Diagnostics.Process]::Start($start)
    try{
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit(30000)){throw 'Private readline fixture deadline exceeded'}
        $stdout.Result
        if($child.ExitCode-ne 0){throw $stderr.Result}
    }finally{
        if(-not $child.HasExited){$child.Kill();if(-not $child.WaitForExit(5000)){throw 'Owned readline fixture failed to exit'}}
        $child.Dispose()
    }
}
"readline status: $($shells.Count*4) scenarios passed; no host, profile, draft, or shared-state changes"
