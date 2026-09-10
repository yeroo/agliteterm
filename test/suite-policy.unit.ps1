param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/suite-policy.ps1"
$prior=$env:GITHUB_ACTIONS;$checks=0
$entry=Get-Content -LiteralPath "$PSScriptRoot/selection-ui.ps1" -Raw
$end=$entry.IndexOf('$PSNativeCommandUseErrorActionPreference=')
if($end-lt 0){throw 'Cannot identify the selection admission boundary'}
# Execute the real entry-point prefix, stopping before artifacts, lease or any desktop action.
$policyRoot=$PSScriptRoot
$admission=[scriptblock]::Create($entry.Substring(0,$end).Replace('$PSScriptRoot','$policyRoot'))
try {
    foreach($ci in '', 'true'){foreach($hub in $false,$true){foreach($name in 'clipboard','conformance','control-honesty','selection-ui','log-basics','targeting.unit'){
        $env:GITHUB_ACTIONS=$ci
        function Test-Path {param([Parameter(Position=0)]$Path,$LiteralPath) return $hub}
        $expected=$name -in @('clipboard','conformance','control-honesty','selection-ui') -and -not ($ci-eq 'true' -and -not $hub)
        $denied=$false;try{Assert-LiteSuitePolicy @($name)}catch{$denied=$true}
        if($denied-ne $expected){throw "Suite policy mismatch: $name ci=$ci hub=$hub"}
        $checks++
    }}}
    foreach($ci in '', 'true'){foreach($hub in $false,$true){foreach($filter in '', 'DrivingOnly','RemainderOnly','ClipboardOnly','ConfigurationOnly','ShellConfigurationOnly','AgentIntegrationOnly','Wave3Only'){
        $env:GITHUB_ACTIONS=$ci
        function Test-Path {param([Parameter(Position=0)]$Path,$LiteralPath) return $hub}
        $arguments=@{};if($filter){$arguments[$filter]=$true}
        $expected=$filter-in @('','DrivingOnly','RemainderOnly','ClipboardOnly') -and -not ($ci-eq 'true' -and -not $hub)
        $denied=$false;try{& $admission @arguments}catch{$denied=$true}
        if($denied-ne $expected){throw "Selection entry policy mismatch: filter=$filter ci=$ci hub=$hub"}
        $checks++
    }}}
}finally{$env:GITHUB_ACTIONS=$prior;Remove-Item Function:/Test-Path}
"Suite policy: $checks private admission checks passed"
