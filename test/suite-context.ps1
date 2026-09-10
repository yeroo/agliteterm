. "$PSScriptRoot/test-registry-path.ps1"
. "$PSScriptRoot/suite-job.ps1"
function Assert-LiteSuiteContext {
    $null=Get-LiteTestRegistryPath -RequireIsolation
    $jobPattern='\ALocal\\agliteterm-suite-'+$env:AGLITETERM_TEST_RUN+'-[0-9a-f]{32}\z'
    if($env:AGLITETERM_TEST_JOB-cnotmatch $jobPattern -or
       -not [LiteSuiteJob]::InNamedJob($env:AGLITETERM_TEST_JOB)){throw 'Legacy suite requires owned-job supervisor; use test/run-all.ps1 -Suite <name>'}
    $hub='C:/Users/boris/AI/bin/suite-token.py'
    if(Test-Path -LiteralPath $hub){
        if(-not $env:AGLITETERM_TEST_RECEIPT){throw 'Missing canonical suite receipt'}
        $receipt=Get-Content -LiteralPath $env:AGLITETERM_TEST_RECEIPT -Raw|ConvertFrom-Json
        $state=& python $hub status|ConvertFrom-Json
        if($LASTEXITCODE-ne 0 -or -not $state.ok -or -not $state.held -or $state.generation-ne $receipt.generation -or
           $state.owner-cne $receipt.owner -or $state.run_id-cne $receipt.run_id -or
           $state.run_id-cne ('lite-suite-'+$env:AGLITETERM_TEST_RUN)){throw 'Canonical suite lease does not match supervisor receipt'}
    }elseif($env:CI-ne 'true'){throw 'Canonical suite token helper unavailable'}
}
