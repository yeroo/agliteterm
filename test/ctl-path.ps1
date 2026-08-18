# Where the checks find agwintermctl.
#
# The suite drives agliteterm through its control pipe, and it does that with the SAME client the
# full app uses — that is the point: "agliteterm speaks the agwintermctl dialect" is only true if
# the real client is what proves it. While lite lived in the agwinterm tree, that binary was simply
# an installed sibling and every check hardcoded its install path. In this repository it is an
# external dependency like the core dll, so it is resolved rather than assumed:
#
#   1. $env:AGWINTERMCTL           — an explicit override, and what CI sets
#   2. bin\agwintermctl.exe        — fetched next to the client by tools\fetch-native.ps1
#   3. the installed agwinterm     — a developer machine that has the full app, i.e. the old path
#
# Returns $null when none is present, so a caller can skip with a clear message instead of failing
# with "the term 'agwintermctl.exe' is not recognized" fifty times.
function Get-CtlPath {
    $candidates = @(
        $env:AGWINTERMCTL,
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\agwintermctl.exe'),
        "$env:LOCALAPPDATA\Programs\agwinterm\agwintermctl.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}
