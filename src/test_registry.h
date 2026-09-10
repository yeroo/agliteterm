#pragma once
#include <string>

namespace lite_test_registry {
inline std::wstring endpoint(const std::wstring& run, const std::wstring& name) {
    if (run.empty()) return name;
    const auto prefix = L"agliteterm-test-" + run + L"-ctl-";
    const auto bare = name.rfind(L"\\\\.\\pipe\\", 0) == 0 ? name.substr(9) : name;
    return bare.rfind(prefix, 0) == 0 ? bare : prefix + bare;
}
// A test may select only its UUID-shaped namespace, never an arbitrary registry path.
inline bool paths(const std::wstring& run, std::wstring& current, std::wstring& legacy,
                  std::wstring& instances) {
    if (run.size() != 32) return false;
    for (wchar_t c : run) if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f'))) return false;
    const auto root = L"Software\\agliteterm-tests\\" + run;
    current = root + L"\\Current";
    legacy = root + L"\\Legacy";
    instances = current + L"\\Instances";
    return true;
}
}
