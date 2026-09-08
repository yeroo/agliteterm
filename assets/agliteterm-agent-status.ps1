param([ValidateSet('active','blocked','completed','idle')][string]$State='completed')
# Product scoped: installing this alongside agwinterm must not double-report its sessions.
if($env:TERM_PROGRAM -ne 'agliteterm' -or -not $env:AGWINTERM_SESSION_ID -or -not $env:AGWINTERM_PIPE){exit 0}
$client=$null
try {
    $client=New-Object IO.Pipes.NamedPipeClientStream('.', $env:AGWINTERM_PIPE, [IO.Pipes.PipeDirection]::InOut)
    $client.Connect(500)
    $writer=New-Object IO.StreamWriter($client);$writer.AutoFlush=$true
    $writer.WriteLine((@{cmd='session.status';target=$env:AGWINTERM_SESSION_ID;args=@{status=$State}}|ConvertTo-Json -Compress))
}catch{}finally{if($client){$client.Dispose()}}
exit 0
