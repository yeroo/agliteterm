#pragma once
#include <string>

namespace overlay_command {
// UTF-8 base64 is data, never PowerShell syntax. Ordinary command-local variables cannot
// replace the wrapper's status locals; marker delimiters use literals, not shared $e/$b.
// This is isolation from accidental collisions, not a sandbox against deliberately hostile code.
inline std::string line(const std::string& encoded) {
    return "[Console]::Write([string][char]27+']133;A'+[char]7+[char]27+']133;C'+[char]7);"
           "$LASTEXITCODE=$null;& {$__ag=@{c=0;j=0;t=$args[0]};try{$__ag.a=[scriptblock]::Create($__ag.t).Ast;"
           "foreach($__ag_b in 'Clean','End','Process','Begin','DynamicParam'){$__ag.p=$__ag.a.PSObject.Properties[$__ag_b+'Block'];if(!$__ag.p-or!$__ag.p.Value){continue};"
           "$__ag.i=[int]::MaxValue;$__ag.j=0;foreach($__ag_n in @($__ag.p.Value.Statements)+@($__ag.p.Value.Traps)){if($__ag_n){$__ag.i=[Math]::Min($__ag.i,$__ag_n.Extent.StartOffset);$__ag.j=[Math]::Max($__ag.j,$__ag_n.Extent.EndOffset)}};"
           "if($__ag.j){$__ag.t=$__ag.t.Insert($__ag.j,[string][char]10*2+'}finally{$__ag.q=$?;$__ag.c=if($null-ne$LASTEXITCODE){$LASTEXITCODE}else{[int](!$__ag.q)}}').Insert($__ag.i,'try{');break}};"
           "& ([scriptblock]::Create($__ag.t));$__ag.q=$?;if(!$__ag.j){$__ag.c=if($null-ne$LASTEXITCODE){$LASTEXITCODE}else{[int](!$__ag.q)}}}catch{$__ag.c=1;Microsoft.PowerShell.Utility\\Write-Error -ErrorRecord $_ -ea Continue};"
           "[Console]::Write([string][char]27+']133;D;'+$__ag.c+[char]7)} ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+encoded+"')))";
}
inline std::string encode(const std::string& text) {
    static const char* alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    const auto* bytes = reinterpret_cast<const unsigned char*>(text.data());
    for (size_t i=0; i<text.size(); i+=3) {
        unsigned v=bytes[i]<<16 | (i+1<text.size()?bytes[i+1]<<8:0) | (i+2<text.size()?bytes[i+2]:0);
        result+=alphabet[(v>>18)&63]; result+=alphabet[(v>>12)&63];
        result+=i+1<text.size()?alphabet[(v>>6)&63]:'=';
        result+=i+2<text.size()?alphabet[v&63]:'=';
    }
    return result;
}
inline bool fits(const std::string& line, size_t argumentCapacity) {
    return line.size() < argumentCapacity; // leave room for the protobuf string terminator
}
}
