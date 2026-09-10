#include <windows.h>
#include <cstdio>
#include <string>
static std::wstring literal(const wchar_t* text) {
    std::wstring out=L"'";for(const wchar_t* p=text;*p;++p){out+=*p;if(*p==L'\'')out+=L'\'';}return out+L"'";
}
int wmain(int argc,wchar_t** argv) {
    if(argc!=5 || wcscmp(argv[1],L"init") || wcscmp(argv[2],L"pwsh") || wcscmp(argv[3],L"--config"))return 7;
    wchar_t receipt[32768]{}, mode[32]{};
    if(!GetEnvironmentVariableW(L"AGLITE_OMP_LIVE_RECEIPT",receipt,32768))return 8;
    GetEnvironmentVariableW(L"AGLITE_OMP_LIVE_MODE",mode,32);
    if(!wcscmp(mode,L"gate")){
        const auto entered=std::wstring(receipt)+L".entered", released=std::wstring(receipt)+L".release";
        HANDLE marker=CreateFileW(entered.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(marker==INVALID_HANDLE_VALUE)return 10;CloseHandle(marker);
        auto until=GetTickCount64()+2500;
        while(GetFileAttributesW(released.c_str())==INVALID_FILE_ATTRIBUTES){if(GetTickCount64()>=until)return 11;Sleep(10);}
    }
    if(!wcscmp(mode,L"slow"))Sleep(400);
    std::wstring script=L"[IO.File]::WriteAllText("+literal(receipt)+L","+literal(argv[4])+L"); function global:prompt { 'OMP-LIVE-READY> ' }";
    int size=WideCharToMultiByte(CP_UTF8,0,script.data(),(int)script.size(),nullptr,0,nullptr,nullptr);
    std::string utf8(size,'\0');WideCharToMultiByte(CP_UTF8,0,script.data(),(int)script.size(),&utf8[0],size,nullptr,nullptr);
    std::fwrite(utf8.data(),1,utf8.size(),stdout);return !wcscmp(mode,L"fail")?9:0;
}
