# Only inside the selection fixture's token, clipboard receipt and registry ownership boundary.
if(-not $clipboard -or -not $script:selectionProc){throw 'Focus checks require guarded selection fixture'}
'-- Focus status publication (#39) --'
function FocusStatus { [SelectionUi]::Status($script:selectionHwnd,2) }
function FocusWait([scriptblock]$condition){for($n=0;$n-lt 50;$n++){if(& $condition){return $true};Start-Sleep -Milliseconds 50};return $false}
$focusOwner=[string](Selection-Rpc 'session.new' @{name='focus-status-owner'})
try {
    Selection-Rpc 'session.select' @{} $focusOwner|Out-Null
    if(-not (FocusWait {(P9Node $focusOwner).active})){throw 'Focus owner did not become active'}
    $fullGeometry=Selection-Geometry
    $focusSplit=[string](Selection-Rpc 'session.split' @{op='on';axis='horizontal'} $focusOwner)
    Selection-Rpc 'session.resize' @{ratio=0.3}|Out-Null
    Selection-Rpc 'session.focus' @{dir='top'}|Out-Null
    if(-not (FocusWait {(P9Node $focusOwner).focusedPane-eq 0})){throw 'Top focus not ready'}
    Start-Sleep -Milliseconds 300
    $topStatus=FocusStatus
    Selection-Rpc 'session.focus' @{dir='bottom'}|Out-Null
    if(-not (FocusWait {(P9Node $focusOwner).focusedPane-eq 1 -and (FocusStatus)-ne $topStatus})){throw 'Unequal pane status fixture not ready'}
    $bottomStatus=FocusStatus
    Check 'uneven horizontal panes expose distinct size labels' ($topStatus-match '^\d+\s*×\s*\d+' -and $bottomStatus-match '^\d+\s*×\s*\d+' -and $topStatus-ne $bottomStatus)
    [LiteUi]::Chord($script:selectionHwnd,[int][char]'L',$true)
    Check 'keyboard top focus publishes its own size' (FocusWait {(P9Node $focusOwner).focusedPane-eq 0 -and (FocusStatus)-eq $topStatus})
    [LiteUi]::Chord($script:selectionHwnd,[int][char]'R',$true)
    Check 'keyboard bottom focus publishes its own size' (FocusWait {(P9Node $focusOwner).focusedPane-eq 1 -and (FocusStatus)-eq $bottomStatus})
    $x=$fullGeometry.Left+20;$topY=$fullGeometry.Top+10;$bottomY=$fullGeometry.Bottom-10
    foreach($point in @(@($topY,0,$topStatus),@($bottomY,1,$bottomStatus))){
        Selection-Button @($script:selectionHwnd,0x201,$x,$point[0])
        Selection-Button @($script:selectionHwnd,0x202,$x,$point[0])
        Check "mouse focus slot $($point[1]) publishes its size" (FocusWait {(P9Node $focusOwner).focusedPane-eq $point[1] -and (FocusStatus)-eq $point[2]})
    }
    Selection-Rpc 'quick' @{op='on'}|Out-Null
    if(-not (FocusWait {[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')-ne [IntPtr]::Zero})){throw 'Quick focus fixture did not open'}
    $popup=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')
    [void][LiteUi]::PostMessageW($popup,7,[IntPtr]::Zero,[IntPtr]::Zero)
    Check 'quick focus changes status away from underlying small pane' (FocusWait {(FocusStatus)-ne $bottomStatus})
    Selection-Rpc 'quick' @{op='off'}|Out-Null
    Check 'hiding quick restores underlying focused pane status' (FocusWait {[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')-eq [IntPtr]::Zero -and (FocusStatus)-eq $bottomStatus})
}finally{
    Selection-Rpc 'quick' @{op='off'} -AllowError|Out-Null
    Selection-Rpc 'session.close' @{} $focusOwner -AllowError|Out-Null
}
