# Runs only inside selection-ui's token-held, whole-format clipboard and registry-guarded fixture.
# The outer finally owns every window/host, including failed restart attempts.
if(-not $script:selectionProc -or -not $clipboard){throw 'P9 live checks require the guarded selection fixture'}
"-- P9 guarded driving acceptance --"
$s=@{Hwnd=$script:selectionHwnd}
function Send-Raw([string]$json){
    $request=$json | ConvertFrom-Json -AsHashtable
    $reply=Selection-Rpc $request.cmd $request.args $request.target -AllowError
    ConvertTo-Json -InputObject $reply -Depth 20 -Compress
}
function Nodes { @((Selection-Rpc 'tree').workspaces | ForEach-Object {$_.sessions}) }
. "$PSScriptRoot/driving-cases.ps1"

# Geometry refusal has an observable before/after ratio, not just an error string.
$id=[string](Selection-Rpc 'session.new' @{name='P9-geometry'})
Selection-Rpc 'session.select' @{} $id | Out-Null
Selection-Rpc 'session.split' @{op='on';axis='vertical'} $id | Out-Null
Selection-Rpc 'session.resize' @{ratio=0.3} | Out-Null
[void][LiteUi]::ShowWindow($s.Hwnd,6) # owned window only, minimize without taking focus
try {
    $r=P9 'session.resize' '' @{'grow-right'=4}
    Check 'minimized grow refuses without moving ratio' (-not $r.ok -and $r.error -like '*geometry is unavailable*' -and [math]::Abs([double](P9Node $id).splitRatios[0]-0.3)-lt 0.001)
} finally {[void][LiteUi]::ShowWindow($s.Hwnd,4)}
Selection-Rpc 'session.split.close' @{} $id | Out-Null
Selection-Rpc 'session.split' @{op='on';axis='vertical'} $id | Out-Null
Check 'promoted split owner retains ratio for its next split' ([math]::Abs([double](P9Node $id).splitRatios[0]-0.3)-lt 0.001)
Selection-Rpc 'session.close' @{} $id | Out-Null

