// Private argv/stdin forwarding oracle; never connects a pipe or invokes application commands.
#include <windows.h>
#include <cstdio>
#include <string>
static void hex(const std::string& s){for(unsigned char c:s)std::printf("%02x",c);std::puts("");}
int wmain(int argc,wchar_t** argv){
 for(int i=1;i<argc;++i){int n=WideCharToMultiByte(CP_UTF8,0,argv[i],-1,nullptr,0,nullptr,nullptr);std::string s(n,'\0');WideCharToMultiByte(CP_UTF8,0,argv[i],-1,s.data(),n,nullptr,nullptr);s.pop_back();hex(s);}
 std::string input;char buffer[256];DWORD got;
 while(ReadFile(GetStdHandle(STD_INPUT_HANDLE),buffer,sizeof buffer,&got,nullptr)&&got)input.append(buffer,got);
 std::puts("STDIN");hex(input);std::fputs("stub stderr\n",stderr);return 7;
}
