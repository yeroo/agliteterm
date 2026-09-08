param(
    [Parameter(Mandatory)][ValidateSet('cli','hooks','shell')][string]$Operation,
    [switch]$Remove,
    [string]$DataRoot=(Join-Path $env:LOCALAPPDATA 'agliteterm'),
    [string]$UserRoot=[Environment]::GetFolderPath('UserProfile'),
    [string]$ProfilePath=$PROFILE.CurrentUserCurrentHost,
    [string]$EnvironmentKey='Environment',
    [string]$CliDir=$PSScriptRoot
)
# Path overrides are for direct isolated fixture invocation, never accepted over the control API.
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$utf8=New-Object Text.UTF8Encoding($false,$true)
$changed=New-Object Collections.Generic.List[string]
function Read-InstallText([string]$Path){
    if(-not [IO.File]::Exists($Path)){return ''}
    $reader=New-Object IO.StreamReader($Path,$utf8,$true)
    try{$reader.ReadToEnd()}finally{$reader.Dispose()}
}
function Set-InstallText([string]$Path,[string]$Text,[string]$Expected){
    $full=[IO.Path]::GetFullPath($Path)
    if([IO.File]::Exists($full) -and (Read-InstallText $full) -ceq $Text){return}
    $parent=[IO.Path]::GetDirectoryName($full)
    for($part=$parent;$part;$part=[IO.Path]::GetDirectoryName($part)){
        if([IO.Directory]::Exists($part) -and ([IO.File]::GetAttributes($part)-band [IO.FileAttributes]::ReparsePoint)){throw "Refusing reparse-point destination: $part"}
    }
    if([IO.File]::Exists($full) -and ([IO.File]::GetAttributes($full)-band [IO.FileAttributes]::ReparsePoint)){throw "Refusing reparse-point destination: $full"}
    if((Read-InstallText $full) -cne $Expected){throw "File changed during install: $full"}
    [IO.Directory]::CreateDirectory($parent)|Out-Null
    $tmp=$full+'.agliteterm-'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($tmp,$Text,$utf8)
        if([IO.File]::Exists($full)){
            $backup=$full+'.agliteterm-'+[guid]::NewGuid().ToString('N')+'.bak'
            [IO.File]::Replace($tmp,$full,$backup)
            $changed.Add("$full (backup $backup)")
        }else{[IO.File]::Move($tmp,$full);$changed.Add($full)}
    }finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
