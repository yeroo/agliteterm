# Transaction faults only: fake clipboard, no native clipboard/window/registry or suite token.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/selection-clipboard.ps1"
$guard=[Agwinterm.Win32ControlTest.ClipboardGuard];$script:count=0
function Check($Name,[bool]$Ok){if(-not $Ok){throw "FAIL $Name"};$script:count++;"PASS $Name"}
function Fixture {
    $script:fake=[Agwinterm.Win32ControlTest.FakeClipboardApi]::new();$guard::Api=$fake
    $fake.Store[13]=[Text.Encoding]::Unicode.GetBytes("original`0")
    $fake.Store[1]=[Text.Encoding]::ASCII.GetBytes("original`0")
    $fake.Store[7]=[Text.Encoding]::ASCII.GetBytes("original`0")
    $fake.Store[16]=[byte[]]@(9,4,0,0)
    $script:ledger=New-SelectionClipboardLedger ($guard::Take())
}
function AppCopy([string]$Value){$null=$fake.Open();$null=$fake.Empty();$null=$fake.Set(13,[Text.Encoding]::Unicode.GetBytes($Value+"`0"));$fake.Close()}
function Refused([scriptblock]$Operation){try{& $Operation|Out-Null;return $false}catch{return $true}}
try {
    Fixture;Write-SelectionClipboardMarker $ledger 'marker'
    Check 'assertion reads only the proven marker generation' ((Read-SelectionClipboardText $ledger) -ceq 'marker')
    Invoke-SelectionClipboardCopy $ledger {AppCopy 'one'} {'one'} ([Func[bool]]{$true})
    $first=$ledger.Receipt.Sequence
    Invoke-SelectionClipboardCopy $ledger {AppCopy 'two'} {'two'} ([Func[bool]]{$true})
    Check 'every app copy replaces its receipt' ($ledger.Sequence -ne $first -and -not $ledger.Pending)
    Restore-SelectionClipboardLedger $ledger
    Check 'success restores all original formats' ($ledger.Before.SameAs($guard::Take()) -and -not $ledger.Touched)

    Fixture;$sets=$fake.Sets;Restore-SelectionClipboardLedger $ledger
    Check 'untouched ledger performs no writes' ($fake.Sets -eq $sets)
    Fixture;AppCopy 'foreign';$sets=$fake.Sets;Restore-SelectionClipboardLedger $ledger
    Check 'untouched ledger permits cleanup while preserving a newer copy' ($fake.Sets -eq $sets -and -not $ledger.Touched)
    Fixture
    Check 'empty owned copy fails the no-copy assertion' (Refused {Invoke-SelectionClipboardCopy $ledger {AppCopy ''} {''} ([Func[bool]]{$true})})
    Check 'unexpected empty write keeps a usable receipt' ($ledger.Touched -and -not $ledger.Pending -and $ledger.Receipt.Sequence -eq $fake.Seq)
    Restore-SelectionClipboardLedger $ledger
    Check 'unexpected empty write can still restore original data' ($ledger.Before.SameAs($guard::Take()))
    foreach($priorWrite in @($false,$true)){
        Fixture;if($priorWrite){Write-SelectionClipboardMarker $ledger 'prior'}
        $priorReceipt=$ledger.Receipt;$priorSequence=$ledger.Sequence;$fake.EmptyFails=$true
        Check "refused EmptyClipboard fails marker (prior write=$priorWrite)" (Refused {Write-SelectionClipboardMarker $ledger 'next'})
        Check "proven failed marker preserves prior receipt (prior write=$priorWrite)" (-not $ledger.Pending -and $ledger.Sequence -eq $priorSequence -and $ledger.Receipt -eq $priorReceipt)
        $fake.EmptyFails=$false;Restore-SelectionClipboardLedger $ledger
        Check "cleanup after no-op marker restores or leaves baseline (prior write=$priorWrite)" ($ledger.Before.SameAs($guard::Take()))
    }
    Fixture;Invoke-SelectionClipboardCopy $ledger {} {''} ([Func[bool]]{throw 'no owner check for no-copy'})
    Check 'empty no-copy action preserves prior receipt' (-not $ledger.Pending -and $null -eq $ledger.Receipt)
    Check 'missing nonempty copy remains unproven' (Refused {Invoke-SelectionClipboardCopy $ledger {} {'expected'} ([Func[bool]]{$true})})
    Check 'unproven copy blocks cleanup and later marker' ((Refused {Restore-SelectionClipboardLedger $ledger}) -and (Refused {Write-SelectionClipboardMarker $ledger 'later'}))

    Fixture;Write-SelectionClipboardMarker $ledger 'prior';$priorReceipt=$ledger.Receipt
    $fake.FailOpensAfter=$fake.Opens+1 # allow marker snapshot, refuse the writer's open
    Check 'unopened marker retains the earlier proven receipt without pending mutation' ((Refused {Write-SelectionClipboardMarker $ledger 'next'}) -and -not $ledger.Pending -and $ledger.Receipt -eq $priorReceipt)
    $fake.FailOpensAfter=0;Restore-SelectionClipboardLedger $ledger
    Check 'earlier write restores after marker open refusal' ($ledger.Before.SameAs($guard::Take()))

    Fixture;Write-SelectionClipboardMarker $ledger 'marker';AppCopy 'marker';$sets=$fake.Sets
    Check 'assertion refuses to read newer contents' (Refused {Read-SelectionClipboardText $ledger})
    Check 'same-text foreign generation blocks marker and restore' ((Refused {Write-SelectionClipboardMarker $ledger 'next'}) -and (Refused {Restore-SelectionClipboardLedger $ledger}) -and $fake.Sets -eq $sets)
    Fixture
    Check 'action throw leaves pending recovery' ((Refused {Invoke-SelectionClipboardCopy $ledger {AppCopy 'late';throw 'injected'} {'late'} ([Func[bool]]{$true})}) -and $ledger.Pending)
    Check 'action throw cannot restore a stale receipt' (Refused {Restore-SelectionClipboardLedger $ledger})
    Fixture
    Check 'foreign owner never yields a receipt' ((Refused {Invoke-SelectionClipboardCopy $ledger {AppCopy 'same'} {'same'} ([Func[bool]]{$false})}) -and $null -eq $ledger.Receipt -and $ledger.Pending)
    Fixture
    Check 'expected-selection read failure keeps recovery pending' ((Refused {Invoke-SelectionClipboardCopy $ledger {AppCopy 'x'} {throw 'pipe failed'} ([Func[bool]]{$true})}) -and $ledger.Pending)
    Fixture;$fake.OpenFails=$true
    Check 'unreadable pre-marker clipboard leaves original untouched' ((Refused {Write-SelectionClipboardMarker $ledger 'x'}) -and -not $ledger.Touched -and -not $ledger.Pending)
    Fixture;Write-SelectionClipboardMarker $ledger 'marker';$fake.SetFailures=100
    Check 'failed native restore is not clean' (Refused {Restore-SelectionClipboardLedger $ledger})
    Check 'failed native restore cannot be retried with stale receipt' (Refused {Restore-SelectionClipboardLedger $ledger})
    "selection clipboard ledger: $script:count checks passed; no shared state touched"
} finally {$guard::Api=[Agwinterm.Win32ControlTest.NativeClipboardApi]::new()}
