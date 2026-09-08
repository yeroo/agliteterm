#pragma once
#include <string>
#include <mutex>
#include "profiles.h"

namespace shell_configuration {
// Serialize a complete editing-input write with the no-prior-input decision. The callback must not take
// the global session lock: callers resolve stable session identity before entering this gate.
class InputGate {
    std::mutex mutex;
    bool written = false;
public:
    template<class Write> bool write(bool editingInput, bool requireUntouched, Write transfer) {
        // Reader-thread terminal replies must not wait behind a possibly backpressured paste:
        // that reader must keep draining shell output so the editing write can finish.
        if (!editingInput && !requireUntouched) { transfer(); return true; }
        std::lock_guard<std::mutex> hold(mutex);
        if (requireUntouched && written) return false;
        if (editingInput) written = true; // even a failed/partial write makes emptiness unproven
        transfer();
        return true;
    }
};
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
