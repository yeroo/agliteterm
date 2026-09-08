#pragma once
#include <string>
#include "profiles.h"

namespace shell_configuration {
inline bool powershell(const std::string& path) {
    const auto separator = path.find_last_of("/\\");
    const auto name = profiles::folded(path.substr(separator == std::string::npos ? 0 : separator + 1));
    return name == "pwsh.exe" || name == "powershell.exe" || name == "pwsh" || name == "powershell";
}
inline std::string literal(const std::string& value) {
    std::string out = "'";
    for (char c : value) { out += c; if (c == '\'') out += '\''; }
    return out + "'";
}
inline const std::string& replay(const std::string& binding, const std::string& pin,
                                 const std::string& captured, bool enabled) {
    static const std::string empty;
    return !binding.empty() ? binding : !pin.empty() ? pin : enabled ? captured : empty;
}
}
