param([string]$Json)
# https://learn.chatgpt.com/docs/config-file/config-advanced#notifications
# Only the supported completion event is mapped; never manufacture permission notifications.
try {
    $event=$Json|ConvertFrom-Json -ErrorAction Stop
    if($event.type -ne 'agent-turn-complete'){exit 0}
    $message=[string]$event.'last-assistant-message'
    $state=if($message.TrimEnd().EndsWith('?')){'blocked'}else{'completed'}
    & (Join-Path $PSScriptRoot 'agliteterm-agent-status.ps1') $state | Out-Null
}catch{}
exit 0
