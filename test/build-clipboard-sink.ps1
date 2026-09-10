param([string]$Output)
$ErrorActionPreference='Stop'
if(-not $Output){throw 'Private sink output directory required'}
New-Item -ItemType Directory -Path $Output -Force|Out-Null
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required for native no-interpreter clipboard sink'}
$source=Join-Path $PSScriptRoot 'clipboard-sink.cpp'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$source`" /Fe:`"$Output/clipboard-sink.exe`" /Fo:`"$Output/clipboard-sink.obj`""
if($LASTEXITCODE-ne 0){throw 'Native clipboard sink compile failed'}
