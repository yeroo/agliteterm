# A lease excludes cooperating suites, not the user's clipboard writers or foreground activity.
function Assert-LiteSuitePolicy([string[]]$Names) {
    $disposable=$env:GITHUB_ACTIONS-eq 'true' -and -not (Test-Path -LiteralPath 'C:/Users/boris/AI/bin/suite-token.py')
    foreach($name in $Names){
        if($name -in @('clipboard','control-honesty','conformance') -and -not $disposable){
            throw "Suite $name requires disposable GitHub CI: it intentionally tests clipboard paste or foreground transfer. Choose an explicit safe -Suite subset locally."
        }
    }
}
