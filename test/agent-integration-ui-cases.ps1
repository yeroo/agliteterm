# Dot-sourced only by the token-owning, redirected selection fixture. Never invoke real Claude.
if(-not $script:selectionProc -or -not $clipboard){throw 'Agent integration requires guarded fixture'}
'-- P11 guarded command and agent integration --'
$script:p11Children=@{}
function Capture-P11Children {
    $roots=@($script:selectionHosts)+@($script:selectionProc)
    $queue=New-Object Collections.Generic.Queue[object]
    foreach($rootProc in $roots){if($rootProc -and -not $rootProc.HasExited){$queue.Enqueue($rootProc)}}
    $seen=@{}
    while($queue.Count){
        $parent=$queue.Dequeue();if($parent.HasExited -or $seen.ContainsKey($parent.Id)){continue};$seen[$parent.Id]=$true
        foreach($row in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($parent.Id)")){
            if($parent.HasExited){break}
            try{$child=Get-Process -Id $row.ProcessId -ErrorAction Stop;[void]$child.SafeHandle}catch{continue}
            $born=$child.StartTime.ToUniversalTime().Ticks
            if($child.HasExited -or ($born-$born%10)-ne $row.CreationDate.ToUniversalTime().Ticks -or $child.StartTime -lt $parent.StartTime){continue}
            $script:p11Children["$($child.Id)|$born"]=$child;$queue.Enqueue($child)
        }
    }
}
function Confirm-P11ChildrenExited {
    foreach($child in $script:p11Children.Values){if(-not $child.HasExited -and -not $child.WaitForExit(5000)){throw "Owned P11 child remains: $($child.Id); token retained"}}
    @($script:p11Children.Keys)|ConvertTo-Json|Set-Content (Join-Path $script:selectionArtifact 'p11-owned-exited.json')
    Write-Host "P11 retained descendant handles all signal exit ($($script:p11Children.Count)); no name-based process cleanup."
}
function P11-Wait([scriptblock]$Condition,[int]$Seconds=12){
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    do{if(& $Condition){return $true};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow-lt$until)
    return $false
}
function P11-Nodes {@((Selection-Rpc 'tree').workspaces|ForEach-Object{$_.sessions})}
function P11-Ready([string]$Pane,[string]$Marker='P11-PROMPT>'){
    if(-not (P11-Wait {([string](Selection-Rpc 'session.text' @{} $Pane)).Contains($Marker)})){
        $screen=[string](Selection-Rpc 'session.text' @{} $Pane);$screen|Set-Content (Join-Path $script:selectionArtifact "not-ready-$Pane.txt")
        throw "P11 pane not ready: $Pane / $Marker; screen: $screen"
    }
}
function P11-Literal([string]$Value){return "'"+$Value.Replace("'","''")+"'"}
$fakeDir=Join-Path $script:selectionArtifact 'fake-agent'; & "$PSScriptRoot/build-fake-claude.ps1" -OutputDirectory $fakeDir
$fake=Join-Path $fakeDir 'claude.exe';$launchLog=Join-Path $fakeDir 'launch.log'
$bundle=Split-Path ([IO.Path]::GetFullPath($Exe)) -Parent
$promptHelper=Join-Path $bundle 'agliteterm-prompt.ps1'
$catalogPath=Join-Path $profile 'agliteterm/profiles.json'
$setup="function global:prompt {'P11-PROMPT> '}; . "+(P11-Literal $promptHelper)
$catalog=@{default='P11';profiles=@(@{name='P11';command='powershell.exe';args=@('-NoLogo','-NoProfile','-NoExit','-Command',$setup);cwd=$script:selectionArtifact})}
$catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $catalogPath -Encoding utf8
$null=Selection-Rpc 'profiles.reload'
$pane=[string](Selection-Rpc 'session.new' @{profile='P11';name='P11-command'})
P11-Ready $pane;Capture-P11Children
$keymap=Join-Path $profile 'agliteterm/keymap.conf';$sink=Join-Path $script:selectionArtifact 'command-context.txt'
$send="[IO.File]::WriteAllText("+(P11-Literal $sink)+",'{AGW_SESSION_ID}|{AGW_PANE_ID}|{AGW_PANE}|{AGW_SESSION}')"
$keytext="command Send = $send`ncommand [new] Fresh = Write-Output 'P11-NEW-RESULT'`ncommand [overlay] Cover = Write-Output 'P11-OVERLAY-RESULT'`nleader = ctrl+k`nmap leader b = command:Send`nmap ctrl+f9 = command:Send`nmap ctrl+f10 = action_palette`n"
[IO.File]::WriteAllText($keymap,$keytext)
Check 'keymap reload publishes command catalog' ((Selection-Rpc 'keymap.reload')-eq'keymap reloaded')
$list=[string](Selection-Rpc 'command.list')
Check 'list reports labels, modes, bindings and text' ($list.Contains("Send`tsend`t") -and $list.Contains("Fresh`tnew`t") -and $list.Contains("Cover`toverlay`t"))
$null=Selection-Rpc 'command.run' @{name='sEnD'} $pane
Check 'send expands exact session and pane context' ((P11-Wait {Test-Path $sink}) -and [IO.File]::ReadAllText($sink)-ceq"$pane|$pane|left|P11-command")
$null=Selection-Rpc 'session.readonly' @{op='on'} $pane
$r=Selection-Rpc 'command.run' @{name='Send'} $pane -AllowError
Check 'readonly send refuses' (-not$r.ok -and $r.error-match'writable')
$null=Selection-Rpc 'session.readonly' @{op='off'} $pane
foreach($mode in 'bad','','SENDx'){$r=Selection-Rpc 'command.run' @{name='Send';mode=$mode} $pane -AllowError;Check 'invalid mode refuses without launch' (-not$r.ok)}
$r=Selection-Rpc 'command.run' @{name='   '} $pane -AllowError;Check 'blank command refuses' (-not$r.ok)
[IO.File]::WriteAllText($keymap,'command [bad] Broken = echo wrong')
$r=Selection-Rpc 'keymap.reload' -AllowError
Check 'invalid reload retains old effective catalog' (-not$r.ok -and (Selection-Rpc 'command.list')-ceq$list)
[IO.File]::WriteAllText($keymap,$keytext);$null=Selection-Rpc 'keymap.reload'
Check 'leader starts idle' ((Selection-Rpc 'command.leader' @{op='state'})-eq'idle')
Check 'leader begin arms' ((Selection-Rpc 'command.leader' @{op='begin'})-eq'pending')
Check 'leader cancel clears' ((Selection-Rpc 'command.leader' @{op='cancel'})-eq'idle')
$null=Selection-Rpc 'command.leader' @{op='begin'};Start-Sleep -Milliseconds 2100
Check 'leader timeout clears' ((Selection-Rpc 'command.leader' @{op='state'})-eq'idle')
[IO.File]::WriteAllText($sink,'BEFORE-LEADER-API')
$null=Selection-Rpc 'command.leader' @{op='key:b'}
Check 'leader key executes configured command' ((Selection-Rpc 'command.leader' @{op='state'})-eq'idle' -and (P11-Wait {[IO.File]::ReadAllText($sink)-ne'BEFORE-LEADER-API'}))
$keytext+="map leader shift+b = command:Send`n"
[IO.File]::WriteAllText($keymap,$keytext);$null=Selection-Rpc 'keymap.reload'
$null=Selection-Rpc 'session.select' @{} $pane
[IO.File]::WriteAllText($sink,'BEFORE-LEADER-KEY')
[LiteUi]::Chord($script:selectionHwnd,[int][char]'K',$false)
[LiteUi]::Key($script:selectionHwnd,0x10,1)
Check 'physical modifier keydown preserves pending leader' ((Selection-Rpc 'command.leader' @{op='state'})-eq'pending')
[LiteUi]::KeyMods($script:selectionHwnd,[int][char]'B',$false,$true,1)
Check 'physical leader then Shift+B executes custom command' (P11-Wait {[IO.File]::ReadAllText($sink)-ne'BEFORE-LEADER-KEY'})
[IO.File]::WriteAllText($sink,'BEFORE-KEY')
$null=Selection-Rpc 'session.select' @{} $pane
[LiteUi]::Chord($script:selectionHwnd,0x78,$false)
Check 'posted actual Ctrl+F9 binding executes custom command' (P11-Wait {[IO.File]::ReadAllText($sink)-ne'BEFORE-KEY'})
[IO.File]::WriteAllText($sink,'BEFORE-PALETTE')
[LiteUi]::Chord($script:selectionHwnd,0x79,$false)
foreach($character in 'Send'.ToCharArray()){[void][LiteUi]::PostMessageW($script:selectionHwnd,0x102,[IntPtr][int]$character,[IntPtr]1)}
Start-Sleep -Milliseconds 200
[LiteUi]::Key($script:selectionHwnd,13,1)
Check 'custom command is searchable and executable in palette' (P11-Wait {[IO.File]::ReadAllText($sink)-ne'BEFORE-PALETTE'})
$reply=[string](Selection-Rpc 'command.run' @{name='Fresh'} $pane)
$fresh=($reply -split ' ')[3].TrimEnd(';');P11-Ready $fresh 'P11-NEW-RESULT'
Check 'new mode creates an interactive session' ((P11-Nodes).Count-ge 2)
$reply=[string](Selection-Rpc 'command.run' @{name='Cover'} $pane)
$cover=($reply -split ' ')[3].TrimEnd(';');P11-Ready $cover 'P11-OVERLAY-RESULT'
Check 'overlay mode reports actual owned surface' ($cover-ne$pane)
$null=Selection-Rpc 'session.overlay' @{action='close'} $cover
$detachedSink=Join-Path $script:selectionArtifact 'detached.txt'
$r=[string](Selection-Rpc 'command.run' @{command=('echo %AGW_PANE_ID%>"'+$detachedSink+'"');mode='detached'} $pane)
Capture-P11Children
Check 'detached starts and receives context environment' ($r-match'detached process started \d+' -and (P11-Wait {Test-Path $detachedSink}) -and [IO.File]::ReadAllText($detachedSink).Trim()-eq$pane)
$before=(P11-Nodes).Count
$r=Selection-Rpc 'command.run' @{command=('x'*3000)} $pane -AllowError
Check 'oversized host arguments refused before session creation' (-not$r.ok -and (P11-Nodes).Count-eq$before)
$r=Selection-Rpc 'app.update' -AllowError
Check 'developer copy refuses real app updater' (-not$r.ok -and $r.error-match'not an installed update channel')
$r=Selection-Rpc 'install.cli' @{remove='maybe'} -AllowError
Check 'installer API validates before starting helper' (-not$r.ok -and $r.error-match'boolean')
$r=Selection-Rpc 'install.hooks' @{remove=$true} -AllowError
Check 'hooks removal refuses without touching real settings' (-not$r.ok -and $r.error-match'only')
$privateKey='Software\agliteterm-p11-fixture-'+[guid]::NewGuid().ToString('N')
if([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($privateKey)){throw 'Private registry fixture already exists'}
$privateReg=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($privateKey)
$initialPath='%P11_KEEP%\bin;;C:\untouched\'
$privateReg.SetValue('Path',$initialPath,[Microsoft.Win32.RegistryValueKind]::ExpandString)
$privateReg.Dispose()
Copy-Item -LiteralPath $fake -Destination (Join-Path $fakeDir 'agwintermctl.exe')
$installer=Join-Path $bundle 'agliteterm-install.ps1'
$systemPs=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
try {
    $reply=& $systemPs -NoProfile -NonInteractive -File $installer -Operation cli -EnvironmentKey $privateKey -CliDir $fakeDir
    Check 'CLI installer succeeds against private HKCU fixture' (($reply|ConvertFrom-Json).ok -and $LASTEXITCODE-eq 0)
    $privateReg=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($privateKey)
    try{$installedPath=$privateReg.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);$kind=$privateReg.GetValueKind('Path')}finally{$privateReg.Dispose()}
    Check 'CLI preserves unrelated PATH text and expandable-string kind' ($installedPath-ceq($initialPath+';'+$fakeDir) -and $kind-eq[Microsoft.Win32.RegistryValueKind]::ExpandString)
    $null=& $systemPs -NoProfile -NonInteractive -File $installer -Operation cli -EnvironmentKey $privateKey -CliDir $fakeDir
    $privateReg=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($privateKey)
    try{Check 'CLI PATH installation idempotent' ($privateReg.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)-ceq$installedPath)}finally{$privateReg.Dispose()}
    $null=& $systemPs -NoProfile -NonInteractive -File $installer -Operation cli -Remove -EnvironmentKey $privateKey -CliDir $fakeDir
    $privateReg=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($privateKey)
    try{Check 'CLI removal restores exact original PATH' ($privateReg.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)-ceq$initialPath)}finally{$privateReg.Dispose()}
}finally{
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($privateKey,$true)
    if([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($privateKey)){throw 'Private registry fixture cleanup failed'}
    'Private UUID registry fixture removed; real HKCU Environment Path was never accessed.'
}
$r=Selection-Rpc 'claude.adopt' @{} $pane -AllowError
Check 'adopt never guesses newest transcript in idle folder' (-not$r.ok -and $r.error-match'no verified')
$r=Selection-Rpc 'claude.yolo' @{} $pane -AllowError
Check 'yolo idle pane refuses without command input' (-not$r.ok)
function P11-Launches {if(Test-Path $launchLog){return @(Get-Content $launchLog)};return @()}
function P11-Agent([string]$Name,[string]$Id,[string]$Extra='') {
    $newPane=[string](Selection-Rpc 'session.new' @{profile='P11';name=$Name});P11-Ready $newPane
    $count=@(P11-Launches).Count
    $null=Selection-Rpc 'session.type' @{text=("& "+(P11-Literal $fake)+" --session-id $Id $Extra"+[char]13)} $newPane
    if(-not(P11-Wait {@(P11-Launches).Count-gt$count})){throw 'fake agent did not start'}
    Capture-P11Children;return $newPane
}
$sidA=[guid]::NewGuid().ToString();$sidB=[guid]::NewGuid().ToString()
$agentA=P11-Agent 'P11-agent-A' $sidA
$agentB=P11-Agent 'P11-agent-B' $sidB
Check 'two same-folder agents adopt their exact process UUIDs' ((Selection-Rpc 'claude.adopt' @{} $agentA)-match$sidA -and (Selection-Rpc 'claude.adopt' @{} $agentB)-match$sidB)
$null=Selection-Rpc 'session.readonly' @{op='on'} $agentA
$r=Selection-Rpc 'claude.yolo' @{} $agentA -AllowError
Check 'readonly agent yolo refuses before interrupt' (-not$r.ok -and $r.error-match'read-only')
$null=Selection-Rpc 'session.readonly' @{op='off'} $agentA
$count=@(P11-Launches).Count
$r=Selection-Rpc 'claude.yolo' @{} $agentA
Check 'explicit yolo queues, not falsely completes' ($r-match'queued')
Check 'prompt bridge resumes exact conversation with requested mode' ((P11-Wait {@(P11-Launches).Count-gt$count}) -and ((P11-Launches)[-1]-match("--resume\t"+$sidA)) -and (P11-Launches)[-1]-match'--dangerously-skip-permissions')
Capture-P11Children
Check 'sibling conversation was not restarted by targeted yolo' (@(P11-Launches|Where-Object {$_-match$sidB}).Count-eq 1)
$null=Selection-Rpc 'session.bind' @{agent='my-custom-binding --keep'} $agentB
$r=Selection-Rpc 'claude.yolo' @{} $agentB -AllowError
Check 'custom binding is preserved and not silently replaced by yolo' (-not$r.ok -and $r.error-match'custom binding')
$null=Selection-Rpc 'session.bind' @{agent='none'} $agentB
$null=Selection-Rpc 'claude.adopt' @{} $agentB
$ignoreId=[guid]::NewGuid().ToString()
[IO.File]::WriteAllText((Join-Path $fakeDir "ignore-$ignoreId"),'private fixture behavior')
$ignore=P11-Agent 'P11-agent-ignore' $ignoreId
$null=Selection-Rpc 'claude.yolo' @{} $ignore
$r=Selection-Rpc 'session.type' @{text='MUST-NOT-TYPE'} $ignore -AllowError
Check 'pending restart reserves API editing input' (-not$r.ok -and $r.error-match'reserved')
$r=Selection-Rpc 'session.paste' @{text='MUST-NOT-PASTE'} $ignore -AllowError
Check 'pending restart reserves entire bracketed paste' (-not$r.ok -and $r.error-match'reserved')
$null=Selection-Rpc 'session.readonly' @{op='on'} $ignore
Check 'readonly transition cancels restart without relaunch' (P11-Wait {@((Selection-Rpc 'events').events|Where-Object {$_.type-eq'agent.restart' -and $_.session-eq$ignore -and $_.info-match'pane state changed'}).Count-gt 0})
$null=Selection-Rpc 'session.readonly' @{op='off'} $ignore
$changedBefore=@((Selection-Rpc 'events').events|Where-Object {$_.type-eq'agent.restart' -and $_.session-eq$ignore -and $_.info-match'pane state changed'}).Count
$count=@(P11-Launches).Count
$null=Selection-Rpc 'claude.yolo' @{} $ignore
$null=Selection-Rpc 'session.bind' @{agent='none'} $ignore
Check 'same-value binding clear cancels pending restart without relaunch' ((P11-Wait {@((Selection-Rpc 'events').events|Where-Object {$_.type-eq'agent.restart' -and $_.session-eq$ignore -and $_.info-match'pane state changed'}).Count-gt$changedBefore}) -and @(P11-Launches).Count-eq$count)
$count=@(P11-Launches).Count
$null=Selection-Rpc 'claude.yolo' @{} $ignore
Check 'noninterruptible agent times out without fixed-delay relaunch' ((P11-Wait {@((Selection-Rpc 'events').events|Where-Object {$_.type-eq'agent.restart' -and $_.session-eq$ignore -and $_.info-match'timed out'}).Count-gt 0} 34) -and @(P11-Launches).Count-eq$count)
Check 'timeout releases editing-input reservation' ((Selection-Rpc 'session.type' @{text='q'} $ignore)-eq'typed')
$null=Selection-Rpc 'session.close' @{} $ignore
$lateId=[guid]::NewGuid().ToString()
[IO.File]::WriteAllText((Join-Path $fakeDir "late-$lateId"),'private late orphan fixture')
$late=P11-Agent 'P11-agent-late-child' $lateId
$parentPid=[int]((P11-Launches)[-1]-split "`t")[0]
$parent=@($script:p11Children.Values|Where-Object Id -eq $parentPid)[0]
if(-not$parent -or $parent.HasExited){throw 'Late fixture lacks retained parent identity'}
$count=@(P11-Launches).Count
$null=Selection-Rpc 'claude.yolo' @{} $late
$proof=Join-Path $fakeDir "late-proof-$lateId"
if(-not(P11-Wait {(Test-Path $proof) -and $parent.HasExited})){throw 'Late fixture child proof unavailable'}
$proofFields=[IO.File]::ReadAllText($proof)-split "`t"
$child=Get-Process -Id ([int]$proofFields[0]) -ErrorAction Stop;[void]$child.SafeHandle
$born=$child.StartTime.ToUniversalTime()
if($child.HasExited -or $born.ToFileTimeUtc()-ne[long]$proofFields[1] -or $born-lt$parent.StartTime.ToUniversalTime() -or $born-gt$parent.ExitTime.ToUniversalTime()){throw 'Late fixture child lifetime proof failed; token retained'}
$script:p11Children["$($child.Id)|$($born.Ticks)"]=$child
Check 'late console orphan prevents lifecycle resume even after parent exits' ((P11-Wait {@((Selection-Rpc 'events').events|Where-Object {$_.type-eq'agent.restart' -and $_.session-eq$late -and $_.info-match'timed out'}).Count-gt 0} 34) -and @(P11-Launches).Count-eq$count -and -not$child.HasExited)
$null=Selection-Rpc 'session.close' @{} $late
foreach($mode in 'fail','noop','new'){
    [IO.File]::WriteAllText((Join-Path $fakeDir 'version.txt'),'1.0.0');[IO.File]::WriteAllText((Join-Path $fakeDir 'update-mode.txt'),$mode)
    $count=@(P11-Launches).Count;$cursor=(Selection-Rpc 'events').cursor
    $r=[string](Selection-Rpc 'claude.update' @{} $pane)
    $updateCover=($r -split ' ')[6].TrimEnd(';')
    Check "$mode update starts a visible owned overlay" ($r-match'opened in owned overlay')
    Check "$mode update reports completion event" (P11-Wait {@((Selection-Rpc 'events' @{since=$cursor}).events|Where-Object type -eq 'agent.update').Count-gt 0} 25)
    (Selection-Rpc 'events' @{since=$cursor})|ConvertTo-Json -Depth 10|Set-Content (Join-Path $script:selectionArtifact "update-$mode-events.json")
    if($mode-eq'new'){
        Check 'new version restarts both exact conversations' (P11-Wait {@(P11-Launches).Count-ge$count+2})
        Capture-P11Children
        $lastA=@(P11-Launches|Where-Object {$_-match$sidA})[-1];$lastB=@(P11-Launches|Where-Object {$_-match$sidB})[-1]
        Check 'update preserves each prior permission mode' ($lastA-match'--dangerously-skip-permissions' -and $lastB-notmatch'--dangerously-skip-permissions')
    }else{
        Check "$mode update does not interrupt agents" (@(P11-Launches).Count-eq$count)
        Check "$mode owned log viewer displays updater output" (P11-Wait {([string](Selection-Rpc 'session.text' @{} $updateCover)).Contains('Claude update: installed version')})
        $null=Selection-Rpc 'session.overlay' @{action='close'} $updateCover
    }
}
[IO.File]::WriteAllText((Join-Path $fakeDir 'update-mode.txt'),'slow')
$count=@(P11-Launches).Count;$cursor=(Selection-Rpc 'events').cursor
$reply=[string](Selection-Rpc 'claude.update' @{} $pane);$slowCover=($reply-split' ')[6].TrimEnd(';')
Capture-P11Children
Check 'running updater refuses another update' (-not(Selection-Rpc 'claude.update' @{} $agentA -AllowError).ok)
'Waiting for the real five-minute updater-supervision deadline; private fake updater only.'
Check 'slow updater reaches real supervision timeout' (P11-Wait {@((Selection-Rpc 'events' @{since=$cursor}).events|Where-Object {$_.type-eq'agent.update' -and $_.info-match'update timed out'}).Count-gt 0} 310)
$r=Selection-Rpc 'claude.update' @{} $agentA -AllowError
Check 'expired supervisor still excludes a concurrent updater' (-not$r.ok -and $r.error-match'already running')
$null=Selection-Rpc 'session.overlay' @{action='close'} $slowCover
$r=Selection-Rpc 'claude.update' @{} $agentA -AllowError
Check 'closing expired viewer does not release updater process-tree exclusion' (-not$r.ok -and $r.error-match'already running')
[IO.File]::WriteAllText((Join-Path $fakeDir 'update-release.txt'),'allow owned fake updater to finish')
Check 'updater exit releases exclusion without late restarts' ((P11-Wait {@((Selection-Rpc 'events' @{since=$cursor}).events|Where-Object {$_.type-eq'agent.update' -and $_.info-match'exclusion released'}).Count-gt 0}) -and @(P11-Launches).Count-eq$count)
Capture-P11Children
'P11 fixtures used only the locally compiled fake claude.exe; no real Claude, profile installer or release updater invoked.'
