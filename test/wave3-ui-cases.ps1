# Runs only inside selection-ui's lease, owned process and registry/clipboard guards.
'-- P17 Wave 3 guarded native acceptance --'
function Wave-Rpc([string]$Command,[hashtable]$Arguments=@{},[string]$Target,[string]$Window,[switch]$Refusal){
    $body=@{cmd=$Command;args=$Arguments};if($Target){$body.target=$Target};if($Window){$body.window=$Window}
    $pipeClient=[IO.Pipes.NamedPipeClientStream]::new('.',$script:selectionPipe,[IO.Pipes.PipeDirection]::InOut)
    try{$pipeClient.Connect(2000);$writer=[IO.StreamWriter]::new($pipeClient);$writer.AutoFlush=$true;$reader=[IO.StreamReader]::new($pipeClient)
        $writer.WriteLine(($body|ConvertTo-Json -Compress -Depth 15));$read=$reader.ReadLineAsync();if(-not $read.Wait(15000)){throw "Wave3 request timeout: $Command"}
        $reply=$read.Result|ConvertFrom-Json;if($Refusal){return (-not $reply.ok -and [bool]$reply.error)}
        if(-not $reply.ok){throw "${Command}: $($reply.error)"};return $reply.result
    }finally{$pipeClient.Dispose()}
}
if(-not ('WaveUi' -as [type])){Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class WaveUi {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,string l,uint f,uint t,out IntPtr r);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h,int id,uint mods,uint vk);
 [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h,int id);
 [DllImport("user32.dll")] public static extern bool SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint f,uint t,out IntPtr r);
 public static void Text(IntPtr h,string text){IntPtr r;if(SendMessageTimeoutW(h,12,IntPtr.Zero,text,2,5000,out r)==IntPtr.Zero)throw new Exception("Set owned text timed out");}
}
'@}
function Wave-Set([string]$Key,[string]$Value,[string]$Registry,[int]$Stored){
    $regKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\agliteterm')
    $prior=$script:selectionRegistry[$Registry].Expected
    try{Set-RegistryGuardValue $script:selectionRegistry $Registry @{Exists=$true;Kind=4;Value=$Stored} `
        {param($n) Read-RegistryGuardValue $regKey $n} `
        {param($n,$state) $null=Wave-Rpc 'config.set' @{key=$Key;value=$Value}}
    }catch{if(Test-RegistryGuardValue (Read-RegistryGuardValue $regKey $Registry) $prior){$script:selectionRegistry[$Registry].Expected=$prior};throw
    }finally{$regKey.Dispose()}
}
# Start fresh even in run-all: previous phase restart fixtures must not dictate Wave3's tree.
Stop-SelectionSandbox
$waveProfile=Join-Path $script:selectionArtifact 'wave3-profile';New-Item -ItemType Directory $waveProfile|Out-Null
Start-SelectionSandbox $Exe $waveProfile
$h=$script:selectionHwnd;$g=Selection-Geometry
$owner=@((Wave-Rpc 'tree').workspaces.sessions)[0].id
$beforeForeground=[WaveUi]::GetForegroundWindow()
$hud=Wave-Rpc 'session.hud.open' @{message="Cafe$([char]0x301)";detail='detail';spinner='dot';position='bottom-right';color='#123456';'size-percent'=40} $owner
Check 'HUD NFC normalization and typed readback' ($hud.hud.message -eq "Caf$([char]0xE9)" -and $hud.hud.position -eq 'bottom-right' -and $hud.hud.backgroundColor -eq '123456' -and $hud.hud.sizePercent -eq 40)
Check 'HUD is passive' ([WaveUi]::GetForegroundWindow() -eq $beforeForeground)
foreach($position in 'top-left','top-center','top-right','center-left','center','center-right','bottom-left','bottom-center','bottom-right'){
    $updated=Wave-Rpc 'session.hud.update' @{message=$position;position=$position} $owner
    Check "HUD anchor $position" ($updated.hud.position -eq $position -and $updated.hud.backgroundColor -eq '123456')
}
foreach($bad in @(@{message=''},@{message="bad`nline"},@{message='x';spinner='bad'},@{message='x';position='bad'},@{message='x';'size-percent'=0},@{message='x';color='red'},@{message='x';unknown=$true})){
    Check 'HUD rejects invalid input without closing existing HUD' (Wave-Rpc 'session.hud.open' $bad $owner -Refusal)
}
Check 'HUD appears in tree' ([bool](@((Wave-Rpc 'tree').workspaces.sessions)|Where-Object id -eq $owner).hud)
$null=Wave-Rpc 'session.overlay' @{action='close'} $owner
Check 'generic overlay close dismisses HUD' (-not (@((Wave-Rpc 'tree').workspaces.sessions)|Where-Object id -eq $owner).hud)
Check 'HUD update without HUD refuses' (Wave-Rpc 'session.hud.update' @{message='missing'} $owner -Refusal)
Check 'foreign window selector refuses' (Wave-Rpc 'ping' @{} '' 'p17-not-this-window' -Refusal)