# Search painting: compare the same static owned surface before, during and after search.
$id=[string](Selection-Rpc 'session.new' @{name='P9-pixels';command="[Console]::WriteLine('P9-PIXELS-READY'); while (`$true) { [void][Console]::ReadKey(`$true) }"})
Selection-Rpc 'session.select' @{} $id | Out-Null
if(-not (P9WaitText $id 'P9-PIXELS-READY')){throw 'Static pixel fixture did not become ready'}
Write-Screen ($esc+'[3J'+$esc+'[2J'+$esc+'[H'+$esc+'[?25l'+'漢字 needle') $id
$g=Selection-Geometry;$h=$script:selectionHwnd
$plain=Shot 'p9-search-before'
Selection-Rpc 'session.search' @{query='needle'} $id | Out-Null
$found=Shot 'p9-search-found'
Check 'search match is visibly painted' ((Selection-PixelDiff $plain $found)-gt 20)
$outside=0;$shotWidth=[math]::Min(350,$g.Right-$g.Left)
for($i=0;$i-lt $plain.Length;$i++){
    if($plain[$i]-ne $found[$i]){$x=$i%$shotWidth;$y=[int][math]::Floor($i/$shotWidth);if($x-lt 5*$g.Cw -or $x-ge 11*$g.Cw -or $y-ge $g.Ch){$outside++}}
}
Check 'search frame follows cell columns after wide glyphs' ($outside-eq 0)
Check 'search count is shown in status' ([SelectionUi]::Status($h,2)-match 'FIND 1 of 1')
Selection-Rpc 'session.search' @{action='close'} $id | Out-Null
$closed=Shot 'p9-search-closed'
Check 'closing search removes its paint' ((Selection-PixelDiff $plain $closed)-eq 0)
Selection-Rpc 'session.search' @{query='needle'} $id | Out-Null
Write-Screen ($esc+'[H'+'漢字 changed') $id
$stale=Shot 'p9-search-stale'
Selection-Rpc 'session.search' @{action='close'} $id | Out-Null
$noSearch=Shot 'p9-search-stale-closed'
Check 'changed row suppresses stale search paint' ((Selection-PixelDiff $stale $noSearch)-eq 0)
Selection-Rpc 'session.readonly' @{op='on'} $id | Out-Null
Selection-Rpc 'session.status' @{status='active'} $id | Out-Null
foreach($key in 27,3){[void][LiteUi]::PostMessageW($h,0x102,[IntPtr]$key,[IntPtr]::Zero)}
Start-Sleep -Milliseconds 200
Check 'blocked interrupts retain working status' ((P9Node $id).status -eq 'active')
Check 'readonly status is visible' ([SelectionUi]::Status($h,2)-match 'READ-ONLY')
Selection-Rpc 'session.readonly' @{op='off'} $id | Out-Null
[void][LiteUi]::PostMessageW($h,0x102,[IntPtr]27,[IntPtr]::Zero)
Start-Sleep -Milliseconds 200
Check 'writable interrupt clears working status (non-vacuous)' ((P9Node $id).status-eq 'idle')
Seed-Main
[SelectionUi]::Wheel($h,($g.Left+100),($g.Top+60),3)
$scrolled=Shot 'p9-readonly-scroll'
Selection-Rpc 'session.readonly' @{op='on'} $id | Out-Null
[LiteUi]::Key($h,8,1)
$backspace=Shot 'p9-readonly-backspace'
Check 'readonly Backspace preserves scrollback viewport' ((Selection-PixelDiff $scrolled $backspace)-eq 0)
[LiteUi]::KeyMods($h,9,$false,$true,1)
$backtab=Shot 'p9-readonly-backtab'
Check 'readonly Shift-Tab preserves scrollback viewport' ((Selection-PixelDiff $scrolled $backtab)-eq 0)
[LiteUi]::Key($h,0x27,1)
[void][LiteUi]::PostMessageW($h,0x102,[IntPtr][int][char]'x',[IntPtr]::Zero)
Start-Sleep -Milliseconds 200
$otherKeys=Shot 'p9-readonly-other-keys'
Check 'readonly arrows and characters preserve scrollback viewport' ((Selection-PixelDiff $scrolled $otherKeys)-eq 0)
Selection-Rpc 'session.readonly' @{op='off'} $id | Out-Null
[LiteUi]::Key($h,8,1)
$writable=Shot 'p9-writable-backspace'
Check 'writable Backspace really snaps back (non-vacuous)' ((Selection-PixelDiff $scrolled $writable)-gt 100)
Selection-Rpc 'session.close' @{} $id | Out-Null

