param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$main=Get-Content "$repo/src/main.cpp" -Raw
$helpers=[regex]::Match($main,'(?ms)^static int treeSessionIndex\(.*?(?=^static void refreshTree\()')
if(-not $helpers.Success){throw 'Actual tree identity helpers missing'}
if($main-match '\bg_(arm|drag)Idx\b' -or $main-match 'item\.lParam = i;'){throw 'Stale tree indices remain'}
$out=Join-Path $repo 'bin/ui-ownership-unit';New-Item -ItemType Directory -Force $out|Out-Null
$cpp=Join-Path $out 'ui-ownership-unit.cpp'
[IO.File]::WriteAllText($cpp,(Get-Content "$PSScriptRoot/ui-ownership.unit.cpp" -Raw).Replace('// ACTUAL_TREE_IDENTITY_HELPERS',$helpers.Value))
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$testExe=Join-Path $out 'ui-ownership-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 /I `"$repo/src`" `"$cpp`" /Fe:`"$testExe`" /Fo:`"$out/ui-ownership-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'UI ownership fixture compile failed'}
& $testExe
if($LASTEXITCODE-ne 0){throw 'UI ownership fixture failed'}
$io=[regex]::Match($main,'(?ms)^static DWORD ovIo\(.*?^\}')
if(-not $io.Success){throw 'Actual I/O function missing'}
$ioCpp=Join-Path $out 'input-ownership-unit.cpp'
[IO.File]::WriteAllText($ioCpp,(Get-Content "$PSScriptRoot/input-ownership.unit.cpp" -Raw).Replace('// ACTUAL_OV_IO',$io.Value))
$ioExe=Join-Path $out 'input-ownership-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 /I `"$repo/src`" `"$ioCpp`" /Fe:`"$ioExe`" /Fo:`"$out/input-ownership-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'Input ownership fixture compile failed'}
& $ioExe
if($LASTEXITCODE-ne 0){throw 'Input ownership fixture failed'}
