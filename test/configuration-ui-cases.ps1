# Runs inside selection-ui's token/clipboard/registry/process ownership boundary only.
if(-not $script:selectionProc -or -not $clipboard){throw 'Configuration checks require guarded fixture'}
'-- P10a guarded configuration acceptance --'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class P10ConfigurationUi {
 [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr window);
 [DllImport("user32.dll")] static extern uint GetMenuState(IntPtr menu,uint id,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent,IntPtr after,string cls,string title);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out IntPtr result);
 public static bool Checked(IntPtr window,uint id) {
  uint state=GetMenuState(GetMenu(window),id,0);
  if(state==0xffffffff)throw new InvalidOperationException("Owned menu item absent");
  return (state&8)!=0;
 }
 public static bool ToolbarChecked(IntPtr window,uint id) {
  IntPtr bar=FindWindowExW(window,IntPtr.Zero,"ToolbarWindow32",null), result;
  if(bar==IntPtr.Zero || SendMessageTimeoutW(bar,0x40A,(IntPtr)id,IntPtr.Zero,2,5000,out result)==IntPtr.Zero)
   throw new InvalidOperationException("Owned toolbar query failed");
  return result!=IntPtr.Zero;
 }
 public static void Command(IntPtr window,int id) {
  IntPtr result;
  if(SendMessageTimeoutW(window,0x111,(IntPtr)id,IntPtr.Zero,2,5000,out result)==IntPtr.Zero)
   throw new InvalidOperationException("Owned command did not complete");
 }
}
"@
Stop-SelectionSandbox
Start-SelectionSandbox $Exe $profile
$h=$script:selectionHwnd;$g=Selection-Geometry
function Config-Get([string]$Name){[string](Selection-Rpc 'config.get' @{key=$Name})}
function Config-Set([string]$SettingName,[string]$SettingText,[string]$Registry,[int]$Stored,[switch]$ThemeVerb,[int]$UiCommand=0) {
    $regKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey((Get-LiteTestRegistryPath))
    $prior=$script:selectionRegistry[$Registry].Expected
    try {
        Set-RegistryGuardValue $script:selectionRegistry $Registry @{Exists=$true;Kind=4;Value=$Stored} `
            {param($n) Read-RegistryGuardValue $regKey $n} `
            {param($n,$state)
                if($UiCommand){[P10ConfigurationUi]::Command($script:selectionHwnd,$UiCommand);$script:configReply='UI command completed'}
                elseif($ThemeVerb){$script:configReply=Selection-Rpc 'theme.set' @{name=$SettingText}}
                else{$script:configReply=Selection-Rpc 'config.set' @{key=$SettingName;value=$SettingText}}
            }
    } catch {
        # A known failed/no-write action can retain its previous proven expected value. Never
        # adopt arbitrary current state; an unknown write remains an explicit cleanup conflict.
        if(Test-RegistryGuardValue (Read-RegistryGuardValue $regKey $Registry) $prior){$script:selectionRegistry[$Registry].Expected=$prior}
        throw
    } finally {$regKey.Dispose()}
    return $script:configReply
}
function Config-Ready([string]$Id) {
    for($wait=0;$wait-lt 80;$wait++){
        if([string](Selection-Rpc 'session.text' @{} $Id)-match 'P10-IDLE-READY'){return}
        Start-Sleep -Milliseconds 100
    }
    throw 'P10 static surface did not become ready'
}
$idle="[Console]::WriteLine('P10-IDLE-READY'); while (`$true) { [void][Console]::ReadKey(`$true) }"
$old=[string](Selection-Rpc 'session.new' @{name='P10-existing';command=$idle});Config-Ready $old
$null=Selection-Rpc 'session.select' @{} $old
Set-SelectionRegistry 'P10UntouchedSentinel' @{Exists=$true;Kind=1;Value='not-a-setting-P10'}
$rows=@(
    @('theme','Theme','dark','dark',1),@('custom-colors','CustomColors','on','true',1),
    @('foreground','DefFg','#aBc123','#ABC123',0xABC123),@('background','DefBg','#123456','#123456',0x123456),
    @('dos-palette','DosPalette','off','false',0),@('sidebar-font-size','SidebarFontPt','6','6',6),
    @('show-sidebar','ShowSidebar','off','false',0),@('show-toolbar','ShowToolbar','off','false',0),
    @('show-status','ShowStatus','off','false',0),@('flag-view','FlagView','on','true',1),
    @('right-click-paste','RightClickPaste','off','false',0),@('copy-on-ctrl-c','CopyOnCtrlC','off','false',0),
    @('copy-on-select','CopyOnSelect','off','false',0),@('scrollback-lines','ScrollbackLines','2','2',2)
)
foreach($row in $rows){
    $reply=Config-Set $row[0] $row[2] $row[1] $row[4]
    Check "config $($row[0]): canonical readback and verified exact registry value" ((Config-Get $row[0])-ceq $row[3])
    Check "config $($row[0]): truthful applied reply" ($reply.StartsWith("$($row[0]) = $($row[3])"))
    $menuId=@{'show-sidebar'=123;'show-toolbar'=124;'show-status'=125;'flag-view'=127}[$row[0]]
    if($menuId){Check "config $($row[0]): menu check agrees" ([P10ConfigurationUi]::Checked($h,$menuId)-eq [bool]$row[4])}
    if($row[0]-eq 'flag-view'){Check 'config flag-view: toolbar check agrees' ([P10ConfigurationUi]::ToolbarChecked($h,127)-eq [bool]$row[4])}
}
Check 'scrollback setter names new-surface scope' ($reply -match 'applies to new surfaces')
$list=[string](Selection-Rpc 'config.list')
Check 'config list contains twenty-one supported keys once each' (($list-split "`n").Count-eq 21 -and @($list-split "`n"|Select-Object -Unique).Count-eq 21)
Check 'config key normalization' ((Config-Get ' COPY-ON-SELECT ')-eq 'false')
foreach($args_ in @(@{key='unknown';value='true'},@{key='font-size';value='16'},@{value='true'},@{key='theme'},
    @{key='copy-on-select';value='toggle'},@{key='scrollback-lines';value='1000001'},@{key='scrollback-lines';value='4294967296'},
    @{key='sidebar-font-size';value='5'},@{key='foreground';value='#gg1234'},@{key='theme';value='1'})) {
    $before=[string](Selection-Rpc 'config.list')
    $r=Selection-Rpc 'config.set' $args_ -AllowError
    Check "invalid config refuses without mutation: $($args_.key)/$($args_.value)" (-not $r.ok -and [string](Selection-Rpc 'config.list')-ceq $before)
}
Check 'unknown get refuses' (-not (Selection-Rpc 'config.get' @{key='unknown'} -AllowError).ok)
Check 'theme catalog names actual lite modes' ([string](Selection-Rpc 'theme.list')-ceq "auto`nlight`ndark`nclassic")
Check 'unknown theme refuses without changing mode' (-not (Selection-Rpc 'theme.set' @{name='invented'} -AllowError).ok -and (Config-Get 'theme')-eq 'dark')
$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey((Get-LiteTestRegistryPath))
try {Check 'single-key setters leave unrelated registry value intact' ($key.GetValue('P10UntouchedSentinel')-ceq 'not-a-setting-P10')}finally{$key.Dispose()}

