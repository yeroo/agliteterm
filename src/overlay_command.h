#pragma once
#include <string>

namespace overlay_command {
// UTF-16LE base64 is data, never PowerShell syntax. Ordinary command-local variables cannot
// replace the wrapper's status locals; marker delimiters use literals, not shared $e/$b.
// This is isolation from accidental collisions, not a sandbox against deliberately hostile code.
inline std::string line(const std::string& encoded) {
    return "[Console]::Write([string][char]27+']133;A'+[char]7+[char]27+']133;C'+[char]7);"
           "$LASTEXITCODE=$null;$c=1;try{& ([scriptblock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('"
           + encoded +
           "'))+[char]10+'$q=$?;$c=if($null -ne $LASTEXITCODE){$LASTEXITCODE}elseif($q){0}else{1};Set-Variable -Name c -Scope 1 -Value $c'))}catch{$c=1};"
           "[Console]::Write([string][char]27+']133;D;'+$c+[char]7)";
}
inline bool fits(const std::string& line, size_t argumentCapacity) {
    return line.size() < argumentCapacity; // leave room for the protobuf string terminator
}
}
