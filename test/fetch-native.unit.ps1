param([string]$Exe,[switch]$Strict)
# One CLI pin for local runs and CI (#109). Offline: the network half is tools\fetch-native.ps1's.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'tools/cli-pin.ps1')
$checks=0;$failures=0
function Check([string]$Name,[bool]$Ok){$script:checks++;if($Ok){"PASS $Name"}else{$script:failures++;"FAIL $Name"}}
function Refusal([scriptblock]$Call){try{& $Call;return $null}catch{return $_.Exception.Message}}

$pin=Get-Content -Raw (Join-Path $root 'native/pinned.json')|ConvertFrom-Json
Check 'native/pinned.json pins the CLI with a release tag or latest' ([string]$pin.cliTag -cmatch '\A(v\d+\.\d+\.\d+|latest)\z')
$got=try{Get-CliPin $pin}catch{$null}
Check 'Get-CliPin returns the pinned cliTag' ($got -and $got-ceq[string]$pin.cliTag)
foreach($bad in @([pscustomobject]@{repo='r';tag='v1.0.0'},[pscustomobject]@{repo='r';tag='v1.0.0';cliTag=''})){
    $m=Refusal {Get-CliPin $bad}
    Check "Get-CliPin refuses a pin without cliTag, with no fallback to the core tag ($(($bad|ConvertTo-Json -Compress)))" ($m -and $m.Contains('cliTag'))
}

Check 'the pinned version line is accepted' ($null -eq (Refusal {Assert-CliVersion "cli 0.20.11 C:\x\agwintermctl.exe`r`napp unavailable (pipe \\.\pipe\p)`r`n" 'v0.20.11'}))
foreach($case in @(
    @{Out="cli 0.19.0 C:\x\agwintermctl.exe`r`n";Why='an older release'},
    @{Out="cli 1.0.0 C:\x\agwintermctl.exe`r`n";Why='a source build'},
    @{Out="cli 0.20.110 C:\x\agwintermctl.exe`r`n";Why='a version that only starts with the tag'},
    @{Out="Unknown command: version`r`n";Why='a client with no version verb'},
    @{Out='';Why='no output'})){
    $m=Refusal {Assert-CliVersion $case.Out 'v0.20.11'}
    Check "Assert-CliVersion refuses $($case.Why), naming the tag and the fix" ($m -and $m.Contains('v0.20.11') -and $m.Contains('-Force') -and $m.Contains('AGWINTERMCTL'))
}
$m=Get-CliLaunchFailure 'v0.20.11' 'The specified executable is not a valid application for this OS platform.'
Check 'a CLI that cannot be run is reported with the tag, the cause and the fix' ($m.Contains('v0.20.11') -and $m.Contains('not a valid application') -and $m.Contains('-Force') -and $m.Contains('AGWINTERMCTL'))
Check 'latest skips the comparison' ($null -eq (Refusal {Assert-CliVersion "cli 0.19.0 C:\x`r`n" 'latest'}))

