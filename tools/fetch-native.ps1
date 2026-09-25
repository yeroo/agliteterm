# agliteterm rides on two binaries it does not build: agwinterm_core.dll (the Rust emulator core)
# and agwinterm-ptyhost.exe (the shell host). They live in the agwinterm repository and are
# published per release as ABI-stamped assets.
#
# The C ABI carries NO compatibility guarantee across versions — src/main.cpp requires exactly one
# abiVersion, and a mismatched pair is a fatal refusal at load. While both lived in one tree that
# could only be wrong for as long as it took to rebuild. Across two repositories it can be wrong
# for a whole release cycle, so this checks the pairing BEFORE the build rather than at load:
#
#   1. read the required ABI out of src/main.cpp — one source of truth, the code that enforces it
#   2. read native/pinned.json for the agwinterm release to take the core from
#   3. download that release's manifest and refuse if its abiVersion is not the one we require
#   4. cache under .native/<tag>/, so a rebuild is offline and reproducible
#
# It also stages agwintermctl.exe, the control client the checks drive lite with. That has its own
# pin, cliTag in native/pinned.json, cached under .native/cli-<cliTag>/, and the staged copy must
# report that version on every run. 'latest' has no version to check, so it is refetched every run
# instead, falling back to the cached copy with a warning when offline. -Tag overrides the core tag
# only; it no longer moves the CLI.
#
# -NativeDir (or AGLITETERM_NATIVE_DIR) takes a local agwinterm checkout's target\release instead,
# which is how you work on the core and the client together — and the only way to build against a
# core that has not been released yet.
[CmdletBinding()]
param(
    [string]$NativeDir = $env:AGLITETERM_NATIVE_DIR,
    [string]$Tag,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bin = Join-Path $root 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null

$wanted = @('agwinterm_core.dll', 'agwinterm-ptyhost.exe')

# --- what this client demands -------------------------------------------------------------------
$mainCpp = Join-Path $root 'src\main.cpp'
$m = Select-String -Path $mainCpp -Pattern 'kRequiredAbi\s*=\s*(\d+)' | Select-Object -First 1
if (-not $m) { throw "kRequiredAbi not found in src\main.cpp - cannot verify the core pairing" }
$requiredAbi = [int]$m.Matches[0].Groups[1].Value

# --- a local core beats a downloaded one --------------------------------------------------------
if ($NativeDir) {
    if (-not (Test-Path $NativeDir)) { throw "NativeDir does not exist: $NativeDir" }
    foreach ($f in $wanted) {
        $src = Join-Path $NativeDir $f
        if (-not (Test-Path $src)) { throw "NativeDir is missing $f - build the agwinterm workspace first (cargo build --release)" }
        Copy-Item $src $bin -Force
    }
    # No manifest to check against a local build: the ABI is whatever that tree compiled. The
    # handshake in main.cpp still refuses a mismatch at load, which is the pre-split behaviour.
    "native: local $NativeDir (abi unchecked - local build)"
    return
}

# --- the pinned release -------------------------------------------------------------------------
$pinFile = Join-Path $root 'native\pinned.json'
if (-not (Test-Path $pinFile)) { throw "native\pinned.json not found - it names the agwinterm release to build against" }
$pin = Get-Content $pinFile -Raw | ConvertFrom-Json
$repo = $pin.repo
if ($Tag) { $pin.tag = $Tag }

$base = if ($pin.tag -eq 'latest') { "https://github.com/$repo/releases/latest/download" }
        else { "https://github.com/$repo/releases/download/$($pin.tag)" }
$cache = Join-Path $root ".native\$($pin.tag)"

if ($Force -and (Test-Path $cache)) { Remove-Item -Recurse -Force $cache }
New-Item -ItemType Directory -Force $cache | Out-Null

# The likeliest cause of a failed core download by far, and the one worth naming: that release
# predates the ABI-stamped assets, or the tag is wrong.
$coreHint = ("  the release must carry ABI-stamped core assets (added in agwinterm 0.17.4).`n" +
             "  to build against an unreleased core, pass -NativeDir <agwinterm>\native\target\release")

function Get-Asset([string]$from, [string]$tag, [string]$name, [string]$dest, [string]$hint) {
    if (Test-Path $dest) { return }
    try { Invoke-WebRequest -Uri "$from/$name" -OutFile $dest -UseBasicParsing }
    catch {
        # A failed request can leave a partial file, which the next run would take as cached.
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        throw "could not download $name from $repo@${tag}: $($_.Exception.Message)`n$hint"
    }
}

$manifestPath = Join-Path $cache 'agwinterm-core-abi.json'
Get-Asset $base $pin.tag 'agwinterm-core-abi.json' $manifestPath $coreHint
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
if ([int]$manifest.abiVersion -ne $requiredAbi) {
    throw ("ABI mismatch: src\main.cpp requires abi $requiredAbi but $repo@$($pin.tag) publishes abi $($manifest.abiVersion).`n" +
           "  Pin a release that matches, or update kRequiredAbi with the code that goes with it.`n" +
           "  The C ABI has no cross-version compatibility guarantee - a mismatched pair refuses to load.")
}

foreach ($f in $wanted) {
    # The published assets are ABI-stamped so several can coexist on one release page; they are
    # renamed back to the plain names the client loads by filename.
    $stamped = $f -replace '(\.[^.]+)$', "-abi$requiredAbi`$1"
    $dest = Join-Path $cache $stamped
    Get-Asset $base $pin.tag $stamped $dest $coreHint
    Copy-Item $dest (Join-Path $bin $f) -Force
}

# The control client the checks drive agliteterm with. Not needed to BUILD and never shipped, but
# pinned on its own (cliTag) so a local run and CI drive lite with the same client, and checked
# on every run so a stale cache or a hand-dropped exe cannot stand in for it.
. (Join-Path $PSScriptRoot 'cli-pin.ps1')
$cliTag = Get-CliPin $pin
$cliBase = if ($cliTag -eq 'latest') { "https://github.com/$repo/releases/latest/download" }
           else { "https://github.com/$repo/releases/download/$cliTag" }
$cliCache = Join-Path $root ".native\cli-$cliTag"
if ($Force -and (Test-Path $cliCache)) { Remove-Item -Recurse -Force $cliCache }
New-Item -ItemType Directory -Force $cliCache | Out-Null
$ctlCached = Join-Path $cliCache 'agwintermctl.exe'
# Whatever an earlier run staged is unchecked until this step passes, so a failure anywhere below
# leaves no CLI in bin rather than one test\ctl-path.ps1 would still pick up.
$ctlStaged = Join-Path $bin 'agwintermctl.exe'
Remove-Item $ctlStaged -Force -ErrorAction SilentlyContinue
$cliHint = ("  native\pinned.json's cliTag must name an agwinterm release that publishes agwintermctl.exe.`n" +
            "  to test with an unreleased CLI, set AGWINTERMCTL to a dev build")
if ($cliTag -eq 'latest') {
    # latest has no version to check the cache against, so a cached copy would freeze at the first
    # fetch unnoticed: take it afresh each run. Into a side file, so a failed download (offline, rate
    # limited) keeps the cached copy to build with rather than failing the build.
    $ctlFresh = "$ctlCached.download"
    Remove-Item $ctlFresh -Force -ErrorAction SilentlyContinue
    try {
        Get-Asset $cliBase $cliTag 'agwintermctl.exe' $ctlFresh $cliHint
        Move-Item $ctlFresh $ctlCached -Force
    }
    catch {
        if (-not (Test-Path $ctlCached)) { throw }
        Write-Warning "could not refresh the latest agwintermctl.exe, so the cached copy is used and may be stale: $($_.Exception.Message)"
    }
}
else { Get-Asset $cliBase $cliTag 'agwintermctl.exe' $ctlCached $cliHint }
Install-CheckedCli -Cached $ctlCached -Staged $ctlStaged -CliTag $cliTag

"native: $repo@$($pin.tag) abi $requiredAbi (cached in .native\$($pin.tag)); cli $cliTag (cached in .native\cli-$cliTag)"
