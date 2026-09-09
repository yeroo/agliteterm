# Headless atomic state tests; no windows, token or shared settings.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$out=Join-Path $repo 'bin/ui-request-unit';New-Item -ItemType Directory -Force $out|Out-Null
$source=Join-Path $PSScriptRoot 'ui-request.unit.cpp';$testExe=Join-Path $out 'ui-request-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$source`" /Fe:`"$testExe`" /Fo:`"$out/ui-request-unit.obj`""
if($LASTEXITCODE -ne 0){throw 'UI request unit compile failed'}
& $testExe
if($LASTEXITCODE -ne 0){throw 'UI request unit tests failed'}
