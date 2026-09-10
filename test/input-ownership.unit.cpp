#include <vector>
#include <cstdio>
#include <functional>
#include "shell_configuration.h"
using HANDLE=int;using DWORD=unsigned long;using BOOL=int;
constexpr DWORD INFINITE=0xffffffff,ERROR_IO_PENDING=997;
struct OVERLAPPED {HANDLE hEvent=0;};
int held=0,transfers=0;DWORD transferred=0;
std::function<void()> afterLookup;
struct LockG {LockG(){++held;}~LockG(){--held;if(afterLookup){auto f=std::move(afterLookup);afterLookup=nullptr;f();}}};
struct Session {HANDLE data=1;shell_configuration::InputGate inputGate;};
std::vector<Session*> g_sessions;
HANDLE CreateEventW(void*,BOOL,BOOL,void*){return 1;}
DWORD GetLastError(){return 0;}
BOOL WriteFile(HANDLE,const void*,DWORD n,void*,OVERLAPPED*){if(held)throw "I/O under global lock";++transfers;transferred=n;return 1;}
BOOL ReadFile(HANDLE,void*,DWORD n,void*,OVERLAPPED*){if(held)throw "I/O under global lock";++transfers;transferred=n;return 1;}
BOOL GetOverlappedResult(HANDLE,OVERLAPPED*,DWORD* n,BOOL){*n=transferred;return 1;}
BOOL CloseHandle(HANDLE){return 1;}
constexpr BOOL TRUE=1,FALSE=0;
namespace bounded_pipe_write {struct Pending {};DWORD write(HANDLE h,const void* b,DWORD n,DWORD,Pending*&){WriteFile(h,b,n,nullptr,nullptr);return n;}}
// ACTUAL_OV_IO
int main(){
    int checks=0;auto check=[&](bool ok){++checks;if(!ok)throw checks;};
    Session s;g_sessions={&s};char buffer[8]{};
    check(ovIo(s.data,true,"abc",nullptr,3)==3);check(transfers==1);
    auto lease=s.inputGate.reserve();check(lease!=0);
    check(ovIo(s.data,true,"abc",nullptr,3)==0);check(transfers==1);
    // Removed before lookup: no raw write, including protocol/reserved writes.
    g_sessions.clear();bool refused=false;
    check(ovIo(s.data,true,"abc",nullptr,3,true,false,&refused)==0);check(refused&&transfers==1);
    check(ovIo(s.data,true,"abc",nullptr,3,false)==0);check(transfers==1);
    check(ovIo(s.data,true,"abc",nullptr,3,true,false,nullptr,lease)==0);check(transfers==1);
    check(ovIo(s.data,false,nullptr,buffer,3)==3);check(transfers==2); // reader may drain retained handle
    // Removed AFTER lookup: the retained gate must still deny unreserved input.
    g_sessions={&s};afterLookup=[] {g_sessions.clear();};
    check(ovIo(s.data,true,"abc",nullptr,3)==0);check(transfers==2);
    s.inputGate.release(lease);g_sessions={&s};afterLookup=[] {g_sessions.clear();};
    check(ovIo(s.data,true,"abc",nullptr,3)==3);check(transfers==3&&held==0);
    std::printf("Input ownership: %d actual I/O dispatch checks passed; no host\n",checks);
}
