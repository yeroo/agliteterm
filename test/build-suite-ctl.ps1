param([string]$Output)
$ErrorActionPreference='Stop'
if(-not $Output){throw 'Private output directory required'}
New-Item -ItemType Directory -Force -Path $Output|Out-Null
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required for namespace forwarding adapter'}
$source=Join-Path $PSScriptRoot 'suite-ctl.cpp';$out=Join-Path $Output 'suite-ctl.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 `"$source`" /Fe:`"$out`" /Fo:`"$Output/suite-ctl.obj`""
if($LASTEXITCODE-ne 0){throw 'Namespace forwarding adapter compile failed'}
