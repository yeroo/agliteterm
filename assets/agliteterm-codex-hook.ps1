param([string]$State)
# Codex reads hook stdout as a decision. This script only reports pane status.
if($env:TERM_PROGRAM -ne 'agliteterm' -or -not $env:AGWINTERM_SESSION_ID -or -not $env:AGWINTERM_PIPE){exit 0}
if($State -cnotin @('active','blocked','completed','stop')){exit 0}
try {
    $reader=New-Object IO.StreamReader([Console]::OpenStandardInput(),[Text.Encoding]::UTF8)
    try{$event=$reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop}finally{$reader.Dispose()}
    if($event.transcript_path -is [string] -and $event.transcript_path){
        $first=[IO.File]::ReadLines($event.transcript_path,[Text.Encoding]::UTF8)|Select-Object -First 1
        $meta=$first|ConvertFrom-Json -ErrorAction Stop
        if($meta.payload.source -and $meta.payload.source -cne 'cli'){exit 0}
    }
    if($State -ceq 'stop'){
        $message=[string]$event.last_assistant_message
        $State=if($message.TrimEnd().EndsWith('?')){'blocked'}else{'completed'}
    }
    & (Join-Path $PSScriptRoot 'agliteterm-agent-status.ps1') $State | Out-Null
}catch{}
exit 0
