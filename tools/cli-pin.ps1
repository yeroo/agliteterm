# The pure half of fetch-native's CLI step: which agwintermctl the checks drive, and whether the one
# staged in bin is that one. Dot-sourced by tools\fetch-native.ps1 and test\fetch-native.unit.ps1.
#
# The CLI has its own pin (cliTag in native\pinned.json) because it answers to a different clock
# than the core: the core must match kRequiredAbi exactly, while the checks want a client new
# enough for every contract feature lite answers. Tying the two let local runs drive lite with a
# client older than CI's (#109). The CLI is never shipped - it only drives the checks.

function Get-CliPin($Pin) {
    $tag = [string]$Pin.cliTag
    if ([string]::IsNullOrWhiteSpace($tag)) {
        throw ("native\pinned.json has no cliTag - it names the agwintermctl release the checks drive lite with.`n" +
               "  Add e.g. `"cliTag`": `"v0.20.11`" (or `"latest`").")
    }
    return $tag
}

$script:CliFix = "  run tools\fetch-native.ps1 -Force to refetch it, or set AGWINTERMCTL to test with a dev build"

# The staged exe could not be run at all (a truncated download, AV or app control blocking it).
function Get-CliLaunchFailure([string]$CliTag, [string]$Reason) {
    "the agwintermctl.exe fetched for cliTag $CliTag could not be run, so it was removed from bin and the cache: $Reason`n$script:CliFix"
}

# $VersionOutput is what `agwintermctl version` printed; its first line is `cli <version> <path>`.
function Assert-CliVersion([string]$VersionOutput, [string]$CliTag) {
    if ($CliTag -eq 'latest') { return }   # latest has no fixed number to compare against
    $fix = $script:CliFix
    $m = [regex]::Match($VersionOutput, '(?m)^cli (\S+)')
    if (-not $m.Success) {
        throw ("the staged agwintermctl.exe printed no 'cli <version>' line, so it cannot be checked against cliTag $CliTag.`n" +
               "  output: $($VersionOutput.Trim())`n$fix")
    }
    $want = $CliTag -replace '^v', ''
    if ($m.Groups[1].Value -ne $want) {
        throw ("the staged agwintermctl.exe is cli $($m.Groups[1].Value), but native\pinned.json pins cliTag $CliTag.`n$fix")
    }
}
