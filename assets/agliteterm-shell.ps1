# Sourced only by the user's opt-in profile block. Uses the launch wrapper's sentinel.
if($env:TERM_PROGRAM -eq 'agliteterm' -and -not $global:__agwSI){
    $global:__agwSI=$true
    $global:__agwPrompt=$function:prompt
    function global:prompt {
        $cwd=(Get-Location).ProviderPath
        [Console]::Write("$([char]27)]7;file://$env:COMPUTERNAME/$(($cwd -replace '\\','/'))$([char]7)")
        if($global:__agwPrompt){& $global:__agwPrompt}else{"PS $cwd> "}
    }
}
