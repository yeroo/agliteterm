param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $OutputDirectory|Out-Null
$vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC tools required for fake agent'}
$source=Join-Path $PSScriptRoot 'fake-claude.cpp'
& cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$source`" /Fe:`"$OutputDirectory\claude.exe`" /Fo:`"$OutputDirectory\fake-claude.obj`""
if($LASTEXITCODE -ne 0){throw 'fake Claude compile failed'}
