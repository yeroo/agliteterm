// SessionStart resume binding - the host-free half (agwinterm #323: AgentResume.cs). An agent's
// SessionStart hook reports the live session id, its cwd and its own pid; the host takes the hook's
// ancestry and asks this header three things: which process is the agent that fired the hook (and is
// it the pane's own, not one nested under another agent), which of its flags must survive a relaunch,
// and what to type into the pane's shell to resume it.
//
// The binding used to come only from the PowerShell `claude` wrapper, which a Git Bash or cmd pane
// never loads and which `/resume` or `/clear` leave pointing at the old conversation. SessionStart
// fires on startup, resume, clear and compact, so the id it reports is always the one to resume.
#pragma once
#include <map>
#include <string>
#include <vector>
#include "powershell_quote.h"

namespace agent_resume {

// One process of the hook's ancestry: pid, parent, image name (no path) and command line.
struct ProcRow { unsigned long pid = 0, parent = 0; std::string name, commandLine; };

enum class Shell { PowerShell, Bash, Cmd, Other };

inline std::string lower(std::string s) { for (char& c : s) if (c >= 'A' && c <= 'Z') c += 'a' - 'A'; return s; }

// A session id both CLIs accept and that is safe to type unquoted into any shell.
inline bool validSessionId(const std::string& id) {
    if (id.empty() || id.size() > 128) return false;
    for (char c : id)
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return false;
    return true;
}
// A flag value kept on the relaunch line: a conservative set, so nothing a shell could interpret.
inline bool validFlagValue(const std::string& value) {
    if (value.empty() || value.size() > 64) return false;
    for (char c : value)
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == ':' || c == '-')) return false;
    return true;
}
inline bool knownAgent(const std::string& agent) { return agent == "claude" || agent == "codex"; }

// The shell a pane runs, from its launch executable (a path or a bare name).
inline Shell classifyShell(const std::string& exe) {
    std::string name = lower(exe);
    const auto slash = name.find_last_of("/\\");
    if (slash != std::string::npos) name = name.substr(slash + 1);
    if (name.size() > 4 && name.compare(name.size() - 4, 4, ".exe") == 0) name.resize(name.size() - 4);
    if (name == "powershell" || name == "pwsh") return Shell::PowerShell;
    if (name == "bash" || name == "sh" || name == "zsh") return Shell::Bash;   // Git Bash, MSYS2, Cygwin: POSIX syntax, Windows paths accepted
    if (name == "cmd") return Shell::Cmd;
    return Shell::Other;                                                       // wsl and anything custom: no directory prefix
}

// Which agent a process is: the native binary, or node running the npm package (the launcher a shim
// starts, whose child is the native binary for Codex). Empty for anything else.
inline std::string agentOf(const ProcRow& p) {
    const std::string name = lower(p.name);
    if (name == "claude.exe") return "claude";
    if (name == "codex.exe") return "codex";
    if (name == "node.exe") {
        std::string cmd = lower(p.commandLine);
        for (char& c : cmd) if (c == '\\') c = '/';
        if (cmd.find("@anthropic-ai/claude-code") != std::string::npos) return "claude";
        if (cmd.find("@openai/codex") != std::string::npos) return "codex";
    }
    return {};
}

// Walk up from the hook's process towards the pane's shell and return the command line the user
// started the agent with: the outermost process of the first run of `agent` processes (a node
// launcher over the native binary counts as one agent). False, with the reason in `why`, when no
// such agent is found before the walk ends, or when another agent sits above it (a nested
// `claude -p` or `codex exec` run from an agent's tool shell, which inherits the pane's id).
//
// The walk ends at the shell, or where a parent is no longer in the snapshot. The second is normal
// in Git Bash: MSYS implements exec by starting a new Windows process and letting the old one go,
// so an npm shim run by bash has a parent that has already exited. The agent found below such a
// break is accepted; the nested-run check then covers only what the walk saw, and the hook's own
// tells (a headless entrypoint, an exec rollout) cover the rest.
inline bool findAgentCommandLine(const std::map<unsigned long, ProcRow>& procs, unsigned long hookPid,
                                 unsigned long shellPid, const std::string& agent,
                                 std::string& commandLine, std::string& why) {
    const ProcRow* outer = nullptr;
    bool inRun = false;
    unsigned long pid = hookPid;
    for (int depth = 0; depth < 64; ++depth) {
        const auto found = procs.find(pid);
        if (found == procs.end()) break;
        const ProcRow& row = found->second;
        if (row.pid == shellPid) break;
        const std::string a = agentOf(row);
        if (!outer) {
            if (a == agent) { outer = &row; inRun = true; }
        } else if (inRun && a == agent) outer = &row;
        else {
            inRun = false;
            if (!a.empty()) { why = "nested: this " + agent + " runs under another " + a + " in the pane"; return false; }
        }
        if (row.parent == row.pid) break;
        pid = row.parent;
    }
    if (!outer) { why = "no " + agent + " process above the hook"; return false; }
    why.clear();
    commandLine = outer->commandLine;
    return true;
}

