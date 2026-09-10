# Match the production namespace exactly; absence retains the existing guarded standalone fixture.
function Get-LiteTestRegistryPath([switch]$Legacy,[switch]$RequireIsolation) {
    $run=$env:AGLITETERM_TEST_RUN
    if([string]::IsNullOrEmpty($run)){
        if($RequireIsolation){throw 'Use test/run-all.ps1 to acquire a suite token and isolated test namespace'}
        return $(if($Legacy){'Software\agwinterm-lite'}else{'Software\agliteterm'})
    }
    if($run-cnotmatch '\A[0-9a-f]{32}\z'){throw 'Invalid test registry namespace; refusing personal settings fallback'}
    'Software\agliteterm-tests\'+$run+$(if($Legacy){'\Legacy'}else{'\Current'})
}
function Get-LiteTestPipe([string]$Name) {
    if(-not $env:AGLITETERM_TEST_RUN){return $Name}
    $null=Get-LiteTestRegistryPath -RequireIsolation
    $prefix='agliteterm-test-'+$env:AGLITETERM_TEST_RUN+'-ctl-'
    if($Name.StartsWith('\\.\pipe\',[StringComparison]::Ordinal)){$Name=$Name.Substring(9)}
    if($Name.StartsWith($prefix,[StringComparison]::Ordinal)){return $Name}
    $prefix+$Name
}
