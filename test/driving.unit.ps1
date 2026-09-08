# Pure in-process cell/casing/field-codec checks: no terminal, host, GUI, clipboard or registry.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'MSVC C++ tools are required' }
$out = Join-Path $repo '.revmux/driving-unit'
New-Item -ItemType Directory -Force $out | Out-Null
$source = Join-Path $PSScriptRoot 'driving.unit.cpp'
$testExe = Join-Path $out 'driving-unit.exe'
$compile = "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 /DUNICODE /D_UNICODE `"$source`" /Fe:`"$testExe`" /Fo:`"$out\driving-unit.obj`" user32.lib"
& cmd /c $compile
if ($LASTEXITCODE -ne 0) { throw 'driving unit compile failed' }
& $testExe
if ($LASTEXITCODE -ne 0) { throw 'driving unit checks failed' }