// Split a Windows command line the way CommandLineToArgvW does: whitespace separates arguments
// outside quotes, 2n backslashes before a quote are n backslashes and the quote toggles quoting,
// 2n+1 are n backslashes and a literal quote, and backslashes elsewhere are literal.
inline std::vector<std::string> splitCommandLine(const std::string& line) {
    std::vector<std::string> args;
    std::string cur;
    bool inQuotes = false, have = false;
    for (size_t i = 0; i < line.size(); ++i) {
        const char c = line[i];
        if (c == '\\') {
            size_t n = 0;
            while (i < line.size() && line[i] == '\\') { ++n; ++i; }
            if (i < line.size() && line[i] == '"') {
                cur.append(n / 2, '\\');
                if (n % 2 == 1) cur += '"'; else inQuotes = !inQuotes;
            } else { cur.append(n, '\\'); --i; }
            have = true;
        } else if (c == '"') { inQuotes = !inQuotes; have = true; }
        else if (!inQuotes && (c == ' ' || c == '\t')) {
            if (have) { args.push_back(cur); cur.clear(); have = false; }
        } else { cur += c; have = true; }
    }
    if (have) args.push_back(cur);
    return args;
}

// The flag vocabulary resumeFlags keeps and composedFlags accepts: the agent's flags that stand
// alone, and those followed by a value.
inline std::vector<std::string> bareFlags(const std::string& agent) {
    return agent == "codex" ? std::vector<std::string>{ "--dangerously-bypass-approvals-and-sandbox" }
                            : std::vector<std::string>{ "--dangerously-skip-permissions" };
}
inline std::vector<std::string> valuedFlags(const std::string& agent) {
    return agent == "codex" ? std::vector<std::string>{ "-s", "--sandbox", "-a", "--ask-for-approval", "-p", "--profile" }
                            : std::vector<std::string>{ "--permission-mode" };
}
inline bool listed(const std::vector<std::string>& set, const std::string& s) {
    for (const auto& each : set) if (each == s) return true;
    return false;
}
// The flags of the running agent that a resume must repeat: the permission and sandbox mode, so a
// YOLO session comes back YOLO. A value outside the conservative set is dropped rather than quoted,
// which keeps the relaunch line free of anything a shell could interpret.
inline std::vector<std::string> resumeFlags(const std::string& agent, const std::string& commandLine) {
    const auto bare = bareFlags(agent), valued = valuedFlags(agent);
    const auto args = splitCommandLine(commandLine);
    std::vector<std::string> flags;
    for (size_t i = 1; i < args.size(); ++i) {
        const std::string& a = args[i];
        if (listed(bare, a)) { if (!listed(flags, a)) flags.push_back(a); continue; }
        // `--sandbox value` and `--sandbox=value`; short flags only in the spaced form.
        const size_t eq = a.compare(0, 2, "--") == 0 ? a.find('=') : std::string::npos;
        const bool joined = eq != std::string::npos && eq > 0;
        const std::string key = joined ? a.substr(0, eq) : a;
        if (!listed(valued, key)) continue;
        std::string value; bool haveValue = false;
        if (joined) { value = a.substr(eq + 1); haveValue = true; }
        else if (i + 1 < args.size()) { value = args[++i]; haveValue = true; }
        if (haveValue && validFlagValue(value)) { flags.push_back(key); flags.push_back(value); }
    }
    return flags;
}

inline std::string replaceAll(std::string s, const std::string& from, const std::string& to) {
    for (size_t at = 0; (at = s.find(from, at)) != std::string::npos; at += to.size()) s.replace(at, from.size(), to);
    return s;
}
// A directory that may be typed into a shell inside quotes: no control character (a newline would
// end the line and start another). lite's own rule; an unusable cwd drops the prefix, not the bind.
// What each shell's quotes cannot hold is compose's business: PowerShell's five quote characters
// are doubled, cmd has no escape for `"` or `%` inside its quotes and drops the prefix.
inline bool typableCwd(const std::string& cwd) {
    for (unsigned char c : cwd) if (c < 0x20 || c == 0x7F) return false;
    for (char c : cwd) if (c != ' ' && c != '\t') return true;
    return false;   // empty or blank
}

