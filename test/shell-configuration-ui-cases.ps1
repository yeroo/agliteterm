# Runs only under selection-ui's token, redirected app data and proven cleanup boundary.
if(-not $script:selectionProc -or -not $clipboard){throw 'Shell configuration requires guarded fixture'}
'-- P10b guarded shell configuration --'
function Shell-Set([string]$Setting,[string]$Text,[string]$RegName,$ExpectedState,[switch]$OmpLive,[string]$Pane='active') {
    $regKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\agliteterm')
    $prior=$script:selectionRegistry[$RegName].Expected
    try {
        Set-RegistryGuardValue $script:selectionRegistry $RegName $ExpectedState {
            param($n) Read-RegistryGuardValue $regKey $n
        } {
            param($n,$state)
            $script:shellReply=if($OmpLive){Selection-Rpc 'omp.set' @{name=$Text;persist=$true} $Pane}
                else{Selection-Rpc 'config.set' @{key=$Setting;value=$Text}}
        }
    } catch {
        if(Test-RegistryGuardValue (Read-RegistryGuardValue $regKey $RegName) $prior){$script:selectionRegistry[$RegName].Expected=$prior}
        throw
    } finally {$regKey.Dispose()}
    $script:shellReply
}
function Shell-Ready([string]$Pane,[string]$Marker) {
    for($n=0;$n-lt 100;$n++){
        if(([string](Selection-Rpc 'session.text' @{} $Pane)).Contains($Marker)){return}
        Start-Sleep -Milliseconds 100
    }
    throw "Owned shell did not show $Marker"
}
function Shell-Nodes { @((Selection-Rpc 'tree').workspaces | ForEach-Object sessions) }
Stop-SelectionSandbox
Start-SelectionSandbox $Exe $profile
$catalogPath=Join-Path $profile 'agliteterm/profiles.json'
$catalog=@{default='P10b-cmd';profiles=@(
    @{name='P10b-cmd';command='cmd.exe';args=@('/k','echo P10B-CMD-READY');cwd=$script:selectionArtifact},
    @{name='P10b-PS';command='powershell.exe';args=@('-NoLogo','-NoProfile','-NoExit');cwd=$script:selectionArtifact}
)}
$catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $catalogPath -Encoding utf8
$bytes=[IO.File]::ReadAllBytes($catalogPath)
Check 'profiles reload publishes validated custom catalog' ((Selection-Rpc 'profiles.reload')-eq '2 profiles loaded')
$listed=[string](Selection-Rpc 'profiles.list')
Check 'profiles list identifies default and other profile' ($listed-match '(?m)^\* P10b-cmd\tcmd.exe' -and $listed-match 'P10b-PS')
Check 'profiles list and reload never rewrite user file' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($catalogPath))-ceq [Convert]::ToBase64String($bytes))
$locked=[IO.File]::Open($catalogPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
try {
    $answer=Selection-Rpc 'profiles.reload' -AllowError
    Check 'unreadable profile file preserves last good catalog' (-not $answer.ok -and (Selection-Rpc 'profiles.list')-ceq $listed)
} finally {$locked.Dispose()}
$before=(Shell-Nodes).Count
foreach($bad in @('', 'P10b', 'missing')) {
    $answer=Selection-Rpc 'session.new' @{profile=$bad;'workspace-name'='must-not-create';'create-workspace'=$true} -AllowError
    Check "unknown/empty/exact-prefix profile refuses: <$bad>" (-not $answer.ok -and (Shell-Nodes).Count-eq $before -and @((Selection-Rpc 'tree').workspaces|Where-Object name -eq 'must-not-create').Count-eq 0)
}
$answer=Selection-Rpc 'session.new' @{profile='P10b-cmd';command='echo MUST-NOT-RUN'} -AllowError
Check 'profile and command refuse ambiguity' (-not $answer.ok -and (Shell-Nodes).Count-eq $before)
$cmdPane=[string](Selection-Rpc 'session.new' @{profile='p10B-CMD';name='P10b-custom'})
Shell-Ready $cmdPane 'P10B-CMD-READY'
Check 'custom profile launches selected executable and args' (([string](Selection-Rpc 'session.text' @{} $cmdPane))-match 'P10B-CMD-READY')
$null=Selection-Rpc 'session.type' @{text=('cd'+[char]13)} $cmdPane
Shell-Ready $cmdPane $script:selectionArtifact
Check 'profile cwd applied to launched shell' (([string](Selection-Rpc 'session.text' @{} $cmdPane)).Contains($script:selectionArtifact))
$defaultPane=[string](Selection-Rpc 'session.new' @{name='P10b-default'})
Shell-Ready $defaultPane 'P10B-CMD-READY'
Check 'implicit new shell uses catalog default' (([string](Selection-Rpc 'session.text' @{} $defaultPane))-match 'P10B-CMD-READY')
# Changing the catalog changes future resolution, never an already-resolved launch specification.
$catalog.profiles[0].args=@('/k','echo P10B-CMD-RELOADED')
$catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $catalogPath -Encoding utf8
$null=Selection-Rpc 'profiles.reload'
$duplicate=[string](Selection-Rpc 'session.duplicate' @{} $cmdPane)
Shell-Ready $duplicate 'P10B-CMD-READY'
Check 'duplicate preserves launch args across catalog reload' (([string](Selection-Rpc 'session.text' @{} $duplicate))-match 'P10B-CMD-READY')
$changed=[string](Selection-Rpc 'session.new' @{profile='P10b-cmd'})
Shell-Ready $changed 'P10B-CMD-RELOADED'
Check 'new named launch uses reloaded catalog' (([string](Selection-Rpc 'session.text' @{} $changed))-match 'P10B-CMD-RELOADED')
$catalog.profiles[0].args=@('/k','echo P10B-CMD-READY')
$catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $catalogPath -Encoding utf8
$null=Selection-Rpc 'profiles.reload'
foreach($malformed in @('{bad', '{"default":"x","profiles":[]}', '{"default":"x","profiles":[{"name":"x","command":"cmd.exe","env":{"SECRET":"x"}}]}')) {
    [IO.File]::WriteAllText($catalogPath,$malformed)
    $answer=Selection-Rpc 'profiles.reload' -AllowError
    Check 'bad reload preserves catalog and original invalid file' (-not $answer.ok -and (Selection-Rpc 'profiles.list')-ceq $listed -and [IO.File]::ReadAllText($catalogPath)-ceq $malformed)
}
$catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $catalogPath -Encoding utf8
$null=Selection-Rpc 'profiles.reload'

# Fake OMP is a function inside this owned NoProfile shell, never the installed user tool/theme.
$themeDir=Join-Path $profile 'agliteterm/omp-themes';New-Item -ItemType Directory -Force $themeDir|Out-Null
$themeFile=Join-Path $themeDir "P10b's theme.omp.json";[IO.File]::WriteAllText($themeFile,'{}')
$ompSink=Join-Path $script:selectionArtifact 'omp-args.txt'
$setup=@'
function global:oh-my-posh { [IO.File]::WriteAllText('__SINK__',($args -join '|')); 'function global:prompt { ''P10B-OMP-READY> '' }' }; function global:prompt { [Console]::Write(([string][char]27)+']133;A'+[char]7); 'P10B-OMP-READY> ' }
'@
$setup=$setup.Replace('__SINK__',$ompSink.Replace("'","''"))
$catalog.profiles+=@{name='P10b-OMP';command='powershell.exe';args=@('-NoLogo','-NoProfile','-NoExit','-Command',$setup.Trim());cwd=$script:selectionArtifact}
$catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $catalogPath -Encoding utf8
$null=Selection-Rpc 'profiles.reload'
$ompPane=[string](Selection-Rpc 'session.new' @{profile='P10b-OMP';name='P10b-OMP'})
Shell-Ready $ompPane 'P10B-OMP-READY>'
Start-Sleep -Milliseconds 300
Check 'OMP catalog discovers local fake theme without executing it' ((Selection-Rpc 'omp.list')-match "P10b's theme" -and -not (Test-Path $ompSink))
$answer=Selection-Rpc 'omp.set' @{name='missing-theme'} $ompPane -AllowError
Check 'unknown OMP theme refuses without execution' (-not $answer.ok -and -not (Test-Path $ompSink))
$answer=Selection-Rpc 'omp.set' @{name=$themeFile} $cmdPane -AllowError
Check 'OMP rejects non-PowerShell target' (-not $answer.ok -and -not (Test-Path $ompSink))
$null=Selection-Rpc 'session.readonly' @{op='on'} $ompPane
$answer=Selection-Rpc 'omp.set' @{name=$themeFile} $ompPane -AllowError
Check 'OMP readonly refusal precedes write/persistence' (-not $answer.ok -and -not (Test-Path $ompSink))
$null=Selection-Rpc 'session.readonly' @{op='off'} $ompPane
$answer=Selection-Rpc 'omp.set' @{name=$themeFile;persist='invalid'} $ompPane -AllowError
Check 'OMP invalid persist refuses without mutation' (-not $answer.ok -and -not (Test-Path $ompSink))
$null=Selection-Rpc 'session.write' @{text=([string][char]27+'[?1049h')} $ompPane
$answer=Selection-Rpc 'omp.set' @{name=$themeFile} $ompPane -AllowError
Check 'OMP alternate screen refuses without mutation' (-not $answer.ok -and -not (Test-Path $ompSink))
$null=Selection-Rpc 'session.write' @{text=([string][char]27+'[?1049l')} $ompPane
$reply=Shell-Set '' $themeFile 'OmpTheme' @{Exists=$true;Kind=1;Value=$themeFile} -OmpLive -Pane $ompPane
for($n=0;$n-lt 100 -and -not (Test-Path $ompSink);$n++){Start-Sleep -Milliseconds 100}
Check 'OMP initialization writes exact quoted path to fake tool' ((Test-Path $ompSink) -and [IO.File]::ReadAllText($ompSink)-ceq "init|pwsh|--config|$themeFile")
Check 'OMP reply distinguishes write from shell success' ($reply-match 'initialization written' -and $reply-match 'success not confirmed')
Check 'OMP persist readback is exact' ((Selection-Rpc 'config.get' @{key='omp-theme'})-ceq $themeFile)
$draftPane=[string](Selection-Rpc 'session.new' @{profile='P10b-OMP';name='P10b-draft'})
Shell-Ready $draftPane 'P10B-OMP-READY>'
$draftSink=Join-Path $script:selectionArtifact 'draft-must-not-run.txt'
$draft="[IO.File]::WriteAllText('$($draftSink.Replace("'","''"))','EXECUTED'); "
$null=Selection-Rpc 'session.type' @{text=$draft} $draftPane
Start-Sleep -Milliseconds 150
$answer=Selection-Rpc 'omp.set' @{name=$themeFile} $draftPane -AllowError
# A wrapped draft may invalidate the observed-prompt gate before the atomic input gate.
# Both refusals must leave the draft unsubmitted; never accept a generic RPC failure here.
Check 'OMP refuses a single-line draft without submitting it' (-not $answer.ok -and $answer.error-match 'emptiness is unproven|not at an observed prompt' -and -not (Test-Path $draftSink)) ($answer|ConvertTo-Json -Compress)
$answer=Selection-Rpc 'omp.set' @{name=$themeFile} $ompPane -AllowError
Check 'OMP conservatively refuses after prior initialization input' (-not $answer.ok -and $answer.error-match 'emptiness is unproven')
foreach($setter in @(@{key='omp-theme'},@{key='omp-theme';value=''})){
    $answer=Selection-Rpc 'config.set' $setter -AllowError
    Check 'omitted or empty OMP value refuses without clearing' (-not $answer.ok -and (Selection-Rpc 'config.get' @{key='omp-theme'})-ceq $themeFile)
}
# Clear before any restart: no real OMP executable is invoked by a fresh shell in this fixture.
$null=Shell-Set 'omp-theme' 'none' 'OmpTheme' @{Exists=$true;Kind=1;Value=''}
Check 'OMP future-shell config clears explicitly' ((Selection-Rpc 'config.get' @{key='omp-theme'})-ceq '')
$null=Selection-Rpc 'session.type' @{text=('exit'+[char]13)} $ompPane
for($n=0;$n-lt 100;$n++){if(@(Shell-Nodes|Where-Object id -eq $ompPane)[0].exited){break};Start-Sleep -Milliseconds 100}
$answer=Selection-Rpc 'omp.set' @{name=$themeFile} $ompPane -AllowError
Check 'OMP exited pane refuses' (-not $answer.ok)