$items=@(@{id='a';label='Alpha';subtitle='Beta'},@{id='b';label='Beta'},@{id='b2';label='Beta'})
$pick=Wave-Rpc 'pick.open' @{items=$items;prompt='P17 pick'}
$picker=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePicker')
Check 'picker creates native window and exact id' ($picker -ne [IntPtr]::Zero -and [bool]$pick.id)
Check 'picker open does not seize foreground' ([WaveUi]::GetForegroundWindow() -eq $beforeForeground)
Check 'picker begins pending' ((Wave-Rpc 'pick.result' @{} $pick.id).pick.result -eq 'pending')
Check 'picker exact id required' (Wave-Rpc 'pick.result' @{} $pick.id.Substring(0,8) -Refusal)
Check 'second picker refused' (Wave-Rpc 'pick.open' @{items=$items} -Refusal)
Check 'picker blocks quick opening' (Wave-Rpc 'quick' @{op='on'} -Refusal)
Check 'picker blocks settings opening' (Wave-Rpc 'settings.open' -Refusal)
$edit=[WaveUi]::GetDlgItem($picker,101);$list=[WaveUi]::GetDlgItem($picker,102)
Check 'picker standard controls exist' ($edit -ne [IntPtr]::Zero -and $list -ne [IntPtr]::Zero)
[WaveUi]::Text($edit,'Beta');[LiteUi]::Key($edit,0x0D,1);Start-Sleep -Milliseconds 250
$answer=(Wave-Rpc 'pick.result' @{} $pick.id).pick
Check 'picker searches labels, stable duplicate tie order' ($answer.result -eq 'picked' -and $answer.id -eq 'b') ($answer|ConvertTo-Json -Compress)
Check 'picker completed cancel preserves answer' ((Wave-Rpc 'pick.cancel' @{} $pick.id) -eq 'cancelled' -and (Wave-Rpc 'pick.result' @{} $pick.id).pick.id -eq 'b')
$custom=Wave-Rpc 'pick.open' @{items=@();allowCustom=$true;query='  custom answer  '}
$picker=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePicker');[LiteUi]::Key([WaveUi]::GetDlgItem($picker,101),0x0D,1);Start-Sleep -Milliseconds 200
Check 'picker custom trims surrounding whitespace' ((Wave-Rpc 'pick.result' @{} $custom.id).pick.query -eq 'custom answer')
$cancel=Wave-Rpc 'pick.open' @{items=$items};$null=Wave-Rpc 'pick.cancel' @{} $cancel.id
Check 'picker cancellation terminal result' ((Wave-Rpc 'pick.result' @{} $cancel.id).pick.result -eq 'cancelled')
foreach($bad in @(@{items=@()},@{items=@(@{id='a';label=''},@{id='b';label='ok'})},@{items=@(@{id='x';label='a'},@{id='x';label='b'})},@{items='wrong'},@{items=$items;allowCustom='true'})){
    Check 'picker rejects invalid typed input' (Wave-Rpc 'pick.open' $bad -Refusal)
}
for($n=0;$n -lt 8;$n++){$recent=Wave-Rpc 'pick.open' @{items=$items};$null=Wave-Rpc 'pick.cancel' @{} $recent.id}
Check 'picker evicts oldest after eight completed answers' (Wave-Rpc 'pick.result' @{} $pick.id -Refusal)
Check 'picker retains newest exact result' ((Wave-Rpc 'pick.result' @{} $recent.id).pick.result -eq 'cancelled')

# Capture refusal is before state creation; a subsequent picker must still be possible.
Selection-Button -EventArgs @($h,0x201,($g.Left+10),($g.Top+10))
try{
    Check 'picker capture fixture owns capture' ([SelectionUi]::Capture($h) -eq $h)
    Check 'picker refuses while terminal drag owns capture' (Wave-Rpc 'pick.open' @{items=$items} -Refusal)
}finally{Selection-Button -EventArgs @($h,0x202,($g.Left+10),($g.Top+10))}
$isolated=Wave-Rpc 'pick.open' @{items=$items}
$picker=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePicker')
$null=Wave-Rpc 'session.write' @{text=([string][char]27+'[2J'+[char]27+'[HOWNER-STAYS')} $owner
[LiteUi]::Key($h,0x1B,1);Start-Sleep -Milliseconds 200
Check 'owner keyboard Escape routes to picker cancellation' ((Wave-Rpc 'pick.result' @{} $isolated.id).pick.result -eq 'cancelled')
Check 'explicit API writes remain independent of picker' ((Wave-Rpc 'session.text' @{} $owner) -match 'OWNER-STAYS')

