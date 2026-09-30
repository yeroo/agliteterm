// The pure half of the SessionStart resume binding (agwinterm #323 / AgentResumeTests.cs): telling
// the pane's own agent from a nested one by the process tree, the flags a relaunch keeps, and the
// line typed into each kind of shell. The trees are the shapes observed on Windows with Git Bash,
// Claude Code 2.1 (native) and Codex 0.156 (npm). No process, pipe or file is touched.
#include "../src/agent_resume.h"
#include <cstdio>
#include <initializer_list>
#include <utility>
using namespace agent_resume;
static int checks = 0, failures = 0;
static void check(bool yes, const char* what) { ++checks; if (!yes) { ++failures; std::printf("FAIL %s\n", what); } }

static const unsigned long kShell = 100;
static const std::string ClaudeExe = R"(C:\Users\u\.local\bin\claude.exe)";
static const std::string CodexJs = R"("C:\Program Files\nodejs\node.exe" C:\Users\u\AppData\Roaming\npm/node_modules/@openai/codex/bin/codex.js)";
static const std::string CodexExe = R"(C:\Users\u\AppData\Roaming\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe)";

// A chain child first: each row's parent is the next row, the last row's parent is the shell.
static std::map<unsigned long, ProcRow> chain(std::initializer_list<std::pair<std::string, std::string>> childFirst) {
    std::map<unsigned long, ProcRow> rows;
    unsigned long pid = 1; const unsigned long count = (unsigned long)childFirst.size();
    for (const auto& each : childFirst) { rows[pid] = ProcRow{ pid, pid == count ? kShell : pid + 1, each.first, each.second }; ++pid; }
    rows[kShell] = ProcRow{ kShell, 50, "bash.exe", R"(C:\Git\bin\bash.exe --login -i)" };
    rows[50] = ProcRow{ 50, 40, "agwinterm-ptyhost.exe", "agwinterm-ptyhost.exe --pipe agliteterm" };
    return rows;
}
static std::string join(const std::vector<std::string>& parts) { std::string s; for (const auto& p : parts) { if (!s.empty()) s += ' '; s += p; } return s; }

