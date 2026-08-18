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

function Get-Asset([string]$name, [string]$dest) {
    if (Test-Path $dest) { return }
    $url = "$base/$name"
    try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing }
    catch {
        # The likeliest cause by far, and the one worth naming: that release predates the
        # ABI-stamped assets, or the tag is wrong.
        throw ("could not download $name from $repo@$($pin.tag): $($_.Exception.Message)`n" +
               "  the release must carry ABI-stamped core assets (added in agwinterm 0.17.4).`n" +
               "  to build against an unreleased core, pass -NativeDir <agwinterm>\native\target\release")
    }
}

$manifestPath = Join-Path $cache 'agwinterm-core-abi.json'
Get-Asset 'agwinterm-core-abi.json' $manifestPath
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
    Get-Asset $stamped $dest
    Copy-Item $dest (Join-Path $bin $f) -Force
}

# The control client the checks drive agliteterm with. Not ABI-stamped and not needed to BUILD,
# so a release that predates it is not an error here — test\ctl-path.ps1 falls back to an installed
# agwinterm, and the checks that need it skip with a message rather than failing obscurely.
$ctlDest = Join-Path $cache 'agwintermctl.exe'
if (-not (Test-Path $ctlDest)) {
    try { Invoke-WebRequest -Uri "$base/agwintermctl.exe" -OutFile $ctlDest -UseBasicParsing }
    catch { Write-Warning "agwintermctl.exe not published by $repo@$($pin.tag) - control-pipe checks will skip" }
}
if (Test-Path $ctlDest) { Copy-Item $ctlDest (Join-Path $bin 'agwintermctl.exe') -Force }

"native: $repo@$($pin.tag) abi $requiredAbi (cached in .native\$($pin.tag))"
