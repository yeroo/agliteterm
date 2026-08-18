# The control-API contract is CANONICAL in agwinterm (tests/conformance/control-api.json) and
# mirrored here. Two copies of a promise drift, and the drift is silent: both suites keep passing
# against their own stale idea of the contract while the two products quietly diverge.
#
# So CI compares them. A difference is not automatically a failure of this repository — agwinterm
# may have added a verb we have yet to implement — but it always demands a decision, which is the
# point.
[CmdletBinding()]
param(
    [string]$Url = 'https://raw.githubusercontent.com/yeroo/agwinterm/main/tests/conformance/control-api.json',
    [string]$Local = "$PSScriptRoot\..\test\control-api.json",
    [switch]$Update
)

$ErrorActionPreference = 'Stop'

try { $canonical = (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content }
catch {
    # Offline, or the path moved. Not a silent pass: say which, and let the caller decide.
    Write-Warning "could not fetch the canonical contract ($($_.Exception.Message))"
    exit 0
}

if ($Update) {
    Set-Content -Path $Local -Value $canonical -NoNewline -Encoding utf8
    "contract updated from $Url"
    exit 0
}

# Compare the PARSED contract, not the bytes: line endings and key order are not the promise.
function Normalize([string]$json) { ($json | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress) }
$a = Normalize $canonical
$b = Normalize (Get-Content $Local -Raw)

if ($a -eq $b) { "contract: in step with agwinterm"; exit 0 }

$canonVerbs = ($canonical | ConvertFrom-Json).steps.verb | Sort-Object -Unique
$localVerbs = ((Get-Content $Local -Raw) | ConvertFrom-Json).steps.verb | Sort-Object -Unique
$missing = $canonVerbs | Where-Object { $_ -notin $localVerbs }
$extra = $localVerbs | Where-Object { $_ -notin $canonVerbs }

"contract DRIFT against $Url"
if ($missing) { "  verbs agwinterm expects that this copy does not test: $($missing -join ', ')" }
if ($extra) { "  verbs this copy tests that agwinterm's contract does not: $($extra -join ', ')" }
if (-not $missing -and -not $extra) { "  same verbs, different expectations — a response shape changed on one side" }
"  reconcile with: ./tools/check-contract.ps1 -Update   (then make the checks pass, or push back)"
exit 1
