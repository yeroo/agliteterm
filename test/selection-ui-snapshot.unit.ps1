# Synthetic data only: no clipboard, registry, window, or process mutations.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/selection-ui-env.ps1",[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Harness parse failed'}
foreach($name in @('Export-SelectionClipboard','Import-SelectionClipboard','Clipboard-Fingerprint')){
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $name},$true)
    if(-not $definition){throw "Missing snapshot function: $name"}
    . ([scriptblock]::Create($definition.Extent.Text))
}
$artifact=Join-Path (Split-Path $PSScriptRoot -Parent) ('.revmux/snapshot-unit-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $artifact|Out-Null
$source=[Windows.Forms.DataObject]::new()
$source.SetData('Text',$false,"synthetic unicode: Ω 🙂`r`nline")
$source.SetData('EmptyText',$false,'')
$source.SetData('Bytes',$false,[byte[]]@(0,1,255))
$source.SetData('Stream',$false,[IO.MemoryStream]::new([byte[]]@(3,4,5)))
$source.SetData('Strings',$false,[string[]]@('a','b'))
$source.SetData('OneString',$false,[string[]]@('a'))
$source.SetData('EmptyStrings',$false,[string[]]@())
$bitmap=[Drawing.Bitmap]::new(2,2);$bitmap.SetPixel(0,0,[Drawing.Color]::Red)
$source.SetData('Bitmap',$false,$bitmap)
foreach($fixture in @($source,[Windows.Forms.DataObject]::new())){
    $path=Join-Path $artifact ([guid]::NewGuid().ToString('N')+'.dpapi')
    Export-SelectionClipboard $fixture $path
    $actual=Import-SelectionClipboard $path
    if($actual.GetFormats($false).Count-ne $fixture.GetFormats($false).Count){throw 'Snapshot format count changed'}
    foreach($format in $fixture.GetFormats($false)){
        if(-not $actual.GetDataPresent($format,$false) -or (Clipboard-Fingerprint $actual.GetData($format,$false))-cne (Clipboard-Fingerprint $fixture.GetData($format,$false))){throw "Snapshot roundtrip failed: $format"}
        "PASS encrypted snapshot roundtrip: $format"
    }
}
'PASS empty clipboard snapshot roundtrip; no shared state touched'
