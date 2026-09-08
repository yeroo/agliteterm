# Per-process launch integration, never installed into or written to a user profile.
if(-not $global:__agliteBridgeToken){$global:__agliteBridgeToken=[guid]::NewGuid().ToString('D')}
if(-not ('AgLitePromptConsole' -as [type])){
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class AgLitePromptConsole { [DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetConsoleProcessList([Out] uint[] processes, uint count); }'
}
function global:Invoke-AgLiteBridgeRequest([string]$Op,[string]$Lease='', [switch]$NoReply){
    if($env:TERM_PROGRAM -ne 'agliteterm' -or -not $env:AGWINTERM_PIPE -or -not $env:AGWINTERM_SESSION_ID){return}
    $client=$null
    try {
        $client=New-Object IO.Pipes.NamedPipeClientStream('.', $env:AGWINTERM_PIPE, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
        $client.Connect(300)
        $writer=New-Object IO.StreamWriter($client);$writer.AutoFlush=$true
        $fields=@{op=$Op;token=$global:__agliteBridgeToken;pid="$PID";lease=$Lease}
        if($Op-eq'claim' -or $Op-eq'ack'){
            $clients=New-Object 'uint32[]' 64
            $count=[AgLitePromptConsole]::GetConsoleProcessList($clients,64)
            # Fail closed on no console, overflow, or any other attached client (including
            # a late orphan whose parent agent exited before the native process snapshot).
            if($count-ne 1 -or $clients[0]-ne$PID){return}
            $fields['console-pids']="$PID"
        }
        $writer.WriteLine((@{cmd='agent.bridge';target=$env:AGWINTERM_SESSION_ID;args=$fields}|ConvertTo-Json -Compress))
        if($NoReply){return}
        $reader=New-Object IO.StreamReader($client)
        $read=$reader.ReadLineAsync()
        if(-not $read.Wait(1000)){return}
        $reply=$read.Result|ConvertFrom-Json
        return $reply
    }catch{}finally{if($client){$client.Dispose()}}
}
function global:Get-AgLiteResume {
    $offer=$null
    for($attempt=0;$attempt-lt 5;$attempt++){
        $reply=Invoke-AgLiteBridgeRequest claim
        if($reply -and $reply.ok){if(-not$reply.result){return};$offer=$reply.result|ConvertFrom-Json;break}
        Start-Sleep -Milliseconds 100
    }
    if(-not$offer){return}
    for($attempt=0;$attempt-lt 5;$attempt++){
        if([DateTime]::UtcNow.ToFileTimeUtc()-ge[long]$offer.deadline){return}
        $reply=Invoke-AgLiteBridgeRequest ack $offer.lease
        if($reply -and $reply.ok -and $reply.result){
            $accepted=$reply.result|ConvertFrom-Json
            if($accepted.lease-cne$offer.lease -or $accepted.command-cne$offer.command -or [DateTime]::UtcNow.ToFileTimeUtc()-ge[long]$accepted.deadline){return}
            if($global:__agliteExecutedLease-ceq$accepted.lease){return}
            $global:__agliteExecutedLease=$accepted.lease
            # Receipt notification is not on the executable path's disk-I/O acknowledgement.
            $null=Invoke-AgLiteBridgeRequest received $accepted.lease -NoReply
            return $accepted.command
        }
        if($reply -and -not$reply.ok){return}
        Start-Sleep -Milliseconds 100
    }
}
if(-not $global:__agwLiteWrap){
    $global:__agwLiteWrap=$true;$global:__agwLiteP=$function:prompt
    function global:prompt {
        $ec=if($?){0}else{1}
        # Claim only from the prompt, not from PSReadLine: no command is appended to draft input.
        # The native owner verifies retained process handles have exited before returning a resume.
        while($true){
            $null=Invoke-AgLiteBridgeRequest register
            $resume=Get-AgLiteResume
            if(-not $resume){break}
            try { & ([scriptblock]::Create($resume)) } catch { Write-Error $_ }
            $ec=if($?){0}else{1}
            # A resumed agent ran inside this prompt. Its next exit must allow another claim
            # before returning to ReadLine, including a later version-update restart.
        }
        $e=[char]27;$b=[char]7
        $location=$executionContext.SessionState.Path.CurrentLocation
        if($location.Provider.Name -eq 'FileSystem'){[Environment]::CurrentDirectory=$location.ProviderPath}
        [Console]::Write("$e]133;D;$ec$b$e]133;A$b")
        if($global:__agwLiteP){& $global:__agwLiteP}else{"PS $($executionContext.SessionState.Path.CurrentLocation)> "}
    }
}
