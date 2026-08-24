# Pack and push the Chocolatey package for a released version.
#
# Shared by two callers so the packaging steps can never drift apart:
#   - release.yml's `chocolatey` job, on every checkpoint tag
#   - choco-push.yml (workflow_dispatch), to REPUSH a version whose package changed but whose
#     version must not — which is exactly what Chocolatey moderation asks for ("repush your updated
#     package with the exact same version"). That path runs from the default branch, so packaging
#     fixes land without re-tagging or burning a version number.
#
# The committed nuspec/install script stay pinned at whatever was last released; this rewrites the
# version, download URL and checksum in place from the actual release asset.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,      # e.g. 0.17.9 (no leading v)
    [Parameter(Mandatory)][string]$ApiKey,
    [string]$Repository = 'yeroo/agliteterm',
    [string]$OutputDir = $env:RUNNER_TEMP
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = [IO.Path]::GetTempPath() }

$here  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$asset = "agliteterm-portable-$Version-win-x64.zip"
$url   = "https://github.com/$Repository/releases/download/v$Version/$asset"

# tools\ must contain ONLY the install/uninstall scripts and the shim markers. VERIFICATION.txt and
# LICENSE.txt belong to packages that EMBED a binary; this one downloads it in the install script,
# and shipping them anyway is what got an agwinterm release held for corrective action. Checked
# before the download so a packaging mistake fails in a second rather than after fetching the asset.
foreach ($stray in 'tools/VERIFICATION.txt', 'tools/LICENSE.txt') {
    if (Test-Path (Join-Path $here $stray)) {
        throw "$stray must not be in a download-based package (Chocolatey moderation rejects it)"
    }
}

Write-Host "== downloading $asset for its checksum =="
$tmp = Join-Path $OutputDir $asset
Invoke-WebRequest $url -OutFile $tmp
$sha = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
Write-Host "sha256: $sha"

Push-Location $here
try {
    $nuspec = Get-Content agliteterm.nuspec -Raw
    $nuspec = $nuspec -replace '(?<=<version>)[^<]+(?=</version>)', $Version
    # The icon and release notes are pinned per version too: jsdelivr serves the tag, and a link to
    # last release's notes on this release's package is a small lie that moderation does spot.
    $nuspec = $nuspec -replace 'agliteterm@v[0-9][^/]*', "agliteterm@v$Version"
    $nuspec = $nuspec -replace 'releases/tag/v[0-9][^<]*', "releases/tag/v$Version"
    Set-Content agliteterm.nuspec $nuspec

    $ps = 'tools/chocolateyinstall.ps1'
    $c = Get-Content $ps -Raw
    $c = $c -replace 'download/v[^/]+/agliteterm-portable-[^'']+\.zip', "download/v$Version/$asset"
    $c = $c -replace "checksum64\s+= '[0-9a-fA-F]+'", "checksum64     = '$sha'"
    Set-Content $ps $c

    Write-Host "== pack =="
    choco pack --outputdirectory $OutputDir
    if ($LASTEXITCODE -ne 0) { throw 'choco pack failed' }

    Write-Host "== push $Version =="
    choco push (Join-Path $OutputDir "agliteterm.$Version.nupkg") --source https://push.chocolatey.org/ --api-key $ApiKey
    if ($LASTEXITCODE -ne 0) { throw 'choco push failed' }
} finally { Pop-Location }

Write-Host "== pushed agliteterm $Version =="
