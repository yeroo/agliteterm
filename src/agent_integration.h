#pragma once
#include <string>
#include <vector>
#include "commands.h"

namespace agent_integration {
inline bool uuid(const std::string& s) {
    if (s.size() != 36) return false;
    for (size_t i = 0; i < s.size(); ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (s[i] != '-') return false; }
        else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f') || (s[i] >= 'A' && s[i] <= 'F'))) return false;
    }
    return true;
}
inline std::string normalizedPath(std::string s) {
    s = commands::lower(s); for (auto& c : s) if (c == '\\') c = '/'; return s;
}
inline std::string basename(const std::string& s) {
    auto path = normalizedPath(s); auto slash = path.find_last_of('/');
    return path.substr(slash == std::string::npos ? 0 : slash + 1);
}
struct Identity {
    std::string conversation;
    bool dangerous = false;
    size_t executableArgs = 1;
};
// Identity comes from a live, owned process's real image and argv, not its title or cwd.
// Bare/continue/headless invocations deliberately cannot be adopted by guessing a transcript.
inline bool identify(const std::string& image, const std::vector<std::string>& argv, Identity& out) {
    if (argv.empty()) return false;
    Identity next;
    const auto exe = basename(image);
    if (exe == "node.exe") {
        if (argv.size() < 2) return false;
        const auto path = normalizedPath(argv[1]);
        const std::string suffix = "/node_modules/@anthropic-ai/claude-code/cli.js";
        if (path.size() <= suffix.size() || path.compare(path.size() - suffix.size(), suffix.size(), suffix) != 0) return false;
        next.executableArgs = 2;
    } else if (exe != "claude.exe") return false;
    for (size_t i = next.executableArgs; i < argv.size(); ++i) {
        const auto& arg = argv[i];
        if (arg == "--print" || arg == "-p" || arg == "--continue" || arg == "-c" ||
            arg.rfind("--print=",0) == 0 || arg.rfind("--continue=",0) == 0) return false;
        if (arg == "--dangerously-skip-permissions") next.dangerous = true;
        std::string value;
        if (arg == "--resume" || arg == "--session-id" || arg == "-r") {
            if (++i == argv.size()) return false;
            value = argv[i];
        } else if (arg.rfind("--resume=",0) == 0) value = arg.substr(9);
        else if (arg.rfind("--session-id=",0) == 0) value = arg.substr(13);
        else if (arg.rfind("-r=",0) == 0) value = arg.substr(3);
        else continue;
        if (!uuid(value) || !next.conversation.empty()) return false;
        next.conversation = commands::lower(value);
    }
    if (next.conversation.empty()) return false;
    out = next; return true;
}
inline std::vector<std::string> resumeArgs(const std::vector<std::string>& argv, const Identity& id, bool yolo) {
    std::vector<std::string> result;
    for (size_t i = id.executableArgs; i < argv.size(); ++i) {
        const auto& arg = argv[i];
        if (arg == "--resume" || arg == "--session-id" || arg == "-r") { ++i; continue; }
        if (arg.rfind("--resume=",0) == 0 || arg.rfind("--session-id=",0) == 0 || arg.rfind("-r=",0) == 0) continue;
        if (arg == "--dangerously-skip-permissions") continue;
        result.push_back(arg);
    }
    result.push_back("--resume"); result.push_back(id.conversation);
    if (yolo || id.dangerous) result.push_back("--dangerously-skip-permissions");
    return result;
}
}
