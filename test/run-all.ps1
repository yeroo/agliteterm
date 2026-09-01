# Run every lite check. These drive the BUILT exe (lite has no C++ unit-test harness), so build
# first: ./build.ps1
param(
    [string]$Exe = "$PSScriptRoot\..\bin\agliteterm.exe",
    # Passed through to the checks that can skip (they need agwintermctl). In CI a skip is a
    # failure: a suite reporting success while checking nothing is worse than no suite.
    [switch]$Strict
)

$ErrorActionPreference = 'Continue'
$failed = @()
# NOTE: the SELECTION checks moved to qa/selection.md — markdown cases an agent executes through the
# ui-qa skill, because they need a real window, real mouse buttons and a modifier a program can
# actually see, and because the interesting ones are about intent that reads badly as code.
# clipboard.ps1 stays: CI runs this runner, and its OSC 52 / host-action drain coverage would have
# no home until the markdown cases have a CI story of their own.
foreach ($t in 'log-basics', 'log-restore', 'log-focus-font', 'log-rotation', 'diagnose', 'migration', 'restore-matrix', 'conformance', 'clipboard', 'agbf-packs') {
    $script = Join-Path $PSScriptRoot "$t.ps1"
    if (-not (Test-Path $script)) { continue }
    # Each child sets $ErrorActionPreference = 'Stop', so it can die before reaching its own exit
    # statement. Without the reset + catch, $LASTEXITCODE would still hold the PREVIOUS script's 0
    # and a script that crashed would be reported as passing.
    $global:LASTEXITCODE = 0
    try { if ($Strict) { & $script -Exe $Exe -Strict } else { & $script -Exe $Exe } }
    catch { "  ERROR  $t terminated: $($_.Exception.Message)"; $global:LASTEXITCODE = 1 }
    if ($LASTEXITCODE -ne 0) { $failed += $t }
    ""
}
if ($failed.Count) { "FAILED: $($failed -join ', ')"; exit 1 }
"all lite checks passed"
exit 0
