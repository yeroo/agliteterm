param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$out=Join-Path $repo 'bin/suite-ctl-unit'
& "$PSScriptRoot/build-suite-ctl.ps1" -Output $out
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$stub=Join-Path $out 'suite-ctl-stub.exe';$source=Join-Path $PSScriptRoot 'suite-ctl-stub.cpp'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 `"$source`" /Fe:`"$stub`" /Fo:`"$out/suite-ctl-stub.obj`""
if($LASTEXITCODE-ne 0){throw 'CLI stub compile failed'}
$adapter=Join-Path $out 'suite-ctl.exe';$run='0123456789abcdef0123456789abcdef';$prefix='agliteterm-test-'+$run+'-ctl-'
function Hex([string]$s){[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($s)).ToLowerInvariant()}
$checks=0
$cases=@(
    @{args=@('session','type','quote " Ω','', 'trailing\');expected=@('session','type','quote " Ω','','trailing\','--pipe',($prefix+'agliteterm'));code=7},
    @{args=@('--pipe','ordinary','ping');expected=@('--pipe',($prefix+'ordinary'),'ping');code=7},
    @{args=@('--pipe=\\.\pipe\ordinary','ping');expected=@(('--pipe='+$prefix+'ordinary'),'ping');code=7},
    @{args=@('ping');inherited=$prefix+'already';expected=@('ping','--pipe',($prefix+'already'));code=7},
    @{args=@('--socket','foreign');code=2},
    @{args=@('ping');run='../bad';code=2},
    @{args=@('ping');self=$true;code=2}
)
foreach($case in $cases){
    $start=[Diagnostics.ProcessStartInfo]::new($adapter);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    foreach($arg in $case.args){$start.ArgumentList.Add($arg)}
    $start.Environment['AGLITETERM_TEST_RUN']=$(if($case.run){$case.run}else{$run})
    $start.Environment['AGLITETERM_TEST_REAL_CTL']=$(if($case.self){$adapter}else{$stub})
    $start.Environment['AGWINTERM_PIPE']=[string]$case.inherited
    $child=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        # Refused cases may exit before any stdin write; those need no payload.
        if($case.code-eq 7){$child.StandardInput.Write("quote `" Ω`nnext line")}
        $child.StandardInput.Close()
        if(-not $child.WaitForExit(15000) -or $child.ExitCode-ne $case.code){throw 'Adapter exit/refusal mismatch'}
        if($case.code-eq 7){
            $expected=(@($case.expected|ForEach-Object{Hex $_})+@('STDIN',(Hex "quote `" Ω`nnext line")))-join "`n"
            if($stdout.Result.Replace("`r`n","`n").TrimEnd("`n")-cne $expected -or $stderr.Result.Trim()-cne 'stub stderr'){throw "Adapter argument/stdin/stdout/stderr mismatch: $($stdout.Result)"}
        }elseif($stdout.Result -or $stderr.Result){throw 'Refusal unexpectedly invoked the stub'}
        $checks++
    }finally{if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(5000)};$child.Dispose()}
}
"Suite CLI adapter: $checks private forwarding/refusal checks passed"
