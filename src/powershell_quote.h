// A PowerShell single-quoted string, for text lite TYPES into a shell or passes on a command line.
//
// PowerShell ends a single-quoted string at any of FIVE characters, not only the ASCII apostrophe:
// U+0027, U+2018, U+2019, U+201A and U+201B (its tokenizer treats the typographic quotes as quotes,
// and its own escaper, CodeGeneration.EscapeSingleQuotedStringContent, doubles all five). Doubling
// only U+0027 lets a directory named `x<U+2019>; Start-Process calc; <U+2019>` close the string and
// run the rest as commands (revmux lite-118 r1), and a harmless `Bob<U+2019>s files` leave the line
// an unterminated string. The input is UTF-8; the typographic four are E2 80 98 .. E2 80 9B.
#pragma once
#include <string>

namespace powershell_quote {
// `value` with every single-quote character doubled: the inside of a single-quoted string.
inline std::string body(const std::string& value) {
    std::string out;
    for (size_t i = 0; i < value.size(); ++i) {
        const unsigned char c = static_cast<unsigned char>(value[i]);
        if (c == '\'') { out += "''"; continue; }
        if (c == 0xE2 && i + 2 < value.size() && static_cast<unsigned char>(value[i + 1]) == 0x80) {
            const unsigned char last = static_cast<unsigned char>(value[i + 2]);
            if (last >= 0x98 && last <= 0x9B) { out.append(value, i, 3); out.append(value, i, 3); i += 2; continue; }
        }
        out += value[i];
    }
    return out;
}
inline std::string literal(const std::string& value) { return "'" + body(value) + "'"; }
}
