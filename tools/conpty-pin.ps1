# The ConPTY the pty-host runs shells on: conpty.dll + OpenConsole.exe from Microsoft's
# Microsoft.Windows.Console.ConPTY NuGet package (MIT, the one Windows Terminal ships). Dot-sourced
# by tools\fetch-native.ps1 and test\fetch-native.unit.ps1.
#
# agwinterm-ptyhost.exe --conpty bundled loads conpty.dll from its own directory, and that dll starts
# the OpenConsole.exe beside it or in x64\. Unlike the conhost built into Windows it hands a
# program's questions to the terminal (colours, device attributes, cursor position) instead of
# swallowing them, and passes output through unchanged. With either file missing the host falls back
# to the inbox conhost, silently, so both are staged as a pair.
#
# They are not agwinterm release assets: agwinterm takes them from NuGet at build time, and so does
# this. native\pinned.json names the package version and the SHA-256 of its .nupkg; nothing is
# staged from a package whose hash is not that one.

$script:ConptyFix = "  check native\pinned.json's conpty entry, or run tools\fetch-native.ps1 -Force to refetch the package"

function Get-ConptyPin($Pin) {
    $entry = $Pin.conpty
    if (-not $entry) {
        throw ("native\pinned.json has no conpty entry - it names the Microsoft.Windows.Console.ConPTY package the pty-host's ConPTY comes from.`n" +
               "  Add e.g. `"conpty`": { `"package`": `"Microsoft.Windows.Console.ConPTY`", `"version`": `"1.24.260710001`", `"sha256`": `"<the .nupkg's SHA-256>`" }")
    }
    $package = [string]$entry.package; $version = [string]$entry.version; $sha = [string]$entry.sha256
    if ($package -cnotmatch '\A[A-Za-z0-9]+(\.[A-Za-z0-9]+)*\z') { throw "native\pinned.json conpty.package is not a NuGet package id: '$package'" }
    if ($version -cnotmatch '\A\d+(\.\d+){1,3}\z') { throw "native\pinned.json conpty.version is not a package version: '$version'" }
    if ($sha -cnotmatch '\A[0-9a-f]{64}\z') { throw "native\pinned.json conpty.sha256 must be 64 lower-case hex digits (the .nupkg's SHA-256), not '$sha'" }
    [pscustomobject]@{ Package = $package; Version = $version; Sha256 = $sha }
}

# nuget.org's flat container: all lower case, the version repeated in the file name.
function Get-ConptyPackageUrl($Conpty) {
    $id = $Conpty.Package.ToLowerInvariant()
    "https://api.nuget.org/v3-flatcontainer/$id/$($Conpty.Version)/$id.$($Conpty.Version).nupkg"
}

# The .nupkg on disk is the pinned one. A caller that caches the package deletes it when this
# throws: a file with another hash is a bad download, and the next run fetches it again.
function Assert-ConptyPackage([string]$Package, $Conpty) {
    if (-not (Test-Path -LiteralPath $Package)) { throw "$($Conpty.Package) $($Conpty.Version) was not staged: the package is not at $Package`n$script:ConptyFix" }
    $actual = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $Conpty.Sha256) {
        throw "$($Conpty.Package) $($Conpty.Version) was not staged: its SHA-256 is $actual, native\pinned.json pins $($Conpty.Sha256)`n$script:ConptyFix"
    }
}

# Stage the pair from a .nupkg on disk: bin\conpty.dll and bin\x64\OpenConsole.exe, the layout
# agwinterm ships. Three outcomes:
#   - the package is not the pinned one, or lacks either file: nothing is staged and what an
#     earlier run staged is removed, so a bin never holds a ConPTY nobody checked;
#   - a destination cannot be replaced (a pty-host started from this bin keeps conpty.dll loaded
#     for its whole life, and the host outlives the window): the pair already in bin is left as it
#     is and the message says to close that host - the package and the pin are fine;
#   - otherwise both files are in place. A destination that already holds the same bytes is not
#     rewritten, so a rebuild beside a running host succeeds when the pin has not moved.
# Both entries are extracted beside their destinations first and moved in only once both exist.
function Install-ConptyPackage([string]$Package, $Conpty, [string]$Bin) {
    $dll = Join-Path $Bin 'conpty.dll'
    $console = Join-Path $Bin 'x64\OpenConsole.exe'
    $wanted = [ordered]@{ 'runtimes/win-x64/native/conpty.dll' = $dll; 'build/native/runtimes/x64/OpenConsole.exe' = $console }
    $fresh = @{}
    try {
        try {
            Assert-ConptyPackage $Package $Conpty
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($Package)
            try {
                $found = @{}
                foreach ($name in $wanted.Keys) {
                    $entry = $zip.Entries | Where-Object { $_.FullName -ceq $name } | Select-Object -First 1
                    if (-not $entry -or $entry.Length -le 0) {
                        throw "$($Conpty.Package) $($Conpty.Version) was not staged: it has no $name`n$script:ConptyFix"
                    }
                    $found[$name] = $entry
                }
                foreach ($name in $wanted.Keys) {
                    $dest = $wanted[$name]
                    New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
                    $fresh[$name] = "$dest.staging"
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($found[$name], $fresh[$name], $true)
                }
            }
            finally { $zip.Dispose() }
        }
        catch {
            Remove-Item -LiteralPath $dll, $console -Force -ErrorAction SilentlyContinue
            throw
        }
        foreach ($name in $wanted.Keys) {
            $dest = $wanted[$name]
            if ((Test-Path -LiteralPath $dest) -and
                (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $fresh[$name] -Algorithm SHA256).Hash) { continue }
            try { Move-Item -LiteralPath $fresh[$name] -Destination $dest -Force }
            catch {
                throw ("$dest could not be replaced: $($_.Exception.Message)`n" +
                       "  a pty-host started from this bin keeps conpty.dll loaded while it runs - close every agliteterm using this bin (and its agwinterm-ptyhost.exe), then build again.`n" +
                       "  The package and native\pinned.json are fine; the ConPTY already in bin was left as it is.")
            }
        }
    }
    finally {
        foreach ($temp in $fresh.Values) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}
