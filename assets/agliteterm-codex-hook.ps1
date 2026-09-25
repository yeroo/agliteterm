param([string]$State)
# Codex reads hook stdout as a decision. This script only reports pane status.
if($env:TERM_PROGRAM -ne 'agliteterm' -or -not $env:AGWINTERM_SESSION_ID -or -not $env:AGWINTERM_PIPE){exit 0}
if($State -cnotin @('active','blocked','completed','stop')){exit 0}
try {
    $reader=New-Object IO.StreamReader([Console]::OpenStandardInput(),[Text.Encoding]::UTF8)
    try{$event=$reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop}finally{$reader.Dispose()}
    if($event.transcript_path -is [string] -and $event.transcript_path){
        # Codex keeps the rollout open while hooks run. Only a positive nested-run signal suppresses status.
        $source=$null;$transcript=$null;$lines=$null
        try {
            $transcript=[IO.FileStream]::new($event.transcript_path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]'ReadWrite, Delete')
            $lines=New-Object IO.StreamReader($transcript,[Text.Encoding]::UTF8)
            $meta=$lines.ReadLine()|ConvertFrom-Json -ErrorAction Stop
            $source=$meta.payload.source
        }catch{}finally{if($lines){$lines.Dispose()}elseif($transcript){$transcript.Dispose()}}
        if($source -and $source -cne 'cli'){exit 0}
    }
    if($State -ceq 'stop'){
        $message=[string]$event.last_assistant_message
        $State=if($message.TrimEnd().EndsWith('?')){'blocked'}else{'completed'}
    }
    & (Join-Path $PSScriptRoot 'agliteterm-agent-status.ps1') $State | Out-Null
}catch{}
exit 0
