# P7's isolated UI harness. No sweeps by process name, path, command line or PID difference.
# The caller holds the desktop suite token through Stop-SelectionSandbox and state restoration.
function Invoke-SelectionCleanup([scriptblock]$ProcessCleanupStep,[scriptblock]$RegistryRestoreStep,[scriptblock]$ClipboardRestoreStep) {
    $ok=$true
    foreach($step in @(@{Name='processes';Run=$ProcessCleanupStep},@{Name='registry';Run=$RegistryRestoreStep},@{Name='clipboard';Run=$ClipboardRestoreStep})){
        try { & $step.Run | Out-Null }
        catch { $ok=$false;Write-Host "TEARDOWN INCOMPLETE ($($step.Name)): $($_.Exception.Message)" }
    }
    return $ok
}
. "$PSScriptRoot/ui-lib.ps1"
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
if (-not ('SelectionUi' -as [type])) { Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SelectionUi {
 public delegate bool EnumProc(IntPtr h,IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct RECT {public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential)] public struct POINT {public int X,Y;}
 [StructLayout(LayoutKind.Sequential)] struct GUIINFO {public uint Size,Flags;public IntPtr Active,Focus,Capture,MenuOwner,MoveSize,Caret;public RECT CaretRect;}
 [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread,ref GUIINFO info);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc c,IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumProc c,IntPtr l);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h,ref POINT p);
 [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref POINT p);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint f);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out IntPtr result);
 [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p,IntPtr address,UIntPtr size,uint type,uint protect);
 [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p,IntPtr address,UIntPtr size,uint type);
 [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p,IntPtr address,byte[] bytes,UIntPtr size,out UIntPtr read);
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 static string Class(IntPtr h){var b=new StringBuilder(256);GetClassNameW(h,b,256);return b.ToString();}
 public static IntPtr Window(int pid,string cls){IntPtr result=IntPtr.Zero;EnumWindows((h,l)=>{uint p;GetWindowThreadProcessId(h,out p);if(p==pid && Class(h)==cls && (cls!="AgwintermLitePopup" || IsWindowVisible(h))){result=h;return false;}return true;},IntPtr.Zero);return result;}
 public static IntPtr Child(IntPtr h,string cls){IntPtr result=IntPtr.Zero;EnumChildWindows(h,(c,l)=>{if(Class(c)==cls){result=c;return false;}return true;},IntPtr.Zero);return result;}
 public static RECT Rect(IntPtr h){RECT r;GetClientRect(h,out r);return r;}
 public static IntPtr Capture(IntPtr h){uint pid;uint thread=GetWindowThreadProcessId(h,out pid);var info=new GUIINFO{Size=(uint)Marshal.SizeOf<GUIINFO>()};if(thread==0 || !GetGUIThreadInfo(thread,ref info))throw new InvalidOperationException("Cannot read owned window capture");return info.Capture;}
 public static RECT ChildRect(IntPtr parent,string cls){var h=Child(parent,cls);RECT r=new RECT();if(h==IntPtr.Zero)return r;GetWindowRect(h,out r);var a=new POINT{X=r.Left,Y=r.Top};var b=new POINT{X=r.Right,Y=r.Bottom};ScreenToClient(parent,ref a);ScreenToClient(parent,ref b);return new RECT{Left=a.X,Top=a.Y,Right=b.X,Bottom=b.Y};}
 public static string Status(IntPtr h,int part){
  var bar=Child(h,"msctls_statusbar32");uint pid;GetWindowThreadProcessId(bar,out pid);if(pid==0)return null;
  var p=OpenProcess(0x38,false,pid);if(p==IntPtr.Zero)return null;
  try{IntPtr result;if(SendMessageTimeoutW(bar,0x40C,(IntPtr)part,IntPtr.Zero,2,5000,out result)==IntPtr.Zero)return null;
   int len=(int)(result.ToInt64()&65535);var mem=VirtualAllocEx(p,IntPtr.Zero,(UIntPtr)((len+1)*2),0x3000,4);if(mem==IntPtr.Zero)return null;
   try{if(SendMessageTimeoutW(bar,0x40D,(IntPtr)part,mem,2,5000,out result)==IntPtr.Zero)return null;var bytes=new byte[len*2];UIntPtr read;if(len>0 && !ReadProcessMemory(p,mem,bytes,(UIntPtr)bytes.Length,out read))return null;return Encoding.Unicode.GetString(bytes);}
   finally{VirtualFreeEx(p,mem,UIntPtr.Zero,0x8000);}
  }finally{CloseHandle(p);}
 }
 static IntPtr Point(int x,int y){return (IntPtr)((y<<16)|(x&65535));}
 public static void Button(IntPtr h,uint message,int x,int y){PostMessageW(h,message,message==0x202?IntPtr.Zero:(IntPtr)1,Point(x,y));}
 public static void Wheel(IntPtr h,int x,int y,int notches){var p=new POINT{X=x,Y=y};ClientToScreen(h,ref p);for(int i=0;i<Math.Abs(notches);i++){PostMessageW(h,0x20A,(IntPtr)((notches>0?120:-120)<<16),Point(p.X,p.Y));System.Threading.Thread.Sleep(60);}System.Threading.Thread.Sleep(250);}
}
'@ }

