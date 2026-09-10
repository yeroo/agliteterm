param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $repo 'src/main.cpp') -Raw
$catalog=[regex]::Match($source,'(?ms)^static std::map<[^\r\n]+ ompCatalog\([^\r\n]*\) \{.*?^\}')
if(-not $catalog.Success){throw 'Actual OMP catalog function not found'}
$body=(Get-Content "$PSScriptRoot/omp-discovery.unit.cpp" -Raw).Replace('// INSERT_PRODUCTION_CATALOG',$catalog.Value)
$out=Join-Path $repo 'bin/omp-discovery-unit';New-Item -ItemType Directory -Force $out|Out-Null
$cpp=Join-Path $out 'omp-discovery.generated.cpp';[IO.File]::WriteAllText($cpp,$body)
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$testExe=Join-Path $out 'omp-discovery-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 /D_CRT_SECURE_NO_WARNINGS `"$cpp`" /Fe:`"$testExe`" /Fo:`"$out/omp-discovery-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'OMP discovery fixture compile failed'}
& $testExe
if($LASTEXITCODE-ne 0){throw 'OMP discovery fixture failed'}
