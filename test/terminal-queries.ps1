# A program's questions to the terminal reach lite and are answered (agliteterm #120, agwinterm
# #342): with `conpty = bundled` the pty-host runs shells on the bundled ConPTY, which passes
# OSC 10/11, DA1 and CPR through instead of swallowing them, and the core (ABI 19) answers from the
# colours lite gives it. The key defaults to inbox, so the suite sets it in the run's registry
# namespace before its window starts the host, and takes it out again. Only under the canonical
# owned-job supervisor; text reaches the pane through the control pipe alone.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/suite-context.ps1"
Assert-LiteSuiteContext
. "$PSScriptRoot/owned-window.ps1"
$artifact=Join-Path $env:LOCALAPPDATA ('queries-'+[guid]::NewGuid().ToString('N'))
$appDir=Join-Path $artifact 'agliteterm';New-Item -ItemType Directory -Path $appDir|Out-Null
@{default='SafeCmd';profiles=@(@{name='SafeCmd';command='cmd.exe';args=@('/d','/q')})}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $appDir 'profiles.json')
# The program in the pane: ask, read what comes back on stdin, print it with controls spelled out.
# It sets ENABLE_VIRTUAL_TERMINAL_INPUT as every TUI that asks does: without it the console turns a
# reply that looks like a key (CPR `ESC [ r ; c R` is also a modified F3) into that key.
$ask=Join-Path $artifact 'ask.ps1'
@'
param([string]$Tag)
$e=[string][char]27
Add-Type -Namespace Ask -Name Con -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h,out uint m);[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h,uint m);'
$stdin=[Ask.Con]::GetStdHandle(-10);$mode=0;[void][Ask.Con]::GetConsoleMode($stdin,[ref]$mode);[void][Ask.Con]::SetConsoleMode($stdin,$mode-bor 0x200)
function Ask([string]$name,[string]$query){
    while([Console]::KeyAvailable){[void][Console]::ReadKey($true)}
    [Console]::Write($query)
    $until=[DateTime]::UtcNow.AddMilliseconds(1500);$r=''
    while([DateTime]::UtcNow-lt $until){if([Console]::KeyAvailable){$r+=[Console]::ReadKey($true).KeyChar}else{Start-Sleep -Milliseconds 20}}
    $shown=-join($r.ToCharArray()|ForEach-Object{if([int]$_-lt 32){'<'+[int]$_+'>'}else{[string]$_}})
    "R-$Tag-$name=[$shown]"
}
$lines=@((Ask 'osc11' ($e+']11;?'+$e+'\')),(Ask 'osc10' ($e+']10;?'+$e+'\')),(Ask 'da1' ($e+'[c')),(Ask 'cpr' ($e+'[6n')))
[void][Ask.Con]::SetConsoleMode($stdin,$mode)
[Console]::WriteLine();$lines|ForEach-Object{[Console]::WriteLine($_)}
[Console]::WriteLine($e+'[>4;2m'+"XTPLAIN-$Tag"+$e+'[0m')
'@|Set-Content -LiteralPath $ask
$pipe=Get-LiteTestPipe 'queries'
# The host reads --conpty when it starts, and this window starts it: the value has to be there first.
$conptyKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey((Get-LiteTestRegistryPath -RequireIsolation))
try{$conptyKey.SetValue('Conpty',0,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$conptyKey.Dispose()}
$proc=$null;$checks=0;$failures=0;$colorsTouched=$false
function Check([string]$name,[bool]$ok,[string]$detail=''){$script:checks++;if($ok){"PASS $name"}else{$script:failures++;"FAIL $name : $detail"}}
function QueryRpc([string]$verb,$params=@{},[string]$target,[switch]$AllowError){
    $client=[IO.Pipes.NamedPipeClientStream]::new('.',$pipe,[IO.Pipes.PipeDirection]::InOut)
    try{
        $client.Connect(1500)
        $writer=[IO.StreamWriter]::new($client);$writer.AutoFlush=$true;$reader=[IO.StreamReader]::new($client)
        $writer.WriteLine((@{cmd=$verb;args=$params;target=$target}|ConvertTo-Json -Compress -Depth 8))
        $read=$reader.ReadLineAsync();if(-not $read.Wait(15000)){throw 'Query RPC deadline exceeded'}
        $answer=$read.Result|ConvertFrom-Json
        if($AllowError){return $answer}
        if(-not $answer.ok){throw "$verb : $($answer.error)"};return $answer.result
    }finally{$client.Dispose()}
}
function Wait-Query([scriptblock]$Condition,[int]$Seconds=20){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{if(& $Condition){return $true};Start-Sleep -Milliseconds 150}while($clock.Elapsed.TotalSeconds-lt $Seconds)
    $false
}
function Screen([string]$id){[string](QueryRpc 'session.text' @{} $id)}
function TypeLine([string]$id,[string]$line){$null=QueryRpc 'session.type' @{text=($line+"`r")} $id}
# The helper prints its XTPLAIN line last, so that line on screen means the four replies are too.
function Ask-Pane([string]$id,[string]$tag){
    TypeLine $id ("powershell -NoProfile -ExecutionPolicy Bypass -File `"$ask`" -Tag $tag")
    if(-not (Wait-Query {(Screen $id).Contains("XTPLAIN-$tag")} 40)){throw "the query helper did not finish in $id (tag $tag): $(((Screen $id).Trim()-replace'\s+',' '))"}
}
# The pane may be narrower than a reply (CI's is), and a wrapped line arrives with a break in it:
# the whitespace is dropped before the reply is cut out between `R-<tag>-<name>=[` and the next `]R-` or `]XTPLAIN`.
function Reply([string]$id,[string]$tag,[string]$what){
    $flat=(Screen $id)-replace'\s+',''
    if($flat-match([regex]::Escape("R-$tag-$what=[")+'(.*?)\](?=R-|XTPLAIN)')){$Matches[1]}else{'(no line)'}
}
$esc='<27>'
try{
    $proc=Start-Process $Exe -ArgumentList @('--pipe','queries','--no-restore') -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$artifact}
    [void]$proc.SafeHandle;$null=Get-OwnedLiteWindow $proc -Show
    $ready=$false
    for($try=0;$try-lt 60;$try++){
        try{$null=QueryRpc 'tree' @{} '';$ready=$true;break}catch{if($proc.HasExited){throw};Start-Sleep -Milliseconds 100}
    }
    if(-not $ready){throw 'Owned query window did not become ready'}
    $a=[string]@((QueryRpc 'tree' @{} '').workspaces|ForEach-Object{$_.sessions})[0].id
    if(-not (Wait-Query {(Screen $a).Contains('>')})){throw 'the cmd pane did not reach a prompt'}

    Check 'the window read conpty = bundled from the run''s namespace' ([string](QueryRpc 'config.get' @{key='conpty'} '')-ceq'bundled')
    # The pane's pseudoconsole is OpenConsole.exe, a child of the pty-host this run started (the host's
    # own windowless console is a conhost.exe child whichever ConPTY it uses).
    $hostRow=@(Get-CimInstance Win32_Process -Filter "Name='agwinterm-ptyhost.exe'"|Where-Object{$_.CommandLine-like"*$env:AGLITETERM_TEST_RUN*"})[0]
    $children=if($hostRow){@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($hostRow.ProcessId)"|ForEach-Object{$_.Name.ToLowerInvariant()})}else{@()}
    Check 'the run''s pty-host was started with --conpty bundled' ($hostRow -and $hostRow.CommandLine-match'--conpty bundled\s*$') "command line=$($hostRow.CommandLine)"
    Check 'the pane runs on the bundled OpenConsole.exe' ($children-contains'openconsole.exe') "children=$($children-join',')"

    TypeLine $a 'echo ENV=%AGWINTERM_THEME_COLORS%/%COLORTERM%/'
    Check 'the pane environment carries the theme pair and truecolor' (Wait-Query {((Screen $a)-replace'\s+','').Contains('ENV=c0c0c0;000000/truecolor/')}) "screen=$(((Screen $a).Trim()-replace'\s+',' '))"

    Ask-Pane $a 'one'
    Check 'OSC 11 is answered with the background' ((Reply $a 'one' 'osc11')-ceq"$esc]11;rgb:0000/0000/0000$esc\") "got=$(Reply $a 'one' 'osc11')"
    Check 'OSC 10 is answered with the foreground' ((Reply $a 'one' 'osc10')-ceq"$esc]10;rgb:c0c0/c0c0/c0c0$esc\") "got=$(Reply $a 'one' 'osc10')"
    Check 'DA1 is answered by the core' ((Reply $a 'one' 'da1')-ceq"$esc[?62;4;22c") "got=$(Reply $a 'one' 'da1')"
    Check 'CPR is answered with a position' ((Reply $a 'one' 'cpr')-cmatch"^$esc\[\d+;\d+R$") "got=$(Reply $a 'one' 'cpr')"
    # CSI > 4 ; 2 m is XTMODKEYS, not SGR 4;2: ABI 18 ran it as underline + faint.
    $styled=(QueryRpc 'session.text' @{styles=$true} $a)|ConvertTo-Json -Compress -Depth 10
    $run=if($styled-match'\{[^{}]*"text":"[^"]*XTPLAIN-one[^"]*"[^{}]*\}'){$Matches[0]}else{''}
    Check 'a CSI with a > prefix leaves the pen alone' ($run -and $run-match'"underline":false' -and $run-match'"faint":false') "run=$run"

    # A colour change reaches the emulator that is already running, and the next pane's environment.
    $colorsTouched=$true
    $null=QueryRpc 'config.set' @{key='foreground';value='#112233'} '';$null=QueryRpc 'config.set' @{key='background';value='#445566'} ''
    $null=QueryRpc 'config.set' @{key='custom-colors';value='true'} ''
    Ask-Pane $a 'two'
    Check 'a running pane answers OSC 11 with the new background' ((Reply $a 'two' 'osc11')-ceq"$esc]11;rgb:4444/5555/6666$esc\") "got=$(Reply $a 'two' 'osc11')"
    Check 'and OSC 10 with the new foreground' ((Reply $a 'two' 'osc10')-ceq"$esc]10;rgb:1111/2222/3333$esc\") "got=$(Reply $a 'two' 'osc10')"
    $b=[string](QueryRpc 'session.new' @{name='later'} '')
    if(-not (Wait-Query {(Screen $b).Contains('>')})){throw 'the second cmd pane did not reach a prompt'}
    TypeLine $b 'echo ENV=%AGWINTERM_THEME_COLORS%/'
    Check 'a pane created afterwards gets the new pair in its environment' (Wait-Query {((Screen $b)-replace'\s+','').Contains('ENV=112233;445566/')}) "screen=$(((Screen $b).Trim()-replace'\s+',' '))"
    Ask-Pane $b 'three'
    Check 'and its emulator answers with it' ((Reply $b 'three' 'osc11')-ceq"$esc]11;rgb:4444/5555/6666$esc\") "got=$(Reply $b 'three' 'osc11')"
    "terminal queries: $checks checks, $failures failed"
}catch{$failures++;"Terminal queries FAILED: $_"}
finally{
    # The run's registry namespace is shared by the suites after this one: put the colours back.
    # Through the window while it lives (its emulators follow); a window that died, or a refused
    # set, leaves the three values in the namespace, and they are then written there directly - a
    # crash here must not hand every later suite a window with custom colours.
    if($colorsTouched){
        $restored=$proc -and -not $proc.HasExited
        if($restored){
            foreach($pair in @(@('custom-colors','false'),@('foreground','#C0C0C0'),@('background','#000000'))){
                try{$null=QueryRpc 'config.set' @{key=$pair[0];value=$pair[1]} ''}catch{$restored=$false;$failures++;"colour restore failed for $($pair[0]): $_"}
            }
        }
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey((Get-LiteTestRegistryPath -RequireIsolation))
        try{
            if(-not $restored){
                $failures++;'the window was gone or refused the colour restore: the run''s registry values are reset directly'
                $key.SetValue('CustomColors',0,[Microsoft.Win32.RegistryValueKind]::DWord)
                $key.SetValue('DefFg',0xC0C0C0,[Microsoft.Win32.RegistryValueKind]::DWord)
                $key.SetValue('DefBg',0,[Microsoft.Win32.RegistryValueKind]::DWord)
            }
            $custom=$key.GetValue('CustomColors')
            if($null-ne $custom -and [int]$custom-ne 0){$failures++;"the run's CustomColors is still $custom after the restore"}
        }finally{$key.Dispose()}
    }
    # And the ConPTY choice: absent is the default (inbox) for every suite after this one.
    $conptyKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey((Get-LiteTestRegistryPath -RequireIsolation))
    try{$conptyKey.DeleteValue('Conpty',$false)}finally{$conptyKey.Dispose()}
    if($proc){
        if(-not $proc.HasExited){[void]$proc.CloseMainWindow()}
        if(-not $proc.WaitForExit(5000)){$proc.Kill();if(-not $proc.WaitForExit(10000)){throw 'Owned query window did not exit'}}
        $proc.Dispose()
    }
}
if($failures){exit 1};exit 0
