# Opt-in wrapper. A lite pane id is NOT a Claude UUID; generate/bind an explicit conversation id.
if($env:TERM_PROGRAM -eq 'agliteterm' -and -not $global:__agliteClaude){
    $global:__agliteClaude=$true
    function global:claude {
        $real=Get-Command claude -CommandType Application,ExternalScript -ErrorAction SilentlyContinue|Select-Object -First 1
        if(-not $real){Write-Error 'claude executable not found';return}
        $pass=$false;$dangerous=$false;$explicit=$null
        if($args.Count -gt 0 -and "$($args[0])" -match '^(update|doctor|mcp|config|install|migrate-installer|setup-token|plugin|agents|auth)$'){$pass=$true}
        for($i=0;$i-lt$args.Count;$i++){
            $arg=[string]$args[$i]
            if($arg -match '^(--resume|--session-id|-r)(=|$)'){
                $pass=$true
                $candidate=if($arg.Contains('=')){$arg.Substring($arg.IndexOf('=')+1)}elseif($i+1-lt$args.Count){[string]$args[$i+1]}else{''}
                $parsed=[guid]::Empty;if([guid]::TryParseExact($candidate,'D',[ref]$parsed)){$explicit=$parsed.ToString()}
            }
            if($arg -match '^(--continue|--print|-c|-p)(=|$)'){$pass=$true}
            if($arg -eq '--dangerously-skip-permissions'){$dangerous=$true}
        }
        if($pass -or -not $env:AGWINTERM_SESSION_ID -or -not $env:AGWINTERM_PIPE){
            & $real.Source @args
            if($LASTEXITCODE -eq 0 -and $explicit){$global:__agliteConversation=$explicit}
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
