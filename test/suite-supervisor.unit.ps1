param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$artifact=Join-Path ([IO.Path]::GetTempPath()) ('lite-supervisor-unit-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifact|Out-Null
$cases=@(
    @{name='success';code=0;start=2;release=1;delete=1},
    @{name='test-fail';code=1;start=2;release=1;delete=1},
    @{name='unsafe';code=2;start=1;release=0;delete=1},
    @{name='deadline';code=2;start=1;release=0;delete=1},
    @{name='job-fail';code=2;start=1;release=0;delete=0},
    @{name='registry-fail';code=2;start=2;release=0;delete=1},
    @{name='marker-fail';code=2;start=0;release=0;delete=0},
    @{name='acquire-fail';code=1;start=0;release=0;delete=0},
    @{name='receipt-fail';code=1;start=0;release=1;delete=0}
)
foreach($case in $cases){
    $dir=Join-Path $artifact $case.name;New-Item -ItemType Directory -Path $dir|Out-Null
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-File',"$PSScriptRoot/suite-supervisor-fixture.ps1",'-Case',$case.name,'-Artifact',$dir)){$start.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit(15000)){throw 'Mock supervisor deadline exceeded'}
        $calls=@(Get-Content -LiteralPath (Join-Path $dir 'calls.json') -Raw|ConvertFrom-Json)
        if($child.ExitCode-ne $case.code -or @($calls|Where-Object {$_-eq 'start'}).Count-ne $case.start -or
           @($calls|Where-Object {$_-eq 'release'}).Count-ne $case.release -or @($calls|Where-Object {$_-eq 'delete-key'}).Count-ne $case.delete){throw "Wrong supervisor result $($case.name): exit=$($child.ExitCode); calls=$calls; stdout=$($stdout.Result); stderr=$($stderr.Result)"}
        if($case.start -and ($calls.IndexOf('receipt')-lt 0 -or $calls.IndexOf('receipt')-gt $calls.IndexOf('create-key'))){throw 'Mutation preceded receipt'}
        "PASS supervisor $($case.name): starts=$($case.start), release=$($case.release), exit=$($case.code)"
    }finally{if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(5000)};$child.Dispose()}
}
"Supervisor: $($cases.Count) private fault scenarios passed; fake lease/registry/jobs only; artifacts $artifact"