function Selection-Rpc([string]$cmd,[hashtable]$args_=@{},[string]$target='active',[switch]$AllowError) {
    $client=[IO.Pipes.NamedPipeClientStream]::new('.',$script:selectionPipe,[IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect(2000);$writer=[IO.StreamWriter]::new($client);$writer.AutoFlush=$true;$reader=[IO.StreamReader]::new($client)
        $writer.WriteLine((@{cmd=$cmd;target=$target;args=$args_}|ConvertTo-Json -Compress -Depth 10))
        $read=$reader.ReadLineAsync();if(-not $read.Wait(5000)){throw 'selection UI control request timed out'}
        $reply=$read.Result|ConvertFrom-Json
        if(-not $reply.ok -and -not $AllowError){throw "${cmd}: $($reply.error)"}
        if($AllowError){return $reply};return $reply.result
    } finally {$client.Dispose()}
}
function Start-SelectionSandbox {
    param([string]$Exe,[string]$Profile)
    # Caller records the launch immediately; even startup failure is cleaned by its finally.
    $script:selectionProc=Start-Process $Exe -ArgumentList @('--pipe',$script:selectionPipe,'--no-restore') -Environment @{LOCALAPPDATA=$Profile} -WindowStyle Hidden -PassThru
    $script:selectionLaunched=$true
    [void]$script:selectionProc.SafeHandle
    $script:selectionHosts=@()
    for($i=0;$i -lt 60;$i++) {
        try {$null=Selection-Rpc 'ping';break} catch {if($script:selectionProc.HasExited){throw 'selection sandbox exited during launch'};Start-Sleep -Milliseconds 250}
    }
    $null=Selection-Rpc 'ping'
    if($script:selectionProc.HasExited){throw 'Sandbox exited before host identity capture'}
    foreach($row in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($script:selectionProc.Id) AND Name='agwinterm-ptyhost.exe'")) {
        $owned=Get-Process -Id $row.ProcessId;[void]$owned.SafeHandle
        $t=$owned.StartTime.ToUniversalTime().Ticks;$r=$row.CreationDate.ToUniversalTime().Ticks
        # CIM timestamps have microsecond precision; no broad millisecond identity tolerance.
        if(($t-($t%10)) -ne ($r-($r%10)) -or $owned.StartTime -lt $script:selectionProc.StartTime -or $script:selectionProc.HasExited){throw 'Cannot prove sandbox host identity within the live parent lifetime'}
        $script:selectionHosts+=$owned
    }
    $script:selectionHwnd=[SelectionUi]::Window($script:selectionProc.Id,'AgwintermLite')
    if($script:selectionHwnd -eq [IntPtr]::Zero){throw 'No sandbox frame'}
    [void][LiteUi]::ShowWindow($script:selectionHwnd,4) # show without activating
    [void][LiteUi]::SetWindowPos($script:selectionHwnd,[IntPtr]::Zero,150,100,1100,700,0x14)
    Start-Sleep -Seconds 3
}
function Stop-SelectionSandbox {
    if($script:selectionProc -and -not $script:selectionProc.HasExited){
        [void]$script:selectionProc.CloseMainWindow()
        if(-not $script:selectionProc.WaitForExit(10000)){$script:selectionProc.Kill();if(-not $script:selectionProc.WaitForExit(5000)){throw 'Owned window did not exit'}}
    }
    foreach($owned in $script:selectionHosts){if(-not $owned.HasExited){
        if(@(Get-CimInstance Win32_Process -Filter "Name='agliteterm.exe'").Count){throw 'Other lite window exists; shared host retained'}
        $owned.Kill();if(-not $owned.WaitForExit(5000)){throw 'Owned host did not exit'}
    }}
    if($script:selectionLaunched -and @(Get-CimInstance Win32_Process -Filter "Name='agliteterm.exe' OR Name='agwinterm-ptyhost.exe'").Count){
        throw 'Lite/host residue remains after owned teardown; refusing to kill an unproven process or release the token'
    }
    $script:selectionProc=$null;$script:selectionHosts=@()
    $script:selectionLaunched=$false
}
function Selection-Geometry {
    $h=$script:selectionHwnd;$rc=[SelectionUi]::Rect($h)
    $tree=[SelectionUi]::ChildRect($h,'SysTreeView32');$toolbar=[SelectionUi]::ChildRect($h,'ToolbarWindow32');$status=[SelectionUi]::ChildRect($h,'msctls_statusbar32')
    $size=[SelectionUi]::Status($h,2)
    if($size -notmatch '(\d+)\s*×\s*(\d+)'){throw "Cannot read cell dimensions: $size"}
    $cols=[int]$Matches[1];$rows=[int]$Matches[2]
    $left=if($tree.Right){$tree.Right+5}else{0};$top=$toolbar.Bottom;$bottom=if($status.Top){$status.Top}else{$rc.Bottom}
    @{Left=$left;Top=$top;Right=$rc.Right;Bottom=$bottom;Cols=$cols;Rows=$rows;Cw=[int][math]::Floor(($rc.Right-$left)/$cols);Ch=[int][math]::Floor(($bottom-$top)/$rows)}
}
function Selection-Capture([IntPtr]$h,[string]$name,[int]$left,[int]$top,[int]$width,[int]$height) {
    $bitmap=[Drawing.Bitmap]::new(1200,900);$graphics=[Drawing.Graphics]::FromImage($bitmap);$dc=$graphics.GetHdc()
    try{if(-not [SelectionUi]::PrintWindow($h,$dc,1)){throw 'PrintWindow failed'}}finally{$graphics.ReleaseHdc($dc);$graphics.Dispose()}
    $bitmap.Save((Join-Path $script:selectionArtifact "$name.png"))
    $data=[Collections.Generic.List[int]]::new()
    for($y=$top;$y -lt ($top+$height);$y++){for($x=$left;$x -lt ($left+$width);$x++){$data.Add($bitmap.GetPixel($x,$y).ToArgb())}}
    $bitmap.Dispose();return ,$data.ToArray()
}
function Selection-PixelDiff($a,$b){$n=0;for($i=0;$i -lt $a.Length;$i++){if($a[$i] -ne $b[$i]){$n++}};return $n}

function Export-SelectionClipboard($snapshot,[string]$path) {
    # Recovery survives a crashed runner. DPAPI keeps clipboard contents local to this user.
    $records=@(foreach($format in $snapshot.GetFormats($false)){
        $data=$snapshot.GetData($format,$false)
        $kind=if($data -is [Drawing.Bitmap]){'Bitmap'}elseif($data -is [IO.MemoryStream]){'Stream'}elseif($data -is [byte[]]){'Bytes'}elseif($data -is [string[]]){'Strings'}else{'Text'}
        $value=if($kind-eq 'Bitmap'){
            $stream=[IO.MemoryStream]::new()
            try{$data.Save($stream,[Drawing.Imaging.ImageFormat]::Png);[Convert]::ToBase64String($stream.ToArray())}finally{$stream.Dispose()}
        }else{Clipboard-Fingerprint $data}
        @{Format=$format;Kind=$kind;Value=$value}
    })
    $plain=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $records -Depth 5 -Compress))
    try {
        $encrypted=[Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes($path,$encrypted)
    } finally {[Array]::Clear($plain,0,$plain.Length)}
}
function Import-SelectionClipboard([string]$path) {
    $plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try {$records=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($plain))}finally{[Array]::Clear($plain,0,$plain.Length)}
    $copy=[Windows.Forms.DataObject]::new()
    foreach($record in $records){
        $data=switch($record.Kind){
            'Bitmap' {$stream=[IO.MemoryStream]::new([Convert]::FromBase64String($record.Value));try{$bitmap=[Drawing.Bitmap]::new($stream);try{[Drawing.Bitmap]::new($bitmap)}finally{$bitmap.Dispose()}}finally{$stream.Dispose()}}
            'Stream' {[IO.MemoryStream]::new([Convert]::FromBase64String($record.Value))}
            'Bytes' {,[Convert]::FromBase64String($record.Value)}
            'Strings' {,[string[]](ConvertFrom-Json -NoEnumerate $record.Value)}
            'Text' {[string]$record.Value}
            default {throw 'Invalid encrypted clipboard snapshot kind'}
        }
        $copy.SetData($record.Format,$false,$data)
    }
    return $copy
}
function Save-SelectionClipboard([string]$RecoveryPath) {
    # Eagerly materialize every native/registered format before any selection can replace it.
    # Unknown object types fail closed, while the user's clipboard is still untouched.
    $source=[Windows.Forms.Clipboard]::GetDataObject();$copy=[Windows.Forms.DataObject]::new()
    if($source){foreach($format in $source.GetFormats($false)){
        $data=$source.GetData($format,$false)
        if($data -is [Drawing.Bitmap]){$data=$data.Clone()}
        elseif($data -is [IO.MemoryStream]){$data=[IO.MemoryStream]::new($data.ToArray())}
        elseif($data -is [byte[]] -or $data -is [string[]]){$data=$data.Clone()}
        elseif($null -ne $data -and $data -isnot [string]){throw "Clipboard format $format has unsupported type $($data.GetType().FullName); no test mutation performed"}
        if($null -eq $data){throw "Clipboard format $format could not be captured; no test mutation performed"}
        $copy.SetData($format,$false,$data)
    }}
    if(-not $RecoveryPath){throw 'Clipboard recovery path required before test mutations'}
    Export-SelectionClipboard $copy $RecoveryPath
    $roundtrip=Import-SelectionClipboard $RecoveryPath
    if($roundtrip.GetFormats($false).Count -ne $copy.GetFormats($false).Count){throw 'Clipboard recovery snapshot format count mismatch'}
    foreach($format in $copy.GetFormats($false)){
        if(-not $roundtrip.GetDataPresent($format,$false) -or (Clipboard-Fingerprint $roundtrip.GetData($format,$false)) -cne (Clipboard-Fingerprint $copy.GetData($format,$false))){throw "Clipboard recovery snapshot failed verification: $format"}
    }
    return $copy
}

