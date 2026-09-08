// Isolated P11 fixture. Never calls a real CLI, network, installer, or user settings.
#include <windows.h>
#include <fstream>
#include <string>
#include <cstdio>
static bool ignore = false;
int main(int argc, char** argv) {
    char self[MAX_PATH]{}; GetModuleFileNameA(nullptr,self,MAX_PATH);
    std::string dir(self); dir.resize(dir.find_last_of("/\\")+1);
    if (argc > 1 && std::string(argv[1]) == "--fixture-console-child") {
        SetConsoleCtrlHandler(nullptr,TRUE); Sleep(60000); return 0;
    }
    if (argc > 1 && std::string(argv[1]) == "--version") {
        std::ifstream input(dir+"version.txt"); std::string version; std::getline(input,version);
        std::printf("%s (Claude Code)\n", version.empty() ? "1.0.0" : version.c_str()); return 0;
    }
    if (argc > 1 && std::string(argv[1]) == "update") {
        std::ifstream input(dir+"update-mode.txt"); std::string mode; std::getline(input,mode);
        if (mode == "fail") return 7;
        if (mode == "slow") {
            while (!std::ifstream(dir+"update-release.txt").good()) Sleep(100);
            std::ofstream output(dir+"version.txt"); output << "1.0.2";
        }
        if (mode == "new") { std::ofstream output(dir+"version.txt"); output << "1.0.1"; }
        if (mode == "downgrade") { std::ofstream output(dir+"version.txt"); output << "0.9.0"; }
        std::printf("P11 fake update %s\n", mode.c_str()); return 0;
    }
    std::string sid;
    for (int i=1; i+1<argc; ++i) if (std::string(argv[i])=="--session-id" || std::string(argv[i])=="--resume") sid=argv[i+1];
    const bool immediate = std::ifstream(dir+"immediate.txt").good();
    ignore = !sid.empty() && std::ifstream(dir+"ignore-"+sid).good();
    HANDLE input=GetStdHandle(STD_INPUT_HANDLE); DWORD inputMode=0;
    if(!immediate && (!GetConsoleMode(input,&inputMode) ||
        !SetConsoleMode(input,inputMode & ~(ENABLE_PROCESSED_INPUT|ENABLE_LINE_INPUT|ENABLE_ECHO_INPUT)))) return 12;
    // Two panes can resume together. CRT append seeks are not an inter-process logging lock.
    std::string mutexName="Local\\p11-fake-log-"+dir;
    for(size_t i=6;i<mutexName.size();++i) if(mutexName[i]=='\\' || mutexName[i]=='/' || mutexName[i]==':') mutexName[i]='_';
    HANDLE logMutex=CreateMutexA(nullptr,FALSE,mutexName.c_str());
    if(!logMutex) return 10;
    const auto locked=WaitForSingleObject(logMutex,5000);
    if(locked!=WAIT_OBJECT_0 && locked!=WAIT_ABANDONED){CloseHandle(logMutex);return 10;}
    bool logged=false;
    { std::ofstream output(dir+"launch.log",std::ios::app); output << GetCurrentProcessId();
      for (int i = 1; i < argc; ++i) output << '\t' << argv[i];
      output << '\n'; output.flush(); logged=output.good(); }
    ReleaseMutex(logMutex);CloseHandle(logMutex);
    if(!logged) return 11;
    std::printf("P11-AGENT-READY\n"); std::fflush(stdout);
    if (immediate) return 0;
    // Interactive Claude uses raw input: Ctrl+C cancels; the documented Ctrl+D requests exit.
    bool exiting=false; char bytes[128]; DWORD count=0;
    while(!exiting && ReadFile(input,bytes,sizeof bytes,&count,nullptr) && count){
        for(DWORD i=0;i<count;++i){
            if(bytes[i]=='\x03'){std::printf("P11-AGENT-CANCELLED\n");std::fflush(stdout);}
            if(bytes[i]=='\x04' && !ignore) exiting=true;
        }
    }
    SetConsoleMode(input,inputMode);
    if (!sid.empty() && std::ifstream(dir+"late-"+sid).good()) {
        STARTUPINFOA startup{}; startup.cb=sizeof startup; PROCESS_INFORMATION child{};
        std::string command="\""+std::string(self)+"\" --fixture-console-child";
        if (!CreateProcessA(self,&command[0],nullptr,nullptr,FALSE,0,nullptr,dir.c_str(),&startup,&child)) return 9;
        FILETIME born{},exit{},kernel{},user{};
        GetProcessTimes(child.hProcess,&born,&exit,&kernel,&user);
        { std::ofstream proof(dir+"late-proof-"+sid);
          proof << child.dwProcessId << '\t' << ((static_cast<unsigned long long>(born.dwHighDateTime)<<32)|born.dwLowDateTime); }
        CloseHandle(child.hThread); CloseHandle(child.hProcess);
    }
    return 0;
}
