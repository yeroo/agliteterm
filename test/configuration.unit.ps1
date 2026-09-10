# Pure key/codec/validation checks; no registry, clipboard, host or GUI.
param([string]$Exe = "$PSScriptRoot\..\bin\agliteterm.exe", [switch]$Strict)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'MSVC C++ tools are required' }
$out = Join-Path $repo 'bin/configuration-unit'
New-Item -ItemType Directory -Force $out | Out-Null
$source = Join-Path $PSScriptRoot 'configuration.unit.cpp'
$testExe = Join-Path $out 'configuration-unit.exe'
$compile = "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$source`" /Fe:`"$testExe`" /Fo:`"$out\configuration-unit.obj`""
& cmd /c $compile
if ($LASTEXITCODE -ne 0) { throw 'configuration unit compile failed' }
& $testExe
if ($LASTEXITCODE -ne 0) { throw 'configuration unit checks failed' }
& "$PSScriptRoot/omp-discovery.unit.ps1" -Strict:$Strict
& "$PSScriptRoot/omp-protocol.unit.ps1" -Strict:$Strict
& "$PSScriptRoot/omp-shell.unit.ps1" -Strict:$Strict
