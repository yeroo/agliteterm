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
# Only link-type reparse points (junctions, symlinks) redirect a path, so only they are refused.
# Cloud-files placeholders (OneDrive Known Folder Move), dedup, WOF and similar tags are written through.
function Test-InstallLinkTag([uint32]$Tag){
    # Name-surrogate bit (0x20000000): junction, symlink, LX symlink, WCI link, ...
    # APPEXECLINK (0x8000001B) lacks the bit but is a link too; tag 0 means it was not read.
    return [bool]($Tag -eq 0 -or ($Tag -band 0x20000000) -or $Tag -eq [uint32]2147483675)
}
function Get-InstallReparseTag([string]$Path){
    # The tag from the directory entry, or $null when it cannot be read. FindFirstFile does not open
    # the file, so a cloud placeholder is not hydrated. FILETIMEs are uint pairs: a long would be
    # 8-aligned, shift dwReserved0 and read every tag as 0.
    try{
        if(-not ('AgLiteInstallFind' -as [type])){
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgLiteInstallFind {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct FindData {
        public uint Attributes;
        public uint CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint SizeHigh, SizeLow, Reserved0, Reserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string FileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=14)] public string AlternateFileName;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr FindFirstFileW(string path, out FindData data);
    [DllImport("kernel32.dll")]
    static extern bool FindClose(IntPtr handle);
    // The reparse tag, or -1 when the entry cannot be read or is not a reparse point.
    public static long Tag(string path) {
        FindData data;
        IntPtr handle = FindFirstFileW(path, out data);
        if (handle == new IntPtr(-1)) return -1;
        FindClose(handle);
        if ((data.Attributes & 0x400) == 0) return -1;
        return data.Reserved0;
    }
}
'@
        }
        $tag=[AgLiteInstallFind]::Tag($Path)
        if($tag -lt 0){return $null}
        return [uint32]$tag
    }catch{return $null}
}
function Test-InstallLinkPart([string]$Path){
    try{if(-not([IO.File]::GetAttributes($Path)-band [IO.FileAttributes]::ReparsePoint)){return $false}}
    catch [IO.FileNotFoundException]{return $false} catch [IO.DirectoryNotFoundException]{return $false}
    # Fail closed: a reparse point whose tag cannot be read counts as a link.
    $tag=Get-InstallReparseTag $Path
    return ($null -eq $tag) -or (Test-InstallLinkTag $tag)
}
function Get-InstallLinkPoint([string]$Path){
    $full=[IO.Path]::GetFullPath($Path)
    for($part=[IO.Path]::GetDirectoryName($full);$part;$part=[IO.Path]::GetDirectoryName($part)){
        if(Test-InstallLinkPart $part){return $part}
    }
    if(Test-InstallLinkPart $full){return $full}
    return $null
}
function Test-InstallDestination([string]$Path){
    $link=Get-InstallLinkPoint $Path
    if($link){throw "Refusing junction/symlink destination: $link"}
}
function Set-InstallText([string]$Path,[string]$Text,[string]$Expected){
    $full=[IO.Path]::GetFullPath($Path)
    if([IO.File]::Exists($full) -and (Read-InstallText $full) -ceq $Text){return}
    $parent=[IO.Path]::GetDirectoryName($full)
    Test-InstallDestination $full
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
function Test-InstallKeyCase($Object,[string[]]$Known,[string]$Label='Claude hook'){
    # PowerShell lookup folds case; JSON consumers do not. Reject aliases before using dot lookup.
    foreach($property in $Object.PSObject.Properties){
        if($Known -contains $property.Name -and $Known -cnotcontains $property.Name){
            throw "Wrong-case $Label field '$($property.Name)'; unchanged"
        }
    }
}
function Test-InstallJsonShape([string]$Text,[string]$Label='Claude settings'){
    if($Text.Length -gt 1048576){throw "$Label exceeds 1 MiB; unchanged"}
    # ConvertFrom-Json collapses duplicate keys (including case-only collisions in PS 5.1).
    # Detect them before conversion and cap nesting below ConvertTo-Json's output depth.
    $stack=New-Object Collections.Generic.Stack[object]
    foreach($match in [regex]::Matches($Text,'"(?:\\.|[^"\\])*"|[{}\[\],]')){
        $part=$match.Value
        if($part -eq '{' -or $part -eq '['){
            if($stack.Count -ge 64){throw "$Label nesting exceeds 64; unchanged"}
            $stack.Push(@{Object=($part-eq'{');Key=($part-eq'{');Names=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))})
        }elseif($part -eq '}' -or $part -eq ']'){if($stack.Count){$null=$stack.Pop()}}
        elseif($stack.Count){
            $frame=$stack.Peek()
            if($part -eq ','){$frame.Key=$frame.Object}
            elseif($frame.Object -and $frame.Key -and $part.StartsWith('"')){
                try{$key=$part|ConvertFrom-Json -ErrorAction Stop}
                catch{throw "$Label has an invalid JSON key; unchanged"}
                if(-not $frame.Names.Add($key)){throw "Duplicate/case-colliding $Label key '$key'; unchanged"}
                $frame.Key=$false
            }
        }
    }
}
function Test-InstallHookTree($Root,[string]$Label,[string[]]$Events,[string[]]$HandlerFields,[bool]$Claude,[string[]]$RootKeys=@('hooks')){
    if($Root -isnot [pscustomobject]){throw "$Label root is not an object; unchanged"}
    Test-InstallKeyCase $Root $RootKeys $Label
    if(-not $Root.PSObject.Properties['hooks']){$Root|Add-Member hooks ([pscustomobject]@{})}
    if($Root.hooks -isnot [pscustomobject]){throw "$Label hooks is not an object; unchanged"}
    Test-InstallKeyCase $Root.hooks $Events $Label
    foreach($eventProperty in $Root.hooks.PSObject.Properties){
        if($eventProperty.Value -isnot [Array]){throw "$Label hook event is not an array; unchanged"}
        foreach($entry in $eventProperty.Value){
            if($entry -isnot [pscustomobject]){throw "$Label hook entry/hooks has invalid shape; unchanged"}
            Test-InstallKeyCase $entry @('hooks','matcher') $Label
            if($entry.hooks -isnot [Array]){throw "$Label hook entry/hooks has invalid shape; unchanged"}
            if($entry.PSObject.Properties['matcher'] -and $entry.matcher -isnot [string]){throw "$Label hook matcher is not text; unchanged"}
            foreach($hook in $entry.hooks){
                if($Claude){Test-InstallHandler $hook $eventProperty.Name}
                else{
                    if($hook -isnot [pscustomobject]){throw "$Label hook handler is not an object; unchanged"}
                    Test-InstallKeyCase $hook $HandlerFields $Label
                    if($hook.type -isnot [string]){throw "$Label hook handler type is not text; unchanged"}
                }
            }
        }
    }
}
function Merge-InstallHooks($Root,$Items,[string]$Wrapper,[bool]$Codex){
    foreach($item in $Items){
        $event=$item[0];$command='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$Wrapper+'" '+$item[1]
        if(-not $Root.hooks.PSObject.Properties[$event]){$Root.hooks|Add-Member $event @()}
        $exists=$false
        foreach($entry in $Root.hooks.$event){
            $matcher=[string]$entry.matcher
            if($Codex -and -not $item[2]){if($matcher -cnotin @('','*')){continue}}
            elseif($matcher -cne $item[2]){continue}
            foreach($hook in $entry.hooks){if($hook.type-ceq'command' -and $hook.command -ceq $command){$exists=$true}}
        }
        if(-not $exists){$entry=@{hooks=@(@{type='command';command=$command})};if($item[2]){$entry.matcher=$item[2]};$Root.hooks.$event=@($Root.hooks.$event)+@([pscustomobject]$entry)}
    }
}
# Catalog snapshot 2026-09-10, https://code.claude.com/docs/en/hooks
# A dated supported catalog, not a claim to validate future extensions or permission-rule syntax.
$hookModelEvents=@('PermissionDenied','PermissionRequest','PostToolBatch','PostToolUse','PostToolUseFailure','PreToolUse','Stop','SubagentStop','TaskCompleted','TaskCreated','TeammateIdle','UserPromptExpansion','UserPromptSubmit')
$hookIoEvents=@('ConfigChange','CwdChanged','DirectoryAdded','Elicitation','ElicitationResult','FileChanged','InstructionsLoaded','MessageDisplay','Notification','PostCompact','PostModelSwitch','PreCompact','PreModelSwitch','SessionEnd','StopFailure','SubagentStart','WorktreeCreate','WorktreeRemove')
$hookStartupEvents=@('SessionStart','Setup')
$hookEvents=$hookModelEvents+$hookIoEvents+$hookStartupEvents
$hookCommon=@{type='text';if='text';timeout='number';statusMessage='text';once='boolean'}
$hookKinds=@{
    command=@{command='requiredText';args='textArray';async='boolean';asyncRewake='boolean';shell='shell'}
    http=@{url='requiredText';headers='textMap';allowedEnvVars='textArray'}
    mcp_tool=@{server='requiredText';tool='requiredText';input='object'}
    prompt=@{prompt='requiredText';model='text';continueOnBlock='boolean'}
    agent=@{prompt='requiredText';model='text'}
}
$hookFields=@($hookCommon.Keys)+@($hookKinds.Values|ForEach-Object {$_.Keys})|Select-Object -Unique
# Catalog snapshot 2026-09-25, https://learn.chatgpt.com/docs/hooks
$codexEvents=@('SessionStart','SessionEnd','SubagentStart','PreToolUse','PermissionRequest','PostToolUse','PreCompact','PostCompact','UserPromptSubmit','SubagentStop','Stop','Interrupt')
$codexFields=@('type','command','commandWindows','timeout','statusMessage','additionalContextLimit','async','server','tool','input')
function Test-InstallHandler($Hook,[string]$Event){
    if($Hook -isnot [pscustomobject]){throw 'Claude hook is not an object; unchanged'}
    Test-InstallKeyCase $Hook $hookFields
    if($Hook.type -isnot [string] -or @($hookKinds.Keys) -cnotcontains $Hook.type){throw 'Unknown Claude hook handler type; unchanged'}
    if(($hookStartupEvents -ccontains $Event -and $Hook.type -cnotin @('command','mcp_tool')) -or
       ($hookIoEvents -ccontains $Event -and $Hook.type -cin @('prompt','agent'))){throw "Claude hook type $($Hook.type) is unsupported for $Event; unchanged"}
    $fields=$hookKinds[$Hook.type]
    foreach($field in $fields.Keys){
        if($fields[$field]-eq 'requiredText' -and ($Hook.$field -isnot [string] -or -not $Hook.$field.Trim())){throw "Claude hook requires text field $field; unchanged"}
    }
    foreach($property in $Hook.PSObject.Properties){
        $name=$property.Name;$value=$property.Value
        $rule=if($hookCommon.ContainsKey($name)){$hookCommon[$name]}elseif($fields.ContainsKey($name)){$fields[$name]}else{$null}
        if(-not $rule){
            if($hookFields -ccontains $name){throw "Claude hook field $name does not apply to $($Hook.type); unchanged"}
            continue # Unknown optional fields are preserved, not normalized or guessed.
        }
        $valid=switch($rule){
            'text' {$value -is [string]}
            'requiredText' {$value -is [string] -and $value.Trim().Length-gt 0}
            'boolean' {$value -is [bool]}
            'shell' {$value -is [string] -and $value -cin @('bash','powershell')}
            'textArray' {$value -is [Array] -and @($value|Where-Object {$_ -isnot [string]}).Count-eq 0}
            'object' {$value -is [pscustomobject]}
            'textMap' {$value -is [pscustomobject] -and @($value.PSObject.Properties|Where-Object {$_.Value -isnot [string]}).Count-eq 0}
            'number' {($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) -and $value-ge 0 -and -not [double]::IsInfinity([double]$value) -and -not [double]::IsNaN([double]$value)}
            default {$false}
        }
        if(-not $valid){throw "Claude hook field $name has invalid $rule value; unchanged"}
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
        $scripts=if($Operation -eq 'shell'){@('agliteterm-shell.ps1')}else{@('agliteterm-agent-status.ps1','agliteterm-codex-notify.ps1','agliteterm-codex-hook.ps1','agliteterm-claude.ps1','agliteterm-generic-agent.ps1')}
        $sources=@{}
        foreach($script in $scripts){$sources[$script]=Read-InstallText (Join-Path $PSScriptRoot $script);if(-not $sources[$script]){throw "Missing bundled helper $script"}}
        $loads=if($Operation -eq 'shell'){@('agliteterm-shell.ps1')}else{@('agliteterm-claude.ps1','agliteterm-generic-agent.ps1')}
        $body="if (`$env:TERM_PROGRAM -eq 'agliteterm') {`r`n"
        foreach($script in $loads){$body+="    . '"+(Join-Path $DataRoot $script).Replace("'","''")+"'`r`n"};$body+='}'
        # A profile behind a junction/symlink is skipped, not fatal.
        $profileReparse=Get-InstallLinkPoint $ProfilePath
        try{$next=Add-InstallBlock $profile $Operation $body}catch{if(-not $profileReparse){throw};$next=$null}
        $settingsPath=Join-Path $UserRoot '.claude/settings.json';$settings='';$merged=''
        $codexDir=Join-Path $UserRoot '.codex';$codexPath=Join-Path $codexDir 'hooks.json';$codex='';$codexMerged=''
        $codexPresent=[IO.Directory]::Exists($codexDir)
        $codexReparse=if($codexPresent){Get-InstallLinkPoint $codexPath}else{$null}
        if($codexReparse){$codexPresent=$false}
        if($Operation -eq 'hooks'){
            $settings=Read-InstallText $settingsPath
            Test-InstallJsonShape $settings
            $root=if($settings.Trim()){$settings|ConvertFrom-Json -ErrorAction Stop}else{[pscustomobject]@{}}
            Test-InstallHookTree $root 'Claude settings' $hookEvents $hookFields $true
            $wrapper=Join-Path $DataRoot 'agliteterm-agent-status.ps1'
            Merge-InstallHooks $root @(@('UserPromptSubmit','active',''),@('PostToolUse','active',''),@('Stop','completed',''),@('Notification','blocked','permission_prompt')) $wrapper $false
            $merged=$root|ConvertTo-Json -Depth 100
            if($codexPresent){
                try{$codex=Read-InstallText $codexPath}
                catch{throw "Codex hooks could not be read: $($_.Exception.Message); unchanged"}
                Test-InstallJsonShape $codex 'Codex hooks'
                try{$codexRoot=if($codex.Trim()){$codex|ConvertFrom-Json -ErrorAction Stop}else{[pscustomobject]@{}}}
                catch{throw "Codex hooks JSON is invalid: $($_.Exception.Message); unchanged"}
                Test-InstallHookTree $codexRoot 'Codex hooks' $codexEvents $codexFields $false @('hooks','description')
                if($null -ne $codexRoot.description -and $codexRoot.description -isnot [string]){throw 'Codex hooks description is not text; unchanged'}
                $codexWrapper=Join-Path $DataRoot 'agliteterm-codex-hook.ps1'
                Merge-InstallHooks $codexRoot @(@('UserPromptSubmit','active',''),@('PostToolUse','active',''),@('PermissionRequest','blocked',''),@('Stop','stop','')) $codexWrapper $true
                $codexMerged=$codexRoot|ConvertTo-Json -Depth 100
            }
        }
        # Validate all inputs above, then preflight every destination that will really be written
        # before the first write. Already-current files are left alone wherever they live.
        $destinations=@()
        foreach($script in $scripts){$path=Join-Path $DataRoot $script;$destinations+=@{Kind='helper';Path=$path;Text=$sources[$script];Expected=(Read-InstallText $path)}}
        if($Operation -eq 'hooks'){$destinations+=@{Kind='claude';Path=$settingsPath;Text=$merged;Expected=$settings}}
        if($Operation -eq 'hooks' -and $codexPresent){$destinations+=@{Kind='codex';Path=$codexPath;Text=$codexMerged;Expected=$codex}}
        if($null -ne $next){$destinations+=@{Kind='profile';Path=$ProfilePath;Text=$next;Expected=$profile}}
        $writes=@()
        foreach($destination in $destinations){
            if([IO.File]::Exists($destination.Path) -and (Read-InstallText $destination.Path) -ceq $destination.Text){continue}
            $reparse=Get-InstallLinkPoint $destination.Path
            if(-not $reparse){$writes+=$destination;continue}
            switch($destination.Kind){
                'codex' {$codexReparse=$reparse;$codexPresent=$false}
                'profile' {$profileReparse=$reparse;$next=$null}
                default {throw "Refusing junction/symlink destination: $reparse"}
            }
        }
        foreach($destination in $writes){Set-InstallText $destination.Path $destination.Text $destination.Expected}
        $result="Installed $Operation; existing text/settings preserved; restart shells. Changed: $($changed -join ', ')"
        if($null -eq $next){
            $dotSources=($loads|ForEach-Object {Join-Path $DataRoot $_}) -join ' and '
            $result+="`nPowerShell profile block skipped: $ProfilePath is under a junction/symlink ($profileReparse); agliteterm does not write through junctions/symlinks. Dot-source $dotSources yourself if you want them."
        }
        if($Operation -eq 'hooks'){
            if($codexPresent){$result+="`nCodex hooks installed in $codexPath. Trust new hooks once in Codex /hooks before they run."}
            elseif($codexReparse){$result+="`nCodex hooks skipped: $codexReparse is a junction/symlink; agliteterm does not write through junctions/symlinks."}
            else{$result+="`nCodex hooks skipped because $codexDir does not exist."}
        }
        @{ok=$true;result=$result}|ConvertTo-Json -Compress -Depth 4
    }
}catch{
    @{ok=$false;error=($_.Exception.Message+"; completed writes: "+($changed -join ', '))}|ConvertTo-Json -Compress
    exit 1
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
