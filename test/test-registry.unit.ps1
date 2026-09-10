# Actual startup namespace resolver; process-local environment only, no registry/host/GUI IO.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $repo 'src/main.cpp') -Raw
$resolve=[regex]::Match($source,'(?ms)^static std::wstring g_testCurrentKey,.*?^\}')
if(-not $resolve.Success){throw 'Production test namespace resolver missing'}
if($source-notmatch '(?s)int WINAPI wWinMain[^\{]*\{\s*//[^\r\n]*\r?\n\s*if \(!configureTestRegistry\(\)\) return 2;'){throw 'Isolation is not the first startup action'}
$prefix=@'
#include <windows.h>
#include <string>
#include <cstdio>
#include "../../src/test_registry.h"
static const wchar_t* kRegKey=L"Software\\agliteterm";
static const wchar_t* kInstKey=L"Software\\agliteterm\\Instances";
static const wchar_t* kLegacyRegKey=L"Software\\agwinterm-lite";
'@
$suffix=@'
int main(){
 int checks=0,failed=0;
 auto check=[&](bool good){++checks;if(!good)++failed;};
 SetEnvironmentVariableW(L"AGLITETERM_TEST_RUN",nullptr);
 check(configureTestRegistry() && std::wstring(kRegKey)==L"Software\\agliteterm" && g_testHostAppId.empty());
 for(const wchar_t* bad:{L"x",L"../personal",L"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",L"01234567890123456789012345678901234",L"012345678901234567890123456789012g"}){
   SetEnvironmentVariableW(L"AGLITETERM_TEST_RUN",bad);
   check(!configureTestRegistry() && std::wstring(kRegKey)==L"Software\\agliteterm" && g_testHostAppId.empty());
 }
 const std::wstring run=L"0123456789abcdef0123456789abcdef";
 SetEnvironmentVariableW(L"AGLITETERM_TEST_RUN",run.c_str());
 check(configureTestRegistry());
 check(std::wstring(kRegKey)==L"Software\\agliteterm-tests\\"+run+L"\\Current");
 check(std::wstring(kInstKey)==std::wstring(kRegKey)+L"\\Instances");
 check(std::wstring(kLegacyRegKey)==L"Software\\agliteterm-tests\\"+run+L"\\Legacy");
 check(g_testHostAppId==L"agliteterm-test-"+run);
 const auto pipe=L"agliteterm-test-"+run+L"-ctl-name";
 check(lite_test_registry::endpoint(run,L"name")==pipe);
 check(lite_test_registry::endpoint(run,pipe)==pipe);
 check(lite_test_registry::endpoint(run,L"\\\\.\\pipe\\name")==pipe);
 check(lite_test_registry::endpoint(L"",L"ordinary")==L"ordinary");
 std::printf("test namespace: %d actual resolver checks, %d failed; no registry/host IO\n",checks,failed);
 return failed?1:0;
}
'@
$out=Join-Path $repo 'bin/test-registry-unit';New-Item -ItemType Directory -Force $out|Out-Null
$cpp=Join-Path $out 'test-registry-unit.cpp'
[IO.File]::WriteAllText($cpp,($prefix+"`n"+$resolve.Value+"`n"+$suffix))
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$testExe=Join-Path $out 'test-registry-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$cpp`" /Fe:`"$testExe`" /Fo:`"$out/test-registry-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'Namespace fixture compile failed'}
& $testExe
if($LASTEXITCODE-ne 0){throw 'Namespace fixture failed'}
. "$PSScriptRoot/test-registry-path.ps1"
$prior=$env:AGLITETERM_TEST_RUN
try {
    $env:AGLITETERM_TEST_RUN=$null
    if((Get-LiteTestRegistryPath)-cne 'Software\agliteterm'){throw 'Default path changed'}
    $refused=$false;try {Get-LiteTestRegistryPath -RequireIsolation|Out-Null}catch{$refused=$true}
    if(-not $refused){throw 'Missing isolation not refused'}
    $env:AGLITETERM_TEST_RUN='0123456789abcdef0123456789abcdef'
    if((Get-LiteTestRegistryPath)-cne 'Software\agliteterm-tests\0123456789abcdef0123456789abcdef\Current'){throw 'Namespace disagreement'}
    if((Get-LiteTestRegistryPath -Legacy)-cne 'Software\agliteterm-tests\0123456789abcdef0123456789abcdef\Legacy'){throw 'Legacy namespace disagreement'}
    $expected='agliteterm-test-0123456789abcdef0123456789abcdef-ctl-name'
    foreach($name in 'name','\\.\pipe\name',$expected){if((Get-LiteTestPipe $name)-cne $expected){throw 'Pipe namespace disagreement'}}
    $env:AGLITETERM_TEST_RUN='../personal'
    $refused=$false;try {Get-LiteTestRegistryPath|Out-Null}catch{$refused=$true}
    if(-not $refused){throw 'Invalid isolation not refused'}
} finally {$env:AGLITETERM_TEST_RUN=$prior}
'Namespace adapters: 8 private checks passed'
