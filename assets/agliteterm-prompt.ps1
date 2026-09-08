# Per-process launch integration, never installed into or written to a user profile.
if(-not $global:__agliteBridgeToken){$global:__agliteBridgeToken=[guid]::NewGuid().ToString('D')}
function global:Invoke-AgLiteBridgeRequest([string]$Op){
    if($env:TERM_PROGRAM -ne 'agliteterm' -or -not $env:AGWINTERM_PIPE -or -not $env:AGWINTERM_SESSION_ID){return}
    $client=$null
    try {
        $client=New-Object IO.Pipes.NamedPipeClientStream('.', $env:AGWINTERM_PIPE, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
        $client.Connect(300)
        $writer=New-Object IO.StreamWriter($client);$writer.AutoFlush=$true
        $writer.WriteLine((@{cmd='agent.bridge';target=$env:AGWINTERM_SESSION_ID;args=@{op=$Op;token=$global:__agliteBridgeToken;pid="$PID"}}|ConvertTo-Json -Compress))
        $reader=New-Object IO.StreamReader($client)
        $read=$reader.ReadLineAsync()
        if(-not $read.Wait(1000)){return}
        $reply=$read.Result|ConvertFrom-Json
        if($reply.ok){return $reply.result}
    }catch{}finally{if($client){$client.Dispose()}}
}
if(-not $global:__agwLiteWrap){
    $global:__agwLiteWrap=$true;$global:__agwLiteP=$function:prompt
    function global:prompt {
        $ec=if($?){0}else{1}
        # Claim only from the prompt, not from PSReadLine: no command is appended to draft input.
        # The native owner verifies retained process handles have exited before returning a resume.
        while($true){
            $null=Invoke-AgLiteBridgeRequest register
            $resume=Invoke-AgLiteBridgeRequest claim
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
