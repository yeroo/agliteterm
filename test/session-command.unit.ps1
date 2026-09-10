# Production launch plans executed in private no-profile processes; no terminal/desktop access.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$root=Split-Path $PSScriptRoot -Parent
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC tools required'}
$out=Join-Path $root 'bin/session-command-unit';New-Item -ItemType Directory -Force $out|Out-Null
$testExe=Join-Path $out 'session-command-unit.exe';$source=Join-Path $PSScriptRoot 'session-command.unit.cpp'
& cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" && cl /nologo /EHsc /std:c++14 /W4 /utf-8 `"$source`" /Fe:`"$testExe`" /Fo:`"$out\unit.obj`" /link shell32.lib"
if($LASTEXITCODE-ne 0){throw 'Session command unit compile failed'}
& $testExe
if($LASTEXITCODE-ne 0){throw 'Session command checks failed'}
foreach($scenario in 0..3){
    $launch=(& $testExe $scenario)|ConvertFrom-Json
    if($LASTEXITCODE-ne 0){throw 'Could not build production launch'}
    $start=[Diagnostics.ProcessStartInfo]::new($launch.app)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    if($launch.app-eq 'powershell.exe'){$start.ArgumentList.Add('-NoProfile')}
    foreach($arg in $launch.args){$start.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($start)
    try{
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        if($scenario-lt 2){
            $child.StandardInput.WriteLine("Write-Output ('FOLLOWUP-'+'READY')")
            $child.StandardInput.WriteLine('exit 0');$child.StandardInput.Close()
        }
        if(-not $child.WaitForExit(20000)){throw 'Command fixture deadline exceeded'}
        $text=$stdout.Result;$errors=$stderr.Result
        if($scenario-lt 2){
            if(-not $text.Contains('COMMAND-READY') -or -not $text.Contains('FOLLOWUP-READY')){throw "Interactive follow-up missing: $text $errors"}
            if($scenario-eq 0 -and -not $text.Contains('quoted "value"')){throw "Quoting changed: $text"}
            if($scenario-eq 1 -and -not $errors.Contains('intentional failure')){throw "Diagnostic missing: $errors"}
            if($child.ExitCode-ne 0){throw 'Follow-up exit code changed'}
        }else{
            $expected=if($scenario-eq 2){7}else{9}
            if($child.ExitCode-ne $expected){throw "Wrong exit code: $($child.ExitCode)"}
        }
        "PASS actual launch scenario $scenario"
    }finally{
        if(-not $child.HasExited){$child.Kill($true);if(-not $child.WaitForExit(5000)){throw 'Owned fixture did not exit'}}
        $child.Dispose()
    }
}