function Clipboard-Fingerprint($data) {
    if($data -is [Drawing.Bitmap]) {
        # PNG codec metadata may change on decode. Compare dimensions and exact ARGB pixels.
        $rect=[Drawing.Rectangle]::new(0,0,$data.Width,$data.Height)
        $normalized=$data.Clone($rect,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $bits=$normalized.LockBits($rect,[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $bytes=[byte[]]::new($data.Width*$data.Height*4)
                for($row=0;$row-lt $data.Height;$row++){
                    [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($bits.Scan0,$row*$bits.Stride),$bytes,$row*$data.Width*4,$data.Width*4)
                }
                return "$($data.Width)x$($data.Height):$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)))"
            }finally{$normalized.UnlockBits($bits)}
        }finally{$normalized.Dispose()}
    }
    if($data -is [IO.MemoryStream]){return [Convert]::ToBase64String($data.ToArray())}
    if($data -is [byte[]]){return [Convert]::ToBase64String($data)}
    if($data -is [string[]]){return ConvertTo-Json -InputObject $data -Compress}
    if($data -is [string]){return $data}
    throw 'Unsupported clipboard value during restoration verification'
}
function Restore-SelectionClipboard($saved) {
    if($saved.GetFormats($false).Count){[Windows.Forms.Clipboard]::SetDataObject($saved,$true)}else{[Windows.Forms.Clipboard]::Clear()}
    $actual=[Windows.Forms.Clipboard]::GetDataObject()
    foreach($format in $saved.GetFormats($false)){
        if(-not $actual -or -not $actual.GetDataPresent($format,$false) -or (Clipboard-Fingerprint $actual.GetData($format,$false)) -cne (Clipboard-Fingerprint $saved.GetData($format,$false))){throw "Clipboard restoration verification failed: $format"}
    }
    if(-not $saved.GetFormats($false).Count -and $actual -and $actual.GetFormats($false).Count){throw 'Clipboard was not restored to empty'}
}