# Fresh versus existing replicas: the setting never evicts history from a running surface.
$fresh=[string](Selection-Rpc 'session.new' @{name='P10-capped';command=$idle});Config-Ready $fresh
# The core amortizes eviction with 512 rows of slack: exceed that plus the live grid.
$history=($esc+'[3J'+$esc+'[2J'+$esc+'[H')+((0..1200|ForEach-Object{'P10-HIST-{0:D4}'-f $_})-join "`r`n")+"`r`n"
Write-Screen $history $old;Write-Screen $history $fresh
$oldText=[string](Selection-Rpc 'session.text' @{} $old);$newText=[string](Selection-Rpc 'session.text' @{} $fresh)
Check 'existing surface retains earlier scrollback cap' ($oldText-match 'P10-HIST-0000' -and $oldText-match 'P10-HIST-1200')
Check 'new surface uses reduced scrollback cap' ($newText-notmatch 'P10-HIST-0000' -and $newText-match 'P10-HIST-1200')
$null=Config-Set 'scrollback-lines' '0' 'ScrollbackLines' 0
$zero=[string](Selection-Rpc 'session.new' @{name='P10-zero';command=$idle});Config-Ready $zero
Write-Screen $history $zero
$all=[string](Selection-Rpc 'session.text' @{} $zero)
$screen=[string](Selection-Rpc 'session.text' @{lines=0} $zero)
Check 'zero scrollback contains only the live screen' ($all-ceq $screen -and $all-match 'P10-HIST-1200')