# Install-CheckedCli, offline: a .cmd stands in for a CLI that runs (`&` runs it through cmd), and
# random bytes for one that cannot. Each stages under its own name in a private bin.
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('agliteterm-fetch-native-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp|Out-Null
$outer=[Environment]::GetEnvironmentVariable('AGWINTERM_PIPE')
[Environment]::SetEnvironmentVariable('AGWINTERM_PIPE','outer-pipe')
function Case([string]$Name,[string]$File){$d=Join-Path $tmp $Name;New-Item -ItemType Directory $d,(Join-Path $d 'bin')|Out-Null;@{Cached=Join-Path $d $File;Staged=Join-Path $d "bin/$File";Seen=Join-Path $d 'seen.txt'}}
function FakeCli($c,[string]$Version){[IO.File]::WriteAllText($c.Cached,"@echo [%AGWINTERM_PIPE%]>`"$($c.Seen)`"`r`n@echo cli $Version %~f0`r`n@echo app unavailable 1>&2`r`n@exit /b 1`r`n")}
try{
    $c=Case 'ok' 'agwintermctl.cmd';FakeCli $c '0.20.11'
    $m=Refusal {Install-CheckedCli -Cached $c.Cached -Staged $c.Staged -CliTag 'v0.20.11'}
    $probeExit=$LASTEXITCODE
    Check 'a CLI reporting the pinned version is admitted and stays staged, despite stderr and exit 1' ($null -eq $m -and (Test-Path $c.Staged))
    Check 'the probe''s exit code does not leak into the caller''s LASTEXITCODE' ($probeExit -eq 0)
    # The Continue guard exists for Windows PowerShell 5.1, which makes native stderr under 2>&1 a
    # terminating error when the caller runs with Stop, so the same admission is driven under 5.1 too.
    $c=Case 'ps51' 'agwintermctl.cmd';FakeCli $c '0.20.11'
    $driver=Join-Path $tmp 'ps51.ps1'
    [IO.File]::WriteAllText($driver,"`$ErrorActionPreference='Stop'`r`n. '$(Join-Path $root 'tools/cli-pin.ps1')'`r`ntry{Install-CheckedCli -Cached '$($c.Cached)' -Staged '$($c.Staged)' -CliTag 'v0.20.11';'admitted'}catch{'refused: '+`$_.Exception.Message}`r`n")
    $ps51=(& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $driver 2>&1|Out-String).Trim()
    Check 'Windows PowerShell 5.1 with Stop admits a CLI that writes stderr' ($ps51-ceq'admitted')
    if($ps51-cne'admitted'){"  5.1 said: $ps51"}
    Check 'the probe ran without the caller''s AGWINTERM_PIPE' ((Get-Content -Raw $c.Seen).Trim()-ceq'[]') # a batch file expands an unset variable to nothing
    Check 'AGWINTERM_PIPE is restored after the probe' ($env:AGWINTERM_PIPE-ceq'outer-pipe')

    $c=Case 'old' 'agwintermctl.cmd';FakeCli $c '0.19.0'
    $m=Refusal {Install-CheckedCli -Cached $c.Cached -Staged $c.Staged -CliTag 'v0.20.11'}
    Check 'a CLI reporting another version is refused with the version check''s message' ($m -and $m.Contains('cli 0.19.0') -and $m.Contains('v0.20.11'))
    Check 'the refused CLI is removed from bin' (-not (Test-Path $c.Staged))
    Check 'a CLI that ran keeps its cache (the message says why it was refused)' (Test-Path $c.Cached)
    Check 'AGWINTERM_PIPE is restored after a refusal' ($env:AGWINTERM_PIPE-ceq'outer-pipe')

    $c=Case 'garbage' 'agwintermctl.exe';$bytes=[byte[]]::new(5000);[Random]::new(109).NextBytes($bytes);[IO.File]::WriteAllBytes($c.Cached,$bytes)
    $m=Refusal {Install-CheckedCli -Cached $c.Cached -Staged $c.Staged -CliTag 'v0.20.11'}
    Check 'a CLI that cannot be run is refused with the launch-failure message' ($m -and $m.Contains('could not be run') -and $m.Contains('v0.20.11') -and $m.Contains('-Force'))
    Check 'a CLI that cannot be run is removed from bin AND the cache' (-not (Test-Path $c.Staged) -and -not (Test-Path $c.Cached))
    Check 'AGWINTERM_PIPE is restored after a launch failure' ($env:AGWINTERM_PIPE-ceq'outer-pipe')
}finally{
    [Environment]::SetEnvironmentVariable('AGWINTERM_PIPE',$outer)
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# The ConPTY pin (tools\conpty-pin.ps1): which package, and staging the pair only from that one.
. (Join-Path $root 'tools/conpty-pin.ps1')
$conpty=try{Get-ConptyPin $pin}catch{$null}
Check 'native/pinned.json pins the ConPTY package by version and SHA-256' ($conpty -and $conpty.Package-ceq'Microsoft.Windows.Console.ConPTY' -and $conpty.Version-cmatch'\A\d+(\.\d+){1,3}\z' -and $conpty.Sha256-cmatch'\A[0-9a-f]{64}\z')
Check 'the package URL is nuget.org''s flat container, lower case' ($conpty -and (Get-ConptyPackageUrl $conpty)-ceq"https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/$($conpty.Version)/microsoft.windows.console.conpty.$($conpty.Version).nupkg")
foreach($bad in @(
    @{Pin=[pscustomobject]@{repo='r'};Word='conpty entry'},
    @{Pin=[pscustomobject]@{conpty=[pscustomobject]@{package='Some Package';version='1.0.0';sha256=('a'*64)}};Word='conpty.package'},
    @{Pin=[pscustomobject]@{conpty=[pscustomobject]@{package='A.B';version='latest';sha256=('a'*64)}};Word='conpty.version'},
    @{Pin=[pscustomobject]@{conpty=[pscustomobject]@{package='A.B';version='1.0.0';sha256=('A'*64)}};Word='conpty.sha256'},
    @{Pin=[pscustomobject]@{conpty=[pscustomobject]@{package='A.B';version='1.0.0';sha256='abc'}};Word='conpty.sha256'})){
    $m=Refusal {Get-ConptyPin $bad.Pin}
    Check "Get-ConptyPin refuses a pin with a bad $($bad.Word)" ($m -and $m.Contains($bad.Word))
}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('agliteterm-conpty-pin-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp|Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
function FakePackage([string]$Name,[hashtable]$Entries){
    $src=Join-Path $tmp "$Name-src"
    foreach($entry in $Entries.Keys){$file=Join-Path $src $entry;New-Item -ItemType Directory -Force (Split-Path $file -Parent)|Out-Null;[IO.File]::WriteAllText($file,$Entries[$entry])}
    $zip=Join-Path $tmp "$Name.nupkg";[IO.Compression.ZipFile]::CreateFromDirectory($src,$zip);$zip
}
function PinFor([string]$Zip){[pscustomobject]@{Package='Fake.ConPTY';Version='1.2.3';Sha256=(Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()}}
try{
    $good=FakePackage 'good' @{'runtimes/win-x64/native/conpty.dll'='DLL';'build/native/runtimes/x64/OpenConsole.exe'='EXE';'runtimes/win-arm64/native/conpty.dll'='ARM'}
    $bin=Join-Path $tmp 'bin-good';New-Item -ItemType Directory $bin|Out-Null
    $m=Refusal {Install-ConptyPackage -Package $good -Conpty (PinFor $good) -Bin $bin}
    Check 'a package with the pinned hash stages conpty.dll and x64\OpenConsole.exe, the x64 ones' ($null-eq $m -and (Get-Content -Raw (Join-Path $bin 'conpty.dll'))-ceq'DLL' -and (Get-Content -Raw (Join-Path $bin 'x64/OpenConsole.exe'))-ceq'EXE')
    $wrong=PinFor $good;$wrong.Sha256='0'*64
    $m=Refusal {Install-ConptyPackage -Package $good -Conpty $wrong -Bin $bin}
    Check 'a package with another hash is refused, naming both hashes and the fix' ($m -and $m.Contains('0'*64) -and $m.Contains((PinFor $good).Sha256) -and $m.Contains('-Force'))
    Check 'and what an earlier run staged is removed with it' (-not (Test-Path (Join-Path $bin 'conpty.dll')) -and -not (Test-Path (Join-Path $bin 'x64/OpenConsole.exe')))
    $half=FakePackage 'half' @{'runtimes/win-x64/native/conpty.dll'='DLL';'build/native/runtimes/arm64/OpenConsole.exe'='ARM'}
    $bin=Join-Path $tmp 'bin-half';New-Item -ItemType Directory $bin|Out-Null
    $m=Refusal {Install-ConptyPackage -Package $half -Conpty (PinFor $half) -Bin $bin}
    Check 'a package without the x64 OpenConsole.exe stages neither file' ($m -and $m.Contains('build/native/runtimes/x64/OpenConsole.exe') -and -not (Test-Path (Join-Path $bin 'conpty.dll')))
    $m=Refusal {Install-ConptyPackage -Package (Join-Path $tmp 'absent.nupkg') -Conpty (PinFor $good) -Bin $bin}
    Check 'a missing package is refused' ($m -and $m.Contains('was not staged'))
    $m=Refusal {Assert-ConptyPackage $good $wrong}
    Check 'Assert-ConptyPackage alone refuses another hash (what fetch-native drops a cached download on)' ($m -and $m.Contains('0'*64))
    # A pty-host running from bin keeps conpty.dll open. Same bytes: nothing to replace, the build goes on.
    $bin=Join-Path $tmp 'bin-held';New-Item -ItemType Directory $bin|Out-Null
    Install-ConptyPackage -Package $good -Conpty (PinFor $good) -Bin $bin
    $held=[IO.File]::Open((Join-Path $bin 'conpty.dll'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $m=Refusal {Install-ConptyPackage -Package $good -Conpty (PinFor $good) -Bin $bin}
        Check 'a held conpty.dll with the same bytes is left alone and staging succeeds' ($null-eq $m)
        # Other bytes (the pin moved): it cannot be replaced, and the message names the cause, not the pin.
        $next=FakePackage 'next' @{'runtimes/win-x64/native/conpty.dll'='DLL2';'build/native/runtimes/x64/OpenConsole.exe'='EXE2'}
        $m=Refusal {Install-ConptyPackage -Package $next -Conpty (PinFor $next) -Bin $bin}
        Check 'a held conpty.dll that must change is reported as in use, not as a bad pin' ($m -and $m.Contains('could not be replaced') -and $m.Contains('agwinterm-ptyhost.exe') -and -not $m.Contains('-Force'))
        Check 'and the pair already in bin is still there' ((Test-Path (Join-Path $bin 'conpty.dll')) -and (Get-Content -Raw (Join-Path $bin 'x64/OpenConsole.exe'))-ceq'EXE')
        Check 'and no staging file is left behind' (@(Get-ChildItem $bin -Recurse -Filter '*.staging').Count-eq 0)
    }finally{$held.Dispose()}
}finally{Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue}
$fetch=Get-Content -Raw (Join-Path $root 'tools/fetch-native.ps1')
Check 'fetch-native stages the ConPTY before it branches on -NativeDir' ($fetch.IndexOf('Install-ConptyPackage')-gt 0 -and $fetch.IndexOf('Install-ConptyPackage')-lt $fetch.IndexOf('if ($NativeDir) {'))

# CI drives lite with the CLI fetch-native staged from cliTag, not a second, CI-only build of it.
$ci=Get-Content -Raw (Join-Path $root '.github/workflows/ci.yml')
foreach($word in 'ci-full-cli','setup-dotnet','Agwinterm.Ctl.csproj'){
    Check "ci.yml does not build its own CLI ($word)" (-not $ci.Contains($word))
}
Check 'ci.yml stages the CLI through fetch-native' ($ci.Contains('./tools/fetch-native.ps1'))

"fetch-native-unit: $checks checks, $failures failed"
if($failures){throw 'fetch-native unit checks failed'}
exit 0
