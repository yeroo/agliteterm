# Preserve custom Enter handlers: only wrap the standard AcceptLine binding.
if($env:TERM_PROGRAM -eq 'agliteterm' -and -not $global:__agliteAgent){
    $global:__agliteAgent=$true
    $global:__agliteStatusScript=Join-Path $PSScriptRoot 'agliteterm-agent-status.ps1'
    if(-not $env:AGWINTERM_AGENT_RE){$env:AGWINTERM_AGENT_RE='claude|codex|aider|gemini|cursor|copilot|goose|opencode|amp|pi'}
    if(Get-Module -ListAvailable PSReadLine){
        Import-Module PSReadLine
        $enter=Get-PSReadLineKeyHandler -Chord Enter -ErrorAction SilentlyContinue
        if($enter.Function -eq 'AcceptLine'){
            Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
                $line=$null;$cursor=$null
                [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line,[ref]$cursor)
                try{if($line -match ('^\s*('+$env:AGWINTERM_AGENT_RE+')\b')){& $global:__agliteStatusScript active}}catch{}
                [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
            }
        }
        $global:__agliteAgentPrompt=$function:prompt
        function global:prompt {
            $last=Get-History -Count 1
            try{if($last -and $last.Id -ne $global:__agliteLastHistory -and $last.CommandLine -match ('^\s*('+$env:AGWINTERM_AGENT_RE+')\b')){
                $global:__agliteLastHistory=$last.Id;& $global:__agliteStatusScript completed
            }}catch{}
            if($global:__agliteAgentPrompt){& $global:__agliteAgentPrompt}else{"PS $((Get-Location).Path)> "}
        }
    }
}
