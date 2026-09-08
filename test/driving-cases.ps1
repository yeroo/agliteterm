# Dot-sourced by control-honesty inside its owned sandbox. No process discovery/cleanup here.
# Restart, clipboard-format restoration and pixel/mouse cases remain separate acceptance gates.
if (-not (Get-Command Send-Raw -ErrorAction SilentlyContinue) -or -not $s) { throw 'driving cases need the control-honesty sandbox' }
function P9([string]$verb, [string]$target = '', [hashtable]$fields = @{}) {
    ConvertFrom-Json (Send-Raw (@{cmd=$verb; target=$target; args=$fields} | ConvertTo-Json -Depth 6 -Compress))
}
function P9Node([string]$id) { Nodes | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1 }
function P9WaitText([string]$id, [string]$needle) {
    $until = [DateTime]::UtcNow.AddSeconds(8)
    do {
        if ([string](P9 'session.text' $id).result -like "*$needle*") { return $true }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $until)
    return $false
}
"-- P9: driving a pane --"
$p9Ids = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($name in 'P9-A', 'P9-B', 'P9-C') {
        $r = P9 'session.new' '' @{name=$name; command="[Console]::WriteLine('P9-READY')"}
        if (-not $r.ok -or -not [string]$r.result) { throw "P9 session fixture failed: $($r | ConvertTo-Json -Compress)" }
        $p9Ids.Add([string]$r.result)
    }
    $a,$b,$c = $p9Ids
    Check 'P9 fixture reaches its live shell' (P9WaitText $a 'P9-READY')
    P9 'session.select' $a | Out-Null
    Check 'readonly on' ((P9 'session.readonly' $a @{op='on'}).result -eq 'on')
    Check 'readonly get' ((P9 'session.readonly' $a @{op='get'}).result -eq 'on')
    $r = P9 'session.readonly' $a @{op='bogus'}
    Check 'readonly typo refuses without toggling' (-not $r.ok -and (P9 'session.readonly' $a @{op='state'}).result -eq 'on')
    Check 'readonly missing target refuses' (-not (P9 'session.readonly' 'p9-no-such-pane' @{op='on'}).ok)
    $r = P9 'session.paste' $a
    Check 'readonly paste refuses before clipboard fallback' (-not $r.ok -and $r.error -like '*read-only; nothing pasted')
    P9 'session.type' $a @{text="[Console]::WriteLine('P9-'+'API-ALLOWED')`r"} | Out-Null
    Check 'API type still reaches readonly shell' (P9WaitText $a 'P9-API-ALLOWED')
    $human = "[Console]::WriteLine('P9-'+'HUMAN')`r"
    foreach ($ch in $human.ToCharArray()) { [LiteUi]::PostMessageW($s.Hwnd, 0x102, [IntPtr][int]$ch, [IntPtr]::Zero) | Out-Null }
    Start-Sleep -Milliseconds 250
    Check 'posted human chars do not reach readonly shell' ([string](P9 'session.text' $a).result -notlike '*P9-HUMAN*')
    Check 'readonly off' ((P9 'session.readonly' $a @{op='off'}).result -eq 'off')
    foreach ($ch in $human.ToCharArray()) { [LiteUi]::PostMessageW($s.Hwnd, 0x102, [IntPtr][int]$ch, [IntPtr]::Zero) | Out-Null }
    Check 'same posted human chars reach writable shell (non-vacuous gate)' (P9WaitText $a 'P9-HUMAN')

    foreach ($t in '', 'active') {
        Check "restore '$t' needs explicit pane" (-not (P9 'session.restore' $t @{command='echo pinned'}).ok)
        Check "bind '$t' needs explicit pane" (-not (P9 'session.bind' $t @{agent='claude'}).ok)
    }
    Check 'restore missing pane refuses' (-not (P9 'session.restore' 'p9-no-such-pane' @{command='echo pinned'}).ok)
    $pin = 'Write-Output "Quoted C:\Work\A"'
    $r = P9 'session.restore' $a @{command=$pin}
    Check 'pin reply identifies command, pane and session' ($r.ok -and $r.result.action -eq 'pinned' -and $r.result.pane -eq $a -and $r.result.session -eq $a -and $r.result.command -ceq $pin)
    Check 'tree restoreCommands reads exact pin' ([string](P9Node $a).restoreCommands.$a -ceq $pin)
    Check 'bind preserves command-shaped value' ((P9 'session.bind' $a @{agent='Claude --Resume C:\Work\A'}).result -eq 'bound')
    P9 'session.bind' $a @{agent='none'} | Out-Null
    $r = P9 'session.restore' $a @{command='none'}
    Check 'clear pin omits command' ($r.ok -and $r.result.action -eq 'cleared' -and -not $r.result.PSObject.Properties['command'])
    Check 'clear pin removes tree map' (-not (P9Node $a).PSObject.Properties['restoreCommands'])

    Check 'resize single pane refuses' (-not (P9 'session.resize' '' @{ratio=0.4}).ok)
    $r = P9 'session.split' $a @{op='on'; axis='vertical'}
    Check 'resize fixture split exists' ([bool]$r.ok)
    Check 'number ratio accepted' ((P9 'session.resize' '' @{ratio=0.3}).result -eq 'resized')
    Check 'tree ratio is slot share' ([Math]::Abs([double](P9Node $a).splitRatios[0] - 0.3) -lt 0.001)
    Check 'string ratio accepted' ((P9 'session.resize' '' @{ratio='0.4'}).result -eq 'resized')
    foreach ($bad in 'abc','NaN','Infinity','0.4junk','') {
        Check "bad ratio '$bad' refuses without moving" (-not (P9 'session.resize' '' @{ratio=$bad}).ok -and [Math]::Abs([double](P9Node $a).splitRatios[0] - 0.4) -lt 0.001)
    }
    Check 'wrong-axis growth refuses' (-not (P9 'session.resize' '' @{'grow-top'=1}).ok)
    Check 'zero wrong-axis growth is a no-op' ((P9 'session.resize' '' @{'grow-top'=0}).ok -and [Math]::Abs([double](P9Node $a).splitRatios[0] - 0.4) -lt 0.001)
    Check 'explicit ratio overrides valid growth' ((P9 'session.resize' '' @{ratio=0.4;'grow-right'=10}).ok -and [Math]::Abs([double](P9Node $a).splitRatios[0] - 0.4) -lt 0.001)
    Check 'ratio does not bypass growth validation' (-not (P9 'session.resize' '' @{ratio=0.4;'grow-right'='bad'}).ok)
    Check 'fractional cell growth refuses' (-not (P9 'session.resize' '' @{'grow-right'='1.5'}).ok)
    P9 'session.resize' '' @{ratio=-99} | Out-Null
    Check 'ratio clamps to lower limit' ([Math]::Abs([double](P9Node $a).splitRatios[0] - 0.05) -lt 0.001)
    P9 'session.swap' $a | Out-Null
    Check 'swap leaves divider share in slot order' ([Math]::Abs([double](P9Node $a).splitRatios[0] - 0.05) -lt 0.001)
    P9 'session.swap' $a | Out-Null
    P9 'session.split' $a @{op='off'} | Out-Null

    foreach ($id in $a,$c,$b) { P9 'session.select' $id | Out-Null }
    foreach ($step in @(@('begin','P9-B'),@('advance','P9-C'),@('advance','P9-A'),@('cancel','P9-B'),@('begin','P9-B'),@('advance','P9-C'),@('cancel','P9-B'))) {
        Check "cancel preserves MRU: $($step[0]) -> $($step[1])" ((P9 'session.switch' '' @{op=$step[0]}).result -eq $step[1])
    }
    foreach ($step in @(@('begin','P9-B'),@('advance','P9-C'),@('advance','P9-A'),@('advance-back','P9-C'),@('cancel','P9-B'),@('begin','P9-B'),@('advance','P9-C'),@('commit','P9-C'),@('begin','P9-C'),@('advance','P9-B'))) {
        Check "switch $($step[0]) -> $($step[1])" ((P9 'session.switch' '' @{op=$step[0]}).result -eq $step[1])
    }
    Check 'switch typo refuses' (-not (P9 'session.switch' '' @{op='bogus'}).ok)
    P9 'session.switch' '' @{op='commit'} | Out-Null

    P9 'session.select' $a | Out-Null
    $esc = [string][char]27
    P9 'session.write' $a @{text="$esc[3J$esc[2J$esc[H" + "xx игла yy`r`n漢字 needle`r`nNEEDLE$esc[?25l"} | Out-Null
    Check 'search Cyrillic case-insensitively' ((P9 'session.search' $a @{query='ИГЛА'}).result -eq '1 of 1')
    Check 'search both ASCII cases' ((P9 'session.search' $a @{query='needle'}).result -eq '1 of 2')
    Check 'search next' ((P9 'session.search' $a @{action='next'}).result -eq '2 of 2')
    Check 'search next wraps' ((P9 'session.search' $a @{action='next'}).result -eq '1 of 2')
    Check 'search prev wraps' ((P9 'session.search' $a @{action='prev'}).result -eq '2 of 2')
    Check 'search no matches' ((P9 'session.search' $a @{query='P9-ABSENT'}).result -eq 'no matches')
    $beforeClose = [string](P9 'session.text' $a).result
    Check 'search closes' ((P9 'session.search' $a @{action='close'}).result -eq 'closed')
    Check 'closing search leaves text unchanged' ([string](P9 'session.text' $a).result -ceq $beforeClose)
    Check 'search missing target refuses' (-not (P9 'session.search' 'p9-no-such-pane' @{query='needle'}).ok)
    # Put the main-screen marker in actual history, not merely on a grid that alt-screen replaces.
    P9 'session.write' $a @{text="$esc[3J$esc[2J$esc[H" + "P9-HISTORY-NEEDLE`r`n" + ("filler`r`n" * 300)} | Out-Null
    Check 'main history search fixture is non-vacuous' ((P9 'session.search' $a @{query='P9-HISTORY-NEEDLE'}).result -eq '1 of 1')
    P9 'session.write' $a @{text="$esc[?1049h$esc[2J$esc[H"} | Out-Null
    Check 'alternate search excludes main history' ((P9 'session.search' $a @{query='P9-HISTORY-NEEDLE'}).result -eq 'no matches')
    P9 'session.write' $a @{text='P9-HISTORY-NEEDLE'} | Out-Null
    Check 'alternate search counts only alternate grid' ((P9 'session.search' $a @{query='P9-HISTORY-NEEDLE'}).result -eq '1 of 1')
    P9 'session.write' $a @{text="$esc[?1049l"} | Out-Null
    Check 'returning to main searches history again' ((P9 'session.search' $a @{query='P9-HISTORY-NEEDLE'}).result -eq '1 of 1')
    P9 'session.search' $a @{action='close'} | Out-Null
    Check 'background remains refused' (-not (P9 'session.background' $a @{action='set';path='x.png'}).ok)
}
finally {
    foreach ($id in $p9Ids) { P9 'session.close' $id | Out-Null }
}