# Persisted values are loaded through the same definition before a restored/new replica exists.
Stop-SelectionSandbox;Start-SelectionSandbox $Exe $profile;$h=$script:selectionHwnd
foreach($row in $rows){
    $expected=if($row[0]-eq 'scrollback-lines'){'0'}else{$row[3]}
    Check "config $($row[0]): survives restart" ((Config-Get $row[0])-ceq $expected)
}
# Restore deterministic fixture values through the API for layout/copy/key tests.
foreach($row in $rows){
    $v=[int]$configDefaults[$row[1]]
    $text=if($row[0]-eq 'theme'){'auto'}elseif($row[0]-in @('foreground','background')){'#{0:X6}'-f $v}
        elseif($row[0]-in @('sidebar-font-size','scrollback-lines')){[string]$v}else{if($v){'true'}else{'false'}}
    $null=Config-Set $row[0] $text $row[1] $v
}
# Model another instance's successful save without changing this instance's runtime snapshot.
# Each unrelated human toggle must preserve that exact shared-registry value.
function Config-RegistryTheme {
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey((Get-LiteTestRegistryPath))
    try {return $key.GetValue('Theme')}finally{$key.Dispose()}
}
Set-SelectionRegistry 'Theme' @{Exists=$true;Kind=4;Value=1}
Check 'stale-instance setup has distinct runtime and persisted themes' ((Config-Get 'theme')-eq 'auto' -and (Config-RegistryTheme)-eq 1)
foreach($view in @(@('show-sidebar','ShowSidebar',123,0),@('show-toolbar','ShowToolbar',124,0),
    @('show-status','ShowStatus',125,0),@('flag-view','FlagView',127,1))) {
    $null=Config-Set $view[0] ([string]$view[3]) $view[1] $view[3] -UiCommand $view[2]
    Check "UI $($view[0]) preserves another instance's saved theme" ((Config-RegistryTheme)-eq 1)
    Check "UI $($view[0]) changes its own value" ((Config-Get $view[0])-eq $(if($view[3]){'true'}else{'false'}))
    $default=[int]$configDefaults[$view[1]]
    $null=Config-Set $view[0] ([string]$default) $view[1] $default
}
$null=Config-Set 'theme' 'auto' 'Theme' 0
$id=[string](Selection-Rpc 'session.new' @{name='P10-pixels-copy';command=$idle});Config-Ready $id
$null=Selection-Rpc 'session.select' @{} $id;$g=Selection-Geometry
Write-Screen ($esc+'[2J'+$esc+'[HP10-COPY word'+$esc+'[?25l')
$null=Config-Set 'theme' 'dark' 'Theme' 1 -ThemeVerb
$dark=Selection-Capture $h 'p10-theme-dark' 0 0 100 70
$null=Config-Set 'theme' 'light' 'Theme' 2 -ThemeVerb
$light=Selection-Capture $h 'p10-theme-light' 0 0 100 70
Check 'theme setter visibly updates chrome' ((Selection-PixelDiff $dark $light)-gt 100 -and (Config-Get 'theme')-eq 'light')

