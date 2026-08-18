# Build the agliteterm Inno setup: installer\Output\agliteterm-setup-<ver>.exe
#
# The setup is self-contained — the client, its pinned copy of agwinterm-ptyhost.exe and
# agwinterm_core.dll, and the bundled fonts — so an install needs nothing else on the machine.
param([string]$NativeDir = $env:AGLITETERM_NATIVE_DIR)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$stage = Join-Path $here 'stage'

# resolve ISCC (Inno Setup compiler): PATH, machine-wide (choco/CI), and the per-user winget location.
$iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
  $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
            "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw "ISCC (Inno Setup compiler) not found. Install Inno Setup 6 (winget install JRSoftware.InnoSetup)." }

$issText = Get-Content (Join-Path $here 'agliteterm.iss') -Raw
if ($issText -notmatch '#define\s+AppVersion\s+"([^"]+)"') { throw 'AppVersion not found in agliteterm.iss' }
$ver = $Matches[1]

Write-Host "== build agliteterm (v$ver) ==" -ForegroundColor Cyan
& (Join-Path $root 'build.ps1') -NativeDir $NativeDir
if ($LASTEXITCODE -ne 0) { throw 'build failed' }

# Stage: the exe + its pinned core/pty-host (build.ps1 drops all three in bin\) + ALL bundled
# assets (fonts + licenses + the app icon). Named files are asserted so a staging slip fails here
# rather than shipping a setup that installs a client with no fonts.
Write-Host '== stage ==' -ForegroundColor Cyan
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
$bin = Join-Path $root 'bin'
foreach ($f in @('agliteterm.exe', 'agwinterm-ptyhost.exe', 'agwinterm_core.dll')) {
  if (-not (Test-Path (Join-Path $bin $f))) { throw "bin is missing $f" }
  Copy-Item (Join-Path $bin $f) $stage -Force
}
Copy-Item (Join-Path $root 'assets\*') $stage -Force   # fonts + licenses + app icon
foreach ($f in @('agliteterm.ico', 'CozetteVector.ttf', 'MesloLGLDZNerdFont-Regular.ttf')) {
  if (-not (Test-Path (Join-Path $stage $f))) { throw "stage is missing $f" }
}

Write-Host '== compile installer (ISCC) ==' -ForegroundColor Cyan
& $iscc (Join-Path $here 'agliteterm.iss')
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }
$out = Join-Path $here "Output\agliteterm-setup-$ver.exe"
Write-Host ("== done: {0} ({1:N1} MB) ==" -f $out, ((Get-Item $out).Length / 1MB)) -ForegroundColor Green
