# Compile production paste/clipboard and capture dispatch with private deterministic I/O fakes.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $repo 'src/main.cpp') -Raw
$arm=[regex]::Match($source,'(?ms)^    if \(cmd == "session.paste"\).*?(?=^    if \(cmd == "session.go"\))')
$typeArm=[regex]::Match($source,'(?ms)^    if \(cmd == "session.type"\).*?(?=^    if \(cmd == "session.write"\))')
$normalize=[regex]::Match($source,'(?ms)^static std::string pasteNormalize\(.*?^\}')
$clipboard=[regex]::Match($source,'(?ms)^static std::string readClipboardText\(.*?^\}')
$capture=[regex]::Match($source,'(?ms)^    if \(cmd == "restore.capture"\).*?(?=^    if \(cmd == "session.duplicate"\))')
$capPane=[regex]::Match($source,'(?ms)^struct CapPane \{.*?\};')
$snapshot=[regex]::Match($source,'(?ms)^static void snapshotRealPanes\(.*?^\}')
$applyCapture=[regex]::Match($source,'(?ms)^static int applyForegroundCapture\(.*?^\}')
if(-not $arm.Success -or -not $typeArm.Success -or -not $normalize.Success -or -not $clipboard.Success -or -not $capture.Success){throw 'Production paste/capture functions not found'}
if(-not $capPane.Success -or -not $snapshot.Success -or -not $applyCapture.Success){throw 'Production capture helpers not found (CapPane/snapshotRealPanes/applyForegroundCapture)'}
$prefix=@'
#include <string>
#include <cstdio>
#include <cstdint>
#include <algorithm>
#include <map>
#include <vector>
#include <atomic>
namespace bounded_pipe_write { struct Pending {}; }
#include "bounded_input.h"
using DWORD=unsigned long; using HANDLE=uintptr_t; using HWND=void*;
constexpr HANDLE INVALID_HANDLE_VALUE=0; constexpr int CF_UNICODETEXT=13;
struct Session { bool readOnly=false,exited=false,listed=true,hidden=false; std::string paneId="pane",id="session",splitId,capturedCmd; HANDLE data=1; int emu=1; };
struct Request { std::string text; std::map<std::string,std::string> fields; std::string get(const char*)const{return text;} };
struct FfiEmuInfo {bool bracketedPaste=false;};
int held=0,reads=0,writes=0,clipMode=0,writeMode=0,closes=0,unlocks=0; bool bracketed=false,infoOk=true;
std::string sent; Session* duringClipboard=nullptr;
struct LockG {LockG(){++held;} ~LockG(){--held;}};
int indexOfSession(Session* s){return s->listed?0:-1;}
std::string ctlErr(const std::string&s){return "error:"+s;}
std::string ctlOkStr(const std::string&s){return "ok:"+s;}
bool OpenClipboard(void*){++reads;if(duringClipboard)duringClipboard->exited=true;return clipMode!=1;}
HANDLE GetClipboardData(int){return clipMode==2?0:1;}
const wchar_t* GlobalLock(HANDLE){return clipMode==3?nullptr:clipMode==4?L"text":clipMode==5?L"bad":L"";}
size_t GlobalSize(HANDLE){return clipMode==4?5*sizeof(wchar_t):clipMode==5?3*sizeof(wchar_t):clipMode==6?1:clipMode==7?0:clipMode==8?32u*1024u*1024u:sizeof(wchar_t);}
void GlobalUnlock(HANDLE){++unlocks;} void CloseClipboard(){++closes;}
std::string narrow(const std::wstring&s){return std::string(s.begin(),s.end());}
bool emu_info(int,FfiEmuInfo*info){info->bracketedPaste=bracketed;return infoOk;}
// The bounded writer (#110) is faked; its Result -> reply mapping (bounded_input::outcome) is real.
// writeMode: 0 all written, 1 gate refused, 2 deadline after N-1 bytes with the last byte cancelled,
// 3 pending, 4 bracket closed after a stop. Any call under the global lock is a failure.
size_t openSeen=0,closeSeen=0; bool lockedWrite=false;
bounded_input::Result<bounded_pipe_write::Pending> boundedPaneInput(Session*,const std::string& bytes,size_t open=0,size_t close=0){
 ++writes;if(held)lockedWrite=true;sent=bytes;openSeen=open;closeSeen=close;
 static bounded_pipe_write::Pending pending;bounded_input::Result<bounded_pipe_write::Pending> r;r.total=(unsigned long)bytes.size();
 using bounded_input::Stop;using bounded_input::Bracket;
 if(writeMode==0){r.stop=Stop::Done;r.written=r.total;}
 else if(writeMode==1)r.stop=Stop::Refused;
 else if(writeMode==2){r.stop=Stop::TimedOut;r.written=r.total-1;r.chunk=1;}
 else if(writeMode==3){r.stop=Stop::Pending;r.written=0;r.chunk=r.total;r.pending=&pending;r.bracket=open?Bracket::Unknown:Bracket::None;}
 else {r.stop=Stop::TimedOut;r.written=(unsigned long)open;r.chunk=1;r.closed=(unsigned long)close;r.bracket=Bracket::Closed;}
 return r;}
