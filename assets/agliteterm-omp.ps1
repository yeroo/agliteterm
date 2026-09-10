# Process-local idle dispatch. Never installed in a profile and never injects terminal input.
if(-not ('AgLiteOmpPipe' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
public static class AgLiteOmpPipe {
    public static string Request(string pipe, string json) {
        if(pipe.StartsWith(@"\\.\pipe\",StringComparison.OrdinalIgnoreCase))pipe=pipe.Substring(9);
        using(var cancel=new CancellationTokenSource(700))
        using(var stream=new NamedPipeClientStream(".",pipe,PipeDirection.InOut,PipeOptions.Asynchronous)) {
            stream.ConnectAsync(cancel.Token).GetAwaiter().GetResult();
            byte[] data=Encoding.UTF8.GetBytes(json+"\n");
            stream.WriteAsync(data,0,data.Length,cancel.Token).GetAwaiter().GetResult();
            using(var result=new MemoryStream()) {
                byte[] one=new byte[1];
                while(result.Length<8192) {
                    int n=stream.ReadAsync(one,0,1,cancel.Token).GetAwaiter().GetResult();
                    if(n==0)throw new IOException("OMP bridge reply incomplete");
                    if(one[0]==10)return Encoding.UTF8.GetString(result.ToArray());
                    result.WriteByte(one[0]);
                }
                throw new IOException("OMP bridge reply too large");
            }
        }
    }
}
'@
}
function global:Invoke-AgLiteOmpRequest([string]$Op,[hashtable]$Extra=@{}) {
    if($env:TERM_PROGRAM-ne 'agliteterm' -or -not $env:AGWINTERM_PIPE -or -not $env:AGWINTERM_SESSION_ID){return}
    $fields=@{op=$Op;token=$global:__agliteBridgeToken;pid="$PID"}
    foreach($key in $Extra.Keys){$fields[$key]=$Extra[$key]}
    $json=@{cmd='agent.bridge';target=$env:AGWINTERM_SESSION_ID;args=$fields}|ConvertTo-Json -Compress
    $beforeErrors=@($global:Error)
    try { return ([AgLiteOmpPipe]::Request($env:AGWINTERM_PIPE,$json)|ConvertFrom-Json -ErrorAction Stop) } catch { return }
    finally {$global:Error.Clear();for($i=$beforeErrors.Count-1;$i-ge 0;$i--){$global:Error.Add($beforeErrors[$i])}}
}
function global:Test-AgLiteOmpIdle {
    if(-not $global:__agliteOmpSupported -or -not $global:__agliteOmpReading){return $false}
    $line='';$cursor=0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line,[ref]$cursor)
    if($line.Length-ne 0){return $false}
    $clients=New-Object 'uint32[]' 64
    $count=[AgLitePromptConsole]::GetConsoleProcessList($clients,64)
    return ($count-eq 1 -and $clients[0]-eq $PID)
}
function global:Invoke-AgLiteOmpIdle {
    $priorStatus=$?
    $priorExit=$global:LASTEXITCODE;$priorErrors=@($global:Error)
    try {
        if(-not (Test-AgLiteOmpIdle)){return}
        $reply=Invoke-AgLiteOmpRequest 'omp-claim' @{'console-pids'="$PID"}
        if(-not $reply -or -not $reply.ok -or -not $reply.result){return}
        $offer=$reply.result|ConvertFrom-Json -ErrorAction Stop
        if($offer.lease-cnotmatch '\A[0-9a-fA-F-]{36}\z' -or $global:__agliteOmpExecuted-ceq $offer.lease){return}
        # Consumed before tool invocation. Missing replies never cause another application.
        $global:__agliteOmpExecuted=$offer.lease
        $success=$false
        $stage='idle'
        try {
            if([Environment]::TickCount64-ge [long]$offer.deadline -or -not (Test-AgLiteOmpIdle)){throw 'Idle authorization expired'}
            $stage='tool';$tool=@(Get-Command oh-my-posh -CommandType Application -ErrorAction Stop)[0]
            # A native exit code is evidence; a PowerShell function pretending to be the binary
            # cannot supply it. The generated initializer is evaluated only after native success.
            $stage='native';$initialization=& $tool.Source init pwsh --config ([string]$offer.path)
            if($LASTEXITCODE-ne 0){throw 'oh-my-posh initialization failed'}
            $stage='before-apply'
            if([Environment]::TickCount64-ge [long]$offer.deadline -or -not (Test-AgLiteOmpIdle)){throw 'Idle authorization expired before apply'}
            $promptBefore=$function:prompt
            $stage='apply';Invoke-Expression ($initialization -join "`n") -ErrorAction Stop
            # Recent OMP can switch its per-session theme cache while retaining prompt(). Do
            # not wrap our existing wrapper around itself in that case.
            if(-not [object]::ReferenceEquals($promptBefore,$function:prompt)){
                $stage='wrap';$global:__agwLiteWrap=$false
                . $global:__aglitePromptAsset
            }
            $success=$true
        } catch { Write-Verbose ("OMP idle initialization: " + $_.Exception.Message) }
        $null=Invoke-AgLiteOmpRequest 'omp-result' @{lease=[string]$offer.lease;success=$success;stage=$stage}
    } catch { }
    finally {
        $global:LASTEXITCODE=$priorExit
        # Script event handlers run in the current reader runspace, not concurrently with a user
        # command. Preserve its original error records and native exit status.
        $global:Error.Clear();for($i=$priorErrors.Count-1;$i-ge 0;$i--){$global:Error.Add($priorErrors[$i])}
        if(-not $priorStatus){Microsoft.PowerShell.Utility\Write-Error 'Restore prior idle status' -ErrorAction Ignore}
    }
}
if(-not $global:__agliteOmpSubscriber -and $global:__agliteOmpSupported){
    $global:__agliteOmpSubscriber=Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -SupportEvent -Action { Invoke-AgLiteOmpIdle }
}
