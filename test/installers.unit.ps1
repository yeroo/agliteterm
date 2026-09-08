param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('agliteterm-install-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root|Out-Null
$data=Join-Path $root 'data';$user=Join-Path $root 'user';$profile=Join-Path $root 'documents/profile.ps1'
New-Item -ItemType Directory (Split-Path $profile), (Join-Path $user '.claude')|Out-Null
$helper=Join-Path (Split-Path $PSScriptRoot -Parent) 'assets/agliteterm-install.ps1'
$shell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$settings=Join-Path $user '.claude/settings.json'
$checks=0;$failures=0
function Check([string]$Name,[bool]$Ok){$script:checks++;if($Ok){"PASS $Name"}else{$script:failures++;"FAIL $Name"}}
function Install([string]$Op){
    $reply=& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Operation $Op -DataRoot $data -UserRoot $user -ProfilePath $profile
    $script:installExit=$LASTEXITCODE
    try {return ($reply|ConvertFrom-Json -ErrorAction Stop)}catch{throw "Installer did not return JSON: $reply"}
}
[IO.File]::WriteAllText($profile,"# user profile 雪`r`nfunction prompt { 'mine> ' }`r`n",[Text.UTF8Encoding]::new($true))
$original=[IO.File]::ReadAllText($profile)
[IO.File]::WriteAllText($settings,'{"theme":"dark","permissionMode":"default","hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}')
$r=Install shell
Check 'shell installer succeeds' ($r.ok -and $installExit-eq 0)
Check 'shell install preserves original text and adds product scope' ([IO.File]::ReadAllText($profile).StartsWith($original) -and [IO.File]::ReadAllText($profile).Contains("TERM_PROGRAM -eq 'agliteterm'"))
$bytes=[IO.File]::ReadAllBytes($profile);$backups=@(Get-ChildItem (Split-Path $profile) -Filter '*.bak').Count
$r=Install shell
Check 'shell installer idempotent, no extra backup' ($r.ok -and [Convert]::ToBase64String($bytes)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes($profile)) -and @(Get-ChildItem (Split-Path $profile) -Filter '*.bak').Count-eq$backups)
Check 'first backup retains original UTF8 BOM' (@(Get-ChildItem (Split-Path $profile) -Filter '*.bak' | Where-Object {[IO.File]::ReadAllBytes($_.FullName)[0]-eq239}).Count-eq 1)
$r=Install hooks
Check 'hooks installer succeeds' ($r.ok -and $installExit-eq 0)
$json=Get-Content -Raw $settings|ConvertFrom-Json
Check 'hooks preserve settings and unrelated command' ($json.theme-eq'dark' -and $json.permissionMode-eq'default' -and $json.hooks.Stop[0].hooks[0].command-eq'keep-me')
Check 'all four status events installed' (@($json.hooks.PSObject.Properties).Count-eq 4 -and $json.hooks.Notification[0].matcher-eq'permission_prompt')
Check 'Codex config only suggested, never created' ($r.result.Contains('notify = [') -and -not(Test-Path (Join-Path $user '.codex/config.toml')))
$line=($r.result -split 'notify = ',2)[1];$argv=$line|ConvertFrom-Json
Check 'suggested notify command has complete argv' ($argv.Count-eq6 -and $argv[0]-eq'powershell.exe' -and $argv[5]-eq(Join-Path $data 'agliteterm-codex-notify.ps1'))
$saved=[IO.File]::ReadAllText($settings);$profileSaved=[IO.File]::ReadAllText($profile)
$r=Install hooks
Check 'hooks install idempotent' ($r.ok -and [IO.File]::ReadAllText($settings)-ceq$saved -and [IO.File]::ReadAllText($profile)-ceq$profileSaved)
foreach($bad in @('{broken','[]','{"hooks":false}','{"hooks":{"Stop":"not-array"}}','{"unrelated":1,"unrelated":2}','{"unrelated":{"X":1,"x":2}}','{"key":1,"\u006bey":2}',
    '{"hooks":{"Stop":[{"hooks":"not-an-array"}]}}','{"hooks":{"Stop":[false]}}','{"hooks":{"Stop":[{"matcher":false,"hooks":[]}]}}',
    '{"hooks":{"Stop":[{"hooks":["command"]}]}}','{"hooks":{"Stop":[{"hooks":[{"type":"command","command":false}]}]}}')){
    [IO.File]::WriteAllText($settings,$bad)
    $r=Install hooks
    Check 'malformed settings refuse without profile/settings change' (-not$r.ok -and $installExit-ne 0 -and [IO.File]::ReadAllText($settings)-ceq$bad -and [IO.File]::ReadAllText($profile)-ceq$profileSaved)
}
[IO.File]::WriteAllText($settings,$saved)
$scoped=$saved|ConvertFrom-Json
$scoped.hooks.Notification[0].matcher='idle_prompt'
[IO.File]::WriteAllText($settings,($scoped|ConvertTo-Json -Depth 100))
$r=Install hooks;$scoped=Get-Content -Raw $settings|ConvertFrom-Json
Check 'same hook command with other matcher does not suppress permission hook' ($r.ok -and @($scoped.hooks.Notification|Where-Object matcher -eq 'permission_prompt').Count-eq 1 -and @($scoped.hooks.Notification|Where-Object matcher -eq 'idle_prompt').Count-eq 1)
[IO.File]::WriteAllText($settings,$saved)
foreach($bad in @('# >>> agliteterm hooks >>>', '# <<< agliteterm hooks <<<', "# >>> agliteterm hooks >>>`n# >>> agliteterm hooks >>>`n# <<< agliteterm hooks <<<")){
    [IO.File]::WriteAllText($profile,$bad)
    $r=Install hooks
    Check 'corrupt profile sentinels refuse without mutation' (-not$r.ok -and [IO.File]::ReadAllText($profile)-ceq$bad -and [IO.File]::ReadAllText($settings)-ceq$saved)
}
foreach($example in @("`$example = '# >>> agliteterm hooks >>>'; `$other = '# <<< agliteterm hooks <<<'", "`$example = @'`n# >>> agliteterm hooks >>>`nimportant user text`n# <<< agliteterm hooks <<<`n'@")){
    [IO.File]::WriteAllText($profile,$example)
    $r=Install hooks
    Check 'quoted and here-string marker examples survive installation' ($r.ok -and [IO.File]::ReadAllText($profile).StartsWith($example))
    $preserved=[IO.File]::ReadAllText($profile);$r=Install hooks
    Check 'real sentinel refresh preserves marker examples and is idempotent' ($r.ok -and [IO.File]::ReadAllText($profile)-ceq$preserved)
}
"installers-unit: $checks checks, $failures failed; isolated files retained at $root; no shared profile/registry changes"
if($failures){throw 'installer unit checks failed'}
exit 0 # Negative helper cases intentionally returned nonzero; do not leak their exit into run-all.
