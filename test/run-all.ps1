# Run every lite check. Integration checks drive the built exe; driving.unit compiles its
# in-process C++ harness. Build first: ./build.ps1 (MSVC is also required by driving.unit).
param(
    [string]$Exe = "$PSScriptRoot\..\bin\agliteterm.exe",
    # Passed through to the checks that can skip (they need agwintermctl). In CI a skip is a
    # failure: a suite reporting success while checking nothing is worse than no suite.
    [switch]$Strict
)

$ErrorActionPreference = 'Continue'
$failed = @()
# Selection UI checks use window-scoped messages and PrintWindow; qa/selection.md also records manual cases.
# Local token-owning callers pass AGLITETERM_TEST_RECEIPT so selection-ui borrows that live lease.
foreach ($t in 'configuration.unit', 'driving.unit', 'owned-procs-checks', 'registry-guard.unit', 'clipboard-guard.tests', 'clipboard-receipt.unit', 'selection-clipboard.unit', 'log-basics', 'log-restore', 'log-focus-font', 'log-rotation', 'diagnose', 'migration', 'restore-matrix', 'conformance', 'clipboard', 'agbf-packs', 'control-read', 'control-honesty', 'selection-ui') {
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
