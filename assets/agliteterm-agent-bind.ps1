param([string]$Agent)
# SessionStart hook for Claude Code and Codex: bind the pane to the live session so a restart
# resumes it (agwinterm #323). The event JSON (session_id, cwd) arrives on stdin. Inert outside
# agliteterm, and it never prints: both CLIs read a hook's stdout.
if($env:TERM_PROGRAM -ne 'agliteterm' -or -not $env:AGWINTERM_SESSION_ID -or -not $env:AGWINTERM_PIPE){exit 0}
if($Agent -cnotin @('claude','codex')){exit 0}
$event=$null
try {
    $reader=New-Object IO.StreamReader([Console]::OpenStandardInput(),[Text.Encoding]::UTF8)
    try{$event=$reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop}finally{$reader.Dispose()}
}catch{}
if(-not $event -or $event.session_id -isnot [string] -or -not $event.session_id){exit 0}
# A nested headless run inherits AGWINTERM_SESSION_ID. agliteterm refuses one by the process tree
# anyway; these cheap tells spare it the walk: `claude -p` reports ENTRYPOINT sdk-cli (the TUI: cli)
# and ATTENDED 0, and `codex exec` writes source "exec" into its rollout (the TUI: "cli").
if($Agent -ceq 'claude' -and (($env:CLAUDE_CODE_ENTRYPOINT -and $env:CLAUDE_CODE_ENTRYPOINT -cne 'cli') -or $env:CLAUDE_CODE_SESSION_ATTENDED -ceq '0')){exit 0}
if($Agent -ceq 'codex' -and $event.transcript_path -is [string] -and $event.transcript_path){
    # Codex keeps the rollout open while hooks run. Only a positive nested-run signal suppresses the bind.
    $source=$null;$transcript=$null;$lines=$null
    try {
        $transcript=[IO.FileStream]::new($event.transcript_path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]'ReadWrite, Delete')
        $lines=New-Object IO.StreamReader($transcript,[Text.Encoding]::UTF8)
        $meta=$lines.ReadLine()|ConvertFrom-Json -ErrorAction Stop
        $source=$meta.payload.source
    }catch{}finally{if($lines){$lines.Dispose()}elseif($transcript){$transcript.Dispose()}}
    if($source -and $source -cne 'cli'){exit 0}
}
$cwd=if($event.cwd -is [string]){$event.cwd}else{''}
$request=@{cmd='session.bind';target=$env:AGWINTERM_SESSION_ID;args=@{agent=$Agent;resume=[string]$event.session_id;cwd=$cwd;pid=$PID}}|ConvertTo-Json -Compress
$client=$null
try {
    $client=New-Object IO.Pipes.NamedPipeClientStream('.',$env:AGWINTERM_PIPE,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
    $client.Connect(1000)
    $writer=New-Object IO.StreamWriter($client);$writer.AutoFlush=$true
    $writer.WriteLine($request)
    # Wait (bounded) for the reply: agliteterm walks the process tree up from this PID before it
    # answers, so this process must still be alive when it does.
    $null=(New-Object IO.StreamReader($client)).ReadLineAsync().Wait(3000)
}catch{}finally{if($client){$client.Dispose()}}
exit 0
