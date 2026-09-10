#pragma once
#include <windows.h>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace control_transport {
// One framed request/reply, including contention, has one deadline. A failed exchange retires
// the channel: the next request must never consume the previous request's late reply. Mutating
// requests are not replayed; a lost reply does NOT prove the host did nothing.
class Transport {
    struct Pending {
        HANDLE pipe = INVALID_HANDLE_VALUE;
        OVERLAPPED ov{};
        std::vector<uint8_t> bytes;
        ~Pending() { if (ov.hEvent) CloseHandle(ov.hEvent); if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe); }
    };
    std::timed_mutex gate;
    // Canceled I/O still owns its OVERLAPPED and bytes until Windows signals completion.
    // Never wait indefinitely for cancellation. If it never completes, retain this allocation
    // until process exit (raw pointers deliberately outlive this object's destructor).
    std::vector<Pending*> retired;
    void reap() {
        for (auto i = retired.begin(); i != retired.end();) {
            if (WaitForSingleObject((*i)->ov.hEvent, 0) == WAIT_OBJECT_0) { delete *i; i = retired.erase(i); }
            else ++i;
        }
    }
    bool transfer(HANDLE pipe, bool write, uint8_t* bytes, DWORD length, ULONGLONG deadline) {
        DWORD offset = 0;
        while (offset < length) {
            if (GetTickCount64() >= deadline) return false;
            auto* pending = new Pending;
            if (!DuplicateHandle(GetCurrentProcess(), pipe, GetCurrentProcess(), &pending->pipe, 0, FALSE, DUPLICATE_SAME_ACCESS)) { delete pending; return false; }
            pending->ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!pending->ov.hEvent) { delete pending; return false; }
            pending->bytes.resize(length - offset);
            if (write) std::memcpy(pending->bytes.data(), bytes + offset, length - offset);
            BOOL issued = write ? WriteFile(pending->pipe, pending->bytes.data(), length - offset, nullptr, &pending->ov)
                                : ReadFile(pending->pipe, pending->bytes.data(), length - offset, nullptr, &pending->ov);
            if (!issued && GetLastError() != ERROR_IO_PENDING) { delete pending; return false; }
            const auto now = GetTickCount64();
            DWORD remaining = now < deadline ? static_cast<DWORD>(deadline - now) : 0;
            if (WaitForSingleObject(pending->ov.hEvent, remaining) != WAIT_OBJECT_0) {
                CancelIoEx(pending->pipe, &pending->ov);
                retired.push_back(pending);
                return false;
            }
            DWORD transferred = 0;
            bool ok = GetOverlappedResult(pending->pipe, &pending->ov, &transferred, FALSE) && transferred > 0;
            if (ok && !write) std::memcpy(bytes + offset, pending->bytes.data(), transferred);
            delete pending;
            if (!ok) return false;
            offset += transferred;
        }
        return true;
    }
public:
    bool exchange(HANDLE& pipe, std::vector<uint8_t>& request, std::vector<uint8_t>& reply, DWORD timeoutMs) {
        reply.clear();
        const auto start = GetTickCount64();
        std::unique_lock<std::timed_mutex> lock(gate, std::defer_lock);
        if (!lock.try_lock_for(std::chrono::milliseconds(timeoutMs))) return false;
        reap();
        if (pipe == INVALID_HANDLE_VALUE) return false;
        const auto deadline = start + timeoutMs;
        // Failing before issuance must not retire a channel used successfully by the lock holder.
        if (GetTickCount64() >= deadline) return false;
        bool ok = transfer(pipe, true, request.data(), static_cast<DWORD>(request.size()), deadline);
        uint32_t length = 0;
        if (ok) ok = transfer(pipe, false, reinterpret_cast<uint8_t*>(&length), sizeof(length), deadline) && length <= (1u << 20);
        if (ok) { reply.resize(length); ok = transfer(pipe, false, reply.data(), length, deadline); }
        if (!ok) { CloseHandle(pipe); pipe = INVALID_HANDLE_VALUE; reply.clear(); }
        reap();
        return ok;
    }
};
}
