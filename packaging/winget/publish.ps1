# Submit the winget manifests for a released version to microsoft/winget-pkgs.
#
# Why manifests in this repository rather than `wingetcreate update`, which is what agwinterm uses:
# `update` can only edit a package winget-pkgs ALREADY has. agliteterm has never been published, so
# the first submission has to carry a full manifest set. Keeping them here afterwards means every
# later submission goes the same way — one code path, and the metadata people actually read is
# reviewable in this repo rather than rewritten by a tool on each release.
#
# The committed manifests stay pinned at the last submitted version; this rewrites the version,
# the installer URL and its SHA-256 in place from the actual release asset, exactly like the
# Chocolatey publisher does.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,      # e.g. 0.17.9 (no leading v)
    [Parameter(Mandatory)][string]$Token,        # PAT with public_repo (forks winget-pkgs, opens the PR)
    [string]$Repository = 'yeroo/agliteterm',
    [string]$OutputDir = $env:RUNNER_TEMP,
    [switch]$NoSubmit                            # render + validate only (what CI dry-runs on a PR)
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = [IO.Path]::GetTempPath() }

$here  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$asset = "agliteterm-setup-$Version.exe"
$url   = "https://github.com/$Repository/releases/download/v$Version/$asset"

Write-Host "== downloading $asset for its checksum =="
$tmp = Join-Path $OutputDir $asset
Invoke-WebRequest $url -OutFile $tmp
$sha = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToUpper()   # winget manifests carry it uppercase
Write-Host "sha256: $sha"

# Render into a working directory: the submission must never depend on a dirty checkout, and a
# failed run must not leave rewritten manifests behind in the repository.
$work = Join-Path $OutputDir "winget-$Version"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory $work | Out-Null

foreach ($f in Get-ChildItem $here -Filter '*.yaml') {
    $c = Get-Content $f.FullName -Raw
    $c = $c -replace '(?m)^PackageVersion:.*$', "PackageVersion: $Version"
    $c = $c -replace 'download/v[^/]+/agliteterm-setup-[^\s]+\.exe', "download/v$Version/$asset"
    $c = $c -replace '(?m)^(\s*InstallerSha256:).*$', "`$1 $sha"
    $c = $c -replace 'releases/tag/v[0-9][^\s]*', "releases/tag/v$Version"
    Set-Content (Join-Path $work $f.Name) $c -Encoding UTF8
    # Keep the repository copies in step, so the committed manifests always show what was last
    # submitted — the same convention as the nuspec.
    Set-Content $f.FullName $c -Encoding UTF8
}
Get-ChildItem $work | ForEach-Object { "  rendered $($_.Name)" }

# Validate before submitting when winget is present. It is not on every runner image, and its
# absence must not block a release — but when it IS there, a schema error caught here costs
# seconds instead of a rejected pull request.
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($winget) {
    & $winget.Source validate --manifest $work
    if ($LASTEXITCODE -ne 0) { throw 'winget validate rejected the manifests' }
} else {
    Write-Warning 'winget.exe not on this runner - skipping local manifest validation'
}

if ($NoSubmit) { Write-Host "== rendered only (-NoSubmit); nothing submitted =="; return }

# Sync the fork FIRST. wingetcreate refuses to open a PR from a fork that has drifted ("The forked
# repository could not be synced with the upstream commits"), and upstream touches its workflows
# often enough that this recurs — it has blocked an agwinterm release before. merge-upstream is
# server-side, so it needs no checkout. Best-effort: a fresh fork (or none yet) must not fail here.
$owner = $Repository.Split('/')[0]
try {
    $h = @{ Authorization = "token $Token"; 'User-Agent' = 'agliteterm-release'; Accept = 'application/vnd.github+json' }
    $r = Invoke-RestMethod -Method Post -Headers $h -Body (@{ branch = 'master' } | ConvertTo-Json) `
         -Uri "https://api.github.com/repos/$owner/winget-pkgs/merge-upstream"
    Write-Host "fork sync: $($r.message)"
} catch { Write-Warning "fork sync skipped: $($_.Exception.Message)" }

$wc = Join-Path $OutputDir 'wingetcreate.exe'
Invoke-WebRequest https://aka.ms/wingetcreate/latest -OutFile $wc
Write-Host "== submitting yeroo.agliteterm $Version =="
& $wc submit --token $Token $work
if ($LASTEXITCODE -ne 0) { throw 'wingetcreate submit failed' }
Write-Host "== submitted; the PR is now in winget-pkgs moderation =="
