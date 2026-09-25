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

# CI drives lite with the CLI fetch-native staged from cliTag, not a second, CI-only build of it.
$ci=Get-Content -Raw (Join-Path $root '.github/workflows/ci.yml')
foreach($word in 'ci-full-cli','setup-dotnet','Agwinterm.Ctl.csproj'){
    Check "ci.yml does not build its own CLI ($word)" (-not $ci.Contains($word))
}
Check 'ci.yml stages the CLI through fetch-native' ($ci.Contains('./tools/fetch-native.ps1'))

"fetch-native-unit: $checks checks, $failures failed"
if($failures){throw 'fetch-native unit checks failed'}
exit 0
