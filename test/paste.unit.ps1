# Compile the production paste dispatch and normalization with private deterministic I/O fakes.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $repo 'src/main.cpp') -Raw
$arm=[regex]::Match($source,'(?ms)^    if \(cmd == "session.paste"\).*?(?=^    if \(cmd == "session.go"\))')
$normalize=[regex]::Match($source,'(?ms)^static std::string pasteNormalize\(.*?^\}')
if(-not $arm.Success -or -not $normalize.Success){throw 'Production paste functions not found'}
$prefix=@'
#include <string>
#include <cstdio>
#include <cstdint>
using DWORD=unsigned long; using HANDLE=uintptr_t;
constexpr HANDLE INVALID_HANDLE_VALUE=0; constexpr int CF_UNICODETEXT=13;
struct Session { bool readOnly=false,exited=false,listed=true; std::string paneId="pane"; HANDLE data=1; int emu=1; };
struct Request { std::string text; std::string get(const char*)const{return text;} };
struct FfiEmuInfo {bool bracketedPaste=false;};
int held=0,reads=0,writes=0,clipMode=0,writeMode=0; bool bracketed=false,infoOk=true;
std::string sent; Session* duringClipboard=nullptr;
struct LockG {LockG(){++held;} ~LockG(){--held;}};
int indexOfSession(Session* s){return s->listed?0:-1;}
std::string ctlErr(const std::string&s){return "error:"+s;}
std::string ctlOkStr(const std::string&s){return "ok:"+s;}
bool OpenClipboard(void*){++reads;if(duringClipboard)duringClipboard->exited=true;return clipMode!=1;}
HANDLE GetClipboardData(int){return clipMode==2?0:1;}
const wchar_t* GlobalLock(HANDLE){return clipMode==3?nullptr:clipMode==4?L"text":L"";}
void GlobalUnlock(HANDLE){} void CloseClipboard(){}
std::string narrow(const wchar_t*s){std::string r;while(*s)r+=char(*s++);return r;}
bool emu_info(int,FfiEmuInfo*info){info->bracketedPaste=bracketed;return infoOk;}
DWORD ovIo(HANDLE,bool,const void*bytes,void*,DWORD size){++writes;if(held)return 0;sent.assign((const char*)bytes,size);return writeMode==1?0:writeMode==2?size-1:size;}
'@
$tests=@'
int main(){
 int checks=0,failures=0; auto check=[&](bool ok){++checks;if(!ok){++failures;std::printf("FAIL %d\n",checks);}};
 Session s;
 auto reset=[&]{s=Session{};held=reads=writes=clipMode=writeMode=0;bracketed=false;infoOk=true;sent.clear();duringClipboard=nullptr;};
 reset();check(paste(nullptr,{"text"}).find("error:")==0);check(reads==0&&writes==0);
 reset();s.listed=false;check(paste(&s,{}).find("error:")==0);check(reads==0&&writes==0);
 reset();s.readOnly=true;check(paste(&s,{}).find("read-only")!=std::string::npos);check(reads==0&&writes==0);
 reset();s.exited=true;check(paste(&s,{}).find("exited")!=std::string::npos);check(reads==0&&writes==0);
 for(int mode=0;mode<4;++mode){reset();clipMode=mode;check(paste(&s,{})=="ok:nothing to paste");check(reads==1&&writes==0);}
 reset();check(paste(&s,{"one\r\ntwo\n"})=="ok:pasted");check(reads==0&&writes==1&&sent=="one\rtwo\r");
 reset();clipMode=4;bracketed=true;check(paste(&s,{})=="ok:pasted");check(sent=="\x1b[200~text\x1b[201~"&&reads==1);
 reset();writeMode=1;check(paste(&s,{"text"}).find("error:")==0);check(writes==1);
 reset();writeMode=2;check(paste(&s,{"text"}).find("partial")!=std::string::npos);check(writes==1);
 reset();s.data=0;check(paste(&s,{"text"}).find("no live input")!=std::string::npos);check(writes==0);
 reset();infoOk=false;check(paste(&s,{"text"}).find("state unavailable")!=std::string::npos);check(writes==0);
 reset();clipMode=4;duringClipboard=&s;check(paste(&s,{}).find("exited")!=std::string::npos);check(reads==1&&writes==0);
 std::printf("paste: %d checks, %d failed\n",checks,failures);return failures?1:0;
}
'@
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$out=Join-Path $repo 'bin/paste-unit';New-Item -ItemType Directory -Force $out|Out-Null
$generated=Join-Path $out 'paste.generated.cpp'
$dispatch='std::string paste(Session* target,const Request& req){ std::string cmd="session.paste",targetWhy;'+"`n"+$arm.Value+'return "unhandled";}'
[IO.File]::WriteAllText($generated,($prefix+"`n"+$normalize.Value+"`n"+$dispatch+"`n"+$tests),[Text.UTF8Encoding]::new($false))
$testExe=Join-Path $out 'paste-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$generated`" /Fe:`"$testExe`" /Fo:`"$out/paste-unit.obj`""
if($LASTEXITCODE -ne 0){throw 'Paste unit compile failed'}
& $testExe
if($LASTEXITCODE -ne 0){throw 'Paste unit tests failed'}