function Add-InstallBlock([string]$Existing,[string]$Label,[string]$Body){
    $begin='# >>> agliteterm '+$Label+' >>>';$end='# <<< agliteterm '+$Label+' <<<'
    # Only real comment tokens are sentinels. Quoted examples and here-strings are user data.
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($Existing,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Profile has parse errors; file unchanged'}
    $starts=@($tokens|Where-Object {$_.Kind-eq'Comment' -and $_.Text-ceq$begin})
    $ends=@($tokens|Where-Object {$_.Kind-eq'Comment' -and $_.Text-ceq$end})
    $first=if($starts.Count){$starts[0].Extent.StartOffset}else{-1}
    $last=if($ends.Count){$ends[0].Extent.StartOffset}else{-1}
    $block=$begin+"`r`n"+$Body+"`r`n"+$end
    if($first -lt 0 -and $last -lt 0){return $Existing+$(if($Existing){"`r`n`r`n"}else{''})+$block+"`r`n"}
    if($starts.Count-ne 1 -or $ends.Count-ne 1 -or $last-lt$first){throw "Corrupt or duplicate $Label profile block; file unchanged"}
    return $Existing.Substring(0,$first)+$block+$Existing.Substring($last+$end.Length)
}
function Test-InstallJsonShape([string]$Text){
    if($Text.Length -gt 1048576){throw 'Claude settings exceeds 1 MiB; unchanged'}
    # ConvertFrom-Json collapses duplicate keys (including case-only collisions in PS 5.1).
    # Detect them before conversion and cap nesting below ConvertTo-Json's output depth.
    $stack=New-Object Collections.Generic.Stack[object]
    foreach($match in [regex]::Matches($Text,'"(?:\\.|[^"\\])*"|[{}\[\],]')){
        $part=$match.Value
        if($part -eq '{' -or $part -eq '['){
            if($stack.Count -ge 64){throw 'Claude settings nesting exceeds 64; unchanged'}
            $stack.Push(@{Object=($part-eq'{');Key=($part-eq'{');Names=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))})
        }elseif($part -eq '}' -or $part -eq ']'){if($stack.Count){$null=$stack.Pop()}}
        elseif($stack.Count){
            $frame=$stack.Peek()
            if($part -eq ','){$frame.Key=$frame.Object}
            elseif($frame.Object -and $frame.Key -and $part.StartsWith('"')){
                $key=$part|ConvertFrom-Json -ErrorAction Stop
                if(-not $frame.Names.Add($key)){throw "Duplicate/case-colliding Claude settings key '$key'; unchanged"}
                $frame.Key=$false
            }
        }
    }
}
$mutex=New-Object Threading.Mutex($false,'Local\agliteterm-opt-in-install')
$locked=$false
try {
    $locked=$mutex.WaitOne(0);if(-not $locked){throw 'Another agliteterm installer is running'}
    if($Operation -eq 'cli'){
        if(-not $Remove -and -not [IO.File]::Exists((Join-Path $CliDir 'agwintermctl.exe'))){throw 'agwintermctl.exe is not beside this build; PATH unchanged'}
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($EnvironmentKey)
        try {
            $raw=$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if($raw -isnot [string]){throw 'User Path is not a string; unchanged'}
            $kind=if($key.GetValueNames()-contains'Path'){$key.GetValueKind('Path')}else{[Microsoft.Win32.RegistryValueKind]::ExpandString}
            if($kind -notin [Microsoft.Win32.RegistryValueKind]::String,[Microsoft.Win32.RegistryValueKind]::ExpandString){throw 'Unsupported Path kind; unchanged'}
            $parts=@($raw.Split(';'));$dir=[IO.Path]::GetFullPath($CliDir).TrimEnd('\','/')
            $matching=@($parts|Where-Object {$_.Trim().Trim('"').TrimEnd('\','/') -ieq $dir})
            $next=$raw
            if($Remove){$next=(@($parts|Where-Object {$_.Trim().Trim('"').TrimEnd('\','/') -ine $dir})-join ';')}
            elseif(-not $matching.Count){$next=$raw+$(if($raw -and -not $raw.EndsWith(';')){';'}else{''})+$dir}
            if($next -cne $raw){$key.SetValue('Path',$next,$kind);$changed.Add('HKCU\'+$EnvironmentKey+'\Path')}
        }finally{$key.Dispose()}
        @{ok=$true;result="CLI PATH $(if($Remove){'removal'}else{'installation'}) complete; open a new shell. Changed: $($changed -join ', ')"}|ConvertTo-Json -Compress
    }else{
        if($Remove){throw 'Removal is supported only for install.cli'}
        $profile=Read-InstallText $ProfilePath;$next=$profile
        $scripts=if($Operation -eq 'shell'){@('agliteterm-shell.ps1')}else{@('agliteterm-agent-status.ps1','agliteterm-codex-notify.ps1','agliteterm-claude.ps1','agliteterm-generic-agent.ps1')}
        $sources=@{}
        foreach($script in $scripts){$sources[$script]=Read-InstallText (Join-Path $PSScriptRoot $script);if(-not $sources[$script]){throw "Missing bundled helper $script"}}
        $loads=if($Operation -eq 'shell'){@('agliteterm-shell.ps1')}else{@('agliteterm-claude.ps1','agliteterm-generic-agent.ps1')}
        $body="if (`$env:TERM_PROGRAM -eq 'agliteterm') {`r`n"
        foreach($script in $loads){$body+="    . '"+(Join-Path $DataRoot $script).Replace("'","''")+"'`r`n"};$body+='}'
        $next=Add-InstallBlock $profile $Operation $body
        $settingsPath=Join-Path $UserRoot '.claude/settings.json';$settings='';$merged=''
        if($Operation -eq 'hooks'){
            $settings=Read-InstallText $settingsPath
            Test-InstallJsonShape $settings
            $root=if($settings.Trim()){$settings|ConvertFrom-Json -ErrorAction Stop}else{[pscustomobject]@{}}
            if($root -isnot [pscustomobject]){throw 'Claude settings root is not an object; unchanged'}
            if(-not $root.PSObject.Properties['hooks']){$root|Add-Member hooks ([pscustomobject]@{})}
            if($root.hooks -isnot [pscustomobject]){throw 'Claude hooks is not an object; unchanged'}
            foreach($eventProperty in $root.hooks.PSObject.Properties){
                if($eventProperty.Value -isnot [Array]){throw 'Claude hook event is not an array; unchanged'}
                foreach($entry in $eventProperty.Value){
                    if($entry -isnot [pscustomobject] -or $entry.hooks -isnot [Array]){throw 'Claude hook entry/hooks has invalid shape; unchanged'}
                    if($entry.PSObject.Properties['matcher'] -and $entry.matcher -isnot [string]){throw 'Claude hook matcher is not text; unchanged'}
                    foreach($hook in $entry.hooks){
                        if($hook -isnot [pscustomobject] -or $hook.type -isnot [string]){throw 'Claude hook/type has invalid shape; unchanged'}
                        if($hook.PSObject.Properties['command'] -and $hook.command -isnot [string]){throw 'Claude hook command is not text; unchanged'}
                        if($hook.type-eq'command' -and $hook.command -isnot [string]){throw 'Claude command hook has no command text; unchanged'}
                    }
                }
            }
            $wrapper=Join-Path $DataRoot 'agliteterm-agent-status.ps1'
            foreach($item in @(@('UserPromptSubmit','active',''),@('PostToolUse','active',''),@('Stop','completed',''),@('Notification','blocked','permission_prompt'))){
                $event=$item[0];$command='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$wrapper+'" '+$item[1]
                if(-not $root.hooks.PSObject.Properties[$event]){$root.hooks|Add-Member $event @()}
                if($root.hooks.$event -isnot [Array]){throw "Claude hook $event is not an array; unchanged"}
                $exists=$false
                foreach($entry in $root.hooks.$event){
                    if([string]$entry.matcher -cne $item[2]){continue}
                    foreach($hook in $entry.hooks){if($hook.type-ceq'command' -and $hook.command -ceq $command){$exists=$true}}
                }
                if(-not $exists){$entry=@{hooks=@(@{type='command';command=$command})};if($item[2]){$entry.matcher=$item[2]};$root.hooks.$event=@($root.hooks.$event)+@([pscustomobject]$entry)}
            }
            $merged=$root|ConvertTo-Json -Depth 100
        }
        # Validate all inputs above before touching the first destination. Report partial failures.
        foreach($script in $scripts){$path=Join-Path $DataRoot $script;Set-InstallText $path $sources[$script] (Read-InstallText $path)}
        if($Operation -eq 'hooks'){Set-InstallText $settingsPath $merged $settings}
        Set-InstallText $ProfilePath $next $profile
        $result="Installed $Operation; existing text/settings preserved; restart shells. Changed: $($changed -join ', ')"
        if($Operation -eq 'hooks'){
            $notify=Join-Path $DataRoot 'agliteterm-codex-notify.ps1'
            $result+="`nCodex config is unchanged. Add to your user config.toml: notify = ["+((@('powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',$notify)|ForEach-Object{$_|ConvertTo-Json -Compress}) -join ',')
            $result+=']'
        }
        @{ok=$true;result=$result}|ConvertTo-Json -Compress -Depth 4
    }
}catch{
    @{ok=$false;error=($_.Exception.Message+"; completed writes: "+($changed -join ', '))}|ConvertTo-Json -Compress
    exit 1
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
