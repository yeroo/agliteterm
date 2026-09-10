# Actual production clear and save-publication bodies, with private deterministic Win32 I/O.
# No app/host/clipboard/registry. Scheduling points are fake lock acquisition, never sleeps.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$main=Get-Content (Join-Path $repo 'src/main.cpp') -Raw
$runtime=Get-Content (Join-Path $repo 'src/remainder_runtime.h') -Raw
$save=[regex]::Match($main,'(?ms)^    struct LockSave \{.*?^\}')
$clear=[regex]::Match($runtime,'(?ms)^static std::string clearRestoreState\(\).*?^\}')
if(-not $save.Success -or -not $clear.Success){throw 'Production save/clear bodies missing'}
$prefix=@'
#include <string>
#include <map>
#include <functional>
#include <cstdio>
#include <utility>
using DWORD=unsigned long; using BOOL=int; using HANDLE=int;
constexpr int FALSE=0,GENERIC_WRITE=1,FILE_SHARE_READ=2,OPEN_ALWAYS=3,CREATE_ALWAYS=4;
constexpr int FILE_ATTRIBUTE_NORMAL=0,FILE_FLAG_OPEN_REPARSE_POINT=8,FILE_ATTRIBUTE_DIRECTORY=16,FILE_ATTRIBUTE_REPARSE_POINT=32;
constexpr int ERROR_FILE_NOT_FOUND=2,ERROR_PATH_NOT_FOUND=3,INVALID_HANDLE_VALUE=-1;
constexpr int REPLACEFILE_IGNORE_MERGE_ERRORS=1,REPLACEFILE_WRITE_THROUGH=2,MOVEFILE_REPLACE_EXISTING=1;
struct BY_HANDLE_FILE_INFORMATION {DWORD dwFileAttributes=0;};
int g_lock=0,g_saveLock=1,heldState=0,heldSave=0,lockErrors=0,ioCalls=0,nextHandle=1;
unsigned long long g_saveStamp=0,g_savePublished=0;
DWORD error=0; bool flushOk=true,regular=true,markerOk=true;
std::wstring failDelete;
std::map<std::wstring,std::string> files; std::map<int,std::wstring> handles;
std::function<void()> beforeSaveLock;
void EnterCriticalSection(int* p){
 if(p==&g_lock){if(heldSave)++lockErrors;++heldState;}
 else{if(heldState)++lockErrors;if(beforeSaveLock){auto hook=std::move(beforeSaveLock);beforeSaveLock=nullptr;hook();}++heldSave;}
}
void LeaveCriticalSection(int* p){if(p==&g_lock)--heldState;else --heldSave;}
struct LockG {LockG(){EnterCriticalSection(&g_lock);}~LockG(){LeaveCriticalSection(&g_lock);}};
void io(){++ioCalls;if(heldState||heldSave!=1)++lockErrors;}
std::wstring stateFilePath(){return L"private/sessions.tsv";}
std::string narrow(const std::wstring&s){return {s.begin(),s.end()};}
std::string ctlErr(const std::string&s){return "error:"+s;}
std::string ctlOkStr(const std::string&s){return "ok:"+s;}
template<class... T> void logWarn(const char*,T...){} template<class... T> void logInfo(const char*,T...){}
DWORD GetLastError(){return error;}
HANDLE CreateFileW(const wchar_t* p,int,int,void*,int creation,int,void*){
 io();std::wstring path=p;if(path.ends_with(L".cleared")&&!markerOk){error=5;return -1;}
 if(creation==CREATE_ALWAYS||!files.count(path))files[path]="";
 int handle=nextHandle++;handles[handle]=path;return handle;
}
BOOL GetFileInformationByHandle(HANDLE,BY_HANDLE_FILE_INFORMATION*info){io();info->dwFileAttributes=regular?0:FILE_ATTRIBUTE_REPARSE_POINT;return 1;}
BOOL FlushFileBuffers(HANDLE){io();return flushOk;}
BOOL CloseHandle(HANDLE h){io();handles.erase(h);return 1;}
BOOL WriteFile(HANDLE h,const void*data,DWORD size,DWORD*written,void*){io();files[handles.at(h)]={static_cast<const char*>(data),size};*written=size;return 1;}
BOOL DeleteFileW(const wchar_t*p){io();if(failDelete==p){error=5;return 0;}if(files.erase(p))return 1;error=ERROR_FILE_NOT_FOUND;return 0;}
BOOL CopyFileW(const wchar_t*from,const wchar_t*to,BOOL){io();if(!files.count(from)){error=2;return 0;}files[to]=files[from];return 1;}
BOOL MoveFileExW(const wchar_t*from,const wchar_t*to,int){io();if(!files.count(from)){error=2;return 0;}files[to]=files[from];files.erase(from);return 1;}
BOOL ReplaceFileW(const wchar_t*path,const wchar_t*tmp,const wchar_t*bak,int,void*,void*){
 io();if(!files.count(path)||!files.count(tmp)){error=2;return 0;}files[bak]=files[path];files[path]=files[tmp];files.erase(tmp);return 1;
}
int stateFileSessionCount(const std::wstring&path,DWORD*err=nullptr){io();if(!files.count(path)){if(err)*err=ERROR_FILE_NOT_FOUND;return -1;}return files[path].empty()?0:1;}
'@
$tests=@'
int main(){
 int checks=0,failed=0;auto check=[&](bool ok){++checks;if(!ok){++failed;std::printf("FAIL fence %d\n",checks);}};
 const auto path=stateFilePath();
 auto reset=[&]{g_saveStamp=g_savePublished=0;files={{path,"primary"},{path+L".bak","backup"},{path+L".tmp","temp"}};handles.clear();heldState=heldSave=lockErrors=ioCalls=0;beforeSaveLock=nullptr;flushOk=regular=markerOk=true;failDelete.clear();};
 auto snapshot=[&]{LockG hold;return ++g_saveStamp;};
 // Older snapshot is paused before the actual save lock; clear publishes its durable fence first.
 reset();auto old=snapshot();auto cleared=clearRestoreState();int clearedIo=ioCalls;
 check(cleared.starts_with("ok:"));check(g_savePublished==2);check(files.size()==1&&files.count(path+L".cleared"));
 check(publish(path,"old",old));check(ioCalls==clearedIo);check(files.size()==1);check(lockErrors==0);
 // A later snapshot is explicitly allowed to recreate state; an older one cannot replace it.
 auto fresh=snapshot();check(publish(path,"fresh",fresh));check(files[path]=="fresh"&&g_savePublished==fresh);
 check(publish(path,"old",old));check(files[path]=="fresh"&&!files.count(path+L".tmp"));check(lockErrors==0);
 // Newer save wins before clear acquires its I/O lock: clear refuses without marker/deletion.
 reset();std::string before,backup;int winningIo=0;
 beforeSaveLock=[&]{auto stamp=snapshot();check(publish(path,"winner",stamp));before=files[path];backup=files[path+L".bak"];winningIo=ioCalls;};
 auto overtaken=clearRestoreState();check(overtaken.find("overtook")!=std::string::npos);
 check(files[path]==before&&files[path+L".bak"]==backup&&!files.count(path+L".cleared"));check(ioCalls==winningIo&&lockErrors==0);
 // Save already published, then clear: all generations removed, no old snapshot resurrection.
 reset();old=snapshot();check(publish(path,"already published",old));check(clearRestoreState().starts_with("ok:"));
 check(files.size()==1);check(publish(path,"already published",old));check(files.size()==1);
 // Marker failures do not delete or fence anything. A partial delete DOES fence older snapshots.
 for(int mode=0;mode<3;++mode){reset();old=snapshot();if(mode==0)markerOk=false;if(mode==1)regular=false;if(mode==2)flushOk=false;
   check(clearRestoreState().starts_with("error:"));check(files[path]=="primary"&&files[path+L".bak"]=="backup"&&files[path+L".tmp"]=="temp");check(g_savePublished==0&&lockErrors==0);}
 reset();old=snapshot();failDelete=path+L".bak";check(clearRestoreState().find("partial failure")!=std::string::npos);
 check(g_savePublished==2&&!files.count(path)&&files[path+L".bak"]=="backup");clearedIo=ioCalls;
 check(publish(path,"old",old));check(ioCalls==clearedIo&&!files.count(path));check(lockErrors==0&&heldState==0&&heldSave==0);
 // Deliberate empty is per snapshot, never sticky publication state: empty -> populated ->
 // transient empty refused -> deliberate empty accepted. Neither empty may resurrect a backup.
 reset();check(publish(path,"",snapshot(),0,true));check(files[path].empty()&&!files.count(path+L".bak"));
 check(publish(path,"kept-after-empty",snapshot()));check(files[path]=="kept-after-empty");
 check(!publish(path,"",snapshot(),0,false));check(files[path]=="kept-after-empty");
 check(publish(path,"",snapshot(),0,true));check(files[path].empty()&&!files.count(path+L".bak"));
 check(lockErrors==0&&heldState==0&&heldSave==0);
 std::printf("state fence: %d checks, %d failed\n",checks,failed);return failed?1:0;
}
'@
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$out=Join-Path $repo 'bin/state-fence-unit';New-Item -ItemType Directory -Force $out|Out-Null
$generated=Join-Path $out 'state-fence.generated.cpp'
$publication='bool publish(const std::wstring& path,const std::string& out,unsigned long long stamp,int saved=1,bool userEmptied=false){'+"`n"+$save.Value
[IO.File]::WriteAllText($generated,($prefix+"`n"+$publication+"`n"+$clear.Value+"`n"+$tests),[Text.UTF8Encoding]::new($false))
$testExe=Join-Path $out 'state-fence-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /std:c++20 /utf-8 `"$generated`" /Fe:`"$testExe`" /Fo:`"$out/state-fence-unit.obj`""
if($LASTEXITCODE -ne 0){throw 'State fence unit compile failed'}
& $testExe
if($LASTEXITCODE -ne 0){throw 'State fence unit tests failed'}