function No-Copy([scriptblock]$Action) {
    Assert-SelectionClipboardGeneration $clipboard
    $before=$clipboard.Sequence;$clipboard.Pending=$true
    & $Action | Out-Null
    $receipt=[Agwinterm.Win32ControlTest.ClipboardGuard]::ConfirmCopy((Selected),$before,[Func[bool]]{[SelectionUi]::ClipboardOwnedBy($script:selectionProc.Id)})
    if($receipt.State-eq 'unchanged'){$clipboard.Pending=$false}
    elseif($receipt.State-eq 'written'){$clipboard.Receipt=$receipt;$clipboard.Sequence=$receipt.Sequence;$clipboard.Touched=$true;$clipboard.Pending=$false}
    else{throw "No-copy action has unproven clipboard outcome: $($receipt.State)"}
    Check 'automatic no-copy action leaves clipboard sequence unchanged' ($receipt.State-eq 'unchanged')
}
$null=Config-Set 'copy-on-select' 'false' 'CopyOnSelect' 0
Set-Marker
$null=Selection-Rpc 'selection.all'
No-Copy {$r=Selection-Rpc 'selection.finalize';Check 'finalize names disabled automatic copy' ($r-eq 'finalized (copy-on-select off)')}
$x=$g.Left+2*$g.Cw;$y=$g.Top+[int]($g.Ch/2)
[SelectionUi]::Button($h,0x203,$x,$y)
No-Copy {[SelectionUi]::Button($h,0x202,$x,$y)}
Check 'mouse selection remains available with automatic copy off' ((Selected)-eq 'P10-COPY' -and (Clip)-eq $script:selectionMarker)
$expectedCopy=Selected
Invoke-SelectionClipboardCopy $clipboard {$null=Selection-Rpc 'selection.copy';Start-Sleep -Milliseconds 300} {$expectedCopy} ([Func[bool]]{[SelectionUi]::ClipboardOwnedBy($script:selectionProc.Id)})
Check 'explicit copy works with automatic copy off' ((Clip)-eq 'P10-COPY')
$null=Selection-Rpc 'session.overlay' @{action='open';command='pwsh -NoProfile';'size-percent'='60'}
$ph=[IntPtr]::Zero
for($i=0;$i-lt 50 -and $ph-eq [IntPtr]::Zero;$i++){Start-Sleep -Milliseconds 200;$ph=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLitePopup')}
if($ph-eq [IntPtr]::Zero){throw 'P10 copy-off popup did not open'}
Start-Sleep -Seconds 2
[void][SelectionUi]::PostMessageW($ph,7,[IntPtr]::Zero,[IntPtr]::Zero);Start-Sleep -Milliseconds 200
Write-Screen ($esc+'[2J'+$esc+'[HPOPUP-COPY'+$esc+'[?25l')
Set-Marker
[SelectionUi]::Button($ph,0x203,($g.Cw*2),[int]($g.Ch/2))
No-Copy {[SelectionUi]::Button($ph,0x202,($g.Cw*2),[int]($g.Ch/2))}
Check 'popup mouse selection remains available with automatic copy off' ((Selected)-eq 'POPUP-COPY' -and (Clip)-eq $script:selectionMarker)
$null=Selection-Rpc 'session.overlay' @{action='close'};Start-Sleep -Milliseconds 400
$null=Selection-Rpc 'session.select' @{} $id
$null=Selection-Rpc 'selection.all'
$null=Config-Set 'copy-on-select' 'true' 'CopyOnSelect' 1
Copy-Action {$null=Selection-Rpc 'selection.finalize';Start-Sleep -Milliseconds 300}
Check 'finalize positive copy control' ((Clip)-match 'P10-COPY')

# Reload must clear stale unbound actions and preserve explicit zero on seeded ones.
Set-SelectionRegistry 'Key_MarkMode' @{Exists=$true;Kind=4;Value=(0x300+[int][char]'K')}
$null=Selection-Rpc 'keymap.reload';[LiteUi]::Chord($h,[int][char]'K',$true)
Check 'keymap reload applies a rebound key' ([SelectionUi]::Status($h,2)-match 'MARK')
[LiteUi]::Key($h,0x1B,1)
Set-SelectionRegistry 'Key_MarkMode' @{Exists=$true;Kind=4;Value=0}
$null=Selection-Rpc 'keymap.reload';[LiteUi]::Chord($h,[int][char]'K',$true);[LiteUi]::Chord($h,[int][char]'M',$true)
Check 'keymap reload drops old key and preserves explicit zero' ([SelectionUi]::Status($h,2)-notmatch 'MARK')
Set-SelectionRegistry 'Key_MarkMode' @{Exists=$false;Kind=0;Value=$null}
$null=Selection-Rpc 'keymap.reload';[LiteUi]::Chord($h,[int][char]'M',$true)
Check 'keymap reload reseeds an absent default key' ([SelectionUi]::Status($h,2)-match 'MARK')
[LiteUi]::Key($h,0x1B,1)

# Copy has no seeded binding: deleting it must remove its stale in-memory chord.
Set-SelectionRegistry 'Key_Copy' @{Exists=$true;Kind=4;Value=(0x300+[int][char]'K')}
$null=Selection-Rpc 'keymap.reload';$null=Selection-Rpc 'selection.all'
$expectedCopy=Selected
Invoke-SelectionClipboardCopy $clipboard {[LiteUi]::Chord($h,[int][char]'K',$true)} {$expectedCopy} ([Func[bool]]{[SelectionUi]::ClipboardOwnedBy($script:selectionProc.Id)})
Check 'keymap reload applies an unseeded copy binding' ((Clip)-match 'P10-COPY')
Set-SelectionRegistry 'Key_Copy' @{Exists=$false;Kind=0;Value=$null}
$null=Selection-Rpc 'keymap.reload';$null=Selection-Rpc 'selection.all';Set-Marker
No-Copy {[LiteUi]::Chord($h,[int][char]'K',$true)}
Check 'keymap reload drops a deleted unseeded binding' ((Clip)-eq $script:selectionMarker)

$reply=Selection-Rpc 'settings.open'
Check 'settings acknowledges a request, not presumed visibility' ($reply-eq 'settings open requested')
$dialog=[IntPtr]::Zero
for($i=0;$i-lt 40;$i++){$dialog=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLiteProps');if($dialog-ne [IntPtr]::Zero){break};Start-Sleep -Milliseconds 50}
Check 'settings creates the owned Properties dialog' ($dialog-ne [IntPtr]::Zero)
try {
    $before=Config-Get 'theme'
    Set-SelectionRegistry 'Theme' @{Exists=$true;Kind=4;Value=1}
    foreach($pair in @(@('config.set',@{key='theme';value='dark'}),@('theme.set',@{name='dark'}),@('keymap.reload',@{}),@('settings.open',@{}))){
        $r=Selection-Rpc $pair[0] $pair[1] -AllowError
        Check "modal editing blocks $($pair[0]) without mutation" (-not $r.ok -and $r.error-match 'modal dialog' -and (Config-Get 'theme')-eq $before)
    }
    [P10ConfigurationUi]::Command($dialog,1) # OK, with no edited fields
    Check 'unchanged Properties OK preserves another instance saved theme' ((Config-RegistryTheme)-eq 1)
} finally {
    if($dialog-ne [IntPtr]::Zero){[void][SelectionUi]::PostMessageW($dialog,0x10,[IntPtr]::Zero,[IntPtr]::Zero)}
    for($i=0;$i-lt 40;$i++){if([SelectionUi]::Window($script:selectionProc.Id,'AgwintermLiteProps')-eq [IntPtr]::Zero){break};Start-Sleep -Milliseconds 50}
}
$null=Config-Set 'theme' 'auto' 'Theme' 0
Check 'configuration writes resume after modal dialog closes' ((Config-Get 'theme')-eq 'auto')
