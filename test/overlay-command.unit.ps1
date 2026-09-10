# The production C++ wrapper, executed in private no-profile shells; no terminal host or desktop.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC tools required'}
$out=Join-Path $repo 'bin/overlay-command-unit';New-Item -ItemType Directory -Force $out|Out-Null
$source=Join-Path $PSScriptRoot 'overlay-command.unit.cpp';$testExe=Join-Path $out 'overlay-command-unit.exe'
& cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$source`" /Fe:`"$testExe`" /Fo:`"$out\overlay-command-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'Overlay wrapper compile failed'}
$shells=@((Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'))
$pwsh=(Get-Command pwsh -ErrorAction SilentlyContinue).Source
if($pwsh){$shells+=$pwsh}elseif($Strict){throw 'PowerShell 7 required'}
$cases=@(
    @{command='Write-Output $s';profile='$s=''profile-visible''';code=0;text='profile-visible';exact='profile-visible'},
    @{command='$e="";$b="";$q=$false;$c=91;Write-Output COLLISION';code=0;text='COLLISION'},
    @{command='Write-Output "quoted ☃" # trailing comment';code=0;text='quoted'},
    @{command='"dangling';code=1;text='';error='terminator'},
    @{command='throw "intentional failure"';code=1;text='';error='intentional failure'},
    @{command='$ErrorActionPreference="Stop";Write-Error "terminating cmdlet"';code=1;text='';error='terminating cmdlet'},
    @{command='return';code=0;text=''},
    @{command='return 0';code=0;text='0'},
    @{command='Write-Output trailing-backtick`';code=0;text='trailing-backtick';exact='trailing-backtick'},
    @{command='Write-Error "failure" -ErrorAction Continue';code=1;text=''},
    @{command='cmd.exe /d /c exit 7';code=7;text=''},
    @{command='Write-Output ordinary';code=0;text='ordinary'}
    @{command=('Write-Output ''LONG-CONTEXT-OK''; # '+('context '*80));code=0;text='LONG-CONTEXT-OK';fits=$true}
)
$checks=0
foreach($shell in $shells){foreach($case in $cases){
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($case.command))
    $wrapper=& $testExe $encoded
    if($LASTEXITCODE-ne 0){throw 'Production wrapper generation or capacity checks failed'}
    if($wrapper.Contains('"')){throw 'Wrapper must survive the host quoted command argument'}
    if($case.fits -and [Text.Encoding]::UTF8.GetByteCount($wrapper)-ge 2048){throw 'Ordinary context-bearing command no longer fits the host argument'}
    # Keep -Command parsing (the real host mode), not a second -EncodedCommand that could hide quoting bugs.
    $start=[Diagnostics.ProcessStartInfo]::new($shell);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $prefix=if($case.profile){$case.profile+';'}else{''}
    $start.Arguments='-NoProfile -NonInteractive -Command "'+$prefix+$wrapper+'"'
    $child=[Diagnostics.Process]::Start($start)
    try{
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit(30000)){throw 'Private overlay fixture deadline exceeded'}
        $text=$stdout.Result;$errors=$stderr.Result;$esc=[string][char]27;$bel=[string][char]7
        if(-not $text.Contains($esc+']133;A'+$bel+$esc+']133;C'+$bel)){throw 'Missing wrapper start marks'}
        if(-not $text.Contains($esc+']133;D;'+$case.code+$bel)){throw "Wrong wrapper exit for $($case.command): stdout=$text stderr=$errors"}
        if($case.text -and -not $text.Contains($case.text)){throw 'Command output changed'}
        if($case.error -and -not $errors.Contains($case.error)){throw "Diagnostic missing: $errors"}
        if($case.exact){
            $plain=[regex]::Replace($text,[regex]::Escape($esc)+']133;[^'+$bel+']*'+$bel,'').Trim()
            if($plain-ne $case.exact){throw "Instrumentation leaked into command output: $plain"}
        }
        $checks++;"PASS $([IO.Path]::GetFileName($shell)): $($case.command)"
    }finally{
        if(-not $child.HasExited){$child.Kill();if(-not $child.WaitForExit(5000)){throw 'Owned fixture did not exit'}}
        $child.Dispose()
    }
}}
"overlay wrapper: $checks private shell cases passed; argument capacity boundaries passed"
