#include <string>
#include <map>
#include <vector>
#include <cwchar>
#include <cstdio>
using DWORD = unsigned long;
using HANDLE = int;
constexpr int INVALID_HANDLE_VALUE = -1;
constexpr DWORD ERROR_FILE_NOT_FOUND=2, ERROR_PATH_NOT_FOUND=3, ERROR_ACCESS_DENIED=5, ERROR_NO_MORE_FILES=18, ERROR_MORE_DATA=234;
struct WIN32_FIND_DATAW { wchar_t cFileName[260]{}; };
std::string mode;
int opens=0, closes=0, logs=0, nexts[3]{};
DWORD lastError=0;
std::string narrow(const std::wstring& text) { return {text.begin(), text.end()}; }
std::wstring environmentPath(const wchar_t* name) {
    return std::wcscmp(name,L"POSH_THEMES_PATH")==0 ? L"C:\\priority" :
        std::wcscmp(name,L"LOCALAPPDATA")==0 ? L"C:\\fallback" : L"";
}
std::wstring stateDir() { return {}; }
namespace profiles { std::string folded(const std::string& s) { return s; } }
void logWarn(const char*, const char*) { ++logs; }
bool localThemeFile(const std::wstring& file,std::string& path) { path=narrow(file); return file.find(L"bad") == std::wstring::npos; }
DWORD GetLastError() { return lastError; }
HANDLE FindFirstFileW(const wchar_t*,WIN32_FIND_DATAW* data) {
    int handle=++opens;
    if(mode=="missing" || mode=="missing-path" || mode=="empty" || (mode=="denied" && handle==1)) {
        lastError=mode=="missing" ? ERROR_FILE_NOT_FOUND : mode=="missing-path" ? ERROR_PATH_NOT_FOUND :
            mode=="empty" ? ERROR_NO_MORE_FILES : ERROR_ACCESS_DENIED;
        return INVALID_HANDLE_VALUE;
    }
    std::wcscpy(data->cFileName, mode=="invalid-entry" && handle==1 ? L"bad.omp.json" : L"same.omp.json");
    return handle;
}
bool FindNextFileW(HANDLE h,WIN32_FIND_DATAW* data) {
    ++nexts[h];
    if(mode=="limit" && h==1) return true;
    if(mode=="invalid-entry" && h==1 && nexts[h]==1) { std::wcscpy(data->cFileName,L"valid.omp.json"); return true; }
    lastError=mode=="interrupted" && h==1 ? ERROR_ACCESS_DENIED : ERROR_NO_MORE_FILES;
    return false;
}
bool FindClose(HANDLE) { ++closes; return true; }
// INSERT_PRODUCTION_CATALOG
int main() {
    int checks=0,failed=0;auto check=[&](bool value){++checks;if(!value)++failed;};
    for(const char* scenario : {"missing","missing-path","empty","denied","interrupted","normal","limit","invalid-entry"}) {
        mode=scenario; opens=closes=logs=0;nexts[1]=nexts[2]=0;
        std::string error="old error";const auto result=ompCatalog(&error);
        bool absent=mode=="missing" || mode=="missing-path" || mode=="empty";
        bool broken=mode=="denied" || mode=="interrupted" || mode=="limit";
        check(opens==2);check(closes==(absent ? 0 : mode=="denied" ? 1 : 2));
        check(error.empty()!=broken);check(logs==(broken ? 1 : 0));
        check(result.empty()==absent);
        if(mode=="normal")check(result.at("same").second.find("C:\\priority")==0); // first directory wins
        if(mode=="invalid-entry")check(result.count("valid")==1); // filtered entry still advances the enumeration
        if(mode=="limit")check(nexts[1]==4096);
    }
    std::printf("OMP discovery: %d actual-function checks, %d failed; fake filesystem only\n",checks,failed);
    return failed ? 1 : 0;
}
