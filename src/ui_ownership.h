#pragma once
#include <string>
namespace ui_ownership {
// Structural/control state shares the UI thread with menus, paint and workspace navigation.
// Potentially blocking shell input and emulator-only operations retain their own fine-grained
// locking on pipe workers. Never acquire the session lock while waiting for UI dispatch.
inline bool dispatchToUi(const std::string& cmd) {
    if (cmd == "session.type" || cmd == "session.paste" || cmd == "session.write" ||
        cmd == "session.text" || cmd == "session.output" || cmd == "session.copy") return false;
    return cmd.rfind("session.", 0) == 0 || cmd.rfind("selection.", 0) == 0 ||
        cmd.rfind("workspace.", 0) == 0 || cmd.rfind("sidebar.", 0) == 0 ||
        cmd.rfind("font.", 0) == 0 || cmd == "sidebar" || cmd == "font" || cmd == "tree" || cmd == "quick";
}
}
