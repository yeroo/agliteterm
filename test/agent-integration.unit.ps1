param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC C++ tools required'}
$out=Join-Path $repo 'bin/agent-integration-unit';New-Item -ItemType Directory -Force $out|Out-Null
$source=Join-Path $PSScriptRoot 'agent-integration.unit.cpp';$testExe=Join-Path $out 'agent-integration-unit.exe'
& cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$source`" /Fe:`"$testExe`" /Fo:`"$out\agent-integration-unit.obj`""
if($LASTEXITCODE -ne 0){throw 'agent integration unit compile failed'}
& $testExe
if($LASTEXITCODE -ne 0){throw 'agent integration unit checks failed'}