# Synthetic K state uses only these harmless marker commands, never a captured real command.
Stop-SelectionSandbox
$catalog.default='P10b-PS';$catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $catalogPath -Encoding utf8
$statePath=Join-Path $profile "agliteterm/sessions-$script:selectionPipe.tsv"
$replayPath=Join-Path $script:selectionArtifact 'captured-replay.txt'
function Captured-Command([string]$Letter) { "[IO.File]::AppendAllText('$($replayPath.Replace("'","''"))','$Letter')" }
function Captured-State([string]$Binding='',[string]$Pin='') {
    $tab=[string][char]9;$nl=[string][char]10
    function Encoded-Field([string]$Text){$json=ConvertTo-Json -InputObject $Text -Compress;$json.Substring(1,$json.Length-2)}
    $lines=@(('W'+$tab+'P10b-replay'),((@('S','0','P10b-K','powershell.exe','','-NoLogo','-NoProfile','-NoExit'))-join $tab),((@('K','0',(Captured-Command 'K'),''))-join $tab))
    if($Binding){$lines+=(@('B','0',(Encoded-Field $Binding),'')-join $tab)};if($Pin){$lines+=(@('R','0',(Encoded-Field $Pin),'')-join $tab)}
    [IO.File]::WriteAllText($statePath,($lines-join $nl)+$nl)
}
function Captured-Text { if(Test-Path $replayPath){[IO.File]::ReadAllText($replayPath)}else{''} }
function Captured-Wait([string]$Expected) {
    for($n=0;$n-lt 100;$n++){if((Captured-Text)-ceq $Expected){return $true};Start-Sleep -Milliseconds 100};return $false
}
Captured-State
Start-SelectionSandbox $Exe $profile -Restore
Start-Sleep -Seconds 2
Check 'captured replay defaults off' ((Selection-Rpc 'config.get' @{key='restore-commands'})-eq 'false' -and (Captured-Text)-ceq '')
$null=Shell-Set 'restore-commands' 'true' 'RestoreCommands' @{Exists=$true;Kind=4;Value=1}
Stop-SelectionSandbox;Captured-State
Start-SelectionSandbox $Exe $profile -Restore
Check 'opt-in fresh restore replays captured K once' (Captured-Wait 'K')
Stop-SelectionSandbox;Captured-State '' (Captured-Command 'R')
Start-SelectionSandbox $Exe $profile -Restore
Check 'explicit R pin wins over captured K' (Captured-Wait 'KR')
Stop-SelectionSandbox;Captured-State (Captured-Command 'B') (Captured-Command 'R')
Start-SelectionSandbox $Exe $profile -Restore
Check 'binding B wins over R and K' (Captured-Wait 'KRB')
Stop-SelectionSandbox;Captured-State
Start-SelectionSandbox $Exe $profile -Restore -SettleMilliseconds 0
$pane=[string](@(Shell-Nodes|Where-Object name -eq 'P10b-K')[0].id)
$null=Selection-Rpc 'session.readonly' @{op='on'} $pane
Start-Sleep -Seconds 4
Check 'readonly before timer cancels captured replay' ((Captured-Text)-ceq 'KRB')
Stop-SelectionSandbox;Captured-State
Start-SelectionSandbox $Exe $profile -Restore -SettleMilliseconds 0
$null=Shell-Set 'restore-commands' 'false' 'RestoreCommands' @{Exists=$true;Kind=4;Value=0}
Start-Sleep -Seconds 4
Check 'opt-out before timer cancels captured replay' ((Captured-Text)-ceq 'KRB')
$capture=Selection-Rpc 'restore.capture'
Check 'capture reply reports current off policy' (-not $capture.replayOnRestore)
$null=Shell-Set 'restore-commands' 'true' 'RestoreCommands' @{Exists=$true;Kind=4;Value=1}
$capture=Selection-Rpc 'restore.capture'
Check 'capture reply reports current on policy' ($capture.replayOnRestore)
Stop-SelectionSandbox;Captured-State
Start-SelectionSandbox $Exe $profile -Restore
Check 'fresh captured replay prepares adoption control' (Captured-Wait 'KRBK')
if(-not $script:selectionHosts.Count){throw 'Adoption requires a previously pinned owned host'}
$script:selectionProc.Kill()
if(-not $script:selectionProc.WaitForExit(5000)){throw 'Owned adoption window did not exit'}
Start-SelectionSandbox $Exe $profile -Restore
Start-Sleep -Seconds 2
Check 'adopted live shell never replays K again' ((Captured-Text)-ceq 'KRBK')
Stop-SelectionSandbox;Captured-State
Start-SelectionSandbox $Exe $profile -Restore -SettleMilliseconds 0
$pane=[string](@(Shell-Nodes|Where-Object name -eq 'P10b-K')[0].id)
$null=Selection-Rpc 'session.close' @{} $pane
Start-Sleep -Seconds 4
Check 'closed pending captured pane never receives replay' ((Captured-Text)-ceq 'KRBK')
# An exited restored process cannot receive a captured command.
Stop-SelectionSandbox;Captured-State
$tab=[string][char]9;$nl=[string][char]10
$state=[IO.File]::ReadAllText($statePath).Replace(('-NoLogo'+$tab+'-NoProfile'+$tab+'-NoExit'),('-NoProfile'+$tab+'-Command'+$tab+'exit'))
[IO.File]::WriteAllText($statePath,$state)
Start-SelectionSandbox $Exe $profile -Restore
Start-Sleep -Seconds 2
$node=@(Shell-Nodes|Where-Object name -eq 'P10b-K')[0]
Check 'exited restored pane never receives captured replay' ($node.exited -and (Captured-Text)-ceq 'KRBK')
# Legacy K owner corruption must not turn into execution in positional pane zero.
Stop-SelectionSandbox;Captured-State
$state=[IO.File]::ReadAllText($statePath).Replace(('K'+$tab+'0'+$tab),('K'+$tab+'invalid'+$tab))
[IO.File]::WriteAllText($statePath,$state)
Start-SelectionSandbox $Exe $profile -Restore
Start-Sleep -Seconds 2
$node=@(Shell-Nodes|Where-Object name -eq 'P10b-K')[0]
Check 'malformed legacy K owner is dropped without replay' ((Captured-Text)-ceq 'KRBK' -and -not $node.capturedCommands)
# Separate sinks prove both roles without concurrent writes to one file.
Stop-SelectionSandbox;Captured-State
$leftSink=Join-Path $script:selectionArtifact 'captured-left.txt'
$rightSink=Join-Path $script:selectionArtifact 'captured-right.txt'
$leftCommand="[IO.File]::AppendAllText('$($leftSink.Replace("'","''"))','L')"
$rightCommand="[IO.File]::AppendAllText('$($rightSink.Replace("'","''"))','R')"
$state=[IO.File]::ReadAllText($statePath)
$state=$state.Replace(('K'+$tab+'0'+$tab+(Captured-Command 'K')+$tab),(@('K','0',$leftCommand,$rightCommand)-join $tab))
$state+=(@('P','0','powershell.exe','','-NoLogo','-NoProfile','-NoExit')-join $tab)+$nl
[IO.File]::WriteAllText($statePath,$state)
Start-SelectionSandbox $Exe $profile -Restore
for($n=0;$n-lt 100 -and (-not (Test-Path $leftSink) -or -not (Test-Path $rightSink));$n++){Start-Sleep -Milliseconds 100}
$node=@(Shell-Nodes|Where-Object name -eq 'P10b-K')[0]
Check 'captured split roles replay once into their own panes' ($node.paneIds.Count-eq 2 -and (Test-Path $leftSink) -and (Test-Path $rightSink) -and [IO.File]::ReadAllText($leftSink)-ceq 'L' -and [IO.File]::ReadAllText($rightSink)-ceq 'R')
$null=Shell-Set 'restore-commands' 'false' 'RestoreCommands' @{Exists=$true;Kind=4;Value=0}

