# Clipboard/host-action acceptance shares the selection fixture's whole-format snapshot,
# exact per-action receipts, registry compare/restore and token-held owned teardown.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict,
      [string]$TokenOwner=$env:AGLITETERM_TEST_OWNER)
$ErrorActionPreference='Stop'
& "$PSScriptRoot/clipboard-acceptance.unit.ps1" -Strict:$Strict
& "$PSScriptRoot/selection-ui.ps1" -Exe $Exe -Strict:$Strict -TokenOwner $TokenOwner -ClipboardOnly
exit $LASTEXITCODE
