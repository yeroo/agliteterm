#include "../src/agent_integration.h"
#include "../src/shell_configuration.h"
#include "../src/bounded_pipe_write.h"
#include <cstdio>
static int checks = 0, failed = 0;
static void check(bool good, const char* label) { ++checks; if (!good) ++failed; std::printf("%s %s\n", good ? "PASS" : "FAIL", label); }
int main() {
    using namespace agent_integration;
    const std::string sid = "00112233-4455-6677-8899-aabbccddeeff";
    check(uuid(sid), "canonical UUID");
    for (const auto& bad : {"", "lite-1", "{00112233-4455-6677-8899-aabbccddeeff}", "00112233445566778899aabbccddeeff", "00112233-4455-6677-8899-aabbccddeefg"}) check(!uuid(bad), "noncanonical UUID rejected");
    for (const auto& flag : {"--resume", "--session-id", "-r"}) {
        Identity id; std::vector<std::string> args{"claude.exe",flag,sid,"--model","test model"};
        check(identify("C:/tools/CLAUDE.EXE",args,id) && id.conversation == sid && !id.dangerous, "exact native identity");
        const auto next = resumeArgs(args,id,true);
        check(next == std::vector<std::string>({"--model","test model","--resume",sid,"--dangerously-skip-permissions"}), "resume replaces id flag and preserves options");
    }
    for (const auto& flag : {"--resume=", "--session-id=", "-r="}) {
        Identity id; check(identify("claude.exe",{"claude.exe",std::string(flag)+sid,"--dangerously-skip-permissions"},id) && id.dangerous, "equals identity and explicit mode");
    }
    for (const auto& args : std::vector<std::vector<std::string>>{{"claude.exe"},{"claude.exe","--continue"},{"claude.exe","--resume"},
            {"claude.exe","--resume","lite-1"},{"claude.exe","--resume",sid,"--session-id",sid},
            {"claude.exe","--print","--resume",sid},{"claude.exe","--print=x","--resume",sid}}) {
        Identity id; check(!identify("claude.exe",args,id), "unknown/headless/ambiguous invocation refused");
    }
    Identity node;
    for (const auto& args : std::vector<std::vector<std::string>>{
        {"claude.exe","--resume",sid,"--fork-session"},
        {"claude.exe","--append-system-prompt","--session-id",sid},
        {"claude.exe","--","--session-id",sid},
        {"claude.exe","update","--session-id",sid},
        {"claude.exe","--resume",sid,"--unknown-option"},
        {"claude.exe","--resume",sid,"--background"}}) {
        Identity id; check(!identify("claude.exe",args,id), "fork, option values, maintenance and unknown lifecycle refuse");
    }
    {
        Identity id;
        std::vector<std::string> args{"claude.exe","--session-id",sid,"--append-system-prompt","--dangerously-skip-permissions","--permission-mode","plan","initial user request"};
        check(identify("claude.exe",args,id) && !id.dangerous, "opaque option value is not a permission flag");
        check(resumeArgs(args,id,false) == std::vector<std::string>({"--append-system-prompt","--dangerously-skip-permissions","--permission-mode","plan","--resume",sid}), "update preserves explicit options but never replays initial prompt");
        check(resumeArgs(args,id,true) == std::vector<std::string>({"--append-system-prompt","--dangerously-skip-permissions","--resume",sid,"--dangerously-skip-permissions"}), "explicit yolo replaces permission mode without rewriting opaque value");
        args={"claude.exe","--session-id",sid,"--","--fork-session"};
        check(identify("claude.exe",args,id) && resumeArgs(args,id,false)==std::vector<std::string>({"--resume",sid}), "option terminator keeps prompt opaque and unreplayed");
    }
    check(identify("C:/node/node.exe",{"node.exe","C:/npm/node_modules/@anthropic-ai/claude-code/cli.js","--resume",sid},node) && node.executableArgs == 2, "exact npm CLI script accepted");
    for (const auto& path : {"cli.js", "relative/node_modules/@anthropic-ai/claude-code/cli.js", "C:/npm/claude-code/cli.js", "C:/npm/node_modules/@other/claude-code/cli.js", "C:/npm/node_modules/@anthropic-ai/claude-code/cli.js.evil"}) {
        Identity id; check(!identify("node.exe",{"node.exe",path,"--resume",sid},id), "lookalike node script refused");
    }
    for (const auto& image : {"powershell.exe", "my-claude.exe", "claude.exe.bat"}) {
        Identity id; check(!identify(image,{image,"--resume",sid},id), "lookalike executable refused");
    }
    shell_configuration::InputGate gate; int calls = 0;
    const auto first = gate.reserve(); check(first != 0 && gate.reserve() == 0, "exclusive input lease");
    check(!gate.write(true,false,[&]{++calls;}), "human/API editing input refused during restart");
    check(gate.write(false,false,[&]{++calls;}), "terminal protocol replies bypass reservation");
    check(gate.write(true,false,[&]{++calls;},first), "owned interrupt permitted");
    gate.release(first+1); check(!gate.write(true,false,[&]{++calls;}), "wrong token cannot release");
    gate.release(first); const auto second = gate.reserve(); check(second != first, "fresh lease identity");
    check(!gate.write(true,false,[&]{++calls;},first), "old token cannot write into new reservation");
    gate.release(first); check(!gate.write(true,false,[&]{++calls;}), "old token cannot release new reservation");
    gate.release(second); check(gate.write(true,false,[&]{++calls;}), "normal input restored");
    check(!gate.write(true,false,[&]{++calls;},second), "released token cannot write");
    check(calls == 3, "only authorized transfers executed");
    gate.setReadOnly(true);
    check(gate.write(true,false,[]{}), "explicit API typing remains permitted in readonly pane");
    const auto readonlyLease = gate.reserve();
    check(!gate.write(true,false,[&]{++calls;},readonlyLease), "readonly transition refuses even reserved interrupt");
    check(gate.write(false,false,[]{}), "readonly still permits protocol replies");
    gate.release(readonlyLease); gate.setReadOnly(false);
    check(gate.write(true,false,[]{}), "readonly off restores normal input");
    const auto pipeName = "\\\\.\\pipe\\p11-bounded-unit-" + std::to_string(GetCurrentProcessId());
    HANDLE server=CreateNamedPipeA(pipeName.c_str(),PIPE_ACCESS_OUTBOUND|FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE|PIPE_WAIT,1,4096,4096,0,nullptr);
    HANDLE client=CreateFileA(pipeName.c_str(),GENERIC_READ,0,nullptr,OPEN_EXISTING,0,nullptr);
    check(server!=INVALID_HANDLE_VALUE && client!=INVALID_HANDLE_VALUE,"private bounded-write pipe opens");
    if (server!=INVALID_HANDLE_VALUE && client!=INVALID_HANDLE_VALUE) {
        check(bounded_pipe_write::write(server,"abc",3,100)==3,"bounded write reports full delivered bytes");
        std::string blocked(1024*1024,'x'); const auto started=GetTickCount64();
        check(bounded_pipe_write::write(server,blocked.data(),static_cast<DWORD>(blocked.size()),50)==0 && GetTickCount64()-started<2000,
              "non-draining pipe cancels within deadline, no false write success");
    }
    if(client!=INVALID_HANDLE_VALUE) CloseHandle(client);
    if(server!=INVALID_HANDLE_VALUE) CloseHandle(server);
    std::printf("agent-integration-unit: %d checks, %d failed\n", checks, failed); return failed ? 1 : 0;
}
