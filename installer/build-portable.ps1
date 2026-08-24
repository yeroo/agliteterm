# Build the portable agliteterm: installer\Output\agliteterm-portable-<ver>-win-x64.zip
#
# Same payload as the setup — the client, its pinned agwinterm-ptyhost.exe and agwinterm_core.dll,
# and the bundled fonts — with no installer around it. Unzip anywhere and run agliteterm.exe.
#
# It exists for two reasons. A machine that cannot (or should not) run an installer is exactly the
# machine this product is for. And the Chocolatey package needs it: the setup is a PER-USER Inno
# installer (PrivilegesRequired=lowest), and Chocolatey runs elevated — so packaging the setup
# would install agliteterm into the ADMINISTRATOR's profile, not the user's. A portable zip has no
# such ambiguity.
#
# Settings still live in %LOCALAPPDATA%\agliteterm and HKCU\Software\agliteterm, so a portable copy
# and an installed one share their sessions and preferences on the same machine.
param([string]$NativeDir = $env:AGLITETERM_NATIVE_DIR)

$ErrorActionPreference = 'Stop'
$here  = $PSScriptRoot
$root  = Split-Path -Parent $here
$stage = Join-Path $here 'stage'
$out   = Join-Path $here 'Output'

$issText = Get-Content (Join-Path $here 'agliteterm.iss') -Raw
if ($issText -notmatch '#define\s+AppVersion\s+"([^"]+)"') { throw 'AppVersion not found in agliteterm.iss' }
$ver = $Matches[1]

# The setup build stages everything; reuse that staging rather than duplicating the file list, so
# the zip and the installer can never ship different payloads.
if (-not (Test-Path (Join-Path $stage 'agliteterm.exe'))) {
    Write-Host '== no staged build; running installer\build.ps1 first ==' -ForegroundColor Cyan
    & (Join-Path $here 'build.ps1') -NativeDir $NativeDir
    if ($LASTEXITCODE -ne 0) { throw 'installer build failed' }
}
foreach ($f in @('agliteterm.exe', 'agwinterm-ptyhost.exe', 'agwinterm_core.dll', 'agliteterm.ico')) {
    if (-not (Test-Path (Join-Path $stage $f))) { throw "stage is missing $f" }
}

# The license travels with the binaries here (it does not in the setup, where Add/Remove Programs
# and the repository carry it) — a zip someone downloaded has no other link back to its terms.
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $stage 'LICENSE.txt') -Force

New-Item -ItemType Directory -Force $out | Out-Null
$zip = Join-Path $out "agliteterm-portable-$ver-win-x64.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal

# Prove the archive is what it claims to be: a zip that unpacks without the exe is a broken
# release nobody notices until someone downloads it.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$names = [IO.Compression.ZipFile]::OpenRead($zip).Entries.FullName
foreach ($f in @('agliteterm.exe', 'agwinterm_core.dll', 'agwinterm-ptyhost.exe')) {
    if ($names -notcontains $f) { throw "the portable zip is missing $f" }
}
Write-Host ("== done: {0} ({1:N1} MB, {2} files) ==" -f $zip, ((Get-Item $zip).Length / 1MB), $names.Count) -ForegroundColor Green
