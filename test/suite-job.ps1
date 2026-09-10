# Suspended launch before job assignment: even a failing child startup cannot escape ownership.
if(-not ('LiteSuiteJob' -as [type])){Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;using System.Threading;
public sealed class LiteSuiteJob {
 [StructLayout(LayoutKind.Sequential)] struct IO {public ulong a,b,c,d,e,f;}
 [StructLayout(LayoutKind.Sequential)] struct BASIC {public long a,b;public uint flags;public UIntPtr min,max;public uint active;public UIntPtr affinity;public uint priority,schedule;}
 [StructLayout(LayoutKind.Sequential)] struct LIMIT {public BASIC basic;public IO io;public UIntPtr a,b,c,d;}
 [StructLayout(LayoutKind.Sequential)] struct ACCOUNT {public long a,b,c,d;public uint faults,total,active,terminated;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct STARTUP {public int cb;public string reserved,desktop,title;public int x,y,w,h,xc,yc,fill,flags;public short show,reserved2;public IntPtr reservedPtr,input,output,error;}
 [StructLayout(LayoutKind.Sequential)] struct PROCESS {public IntPtr process,thread;public uint pid,tid;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr a,string n);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenJobObjectW(uint access,bool inherit,string name);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j,int c,ref LIMIT l,int n);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr j,int c,out ACCOUNT a,int n,IntPtr r);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref STARTUP si,out PROCESS pi);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
 [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
 [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr p,uint e);
 [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr j,uint e);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint ms);
 [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr p,out uint code);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 IntPtr job,process;bool assigned;
 public void Start(string name,string exe,string args,string cwd){
  if(job!=IntPtr.Zero || process!=IntPtr.Zero)throw new InvalidOperationException("Suite job already active");
  job=CreateJobObjectW(IntPtr.Zero,name);int error=Marshal.GetLastWin32Error();
  if(job==IntPtr.Zero)throw new Exception("CreateJobObject: "+error);
  if(error==183){CloseHandle(job);job=IntPtr.Zero;throw new Exception("Suite job already exists; refusing adoption");}
  var limit=new LIMIT();limit.basic.flags=0x2000;
  if(!SetInformationJobObject(job,9,ref limit,Marshal.SizeOf<LIMIT>()))throw new Exception("Job limits");
  var startup=new STARTUP{cb=Marshal.SizeOf<STARTUP>(),flags=1,show=0};PROCESS pi;
  if(!CreateProcessW(exe,new StringBuilder("\""+exe+"\" "+args),IntPtr.Zero,IntPtr.Zero,false,4|0x08000000,IntPtr.Zero,cwd,ref startup,out pi))throw new Exception("CreateProcess: "+Marshal.GetLastWin32Error());
  process=pi.process;
  try{if(!AssignProcessToJobObject(job,process))throw new Exception("AssignProcessToJobObject");assigned=true;if(ResumeThread(pi.thread)==uint.MaxValue)throw new Exception("ResumeThread");}
  finally{CloseHandle(pi.thread);}
 }
 public bool Wait(int milliseconds){if(process==IntPtr.Zero)throw new Exception("No suite process");uint r=WaitForSingleObject(process,(uint)milliseconds);if(r==0)return true;if(r==258)return false;throw new Exception("Suite wait failed");}
 public int ExitCode(){uint code;if(!GetExitCodeProcess(process,out code)||code==259)throw new Exception("Suite exit unproven");return unchecked((int)code);}
 public uint Count(){ACCOUNT a;if(!QueryInformationJobObject(job,1,out a,Marshal.SizeOf<ACCOUNT>(),IntPtr.Zero))throw new Exception("Job accounting");return a.active;}
 public void Finish(){
  if(job==IntPtr.Zero)return;
  if(process!=IntPtr.Zero && WaitForSingleObject(process,0)!=0){
   if(assigned){if(!TerminateJobObject(job,2))throw new Exception("Owned job termination failed");}
   else if(!TerminateProcess(process,2))throw new Exception("Owned suspended process termination failed");
   if(WaitForSingleObject(process,10000)!=0)throw new Exception("Owned primary process still live");
  }
  if(Count()!=0){if(!TerminateJobObject(job,2))throw new Exception("Owned descendant termination failed");for(int i=0;i<100 && Count()!=0;i++)Thread.Sleep(100);}
  if(Count()!=0)throw new Exception("Owned descendants remain; retain token");
  if(process!=IntPtr.Zero){CloseHandle(process);process=IntPtr.Zero;}CloseHandle(job);job=IntPtr.Zero;
 }
 public static bool InNamedJob(string name){var j=OpenJobObjectW(4,false,name);if(j==IntPtr.Zero)return false;try{bool result;return IsProcessInJob(GetCurrentProcess(),j,out result)&&result;}finally{CloseHandle(j);}}
}
'@}
