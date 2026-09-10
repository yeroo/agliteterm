# Atomically create a fresh per-run key; opening an existing namespace is never ownership.
if(-not ('LiteSuiteRegistry' -as [type])){Add-Type @'
using System;using System.Runtime.InteropServices;using Microsoft.Win32;using Microsoft.Win32.SafeHandles;
public static class LiteSuiteRegistry {
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegCreateKeyExW(IntPtr h,string name,int reserved,string cls,int options,int access,IntPtr sa,out IntPtr result,out int disposition);
 [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr h);
 public static RegistryKey Create(string run){
  if(!System.Text.RegularExpressions.Regex.IsMatch(run??"",@"\A[0-9a-f]{32}\z"))throw new ArgumentException("Invalid test registry run");
  IntPtr key;int disposition;
  int result=RegCreateKeyExW(new IntPtr(unchecked((int)0x80000001)),"Software\\agliteterm-tests\\"+run,0,null,0,0xF003F,IntPtr.Zero,out key,out disposition);
  if(result!=0)throw new InvalidOperationException("Private registry creation failed: "+result);
  if(disposition!=1){RegCloseKey(key);throw new InvalidOperationException("Test registry namespace already exists; refusing adoption");}
  return RegistryKey.FromHandle(new SafeRegistryHandle(key,true));
 }
}
'@}
