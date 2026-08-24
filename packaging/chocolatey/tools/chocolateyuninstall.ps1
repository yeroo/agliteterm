$ErrorActionPreference = 'Stop'

# The portable payload was unpacked into the package's tools dir, which Chocolatey deletes on
# uninstall along with the shims it generated — so the files go with the package. This only makes
# sure a RUNNING agliteterm doesn't leave its exe behind and turn the uninstall into a half-removal.
#
# User settings under %LOCALAPPDATA%\agliteterm and HKCU\Software\agliteterm are deliberately kept:
# reinstalling should find your sessions where you left them.
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
foreach ($f in 'agliteterm.exe', 'agwinterm-ptyhost.exe', 'agwinterm_core.dll') {
    $p = Join-Path $toolsDir $f
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}
