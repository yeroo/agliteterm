param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$out=Join-Path $repo 'bin/omp-protocol-unit';New-Item -ItemType Directory -Force $out|Out-Null
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$testExe=Join-Path $out 'omp-protocol-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 `"$PSScriptRoot/omp-protocol.unit.cpp`" /Fe:`"$testExe`" /Fo:`"$out/omp-protocol-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'OMP protocol fixture compile failed'}
& $testExe
if($LASTEXITCODE-ne 0){throw 'OMP protocol fixture failed'}
$runtime=Get-Content "$repo/src/omp_runtime.h" -Raw
$eligible=[regex]::Match($runtime,'(?ms)^static bool ompPaneEligible\(.*?^\}')
if(-not $eligible.Success){throw 'Actual OMP eligibility missing'}
$cpp=Join-Path $out 'omp-eligibility-unit.cpp'
[IO.File]::WriteAllText($cpp,(Get-Content "$PSScriptRoot/omp-eligibility.unit.cpp" -Raw).Replace('// ACTUAL_ELIGIBILITY',$eligible.Value))
$eligibleExe=Join-Path $out 'omp-eligibility-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 /I `"$repo/src`" `"$cpp`" /Fe:`"$eligibleExe`" /Fo:`"$out/omp-eligibility-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'OMP eligibility fixture compile failed'}
& $eligibleExe
if($LASTEXITCODE-ne 0){throw 'OMP eligibility fixture failed'}
$configExe=Join-Path $out 'omp-config-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 `"$PSScriptRoot/omp-config.unit.cpp`" /Fe:`"$configExe`" /Fo:`"$out/omp-config-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'OMP configuration fixture compile failed'}
& $configExe
if($LASTEXITCODE-ne 0){throw 'OMP configuration fixture failed'}
