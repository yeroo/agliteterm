# Execute the actual CI gate and paste-sink expression with private redirected shells only.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$suite=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/selection-ui.ps1",[ref]$tokens,[ref]$errors)
if($errors){throw $errors}
$gate=$suite.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($ClipboardOnly -and')},$true)
if(-not $gate){throw 'Clipboard-only early gate missing'}
$gateBlock=[scriptblock]::Create($gate.Extent.Text)
$priorCi=$env:GITHUB_ACTIONS;$checks=0
try {
    foreach($case in @(@{ci='';hub=$false;deny=$true},@{ci='true';hub=$true;deny=$true},@{ci='true';hub=$false;deny=$false})){
        $env:GITHUB_ACTIONS=$case.ci;$ClipboardOnly=$true
        function Test-Path {param($LiteralPath) return $case.hub}
        $denied=$false;try{& $gateBlock}catch{$denied=$true}
        if($denied-ne $case.deny){throw 'Disposable-CI gate result wrong'}
        $checks++
    }
}finally{$env:GITHUB_ACTIONS=$priorCi;Remove-Item Function:/Test-Path}
$cases=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/clipboard-ui-cases.ps1",[ref]$tokens,[ref]$errors)
if($errors){throw $errors}
$assignment=$cases.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-ceq '$sink'},$true)
if(-not $assignment){throw 'Actual paste sink missing'}
$artifact=Join-Path ([IO.Path]::GetTempPath()) ('lite-paste-sink-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifact|Out-Null
$literal=(Join-Path $artifact 'result.txt').Replace("'","''")
. ([scriptblock]::Create($assignment.Extent.Text))
$shells=@((Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'),(Join-Path $PSHOME 'pwsh.exe'))
foreach($shell in $shells){foreach($inputCase in @(@{text='PASTED_OK';result='True'},@{text='PRIVATE-UNPROVEN-TEXT';result='False'},@{text="wrong`r`nWrite-Output SHOULD-NOT-EXECUTE";result='False'})){
    $file=Join-Path $artifact 'result.txt'
    if([IO.File]::Exists($file)){Remove-Item -LiteralPath $file}
    $start=[Diagnostics.ProcessStartInfo]::new($shell)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.Arguments='-NoProfile -NonInteractive -NoExit -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sink))
    $child=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        $child.StandardInput.WriteLine($inputCase.text);$child.StandardInput.Close()
        if(-not $child.WaitForExit(15000)){throw 'Private paste sink did not terminate'}
        if($child.ExitCode-ne 0 -or -not [IO.File]::Exists($file) -or [IO.File]::ReadAllText($file)-cne $inputCase.result){throw 'Paste sink did not record only the expected boolean'}
        if($stdout.Result.Contains('SHOULD-NOT-EXECUTE') -or $stdout.Result.Contains('PRIVATE-UNPROVEN-TEXT') -or $stderr.Result){throw 'Paste sink disclosed input or resumed shell execution'}
        $checks++
    }finally{if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(5000)};$child.Dispose()}
}}
Remove-Item -LiteralPath (Join-Path $artifact 'result.txt');Remove-Item -LiteralPath $artifact
"Clipboard acceptance: $checks private gate/sink checks passed; no clipboard or host access"
