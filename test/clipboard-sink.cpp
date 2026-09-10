// A console input sink, never an interpreter. No input is echoed, logged or written to disk.
#include <windows.h>
#include <string>
static BOOL WINAPI ignoreControl(DWORD){return TRUE;}
int wmain(int argc,wchar_t** argv){
    if(argc!=2)return 2;
    HANDLE input=GetStdHandle(STD_INPUT_HANDLE);DWORD mode=0,verified=0;
    if(!GetConsoleMode(input,&mode) || !SetConsoleCtrlHandler(ignoreControl,TRUE) ||
       !SetConsoleMode(input,(mode|ENABLE_LINE_INPUT)&~(ENABLE_ECHO_INPUT|ENABLE_PROCESSED_INPUT)) ||
       !GetConsoleMode(input,&verified) || (verified&(ENABLE_ECHO_INPUT|ENABLE_PROCESSED_INPUT)))return 2;
    const char ready[]="\x1b[?1000h\x1b[?1006hRIGHT-PASTE-READY\r\n";DWORD written=0;
    if(!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),ready,sizeof ready-1,&written,nullptr) || written!=sizeof ready-1)return 2;
    std::wstring line;bool complete=false;
    while(line.size()<256 && !complete){
        wchar_t buffer[64];DWORD count=0;
        if(!ReadConsoleW(input,buffer,64,&count,nullptr) || !count)return 2;
        for(DWORD i=0;i<count;i++){if(buffer[i]==L'\r'||buffer[i]==L'\n'){complete=true;break;}line+=buffer[i];}
    }
    const std::string result=complete&&line==L"PASTED_OK"?"True":"False";
    HANDLE file=CreateFileW(argv[1],GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return 2;
    const bool ok=WriteFile(file,result.data(),static_cast<DWORD>(result.size()),&written,nullptr)&&written==result.size();
    CloseHandle(file);return ok?0:2;
}
