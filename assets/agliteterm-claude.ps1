# Opt-in wrapper. A lite pane id is NOT a Claude UUID; generate/bind an explicit conversation id.
if($env:TERM_PROGRAM -eq 'agliteterm' -and -not $global:__agliteClaude){
    $global:__agliteClaude=$true
    function global:claude {
        $real=Get-Command claude -CommandType Application,ExternalScript -ErrorAction SilentlyContinue|Select-Object -First 1
        if(-not $real){Write-Error 'claude executable not found';return}
        # Only decorate bare launches (optionally the explicit bypass flag). All other argv,
        # including future subcommands, option values, fork/resume and prompts pass untouched.
        $dangerous=$args.Count-eq 1 -and [string]$args[0]-ceq'--dangerously-skip-permissions'
        if(($args.Count -gt 0 -and -not $dangerous) -or -not $env:AGWINTERM_SESSION_ID -or -not $env:AGWINTERM_PIPE){
            & $real.Source @args
            return
        }
        $resume=!!$global:__agliteConversation
        $sid=if($resume){$global:__agliteConversation}else{[guid]::NewGuid().ToString()}
        $binding='claude --resume '+$sid+$(if($dangerous){' --dangerously-skip-permissions'}else{''})
        $client=$null
        try {
            $client=New-Object IO.Pipes.NamedPipeClientStream('.', $env:AGWINTERM_PIPE, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
            $client.Connect(1000)
            $writer=New-Object IO.StreamWriter($client);$writer.AutoFlush=$true
            $writer.WriteLine((@{cmd='session.bind';target=$env:AGWINTERM_SESSION_ID;args=@{agent=$binding}}|ConvertTo-Json -Compress))
            $reader=New-Object IO.StreamReader($client);$read=$reader.ReadLineAsync()
            if(-not $read.Wait(1000) -or -not (($read.Result|ConvertFrom-Json).ok)){Write-Warning 'Claude launch binding was not acknowledged; persistence is unconfirmed'}
        }catch{Write-Warning 'Claude launch binding could not be sent; persistence is unconfirmed'}finally{if($client){$client.Dispose()}}
        if($resume){& $real.Source --resume $sid @args}else{& $real.Source --session-id $sid @args}
        if($LASTEXITCODE -eq 0){$global:__agliteConversation=$sid}
    }
}