int main() {
    std::string line, why;
    {   // Claude in Git Bash is found through the hook's shells.
        const auto procs = chain({ {"powershell.exe", "powershell -NoProfile -File bind.ps1 claude"}, {"bash.exe", "bash.exe -c \"powershell ...\""},
            {"claude.exe", ClaudeExe + " --dangerously-skip-permissions"}, {"bash.exe", "usr\\bin\\bash.exe --login -i"}, {"bash.exe", "usr\\bin\\bash.exe --login -i"} });
        check(findAgentCommandLine(procs, 1, kShell, "claude", line, why) && line == ClaudeExe + " --dangerously-skip-permissions" && why.empty(), "claude in Git Bash is found through the hook shells");
    }
    {   // The Codex launcher and the native binary count as one agent, and the launcher's line wins.
        const auto procs = chain({ {"powershell.exe", "powershell -NoProfile -File bind.ps1 codex"}, {"codex.exe", CodexExe + " --sandbox workspace-write"}, {"node.exe", CodexJs + " --sandbox workspace-write"} });
        check(findAgentCommandLine(procs, 1, kShell, "codex", line, why) && line == CodexJs + " --sandbox workspace-write", "codex launcher and binary are one agent; the launcher line wins");
    }
    {   // A headless claude under the interactive one is nested.
        const auto procs = chain({ {"powershell.exe", "powershell -NoProfile -File bind.ps1 claude"}, {"bash.exe", "bash -c powershell"},
            {"claude.exe", ClaudeExe + " -p \"summarize\""}, {"bash.exe", "bash -c \"claude -p summarize\""}, {"claude.exe", ClaudeExe} });
        check(!findAgentCommandLine(procs, 1, kShell, "claude", line, why) && why.compare(0, 6, "nested") == 0, "a headless claude under the interactive one is nested");
    }
    {   // A codex exec run from claude is nested.
        const auto procs = chain({ {"powershell.exe", "powershell -NoProfile -File bind.ps1 codex"}, {"codex.exe", CodexExe + " exec hi"},
            {"node.exe", CodexJs + " exec hi"}, {"bash.exe", "bash -c \"codex exec hi\""}, {"claude.exe", ClaudeExe} });
        check(!findAgentCommandLine(procs, 1, kShell, "codex", line, why) && why.find("under another claude") != std::string::npos, "a codex exec run from claude is nested");
    }
    {   // Codex from Git Bash is found below the MSYS exec break: sh.exe's parent has already exited.
        std::map<unsigned long, ProcRow> procs;
        procs[1] = ProcRow{ 1, 2, "powershell.exe", "powershell -NoProfile -File bind.ps1 codex" };
        procs[2] = ProcRow{ 2, 3, "powershell.exe", "powershell -Command <hook>" };
        procs[3] = ProcRow{ 3, 4, "codex.exe", CodexExe + " -s workspace-write" };
        procs[4] = ProcRow{ 4, 5, "node.exe", CodexJs + " -s workspace-write" };
        procs[5] = ProcRow{ 5, 777, "sh.exe", "sh C:/npm/codex" };
        procs[kShell] = ProcRow{ kShell, 50, "bash.exe", "bash --login -i" };
        check(findAgentCommandLine(procs, 1, kShell, "codex", line, why) && line == CodexJs + " -s workspace-write" && why.empty(), "codex is found below the MSYS exec break");
    }
    {   // A walk that ends before its agent binds nothing.
        check(!findAgentCommandLine(chain({ {"powershell.exe", "p"}, {"bash.exe", "bash"} }), 1, kShell, "claude", line, why) && why.find("no claude process") != std::string::npos, "no agent above the hook");
        check(!findAgentCommandLine(chain({ {"powershell.exe", "p"}, {"codex.exe", CodexExe} }), 1, kShell, "claude", line, why), "the other agent is not this one");
        std::map<unsigned long, ProcRow> hookGone; hookGone[kShell] = ProcRow{ kShell, 50, "bash.exe", "bash" };
        check(!findAgentCommandLine(hookGone, 1, kShell, "claude", line, why), "a hook that is already gone binds nothing");
    }
    {   // The walk stops at the pane's shell: an agent ABOVE it is not the pane's.
        auto procs = chain({ {"powershell.exe", "p"}, {"bash.exe", "bash -c hook"} });
        procs[50] = ProcRow{ 50, 60, "claude.exe", ClaudeExe };
        check(!findAgentCommandLine(procs, 1, kShell, "claude", line, why), "the walk stops at the pane's shell");
    }
    {   // The hook process may itself be the agent (no shell between them).
        check(findAgentCommandLine(chain({ {"claude.exe", ClaudeExe + " --permission-mode plan"} }), 1, kShell, "claude", line, why) && line == ClaudeExe + " --permission-mode plan", "the reporting process may be the agent itself");
    }
    // agentOf knows the binaries and the npm launchers.
    check(agentOf(ProcRow{ 1, 2, "Claude.exe", "" }) == "claude" && agentOf(ProcRow{ 1, 2, "node.exe", CodexJs }) == "codex", "agentOf: native claude, npm codex");
    check(agentOf(ProcRow{ 1, 2, "node.exe", R"(node C:\npm\node_modules\@anthropic-ai\claude-code\cli.js)" }) == "claude", "agentOf: npm claude");
    check(agentOf(ProcRow{ 1, 2, "node.exe", "node server.js" }).empty() && agentOf(ProcRow{ 1, 2, "bash.exe", "bash -c claude" }).empty(), "agentOf: other node and shells are no agent");
    // Claude keeps its permission mode.
    check(join(resumeFlags("claude", ClaudeExe + " --resume 36145f11-e132-4691-ab98-ae5c4445c46b --dangerously-skip-permissions --model opus")) == "--dangerously-skip-permissions", "claude: yolo kept, model and resume dropped");
    check(join(resumeFlags("claude", ClaudeExe + " --permission-mode acceptEdits")) == "--permission-mode acceptEdits", "claude: spaced permission mode");
    check(join(resumeFlags("claude", ClaudeExe + " --permission-mode=plan")) == "--permission-mode plan", "claude: joined permission mode");
    check(join(resumeFlags("claude", ClaudeExe + " --permission-mode \"x; rm -rf ~\"")).empty(), "claude: a value a shell could interpret is dropped");
    check(join(resumeFlags("claude", ClaudeExe + " \"fix the login bug\"")).empty(), "claude: a prompt is not a flag");
    check(join(resumeFlags("claude", ClaudeExe + " --dangerously-skip-permissions --dangerously-skip-permissions")) == "--dangerously-skip-permissions", "a bare flag is kept once");
    // Codex keeps its sandbox and approval mode.
    check(join(resumeFlags("codex", CodexJs + " resume 01a0 --dangerously-bypass-approvals-and-sandbox -m gpt-5")) == "--dangerously-bypass-approvals-and-sandbox", "codex: bypass kept");
    check(join(resumeFlags("codex", CodexJs + " -s workspace-write -a on-request")) == "-s workspace-write -a on-request", "codex: short flags");
    check(join(resumeFlags("codex", CodexJs + " --sandbox=read-only --profile work -c model=\"o3\"")) == "--sandbox read-only --profile work", "codex: joined and spaced long flags");
    check(join(resumeFlags("codex", CodexJs + " -p")).empty(), "codex: a valued flag with nothing after it");
    // compose uses each shell's own syntax.
    check(compose(Shell::Bash, "claude", "abc", R"(C:\src\it's)", { "--dangerously-skip-permissions" }) == "cd 'C:\\src\\it'\\''s' && claude --resume abc --dangerously-skip-permissions", "compose: bash");
    check(compose(Shell::PowerShell, "claude", "abc", R"(C:\src\it's)", {}) == "Set-Location -LiteralPath 'C:\\src\\it''s'; claude --resume abc", "compose: powershell");
    check(compose(Shell::Cmd, "codex", "01a0", R"(C:\src)", { "-s", "workspace-write" }) == "cd /d \"C:\\src\" && codex resume 01a0 -s workspace-write", "compose: cmd");
    check(compose(Shell::Cmd, "claude", "abc", "C:\\a\"b", {}) == "claude --resume abc", "compose: cmd drops a directory with a quote");
    check(compose(Shell::Cmd, "claude", "abc", "C:\\work\\%OS%", {}) == "claude --resume abc", "compose: cmd drops a directory with a percent sign");
    // PowerShell closes a single-quoted string at U+2018..U+201B as well as at the apostrophe.
    check(compose(Shell::PowerShell, "claude", "abc", "C:\\x\xE2\x80\x99; Start-Process calc; \xE2\x80\x99", {})
              == "Set-Location -LiteralPath 'C:\\x\xE2\x80\x99\xE2\x80\x99; Start-Process calc; \xE2\x80\x99\xE2\x80\x99'; claude --resume abc",
          "compose: powershell doubles a typographic quote");
    check(powershell_quote::body("\xE2\x80\x98" "a" "\xE2\x80\x9A" "b" "\xE2\x80\x9B" "'") == "\xE2\x80\x98\xE2\x80\x98" "a" "\xE2\x80\x9A\xE2\x80\x9A" "b" "\xE2\x80\x9B\xE2\x80\x9B" "''",
          "powershell quote: all five quote characters are doubled");
    check(powershell_quote::body("\xE2\x80\x97 \xE2\x80\x9C \xE2\x80") == "\xE2\x80\x97 \xE2\x80\x9C \xE2\x80", "powershell quote: neighbours and a cut sequence pass unchanged");
    check(compose(Shell::Bash, "claude", "abc", "C:\\x\xE2\x80\x99s", {}) == "cd 'C:\\x\xE2\x80\x99s' && claude --resume abc", "compose: bash ends a quote only at the apostrophe");
    check(compose(Shell::Other, "codex", "01a0", R"(C:\src)", {}) == "codex resume 01a0", "compose: unknown shell gets the resume alone");
    check(compose(Shell::Bash, "claude", "abc", "", {}) == "claude --resume abc" && compose(Shell::Bash, "claude", "abc", "   ", {}) == "claude --resume abc", "compose: empty or blank cwd");
    check(compose(Shell::PowerShell, "claude", "abc", "C:\\src\nStart-Process calc", {}) == "claude --resume abc", "compose: a cwd with a control character is dropped, never typed");
    // Shells are classified by their executable.
    check(classifyShell(R"(C:\Program Files\Git\bin\bash.exe)") == Shell::Bash && classifyShell("powershell.exe") == Shell::PowerShell, "classify: bash, powershell");
    check(classifyShell(R"(C:\Program Files\PowerShell\7\pwsh.exe)") == Shell::PowerShell && classifyShell("CMD.EXE") == Shell::Cmd, "classify: pwsh, cmd any case");
    check(classifyShell("wsl.exe") == Shell::Other && classifyShell("") == Shell::Other && classifyShell("C:/msys64/usr/bin/zsh") == Shell::Bash, "classify: wsl, empty, zsh without extension");
    // Session ids are safe to type unquoted.
    check(validSessionId("01a0ce4b-7125-7dd1-b5a1-a99d8f14402c") && validSessionId("thr_123"), "session ids: uuid and thread form");
    check(!validSessionId("") && !validSessionId("a b") && !validSessionId("x;rm") && !validSessionId(std::string(129, 'a')) && validSessionId(std::string(128, 'a')), "session ids: empty, space, metacharacter, length bound");
    check(knownAgent("claude") && knownAgent("codex") && !knownAgent("Claude") && !knownAgent("claude --resume x") && !knownAgent(""), "known agents are the two exact words");
    {   // splitCommandLine follows CommandLineToArgvW.
        const auto args = splitCommandLine(R"("C:\Program Files\nodejs\node.exe" "a b" c\"d e\\f "g\\")");
        check(args.size() == 5 && args[0] == R"(C:\Program Files\nodejs\node.exe)" && args[1] == "a b" && args[2] == "c\"d" && args[3] == R"(e\\f)" && args[4] == "g\\", "split: quotes and backslashes");
        const auto empty = splitCommandLine("x \"\"");
        check(empty.size() == 2 && empty[0] == "x" && empty[1].empty(), "split: an empty quoted argument");
    }
    {   // lite: a SessionStart line is recognised for the conversation it resumes, whatever its prefix and flags.
        const std::string id = "36145f11-e132-4691-ab98-ae5c4445c46b";
        for (Shell shell : { Shell::PowerShell, Shell::Bash, Shell::Cmd, Shell::Other }) {
            check(resumes(compose(shell, "claude", id, R"(C:\src\it's)", { "--dangerously-skip-permissions" }), "claude", id), "resumes: every shell form, with flags");
            check(resumes(compose(shell, "claude", id, "", {}), "claude", id), "resumes: no directory, no flags");
        }
        check(resumes("claude --resume 36145F11-E132-4691-AB98-AE5C4445C46B", "claude", id), "resumes: the id compares without case");
        check(!resumes(compose(Shell::PowerShell, "claude", id + "x", "C:\\src", {}), "claude", id), "resumes: a longer id is another conversation");
        check(!resumes(compose(Shell::PowerShell, "codex", id, "C:\\src", {}), "claude", id) && resumes(compose(Shell::PowerShell, "codex", id, "C:\\src", {}), "codex", id), "resumes: the agent must match");
        check(!resumes("& 'C:\\bin\\claude.exe' --resume " + id, "claude", id) && !resumes("echo hi; claude --resume " + id, "claude", id), "resumes: another shape is a custom binding");
        check(!resumes("claude --resume " + id, "claude", "") && !resumes("", "claude", id), "resumes: empty inputs");
        // Only what compose could have written after the id; anything else is the user's own line.
        check(resumes("claude --resume " + id + " --permission-mode plan --dangerously-skip-permissions", "claude", id), "resumes: kept claude flags");
        check(resumes("codex resume " + id + " -s workspace-write -a on-request --profile work", "codex", id), "resumes: kept codex flags");
        for (const char* tail : { " --model opus", " && npm test", "; Write-Host done", " | Tee-Object log", " ", "  --dangerously-skip-permissions",
                                  " --permission-mode", " --permission-mode a;b", " --dangerously-skip-permissions ", " -s workspace-write" })
            check(!resumes("claude --resume " + id + tail, "claude", id), "resumes: text compose never writes after the id is a custom binding");
        check(!resumes("Set-Location -LiteralPath 'C:\\x'; claude --resume " + id + "; Start-Something", "claude", id), "resumes: a command behind the resume is a custom binding");
        check(!resumes("codex resume " + id + " --dangerously-skip-permissions", "codex", id), "resumes: another agent's flag is not kept");
        check(resumes(compose(Shell::PowerShell, "claude", id, "C:\\x\xE2\x80\x99; y", { "--permission-mode", "plan" }), "claude", id), "resumes: a directory with a typographic quote");
        check(runPart("Set-Location -LiteralPath 'C:\\a''b'; claude --resume x") == "claude --resume x" && runPart("cd 'C:\\a'\\''b' && claude --resume x") == "claude --resume x" && runPart("cd /d \"C:\\a\" && codex resume y") == "codex resume y", "runPart strips each prefix compose writes");
        check(runPart("Set-Location -LiteralPath 'C:\\a' ; claude") == "Set-Location -LiteralPath 'C:\\a' ; claude" && runPart("claude") == "claude", "runPart leaves anything else whole");
    }
    std::printf("agent resume unit: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