// The line typed into a restored pane to resume the session: change to its directory in the pane's
// own shell syntax, then resume by id with `flags`. PowerShell 5.1 has no `&&`, so it gets `;`. An
// empty cwd, or a shell whose syntax is unknown, gets the resume alone. So does a cmd pane whose
// directory holds `"` (no escape inside cmd's quotes) or `%`: an interactive cmd expands %NAME%
// inside double quotes too, so `C:\work\%OS%` would be typed as another directory, and a variable
// whose value holds a quote would end the string.
inline std::string compose(Shell shell, const std::string& agent, const std::string& sessionId,
                           const std::string& cwd, const std::vector<std::string>& flags) {
    std::string run = (agent == "codex" ? "codex resume " : "claude --resume ") + sessionId;
    for (const auto& f : flags) run += " " + f;
    if (!typableCwd(cwd)) return run;
    switch (shell) {
    case Shell::PowerShell: return "Set-Location -LiteralPath " + powershell_quote::literal(cwd) + "; " + run;
    case Shell::Bash: return "cd '" + replaceAll(cwd, "'", "'\\''") + "' && " + run;
    case Shell::Cmd: if (cwd.find_first_of("\"%") == std::string::npos) return "cd /d \"" + cwd + "\" && " + run; return run;
    default: return run;
    }
}

// The run part of a line `compose` wrote: the text after its directory prefix, or the whole line
// when it has none. Only the three prefixes compose emits are recognised; anything else is
// returned whole, so a hand-written binding is never mistaken for one of ours.
inline std::string runPart(const std::string& line) {
    auto after = [&](const std::string& open, const std::string& quote, const std::string& doubled, const std::string& close) -> std::string {
        if (line.compare(0, open.size(), open) != 0) return {};
        size_t at = open.size();
        for (;;) {
            const size_t q = line.find(quote, at);
            if (q == std::string::npos) return {};
            if (!doubled.empty() && line.compare(q, doubled.size(), doubled) == 0) { at = q + doubled.size(); continue; }
            if (line.compare(q, close.size(), close) == 0) return line.substr(q + close.size());
            return {};
        }
    };
    std::string rest = after("Set-Location -LiteralPath '", "'", "''", "'; ");
    if (rest.empty()) rest = after("cd '", "'", "'\\''", "' && ");
    if (rest.empty()) rest = after("cd /d \"", "\"", "", "\" && ");
    return rest.empty() ? line : rest;
}
// Whether `tail`, the text after the session id, is exactly what compose appends: nothing, or for
// each kept flag one space and a bare flag of `agent`, or one space, a valued flag, one space and a
// value validFlagValue accepts. Anything else - another flag, a second command behind `;`, `&&` or
// `|` - is somebody's own text.
inline bool composedFlags(const std::string& agent, const std::string& tail) {
    const auto bare = bareFlags(agent), valued = valuedFlags(agent);
    size_t at = 0;
    auto next = [&](std::string& token) {   // one space, then a run without spaces
        if (at >= tail.size() || tail[at] != ' ') return false;
        const size_t end = tail.find(' ', at + 1);
        const size_t stop = end == std::string::npos ? tail.size() : end;
        token = tail.substr(at + 1, stop - at - 1);
        at = stop;
        return !token.empty();
    };
    while (at < tail.size()) {
        std::string token, value;
        if (!next(token)) return false;
        if (listed(bare, token)) continue;
        if (!listed(valued, token) || !next(value) || !validFlagValue(value)) return false;
    }
    return true;
}
// Whether `binding` is a SessionStart line resuming `sessionId` with `agent`: one of compose's
// directory prefixes or none, the resume, the id, and only flags compose could have kept. claude
// yolo / claude update use it to tell "the binding the hook wrote for the conversation I verified"
// from a custom binding they must not overwrite - `claude --resume <id> --model opus` and
// `claude --resume <id>; npm test` are custom ones (revmux r1: any text after the id passed).
inline bool resumes(const std::string& binding, const std::string& agent, const std::string& sessionId) {
    if (sessionId.empty()) return false;
    const std::string run = runPart(binding);
    const std::string head = agent == "codex" ? "codex resume " : "claude --resume ";
    if (run.compare(0, head.size(), head) != 0) return false;
    const std::string rest = run.substr(head.size());
    if (rest.size() < sessionId.size() || lower(rest.substr(0, sessionId.size())) != lower(sessionId)) return false;
    return composedFlags(agent, rest.substr(sessionId.size()));
}

}  // namespace agent_resume
