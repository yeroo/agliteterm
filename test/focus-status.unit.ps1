# Actual production focus setters, with an in-process lock/message seam; no GUI or host.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $repo 'src/main.cpp') -Raw
$pane=[regex]::Match($source,'(?ms)^static void setFocusedPane\(int pane\) \{.*?^\}')
$surface=[regex]::Match($source,'(?ms)^static void setFocusOverride\(Session\* surface\) \{.*?^\}')
if(-not $pane.Success -or -not $surface.Success){throw 'Production focus setters missing'}
$rest=$source.Replace($pane.Value,'').Replace($surface.Value,'')
if([regex]::Matches($rest,'\bg_focus\s*=(?!=)').Count-ne 1 -or [regex]::IsMatch($rest,'\bg_focusOverride\s*=(?!=)')){throw 'Focus assignments bypass the status-notifying setters'}
$prefix=@'
#include <cstdio>
struct Session {};
int g_focus=0, g_hwnd=1, messages=0, held=0, errors=0;
Session* g_focusOverride=nullptr;
const int WM_APP_UPDATESTATUS=17;
struct LockG { LockG(){++held;} ~LockG(){--held;} };
bool PostMessageW(int hwnd,int message,int w,int l){if(!held||hwnd!=g_hwnd||message!=WM_APP_UPDATESTATUS||w||l)++errors;++messages;return true;}
'@
$suffix=@'
int main(){
 Session popup;
 setFocusedPane(1);if(g_focus!=1||messages!=1||held)++errors;
 setFocusedPane(0);if(g_focus!=0||messages!=2||held)++errors;
 setFocusOverride(&popup);if(g_focusOverride!=&popup||messages!=3||held)++errors;
 setFocusOverride(nullptr);if(g_focusOverride||messages!=4||held)++errors;
 // Same pane index after owner selection still needs a fresh grid publication.
 setFocusedPane(0);if(messages!=5||held)++errors;
 g_hwnd=0;setFocusedPane(1);setFocusOverride(&popup);if(messages!=5||held)++errors;
 std::printf("focus status: 6 runtime checks + assignment coverage, %d failed\n",errors);return errors?1:0;
}
'@
$out=Join-Path $repo 'bin/focus-status-unit';New-Item -ItemType Directory -Force $out|Out-Null
$cpp=Join-Path $out 'focus-status-unit.cpp';[IO.File]::WriteAllText($cpp,($prefix+"`n"+$pane.Value+"`n"+$surface.Value+"`n"+$suffix))
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$testExe=Join-Path $out 'focus-status-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /EHsc /W4 /utf-8 `"$cpp`" /Fe:`"$testExe`" /Fo:`"$out/focus-status-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'Focus fixture compile failed'}
& $testExe
if($LASTEXITCODE-ne 0){throw 'Focus fixture failed'}
