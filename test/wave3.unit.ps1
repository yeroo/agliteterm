# NLS/model checks only: no GUI or shared-state mutation.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC C++ tools are required'}
$out=Join-Path $repo 'bin/wave3-unit';New-Item -ItemType Directory -Force $out|Out-Null
$source=Join-Path $PSScriptRoot 'wave3.unit.cpp';$testExe=Join-Path $out 'wave3-unit.exe'
$compile="`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$source`" /Fe:`"$testExe`" /Fo:`"$out/wave3-unit.obj`""
& cmd /c $compile
if($LASTEXITCODE-ne 0){throw 'wave3 unit compile failed'}
& $testExe
if($LASTEXITCODE-ne 0){throw 'wave3 model checks failed'}
