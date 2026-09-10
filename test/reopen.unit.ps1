# Production undo-close body and create/attach workspace wiring, with a fake blocking host.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $repo 'src/main.cpp') -Raw
$closed=[regex]::Match($source,'(?m)^struct ClosedSpec .*;\r?$')
$reopen=[regex]::Match($source,'(?ms)^static void reopenClosed\(\).*?^\}')
$create=[regex]::Match($source,'(?ms)^static Session\* newSession\(.*?^\}')
$attach=[regex]::Match($source,'(?ms)^static Session\* attachSession\([^;]*?\{.*?^\}')
$capturePattern='(?m)^    \{ LockG hold; if \(!workspace\).*?\}\r?$'
$createCapture=[regex]::Match($create.Value,$capturePattern)
$attachCapture=[regex]::Match($attach.Value,$capturePattern)
$attachCall=[regex]::Match($create.Value,'(?m)^    Session\* s = attachSession\(.*?;\r?$')
$publication=[regex]::Match($attach.Value,'(?m)^    s->ws = .*?;\r?$')
foreach($part in $closed,$reopen,$createCapture,$attachCapture,$attachCall,$publication){if(-not $part.Success){throw 'Production reopen/create/attach wiring missing'}}
# The fake waits below must not silently relocate a production capture from after I/O to before it.
foreach($pair in @(@($create,$createCapture),@($attach,$attachCapture))){
    $firstRequest=[regex]::Match($pair[0].Value,'\b(?:request|creation_protocol::start)\s*\(')
    if(-not $firstRequest.Success -or $pair[1].Index -ge $firstRequest.Index){throw 'Workspace capture must precede the first host request or creation coordinator'}
}
$ctlStart=$source.IndexOf('    if (cmd == "session.new")')
$ctlSource=$source.Substring($ctlStart,$source.IndexOf('    if (cmd == "session.switch")',$ctlStart)-$ctlStart)
$resolveStart=$ctlSource.IndexOf('        uint64_t workspace = 0;')
$resolveEnd=$ctlSource.IndexOf('        int cols, rows;',$resolveStart)
$resolve=$ctlSource.Substring($resolveStart,$resolveEnd-$resolveStart)
$ctlCreate=[regex]::Match($ctlSource,'(?m)^        Session\* s = newSession\(cols, rows, app, [\s\S]*?;')
if(-not $ctlCreate.Success -or $ctlSource.IndexOf('s->ws =') -ge 0){throw 'Control creation must use attach placement, without later index/name rebinding'}
$prefix=@'
#include <string>
#include <vector>
#include <functional>
#include <cstdio>
#include <map>
#include <cstdlib>
#include <cwchar>
#include <atomic>
#include "workspace_identity.h"
struct Session {int ws=-1;std::wstring name,context;};
WorkspaceNames g_workspaces{L"first",L"remembered",L"current"};
std::atomic<int> g_activeWs{2};
int g_focus=0,held=0,creates=0,lockErrors=0,selectedIndex=0;
void* g_hwnd=nullptr;constexpr bool FALSE=false;
Session made,intruder;Session* selected=nullptr;std::vector<Session*> g_sessions;
std::function<void()> duringHost;std::string appSeen,cwdSeen;std::vector<std::string> argsSeen;
struct LockG {LockG(){++held;}~LockG(){--held;}};
void newSessionGrid(int,int*c,int*r){*c=80;*r=24;}
void selectPrimary(int index,bool,Session* expected=nullptr){selectedIndex=index;selected=expected;}
void InvalidateRect(void*,void*,bool){}
struct Request {std::map<std::string,std::string> args;std::string get(const char*key)const{auto i=args.find(key);return i==args.end()?"":i->second;}};
std::wstring widen(const std::string&s){return std::wstring(s.begin(),s.end());}
Session* ctlErr(const std::string&){return nullptr;}
int callerWs=-1;
int callerWorkspace(const std::string&caller){return caller=="caller-pane"?callerWs:-1;}
'@
$attachFake=@'
static Session* attachSession(const char*,int,int,const char*,const std::vector<std::string>*,const char*,bool,bool,uint64_t workspace=0,const char* creationTicket=""){
'@ + "`n"+$attachCapture.Value+@'

    if(held)++lockErrors;
    if(duringHost)duringHost();
    Session* s=&made;
    { LockG hold;
'@ + "`n"+$publication.Value+@'

      g_sessions.push_back(s); }
    return s;
}
'@
$createFake=@'
static Session* newSession(int cols,int rows,const char* app=nullptr,const std::vector<std::string>*pargs=nullptr,const char*cwd=nullptr,bool quick=false,bool hidden=false,uint64_t workspace=0,bool explicitCommand=false){
'@ + "`n"+$createCapture.Value+@'

    ++creates;appSeen=app?app:"";cwdSeen=cwd?cwd:"";argsSeen=pargs?*pargs:std::vector<std::string>{};
    const char* idbuf="private-created";std::string creationTicket="private-test-ticket";
'@ + "`n"+$attachCall.Value+@'

    g_sessions.push_back(&intruder); // another creator wins the vector's last slot before selection
    return s;
}
'@
$tests=@'
int main(){
 int checks=0,failed=0;auto check=[&](bool ok){++checks;if(!ok){++failed;std::printf("FAIL reopen %d\n",checks);}};
 for(int scenario=0;scenario<5;++scenario){
   g_workspaces=std::vector<std::wstring>{L"first",L"remembered",L"current"};
   auto remembered=g_workspaces.token(1);g_activeWs=2;g_sessions.clear();selected=nullptr;held=creates=lockErrors=0;made=Session{};
   g_closedStack={{L"restored",remembered,"cmd.exe","C:/Remembered",{"/d","/q"},L"kept context"}};
   int expectedWs=1;
   duringHost=[&]{
     check(held==0);check(g_activeWs==2); // reopening must not publish an ambient workspace change before I/O
     LockG hold;
     if(scenario==0){g_activeWs=0;}
     if(scenario==1){g_workspaces[1]=L"renamed";g_activeWs=0;}
     if(scenario==2){g_workspaces.erase(g_workspaces.begin());g_activeWs=1;expectedWs=0;}
     if(scenario==3){g_workspaces.move(1,2);g_activeWs=0;expectedWs=2;}
     if(scenario==4){g_workspaces.erase(g_workspaces.begin()+1);g_workspaces.push_back(L"remembered");g_activeWs=2;expectedWs=0;}
   };
   reopenClosed();check(creates==1&&g_closedStack.empty());check(made.ws==expectedWs);
   check(selected==&made&&selectedIndex==-1&&g_sessions.back()==&intruder);
   check(made.name==L"restored"&&made.context==L"kept context");
   check(appSeen=="cmd.exe"&&cwdSeen=="C:/Remembered"&&argsSeen==std::vector<std::string>{"/d","/q"});
   check(held==0&&lockErrors==0);
 }
 duringHost=nullptr;creates=0;g_closedStack.clear();reopenClosed();check(creates==0);
 // Ordinary create also freezes its destination before the host wait.
 g_workspaces=std::vector<std::wstring>{L"first",L"second"};g_activeWs=1;
 duringHost=[&]{g_activeWs=0;};newSession(80,24);check(made.ws==1);
 // Actual control destination-resolution block and actual newSession call, not a test copy.
 for(int mode=0;mode<5;++mode)for(int replacement=0;replacement<2;++replacement)for(int commandMode=0;commandMode<2;++commandMode){
   g_workspaces=std::vector<std::wstring>{L"first",L"target",L"active"};g_activeWs=2;callerWs=1;held=lockErrors=0;
   Request req;
   if(mode==0)req.args["args.workspace"]="1";
   if(mode==1)req.args["args.workspace-name"]="target";
   if(mode==2)req.args["args.caller"]="caller-pane";
   if(mode==3)req.args["caller"]="caller-pane";
   if(mode==4){req.args["args.workspace-name"]="created";req.args["args.create-workspace"]="true";}
   int target=mode==4?3:1;
   duringHost=[&]{check(held==0);LockG hold;g_activeWs=0;
     if(replacement){g_workspaces.erase(g_workspaces.begin()+target);g_workspaces.push_back(mode==4?L"created":L"target");}
     else g_workspaces[target]=L"renamed during host wait";
   };
   check(controlCreate(req,commandMode==1)==&made);check(made.ws==(replacement?0:target));check(lockErrors==0&&held==0);
 }
 std::printf("reopen: %d checks, %d failed\n",checks,failed);return failed?1:0;
}
'@
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$out=Join-Path $repo 'bin/reopen-unit';New-Item -ItemType Directory -Force $out|Out-Null
$generated=Join-Path $out 'reopen.generated.cpp'
$ctlFake="static Session* controlCreate(const Request& req,bool explicitCommand=false){`n"+$resolve+"`nint cols=80,rows=24;const char*app=nullptr;std::vector<std::string>cargs;std::string cwd;`n"+$ctlCreate.Value+"`nreturn s;}`n"
[IO.File]::WriteAllText($generated,($prefix+"`n"+$closed.Value+"`nstd::vector<ClosedSpec> g_closedStack;`n"+$attachFake+"`n"+$createFake+"`n"+$reopen.Value+"`n"+$ctlFake+$tests),[Text.UTF8Encoding]::new($false))
$testExe=Join-Path $out 'reopen-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /std:c++20 /utf-8 /I`"$repo/src`" `"$generated`" /Fe:`"$testExe`" /Fo:`"$out/reopen-unit.obj`""
if($LASTEXITCODE -ne 0){throw 'Reopen unit compile failed'}
& $testExe
if($LASTEXITCODE -ne 0){throw 'Reopen unit tests failed'}
