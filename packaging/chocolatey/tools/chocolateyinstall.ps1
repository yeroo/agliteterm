$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

$packageArgs = @{
    packageName    = 'agliteterm'
    unzipLocation  = $toolsDir
    url64bit       = 'https://github.com/yeroo/agliteterm/releases/download/v0.17.9/agliteterm-portable-0.17.9-win-x64.zip'
    checksum64     = '0000000000000000000000000000000000000000000000000000000000000000'
    checksumType64 = 'sha256'
}

# The PORTABLE build, not the setup: agliteterm's installer is per-user (Inno,
# PrivilegesRequired=lowest) and Chocolatey runs elevated, so packaging the setup would install it
# into the administrator's profile instead of the user's.
#
# Chocolatey auto-generates a shim on PATH for every exe here. Two markers shape that:
# agliteterm.exe.gui keeps the shim from holding the console, and agwinterm-ptyhost.exe.ignore
# keeps the pty-host — an internal helper, never run by hand — off PATH entirely.
#
# Settings live in %LOCALAPPDATA%\agliteterm and HKCU\Software\agliteterm wherever the exe sits, so
# this shares sessions and preferences with an installed copy on the same machine.
Install-ChocolateyZipPackage @packageArgs
