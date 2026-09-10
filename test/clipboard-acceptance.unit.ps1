# Actual CI gate plus native sink fail-closed checks. Console echo/control proof is CI acceptance.
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
$out=Join-Path (Split-Path $PSScriptRoot -Parent) 'bin/clipboard-sink-unit'
& "$PSScriptRoot/build-clipboard-sink.ps1" -Output $out
$result=Join-Path $out ([guid]::NewGuid().ToString('N')+'.boolean')
foreach($withPath in $false,$true){
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $out 'clipboard-sink.exe'))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    if($withPath){$start.ArgumentList.Add($result)}
    $child=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync();$child.StandardInput.Close()
        if(-not $child.WaitForExit(15000) -or $child.ExitCode-ne 2 -or $stdout.Result -or $stderr.Result -or [IO.File]::Exists($result)){throw 'Native sink failed to refuse missing arguments/non-console input before readiness or output'}
        $checks++
    }finally{if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(5000)};$child.Dispose()}
}
"Clipboard acceptance: $checks private admission/no-console checks passed; actual ConPTY echo/control checks require disposable CI"
