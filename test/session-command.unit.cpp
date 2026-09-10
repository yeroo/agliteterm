#include "../src/session_command.h"
#include "../src/control.h"
#include <iostream>
#include <stdexcept>
using session_command::Launch;
static void check(bool ok) { if (!ok) throw std::runtime_error("session command assertion failed"); }
int main(int argc, char** argv) {
    std::string error, direct = "direct", ps = "powershell", invalid = "cmd";
    Launch launch;
    check(session_command::create("Remove-Item 'old file'; Write-Output \"☃\"", nullptr, false, false, launch, error));
    check(launch.app == "powershell.exe" && launch.args == std::vector<std::string>({"-NoLogo", "-NoExit", "-Command", "Remove-Item 'old file'; Write-Output \"☃\""}));
    check(session_command::create("echo ok", &ps, true, false, launch, error));
    check(session_command::create("  \"C:\\Program Files\\tool.exe\" \"\" \"a b\" \"C:\\tail\\\\\" \"say \\\"hi\\\"\" ; $x &", &direct, false, false, launch, error));
    check(launch.app == "C:\\Program Files\\tool.exe" && launch.args == std::vector<std::string>({"", "a b", "C:\\tail\\", "say \"hi\"", ";", "$x", "&"}));
    check(!session_command::create("", &direct, false, false, launch, error));
    check(!session_command::create("echo ok", &invalid, false, false, launch, error));
    check(!session_command::create("echo ok", &direct, true, false, launch, error));
    check(!session_command::create("echo ok", nullptr, false, true, launch, error));
    check(!session_command::create("\"\" arg", &direct, false, false, launch, error));
    check(!session_command::create(std::string("a\0b",3), nullptr, false, false, launch, error));
    check(session_command::create(std::string(2047,'x'), nullptr, false, false, launch, error));
    check(!session_command::create(std::string(2048,'x'), nullptr, false, false, launch, error));
    std::string args="tool";for(int i=0;i<16;++i)args+=" x";
    check(session_command::create(args, &direct, false, false, launch, error));
    check(!session_command::create(args+" x", &direct, false, false, launch, error));
    if (argc == 1) { std::cout << "PASS 15 session command checks\n"; return 0; }
    const int scenario = atoi(argv[1]);
    const char* commands[] = {
        "Write-Output ('COMMAND-'+'READY'); Write-Output 'quoted \"value\" ☃'",
        "Write-Output ('COMMAND-'+'READY'); Write-Error 'intentional failure'",
        "exit 7", "cmd.exe /d /c exit 9"
    };
    check(scenario>=0 && scenario<4);
    check(session_command::create(commands[scenario], scenario==3?&direct:nullptr, false, false, launch, error));
    std::cout << "{\"app\":\"" << jsonEscape(launch.app) << "\",\"args\":[";
    for(size_t i=0;i<launch.args.size();++i)std::cout<<(i?",":"")<<"\""<<jsonEscape(launch.args[i])<<"\"";
    std::cout << "]}";
}
