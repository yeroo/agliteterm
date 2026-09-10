# Actual Lite creation/close against its bundled host; supports legacy and ticket-capable hosts.
param([string]$Exe="$PSScriptRoot/../bin/agliteterm.exe",[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/suite-context.ps1"
Assert-LiteSuiteContext
. "$PSScriptRoot/owned-window.ps1"
Add-Type -Path "$PSScriptRoot/creation-host.cs"
$profile=Join-Path $env:LOCALAPPDATA ('creation-host-'+[guid]::NewGuid().ToString('N'))
$appDir=Join-Path $profile 'agliteterm';New-Item -ItemType Directory -Path $appDir|Out-Null
@{default='SafeCmd';profiles=@(@{name='SafeCmd';command='cmd.exe';args=@('/d','/q')})}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $appDir 'profiles.json')
$pipe=Get-LiteTestPipe 'creation-host';$hostPipe='agliteterm-test-'+$env:AGLITETERM_TEST_RUN+'-ptyhost'
$proc=$null;$child=$null;$failed=$false;$checks=0
function Check([bool]$ok,[string]$what){if(-not $ok){throw $what};$script:checks++}
try {
    $proc=Start-Process $Exe -ArgumentList @('--pipe','creation-host','--no-restore') -WindowStyle Hidden -PassThru -Environment @{LOCALAPPDATA=$profile}
    [void]$proc.SafeHandle;$null=Get-OwnedLiteWindow $proc -Show
    $tree=[LiteCreationHost]::Call($pipe,'tree','',$null)
    $baseline=@([LiteCreationHost]::List($hostPipe))
    Check ($baseline.Count-ge 1) 'Initial hosted pane missing'
    $revision=[LiteCreationHost]::Revision($hostPipe)
    if($env:AGLITETERM_TEST_REQUIRE_CREATION-eq '1'){Check ($revision-ge 1) 'New creation protocol was not exercised'}
    $id=[LiteCreationHost]::Call($pipe,'session.new','',@{command='cmd.exe /d /q';name='creation-oracle';'no-select'=$true}).GetString()
    $listed=@([LiteCreationHost]::List($hostPipe));$pane=@($listed|Where-Object Id -CEQ $id)
    Check ($listed.Count-eq $baseline.Count+1 -and $pane.Count-eq 1) 'Actual Lite create did not publish exactly one child'
    Check ($pane[0].Attached -and $pane[0].Pid-gt 0) 'Created child was not attached'
    if($revision-ge 1){Check ($pane[0].Ticket-cmatch '\A[0-9a-f]{32}\z') 'Lite create did not use a host-issued ticket'}
    $child=[Diagnostics.Process]::GetProcessById($pane[0].Pid);[void]$child.SafeHandle
    $null=[LiteCreationHost]::Call($pipe,'session.close',$id,$null)
    Check ($child.WaitForExit(10000)) 'Explicit Lite close did not terminate its exact original child'
    $after=@([LiteCreationHost]::List($hostPipe))
    Check ($after.Count-eq $baseline.Count -and @($after|Where-Object Id -CEQ $id).Count-eq 0) 'Close left its incarnation listed'
    foreach($original in $baseline){
        $remaining=@($after|Where-Object Id -CEQ $original.Id)
        Check ($remaining.Count-eq 1 -and $remaining[0].Pid-eq $original.Pid -and $remaining[0].Ticket-ceq $original.Ticket) 'Close replaced an unrelated child'
    }
    "creation-host: $checks checks passed; actual Lite create/attach/close, host revision $revision"
}catch{$failed=$true;"creation-host FAILED: $_"}
finally{
    if($child){$child.Dispose()}
    if($proc){if(-not $proc.HasExited){[void]$proc.CloseMainWindow()};if(-not $proc.WaitForExit(5000)){$proc.Kill();if(-not $proc.WaitForExit(10000)){throw 'Owned creation window did not exit'}};$proc.Dispose()}
}
if($failed){exit 1};exit 0