function Check-P9HumanGate([string]$target,[IntPtr]$window,[string]$tag){
    Start-Sleep -Seconds 2
    Selection-Rpc 'session.readonly' @{op='on'} $target | Out-Null
    $command="[Console]::WriteLine('P9-'+'$tag')`r"
    foreach($ch in $command.ToCharArray()){[void][LiteUi]::PostMessageW($window,0x102,[IntPtr][int]$ch,[IntPtr]::Zero)}
    Start-Sleep -Milliseconds 250
    Check "$tag human input is blocked" ([string](Selection-Rpc 'session.text' @{} $target)-notlike "*P9-$tag*")
    Selection-Rpc 'session.readonly' @{op='off'} $target | Out-Null
    foreach($ch in $command.ToCharArray()){[void][LiteUi]::PostMessageW($window,0x102,[IntPtr][int]$ch,[IntPtr]::Zero)}
    Check "$tag writable input reaches its shell (non-vacuous)" (P9WaitText $target "P9-$tag")
    # An owned raw-key sink proves mouse reports reach a writable shell, then disappear under
    # readonly. Only this fixture's inert bytes are recorded; no user terminal/input is observed.
    $sink=Join-Path $script:selectionArtifact "$tag-input.txt"
    $sinkLiteral=$sink.Replace("'","''")
    $sinkCommand=@'
Add-Type -Name InputMode -Namespace P9 -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int n); [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h,out uint mode); [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h,uint mode);'; $stdinHandle=[P9.InputMode]::GetStdHandle(-10); [uint32]$inputMode=0; if(-not [P9.InputMode]::GetConsoleMode($stdinHandle,[ref]$inputMode)){throw 'no console mode'}; if(-not [P9.InputMode]::SetConsoleMode($stdinHandle,($inputMode -bor 512) -band (-bnot 7))){throw 'cannot set VT input'}; [IO.File]::WriteAllText('__P9_SINK__',''); $stream=[Console]::OpenStandardInput(); while($true){$byte=$stream.ReadByte(); if($byte-lt 0){break}; [IO.File]::AppendAllText('__P9_SINK__',$byte.ToString()+',')}
'@
    $sinkCommand=$sinkCommand.Replace('__P9_SINK__',$sinkLiteral)+"`r"
    Selection-Rpc 'session.type' @{text=$sinkCommand} $target | Out-Null
    # Add-Type may compile for longer than five seconds on a loaded disposable runner. Observe
    # its explicit ready file, never infer readiness from the typed command or elapsed delay.
    $sinkDeadline=[DateTime]::UtcNow.AddSeconds(20)
    while(-not (Test-Path -LiteralPath $sink) -and [DateTime]::UtcNow-lt $sinkDeadline){Start-Sleep -Milliseconds 50}
    if(-not (Test-Path -LiteralPath $sink)){throw "$tag raw-key sink did not start"}
    Selection-Rpc 'session.type' @{text='Q'} $target | Out-Null
    for($i=0;$i-lt 100 -and [IO.File]::ReadAllText($sink)-eq '';$i++){Start-Sleep -Milliseconds 50}
    Check "$tag raw-key sink consumes API input" ([IO.File]::ReadAllText($sink)-eq '81,')
    Selection-Rpc 'session.write' @{text=$esc+'[?1000h'+$esc+'[?1002h'+$esc+'[?1003h'+$esc+'[?1006h'} $target | Out-Null
    $mx=if($window-ne $h){32}elseif($tag-eq 'SPLIT-GATE'){[int](($g.Left+$g.Right)/2)+32}else{$g.Left+32}
    $my=if($window-ne $h){32}else{$g.Top+32}
    $events={
        Selection-Button @($window,0x201,$mx,$my)
        Selection-Button @($window,0x200,($mx+8),$my)
        Selection-Button @($window,0x202,($mx+8),$my)
        [SelectionUi]::Wheel($window,$mx,$my,1)
    }
    Selection-Rpc 'session.readonly' @{op='on'} $target | Out-Null
    & $events
    Start-Sleep -Milliseconds 250
    Check "$tag readonly blocks reporting click/motion/release/wheel" ([IO.File]::ReadAllText($sink)-eq '81,')
    Selection-Rpc 'session.readonly' @{op='off'} $target | Out-Null
    & $events
    for($i=0;$i-lt 100 -and [IO.File]::ReadAllText($sink)-eq '81,';$i++){Start-Sleep -Milliseconds 50}
    Check "$tag writable mouse reports reach the sink (non-vacuous)" ([IO.File]::ReadAllText($sink).Length-gt 3)
}
$id=[string](Selection-Rpc 'session.new' @{name='P9-surfaces'})
Selection-Rpc 'session.select' @{} $id | Out-Null
$split=[string](Selection-Rpc 'session.split' @{op='on';axis='vertical'} $id)
Selection-Rpc 'session.focus' @{dir='right'} | Out-Null
Check-P9HumanGate $split $h 'SPLIT-GATE'
Selection-Rpc 'session.split' @{op='off'} $id | Out-Null
$cover=[string](Selection-Rpc 'session.overlay' @{action='open';command='pwsh -NoProfile';pane='left'} $id)
Check-P9HumanGate $cover $h 'PANE-OVERLAY-GATE'
Selection-Rpc 'session.overlay' @{action='close';pane='left'} $id | Out-Null
foreach($kind in 'overlay','quick','scratch'){
    if($kind-eq 'overlay'){Selection-Rpc 'session.overlay' @{action='open';command='pwsh -NoProfile';'size-percent'=60} | Out-Null}
    else{$verb=if($kind-eq 'quick'){'quick'}else{'session.scratch'};Selection-Rpc $verb @{op='on'} | Out-Null}
    $popup=[IntPtr]::Zero
    for($i=0;$i-lt 50 -and $popup-eq [IntPtr]::Zero;$i++){Start-Sleep -Milliseconds 100;$popup=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')}
    if($popup-eq [IntPtr]::Zero){throw "P9 $kind popup not found"}
    [void][LiteUi]::PostMessageW($popup,7,[IntPtr]::Zero,[IntPtr]::Zero)
    Check-P9HumanGate 'active' $popup ($kind.ToUpper()+'-GATE')
    if($kind-eq 'overlay'){Selection-Rpc 'session.overlay' @{action='close'} | Out-Null}
    else{Selection-Rpc $verb @{op='off'} | Out-Null}
    # Popup off is posted to the UI thread. Observe dismissal before closing its parent session.
    for($i=0;$i-lt 100 -and [SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')-ne [IntPtr]::Zero;$i++){Start-Sleep -Milliseconds 50}
    if([SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')-ne [IntPtr]::Zero){throw "$kind popup did not dismiss"}
    [SelectionUi]::Button($h,0,0,0) # synchronous WM_NULL barrier: dismissal's handler has returned
}
Selection-Rpc 'session.close' @{} $id | Out-Null

# Replay writes only inert run-specific marker files. No agent executable is launched.
$replayMarker=Join-Path $script:selectionArtifact 'replay-markers.txt'
$quotedMarker=$replayMarker.Replace("'","''")
function ReplayCommand([string]$label){"[IO.File]::AppendAllText('$quotedMarker.$label','$label')"}
function ReplayText {
    # Separate sinks avoid sharing violations between simultaneously replayed split shells.
    (@('A','B','C','D','E','F','G','H','I') | ForEach-Object {if(Test-Path -LiteralPath "$replayMarker.$_"){[IO.File]::ReadAllText("$replayMarker.$_")}})-join ''
}
function Wait-ReplayText([string[]]$Expected) {
    # The 2500 ms replay timer is not proof that the shell has completed its file write.
    # Wait only for positive results; exact bytes still reject duplicate or superseded commands.
    for($attempt=0;$attempt-lt 50;$attempt++) {
        $actual=ReplayText
        if($Expected -ccontains $actual){return $actual}
        Start-Sleep -Milliseconds 100
    }
    return (ReplayText)
}
function Restart-P9([switch]$Adopt,[int]$SettleMilliseconds=3000){
    if($Adopt){
        if(-not $script:selectionHosts.Count){throw 'Adoption requires a previously pinned owned host'}
        $script:selectionProc.Kill()
        if(-not $script:selectionProc.WaitForExit(5000)){throw 'Owned adoption window failed to exit'}
    }else{Stop-SelectionSandbox}
    Start-SelectionSandbox $Exe $profile -Restore -SettleMilliseconds $SettleMilliseconds
    $script:selectionHwnd=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLite')
    $s.Hwnd=$script:selectionHwnd
}
$id=[string](Selection-Rpc 'session.new' @{name='P9-replay'})
Selection-Rpc 'session.restore' @{command=(ReplayCommand 'A')} $id | Out-Null
Selection-Rpc 'session.readonly' @{op='on'} $id | Out-Null
Restart-P9
$id=[string](@(Nodes | Where-Object name -eq 'P9-replay')[0].id)
$observed=Wait-ReplayText @('A')
Check 'fresh restore replays pin once' ($observed-ceq 'A') "markers=<$observed>"
Check 'readonly resets on fresh restore' ((Selection-Rpc 'session.readonly' @{op='get'} $id)-eq 'off')
Selection-Rpc 'session.bind' @{agent=(ReplayCommand 'B')} $id | Out-Null
Restart-P9
$id=[string](@(Nodes | Where-Object name -eq 'P9-replay')[0].id)
$observed=Wait-ReplayText @('AB')
Check 'binding wins over pin on fresh restore' ($observed-ceq 'AB') "markers=<$observed>"
Restart-P9 -Adopt
$id=[string](@(Nodes | Where-Object name -eq 'P9-replay')[0].id)
Check 'adopted live shell receives neither binding nor pin' ((ReplayText)-ceq 'AB')
Selection-Rpc 'session.bind' @{agent='none'} $id | Out-Null
Selection-Rpc 'session.restore' @{command=(ReplayCommand 'C')} $id | Out-Null
Restart-P9 -SettleMilliseconds 0
$id=[string](@(Nodes | Where-Object name -eq 'P9-replay')[0].id)
Selection-Rpc 'session.restore' @{command='none'} $id | Out-Null
Start-Sleep -Seconds 3
Check 'clearing a pending pin prevents replay' ((ReplayText)-ceq 'AB')
Selection-Rpc 'session.restore' @{command=(ReplayCommand 'D')} $id | Out-Null
Restart-P9 -SettleMilliseconds 0
$id=[string](@(Nodes | Where-Object name -eq 'P9-replay')[0].id)
Selection-Rpc 'session.restore' @{command=(ReplayCommand 'E')} $id | Out-Null
$observed=Wait-ReplayText @('ABE')
Check 'changing a pending pin replays the new command only' ($observed-ceq 'ABE') "markers=<$observed>"
Selection-Rpc 'session.restore' @{command=(ReplayCommand 'F')} $id | Out-Null
Restart-P9 -SettleMilliseconds 0
$id=[string](@(Nodes | Where-Object name -eq 'P9-replay')[0].id)
Selection-Rpc 'session.close' @{} $id | Out-Null
Start-Sleep -Seconds 3
Check 'closed pending pane never receives replay' ((ReplayText)-ceq 'ABE')
$id=[string](Selection-Rpc 'session.new' @{name='P9-roles'})
Selection-Rpc 'session.select' @{} $id | Out-Null
$split=[string](Selection-Rpc 'session.split' @{op='on';axis='vertical'} $id)
$exactPin=(ReplayCommand 'G')+' # "C:\Work\A"' + "`t" + 'tab'
Selection-Rpc 'session.restore' @{command=$exactPin} $id | Out-Null
Selection-Rpc 'session.bind' @{agent=(ReplayCommand 'I')} $id | Out-Null
Selection-Rpc 'session.restore' @{command=(ReplayCommand 'H')} $split | Out-Null
Selection-Rpc 'session.resize' @{ratio=0.37} | Out-Null
Restart-P9
$node=@(Nodes | Where-Object name -eq 'P9-roles')[0]
$id=[string]$node.id;$split=[string]$node.paneIds[1]
Check 'role pins survive restart with exact quote/backslash/tab bytes' ([string]$node.restoreCommands.$id-ceq $exactPin -and [string]$node.restoreCommands.$split-ceq (ReplayCommand 'H'))
Check 'split ratio survives fresh restart' ([math]::Abs([double]$node.splitRatios[0]-0.37)-lt 0.001)
$observed=Wait-ReplayText @('ABEIH','ABEHI')
Check 'binding and split pin replay once each, never the overridden owner pin' ($observed-ceq 'ABEIH' -or $observed-ceq 'ABEHI') "markers=<$observed>"
