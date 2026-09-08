# Keyboard/mouse selection parity. Run locally under the shared hub token; CI is an isolated host.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict,
      [string]$TokenOwner=$env:AGLITETERM_TEST_OWNER,[switch]$DrivingOnly)
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
        if([string]::IsNullOrWhiteSpace($TokenOwner)){Skip-Selection 'set -TokenOwner or AGLITETERM_TEST_OWNER to the actual runner before acquiring a suite token'}
        $run=Split-Path $script:selectionArtifact -Leaf
        $raw=& python $hub acquire --owner $TokenOwner --run $run --worktree (Split-Path $PSScriptRoot -Parent) --holder-pid $PID --purpose 'P7 selection UI verification'
        $lease=$raw|ConvertFrom-Json
        if($LASTEXITCODE -ne 0 -or -not $lease.ok){Skip-Selection "suite token unavailable: $raw"}
        $ownLease=$true
    }
}elseif($env:CI -ne 'true'){Skip-Selection 'shared suite-token helper absent; no local interactive tests ran'}
$script:selectionPipe='p7sel'+[guid]::NewGuid().ToString('N').Substring(0,10)
$script:selectionProc=$null;$script:selectionHosts=@();$script:selectionLaunched=$false;$script:checks=0;$script:failures=0
$clipboard=$null;$geoSaved=$false;$script:selectionRegistry=@{};$cleanupOk=$true;$regPath='Software\agliteterm';$skipReason=$null
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
    $script:selectionRegistry=New-RegistryGuard $names {param($n) Read-RegistryGuardValue $reg $n}
    if($reg){$reg.Dispose()};$geoSaved=$true
    $script:selectionRegistry|ConvertTo-Json -Depth 8|Set-Content "$script:selectionArtifact/registry-before.json"
    # Deterministic defaults, even if the user's dialog previously cleared/rebound these actions.
    foreach($name in 'Key_MarkMode','Key_SelectAll'){Set-SelectionRegistry $name @{Exists=$false;Kind=0;Value=$null}}
    $profile=Join-Path $script:selectionArtifact profile;New-Item -ItemType Directory $profile|Out-Null
    Start-SelectionSandbox $Exe $profile
    $h=$script:selectionHwnd;$g=Selection-Geometry
    "Grid geometry: $($g|ConvertTo-Json -Compress)"
    $esc=[string][char]27
    function Write-Screen([string]$text,[string]$target='active'){$null=Selection-Rpc 'session.write' @{text=$text} $target;Start-Sleep -Milliseconds 250}
    function Selected([string]$target='active'){[string](Selection-Rpc 'session.copy' @{} $target)}
    function Set-Marker { $script:selectionMarker='P7-'+[guid]::NewGuid().ToString('N');Write-SelectionClipboardMarker $clipboard $script:selectionMarker }
    function Copy-Action([scriptblock]$Action) {
        Invoke-SelectionClipboardCopy $clipboard $Action { Selected } ([Func[bool]]{
            $script:selectionProc -and -not $script:selectionProc.HasExited -and
                [SelectionUi]::ClipboardOwnedBy($script:selectionProc.Id)
        })
    }
    function Selection-Button([object[]]$EventArgs) {
        $hw,$message,$cx,$cy=$EventArgs
        if($message -eq 0x202){Copy-Action { [SelectionUi]::Button($hw,$message,$cx,$cy) }}
        else{[SelectionUi]::Button($hw,$message,$cx,$cy)}
    }
    function Selection-Drag([object[]]$EventArgs) {
        $hw,$x1,$y1,$x2,$y2,$hold=$EventArgs
        Selection-Button @($hw,0x201,$x1,$y1)
        for($i=1;$i -le 8;$i++){
            Selection-Button @($hw,0x200,([int]($x1+($x2-$x1)*$i/8)),([int]($y1+($y2-$y1)*$i/8)))
            Start-Sleep -Milliseconds 40
        }
        for($i=0;$i -lt [int]$hold;$i+=100){Selection-Button @($hw,0x200,$x2,$y2);Start-Sleep -Milliseconds 100}
        Selection-Button @($hw,0x202,$x2,$y2)
        Start-Sleep -Milliseconds 250
    }
    function Clip {
        Read-SelectionClipboardText $clipboard
    }
    function Main-Screen { Write-Screen ($esc+'[?1049l'+$esc+'[?1000l'+$esc+'[?1002l'+$esc+'[?1003l'+$esc+'[2J'+$esc+'[H'+$esc+'[?25l') }
    function Seed-Main { Main-Screen;Write-Screen (((1..200|ForEach-Object{'MARKER-{0:D3} word two'-f $_})-join "`r`n")+"`r`n") }
    function Seed-Alt {
        Write-Screen ($esc+'[?1049h'+$esc+'[2J'+$esc+'[H'+$esc+'[?25l')
        for($row=0;$row -lt $g.Rows;$row++){Write-Screen ($esc+"[$($row+1);1HALT-$row word two")}
        Write-Screen ($esc+'[6;3H') # known caret; surface.cursor exposes only a column
    }
    function Shot([string]$name){Selection-Capture $h $name $g.Left $g.Top ([math]::Min(350,$g.Right-$g.Left)) ([math]::Min(200,$g.Bottom-$g.Top))}
    if(-not $DrivingOnly){
    Seed-Main
    $before=Shot 'wheel-before';[SelectionUi]::Wheel($h,($g.Left+100),($g.Top+60),3);$after=Shot 'wheel-after'
    Check 'wheel: posted main-screen wheel changes the viewport' ((Selection-PixelDiff $before $after)-gt 100)
    [SelectionUi]::Wheel($h,($g.Left+100),($g.Top+60),-3);$back=Shot 'wheel-back'
    Check 'wheel: reversing notches restores the viewport' ((Selection-PixelDiff $before $back)-eq 0)
    [SelectionUi]::Wheel($h,10,100,3);$side=Shot 'wheel-sidebar'
    Check 'wheel: sidebar changes no pane' ((Selection-PixelDiff $back $side)-eq 0)
    Set-Marker;[LiteUi]::Chord($h,[int][char]'A',$true)
    Check 'Select All: seeded chord includes history and live grid' ((Selected)-match 'MARKER-001' -and (Selected)-match 'MARKER-200')
    Check 'Select All: highlight only, no clipboard write' ((Clip)-eq $script:selectionMarker)
    $null=Selection-Rpc 'selection.clear'

    # Release semantics: double-click does not copy until the corresponding button-up.
    Main-Screen;Write-Screen ($esc+'[HMARKER-7 word two'+$esc+'[6;3H')
    $x=$g.Left+2*$g.Cw;$y=$g.Top+[int]($g.Ch/2)
    Set-Marker;Selection-Button -EventArgs @($h,0x203,$x,$y);Selection-Button -EventArgs @($h,0x200,($x+1),$y);Start-Sleep -Milliseconds 200
    Check 'double-click: word selection uses non-blank cells' ((Selected)-eq 'MARKER-7') (Selected)
    Check 'double-click: clipboard stays unchanged while button is held' ((Clip)-eq $script:selectionMarker)
    Selection-Button -EventArgs @($h,0x202,$x,$y);Start-Sleep -Milliseconds 200
    Check 'release copies: selected word matches clipboard' ((Clip)-eq 'MARKER-7') (Clip)
    # Each synchronous release gets its own receipt before the next press. Keep intervening
    # work minimal; the assertion below also detects exceeding the double-click interval.
    Selection-Button -EventArgs @($h,0x203,$x,$y);Selection-Button -EventArgs @($h,0x202,$x,$y)
    Selection-Button -EventArgs @($h,0x201,$x,$y);Selection-Button -EventArgs @($h,0x200,($x+1),$y);Selection-Button -EventArgs @($h,0x202,$x,$y);Start-Sleep -Milliseconds 200
    Check 'triple-click: selects and copies the whole visible line' ((Selected)-eq 'MARKER-7 word two' -and (Clip)-eq (Selected)) (Selected)
    Set-Marker;Selection-Button -EventArgs @($h,0x203,($g.Left+30*$g.Cw),$y);Selection-Button -EventArgs @($h,0x202,($g.Left+30*$g.Cw),$y);Start-Sleep -Milliseconds 200
    Check 'double-click blank: no selection and clipboard untouched' ((Selected)-eq '' -and (Clip)-eq $script:selectionMarker)
    Selection-Button -EventArgs @($h,0x203,($g.Left+1),$y);Selection-Button -EventArgs @($h,0x200,($g.Left+2),$y);Selection-Button -EventArgs @($h,0x202,($g.Left+2),$y);Start-Sleep -Milliseconds 200
    Check 'double-click: first-cell jitter preserves the whole word on release' ((Selected)-eq 'MARKER-7' -and (Clip)-eq 'MARKER-7') (Selected)

    $blankX=$g.Left+70*$g.Cw
    Selection-Button -EventArgs @($h,0x203,$blankX,$y);Selection-Button -EventArgs @($h,0x202,$blankX,$y)
    Selection-Button -EventArgs @($h,0x201,$blankX,$y);Selection-Button -EventArgs @($h,0x202,$blankX,$y);Start-Sleep -Milliseconds 200
    Check 'triple-click: trailing blank selects and copies the whole line' ((Selected)-eq 'MARKER-7 word two' -and (Clip)-eq (Selected))

    foreach($wide in @([string][char]0x4E2D,[char]::ConvertFromUtf32(0x1F600))){
        Main-Screen;Write-Screen ($esc+'[H'+$wide+' Z'+$esc+'[H')
        Selection-Button -EventArgs @($h,0x203,($g.Left+1),$y);Selection-Button -EventArgs @($h,0x202,($g.Left+1),$y);Start-Sleep -Milliseconds 200
        $leadShot=Shot ('wide-lead-'+[int]$wide[0])
        Check 'wide word: leading cell copies the whole glyph' ((Selected)-eq $wide -and (Clip)-eq $wide)
        Selection-Button -EventArgs @($h,0x203,($g.Left+$g.Cw+1),$y);Selection-Button -EventArgs @($h,0x202,($g.Left+$g.Cw+1),$y);Start-Sleep -Milliseconds 200
        $trailShot=Shot ('wide-trail-'+[int]$wide[0])
        Check 'wide word: continuation has the same text and highlight as the lead' ((Selected)-eq $wide -and (Selection-PixelDiff $leadShot $trailShot)-eq 0)
        [LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Key($h,0x27,1)
        $markShot=Shot ('wide-mark-'+[int]$wide[0])
        Check 'wide mark: one Right selects a whole glyph with the word highlight' ((Selected)-eq $wide -and (Selection-PixelDiff $leadShot $markShot)-eq 0)
        [LiteUi]::Key($h,0x25,1)
        Check 'wide mark: one Left returns to the lead without a half-cell selection' ((Selected)-eq '')
        [LiteUi]::Key($h,0x1B,1)
        Write-Screen ($esc+'[1;2H');[LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Key($h,0x27,1)
        Check 'wide mark: caret on a continuation anchors at the lead' ((Selected)-eq $wide)
        [LiteUi]::Key($h,0x1B,1)
    }

    # The timer cancellation door: enter alt while holding an out-of-bounds ordinary drag.
    Selection-Button -EventArgs @($h,0x201,($g.Left+50),($g.Top+3*$g.Ch));Selection-Button -EventArgs @($h,0x200,($g.Left+50),($g.Top-20));Start-Sleep -Milliseconds 100
    Check 'cancel setup: frame drag owns capture' ([SelectionUi]::Capture($h)-eq $h)
    Write-Screen ($esc+'[?1049h'+$esc+'[2J'+$esc+'[HCANCEL-ALT')
    Check 'cancel: screen crossing releases frame capture before button-up' ([SelectionUi]::Capture($h)-eq [IntPtr]::Zero)
    Selection-Button -EventArgs @($h,0x202,($g.Left+50),($g.Top-20));Start-Sleep -Milliseconds 100
    Check 'cancel: frame capture remains released after button-up' ([SelectionUi]::Capture($h)-eq [IntPtr]::Zero)
    Main-Screen;Write-Screen ($esc+'[HEVICT-BEGIN')
    Selection-Button -EventArgs @($h,0x201,($g.Left+8),$y);Selection-Button -EventArgs @($h,0x200,($g.Left+40),($y+$g.Ch));Start-Sleep -Milliseconds 100
    Check 'cancel setup: eviction fixture owns capture' ([SelectionUi]::Capture($h)-eq $h)
    # Eviction is accounted by the PTY reader, not display-only session.write injection.
    # Emit through the fixture shell so this exercises the production bookkeeping path.
    $null=Selection-Rpc 'session.type' @{text='[Console]::Write(("E"+[char]13+[char]10)*6000)'}
    [LiteUi]::Key($h,0x0D,1)
    for($i=0;$i-lt 50;$i++){
        if([string](Selection-Rpc 'session.text')-notmatch 'EVICT-BEGIN'){break}
        Start-Sleep -Milliseconds 100
    }
    Selection-Button -EventArgs @($h,0x200,($g.Left+48),($y+$g.Ch));Start-Sleep -Milliseconds 100
    Check 'cancel: eviction drops selection and releases capture on the next move' ((Selected)-eq '' -and [SelectionUi]::Capture($h)-eq [IntPtr]::Zero)
    Selection-Button -EventArgs @($h,0x202,($g.Left+48),($y+$g.Ch))

    # Caret is deliberately placed on row 0, col 0: Enter after five Right moves copies ABCDE.
    Main-Screen;Write-Screen ($esc+'[HABCDEFGHIJKLMN'+$esc+'[H')
    Set-Marker;[LiteUi]::Chord($h,[int][char]'M',$true)
    Check 'mark: seeded chord displays MARK in status part 2' ([SelectionUi]::Status($h,2)-match 'MARK$') ([SelectionUi]::Status($h,2))
    [LiteUi]::Key($h,0x27,5)
    Check 'mark: Right extends the exclusive end from the known caret' ((Selected)-eq 'ABCDE') (Selected)
    Copy-Action { [LiteUi]::Key($h,0x0D,1) }
    Check 'mark: Enter copies, keeps highlight, and exits' ((Clip)-eq 'ABCDE' -and (Selected)-eq 'ABCDE' -and [SelectionUi]::Status($h,2)-notmatch 'MARK')
    Set-Marker;[LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Key($h,0x27,2);[LiteUi]::Key($h,0x1B,1)
    Check 'mark: Escape clears without copying' ((Selected)-eq '' -and (Clip)-eq $script:selectionMarker -and [SelectionUi]::Status($h,2)-notmatch 'MARK')
    [LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Chord($h,[int][char]'M',$true)
    Check 'mark: its configured chord toggles off and clears' ((Selected)-eq '' -and [SelectionUi]::Status($h,2)-notmatch 'MARK')
    [LiteUi]::Chord($h,[int][char]'M',$true);$text=[string](Selection-Rpc 'session.text');[LiteUi]::Key($h,[int][char]'X',1)
    Check 'mark: other keys do not reach the shell' ([string](Selection-Rpc 'session.text')-eq $text)
    [LiteUi]::Key($h,0x1B,1)

    Write-Screen ($esc+'[H');[LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Key($h,0x23,1)
    Check 'mark: End selects through the exclusive right edge' ((Selected)-eq 'ABCDEFGHIJKLMN') (Selected)
    [LiteUi]::Key($h,0x24,1)
    Check 'mark: Home returns the focus end to column zero' ((Selected)-eq '')
    [LiteUi]::Key($h,0x27,3);Copy-Action { [LiteUi]::Chord($h,[int][char]'C',$false) }
    $copied=Clip;$selected=Selected;$status=[SelectionUi]::Status($h,2)
    Check 'mark: Ctrl+C copies and exits while preserving the highlight' ($copied-eq 'ABC' -and $selected-eq 'ABC' -and $status-notmatch 'MARK') "clipboard=<$copied>; selection=<$selected>; status=<$status>"
    $null=Selection-Rpc 'selection.clear'

    Seed-Main;$before=Shot 'drag-before'
    Selection-Drag -EventArgs @($h,($g.Left+10*$g.Cw),($g.Top+5*$g.Ch),($g.Left+2*$g.Cw),($g.Top-20),1000)
    $dragged=Selected;$null=Selection-Rpc 'selection.clear'
    $after=Shot 'drag-after'
    Check 'drag: holding above the edge scrolls the viewport' ((Selection-PixelDiff $before $after)-gt 100)
    Check 'release copies: autoscrolled selection matches clipboard' ($dragged-match 'MARKER-' -and (Clip)-eq $dragged)
    $before=Shot 'drag-down-before'
    Selection-Drag -EventArgs @($h,($g.Left+2*$g.Cw),($g.Top+5*$g.Ch),($g.Left+10*$g.Cw),($g.Bottom+20),1000)
    $dragged=Selected;$null=Selection-Rpc 'selection.clear';$after=Shot 'drag-down-after'
    Check 'drag: holding below the edge scrolls back toward the live grid' ((Selection-PixelDiff $before $after)-gt 100)
    Check 'release copies: downward autoscroll copies exactly the range' ($dragged-match 'MARKER-' -and (Clip)-eq $dragged)
    Seed-Alt;$before=Shot 'alt-before';[SelectionUi]::Wheel($h,($g.Left+100),($g.Top+60),10);$after=Shot 'alt-wheel'
    Check 'THE PIN: alt-screen wheel changes no visible cells' ((Selection-PixelDiff $before $after)-eq 0)
    Set-Marker;[LiteUi]::Chord($h,[int][char]'A',$true)
    Check 'THE PIN: Select All takes alt rows and no main history' ((Selected)-match '^ALT-0' -and (Selected)-notmatch 'MARKER-')
    Check 'THE PIN: Select All still does not copy' ((Clip)-eq $script:selectionMarker)
    $null=Selection-Rpc 'selection.clear'
    Selection-Drag -EventArgs @($h,($g.Left+10*$g.Cw),($g.Top+5*$g.Ch),$g.Left,($g.Top-20),1000)
    Check 'THE PIN: drag above alt stops at ALT-0, never main history' ((Selected)-match '^ALT-0' -and (Selected)-notmatch 'MARKER-') (Selected)
    Write-Screen ($esc+'[6;1H');[LiteUi]::Chord($h,[int][char]'M',$true);[LiteUi]::Key($h,0x26,40)
    Check 'THE PIN: mark Up stops at the first alt row' ((Selected)-match '^ALT-0' -and (Selected)-notmatch 'MARKER-') (Selected)
    [LiteUi]::Key($h,0x1B,1)
    Selection-Drag -EventArgs @($h,$g.Left,($g.Top+5*$g.Ch),($g.Left+20*$g.Cw),($g.Bottom+20),1000)
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
    Selection-Drag -EventArgs @($ph,0,[int]($g.Ch/2),($g.Cw*5),[int]($g.Ch/2))
    Check 'popup: drag selects and release copies its cells' ((Selected)-eq 'POPUP' -and (Clip)-eq 'POPUP') (Selected)
    Write-Screen ($esc+'[H');[LiteUi]::Chord($ph,[int][char]'M',$true);[LiteUi]::Key($ph,0x27,5)
    Check 'popup: mark mode extends at its own caret' ((Selected)-eq 'POPUP' -and [SelectionUi]::Status($h,2)-match 'MARK') (Selected)
    Copy-Action { [LiteUi]::Chord($ph,[int][char]'C',$false) }
    Check 'popup: mark Ctrl+C copies and exits' ((Clip)-eq 'POPUP' -and [SelectionUi]::Status($h,2)-notmatch 'MARK')
    Selection-Button -EventArgs @($ph,0x201,8,12);Selection-Button -EventArgs @($ph,0x200,16,12);Start-Sleep -Milliseconds 100
    Check 'cancel setup: popup drag owns capture' ([SelectionUi]::Capture($ph)-eq $ph)
    Write-Screen ($esc+'[?1049h'+$esc+'[2J'+$esc+'[HPOPUP-ALT'+$esc+'[?25l')
    Selection-Button -EventArgs @($ph,0x200,24,12);Start-Sleep -Milliseconds 100
    Check 'cancel: screen crossing releases popup capture on the next move' ([SelectionUi]::Capture($ph)-eq [IntPtr]::Zero)
    Selection-Button -EventArgs @($ph,0x202,24,12);Start-Sleep -Milliseconds 100
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
        Check "$kind popup: all selects its own text without copying" ((Selected)-match ($kind.ToUpper()+'-SELECTION') -and (Clip)-eq $script:selectionMarker)
        $null=Selection-Rpc 'selection.clear'
        Selection-Drag -EventArgs @($ph,0,[int]($g.Ch/2),($g.Cw*5),[int]($g.Ch/2))
        $copied=Clip;$selected=Selected
        Check "$kind popup: release copies its mouse selection" ($selected-eq $kind.ToUpper().Substring(0,5) -and $copied-eq $selected) "clipboard=<$copied>; selection=<$selected>"
        $null=Selection-Rpc $verb @{op='off'};Start-Sleep -Milliseconds 400
    }

    # Rebind/clear uses a new owned launch, never the app's asynchronous restart command.
    Stop-SelectionSandbox
    foreach($name in 'Key_MarkMode','Key_SelectAll'){Set-SelectionRegistry $name @{Exists=$true;Kind=4;Value=0}}
    Start-SelectionSandbox $Exe $profile;$h=$script:selectionHwnd
    [LiteUi]::Chord($h,[int][char]'M',$true)
    Check 'bindings: explicit zero disables the seeded mark chord' ([SelectionUi]::Status($h,2)-notmatch 'MARK')
    [LiteUi]::Chord($h,[int][char]'A',$true)
    Check 'bindings: explicit zero disables the seeded Select All chord' ((Selected)-eq '')
    Stop-SelectionSandbox
    Set-SelectionRegistry 'Key_MarkMode' @{Exists=$true;Kind=4;Value=(0x300+[int][char]'K')}
    Set-SelectionRegistry 'Key_SelectAll' @{Exists=$true;Kind=4;Value=(0x300+[int][char]'L')}
    Start-SelectionSandbox $Exe $profile;$h=$script:selectionHwnd
    [LiteUi]::Chord($h,[int][char]'K',$true)
    Check 'bindings: rebound mark chord enters the mode' ([SelectionUi]::Status($h,2)-match 'MARK')
    [LiteUi]::Chord($h,[int][char]'K',$true)
    Check 'bindings: rebound mark chord also toggles it off' ([SelectionUi]::Status($h,2)-notmatch 'MARK')
    Write-Screen ($esc+'[2J'+$esc+'[HSELECT-ALL-REBOUND');Set-Marker;[LiteUi]::Chord($h,[int][char]'L',$true)
    Check 'bindings: rebound Select All highlights without copying' ((Selected)-match 'SELECT-ALL-REBOUND' -and (Clip)-eq $script:selectionMarker)
    }
    if(Test-Path "$PSScriptRoot/driving-ui-cases.ps1"){. "$PSScriptRoot/driving-ui-cases.ps1"}
}catch{if($skipReason){"SKIP selection-ui: $skipReason";if($Strict){$script:failures++}}else{$script:failures++;"FAIL selection UI aborted: $($_.Exception.Message)"}}
finally{
    $cleanupOk=Invoke-SelectionCleanup { Stop-SelectionSandbox } {
        if($geoSaved){
            $reg=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($regPath)
            try {
            Restore-RegistryGuard $script:selectionRegistry `
                {param($n) Read-RegistryGuardValue $reg $n} `
                {param($n,$v) Write-RegistryGuardValue $reg $n $v}
            } finally {$reg.Dispose()}
        }
    } {
        if($null -ne $clipboard){Restore-SelectionClipboard $clipboard}
    }
    if($cleanupOk){'Cleanup verified: owned windows/hosts exited; clipboard restored or proven untouched by fixture; touched registry values restored; no queued launches.'}
    if($ownLease -and $cleanupOk){
        $raw=& python $hub release --owner $lease.owner --token $lease.token --cleanup-confirmed
        $raw|Set-Content "$script:selectionArtifact/release.json";$raw
        if($LASTEXITCODE -ne 0){$cleanupOk=$false}
    }
    "selection-ui: $script:checks checks, $script:failures failed; cleanup complete: $cleanupOk; artifacts $script:selectionArtifact"
    Stop-Transcript|Out-Null
}
if(-not $cleanupOk){exit 2};if($script:failures){exit 1};exit 0
