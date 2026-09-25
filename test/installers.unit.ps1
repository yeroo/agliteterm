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
Check 'Codex skipped without existing directory' ($r.result.Contains('Codex hooks skipped') -and -not(Test-Path (Join-Path $user '.codex/hooks.json')) -and -not $r.result.Contains('notify = ['))
Check 'legacy Codex notify script still copied' (Test-Path (Join-Path $data 'agliteterm-codex-notify.ps1'))
$saved=[IO.File]::ReadAllText($settings);$profileSaved=[IO.File]::ReadAllText($profile)
$r=Install hooks
Check 'hooks install idempotent' ($r.ok -and [IO.File]::ReadAllText($settings)-ceq$saved -and [IO.File]::ReadAllText($profile)-ceq$profileSaved)
foreach($bad in @('{broken','[]','{"hooks":false}','{"hooks":{"Stop":"not-array"}}','{"unrelated":1,"unrelated":2}','{"unrelated":{"X":1,"x":2}}','{"key":1,"\u006bey":2}',
    '{"hooks":{"Stop":[{"hooks":"not-an-array"}]}}','{"hooks":{"Stop":[false]}}','{"hooks":{"Stop":[{"matcher":false,"hooks":[]}]}}',
    '{"hooks":{"Stop":[{"hooks":["command"]}]}}','{"hooks":{"Stop":[{"hooks":[{"type":"command","command":false}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"bogus"}]}]}}','{"hooks":{"Stop":[{"hooks":[{"type":"http"}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"prompt"}]}]}}','{"hooks":{"Stop":[{"hooks":[{"type":"agent","prompt":false}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"mcp_tool","server":"s"}]}]}}','{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x","args":[1]}]}]}}')){
    [IO.File]::WriteAllText($settings,$bad)
    $r=Install hooks
    Check 'malformed settings refuse without profile/settings change' (-not$r.ok -and $installExit-ne 0 -and [IO.File]::ReadAllText($settings)-ceq$bad -and [IO.File]::ReadAllText($profile)-ceq$profileSaved)
}
[IO.File]::WriteAllText($settings,$saved)
$wrongCase=@(
    '{"Hooks":{}}','{"hooks":{"stop":[]}}','{"hooks":{"Stop":[{"Hooks":[]}]}}',
    '{"hooks":{"Stop":[{"Matcher":"x","hooks":[]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"Type":"command","Command":"keep-me"}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"command","Command":"keep-me"}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep-me","Timeout":10}]}]}}'
)
foreach($bad in $wrongCase){
    [IO.File]::WriteAllText($settings,$bad)
    $before=@(Get-ChildItem $data -File|ForEach-Object {$_.Name+':'+(Get-FileHash $_.FullName).Hash}) -join ';'
    $r=Install hooks
    $after=@(Get-ChildItem $data -File|ForEach-Object {$_.Name+':'+(Get-FileHash $_.FullName).Hash}) -join ';'
    Check 'wrong-case hook fields refuse before any destination write' (-not$r.ok -and $installExit-ne 0 -and $r.error-match'Wrong-case' -and [IO.File]::ReadAllText($settings)-ceq$bad -and [IO.File]::ReadAllText($profile)-ceq$profileSaved -and $before-ceq$after -and $r.error.EndsWith('completed writes: '))
}
[IO.File]::WriteAllText($settings,$saved)
$variants='{"hooks":{"Stop":[{"hooks":[{"type":"http","url":"https://example.invalid/hook","headers":{"X":"v"}},{"type":"mcp_tool","server":"local","tool":"check","input":{"x":1}},{"type":"prompt","prompt":"check","model":"unchanged"},{"type":"agent","prompt":"check","timeout":15}]}]}}'
[IO.File]::WriteAllText($settings,$variants);$r=Install hooks
$kept=Get-Content -Raw $settings|ConvertFrom-Json
Check 'all documented non-command hook variants survive unchanged' ($r.ok -and $kept.hooks.Stop[0].hooks.Count-eq 4 -and $kept.hooks.Stop[0].hooks[1].input.x-eq 1 -and $kept.hooks.Stop[0].hooks[2].model-eq'unchanged')
[IO.File]::WriteAllText($settings,$saved)
$scoped=$saved|ConvertFrom-Json
$scoped.hooks.Notification[0].matcher='idle_prompt'
[IO.File]::WriteAllText($settings,($scoped|ConvertTo-Json -Depth 100))
$r=Install hooks;$scoped=Get-Content -Raw $settings|ConvertFrom-Json
Check 'same hook command with other matcher does not suppress permission hook' ($r.ok -and @($scoped.hooks.Notification|Where-Object matcher -eq 'permission_prompt').Count-eq 1 -and @($scoped.hooks.Notification|Where-Object matcher -eq 'idle_prompt').Count-eq 1)
# Independent dated catalog: correct spelling survives; every case-only event alias refuses.
$events=@('SessionStart','Setup','UserPromptSubmit','UserPromptExpansion','PreToolUse','PermissionRequest','PermissionDenied','PostToolUse','PostToolUseFailure','PostToolBatch','Notification','MessageDisplay','SubagentStart','SubagentStop','TaskCreated','TaskCompleted','Stop','StopFailure','TeammateIdle','InstructionsLoaded','ConfigChange','CwdChanged','DirectoryAdded','FileChanged','WorktreeCreate','WorktreeRemove','PreCompact','PostCompact','PreModelSwitch','PostModelSwitch','Elicitation','ElicitationResult','SessionEnd')
$catalog=[ordered]@{}
foreach($event in $events){$catalog[$event]=@(@{hooks=@(@{type='command';command='keep-'+$event;args=@();shell='powershell';async=$false;asyncRewake=$false;once=$false;timeout=1.5;statusMessage='keep';extension=@{payload=@(1,'x')}})})}
$catalog['FutureExtensionEvent']=@(@{hooks=@(@{type='command';command='future';futureField=@{n=2}})})
$validCatalog=@{hooks=$catalog;extensionRoot=@{nested='unchanged'}}|ConvertTo-Json -Depth 100
[IO.File]::WriteAllText($settings,$validCatalog);$r=Install hooks
$kept=Get-Content -Raw $settings|ConvertFrom-Json
Check 'all 33 dated event spellings and unknown extensions survive' ($r.ok -and @($events|Where-Object {$kept.hooks.$_[0].hooks[0].command-cne ('keep-'+$_)}).Count-eq 0 -and $kept.hooks.FutureExtensionEvent[0].hooks[0].futureField.n-eq 2 -and $kept.extensionRoot.nested-eq 'unchanged')
$profileBefore=[IO.File]::ReadAllText($profile)
$catalogBad=@($events|ForEach-Object {'{"hooks":{"'+$_.ToLowerInvariant()+'":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}'})
$catalogBad+=@(
    '{"hooks":{"PreToolUse":[{"hooks":[{"type":"prompt","prompt":"p","ContinueOnBlock":true}]}]}}',
    '{"hooks":{"PreToolUse":[{"hooks":[{"type":"prompt","prompt":"p","continueOnBlock":"true"}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"agent","prompt":"p","continueOnBlock":true}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"prompt","prompt":"p","async":true}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"http","url":"u","command":"c"}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"c","model":"m"}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"mcp_tool","server":"s","tool":"t","headers":{}}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"c","timeout":true}]}]}}',
    '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"c","timeout":-1}]}]}}',
    '{"hooks":{"SessionStart":[{"hooks":[{"type":"http","url":"u"}]}]}}',
    '{"hooks":{"Notification":[{"hooks":[{"type":"prompt","prompt":"p"}]}]}}'
)
foreach($bad in $catalogBad){
    [IO.File]::WriteAllText($settings,$bad)
    # Force a real pending helper update. Already-current destinations cannot detect a
    # misplaced helper-copy loop that runs before validation but happens to be a no-op.
    [IO.File]::WriteAllText((Join-Path $data 'agliteterm-agent-status.ps1'),'# deliberately stale private helper')
    # Include backup files and all helper destinations, not just the profile/settings originals.
    $before=@(Get-ChildItem $root -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash})-join ';'
    $r=Install hooks
    $after=@(Get-ChildItem $root -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash})-join ';'
    Check 'catalog case/type/applicability refusal precedes every destination write' (-not $r.ok -and $installExit-ne 0 -and $before-ceq $after -and $r.error.EndsWith('completed writes: '))
}
$validPrompt='{"hooks":{"PreToolUse":[{"hooks":[{"type":"prompt","prompt":"keep","continueOnBlock":true,"model":"m","timeout":2,"futureFlag":{"unchanged":false}}]}],"SessionStart":[{"hooks":[{"type":"mcp_tool","server":"s","tool":"t","input":{"anything":[1,true]}}]}]}}'
[IO.File]::WriteAllText($settings,$validPrompt);$r=Install hooks;$kept=Get-Content -Raw $settings|ConvertFrom-Json
Check 'positive install really updates the helper held stale by rejection cases' ([IO.File]::ReadAllText((Join-Path $data 'agliteterm-agent-status.ps1'))-cne '# deliberately stale private helper')
Check 'prompt continueOnBlock and MCP startup handler preserve their fields' ($r.ok -and $kept.hooks.PreToolUse[0].hooks[0].continueOnBlock -eq $true -and $kept.hooks.PreToolUse[0].hooks[0].futureFlag.unchanged-eq $false -and $kept.hooks.SessionStart[0].hooks[0].input.anything.Count-eq 2)
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
$codexDir=Join-Path $user '.codex';New-Item -ItemType Directory $codexDir|Out-Null
$codexPath=Join-Path $codexDir 'hooks.json'
$codexWrapper=Join-Path $data 'agliteterm-codex-hook.ps1'
$codexCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$codexWrapper+'" '
$seed='{"custom":{"keep":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep-me"},{"type":"mcp_tool","server":"local","tool":"check","input":{"x":1}}]}],"Interrupt":[{"hooks":[{"type":"command","commandWindows":"keep-win","futureField":42}]}],"FutureEvent":[{"hooks":[{"type":"future","extension":true}]}]}}'
[IO.File]::WriteAllText($codexPath,$seed)
$r=Install hooks;$codexTree=Get-Content -Raw $codexPath|ConvertFrom-Json
Check 'Codex hooks install in existing directory and summary explains trust' ($r.ok -and $r.result.Contains($codexPath) -and $r.result.Contains('/hooks') -and -not $r.result.Contains('notify = [') -and -not(Test-Path (Join-Path $codexDir 'config.toml')))
$expected=@{UserPromptSubmit='active';PostToolUse='active';PermissionRequest='blocked';Stop='stop'}
foreach($event in $expected.Keys){
    $matches=@($codexTree.hooks.$event|Where-Object {-not $_.PSObject.Properties['matcher']}|ForEach-Object {$_.hooks}|Where-Object {$_.type-ceq'command' -and $_.command -ceq ($codexCommand+$expected[$event])})
    Check "Codex $event installs exact matcher-less command" ($matches.Count-eq 1)
}
Check 'Codex root, user handlers, other events and extensions preserved' ($codexTree.custom.keep -and $codexTree.hooks.Stop[0].hooks[0].command-eq'keep-me' -and $codexTree.hooks.Stop[0].hooks[1].input.x-eq 1 -and $codexTree.hooks.Interrupt[0].hooks[0].commandWindows-eq'keep-win' -and $codexTree.hooks.FutureEvent[0].hooks[0].extension)
$codexBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($codexPath));$codexBackups=@(Get-ChildItem $codexDir -Filter '*.bak').Count
$r=Install hooks
Check 'Codex hooks install is byte-idempotent without backup' ($r.ok -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($codexPath))-ceq$codexBytes -and @(Get-ChildItem $codexDir -Filter '*.bak').Count-eq$codexBackups)
$matcherSeed=@{hooks=@{Stop=@(@{matcher='';hooks=@(@{type='command';command=$codexCommand+'stop'})});PostToolUse=@(@{matcher='*';hooks=@(@{type='command';command=$codexCommand+'active'})})}}|ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($codexPath,$matcherSeed);$r=Install hooks;$codexTree=Get-Content -Raw $codexPath|ConvertFrom-Json
Check 'Codex empty and star match-all groups do not duplicate status hooks' ($r.ok -and $codexTree.hooks.Stop.Count-eq 1 -and $codexTree.hooks.PostToolUse.Count-eq 1)
$codexBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($codexPath));$r=Install hooks
Check 'Codex match-all merge remains byte-idempotent' ($r.ok -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($codexPath))-ceq$codexBytes)
$scopedCodex=@{hooks=@{PostToolUse=@(@{matcher='Bash';hooks=@(@{type='command';command=$codexCommand+'active'})})}}|ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($codexPath,$scopedCodex);$r=Install hooks;$codexTree=Get-Content -Raw $codexPath|ConvertFrom-Json
Check 'scoped Codex command does not suppress match-all status hook' ($r.ok -and $codexTree.hooks.PostToolUse.Count-eq 2)
$codexBad=@('{broken','[]','{"hooks":false}','{"hooks":{"Stop":"bad"}}','{"hooks":{"Stop":[false]}}','{"hooks":{"Stop":[{"hooks":false}]}}','{"hooks":{"Stop":[{"matcher":false,"hooks":[]}]}}','{"hooks":{"Stop":[{"hooks":[false]}]}}','{"hooks":{"Stop":[{"hooks":[{"type":false}]}]}}','{"a":1,"a":2}','{"a":1,"A":2}','{"key":1,"\u006bey":2}','{"hooks":{"stop":[]}}','{"Hooks":{}}','{"hooks":{"Stop":[{"Hooks":[]}]}}','{"hooks":{"Stop":[{"hooks":[{"Type":"command"}]}]}}','{"hooks":{"Stop":[{"hooks":[{"type":"command","CommandWindows":"alias"}]}]}}')
foreach($bad in $codexBad){
    [IO.File]::WriteAllText($codexPath,$bad)
    [IO.File]::WriteAllText((Join-Path $data 'agliteterm-codex-hook.ps1'),'# deliberately stale private helper')
    [IO.File]::WriteAllText((Join-Path $data 'agliteterm-agent-status.ps1'),'# deliberately stale private helper')
    $before=@(Get-ChildItem $root -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash})-join ';'
    $r=Install hooks
    $after=@(Get-ChildItem $root -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash})-join ';'
    Check 'malformed Codex hooks refuse every destination write' (-not $r.ok -and $installExit-ne 0 -and $r.error-match'Codex' -and $before-ceq$after -and $r.error.EndsWith('completed writes: '))
}
[IO.File]::WriteAllText($codexPath,$seed);$r=Install hooks
Check 'valid Codex install refreshes helpers after refusals' ($r.ok -and [IO.File]::ReadAllText((Join-Path $data 'agliteterm-codex-hook.ps1'))-cne'# deliberately stale private helper')
"installers-unit: $checks checks, $failures failed; isolated files retained at $root; no shared profile/registry changes"
if($failures){throw 'installer unit checks failed'}
exit 0 # Negative helper cases intentionally returned nonzero; do not leak their exit into run-all.
