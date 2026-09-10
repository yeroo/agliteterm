#pragma once
#include <windows.h>
#include <cstdint>
#include <cwctype>
#include <string>
#include <vector>

namespace omp_config {
struct Snapshot {
    uint64_t revision = 0;
    bool present = false;
    std::wstring theme;
    bool operator==(const Snapshot& other) const {
        return revision == other.revision && present == other.present && theme == other.theme;
    }
};
// All cooperating windows in this desktop session serialize read/compare/write. The registry
// key is part of the name so suite-private configuration never contends with the user's key.
class Guard {
    HANDLE mutex = nullptr;
    bool owned = false;
public:
    explicit Guard(const wchar_t* key) {
        uint64_t hash = 14695981039346656037ull;
        for (const wchar_t* p = key; *p; ++p) { hash ^= static_cast<uint16_t>(towlower(*p)); hash *= 1099511628211ull; }
        const auto name = L"Local\\agliteterm-omp-" + std::to_wstring(hash);
        mutex = CreateMutexW(nullptr, FALSE, name.c_str());
        if (mutex) { const auto result = WaitForSingleObject(mutex, 1000); owned = result == WAIT_OBJECT_0 || result == WAIT_ABANDONED; }
    }
    ~Guard() { if (owned) ReleaseMutex(mutex); if (mutex) CloseHandle(mutex); }
    explicit operator bool() const { return owned; }
    Guard(const Guard&) = delete;
    Guard& operator=(const Guard&) = delete;
};
inline bool readLocked(const wchar_t* key, Snapshot& result) {
    Snapshot current;
    DWORD bytes = sizeof current.revision;
    auto status = RegGetValueW(HKEY_CURRENT_USER, key, L"OmpRevision", RRF_RT_REG_QWORD, nullptr, &current.revision, &bytes);
    if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND) return false;
    if (status == ERROR_SUCCESS && bytes != sizeof current.revision) return false;
    bytes = 0;
    status = RegGetValueW(HKEY_CURRENT_USER, key, L"OmpTheme", RRF_RT_REG_SZ, nullptr, nullptr, &bytes);
    if (status == ERROR_SUCCESS) {
        if (bytes > 65536 || bytes < sizeof(wchar_t) || bytes % sizeof(wchar_t)) return false;
        std::vector<wchar_t> value(bytes / sizeof(wchar_t));
        const DWORD capacity = bytes;
        if (RegGetValueW(HKEY_CURRENT_USER, key, L"OmpTheme", RRF_RT_REG_SZ, nullptr, value.data(), &bytes) != ERROR_SUCCESS ||
            bytes > capacity || bytes < sizeof(wchar_t) || bytes % sizeof(wchar_t) || value[bytes / sizeof(wchar_t) - 1] != 0) return false;
        current.present = true;
        current.theme.assign(value.data(), bytes / sizeof(wchar_t) - 1);
    } else if (status != ERROR_FILE_NOT_FOUND) return false;
    result = std::move(current); return true;
}
inline bool snapshot(const wchar_t* key, Snapshot& result) {
    Guard hold(key); return hold && readLocked(key, result);
}
inline bool save(const wchar_t* key, const std::wstring& theme, const Snapshot* expected) {
    Guard hold(key); Snapshot current;
    if (!hold || !readLocked(key, current) || (expected && !(current == *expected)) || current.revision == UINT64_MAX) return false;
    // Publish the invalidation first. A failed theme write or crash can invalidate older requests,
    // but can never let them overwrite a newer successful write (including same-value/ABA writes).
    ++current.revision;
    if (RegSetKeyValueW(HKEY_CURRENT_USER, key, L"OmpRevision", REG_QWORD, &current.revision, sizeof current.revision) != ERROR_SUCCESS) return false;
    return RegSetKeyValueW(HKEY_CURRENT_USER, key, L"OmpTheme", REG_SZ, theme.c_str(),
        static_cast<DWORD>((theme.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}
}