std::vector<Session*> g_sessions; std::atomic<bool> g_restoreCommands{false};
int saves=0,refreshes=0; bool disappear=false,queryOk=true,saveOk=true; HWND g_hwnd=nullptr; constexpr int WM_APP_REFRESHTREE=1;
std::string stateFile="prior-state",backupFile="prior-backup";
const char *kCaptureQueryFailed="query failed",*kCaptureEmptyTarget="empty target";
std::string captureUnknownTarget(const std::string&){return "missing";}
std::string captureCoverPane(const std::string&){return "cover";}
Session* splitOwnerOf(Session*){return nullptr;}
DWORD livePid(Session*s){return s->exited?0:10;}
bool captureForeground(const std::vector<DWORD>&,std::map<DWORD,std::string>*found){if(disappear){g_sessions.front()->listed=false;g_sessions.erase(g_sessions.begin());}(*found)[10]="tool";return queryOk;}
std::string jsonEscape(const std::string&s){return s;}
std::string ctlOk(const std::string&s){return "ok:"+s;}
bool saveSessionState(){++saves;if(saveOk){backupFile=stateFile;stateFile="new-state";}return saveOk;}
bool PostMessageW(HWND,int,int,int){++refreshes;return true;}
'@
$tests=@'
int main(){
 int checks=0,failures=0; auto check=[&](bool ok){++checks;if(!ok){++failures;std::printf("FAIL %d\n",checks);}};
 Session s;
 auto reset=[&]{s=Session{};held=reads=writes=clipMode=writeMode=closes=unlocks=0;bracketed=false;infoOk=true;sent.clear();duringClipboard=nullptr;};
 reset();check(paste(nullptr,{"text"}).find("error:")==0);check(reads==0&&writes==0);
 reset();s.listed=false;check(paste(&s,{}).find("error:")==0);check(reads==0&&writes==0);
 reset();s.readOnly=true;check(paste(&s,{}).find("read-only")!=std::string::npos);check(reads==0&&writes==0);
 reset();s.exited=true;check(paste(&s,{}).find("exited")!=std::string::npos);check(reads==0&&writes==0);
 for(int mode=0;mode<4;++mode){reset();clipMode=mode;check(paste(&s,{})=="ok:nothing to paste");check(reads==1&&writes==0);}
 for(int mode=5;mode<=8;++mode){reset();clipMode=mode;check(paste(&s,{})=="ok:nothing to paste");check(reads==1&&writes==0&&closes==1);check(unlocks==(mode==5?1:0));}
 reset();check(paste(&s,{"one\r\ntwo\n"})=="ok:pasted");check(reads==0&&writes==1&&sent=="one\rtwo\r");
 reset();clipMode=4;bracketed=true;check(paste(&s,{})=="ok:pasted");check(sent=="\x1b[200~text\x1b[201~"&&reads==1);
 reset();writeMode=1;check(paste(&s,{"text"})=="error:session paste: input to this pane is busy or reserved; nothing pasted");check(writes==1);
 reset();writeMode=2;check(paste(&s,{"text"})=="error:session paste: 3 of 4 bytes written; the 1-byte chunk at offset 3 was cancelled at the 15 s input deadline and may have been partly delivered; the remaining 0 bytes were not written");check(writes==1);
 reset();writeMode=3;check(paste(&s,{"text"}).find("still in flight and may still arrive; the remaining 0 bytes were not written; this pane's input stays reserved")!=std::string::npos);
 reset();bracketed=true;check(paste(&s,{"text"})=="ok:pasted");check(openSeen==6&&closeSeen==6&&sent=="\x1b[200~text\x1b[201~");
 reset();check(paste(&s,{"text"})=="ok:pasted");check(openSeen==0&&closeSeen==0);
 reset();bracketed=true;writeMode=4;check(paste(&s,{"text"}).find("then closed with a separate ESC[201~")!=std::string::npos);
 reset();bracketed=true;writeMode=3;check(paste(&s,{"text"}).find("whether the bracketed paste was opened is unknown")!=std::string::npos);
 // session type: same bounded writer; read-only does NOT refuse it (P9), control bytes still do.
 reset();check(type(&s,{"one\ntwo"})=="ok:typed");check(writes==1&&sent=="one\rtwo"&&openSeen==0&&closeSeen==0);
 reset();s.readOnly=true;check(type(&s,{"x"})=="ok:typed");check(writes==1);
 reset();writeMode=1;check(type(&s,{"x"})=="error:session type: input to this pane is busy or reserved; nothing typed");
 reset();writeMode=2;check(type(&s,{"abcd"}).find("error:session type: 3 of 4 bytes written; the 1-byte chunk at offset 3 was cancelled")==0);
 reset();writeMode=3;check(type(&s,{"abcd"}).find("stays reserved until that write resolves")!=std::string::npos);
 reset();check(type(&s,{std::string("a\x01")}).find("refuses control byte 0x01")!=std::string::npos);check(writes==0);
 reset();s.exited=true;check(type(&s,{"x"}).find("no live input")!=std::string::npos);check(writes==0);
 reset();s.listed=false;check(type(&s,{"x"})=="error:session not found");check(writes==0);
 check(!lockedWrite);
 reset();s.data=0;check(paste(&s,{"text"}).find("no live input")!=std::string::npos);check(writes==0);
 reset();infoOk=false;check(paste(&s,{"text"}).find("state unavailable")!=std::string::npos);check(writes==0);
 reset();clipMode=4;duringClipboard=&s;check(paste(&s,{}).find("exited")!=std::string::npos);check(reads==1&&writes==0);
 for(bool gone:{false,true})for(bool saved:{false,true}){
   reset();Session survivor;survivor.paneId="survivor";survivor.capturedCmd="keep-me";g_sessions={&s,&survivor};disappear=gone;queryOk=true;saveOk=saved;saves=refreshes=0;stateFile="prior-state";backupFile="prior-backup";
   Request req;req.fields["target"]=s.paneId;auto result=capture(&s,req);
   if(gone){check(result=="ok:{\"captured\":0,\"replayOnRestore\":false,\"panes\":[]}");check(saves==0&&refreshes==0);check(stateFile=="prior-state"&&backupFile=="prior-backup");check(s.capturedCmd.empty());check(g_sessions.size()==1&&g_sessions[0]==&survivor&&survivor.capturedCmd=="keep-me");}
   else{check((result.find("ok:")==0)==saved);check(saves==1&&refreshes==1);check(s.capturedCmd=="tool");}
 }
 std::printf("paste: %d checks, %d failed\n",checks,failures);return failures?1:0;
}
'@
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$out=Join-Path $repo 'bin/paste-unit';New-Item -ItemType Directory -Force $out|Out-Null
$generated=Join-Path $out 'paste.generated.cpp'
$dispatch='std::string paste(Session* target,const Request& req){ std::string cmd="session.paste",targetWhy;'+"`n"+$arm.Value+'return "unhandled";}'
$typeDispatch='std::string type(Session* target,const Request& req){ std::string cmd="session.type",targetWhy;'+"`n"+$typeArm.Value+'return "unhandled";}'
$captureDispatch='std::string capture(Session* target,const Request& req){ std::string cmd="restore.capture",targetWhy;'+"`n"+$capture.Value+'return "unhandled";}'
# The helpers go before the capture dispatch that calls them, and after $prefix, which declares the
# Session/LockG/g_sessions/livePid/indexOfSession/jsonEscape they are written against.
[IO.File]::WriteAllText($generated,($prefix+"`n"+$normalize.Value+"`n"+$clipboard.Value+"`n"+$dispatch+"`n"+$typeDispatch+"`n"+
    $capPane.Value+"`n"+$snapshot.Value+"`n"+$applyCapture.Value+"`n"+$captureDispatch+"`n"+$tests),[Text.UTF8Encoding]::new($false))
$testExe=Join-Path $out 'paste-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 /I `"$repo/src`" `"$generated`" /Fe:`"$testExe`" /Fo:`"$out/paste-unit.obj`""
if($LASTEXITCODE -ne 0){throw 'Paste unit compile failed'}
& $testExe
if($LASTEXITCODE -ne 0){throw 'Paste unit tests failed'}
