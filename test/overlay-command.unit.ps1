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
    @{command='Write-Output ($c+$q+$e+$b)';profile='$c=''C'';$q=''Q'';$e=''E'';$b=''B''';code=0;text='CQEB';exact='CQEB'},
    @{command='return $c';profile='$c=''profile-return''';code=0;text='profile-return';exact='profile-return'},
    @{command='return $c';profile='New-Variable -Name c -Value 91 -Option AllScope';code=0;text='91';exact='91'},
    @{command='Write-Output $c';profile='New-Variable -Name c -Value 91 -Option AllScope';code=0;text='91';exact='91'},
    @{command='cmd.exe /d /c exit 7';profile='New-Variable -Name q -Value $false -Option AllScope';code=7;text=''},
    @{command='$e="";$b="";$q=$false;$c=91;Write-Output COLLISION';code=0;text='COLLISION'},
    @{command='Write-Output "quoted ☃" # trailing comment';code=0;text='quoted'},
    @{command='"dangling';code=1;text='';error='terminator'},
    @{command='throw "intentional failure"';code=1;text='';error='intentional failure'},
    @{command='$ErrorActionPreference="Stop";Write-Error "terminating cmdlet"';code=1;text='';error='terminating cmdlet'},
    @{command='return';code=0;text=''},
    @{command='return 0';code=0;text='0'},
    @{command='Write-Output trailing-backtick`';code=0;text='trailing-backtick';exact='trailing-backtick'},
    @{command='Write-Error "failure" -ErrorAction Continue';code=1;text=''},
    @{command='Write-Error "failure" -ErrorAction Continue; return';code=1;text=''},
    @{command='Write-Error "failure" -ErrorAction Continue; return 42';code=1;text='42'},
    @{command='Write-Error "failure" -ErrorAction Continue; Write-Output recovered; return';code=0;text='recovered'},
    @{command='cmd.exe /d /c exit 7; return';code=7;text=''},
    @{command='using namespace System.Text; [Encoding]::UTF8.WebName';code=0;text='utf-8';exact='utf-8'},
    @{command='param($x=42) $x';code=0;text='42';exact='42'},
    @{command='[CmdletBinding()]param($x=42) $x';code=0;text='42';exact='42'},
    @{command='param() Write-Error failure -ErrorAction Continue;return';code=1;text=''},
    @{command='begin {Write-Output BEGIN} process {Write-Output PROCESS} end {Write-Output END}';code=0;text='PROCESS'},
    @{command='end {Write-Output END} begin <# { #> {Write-Output BEGIN}';code=0;text='END'},
    @{command='dynamicparam { [Management.Automation.RuntimeDefinedParameterDictionary]::new() } end {42}';code=0;text='42';exact='42'},
    @{command='begin {} end {Write-Error failure -ErrorAction Continue;return}';code=1;text=''},
    @{command='begin {Write-Error failure -ErrorAction Continue} end {if(-not $?){throw "abort"}}';code=1;text='';error='abort'},
    @{command='begin {Write-Error failure -ErrorAction Continue} process {if(-not $?){throw "abort"}}';code=1;text='';error='abort'},
    @{command='process {Write-Error failure -ErrorAction Continue} end {if(-not $?){throw "abort"}}';code=1;text='';error='abort'},
    @{command='end {if(-not $?){throw "abort"}} begin {Write-Error failure -ErrorAction Continue}';code=1;text='';error='abort'},
    @{command='begin {Write-Error failure -ErrorAction Continue} end {}';code=1;text=''},
    @{command='param($x=$(cmd.exe /d /c exit 7))';code=7;text=''},
    @{command='param($x=$(cmd.exe /d /c exit 0))';code=0;text=''},
    @{command='param($x=$(cmd.exe /d /c exit 7)) end {}';code=7;text=''},
    @{command='end {42} clean {"discarded"}';code=0;text='42';exact='42';ps7=$true},
    @{command='end {Write-Error failure -ErrorAction Continue} clean {if(-not $?){throw "abort"}}';code=1;text='';error='abort';ps7=$true},
    @{command='end {cmd.exe /d /c exit 7} clean {}';code=7;text='';ps7=$true},
    @{command='trap {continue}; throw "handled"';code=1;text=''},
    @{command='param()';code=0;text=''},
    @{command='using namespace System.Text';code=0;text=''},
    @{command='cmd.exe /d /c exit 7';code=7;text=''},
    @{command='Write-Output ordinary';code=0;text='ordinary'}
    @{command=('Write-Output ''LONG-CONTEXT-OK''; # '+('context '*80));code=0;text='LONG-CONTEXT-OK';fits=$true}
)
$checks=0
foreach($shell in $shells){foreach($case in $cases){
    if($case.ps7 -and [IO.Path]::GetFileName($shell)-ine 'pwsh.exe'){continue}
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
        # Windows PowerShell wraps formatted errors at the host width; compare words, not layout.
        if($case.error -and -not ([regex]::Replace($errors,'\s+',' ')).Contains($case.error)){throw "Diagnostic missing: $errors"}
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
