#include <windows.h>
#include <string>
#include <cstring>
#include <cstdio>
#include <cstdint>
#include <limits>
static std::wstring theme;
static uint64_t revision=0;
static bool haveTheme=false,haveRevision=false,failTheme=false,failRevision=false;
static DWORD revisionType=REG_QWORD,themeType=REG_SZ,waitResult=WAIT_OBJECT_0;
static int held=0,failed=0,checks=0;
static void check(bool ok){++checks;if(!ok)++failed;}
static HANDLE fakeCreateMutex(LPSECURITY_ATTRIBUTES,BOOL,LPCWSTR){return reinterpret_cast<HANDLE>(1);}
static DWORD fakeWait(HANDLE,DWORD){if(waitResult==WAIT_OBJECT_0||waitResult==WAIT_ABANDONED)++held;return waitResult;}
static BOOL fakeRelease(HANDLE){--held;return TRUE;}
static BOOL fakeClose(HANDLE){return TRUE;}
static LSTATUS fakeRead(HKEY,LPCWSTR,LPCWSTR name,DWORD flags,LPDWORD,void* data,LPDWORD bytes){
    check(held==1);
    const bool isRevision=wcscmp(name,L"OmpRevision")==0;
    if(!(isRevision?haveRevision:haveTheme))return ERROR_FILE_NOT_FOUND;
    if(isRevision?(revisionType!=REG_QWORD||flags!=RRF_RT_REG_QWORD):(themeType!=REG_SZ||flags!=RRF_RT_REG_SZ))return ERROR_UNSUPPORTED_TYPE;
    const DWORD size=isRevision?sizeof revision:static_cast<DWORD>((theme.size()+1)*sizeof(wchar_t));
    const DWORD capacity=*bytes;*bytes=size;
    if(data){if(capacity<size)return ERROR_MORE_DATA;std::memcpy(data,isRevision?static_cast<const void*>(&revision):theme.c_str(),size);}
    return ERROR_SUCCESS;
}
static LSTATUS fakeWrite(HKEY,LPCWSTR,LPCWSTR name,DWORD type,const void* data,DWORD bytes){
    check(held==1);
    if(wcscmp(name,L"OmpRevision")==0){
        if(failRevision)return ERROR_ACCESS_DENIED;
        check(type==REG_QWORD&&bytes==sizeof revision);std::memcpy(&revision,data,bytes);haveRevision=true;
    }else{
        if(failTheme)return ERROR_ACCESS_DENIED;
        check(type==REG_SZ);theme.assign(static_cast<const wchar_t*>(data),bytes/sizeof(wchar_t)-1);haveTheme=true;
    }
    return ERROR_SUCCESS;
}
#define CreateMutexW fakeCreateMutex
#define WaitForSingleObject fakeWait
#define ReleaseMutex fakeRelease
#define CloseHandle fakeClose
#define RegGetValueW fakeRead
#define RegSetKeyValueW fakeWrite
#include "../src/omp_config.h"
int main(){
    using namespace omp_config;const wchar_t* key=L"private-mocked-key";
    Snapshot empty;check(snapshot(key,empty)&&!empty.present&&empty.revision==0);
    check(save(key,L"A",&empty));Snapshot a;check(snapshot(key,a)&&a.theme==L"A"&&a.revision==1);
    check(!save(key,L"stale",&empty)&&theme==L"A");
    check(save(key,L"B",nullptr));check(save(key,L"A",nullptr));
    check(!save(key,L"late",&a)&&theme==L"A"); // ABA is a newer configuration too.
    Snapshot now;check(snapshot(key,now));check(save(key,L"A",nullptr));
    check(!save(key,L"same-value-late",&now));
    check(snapshot(key,now));failRevision=true;
    check(!save(key,L"refused",&now)&&theme==L"A"&&revision==now.revision);failRevision=false;
    failTheme=true;check(!save(key,L"refused",&now)&&theme==L"A"&&revision==now.revision+1);failTheme=false;
    check(!save(key,L"late-after-failure",&now));
    revisionType=REG_SZ;check(!snapshot(key,now)&&!save(key,L"bad",nullptr));revisionType=REG_QWORD;
    themeType=REG_BINARY;check(!snapshot(key,now)&&!save(key,L"bad",nullptr));themeType=REG_SZ;
    revision=UINT64_MAX;check(!save(key,L"overflow",nullptr));revision=10;
    waitResult=WAIT_TIMEOUT;check(!snapshot(key,now)&&!save(key,L"timeout",nullptr));
    waitResult=WAIT_FAILED;check(!snapshot(key,now));
    waitResult=WAIT_ABANDONED;check(snapshot(key,now)&&save(key,L"recovered",&now));
    waitResult=WAIT_OBJECT_0;check(save(key,L"",nullptr));check(snapshot(key,now)&&now.present&&now.theme.empty());
    check(held==0);
    std::printf("OMP shared configuration: %d mocked actual read/compare/write checks, %d failed; no registry access\n",checks,failed);
    return failed?1:0;
}
