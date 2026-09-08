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
    std::vector<std::string> options;
};
inline bool optionIn(const std::string& arg, const std::string& choices) {
    return choices.find("|" + arg + "|") != std::string::npos;
}
inline bool publishBinding(std::string& current, unsigned long long& generation,
        unsigned long long expectedGeneration, const std::string& next) {
    if (generation != expectedGeneration) return false;
    current = next; ++generation; return true;
}
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
        if (!(path.size() > 3 && path[1] == ':' && path[2] == '/') && path.rfind("//",0) != 0) return false;
        if (path.size() <= suffix.size() || path.compare(path.size() - suffix.size(), suffix.size(), suffix) != 0) return false;
        next.executableArgs = 2;
    } else if (exe != "claude.exe") return false;
    bool positional = false, prompt = false;
    for (size_t i = next.executableArgs; i < argv.size(); ++i) {
        const auto& arg = argv[i];
        if (!positional && arg == "--") { positional = true; continue; }
        if (positional || arg.empty() || arg[0] != '-') {
            // Never replay the initial user request on a lifecycle resume.
            if (prompt || next.conversation.empty()) return false;
            prompt = true; continue;
        }
        const auto equals = arg.find('=');
        const auto flag = arg.substr(0,equals);
        const bool identity = optionIn(flag,"|--resume|--session-id|-r|");
        const bool valued = optionIn(flag,"|--model|--agent|--agents|--append-system-prompt|--append-system-prompt-file|--system-prompt|--system-prompt-file|--effort|--name|-n|--permission-mode|--settings|--setting-sources|--plugin-dir|--debug-file|--teammate-mode|");
        if (identity || valued) {
            std::string value;
            if (equals != std::string::npos) value = arg.substr(equals+1);
            else { if (++i == argv.size()) return false; value = argv[i]; }
            if (value.empty()) return false;
            if (identity) {
                if (!uuid(value) || !next.conversation.empty()) return false;
                next.conversation = commands::lower(value);
            } else { next.options.push_back(flag); next.options.push_back(value); }
            continue;
        }
        // Conservative allowlist: unknown/variadic flags and alternate lifecycle modes cannot
        // prove argv identity. In particular --fork-session does not run the supplied UUID.
        if (equals != std::string::npos || !optionIn(flag,"|--dangerously-skip-permissions|--allow-dangerously-skip-permissions|--verbose|--bare|--chrome|--no-chrome|--disable-slash-commands|--ide|--safe-mode|--strict-mcp-config|--ax-screen-reader|")) return false;
        if (flag == "--dangerously-skip-permissions") next.dangerous = true;
        else next.options.push_back(flag);
    }
    if (next.conversation.empty()) return false;
    out = next; return true;
}
inline std::vector<std::string> resumeArgs(const std::vector<std::string>& argv, const Identity& id, bool yolo) {
    (void)argv; // Parsed options, never a second flag scan through opaque option values.
    std::vector<std::string> result;
    for (size_t i = 0; i < id.options.size(); ++i) {
        const auto& arg = id.options[i];
        if (yolo && arg == "--permission-mode") { ++i; continue; }
        result.push_back(arg);
        // Options were normalized into flag/value pairs. Keep values opaque here too.
        if (optionIn(arg,"|--model|--agent|--agents|--append-system-prompt|--append-system-prompt-file|--system-prompt|--system-prompt-file|--effort|--name|-n|--permission-mode|--settings|--setting-sources|--plugin-dir|--debug-file|--teammate-mode|")) result.push_back(id.options[++i]);
    }
    result.push_back("--resume"); result.push_back(id.conversation);
    if (yolo || id.dangerous) result.push_back("--dangerously-skip-permissions");
    return result;
}
}
