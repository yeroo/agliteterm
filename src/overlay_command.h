#pragma once
#include <string>

namespace overlay_command {
// UTF-8 base64 is data, never PowerShell syntax. Ordinary command-local variables cannot
// replace the wrapper's status locals; marker delimiters use literals, not shared $e/$b.
// This is isolation from accidental collisions, not a sandbox against deliberately hostile code.
inline std::string line(const std::string& encoded) {
    return "[Console]::Write([string][char]27+']133;A'+[char]7+[char]27+']133;C'+[char]7);"
           "$LASTEXITCODE=$null;& {$__aglt=@{c=0;t=$args[0]};try{$__aglt.a=[scriptblock]::Create($__aglt.t).Ast;"
           "foreach($__aglt_b in 'Clean','End','Process','Begin','DynamicParam'){$__aglt.p=$__aglt.a.PSObject.Properties[$__aglt_b+'Block'];if(!$__aglt.p){continue};"
           "$__aglt.i=[int]::MaxValue;$__aglt.j=0;foreach($__aglt_n in @($__aglt.p.Value.Statements)+@($__aglt.p.Value.Traps)){if($__aglt_n){$__aglt.i=[Math]::Min($__aglt.i,$__aglt_n.Extent.StartOffset);$__aglt.j=[Math]::Max($__aglt.j,$__aglt_n.Extent.EndOffset)}};"
           "if($__aglt.j){$__aglt.t=$__aglt.t.Insert($__aglt.j,[string][char]10*2+'}finally{$__aglt.q=$?;$__aglt.c=if($null-ne$LASTEXITCODE){$LASTEXITCODE}else{[int](!$__aglt.q)}}').Insert($__aglt.i,'try{');break}};"
           "& ([scriptblock]::Create($__aglt.t));$__aglt.q=$?;if(!$__aglt.j){$__aglt.c=if($null-ne$LASTEXITCODE){$LASTEXITCODE}else{[int](!$__aglt.q)}}}catch{$__aglt.c=1;Microsoft.PowerShell.Utility\\Write-Error -ErrorRecord $_ -ea Continue};"
           "[Console]::Write([string][char]27+']133;D;'+$__aglt.c+[char]7)} ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+encoded+"')))";
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
