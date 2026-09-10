# Discover only the exact still-live launched process's frame, including a hidden startup window.
if(-not ('LiteOwnedFrame' -as [type])){Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class LiteOwnedFrame {
 delegate bool Callback(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(Callback c,IntPtr p);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
 public static IntPtr Find(int pid) {
  IntPtr found=IntPtr.Zero;
  EnumWindows((h,l)=>{uint p;GetWindowThreadProcessId(h,out p);if(p!=(uint)pid)return true;
   var name=new StringBuilder(128);if(GetClassNameW(h,name,name.Capacity)>0 && name.ToString()=="AgwintermLite"){found=h;return false;}return true;},IntPtr.Zero);
  return found;
 }
}
'@}
function Get-OwnedLiteWindow([Diagnostics.Process]$Process,[switch]$Show) {
    [void]$Process.SafeHandle
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        if($Process.HasExited){throw 'Owned Lite process exited before frame discovery'}
        $window=[LiteOwnedFrame]::Find($Process.Id)
        if($window-ne [IntPtr]::Zero){
            if($Process.HasExited){throw 'Owned Lite process exited during frame discovery'}
            if($Show){[void][LiteOwnedFrame]::ShowWindow($window,4)} # SW_SHOWNOACTIVATE, never foreground
            return $window
        }
        Start-Sleep -Milliseconds 100
    }while($watch.ElapsedMilliseconds-lt 15000)
    throw 'Owned Lite frame was not created before the deadline'
}
