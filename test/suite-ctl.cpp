// Test-only forwarding adapter. The real agwintermctl still parses and executes every verb;
// only the transport endpoint is put inside the same namespace as the fixture application.
#include <windows.h>
#include <string>
#include <vector>
#include <cstdio>
#include "../src/test_registry.h"

static std::wstring env(const wchar_t* key) {
    DWORD n=GetEnvironmentVariableW(key,nullptr,0);if(!n)return {};
    std::wstring value(n,L'\0');DWORD got=GetEnvironmentVariableW(key,value.data(),n);
    if(!got || got>=n)return {};value.resize(got);return value;
}
static std::wstring quote(const std::wstring& value) {
    std::wstring out=L"\"";size_t slashes=0;
    for(wchar_t c:value){
        if(c==L'\\'){++slashes;continue;}
        out.append(slashes*(c==L'"'?2:1),L'\\');slashes=0;
        if(c==L'"')out+=L'\\';out+=c;
    }
    out.append(slashes*2,L'\\');return out+L'"';
}
int wmain(int argc,wchar_t** argv) {
    auto run=env(L"AGLITETERM_TEST_RUN"),real=env(L"AGLITETERM_TEST_REAL_CTL");
    std::wstring current,legacy,instances;
    wchar_t self[32768]{};DWORD own=GetModuleFileNameW(nullptr,self,32768);
    if(!lite_test_registry::paths(run,current,legacy,instances) || real.empty() || !own || own>=32768 ||
       _wcsicmp(real.c_str(),self)==0 || GetFileAttributesW(real.c_str())==INVALID_FILE_ATTRIBUTES)return 2;
    std::vector<std::wstring> args;bool pipe=false;
    for(int i=1;i<argc;i++){
        std::wstring arg=argv[i];
        if(arg==L"--socket" || arg.rfind(L"--socket=",0)==0)return 2; // do not permit a transport escape
        if(arg==L"--pipe"){
            pipe=true;args.push_back(arg);
            if(i+1<argc && std::wstring(argv[i+1]).rfind(L"--",0)!=0)args.push_back(lite_test_registry::endpoint(run,argv[++i]));
        }else if(arg.rfind(L"--pipe=",0)==0){pipe=true;args.push_back(L"--pipe="+lite_test_registry::endpoint(run,arg.substr(7)));}
        else args.push_back(arg);
    }
    if(!pipe){auto inherited=env(L"AGWINTERM_PIPE");args.push_back(L"--pipe");args.push_back(lite_test_registry::endpoint(run,inherited.empty()?L"agliteterm":inherited));}
    std::wstring command=quote(real);for(const auto& arg:args)command+=L" "+quote(arg);
    if(command.size()>=32767)return 2;
    STARTUPINFOW startup{sizeof startup};startup.dwFlags=STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;
    startup.wShowWindow=SW_HIDE;startup.hStdInput=GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput=GetStdHandle(STD_OUTPUT_HANDLE);startup.hStdError=GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION child{};
    if(!CreateProcessW(real.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child))return 2;
    CloseHandle(child.hThread);
    const DWORD waited=WaitForSingleObject(child.hProcess,60000);
    DWORD code=2;
    if(waited==WAIT_OBJECT_0){if(!GetExitCodeProcess(child.hProcess,&code))code=2;}
    else{TerminateProcess(child.hProcess,2);WaitForSingleObject(child.hProcess,10000);}
    CloseHandle(child.hProcess);return static_cast<int>(code);
}
