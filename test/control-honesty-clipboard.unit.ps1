param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/control-honesty.ps1",[ref]$tokens,[ref]$errors)
if($errors){throw $errors}
foreach($name in 'Selection','Honesty-Copy'){
    $definition=$ast.FindAll({param($n) $n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq $name},$true)
    if(@($definition).Count-ne 1){throw "Cannot locate actual $name fixture function"}
    . ([scriptblock]::Create($definition.Extent.Text))
}
# Deliberately retain the production parameter names: PowerShell scope lookup is case-insensitive.
function Invoke-SelectionClipboardCopy($Ledger,[scriptblock]$Action,[scriptblock]$Expected,[Func[bool]]$Owner){
    & $Action|Out-Null
    $actual=[string](& $Expected)
    if($actual-cne $script:wanted){throw "Clipboard expectation shadowed: [$actual] instead of [$script:wanted]"}
}
function Get-CtlResult($S,$Argv){return $script:wanted}
function Send-Ctl($S,$Argv){return '{"ok":true,"result":"fixture result"}'}
$s=$null;$honestyClipboard=$null;$checks=0
foreach($text in '', 'exact nonempty selection'){foreach($op in 'copy','finalize'){
    $script:wanted=$text
    $reply=Selection $op 'private-fixture-id'
    if(-not $reply.ok -or $reply.result-cne 'fixture result'){throw 'Selection action reply was lost'}
    $checks++
}}
"Honesty clipboard: $checks actual-wrapper expectation checks passed; no clipboard, host or registry access"
