param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/suite-policy.ps1"
$prior=$env:GITHUB_ACTIONS;$checks=0
try {
    foreach($ci in '', 'true'){foreach($hub in $false,$true){foreach($name in 'clipboard','conformance','control-honesty','selection-ui','log-basics','targeting.unit'){
        $env:GITHUB_ACTIONS=$ci
        function Test-Path {param($LiteralPath) return $hub}
        $expected=$name -in @('clipboard','conformance','control-honesty','selection-ui') -and -not ($ci-eq 'true' -and -not $hub)
        $denied=$false;try{Assert-LiteSuitePolicy @($name)}catch{$denied=$true}
        if($denied-ne $expected){throw "Suite policy mismatch: $name ci=$ci hub=$hub"}
        $checks++
    }}}
}finally{$env:GITHUB_ACTIONS=$prior;Remove-Item Function:/Test-Path}
"Suite policy: $checks private admission checks passed"
