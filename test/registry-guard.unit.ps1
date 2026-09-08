# In-memory fault injection only. Never opens HKCU, clipboard, windows or processes.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/registry-guard.ps1"
$script:checks=0
function Check($Name,[bool]$Ok) { if (-not $Ok) { throw "FAIL $Name" }; $script:checks++; "PASS $Name" }
function Value($Data,[int]$Kind=1) { @{Exists=$true;Kind=$Kind;Value=$Data} }
$absent=@{Exists=$false;Kind=0;Value=$null}
$script:store=@{ A=(Value 'original'); B=$absent }
$read={param($name) $script:store[$name]}
$script:writes=0
$write={param($name,$value) $script:writes++; $script:store[$name]=$value}
$ledger=New-RegistryGuard @('A','B') $read
Set-RegistryGuardValue $ledger 'A' (Value 7 4) $read $write
Set-RegistryGuardValue $ledger 'B' (Value '' 1) $read $write
Restore-RegistryGuard $ledger $read $write
Check 'restore exact original kind/value and absent value' ((Test-RegistryGuardValue $store.A (Value 'original')) -and -not $store.B.Exists)
$beforeWrites=$writes; Restore-RegistryGuard $ledger $read $write
Check 'successful cleanup is idempotent without additional writes' ($writes -eq $beforeWrites)

$ledger=New-RegistryGuard @('A','B') $read
Set-RegistryGuardValue $ledger 'A' (Value 'ours') $read $write
Set-RegistryGuardValue $ledger 'B' (Value 9 4) $read $write
$store.A=Value 'foreign'; $threw=$false
try { Restore-RegistryGuard $ledger $read $write } catch { $threw=$true }
Check 'foreign change preserved and teardown fails' ($threw -and $store.A.Value -ceq 'foreign' -and $ledger.A.Touched)
Check 'conflict does not skip other captured values' (-not $store.B.Exists -and -not $ledger.B.Touched)
$beforeWrites=$writes; $threw=$false
try { Set-RegistryGuardValue $ledger 'A' (Value 'next') $read $write } catch { $threw=$true }
Check 'next test write refuses foreign value' ($threw -and $writes -eq $beforeWrites)

$ledger=New-RegistryGuard @('A') $read
$faultAfterWrite={param($name,$value) $script:store[$name]=$value; throw 'injected after write'}
try { Set-RegistryGuardValue $ledger 'A' (Value 'ours') $read $faultAfterWrite } catch {}
Restore-RegistryGuard $ledger $read $write
Check 'exception after mutation retains restore evidence' ($store.A.Value -ceq 'foreign' -and -not $ledger.A.Touched)

$ledger=New-RegistryGuard @('A') $read
try { Set-RegistryGuardValue $ledger 'A' (Value 'ours') $read { throw 'injected before write' } } catch {}
$beforeWrites=$writes; Restore-RegistryGuard $ledger $read $write
Check 'exception before mutation does not rewrite baseline' ($writes -eq $beforeWrites -and -not $ledger.A.Touched)

Check 'case-only external edit differs' (-not (Test-RegistryGuardValue (Value 'A') (Value 'a')))
Check 'same data with a different kind differs' (-not (Test-RegistryGuardValue (Value 7 4) (Value 7 11)))
Check 'empty present value is not absence' (-not (Test-RegistryGuardValue (Value '') $absent))
Check 'binary arrays compare every byte' ((Test-RegistryGuardValue (Value ([byte[]]@(1,2)) 3) (Value ([byte[]]@(1,2)) 3)) -and -not (Test-RegistryGuardValue (Value ([byte[]]@(1,2)) 3) (Value ([byte[]]@(1,3)) 3)))
Check 'multi-string shape preserved' ((Test-RegistryGuardValue (Value ([string[]]@()) 7) (Value ([string[]]@()) 7)) -and -not (Test-RegistryGuardValue (Value ([string[]]@('a')) 7) (Value 'a' 7)))

$ledger=New-RegistryGuard @('A') $read
Set-RegistryGuardValue $ledger 'A' (Value 'ours') $read $write
$threw=$false
try { Restore-RegistryGuard $ledger $read { throw 'injected restore failure' } } catch { $threw=$true }
Check 'failed restore retains outstanding ownership' ($threw -and $ledger.A.Touched)
$threw=$false
try { Set-RegistryGuardValue $ledger 'uncaptured' (Value 'x') $read $write } catch { $threw=$true }
Check 'uncaptured value cannot be changed' $threw
"registry guard: $script:checks checks passed; no shared state touched"
