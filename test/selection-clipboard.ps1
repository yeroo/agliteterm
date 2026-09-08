# Per-action ownership ledger. Callbacks permit fault testing without the desktop clipboard.
. "$PSScriptRoot/clipboard-guard.ps1"
function New-SelectionClipboardLedger($Snapshot) {
    if($null -eq $Snapshot -or $Snapshot.Unsupported){throw 'Clipboard cannot be captured faithfully; no fixture writes permitted'}
    @{Before=$Snapshot;Sequence=$Snapshot.Sequence;Receipt=$null;Pending=$false;Touched=$false}
}
function Assert-SelectionClipboardGeneration($Ledger) {
    if($Ledger.Pending){throw 'Previous clipboard action is unproven; recovery required'}
    if([Agwinterm.Win32ControlTest.ClipboardGuard]::Api.Sequence() -ne $Ledger.Sequence){throw 'Clipboard changed outside the proven fixture action; newer contents preserved'}
}
function Read-SelectionClipboardText($Ledger) {
    Assert-SelectionClipboardGeneration $Ledger
    $snapshot=[Agwinterm.Win32ControlTest.ClipboardGuard]::Take()
    if($snapshot.Unsupported -or $snapshot.Sequence -ne $Ledger.Sequence){throw 'Clipboard changed or became unreadable during assertion; no contents disclosed'}
    $index=[Array]::IndexOf($snapshot.Formats,[uint32]13)
    if($index -lt 0){return ''}
    return [Text.Encoding]::Unicode.GetString($snapshot.Data[$index]).TrimEnd([char]0)
}
function Write-SelectionClipboardMarker($Ledger,[string]$Text) {
    Assert-SelectionClipboardGeneration $Ledger
    $now=[Agwinterm.Win32ControlTest.ClipboardGuard]::Take()
    if($now.Unsupported -or $now.Sequence -ne $Ledger.Sequence){throw 'Clipboard changed or became unreadable before marker write'}
    $Ledger.Pending=$true
    $receipt=[Agwinterm.Win32ControlTest.ClipboardGuard]::WriteSentinel($Text,$now)
    if($receipt.State -eq 'written'){
        $Ledger.Receipt=$receipt;$Ledger.Sequence=$receipt.Sequence;$Ledger.Touched=$true;$Ledger.Pending=$false
    }elseif($receipt.State -eq 'put back'){
        # A failed marker write restored the immediately preceding snapshot with proof.
        $Ledger.Receipt=[Agwinterm.Win32ControlTest.ClipboardWrite]::new()
        $Ledger.Receipt.State='written';$Ledger.Receipt.Sequence=$receipt.Sequence
        $Ledger.Sequence=$receipt.Sequence;$Ledger.Touched=$true;$Ledger.Pending=$false
        throw 'Marker write failed; prior contents were put back with proof'
    }elseif($receipt.State -in @('failed','unopened')){
        # Both states prove this action made no write. Keep the prior ownership receipt;
        # cleanup still checks its generation if an earlier action touched the clipboard.
        $Ledger.Pending=$false
        throw "Marker write failed without mutation ($($receipt.State))"
    }else{throw "Marker write unproven ($($receipt.State)); retain recovery snapshot"}
}
function Invoke-SelectionClipboardCopy($Ledger,[scriptblock]$Action,[scriptblock]$Expected,[Func[bool]]$Owner) {
    Assert-SelectionClipboardGeneration $Ledger
    $before=$Ledger.Sequence;$Ledger.Pending=$true
    & $Action | Out-Null
    # Expected data comes from the fixture's selection, never from the system clipboard.
    $text=[string](& $Expected)
    $receipt=[Agwinterm.Win32ControlTest.ClipboardGuard]::ConfirmCopy($text,$before,$Owner)
    if($receipt.State -eq 'written'){
        $Ledger.Receipt=$receipt;$Ledger.Sequence=$receipt.Sequence;$Ledger.Touched=$true;$Ledger.Pending=$false
        # Preserve the receipt for teardown even when the application's write was a defect.
        if($text.Length -eq 0){throw 'Empty/cancelled selection unexpectedly wrote the clipboard'}
    }elseif($receipt.State -eq 'unchanged' -and $text.Length -eq 0){
        # Empty/cancelled selection is explicitly a no-copy action, not a new receipt.
        $Ledger.Pending=$false
    }else{throw "App copy unproven ($($receipt.State)); retain recovery snapshot"}
}
function Restore-SelectionClipboardLedger($Ledger) {
    if($Ledger.Pending){throw 'Previous clipboard action is unproven; recovery required'}
    # A proven no-write run has no clipboard ownership to restore, even if someone copied.
    if(-not $Ledger.Touched){return}
    Assert-SelectionClipboardGeneration $Ledger
    $result=[Agwinterm.Win32ControlTest.ClipboardGuard]::RestoreExact($Ledger.Before,$Ledger.Receipt)
    if($result.State -ne 'restored'){throw "Clipboard restore unproven ($($result.State)); retain recovery snapshot"}
    $Ledger.Sequence=$result.Sequence;$Ledger.Touched=$false;$Ledger.Receipt=$null
}
