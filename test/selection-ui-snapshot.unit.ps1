# Synthetic native snapshots only; never opens the real clipboard or reads existing recovery files.
param([string]$Exe,[switch]$Strict)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/clipboard-guard.ps1"
$artifact=Join-Path ([IO.Path]::GetTempPath()) ('lite-snapshot-unit-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $artifact|Out-Null
$files=@();$checks=0
try {
    foreach($kind in 'empty','unicode','registered-binary','multiple'){
        $snapshot=[Agwinterm.Win32ControlTest.ClipboardSnapshot]::new()
        switch($kind){
            'unicode' {$snapshot.Formats=[uint32[]]@(13);$snapshot.Data=[byte[][]]@([Text.Encoding]::Unicode.GetBytes("synthetic Ω 🙂`r`nline`0"))}
            'registered-binary' {$snapshot.Formats=[uint32[]]@(49152);$snapshot.Data=[byte[][]]@([byte[]]@(0,1,255))}
            'multiple' {$snapshot.Formats=[uint32[]]@(13,49152);$snapshot.Data=[byte[][]]@([Text.Encoding]::Unicode.GetBytes("synthetic`0"),[byte[]]@(3,4,5))}
        }
        $file=Join-Path $artifact "$kind.dpapi";$files+=$file
        $snapshot.Save($file)
        $loaded=[Agwinterm.Win32ControlTest.ClipboardSnapshot]::Load($file)
        if(-not $snapshot.SameAs($loaded)){throw "Snapshot roundtrip failed: $kind"}
        $checks++;"PASS native DPAPI snapshot roundtrip: $kind"
        $refused=$false;try{$snapshot.Save($file)}catch{$refused=$true}
        if(-not $refused -or -not $snapshot.SameAs([Agwinterm.Win32ControlTest.ClipboardSnapshot]::Load($file))){throw "Snapshot overwrite protection failed: $kind"}
        $checks++;"PASS native DPAPI snapshot refuses overwrite: $kind"
    }
    "selection snapshot: $checks checks passed; no shared state touched"
}finally{
    foreach($file in $files){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
    Remove-Item -LiteralPath $artifact
}
