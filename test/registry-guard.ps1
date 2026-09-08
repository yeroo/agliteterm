# Expected-value guard for the exact HKCU values a fixture changes. Callbacks keep its state
# machine testable without HKCU. Native adapters preserve value kinds and unexpanded strings.
# Windows has no value-level compare/exchange here: checks detect observed conflicts, not a
# promise of atomicity against a writer racing between GetValue and SetValue. The suite token
# remains mandatory. Never adopt the current value as an expected value during teardown.
function Read-RegistryGuardValue($Key,[string]$Name) {
    if (-not $Key -or $Key.GetValueNames() -notcontains $Name) {
        return @{ Exists=$false; Kind=0; Value=$null }
    }
    $value=$Key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($value -is [Array]) { $value=$value.Clone() }
    return @{ Exists=$true; Kind=[int]$Key.GetValueKind($Name); Value=$value }
}
function Write-RegistryGuardValue($Key,[string]$Name,$State) {
    if ($State.Exists) { $Key.SetValue($Name,$State.Value,[Microsoft.Win32.RegistryValueKind]$State.Kind) }
    else { $Key.DeleteValue($Name,$false) }
}
function Test-RegistryGuardValue($Left,$Right) {
    if ([bool]$Left.Exists -ne [bool]$Right.Exists) { return $false }
    if (-not $Left.Exists) { return $true }
    if ($Left.Kind -ne $Right.Kind) { return $false }
    # Array shape is significant: one MULTI_SZ item is not a scalar REG_SZ, nor is an empty
    # MULTI_SZ a missing value. Compare elements ordinally; PowerShell's default equality folds case.
    if (($Left.Value -is [Array]) -ne ($Right.Value -is [Array])) { return $false }
    $a=@($Left.Value); $b=@($Right.Value)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i=0; $i -lt $a.Count; $i++) {
        if ($a[$i].GetType() -ne $b[$i].GetType() -or $a[$i] -cne $b[$i]) { return $false }
    }
    return $true
}
function New-RegistryGuard([string[]]$Names,[scriptblock]$Read) {
    $ledger=@{}
    foreach ($name in $Names) {
        $before=& $Read $name
        $ledger[$name]=@{ Before=$before; Expected=$before; Touched=$false }
    }
    return $ledger
}
function Set-RegistryGuardValue($Ledger,[string]$Name,$Value,[scriptblock]$Read,[scriptblock]$Write) {
    if (-not $Ledger.ContainsKey($Name)) { throw "Registry value was not captured: $Name" }
    $entry=$Ledger[$Name]
    if (-not (Test-RegistryGuardValue (& $Read $Name) $entry.Expected)) {
        throw "Registry conflict before write: $Name; newer value preserved"
    }
    # Record the intended atomic value write before calling it, so an exception AFTER the native
    # write cannot leave teardown believing it never touched the value. A partial/foreign result
    # matches neither baseline nor expected and must be preserved for explicit recovery.
    $entry.Expected=$Value; $entry.Touched=$true
    & $Write $Name $Value | Out-Null
    if (-not (Test-RegistryGuardValue (& $Read $Name) $Value)) {
        throw "Registry write could not be verified: $Name"
    }
}
function Restore-RegistryGuard($Ledger,[scriptblock]$Read,[scriptblock]$Write) {
    $failures=[Collections.Generic.List[string]]::new()
    foreach ($name in $Ledger.Keys) {
        $entry=$Ledger[$name]
        if (-not $entry.Touched) { continue }
        try {
            $held=& $Read $name
            if (Test-RegistryGuardValue $held $entry.Before) { $entry.Touched=$false; continue }
            if (-not (Test-RegistryGuardValue $held $entry.Expected)) {
                throw 'newer or unproven value preserved'
            }
            & $Write $name $entry.Before | Out-Null
            if (-not (Test-RegistryGuardValue (& $Read $name) $entry.Before)) {
                throw 'restoration could not be verified'
            }
            $entry.Touched=$false
        } catch { $failures.Add("${name}: $($_.Exception.Message)") }
    }
    if ($failures.Count) { throw "Registry restoration incomplete: $($failures -join '; ')" }
}
