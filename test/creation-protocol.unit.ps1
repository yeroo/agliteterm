param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop';$repo=Split-Path $PSScriptRoot -Parent
$out=Join-Path $repo 'bin/creation-protocol-unit';New-Item -ItemType Directory -Force $out|Out-Null
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $vs){throw 'MSVC required'}
$testExe=Join-Path $out 'creation-protocol-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 /DPB_FIELD_32BIT /I `"$repo/src/proto`" `"$PSScriptRoot/creation-protocol.unit.cpp`" /Fe:`"$testExe`" /Fo:`"$out/creation-protocol-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'Creation protocol fixture compile failed'}
& $testExe
if($LASTEXITCODE-ne 0){throw 'Creation protocol fixture failed'}
$main=Get-Content "$repo/src/main.cpp" -Raw
$call=[regex]::Match($main,'(?s)std::string expectedTicket;\s*for \(const auto& hs : g_hostLive\).*?s = attachSession\(.*?;')
if(-not $call.Success){throw 'Actual adoption list-to-attach wiring not found'}
$fixture=(Get-Content "$PSScriptRoot/adoption-ticket.unit.cpp" -Raw).Replace('// ACTUAL_ADOPTION_CALL',$call.Value)
$source=Join-Path $out 'adoption-ticket-unit.cpp';[IO.File]::WriteAllText($source,$fixture)
$adoptionExe=Join-Path $out 'adoption-ticket-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 `"$source`" /Fe:`"$adoptionExe`" /Fo:`"$out/adoption-ticket-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'Adoption fixture compile failed'}
& $adoptionExe
if($LASTEXITCODE-ne 0){throw 'Adoption incarnation wiring fixture failed'}
# agliteterm #82: a reader's end-of-stream is the shell exiting only when the host says so. Compile the
# production HostSession and hostListSaysAlive, so a renamed field or a changed rule fails here.
$hostSession=[regex]::Match($main,'(?ms)^struct HostSession \{.*?^\};')
$saysAlive=[regex]::Match($main,'(?ms)^static bool hostListSaysAlive\(.*?^\}')
if(-not $hostSession.Success -or -not $saysAlive.Success){throw 'Actual stream-end helpers not found (HostSession/hostListSaysAlive)'}
$streamSource=(Get-Content "$PSScriptRoot/stream-end.unit.cpp" -Raw).Replace('// ACTUAL_HOST_SESSION_STRUCT',$hostSession.Value).Replace('// ACTUAL_HOST_LIST_SAYS_ALIVE',$saysAlive.Value)
$streamCpp=Join-Path $out 'stream-end-unit.cpp';[IO.File]::WriteAllText($streamCpp,$streamSource)
$streamExe=Join-Path $out 'stream-end-unit.exe'
& cmd /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" && cl /nologo /std:c++17 /EHsc /W4 /utf-8 `"$streamCpp`" /Fe:`"$streamExe`" /Fo:`"$out/stream-end-unit.obj`""
if($LASTEXITCODE-ne 0){throw 'Stream end fixture compile failed'}
& $streamExe
if($LASTEXITCODE-ne 0){throw 'Stream end fixture failed'}
