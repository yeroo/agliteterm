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
function FakeCli($c,[string]$Version){[IO.File]::WriteAllText($c.Cached,"@echo [%AGWINTERM_PIPE%]>`"$($c.Seen)`"`r`n@echo cli $Version %~f0`r`n")}
try{
    $c=Case 'ok' 'agwintermctl.cmd';FakeCli $c '0.20.11'
    $m=Refusal {Install-CheckedCli -Cached $c.Cached -Staged $c.Staged -CliTag 'v0.20.11'}
    Check 'a CLI reporting the pinned version is admitted and stays staged' ($null -eq $m -and (Test-Path $c.Staged))
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

# CI drives lite with the CLI fetch-native staged from cliTag, not a second, CI-only build of it.
$ci=Get-Content -Raw (Join-Path $root '.github/workflows/ci.yml')
foreach($word in 'ci-full-cli','setup-dotnet','Agwinterm.Ctl.csproj'){
    Check "ci.yml does not build its own CLI ($word)" (-not $ci.Contains($word))
}
Check 'ci.yml stages the CLI through fetch-native' ($ci.Contains('./tools/fetch-native.ps1'))

"fetch-native-unit: $checks checks, $failures failed"
if($failures){throw 'fetch-native unit checks failed'}
exit 0
