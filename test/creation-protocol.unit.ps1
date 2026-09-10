param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$out=Join-Path $repo 'bin/creation-protocol-unit';New-Item -ItemType Directory -Force $out|Out-Null
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$testExe=Join-Path $out 'creation-protocol-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 /DPB_FIELD_32BIT /I `"$repo/src/proto`" `"$PSScriptRoot/creation-protocol.unit.cpp`" /Fe:`"$testExe`" /Fo:`"$out/creation-protocol-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'Creation protocol fixture compile failed'}
& $testExe
if($LASTEXITCODE-ne 0){throw 'Creation protocol fixture failed'}
