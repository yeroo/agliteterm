# Only FakeClipboardApi. No native clipboard/window/process calls, no shared token needed.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/clipboard-guard.ps1"
$guard=[Agwinterm.Win32ControlTest.ClipboardGuard]
$script:count=0
function Check($name,[bool]$ok) { if(-not $ok){throw "FAIL $name"};$script:count++;"PASS $name" }
function Fixture {
    $script:fake=[Agwinterm.Win32ControlTest.FakeClipboardApi]::new()
    $guard::Api=$fake
    $fake.Store[13]=[Text.Encoding]::Unicode.GetBytes("baseline`0")
    $fake.Store[1]=[Text.Encoding]::ASCII.GetBytes("baseline`0")
    $fake.Store[7]=[Text.Encoding]::ASCII.GetBytes("baseline`0")
    $fake.Store[16]=[byte[]]@(9,4,0,0)
    $script:baseline=$guard::Take()
}
function App-Copy([string]$text) {
    # A separately completed application write, including Windows' close-time synthesized formats.
    $fake.Open()|Out-Null; $fake.Empty()|Out-Null
    $fake.Set(13,[Text.Encoding]::Unicode.GetBytes($text+"`0"))|Out-Null; $fake.Close()
}
try {
    Fixture; $before=$fake.Seq; App-Copy 'first'
    $script:ownerCheckedWhileOpen=$false
    $receipt=$guard::ConfirmCopy('first',$before,[Func[bool]]{ $script:ownerCheckedWhileOpen=$fake.IsOpen; return $true })
    Check 'expected copy records stable generation with ownership checked under open' ($receipt.State -eq 'written' -and $receipt.Sequence -eq $fake.Seq -and $ownerCheckedWhileOpen)
    $before=$receipt.Sequence; App-Copy 'second'
    $receipt=$guard::ConfirmCopy('second',$before,[Func[bool]]{$true})
    $restored=$guard::RestoreExact($baseline,$receipt)
    Check 'second copy gets its own receipt and restores whole original snapshot' ($receipt.State -eq 'written' -and $restored.State -eq 'restored' -and $baseline.SameAs($guard::Take()))

    Fixture; $before=$fake.Seq; App-Copy 'same'
    $receipt=$guard::ConfirmCopy('same',$before,[Func[bool]]{$true})
    App-Copy 'same'; $sets=$fake.Sets
    $restored=$guard::RestoreExact($baseline,$receipt)
    Check 'newer copy of identical text is preserved, not adopted by content' ($restored.State -eq 'changed' -and $fake.Sets -eq $sets)

    Fixture; $before=$fake.Seq; App-Copy 'expected'; $sets=$fake.Sets
    $receipt=$guard::ConfirmCopy('expected',$before,[Func[bool]]{$false})
    Check 'same text from a foreign window is not an owned receipt' ($receipt.State -eq 'changed' -and $fake.Sets -eq $sets)
    Check 'unproven receipt cannot authorize restoration' (($guard::RestoreExact($baseline,$receipt)).State -eq 'unread' -and $fake.Sets -eq $sets)

    Fixture; $before=$fake.Seq; App-Copy 'different'
    Check 'owned window with unexpected text is unverified, not foreign' (($guard::ConfirmCopy('expected',$before,[Func[bool]]{$true})).State -eq 'unverified')
    Fixture; $before=$fake.Seq
    Check 'no generation change is not a new write receipt' (($guard::ConfirmCopy('expected',$before,[Func[bool]]{throw 'must not check owner without a write'})).State -eq 'unchanged')
    App-Copy 'expected'; $fake.GetFails=13
    $receipt=$guard::ConfirmCopy('expected',$before,[Func[bool]]{$true})
    Check 'unreadable copy fails closed without claiming its generation' ($receipt.State -eq 'unverified' -and -not $fake.IsOpen)
    $fake.GetFails=0
    Fixture; $before=$fake.Seq; App-Copy 'expected'
    $receipt=$guard::ConfirmCopy('expected',$before,[Func[bool]]{$true}); $fake.SetFailures=100
    Check 'failed restore is mutation, never foreign preservation' (($guard::RestoreExact($baseline,$receipt)).State -eq 'mutated')
    Fixture; $before=$fake.Seq; App-Copy 'expected'; $threw=$false
    try {$null=$guard::ConfirmCopy('expected',$before,[Func[bool]]{throw 'owner inspection failed'})}catch{$threw=$true}
    Check 'owner-check exception still closes clipboard' ($threw -and -not $fake.IsOpen)
    "clipboard receipts: $script:count checks passed; no shared state touched"
} finally { $guard::Api=[Agwinterm.Win32ControlTest.NativeClipboardApi]::new() }