# K2 preserves tabs/newlines rather than converting executable content into different commands.
Stop-SelectionSandbox;Captured-State
$tab=[string][char]9;$nl=[string][char]10
$exactK="echo 'line one"+$nl+"line two'"+$tab+'; echo "quote\slash"'
$encoded=ConvertTo-Json -InputObject $exactK -Compress
$encoded=$encoded.Substring(1,$encoded.Length-2)
$state=[IO.File]::ReadAllText($statePath)
$state=[regex]::Replace($state,'(?m)^K\t[^\n]*',('K2'+$tab+'0'+$tab+$encoded+$tab))
[IO.File]::WriteAllText($statePath,$state)
Start-SelectionSandbox $Exe $profile -Restore
$node=@(Shell-Nodes|Where-Object name -eq 'P10b-K')[0]
Check 'K2 loads exact quote/backslash/tab/newline bytes' ([string]$node.capturedCommands.($node.id)-ceq $exactK)
Stop-SelectionSandbox
Check 'K2 save remains lossless field encoding' ([IO.File]::ReadAllText($statePath)-match '(?m)^K2\t')
Start-SelectionSandbox $Exe $profile -Restore
$node=@(Shell-Nodes|Where-Object name -eq 'P10b-K')[0]
Check 'K2 roundtrip preserves exact captured command' ([string]$node.capturedCommands.($node.id)-ceq $exactK)
# Policy is evaluated at dispatch in both directions, not frozen when the queue is built.
Stop-SelectionSandbox;Captured-State
Start-SelectionSandbox $Exe $profile -Restore -SettleMilliseconds 0
$null=Shell-Set 'restore-commands' 'true' 'RestoreCommands' @{Exists=$true;Kind=4;Value=1}
Check 'opt-in before timer enables pending captured replay' (Captured-Wait 'KRBKK')
$null=Shell-Set 'restore-commands' 'false' 'RestoreCommands' @{Exists=$true;Kind=4;Value=0}

