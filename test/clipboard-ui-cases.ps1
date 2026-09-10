# Dot-sourced only after whole-format/DPAPI snapshot, registry guard, lease and owned launch.
if(-not $clipboard -or -not $script:selectionProc){throw 'Clipboard acceptance requires guarded fixture'}
'-- Guarded legacy clipboard and host actions --'
function ClipWait([scriptblock]$condition){for($n=0;$n-lt 100;$n++){if(& $condition){return $true};Start-Sleep -Milliseconds 100};return $false}
$clipIds=[Collections.Generic.List[string]]::new()
try {
    # No probe precedes Save-SelectionClipboard. A sentinel write itself has an exact receipt.
    Write-SelectionClipboardMarker $clipboard 'guarded-clipboard-probe'
    Check 'clipboard marker writes through whole-format guard' ((Clip)-ceq 'guarded-clipboard-probe')
    $sinkFile=Join-Path $script:selectionArtifact 'right-paste.txt'
    $sinkExe=Join-Path (Split-Path $PSScriptRoot -Parent) 'bin/clipboard-sink-unit/clipboard-sink.exe'
    if(-not (Test-Path -LiteralPath $sinkExe)){throw 'Compile the native clipboard sink before acceptance'}
    $catalogPath=Join-Path $profile 'agliteterm/profiles.json'
    if(Test-Path -LiteralPath $catalogPath){throw 'Clipboard fixture refuses to overwrite an existing launch catalog'}
    function Clip-Sink([string]$Result){
        @{default='ClipboardShell';profiles=@(@{name='ClipboardSink';command=$sinkExe;args=@($Result);cwd=$script:selectionArtifact},@{name='ClipboardShell';command='powershell.exe';args=@('-NoLogo','-NoProfile','-NoExit');cwd=$script:selectionArtifact})}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $catalogPath -Encoding utf8
        Selection-Rpc 'profiles.reload'|Out-Null
        $id=[string](Selection-Rpc 'session.new' @{name='clipboard-paste-sink';profile='ClipboardSink'})
        $clipIds.Add($id)
        if(-not (ClipWait {([string](Selection-Rpc 'session.text' @{} $id)).Contains('RIGHT-PASTE-READY')})){throw 'Native sink did not establish no-echo console mode'}
        return $id
    }
    $sinkId=Clip-Sink $sinkFile
    Selection-Rpc 'session.select' @{} $sinkId|Out-Null
    if(-not (ClipWait {@((Selection-Rpc 'tree').workspaces.sessions|Where-Object {$_.id-eq $sinkId -and $_.active}).Count-eq 1})){throw 'Private paste sink not selected'}
    if(-not (ClipWait {([string](Selection-Rpc 'session.text' @{} $sinkId)).Contains('RIGHT-PASTE-READY')})){throw 'Private paste sink not ready'}
    Write-SelectionClipboardMarker $clipboard 'PASTED_OK'
    $geometry=Selection-Geometry
    [SelectionUi]::Button($h,0x204,($geometry.Left+25),($geometry.Top+25))
    [SelectionUi]::Button($h,0x205,($geometry.Left+25),($geometry.Top+25))
    Selection-Rpc 'session.type' @{text="`r"} $sinkId|Out-Null
    Check 'right-click pastes into a mouse-reporting pane' (ClipWait {(Test-Path -LiteralPath $sinkFile) -and (Get-Content -LiteralPath $sinkFile -Raw)-ceq 'True'})
    Check 'right-click paste does not mutate clipboard' ((Clip)-ceq 'PASTED_OK')
    Selection-Rpc 'session.close' @{} $sinkId|Out-Null;$clipIds.Remove($sinkId)|Out-Null

    # Exercise actual ConPTY echo/control semantics with synthetic data, never a live clipboard read.
    foreach($payload in @("SYNTHETIC-NO-ECHO`r",([string][char]3+"SYNTHETIC-NO-EXECUTE`r"),"wrong`rSYNTHETIC-SECOND-LINE`r")){
        $resultFile=Join-Path $script:selectionArtifact ([guid]::NewGuid().ToString('N')+'.boolean')
        $proofId=Clip-Sink $resultFile
        Selection-Rpc 'session.type' @{text=$payload;'allow-control'=$true} $proofId|Out-Null
        Check 'native sink terminates after synthetic console input' (ClipWait {@((Selection-Rpc 'tree').workspaces.sessions|Where-Object {$_.id-eq $proofId -and $_.exited}).Count-eq 1})
        Check 'native sink persists only a boolean mismatch' ((Test-Path -LiteralPath $resultFile) -and (Get-Content -LiteralPath $resultFile -Raw)-ceq 'False')
        Check 'actual console input is not echoed into the pane' (-not ([string](Selection-Rpc 'session.text' @{} $proofId)).Contains('SYNTHETIC-'))
        Selection-Rpc 'session.close' @{} $proofId|Out-Null;$clipIds.Remove($proofId)|Out-Null
    }

    # OSC 52 travels through actual child output, exercising the host-action drain.
    $oscId=[string](Selection-Rpc 'session.new' @{name='clipboard-osc52'});$clipIds.Add($oscId)
    Selection-Rpc 'session.select' @{} $oscId|Out-Null
    if(-not (ClipWait {([string](Selection-Rpc 'session.text' @{} $oscId)).Contains('>')})){throw 'OSC shell prompt not ready'}
    Write-SelectionClipboardMarker $clipboard 'BEFORE-OSC52'
    Invoke-SelectionClipboardCopy $clipboard {
        Selection-Rpc 'session.type' @{text="[Console]::Write(([string][char]27)+']52;c;aGVsbG8gZnJvbSBvc2M1Mg=='+[char]7)`r"} $oscId|Out-Null
        if(-not (ClipWait {[Agwinterm.Win32ControlTest.ClipboardGuard]::Api.Sequence()-ne $clipboard.Sequence})){throw 'OSC 52 action did not complete; receipt remains pending'}
    } { 'hello from osc52' } ([Func[bool]]{[SelectionUi]::ClipboardOwnedBy($script:selectionProc.Id)})
    Check 'OSC 52 child output reaches Windows clipboard with ownership proof' ((Clip)-ceq 'hello from osc52')

    $dsrFile=Join-Path $script:selectionArtifact 'dsr.ps1'
    @'
$e=[char]27
[Console]::Write("$e[6n")
$r=@();$watch=[Diagnostics.Stopwatch]::StartNew()
while($watch.ElapsedMilliseconds-lt 5000 -and ($r.Count-eq 0 -or $r[-1]-ne 82)){
    while([Console]::KeyAvailable){$r+=[int][char][Console]::ReadKey($true).KeyChar}
    Start-Sleep -Milliseconds 50
}
Write-Host "DSR=<$($r-join ',')>"
'@|Set-Content -LiteralPath $dsrFile -Encoding utf8
    Selection-Rpc 'session.type' @{text=("& '"+$dsrFile.Replace("'","''")+"'`r")} $oscId|Out-Null
    Check 'DSR query receives its host-action response' (ClipWait {([string](Selection-Rpc 'session.text' @{} $oscId))-match 'DSR=<27,91,(?:4[89]|5[0-7])(?:,(?:4[89]|5[0-7]))*,59,(?:4[89]|5[0-7])(?:,(?:4[89]|5[0-7]))*,82>'})

    Main-Screen;Write-Screen (($esc+'[H')+((1..80|ForEach-Object{'COPY-ME-MARKER'})-join "`r`n")) $oscId
    $geometry=Selection-Geometry
    Selection-Drag @($h,($geometry.Left+5),($geometry.Top+5),($geometry.Right-10),($geometry.Bottom-10),0)
    $copyText=Selected $oscId
    Check 'drag selection contains seeded marker (auto-copy receipted)' ($copyText.Contains('COPY-ME-MARKER'))
    Write-SelectionClipboardMarker $clipboard 'BEFORE-CTRL-C'
    Invoke-SelectionClipboardCopy $clipboard { [LiteUi]::Chord($h,0x43,$false) } { $copyText } ([Func[bool]]{[SelectionUi]::ClipboardOwnedBy($script:selectionProc.Id)})
    Check 'Ctrl+C copies precisely the selected text' ((Clip)-ceq $copyText)
    Selection-Rpc 'selection.clear' @{} $oscId|Out-Null
    # Observe a real command cancellation, not growth in an echoed draft.
    Selection-Rpc 'session.type' @{text="Write-Output ('INTERRUPT-'+'READY'); Start-Sleep -Seconds 120`r"} $oscId|Out-Null
    if(-not (ClipWait {([string](Selection-Rpc 'session.text' @{} $oscId)).Contains('INTERRUPT-READY')})){throw 'Interrupt fixture not ready'}
    [LiteUi]::Chord($h,0x43,$false)
    Selection-Rpc 'session.type' @{text="Write-Output ('INTERRUPT-'+'DONE')`r"} $oscId|Out-Null
    Check 'Ctrl+C without selection interrupts the running child command' (ClipWait {([string](Selection-Rpc 'session.text' @{} $oscId)).Contains('INTERRUPT-DONE')})
    Check 'interrupt with no selection preserves clipboard generation' ((Clip)-ceq $copyText)
}finally{foreach($id in $clipIds){Selection-Rpc 'session.close' @{} $id -AllowError|Out-Null}}
