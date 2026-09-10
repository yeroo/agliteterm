#pragma once
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <vector>

// session.new contract; mirrored by Full's SessionCommand.cs.
namespace session_command {
struct Launch { std::string app; std::vector<std::string> args; };
inline std::wstring wide(const std::string& s) {
    const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0);
    std::wstring result(n, L'\0');
    if (n) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), &result[0], n);
    return result;
}
inline std::string utf8(const wchar_t* s) {
    const int n = WideCharToMultiByte(CP_UTF8, 0, s, (int)wcslen(s), nullptr, 0, nullptr, nullptr);
    std::string result(n, '\0');
    if (n) WideCharToMultiByte(CP_UTF8, 0, s, (int)wcslen(s), &result[0], n, nullptr, nullptr);
    return result;
}
inline bool blank(wchar_t c) {
    // Unicode White_Space, matching .NET Char.IsWhiteSpace.
    return (c >= 9 && c <= 13) || c == 32 || c == 0x85 || c == 0xa0 || c == 0x1680 ||
        (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000;
}
inline bool create(const std::string& command, const std::string* mode, bool wait, bool profile,
                   Launch& launch, std::string& error) {
    launch = {}; error.clear();
    const auto text = wide(command);
    size_t start = 0; while (start < text.size() && blank(text[start])) ++start;
    if (mode && *mode != "powershell" && *mode != "direct") error = "command-mode must be powershell or direct";
    else if (!command.empty() && text.empty()) error = "command must be valid UTF-8";
    else if (start == text.size()) {
        if (mode || wait) error = "command-mode and wait require a nonempty command";
    }
    else if (profile) error = "command and profile are mutually exclusive";
    else if (command.find('\0') != std::string::npos) error = "command must not contain NUL";
    else if (mode && *mode == "direct" && wait) error = "wait requires powershell mode; direct mode does not add a shell";
    else if (mode && *mode == "direct") {
        int count = 0;
        auto** words = CommandLineToArgvW(text.c_str() + start, &count);
        if (!words) error = "could not parse command";
        else {
            if (count == 0 || !*words[0]) error = "command requires an executable";
            else {
                launch.app = utf8(words[0]);
                for (int i = 1; i < count; ++i) launch.args.push_back(utf8(words[i]));
            }
            LocalFree(words);
        }
    }
    else launch = { "powershell.exe", { "-NoLogo", "-NoExit", "-Command", command } };
    bool oversized = launch.app.size() >= 260 || launch.args.size() > 16;
    for (const auto& arg : launch.args) oversized = oversized || arg.size() >= 2048;
    if (oversized) error = "command exceeds host capacity (app 259 bytes, 16 arguments, 2047 bytes each)";
    if (error.empty()) return true;
    launch = {};
    error = "session.new: " + error + "; nothing created";
    return false;
}
}