# Before custom catalogs, empty S/P executables meant PowerShell, never the new default profile.
Stop-SelectionSandbox
$catalog.default='P10b-cmd';$catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $catalogPath -Encoding utf8
$legacy=@(
    ('W'+$tab+'P10b-legacy'),
    (@('S','0','P10b-legacy','',$script:selectionArtifact,'-NoLogo','-NoProfile','-NoExit','-Command',"Write-Output 'P10B-LEGACY-OWNER'")-join $tab),
    (@('P','0','',$script:selectionArtifact,'-NoLogo','-NoProfile','-NoExit','-Command',"Write-Output 'P10B-LEGACY-SPLIT'")-join $tab)
)
[IO.File]::WriteAllText($statePath,($legacy-join $nl)+$nl)
Start-SelectionSandbox $Exe $profile -Restore
$node=@(Shell-Nodes|Where-Object name -eq 'P10b-legacy')[0]
Shell-Ready $node.id 'P10B-LEGACY-OWNER'
Shell-Ready $node.paneIds[1] 'P10B-LEGACY-SPLIT'
Check 'legacy empty owner launch stays PowerShell under a cmd default' (([string](Selection-Rpc 'session.text' @{} $node.id))-match 'P10B-LEGACY-OWNER')
Check 'legacy empty split launch stays PowerShell under a cmd default' (([string](Selection-Rpc 'session.text' @{} $node.paneIds[1]))-match 'P10B-LEGACY-SPLIT')
