# Keyboard/mouse selection parity. Run locally under the shared hub token; CI is an isolated host.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$script:selectionArtifact=Join-Path (Split-Path $PSScriptRoot -Parent) ('.revmux/selection-ui-'+(Get-Date -Format yyyyMMddTHHmmss)+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory $script:selectionArtifact -Force | Out-Null
Start-Transcript "$script:selectionArtifact/transcript.log" | Out-Null
$hub='C:/Users/boris/AI/bin/suite-token.py';$lease=$null;$ownLease=$false
function Skip-Selection([string]$reason){"SKIP selection-ui: $reason";Stop-Transcript|Out-Null;exit $(if($Strict){1}else{0})}
if(Test-Path $hub){
    if($env:AGLITETERM_TEST_RECEIPT){
        $lease=Get-Content -Raw $env:AGLITETERM_TEST_RECEIPT|ConvertFrom-Json
        $state=& python $hub status|ConvertFrom-Json
        if(-not $state.ok -or -not $state.held -or $state.generation -ne $lease.generation -or $state.owner -ne $lease.owner -or $state.run_id -ne $lease.run_id){throw 'Inherited suite-token receipt does not match the live holder'}
    }else{
        $run=Split-Path $script:selectionArtifact -Leaf
        $raw=& python $hub acquire --owner codex-agwinterm --run $run --worktree (Split-Path $PSScriptRoot -Parent) --holder-pid $PID --purpose 'P7 selection UI verification'
        $lease=$raw|ConvertFrom-Json
        if($LASTEXITCODE -ne 0 -or -not $lease.ok){Skip-Selection "suite token unavailable: $raw"}
        $ownLease=$true
    }
}elseif($env:CI -ne 'true'){Skip-Selection 'shared suite-token helper absent; no local interactive tests ran'}
$script:selectionPipe='p7sel'+[guid]::NewGuid().ToString('N').Substring(0,10)
$script:selectionProc=$null;$script:selectionHosts=@();$script:selectionLaunched=$false;$script:checks=0;$script:failures=0
$clipboard=$null;$geoSaved=$false;$regBefore=@{};$cleanupOk=$true;$regPath='Software\agliteterm';$skipReason=$null
function Check([string]$name,[bool]$ok,[string]$detail=''){$script:checks++;if($ok){"PASS $name"}else{$script:failures++;"FAIL $name : $detail"}}
try {
    . "$PSScriptRoot/selection-ui-env.ps1"
    if($ownLease){$lease|ConvertTo-Json -Depth 8|Set-Content "$script:selectionArtifact/lease.json"}
    & "$PSScriptRoot/selection-ui-cleanup.unit.ps1"
    & "$PSScriptRoot/selection-ui-snapshot.unit.ps1"
    # Token excludes other cooperating suites, not the user's app. Do not adopt/stop a shared host.
    if(@(Get-CimInstance Win32_Process -Filter "Name='agliteterm.exe' OR Name='agwinterm-ptyhost.exe'").Count){$skipReason='Existing lite/host: refusing isolated selection fixture';throw $skipReason}
    $clipboard=Save-SelectionClipboard "$script:selectionArtifact/clipboard-before.dpapi"
    $reg=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($regPath)
    $names=@('Key_MarkMode','Key_SelectAll','Key_ZoomIn','Key_ZoomOut','Key_ZoomReset')+@('WinX','WinY','WinW','WinH','WinMax'|ForEach-Object{"$_-$script:selectionPipe"})
    foreach($name in $names){$exists=$reg -and $reg.GetValueNames() -contains $name;$regBefore[$name]=@{Exists=$exists;Value=$(if($exists){$reg.GetValue($name)});Kind=$(if($exists){[int]$reg.GetValueKind($name)})}}
    if($reg){$reg.Dispose()};$geoSaved=$true
    $regBefore|ConvertTo-Json -Depth 8|Set-Content "$script:selectionArtifact/registry-before.json"
    # Deterministic defaults, even if the user's dialog previously cleared/rebound these actions.
    $reg=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($regPath)
    $reg.DeleteValue('Key_MarkMode',$false);$reg.DeleteValue('Key_SelectAll',$false);$reg.Dispose()
    $profile=Join-Path $script:selectionArtifact profile;New-Item -ItemType Directory $profile|Out-Null
    Start-SelectionSandbox $Exe $profile
    $h=$script:selectionHwnd;$g=Selection-Geometry
    "Grid geometry: $($g|ConvertTo-Json -Compress)"
    $esc=[string][char]27
    function Write-Screen([string]$text,[string]$target='active'){$null=Selection-Rpc 'session.write' @{text=$text} $target;Start-Sleep -Milliseconds 250}
    function Selected([string]$target='active'){[string](Selection-Rpc 'session.copy' @{} $target)}
    # Native cmdlets avoid a WinForms/OLE clipboard owner whose message pump would be blocked
    # inside the posted-input helper while the target tries to replace its delayed-render data.
    function Set-Marker { Set-Clipboard -Value 'P7-CLIPBOARD-SENTINEL' }
    function Clip {
        for($attempt=0;$attempt -lt 20;$attempt++){
            try{return [string](Get-Clipboard -Raw)}catch{if($attempt-eq 19){throw};Start-Sleep -Milliseconds 100}
        }
    }
    function Main-Screen { Write-Screen ($esc+'[?1049l'+$esc+'[?1000l'+$esc+'[?1002l'+$esc+'[?1003l'+$esc+'[2J'+$esc+'[H'+$esc+'[?25l') }
    function Seed-Main { Main-Screen;Write-Screen (((1..200|ForEach-Object{'MARKER-{0:D3} word two'-f $_})-join "`r`n")+"`r`n") }
    function Seed-Alt {
        Write-Screen ($esc+'[?1049h'+$esc+'[2J'+$esc+'[H'+$esc+'[?25l')
        for($row=0;$row -lt $g.Rows;$row++){Write-Screen ($esc+"[$($row+1);1HALT-$row word two")}
        Write-Screen ($esc+'[6;3H') # known caret; surface.cursor exposes only a column
    }
    function Shot([string]$name){Selection-Capture $h $name $g.Left $g.Top ([math]::Min(350,$g.Right-$g.Left)) ([math]::Min(200,$g.Bottom-$g.Top))}
    Seed-Main
    $before=Shot 'wheel-before';[SelectionUi]::Wheel($h,($g.Left+100),($g.Top+60),3);$after=Shot 'wheel-after'
    Check 'wheel: posted main-screen wheel changes the viewport' ((Selection-PixelDiff $before $after)-gt 100)
    [SelectionUi]::Wheel($h,($g.Left+100),($g.Top+60),-3);$back=Shot 'wheel-back'
    Check 'wheel: reversing notches restores the viewport' ((Selection-PixelDiff $before $back)-eq 0)
    [SelectionUi]::Wheel($h,10,100,3);$side=Shot 'wheel-sidebar'
    Check 'wheel: sidebar changes no pane' ((Selection-PixelDiff $back $side)-eq 0)
    Set-Marker;[LiteUi]::Chord($h,[int][char]'A',$true)
    Check 'Select All: seeded chord includes history and live grid' ((Selected)-match 'MARKER-001' -and (Selected)-match 'MARKER-200')
    Check 'Select All: highlight only, no clipboard write' ((Clip)-eq 'P7-CLIPBOARD-SENTINEL')
    $null=Selection-Rpc 'selection.clear'

    # Release semantics: double-click does not copy until the corresponding button-up.
    Main-Screen;Write-Screen ($esc+'[HMARKER-7 word two'+$esc+'[6;3H')
    $x=$g.Left+2*$g.Cw;$y=$g.Top+[int]($g.Ch/2)
    Set-Marker;[SelectionUi]::Button($h,0x203,$x,$y);[SelectionUi]::Button($h,0x200,($x+1),$y);Start-Sleep -Milliseconds 200
    Check 'double-click: word selection uses non-blank cells' ((Selected)-eq 'MARKER-7') (Selected)
    Check 'double-click: clipboard stays unchanged while button is held' ((Clip)-eq 'P7-CLIPBOARD-SENTINEL')
    [SelectionUi]::Button($h,0x202,$x,$y);Start-Sleep -Milliseconds 200
    Check 'release copies: selected word matches clipboard' ((Clip)-eq 'MARKER-7') (Clip)
    # A fresh, contiguous click sequence: assertions/pipe/clipboard round trips cannot consume
    # the system's double-click interval between the second and third press.
    [SelectionUi]::Button($h,0x203,$x,$y);[SelectionUi]::Button($h,0x202,$x,$y)
    [SelectionUi]::Button($h,0x201,$x,$y);[SelectionUi]::Button($h,0x200,($x+1),$y);[SelectionUi]::Button($h,0x202,$x,$y);Start-Sleep -Milliseconds 200
    Check 'triple-click: selects and copies the whole visible line' ((Selected)-eq 'MARKER-7 word two' -and (Clip)-eq (Selected)) (Selected)
    Set-Marker;[SelectionUi]::Button($h,0x203,($g.Left+30*$g.Cw),$y);[SelectionUi]::Button($h,0x202,($g.Left+30*$g.Cw),$y);Start-Sleep -Milliseconds 200
    Check 'double-click blank: no selection and clipboard untouched' ((Selected)-eq '' -and (Clip)-eq 'P7-CLIPBOARD-SENTINEL')
    [SelectionUi]::Button($h,0x203,($g.Left+1),$y);[SelectionUi]::Button($h,0x200,($g.Left+2),$y);[SelectionUi]::Button($h,0x202,($g.Left+2),$y);Start-Sleep -Milliseconds 200
    Check 'double-click: first-cell jitter preserves the whole word on release' ((Selected)-eq 'MARKER-7' -and (Clip)-eq 'MARKER-7') (Selected)

    # The timer cancellation door: enter alt while holding an out-of-bounds ordinary drag.
    [SelectionUi]::Button($h,0x201,($g.Left+50),($g.Top+3*$g.Ch));[SelectionUi]::Button($h,0x200,($g.Left+50),($g.Top-20));Start-Sleep -Milliseconds 100
    Check 'cancel setup: frame drag owns capture' ([SelectionUi]::Capture($h)-eq $h)
    Write-Screen ($esc+'[?1049h'+$esc+'[2J'+$esc+'[HCANCEL-ALT')
    Check 'cancel: screen crossing releases frame capture before button-up' ([SelectionUi]::Capture($h)-eq [IntPtr]::Zero)
    [SelectionUi]::Button($h,0x202,($g.Left+50),($g.Top-20));Start-Sleep -Milliseconds 100
    Check 'cancel: frame capture remains released after button-up' ([SelectionUi]::Capture($h)-eq [IntPtr]::Zero)
    Main-Screen;Write-Screen ($esc+'[HEVICT-BEGIN')
    [SelectionUi]::Button($h,0x201,($g.Left+8),$y);[SelectionUi]::Button($h,0x200,($g.Left+40),($y+$g.Ch));Start-Sleep -Milliseconds 100
    Check 'cancel setup: eviction fixture owns capture' ([SelectionUi]::Capture($h)-eq $h)
    # Eviction is accounted by the PTY reader, not display-only session.write injection.
    # Emit through the fixture shell so this exercises the production bookkeeping path.
    $null=Selection-Rpc 'session.type' @{text='[Console]::Write(("E"+[char]13+[char]10)*6000)'}
    [LiteUi]::Key($h,0x0D,1)
    for($i=0;$i-lt 50;$i++){
        if([string](Selection-Rpc 'session.text')-notmatch 'EVICT-BEGIN'){break}
        Start-Sleep -Milliseconds 100
    }
    [SelectionUi]::Button($h,0x200,($g.Left+48),($y+$g.Ch));Start-Sleep -Milliseconds 100
    Check 'cancel: eviction drops selection and releases capture on the next move' ((Selected)-eq '' -and [SelectionUi]::Capture($h)-eq [IntPtr]::Zero)
    [SelectionUi]::Button($h,0x202,($g.Left+48),($y+$g.Ch))

    # Caret is deliberately placed on row 0, col 0: Enter after five Right moves copies ABCDE.
    Main-Screen;Write-Screen ($esc+'[HABCDEFGHIJKLMN'+$esc+'[H')
    Set-Marker;[LiteUi]::Chord($h,[int][char]'M',$true)
    Check 'mark: seeded chord displays MARK in status part 2' ([SelectionUi]::Status($h,2)-match 'MARK$') ([SelectionUi]::Status($h,2))
    [LiteUi]::Key($h,0x27,5)
    Check 'mark: Right extends the exclusive end from the known caret' ((Selected)-eq 'ABCDE') (Selected)
    [LiteUi]::Key($h,0x0D,1)
    Check 'mark: Enter copies, keeps highlight, and exits' ((Clip)-eq 'ABCDE' -and (Selected)-eq 'ABCDE' -and [SelectionUi]::Status($h,2)-notmatch 'MARK')
    Set-Marker;[LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Key($h,0x27,2);[LiteUi]::Key($h,0x1B,1)
    Check 'mark: Escape clears without copying' ((Selected)-eq '' -and (Clip)-eq 'P7-CLIPBOARD-SENTINEL' -and [SelectionUi]::Status($h,2)-notmatch 'MARK')
    [LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Chord($h,[int][char]'M',$true)
    Check 'mark: its configured chord toggles off and clears' ((Selected)-eq '' -and [SelectionUi]::Status($h,2)-notmatch 'MARK')
    [LiteUi]::Chord($h,[int][char]'M',$true);$text=[string](Selection-Rpc 'session.text');[LiteUi]::Key($h,[int][char]'X',1)
    Check 'mark: other keys do not reach the shell' ([string](Selection-Rpc 'session.text')-eq $text)
    [LiteUi]::Key($h,0x1B,1)

    Write-Screen ($esc+'[H');[LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Key($h,0x23,1)
    Check 'mark: End selects through the exclusive right edge' ((Selected)-eq 'ABCDEFGHIJKLMN') (Selected)
    [LiteUi]::Key($h,0x24,1)
    Check 'mark: Home returns the focus end to column zero' ((Selected)-eq '')
    [LiteUi]::Key($h,0x27,3);[LiteUi]::Chord($h,[int][char]'C',$false)
    $copied=Clip;$selected=Selected;$status=[SelectionUi]::Status($h,2)
    Check 'mark: Ctrl+C copies and exits while preserving the highlight' ($copied-eq 'ABC' -and $selected-eq 'ABC' -and $status-notmatch 'MARK') "clipboard=<$copied>; selection=<$selected>; status=<$status>"
    $null=Selection-Rpc 'selection.clear'

    Seed-Main;$before=Shot 'drag-before'
    [LiteUi]::DragHold($h,($g.Left+10*$g.Cw),($g.Top+5*$g.Ch),($g.Left+2*$g.Cw),($g.Top-20),1000)
    $dragged=Selected;$null=Selection-Rpc 'selection.clear'
    $after=Shot 'drag-after'
    Check 'drag: holding above the edge scrolls the viewport' ((Selection-PixelDiff $before $after)-gt 100)
    Check 'release copies: autoscrolled selection matches clipboard' ($dragged-match 'MARKER-' -and (Clip)-eq $dragged)
    $before=Shot 'drag-down-before'
    [LiteUi]::DragHold($h,($g.Left+2*$g.Cw),($g.Top+5*$g.Ch),($g.Left+10*$g.Cw),($g.Bottom+20),1000)
    $dragged=Selected;$null=Selection-Rpc 'selection.clear';$after=Shot 'drag-down-after'
    Check 'drag: holding below the edge scrolls back toward the live grid' ((Selection-PixelDiff $before $after)-gt 100)
    Check 'release copies: downward autoscroll copies exactly the range' ($dragged-match 'MARKER-' -and (Clip)-eq $dragged)
    Seed-Alt;$before=Shot 'alt-before';[SelectionUi]::Wheel($h,($g.Left+100),($g.Top+60),10);$after=Shot 'alt-wheel'
    Check 'THE PIN: alt-screen wheel changes no visible cells' ((Selection-PixelDiff $before $after)-eq 0)
    Set-Marker;[LiteUi]::Chord($h,[int][char]'A',$true)
    Check 'THE PIN: Select All takes alt rows and no main history' ((Selected)-match '^ALT-0' -and (Selected)-notmatch 'MARKER-')
    Check 'THE PIN: Select All still does not copy' ((Clip)-eq 'P7-CLIPBOARD-SENTINEL')
    $null=Selection-Rpc 'selection.clear'
    [LiteUi]::DragHold($h,($g.Left+10*$g.Cw),($g.Top+5*$g.Ch),$g.Left,($g.Top-20),1000)
    Check 'THE PIN: drag above alt stops at ALT-0, never main history' ((Selected)-match '^ALT-0' -and (Selected)-notmatch 'MARKER-') (Selected)
    Write-Screen ($esc+'[6;1H');[LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Key($h,0x26,40)
    Check 'THE PIN: mark Up stops at the first alt row' ((Selected)-match '^ALT-0' -and (Selected)-notmatch 'MARKER-') (Selected)
    [LiteUi]::Key($h,0x1B,1)
    [LiteUi]::DragHold($h,$g.Left,($g.Top+5*$g.Ch),($g.Left+20*$g.Cw),($g.Bottom+20),1000)
    Check 'THE PIN: drag below alt ends on its last row' ((Selected)-match "ALT-$($g.Rows-1)" -and (Selected)-notmatch 'MARKER-') (Selected)
    [LiteUi]::Chord($h,[int][char]'M',$true);Main-Screen;[LiteUi]::Key($h,[int][char]'X',1)
    Check 'mark: screen crossing ends the mode and releases the next key' ([SelectionUi]::Status($h,2)-notmatch 'MARK' -and (Selected)-eq '' -and [string](Selection-Rpc 'session.text')-match 'X')
    $r=Selection-Rpc 'selection.all' @{} 'p7-no-such-surface' -AllowError
    Check 'selection: missing target remains a refusal' (-not $r.ok)

    # Focus stays left; only the right-hand viewport may move under a right-hand wheel.
    Main-Screen
    $owner=@((Selection-Rpc 'tree').workspaces.sessions | Where-Object active)[0].id
    $split=Selection-Rpc 'session.split' @{op='on';axis='vertical'} $owner
    Start-Sleep -Seconds 2
    $right=[int](($g.Left+$g.Right)/2)+3
    foreach($target in @($owner,$split)){Write-Screen ($esc+'[2J'+$esc+'[H'+((1..180|ForEach-Object{'SPLIT-{0:D3}'-f $_})-join "`r`n")+"`r`n"+$esc+'[?25l') $target}
    $null=Selection-Rpc 'session.focus' @{dir='left'}
    $leftBefore=Selection-Capture $h 'split-left-before' $g.Left $g.Top 300 150
    $rightBefore=Selection-Capture $h 'split-right-before' $right $g.Top 300 150
    [SelectionUi]::Wheel($h,($right+80),($g.Top+60),3)
    $leftAfter=Selection-Capture $h 'split-left-after' $g.Left $g.Top 300 150
    $rightAfter=Selection-Capture $h 'split-right-after' $right $g.Top 300 150
    Check 'split wheel: unfocused pane under pointer scrolls' ((Selection-PixelDiff $rightBefore $rightAfter)-gt 100)
    Check 'split wheel: focused other pane stays unchanged' ((Selection-PixelDiff $leftBefore $leftAfter)-eq 0)
    [LiteUi]::Chord($h,[int][char]'M',$true);$null=Selection-Rpc 'session.focus' @{dir='right'};[LiteUi]::Key($h,[int][char]'X',1)
    Check 'mark: switching pane ends the mode before the next shell key' ([SelectionUi]::Status($h,2)-notmatch 'MARK' -and (Selected)-eq '' -and [string](Selection-Rpc 'session.text' @{} $split)-match 'X')
    $null=Selection-Rpc 'session.split' @{op='off'} $owner;Start-Sleep -Milliseconds 400

    # Popup surface resolved from its creation event; all window posts remain owned by our PID.
    $null=Selection-Rpc 'session.overlay' @{action='open';command='pwsh -NoProfile';'size-percent'='60'}
    $ph=[IntPtr]::Zero
    for($i=0;$i-lt 50 -and $ph-eq [IntPtr]::Zero;$i++){Start-Sleep -Milliseconds 200;$ph=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')}
    if($ph -eq [IntPtr]::Zero){throw 'Popup did not open'}
    Start-Sleep -Seconds 2
    [void][SelectionUi]::PostMessageW($ph,7,[IntPtr]::Zero,[IntPtr]::Zero);Start-Sleep -Milliseconds 200
    Write-Screen ($esc+'[2J'+$esc+'[HPOPUP-SELECTION'+$esc+'[?25l')
    $null=Selection-Rpc 'selection.clear'
    $p0=Selection-Capture $ph 'popup-before' 0 0 240 80
    $r=Selection-Rpc 'selection.all'
    $p1=Selection-Capture $ph 'popup-selected' 0 0 240 80
    Check 'popup: selection all succeeds and copy names its own text' ($r-eq 'selected all' -and (Selected)-match 'POPUP-SELECTION') (Selected)
    Check 'popup: the selected band is actually painted' ((Selection-PixelDiff $p0 $p1)-gt 100)
    $null=Selection-Rpc 'selection.clear';$p2=Selection-Capture $ph 'popup-cleared' 0 0 240 80
    Check 'popup: clear removes its painted highlight' ((Selection-PixelDiff $p0 $p2)-eq 0)
    [LiteUi]::Drag($ph,0,[int]($g.Ch/2),($g.Cw*5),[int]($g.Ch/2))
    Check 'popup: drag selects and release copies its cells' ((Selected)-eq 'POPUP' -and (Clip)-eq 'POPUP') (Selected)
    Write-Screen ($esc+'[H');[LiteUi]::Chord($ph,[int][char]'M',$true);[LiteUi]::Key($ph,0x27,5)
    Check 'popup: mark mode extends at its own caret' ((Selected)-eq 'POPUP' -and [SelectionUi]::Status($h,2)-match 'MARK') (Selected)
    [LiteUi]::Chord($ph,[int][char]'C',$false)
    Check 'popup: mark Ctrl+C copies and exits' ((Clip)-eq 'POPUP' -and [SelectionUi]::Status($h,2)-notmatch 'MARK')
    [SelectionUi]::Button($ph,0x201,8,12);[SelectionUi]::Button($ph,0x200,16,12);Start-Sleep -Milliseconds 100
    Check 'cancel setup: popup drag owns capture' ([SelectionUi]::Capture($ph)-eq $ph)
    Write-Screen ($esc+'[?1049h'+$esc+'[2J'+$esc+'[HPOPUP-ALT'+$esc+'[?25l')
    [SelectionUi]::Button($ph,0x200,24,12);Start-Sleep -Milliseconds 100
    Check 'cancel: screen crossing releases popup capture on the next move' ([SelectionUi]::Capture($ph)-eq [IntPtr]::Zero)
    [SelectionUi]::Button($ph,0x202,24,12);Start-Sleep -Milliseconds 100
    Check 'cancel: popup capture remains released after button-up' ([SelectionUi]::Capture($ph)-eq [IntPtr]::Zero)
    $p0=Selection-Capture $ph 'popup-alt-before' 0 0 240 80
    [SelectionUi]::Wheel($ph,80,40,10);$p1=Selection-Capture $ph 'popup-alt-after' 0 0 240 80
    Check 'THE PIN: popup wheel is pinned on its alt screen' ((Selection-PixelDiff $p0 $p1)-eq 0)
    $null=Selection-Rpc 'session.overlay' @{action='close'}

    foreach($kind in @('quick','scratch')){
        $verb=if($kind-eq 'quick'){'quick'}else{'session.scratch'}
        $null=Selection-Rpc $verb @{op='on'}
        $ph=[IntPtr]::Zero
        for($i=0;$i-lt 50 -and $ph-eq [IntPtr]::Zero;$i++){Start-Sleep -Milliseconds 200;$ph=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')}
        if($ph-eq [IntPtr]::Zero){throw "$kind popup did not open"}
        Start-Sleep -Seconds 2
        [void][SelectionUi]::PostMessageW($ph,7,[IntPtr]::Zero,[IntPtr]::Zero);Start-Sleep -Milliseconds 200
        Write-Screen ($esc+'[2J'+$esc+'[H'+$kind.ToUpper()+'-SELECTION'+$esc+'[?25l')
        Set-Marker;$null=Selection-Rpc 'selection.all'
        Check "$kind popup: all selects its own text without copying" ((Selected)-match ($kind.ToUpper()+'-SELECTION') -and (Clip)-eq 'P7-CLIPBOARD-SENTINEL')
        $null=Selection-Rpc 'selection.clear'
        [LiteUi]::Drag($ph,0,[int]($g.Ch/2),($g.Cw*5),[int]($g.Ch/2))
        $copied=Clip;$selected=Selected
        Check "$kind popup: release copies its mouse selection" ($selected-eq $kind.ToUpper().Substring(0,5) -and $copied-eq $selected) "clipboard=<$copied>; selection=<$selected>"
        $null=Selection-Rpc $verb @{op='off'};Start-Sleep -Milliseconds 400
    }

    # Rebind/clear uses a new owned launch, never the app's asynchronous restart command.
    Stop-SelectionSandbox
    $reg=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($regPath);$reg.SetValue('Key_MarkMode',0,[Microsoft.Win32.RegistryValueKind]::DWord);$reg.SetValue('Key_SelectAll',0,[Microsoft.Win32.RegistryValueKind]::DWord);$reg.Dispose()
    Start-SelectionSandbox $Exe $profile;$h=$script:selectionHwnd
    [LiteUi]::Chord($h,[int][char]'M',$true)
    Check 'bindings: explicit zero disables the seeded mark chord' ([SelectionUi]::Status($h,2)-notmatch 'MARK')
    [LiteUi]::Chord($h,[int][char]'A',$true)
    Check 'bindings: explicit zero disables the seeded Select All chord' ((Selected)-eq '')
    Stop-SelectionSandbox
    $reg=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($regPath);$reg.SetValue('Key_MarkMode',(0x300+[int][char]'K'),[Microsoft.Win32.RegistryValueKind]::DWord);$reg.SetValue('Key_SelectAll',(0x300+[int][char]'L'),[Microsoft.Win32.RegistryValueKind]::DWord);$reg.Dispose()
    Start-SelectionSandbox $Exe $profile;$h=$script:selectionHwnd
    [LiteUi]::Chord($h,[int][char]'K',$true)
    Check 'bindings: rebound mark chord enters the mode' ([SelectionUi]::Status($h,2)-match 'MARK')
    [LiteUi]::Chord($h,[int][char]'K',$true)
    Check 'bindings: rebound mark chord also toggles it off' ([SelectionUi]::Status($h,2)-notmatch 'MARK')
    Write-Screen ($esc+'[2J'+$esc+'[HSELECT-ALL-REBOUND');Set-Marker;[LiteUi]::Chord($h,[int][char]'L',$true)
    Check 'bindings: rebound Select All highlights without copying' ((Selected)-match 'SELECT-ALL-REBOUND' -and (Clip)-eq 'P7-CLIPBOARD-SENTINEL')
}catch{if($skipReason){"SKIP selection-ui: $skipReason";if($Strict){$script:failures++}}else{$script:failures++;"FAIL selection UI aborted: $($_.Exception.Message)"}}
finally{
    $cleanupOk=Invoke-SelectionCleanup { Stop-SelectionSandbox } {
        if($geoSaved){
            $reg=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($regPath)
            try {
            foreach($name in $regBefore.Keys){$saved=$regBefore[$name];if($saved.Exists){$reg.SetValue($name,$saved.Value,[Microsoft.Win32.RegistryValueKind]$saved.Kind)}else{$reg.DeleteValue($name,$false)}}
            foreach($name in $regBefore.Keys){$saved=$regBefore[$name];if($saved.Exists){if([string]$reg.GetValue($name)-ne [string]$saved.Value){throw "Registry restore failed: $name"}}elseif($reg.GetValueNames()-contains $name){throw "Registry deletion failed: $name"}}
            } finally {$reg.Dispose()}
        }
    } {
        if($null -ne $clipboard){Restore-SelectionClipboard $clipboard}
    }
    if($cleanupOk){'Cleanup verified: owned windows/hosts exited; captured clipboard formats and touched registry values restored; no queued launches.'}
    if($ownLease -and $cleanupOk){
        $raw=& python $hub release --owner $lease.owner --token $lease.token --cleanup-confirmed
        $raw|Set-Content "$script:selectionArtifact/release.json";$raw
        if($LASTEXITCODE -ne 0){$cleanupOk=$false}
    }
    "selection-ui: $script:checks checks, $script:failures failed; cleanup complete: $cleanupOk; artifacts $script:selectionArtifact"
    Stop-Transcript|Out-Null
}
if(-not $cleanupOk){exit 2};if($script:failures){exit 1};exit 0
