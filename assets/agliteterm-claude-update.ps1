param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string]$Receipt,[Parameter(Mandatory)][string]$Nonce,[string]$NodeScript)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
function Read-AgentVersion {
    $prefix=if($NodeScript){@($NodeScript)}else{@()}
    $versionOutput=@(& $Executable @prefix --version 2>&1)
    if($LASTEXITCODE -ne 0){throw 'Claude version probe failed'}
    $versions=@($versionOutput|ForEach-Object{if("$_" -match '^\s*(\d+\.\d+\.\d+)(?:\s+\(Claude Code\))?\s*$'){[version]$Matches[1]}})
    if($versions.Count -ne 1){throw 'Claude version output is unknown or ambiguous'}
    return $versions[0]
}
try {
    $before=Read-AgentVersion
    Write-Host "Claude update: installed version $before"
    $prefix=if($NodeScript){@($NodeScript)}else{@()}
    & $Executable @prefix update
    if($LASTEXITCODE -ne 0){throw "Claude update failed (exit $LASTEXITCODE); no restart authorized"}
    $after=Read-AgentVersion
    $updated=$after -gt $before
    $json=@{nonce=$Nonce;updated=$updated;before="$before";after="$after"}|ConvertTo-Json -Compress
    # A unique receipt must not replace an existing file. Only a proven newer version permits restart.
    $file=[IO.File]::Open($Receipt,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes($json);$file.Write($bytes,0,$bytes.Length);$file.Flush()}finally{$file.Dispose()}
    if($updated){Write-Host "Installed $after; the app will request safe restarts of verified eligible panes."}
    else{Write-Host "Version remains $after; no agents will be restarted."}
    exit 0
}catch{Write-Error $_;exit 1}
