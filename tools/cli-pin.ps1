# The offline half of fetch-native's CLI step: which agwintermctl the checks drive, and admitting
# the one staged in bin only when it is that one. Dot-sourced by tools\fetch-native.ps1 and
# test\fetch-native.unit.ps1.
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

# Copies the cached CLI to bin and admits it only if it runs and reports $CliTag. A refused client
# must not stay in bin, where test\ctl-path.ps1 would still pick it up. One that never ran (a
# truncated download, AV or app control blocking it) is dropped from the cache too, since every
# later run would copy it; one that ran but is the wrong version keeps its cache, the message says why.
function Install-CheckedCli([string]$Cached, [string]$Staged, [string]$CliTag) {
    Copy-Item $Cached $Staged -Force
    # A pipe nothing answers on, and none of the pane variables that would point the CLI at the app
    # this may be running inside: the probe must never talk to a live instance.
    $paneVars = 'AGWINTERM_PIPE', 'AGWINTERM_SESSION_ID', 'AGWINTERM_PANE_ID'
    $saved = @{}
    $output = $null
    try {
        foreach ($v in $paneVars) { $saved[$v] = [Environment]::GetEnvironmentVariable($v); [Environment]::SetEnvironmentVariable($v, $null) }
        $eap = $ErrorActionPreference
        try {
            # Only the cli line identifies the client; the exit code is about the app, and none answers
            # here. Continue, so stderr under 2>&1 is output to check, not a PS 5.1 terminating error.
            $ErrorActionPreference = 'Continue'
            $output = (& $Staged version --pipe "agliteterm-fetch-probe-$([guid]::NewGuid().ToString('N'))" 2>&1 | Out-String)
            $global:LASTEXITCODE = 0
        }
        finally {
            $ErrorActionPreference = $eap
            foreach ($v in $paneVars) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
        }
        Assert-CliVersion $output $CliTag
    }
    catch {
        Remove-Item $Staged -Force -ErrorAction SilentlyContinue
        if ($null -ne $output) { throw }
        Remove-Item $Cached -Force -ErrorAction SilentlyContinue
        throw (Get-CliLaunchFailure $CliTag $_.Exception.Message)
    }
}
