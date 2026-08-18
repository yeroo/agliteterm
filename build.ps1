# Build agliteterm: MSVC cl.exe (located via vswhere) against a PINNED agwinterm core.
# Output: bin\ with agliteterm.exe + agwinterm_core.dll + agwinterm-ptyhost.exe + the bundled fonts.
#
# The core and pty-host are not built here — they live in the agwinterm repository and arrive as
# ABI-stamped release assets (tools\fetch-native.ps1, pinned by native\pinned.json). To build
# against a core you are changing, point at its target\release:
#
#   ./build.ps1 -NativeDir C:\src\agwinterm\native\target\release
#
param([string]$NativeDir = $env:AGLITETERM_NATIVE_DIR, [switch]$ForceFetch)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# 1) The core + pty-host this client rides on (downloaded and ABI-checked, or taken locally).
& (Join-Path $root 'tools\fetch-native.ps1') -NativeDir $NativeDir -Force:$ForceFetch

# 2) Locate MSVC.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found - install VS Build Tools' }
# WTL needs ATL headers, so require the ATL component (fall back to plain C++ tools with a clear error).
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.ATL -property installationPath
if (-not $vs) { $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.ATLMFC -property installationPath }
if (-not $vs) { throw 'no VS installation with ATL found - install "C++ ATL for latest v143 build tools" (Microsoft.VisualStudio.Component.VC.ATL)' }

# 3) Compile inside the VS dev environment (x64).
$bin = Join-Path $root 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$src = Join-Path $root 'src\main.cpp'
$pb = Join-Path $root 'src\proto'
$wtl = Join-Path $root 'third_party\wtl'
$rc = Join-Path $root 'src\agliteterm.rc'

# Version comes from the installer script, so exe and setup can never disagree — the self-update
# compares this against GitHub releases. Missing iss (odd checkout) -> "dev", which never updates.
$ver = 'dev'
$iss = Join-Path $root 'installer\agliteterm.iss'
if (Test-Path $iss) {
  $m = Select-String -Path $iss -Pattern '#define AppVersion "([^"]+)"'
  if ($m) { $ver = $m.Matches[0].Groups[1].Value }
}
$cmd = "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" && rc /nologo /fo `"$bin\agliteterm.res`" `"$rc`" && cl /nologo /O2 /W3 /EHsc /utf-8 /DUNICODE /D_UNICODE /DPB_FIELD_32BIT /DAGWL_VERSION_STR=`"\`"$ver\`"`" /I `"$pb`" /I `"$wtl`" `"$src`" `"$pb\ptyhost.pb.c`" `"$pb\pb_encode.c`" `"$pb\pb_decode.c`" `"$pb\pb_common.c`" /Fe:`"$bin\agliteterm.exe`" /Fo:`"$bin\\`" user32.lib gdi32.lib `"$bin\agliteterm.res`""
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { throw 'cl.exe failed' }

# 4) Stage the bundled fonts + licenses next to the exe.
Copy-Item (Join-Path $root 'assets\*') $bin -Force

"built: $bin\agliteterm.exe (v$ver)"
