# Pure fault injection: executes only the cleanup coordinator, never GUI/registry/clipboard APIs.
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/selection-ui-env.ps1",[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Harness parse failed'}
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Invoke-SelectionCleanup'},$true)
if(-not $definition){throw 'Cleanup coordinator missing'}
. ([scriptblock]::Create($definition.Extent.Text))
foreach($mask in 0..7){
    $script:called=[Collections.Generic.List[string]]::new()
    $ok=Invoke-SelectionCleanup {
        $script:called.Add('processes');if($mask-band 1){throw 'injected process teardown failure'}
    } {
        $script:called.Add('registry');if($mask-band 2){throw 'injected registry restore failure'}
    } {
        $script:called.Add('clipboard');if($mask-band 4){throw 'injected clipboard restore failure'}
    }
    if(($script:called-join ',')-ne 'processes,registry,clipboard'){throw "Cleanup skipped a restoration step, mask $mask"}
    if($ok-ne ($mask-eq 0)){throw "Cleanup falsely reported success/failure, mask $mask"}
    "PASS cleanup fault mask ${mask}: all three attempted; success=$ok"
}
'selection-ui cleanup: 8 fault combinations passed; no shared state touched'
$clipboard=[pscustomobject]@{Marker='original clipboard snapshot'}
$ok=Invoke-SelectionCleanup {} {} {
    if($clipboard.Marker-ne 'original clipboard snapshot'){throw 'Coordinator shadowed the caller clipboard snapshot'}
}
if(-not $ok){throw 'Cleanup callback lost access to the saved clipboard'}
'PASS cleanup callbacks retain the caller clipboard snapshot'
