# Private named pipes only; no pty host, GUI, clipboard, profile, registry, or shared test lease.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$main=Get-Content (Join-Path $repo 'src/main.cpp') -Raw
if($main -notmatch 'static auto& g_controlTransport = \*new control_transport::Transport;'){throw 'Transport must outlive detached workers'}
if($main -notmatch 'if \(out == ReqOutcome::NoReply \|\| g_control == INVALID_HANDLE_VALUE\) return HostHealth::Dead;'){throw 'Retired handshake channel must not fall back to HelloOnly'}
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$out=Join-Path $repo 'bin/control-transport-unit';New-Item -ItemType Directory -Force $out|Out-Null
$source=Join-Path $PSScriptRoot 'control-transport.unit.cpp';$testExe=Join-Path $out 'control-transport-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$source`" /Fe:`"$testExe`" /Fo:`"$out/control-transport-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'Control transport compile failed'}
$child=Start-Process -FilePath $testExe -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $out 'stdout.log') -RedirectStandardError (Join-Path $out 'stderr.log')
try{
    if(-not $child.WaitForExit(15000)){throw 'Private transport fixture exceeded deadline'}
    Get-Content (Join-Path $out 'stdout.log'),(Join-Path $out 'stderr.log')
    if($child.ExitCode-ne 0){throw 'Control transport tests failed'}
}finally{if(-not $child.HasExited){$child.Kill();if(-not $child.WaitForExit(5000)){throw 'Owned fixture failed to exit'}};$child.Dispose()}
