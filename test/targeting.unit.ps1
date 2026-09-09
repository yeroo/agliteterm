# Compile the actual production resolver with an in-memory session list: no GUI or host I/O.
param([string]$Exe,[switch]$Strict,[switch]$ProveRegression)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $repo 'src/main.cpp') -Raw
$resolver=[regex]::Match($source,'(?ms)^static Session\* resolveTarget\(const std::string& target, std::string\* why = nullptr\) \{.*?^\}')
$cover=[regex]::Match($source,'(?m)^static bool isCoverLocked\(Session\* s\) \{[^\r\n]+\}')
if(-not $resolver.Success -or -not $cover.Success){throw 'Production targeting functions not found'}
$prefix=@'
#include <windows.h>
#include <string>
#include <vector>
#include <cstdio>
struct Session { std::string id, paneId, splitId; std::wstring name; bool hidden=false; };
static std::vector<Session*> g_sessions;
static Session* current=nullptr;
struct LockG {};
static Session* focusedSession(){return current;}
static std::wstring widen(const std::string& s){return std::wstring(s.begin(),s.end());}
static Session* splitOwnerOf(Session* s){for(auto* owner:g_sessions)if(!owner->hidden&&owner->splitId==s->id)return owner;return nullptr;}
'@
$tests=@'
int main(){
 int checked=0,failed=0; auto check=[&](bool value){++checked;if(!value)++failed;};
 Session owner{"lite-9","lite-9","lite-10",L"owner",false};
 Session split{"lite-10","lite-10","",L"split",true};
 Session quick{"quick:lite-11","quick:lite-11","",L"quick",true};
 Session other{"other-id","other-pane","",L"lite-1",false};
 g_sessions={&owner,&split,&quick,&other}; current=&owner;
 check(resolveTarget("lite-1")==&split); // prefix wins over a visible row's name
 check(resolveTarget("lite-10")==&split);
 check(resolveTarget("quick")==nullptr);
 check(resolveTarget("quick:lite-11")==&quick);
 check(resolveTarget("quick:lite-")==nullptr); // hidden covers are exact-ID only
 check(resolveTarget("active")==&owner); check(resolveTarget("")==&owner);
 check(resolveTarget("OWNER")==&owner); check(resolveTarget("lit")==nullptr);
 g_sessions={&split,&owner,&quick,&other};
 check(resolveTarget("lite-")==&split); // destructive verbs must receive the split, not owner
 check(resolveTarget("lite-9")==&owner); // exact identity still wins over earlier prefixes
 check(resolveTarget("lite-1")==&split);
 g_sessions={&owner,&split,&quick,&other};
 check(resolveTarget("lite-")==&owner); // existing list-order prefix contract
 owner.id="stable-id";
 check(resolveTarget("lite-9")==&owner); check(resolveTarget("stab")==&owner);
 other.name=L"quick"; check(resolveTarget("quick")==&other);
 current=&split; check(resolveTarget("active")==&split);
 std::printf("targeting: %d checks, %d failed\n",checked,failed); return failed?1:0;
}
'@
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$out=Join-Path $repo 'bin/targeting-unit';New-Item -ItemType Directory -Force $out|Out-Null
$generated=Join-Path $out 'targeting.generated.cpp'
[IO.File]::WriteAllText($generated,($prefix+"`n"+$cover.Value+"`n"+$resolver.Value+"`n"+$tests),[Text.UTF8Encoding]::new($false))
$testExe=Join-Path $out 'targeting-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$generated`" /Fe:`"$testExe`" /Fo:`"$out/targeting-unit.obj`""
if($LASTEXITCODE -ne 0){throw 'Targeting unit compile failed'}
& $testExe
if($LASTEXITCODE -ne 0){throw 'Targeting unit tests failed'}
if($ProveRegression){
    # A local mutation oracle: the previous guard must fail this same production-body harness.
    $mutant=$resolver.Value.Replace('!isCoverLocked(s) && target.size()', '!s->hidden && target.size()')
    if($mutant -eq $resolver.Value){throw 'Regression mutation did not apply'}
    $badSource=Join-Path $out 'targeting.regression.cpp';$badExe=Join-Path $out 'targeting-regression.exe'
    [IO.File]::WriteAllText($badSource,($prefix+"`n"+$cover.Value+"`n"+$mutant+"`n"+$tests),[Text.UTF8Encoding]::new($false))
    & cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$badSource`" /Fe:`"$badExe`" /Fo:`"$out/targeting-regression.obj`""
    if($LASTEXITCODE -ne 0){throw 'Regression oracle compile failed'}
    & $badExe
    if($LASTEXITCODE -ne 1){throw 'Old broken guard did not fail the regression oracle'}
    'Confirmed: old hidden-session guard fails; fixed production resolver passes.'
    $global:LASTEXITCODE=0
}