$ws=Wave-Rpc 'workspace.new' @{name='P17 empty'}
$null=Wave-Rpc 'session.select' @{} $owner
$null=Wave-Rpc 'workspace.collapse' @{} $ws
Check 'workspace collapse tree state' ([bool](@((Wave-Rpc 'tree').workspaces)|Where-Object id -eq $ws).collapsed)
$null=Wave-Rpc 'workspace.go' @{to='next'}
$next=@((Wave-Rpc 'tree').workspaces)|Where-Object active
Check 'workspace navigation includes collapsed empty row' ($next.id -eq $ws)
$null=Wave-Rpc 'workspace.go' @{to='prev'}
Check 'workspace previous wraps back' ((@((Wave-Rpc 'tree').workspaces)|Where-Object active).id -ne $ws)
$null=Wave-Rpc 'workspace.expand' @{} $ws
Check 'workspace expand tree state' (-not (@((Wave-Rpc 'tree').workspaces)|Where-Object id -eq $ws).collapsed)
Check 'workspace bad direction refuses' (Wave-Rpc 'workspace.go' @{to='sideways'} -Refusal)
Check 'tree includes pane-ordered conservative shell hints' ((@((Wave-Rpc 'tree').workspaces.sessions)|Where-Object id -eq $owner).PSObject.Properties.Name -contains 'foregroundShells')

$null=Wave-Rpc 'quick' @{op='on'};$quick=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')
Check 'quick API show is visible and nonactivating' ($quick -ne [IntPtr]::Zero -and [WaveUi]::GetForegroundWindow() -eq $beforeForeground)
Check 'quick omitted from library tree' (-not (@((Wave-Rpc 'tree').workspaces.sessions)|Where-Object {$_.id -like 'quick:*'}))
Check 'quick library mutation refuses' (Wave-Rpc 'session.new' @{} '' 'quick' -Refusal)
$null=Wave-Rpc 'session.write' @{text=([string][char]27+'[2J'+[char]27+'[HP17-QUICK-RETAIN')} '' 'quick'
Check 'explicit quick window routes content' ((Wave-Rpc 'session.text' @{} '' 'quick') -match 'P17-QUICK-RETAIN')
$null=Wave-Rpc 'quick' @{op='off'}
Check 'quick hidden content selector refuses' (Wave-Rpc 'session.text' @{} '' 'quick' -Refusal)
$null=Wave-Rpc 'quick' @{op='on'}
Check 'quick retains hidden shell' ((Wave-Rpc 'session.text' @{} '' 'quick') -match 'P17-QUICK-RETAIN')
$null=Wave-Rpc 'quick' @{op='off'}
Check 'quick off hides popup' (-not [WaveUi]::IsWindowVisible($quick))
Check 'cursor defaults readable' ((Wave-Rpc 'config.get' @{key='cursor-style'}) -eq 'bar' -and (Wave-Rpc 'config.get' @{key='cursor-blink-ms'}) -eq '530')
Check 'quick default size and disabled hotkey readable' ((Wave-Rpc 'config.get' @{key='quick-terminal-size'}) -eq '70' -and (Wave-Rpc 'config.get' @{key='quick-terminal-hotkey'}) -eq '')
foreach($bad in @(@{key='cursor-style';value='circle'},@{key='cursor-blink-ms';value='0'},@{key='quick-terminal-size';value='91'},@{key='quick-terminal-hotkey';value='win+k'})){
    Check 'invalid Wave3 setting refuses unchanged' (Wave-Rpc 'config.set' $bad -Refusal)
}
foreach($style in @(@('block',1),@('underline',2),@('bar',0))){
    Wave-Set 'cursor-style' $style[0] 'CursorStyle' $style[1]
    Check 'cursor style applies and reads back' ((Wave-Rpc 'config.get' @{key='cursor-style'}) -eq $style[0])
}
Wave-Set 'cursor-blink' 'off' 'CursorBlink' 0
Wave-Set 'cursor-blink-ms' '250' 'CursorBlinkMs' 250
Check 'cursor blink settings apply live' ((Wave-Rpc 'config.get' @{key='cursor-blink'}) -eq 'false' -and (Wave-Rpc 'config.get' @{key='cursor-blink-ms'}) -eq '250')
Wave-Set 'cursor-blink' 'on' 'CursorBlink' 1
Wave-Set 'cursor-blink-ms' '530' 'CursorBlinkMs' 530
if($env:CI -eq 'true'){
    # Registration only on a disposable desktop. No real global key injection is used.
    Wave-Set 'quick-terminal-hotkey' 'ctrl+alt+f10' 'QuickTerminalHotkey' 0x379
    $reserved=[WaveUi]::RegisterHotKey([IntPtr]::Zero,0x713,0x4003,0x7A)
    try{
        Check 'hotkey conflict fixture reserves distinct candidate' $reserved
        if(-not $reserved){throw 'Cannot reserve disposable hotkey conflict'}
        Check 'hotkey conflict refuses replacement' (Wave-Rpc 'config.set' @{key='quick-terminal-hotkey';value='ctrl+alt+f11'} -Refusal)
        Check 'hotkey conflict preserves prior binding' ((Wave-Rpc 'config.get' @{key='quick-terminal-hotkey'}) -eq 'ctrl+alt+f10')
    }finally{if($reserved){[void][WaveUi]::UnregisterHotKey([IntPtr]::Zero,0x713)}}
    Wave-Set 'quick-terminal-hotkey' '' 'QuickTerminalHotkey' 0
}
