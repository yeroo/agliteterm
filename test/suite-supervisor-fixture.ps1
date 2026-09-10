# Executes the real supervisor control flow with mocked resource boundaries. No real lease/HKCU/job.
param([string]$Case,[string]$Artifact)
$ErrorActionPreference='Stop'
Add-Type @'
using System;using System.Collections.Generic;
public static class SuiteFake {
 public static string Case,Owner;public static List<string> Calls=new List<string>();
 public static void Note(string s){Calls.Add(s);}
}
public sealed class FakeSuiteJob {
 public void Start(string n,string e,string a,string c){SuiteFake.Note("start");}
 public bool Wait(int n){if(SuiteFake.Case=="deadline")throw new Exception("injected deadline");return true;}
 public int ExitCode(){return SuiteFake.Case=="unsafe"?2:SuiteFake.Case=="test-fail"?1:0;}
 public void Finish(){SuiteFake.Note("finish");if(SuiteFake.Case=="job-fail")throw new Exception("injected job cleanup failure");}
}
public sealed class FakeSuiteKey {
 public void SetValue(string n,string v,object kind){if(SuiteFake.Case=="marker-fail")throw new Exception("injected marker failure");SuiteFake.Owner=v;}
 public object GetValue(string n){return SuiteFake.Owner;}
 public void Dispose(){}
}
public static class FakeSuiteRegistry {
 public static FakeSuiteKey Create(string run){SuiteFake.Note("create-key");return new FakeSuiteKey();}
}
public sealed class FakeRegistryRoot {
 public FakeSuiteKey OpenSubKey(string n){return new FakeSuiteKey();}
 public void DeleteSubKeyTree(string n,bool ignored){SuiteFake.Note("delete-key");if(SuiteFake.Case=="registry-fail")throw new Exception("injected registry failure");}
}
'@
[SuiteFake]::Case=$Case;$fakeRegistry=[FakeRegistryRoot]::new()
$fixtureRoot=Join-Path $Artifact 'test';New-Item -ItemType Directory -Path $fixtureRoot|Out-Null
$dummy=Join-Path $Artifact 'dummy.exe';[IO.File]::WriteAllText($dummy,'not executable')
function Get-CtlPath {return $dummy}
. "$PSScriptRoot/suite-policy.ps1"
function Test-Path {
    [CmdletBinding()]param([Parameter(Position=0)][string]$Path,[string]$LiteralPath)
    if(($Path+$LiteralPath)-eq 'C:/Users/boris/AI/bin/suite-token.py'){return $true}
    if($LiteralPath){return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}
    return Microsoft.PowerShell.Management\Test-Path -Path $Path
}
function python {
    [SuiteFake]::Note([string]$args[1]);$global:LASTEXITCODE=0
    if($args[1]-eq 'acquire'){
        if($Case-eq 'acquire-fail'){$global:LASTEXITCODE=1;return '{"ok":false}'}
        return '{"ok":true,"owner":"fake-owner","token":"fake-token"}'
    }
    return '{"ok":true}'
}
function Set-Content {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$Value,[string]$LiteralPath)
    process{
        if($LiteralPath.EndsWith('lease.json')){[SuiteFake]::Note('receipt');if($Case-eq 'receipt-fail'){throw 'injected receipt failure'}}
        Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value
    }
}
$source=Get-Content -LiteralPath "$PSScriptRoot/run-all.ps1" -Raw
# Substitute only external boundaries; the try/finally, scheduling and release conditions stay real.
$source=$source.Replace('$PSScriptRoot','$fixtureRoot').Replace('[LiteSuiteJob]','[FakeSuiteJob]').Replace('[LiteSuiteRegistry]','[FakeSuiteRegistry]').Replace('[Microsoft.Win32.Registry]::CurrentUser','$fakeRegistry')
$source=$source -replace '(?m)^\s*\. "\$fixtureRoot/(suite-job|suite-registry|ctl-path|suite-policy)\.ps1"\s*$',''
$source=$source -replace '(?m)^\s*& "\$fixtureRoot/build-suite-ctl\.ps1" -Output \$artifact\s*$',''
$env:AGLITETERM_TEST_RUN=$null;$env:AI_HUB=$null
try {& ([scriptblock]::Create($source)) -Exe $dummy -TokenOwner fake-owner -Suite @('targeting.unit','paste.unit')}
finally{[IO.File]::WriteAllText((Join-Path $Artifact 'calls.json'),([SuiteFake]::Calls|ConvertTo-Json -Compress))}
