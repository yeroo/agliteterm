# P12 only runs under selection-ui's token, redirected files and restoration guards.
if(-not $script:selectionProc -or -not $clipboard){throw 'P12 requires guarded fixture'}
'-- P12 guarded workspace and attention acceptance --'
if(-not('P12Native' -as[type])){Add-Type -Name P12Native -Namespace '' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] static extern System.IntPtr SendMessageTimeoutW(System.IntPtr h,uint m,System.IntPtr w,System.IntPtr l,uint f,uint t,out System.IntPtr r);
[System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool InvalidateRect(System.IntPtr h,System.IntPtr r,bool erase);
public static void Redraw(System.IntPtr h,bool enabled) {System.IntPtr r;if(SendMessageTimeoutW(h,11,(System.IntPtr)(enabled?1:0),System.IntPtr.Zero,2,5000,out r)==System.IntPtr.Zero)throw new System.Exception("Owned redraw dispatch failed");if(enabled)InvalidateRect(h,System.IntPtr.Zero,false);}
'@ }
if(Get-Command Capture-P11Children -ErrorAction SilentlyContinue){Capture-P11Children}
Stop-SelectionSandbox
if(Get-Command Confirm-P11ChildrenExited -ErrorAction SilentlyContinue){Confirm-P11ChildrenExited}
$script:p12Children=@{}
function Capture-P12Children {
    $queue=[Collections.Generic.Queue[object]]::new();$seen=@{}
    foreach($rootProc in @($script:selectionHosts)+@($script:selectionProc)){if($rootProc -and -not $rootProc.HasExited){$queue.Enqueue($rootProc)}}
    while($queue.Count){
        $parent=$queue.Dequeue();if($parent.HasExited -or $seen.ContainsKey($parent.Id)){continue};$seen[$parent.Id]=$true
        foreach($row in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($parent.Id)")){
            if($parent.HasExited){break}
            try{$child=Get-Process -Id $row.ProcessId -ErrorAction Stop;[void]$child.SafeHandle}catch{continue}
            $born=$child.StartTime.ToUniversalTime().Ticks
            if($child.HasExited -or ($born-$born%10)-ne $row.CreationDate.ToUniversalTime().Ticks -or $child.StartTime-lt$parent.StartTime){continue}
            $script:p12Children["$($child.Id)|$born"]=$child;$queue.Enqueue($child)
        }
    }
}
function Confirm-P12ChildrenExited {
    foreach($child in $script:p12Children.Values){if(-not $child.HasExited -and -not $child.WaitForExit(5000)){throw "P12 descendant remains: $($child.Id); token retained"}}
    @($script:p12Children.Keys)|ConvertTo-Json|Set-Content (Join-Path $script:selectionArtifact 'p12-owned-exited.json')
    Write-Host "P12 retained descendant handles exited: $($script:p12Children.Count)."
}
function P12-Wait([scriptblock]$Condition,[int]$Seconds=20){
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    do{if(& $Condition){return $true};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow-lt$until)
    return $false
}
function P12-Nodes {@((Selection-Rpc 'tree').workspaces|ForEach-Object{$_.sessions})}
function P12-Node([string]$Id){P12-Nodes|Where-Object id -eq $Id|Select-Object -First 1}
function P12-Sink([string]$Id){Join-Path $script:selectionArtifact ("input-$Id.txt")}
function P12-Input([string]$Id){
    $file=P12-Sink $Id;if(-not(Test-Path $file)){return 'NOT-READY'}
    $stream=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=[IO.StreamReader]::new($stream)
    try{$reader.ReadToEnd()}finally{$reader.Dispose()}
}
function P12-Char([char]$Char){[void][LiteUi]::PostMessageW($h,0x102,[IntPtr][int]$Char,[IntPtr]::Zero);Start-Sleep -Milliseconds 150}
function P12-Ready([string]$Id){if(-not(P12-Wait {(P12-Input $Id)-ne'NOT-READY'})){throw "P12 sink not ready: $Id"};Capture-P12Children}
$catalogPath=Join-Path $profile 'agliteterm/profiles.json'
$sinkRoot=$script:selectionArtifact.Replace("'","''")
$setup="Add-Type 'using System; using System.Runtime.InteropServices; public static class RawInput { [DllImport(`"kernel32.dll`")] static extern IntPtr GetStdHandle(int n); [DllImport(`"kernel32.dll`")] static extern bool GetConsoleMode(IntPtr h,out uint m); [DllImport(`"kernel32.dll`")] static extern bool SetConsoleMode(IntPtr h,uint m); public static void Enable() { uint m; var h=GetStdHandle(-10); if(!GetConsoleMode(h,out m)||!SetConsoleMode(h,(m & ~7u)|0x200u))throw new Exception(`"raw console input unavailable`"); } }'; [RawInput]::Enable(); `$f=Join-Path '$sinkRoot' ('input-'+`$env:AGWINTERM_SESSION_ID+'.txt'); [IO.File]::WriteAllText(`$f,''); [Console]::Write('P12-SINK-READY'); `$inputBytes=[Console]::OpenStandardInput(); while (`$true) { `$k=`$inputBytes.ReadByte(); if(`$k-lt0){break}; [IO.File]::AppendAllText(`$f,`$k.ToString()+',') }"
@{default='P12';profiles=@(@{name='P12';command='powershell.exe';args=@('-NoLogo','-NoProfile','-Command',$setup);cwd=$script:selectionArtifact})}|ConvertTo-Json -Depth 8|Set-Content $catalogPath -Encoding utf8
Start-SelectionSandbox $Exe $profile;$h=$script:selectionHwnd;$g=Selection-Geometry
$a=[string](P12-Nodes|Select-Object -First 1).id;P12-Ready $a
$null=Selection-Rpc 'session.rename' @{name='P12-A'} $a
$b=[string](Selection-Rpc 'session.new' @{name='P12-B'});P12-Ready $b
$null=Selection-Rpc 'session.select' @{} $a
$split=[string](Selection-Rpc 'session.split' @{op='on'} $a);P12-Ready $split
$null=Selection-Rpc 'workspace.rename' @{name='P12-one'} '0'
$w2=[string](Selection-Rpc 'workspace.new' @{name='P12-two'})
$c=[string](Selection-Rpc 'session.new' @{name='P12-C';workspace=$w2});P12-Ready $c
$null=Selection-Rpc 'session.select' @{} $a
[void][LiteUi]::PostMessageW($h,7,[IntPtr]::Zero,[IntPtr]::Zero)
Check 'broadcast starts off' ((Selection-Rpc 'broadcast' @{op='state'})-eq'off')
$r=Selection-Rpc 'broadcast' @{op='typo'} -AllowError
Check 'broadcast typo refuses without toggling' (-not$r.ok -and (Selection-Rpc 'broadcast' @{op='get'})-eq'off')
$null=Selection-Rpc 'broadcast' @{op='on'}
P12-Char 'Q'
Check 'broadcast reaches focused, sibling session and split' ((P12-Wait {(P12-Input $a)-eq'81,' -and (P12-Input $b)-eq'81,' -and (P12-Input $split)-eq'81,'}))
Check 'broadcast excludes another workspace' ((P12-Input $c)-eq'')
$null=Selection-Rpc 'session.readonly' @{op='on'} $b
P12-Char 'R'
Check 'readonly broadcast recipient gets no keys' ((P12-Input $b)-eq'81,' -and (P12-Wait {(P12-Input $split)-eq'81,82,'}))
$null=Selection-Rpc 'session.type' @{text='S'} $a
Check 'API input stays targeted despite broadcast' ((P12-Wait {(P12-Input $a)-eq'81,82,83,'}) -and (P12-Input $split)-eq'81,82,')
$null=Selection-Rpc 'session.paste' @{text='T'} $a
Check 'API paste stays targeted despite broadcast' ((P12-Wait {(P12-Input $a)-eq'81,82,83,84,'}) -and (P12-Input $split)-eq'81,82,')
$null=Selection-Rpc 'session.readonly' @{op='on'} $a;P12-Char 'U'
Check 'readonly source prevents any fanout' ((P12-Input $split)-eq'81,82,')
$null=Selection-Rpc 'session.readonly' @{op='off'} $a
$null=Selection-Rpc 'broadcast' @{op='off'};P12-Char 'V'
Check 'broadcast off is targeted again' ((P12-Wait {(P12-Input $a)-eq'81,82,83,84,86,'}) -and (P12-Input $split)-eq'81,82,')
$null=Selection-Rpc 'session.split' @{op='off'} $a
$null=Selection-Rpc 'session.readonly' @{op='off'} $b
$cover=[string](Selection-Rpc 'session.overlay' @{action='open';pane='left';command="[Console]::Write('P12-COVER-READY'); while (`$true) {[void][Console]::ReadKey(`$true)}"} $b)
Capture-P12Children
if(-not(P12-Wait {@((P12-Node $b).paneOverlays).Count-gt0})){throw 'P12 pane cover did not open'}
$peerBefore=P12-Input $b;$sourceBefore=P12-Input $a
$null=Selection-Rpc 'broadcast' @{op='on'};P12-Char 'W'
Check 'broadcast skips a writable but covered peer' ((P12-Wait {(P12-Input $a)-ceq($sourceBefore+'87,')}) -and (P12-Input $b)-ceq$peerBefore)
$null=Selection-Rpc 'session.overlay' @{action='close';pane='left'} $b
$null=Selection-Rpc 'broadcast' @{op='off'}
P12-Char 'Y'
Check 'ordinary keyboard remains usable after cover closes' (P12-Wait {(P12-Input $a)-ceq($sourceBefore+'87,89,')})

# Live fixed-strike snapshots do not resize the PTY or clear notification badges.
$beforeShape=(P12-Node $a)|ConvertTo-Json -Depth 10 -Compress
Write-Screen ($esc+'[2J'+$esc+'[H'+$esc+'[?25l'+'AAAA-LIVE') $a
Write-Screen ($esc+'[2J'+$esc+'[H'+$esc+'[?25l'+'BBBB-LIVE') $b
$g=Selection-Geometry;$before=Shot 'p12-before-dashboard'
$null=Selection-Rpc 'dashboard' @{ids="$a,$b"}
$grid=Shot 'p12-dashboard'
Check 'dashboard paints a grid' ((Selection-PixelDiff $before $grid)-gt 100)
Check 'dashboard state reports exact requested IDs' (((Selection-Rpc 'dashboard' @{op='state'}).ids-join',')-ceq"$a,$b")
$shape=(P12-Node $a)|ConvertTo-Json -Depth 10 -Compress
Check 'dashboard leaves terminal geometry/state unchanged' ($shape-ceq$beforeShape)
Write-Screen ($esc+'[H'+'ZZZZ-CHANGED') $a
$changed=Shot 'p12-dashboard-live'
Check 'dashboard preview receives live updates' ((Selection-PixelDiff $grid $changed)-gt 20)
$inputBefore=P12-Input $a
P12-Char 'X';[LiteUi]::Chord($h,[int][char]'V',$false);[SelectionUi]::Wheel($h,($g.Left+40),($g.Top+40),1)
[SelectionUi]::Button($h,0x204,($g.Left+40),($g.Top+40));[SelectionUi]::Button($h,0x205,($g.Left+40),($g.Top+40))
Check 'dashboard captures characters paste wheel and right mouse' ((P12-Input $a)-ceq$inputBefore)
foreach($args_ in @(@{ids="$a,missing"},@{ids="$a,$a"},@{ids="$a,"},@{'font-size'=12},@{close='yes'},@{op='typo'},@{close=$true;ids='missing'},@{close=$true;'font-size'=12})){
    $r=Selection-Rpc 'dashboard' $args_ -AllowError
    Check 'invalid dashboard request preserves current grid' (-not$r.ok -and ((Selection-Rpc 'dashboard' @{op='state'}).ids-join',')-ceq"$a,$b")
}
[LiteUi]::Key($h,39,1)
Check 'dashboard Right selects second tile' ((Selection-Rpc 'dashboard' @{op='state'}).selected-eq1)
[LiteUi]::Key($h,13,1)
Check 'dashboard Enter activates selected session' ((P12-Wait {(P12-Node $b).active}) -and -not(Selection-Rpc 'dashboard' @{op='state'}).open)
$null=Selection-Rpc 'dashboard' @{ids="$a,$b"};[LiteUi]::Key($h,27,1)
Check 'dashboard Escape closes without switching' (-not(Selection-Rpc 'dashboard' @{op='state'}).open -and (P12-Node $b).active)
$null=Selection-Rpc 'dashboard' @{ids="$a,$b"}
[SelectionUi]::Button($h,0x201,($g.Left+35),($g.Top+40));[SelectionUi]::Button($h,0x202,($g.Left+35),($g.Top+40))
Check 'dashboard click activates first tile' ((P12-Wait {(P12-Node $a).active}) -and -not(Selection-Rpc 'dashboard' @{op='state'}).open)
Write-Screen ($esc+'[?1003h'+$esc+'[?1006h') $a
$mouseBefore=P12-Input $a
[SelectionUi]::Button($h,0x200,($g.Left+70),($g.Top+70))
Check 'mouse-report sink is live before activation guard check' (P12-Wait {$bytes=P12-Input $a;$bytes-cne$mouseBefore -and $bytes.EndsWith('77,')})
$mouseBefore=P12-Input $a
$null=Selection-Rpc 'dashboard' @{ids="$a,$b"};$null=Shot 'p12-activation-grid'
[SelectionUi]::Button($h,0x201,($g.Left+35),($g.Top+40))
Check 'dashboard activation owns capture until release' ([SelectionUi]::Capture($h)-eq$h)
[SelectionUi]::Button($h,0x200,($g.Left+75),($g.Top+75))
[SelectionUi]::Button($h,0x202,($g.Left+75),($g.Top+75))
Start-Sleep -Milliseconds 200
Check 'dashboard activation consumes drag and release' ((P12-Input $a)-ceq$mouseBefore)
Check 'dashboard activation releases capture' ([SelectionUi]::Capture($h)-eq[IntPtr]::Zero)
Write-Screen ($esc+'[?1003l'+$esc+'[?1006l') $a

$noticeCursor=(Selection-Rpc 'events').cursor
$foreground=[P12Native]::GetForegroundWindow()
$r=Selection-Rpc 'notify' @{title=('Long title '+('x'*200));body='P12 notice — 漢字'} $b
Check 'notify returns in-app delivery and creates badge' ($r-like'notified*' -and (P12-Node $b).unread-ge1)
Check 'notify does not steal foreground' ([P12Native]::GetForegroundWindow()-eq$foreground)
$noticeEvents=@((Selection-Rpc 'events' @{since=$noticeCursor}).events|Where-Object{$_.type-eq'notification'})
Check 'notify event retains exact target/body' ($noticeEvents.Count-eq1 -and $noticeEvents[0].session-ceq$b -and $noticeEvents[0].info-ceq(('Long title '+('x'*200))+': P12 notice — 漢字'))
$r=Selection-Rpc 'notify' @{body='bad'} 'missing' -AllowError
Check 'notify missing target refuses' (-not$r.ok)
$r=Selection-Rpc 'notify' @{body=('x'*4097)} $b -AllowError
Check 'oversized notify refuses' (-not$r.ok)
$null=Selection-Rpc 'session.seen' @{} $b
Check 'seen clears notification badge' ((P12-Node $b).unread-eq0)
$null=Selection-Rpc 'notify' @{body='Click to B'} $b
$cr=[SelectionUi]::Rect($h);$status=[SelectionUi]::ChildRect($h,'msctls_statusbar32')
$noticeY=$cr.Bottom-($status.Bottom-$status.Top)-30
[SelectionUi]::Button($h,0x201,($g.Left+30),$noticeY);[SelectionUi]::Button($h,0x202,($g.Left+30),$noticeY)
Check 'banner click selects exact target and clears badge' ((P12-Wait {(P12-Node $b).active}) -and (P12-Node $b).unread-eq0)
$null=Selection-Rpc 'notify' @{body='Keep until MRU commit'} $a
$null=Selection-Rpc 'session.switch' @{op='begin'}
for($walk=0;$walk-lt3 -and -not(P12-Node $a).active;$walk++){$null=Selection-Rpc 'session.switch' @{op='advance'}}
Check 'MRU preview preserves target notice' ((P12-Node $a).active -and (P12-Node $a).unread-ge1)
$null=Selection-Rpc 'session.switch' @{op='commit'}
Check 'MRU commit clears selected target notice' ((P12-Node $a).unread-eq0)

# Reorder preserves live membership and focused/active workspace identity, including persistence.
$null=Selection-Rpc 'workspace.select' @{} $w2
$null=Selection-Rpc 'workspace.focus' @{op='on'}
$null=Selection-Rpc 'workspace.move' @{dir='top'} $w2
$tree=Selection-Rpc 'tree'
Check 'workspace top reorders actual tree' ($tree.workspaces[0].name-eq'P12-two')
Check 'workspace reorder preserves memberships' (@($tree.workspaces[0].sessions|Where-Object id -eq $c).Count-eq1 -and @($tree.workspaces[1].sessions|Where-Object id -eq $a).Count-eq1)
$r=Selection-Rpc 'workspace.move' @{dir='typo'} '0' -AllowError
Check 'bad workspace direction refuses unchanged' (-not$r.ok -and (Selection-Rpc 'tree').workspaces[0].name-eq'P12-two')
$r=Selection-Rpc 'workspace.move' @{} '0' -AllowError
Check 'missing workspace direction refuses unchanged' (-not$r.ok -and (Selection-Rpc 'tree').workspaces[0].name-eq'P12-two')
$r=Selection-Rpc 'workspace.move' @{dir='top'} '999999999999999999' -AllowError
Check 'overflowing workspace selector refuses' (-not$r.ok)
$null=Selection-Rpc 'workspace.move' @{dir='bottom'} 'P12-two'
Check 'workspace name selector reverses move' ((Selection-Rpc 'tree').workspaces[1].name-eq'P12-two')
$null=Selection-Rpc 'workspace.focus' @{op='off'}
$state=Join-Path $profile ("agliteterm/sessions-$script:selectionPipe.tsv")
Check 'workspace order persisted' ((Get-Content $state|Where-Object{$_-like"W`t*"})-join'|' -ceq "W`tP12-one|W`tP12-two")

Start-Sleep -Milliseconds 500
New-Item -ItemType Directory "$state.cleared" | Out-Null
try {
    $r=Selection-Rpc 'restore.clear' @{} -AllowError
    Check 'unavailable clear marker refuses before deleting state' (-not$r.ok -and (Test-Path $state))
} finally {Remove-Item -LiteralPath "$state.cleared"} # exact empty directory created by this fixture
$blockedBackup=[IO.File]::Open("$state.bak",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
try {
    $r=Selection-Rpc 'restore.clear' @{} -AllowError
    Check 'locked backup reports partial clear failure' (-not$r.ok -and $r.error-like'*partial failure*' -and (Test-Path "$state.bak") -and -not(Test-Path $state))
} finally {$blockedBackup.Dispose()}
$null=Selection-Rpc 'restore.clear'
Check 'restore clear removes primary backup and temp only' (-not(Test-Path $state) -and -not(Test-Path "$state.bak") -and -not(Test-Path "$state.tmp") -and (Test-Path $catalogPath))
Check 'restore clear retains legacy re-import barrier' (Test-Path "$state.cleared" -PathType Leaf)
Check 'restore clear leaves all live sessions' ((P12-Nodes).Count-eq3)
Check 'restore clear is idempotent' ((Selection-Rpc 'restore.clear')-eq'no restore state')
$null=Selection-Rpc 'session.rename' @{name='P12-B-after-clear'} $b
Check 'later structural save recreates state as documented' (P12-Wait {Test-Path $state})
$null=Selection-Rpc 'session.select' @{} $a
$null=Selection-Rpc 'dashboard' @{ids="$a,$b,$c"};$null=Shot 'p12-before-prune';Capture-P12Children
[P12Native]::Redraw($h,$false)
try {
    $null=Selection-Rpc 'session.close' @{} $b
    Check 'dashboard prunes a closed middle session safely' ((P12-Wait {((Selection-Rpc 'dashboard' @{op='state'}).ids-join',')-ceq"$a,$c"}))
    [SelectionUi]::Button($h,0x201,([int](($g.Left+$g.Right)/2)+35),($g.Top+40))
    [SelectionUi]::Button($h,0x202,([int](($g.Left+$g.Right)/2)+35),($g.Top+40))
    Check 'stale dashboard rectangle cannot activate the next session' ((Selection-Rpc 'dashboard' @{op='state'}).open -and (P12-Node $a).active)
} finally {[P12Native]::Redraw($h,$true)}
$null=Selection-Rpc 'dashboard' @{close=$true}
$null=Selection-Rpc 'workspace.move' @{dir='top'} 'P12-two'
[void][LiteUi]::PostMessageW($h,0x111,[IntPtr]122,[IntPtr]::Zero) # actual Reopen Closed menu command (no default chord)
Check 'reopen history follows its workspace after reorder' (P12-Wait {
    $tree=Selection-Rpc 'tree'
    @($tree.workspaces|Where-Object name -eq 'P12-one'|ForEach-Object{$_.sessions}|Where-Object name -eq 'P12-B-after-clear').Count-eq1
})
$reopened=P12-Nodes|Where-Object name -eq 'P12-B-after-clear'|Select-Object -First 1
if(-not $reopened){throw 'P12 reopen did not produce expected session'}
P12-Ready $reopened.id
$newSplit=[string](Selection-Rpc 'session.split' @{op='on'} $reopened.id);P12-Ready $newSplit
$null=Selection-Rpc 'session.select' @{} $a
$null=Selection-Rpc 'notify' @{body='Survive pane promotion'} $reopened.id
$null=Selection-Rpc 'session.split.close' @{} $reopened.id
Check 'split promotion retains the logical session notification' ((P12-Node $reopened.id).unread-ge1)
Capture-P12Children
