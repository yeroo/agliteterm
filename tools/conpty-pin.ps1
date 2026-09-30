# The ConPTY the pty-host runs shells on: conpty.dll + OpenConsole.exe from Microsoft's
# Microsoft.Windows.Console.ConPTY NuGet package (MIT, the one Windows Terminal ships). Dot-sourced
# by tools\fetch-native.ps1 and test\fetch-native.unit.ps1.
#
# agwinterm-ptyhost.exe --conpty bundled loads conpty.dll from its own directory, and that dll starts
# the OpenConsole.exe beside it or in x64\. Unlike the conhost built into Windows it hands a
# program's questions to the terminal (colours, device attributes, cursor position) instead of
# swallowing them, and passes output through unchanged. With either file missing the host falls back
# to the inbox conhost, silently, so both are staged as a pair or not at all.
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

# Stage the pair from a .nupkg on disk: bin\conpty.dll and bin\x64\OpenConsole.exe, the layout
# agwinterm ships. A package with another hash, or without either file, stages nothing and removes
# what an earlier run staged, so a bin never holds half a ConPTY or one nobody checked.
function Install-ConptyPackage([string]$Package, $Conpty, [string]$Bin) {
    $dll = Join-Path $Bin 'conpty.dll'
    $console = Join-Path $Bin 'x64\OpenConsole.exe'
    $wanted = [ordered]@{ 'runtimes/win-x64/native/conpty.dll' = $dll; 'build/native/runtimes/x64/OpenConsole.exe' = $console }
    try {
        if (-not (Test-Path -LiteralPath $Package)) { throw "the package is not at $Package" }
        $actual = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $Conpty.Sha256) {
            throw "its SHA-256 is $actual, native\pinned.json pins $($Conpty.Sha256)"
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($Package)
        try {
            $found = @{}
            foreach ($name in $wanted.Keys) {
                $entry = $zip.Entries | Where-Object { $_.FullName -ceq $name } | Select-Object -First 1
                if (-not $entry -or $entry.Length -le 0) { throw "it has no $name" }
                $found[$name] = $entry
            }
            foreach ($name in $wanted.Keys) {
                $dest = $wanted[$name]
                New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($found[$name], $dest, $true)
            }
        }
        finally { $zip.Dispose() }
    }
    catch {
        Remove-Item -LiteralPath $dll, $console -Force -ErrorAction SilentlyContinue
        throw "$($Conpty.Package) $($Conpty.Version) was not staged: $($_.Exception.Message)`n$script:ConptyFix"
    }
}
