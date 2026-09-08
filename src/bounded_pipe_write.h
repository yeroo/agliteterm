#pragma once
#include <windows.h>
#include <vector>

namespace bounded_pipe_write {
struct Pending {
    HANDLE pipe = INVALID_HANDLE_VALUE;
    OVERLAPPED ov{};
    std::vector<char> bytes;
    ~Pending() { if (ov.hEvent) CloseHandle(ov.hEvent); if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe); }
};
inline bool complete(Pending*& pending, DWORD& written) {
    if (!pending || WaitForSingleObject(pending->ov.hEvent,0) != WAIT_OBJECT_0) return false;
    if (!GetOverlappedResult(pending->pipe,&pending->ov,&written,FALSE)) written=0;
    delete pending; pending=nullptr; return true;
}
// An unresolved cancellation transfers ownership to the caller. It must retain its input lease
// and this allocation until complete() observes actual success/cancellation/failure.
inline DWORD write(HANDLE pipe, const void* bytes, DWORD length, DWORD timeout, Pending*& deferred) {
    deferred=nullptr;
    auto* pending = new Pending;
    if (!DuplicateHandle(GetCurrentProcess(),pipe,GetCurrentProcess(),&pending->pipe,0,FALSE,DUPLICATE_SAME_ACCESS)) { delete pending; return 0; }
    pending->bytes.assign(static_cast<const char*>(bytes),static_cast<const char*>(bytes)+length);
    pending->ov.hEvent = CreateEventW(nullptr,TRUE,FALSE,nullptr);
    if (!pending->ov.hEvent) { delete pending; return 0; }
    DWORD written = 0;
    const BOOL issued = WriteFile(pending->pipe,pending->bytes.data(),length,nullptr,&pending->ov);
    if (!issued && GetLastError() != ERROR_IO_PENDING) { delete pending; return 0; }
    if (WaitForSingleObject(pending->ov.hEvent,timeout) == WAIT_OBJECT_0) {
        complete(pending,written); return written;
    }
    CancelIoEx(pending->pipe,&pending->ov);
    // Cancellation is asynchronous. Never free the OVERLAPPED/buffer until completion, and
    // never turn its cleanup into another unbounded wait on the control/lease worker.
    WaitForSingleObject(pending->ov.hEvent,1000);
    if (complete(pending,written)) return written; // cancellation may have lost to normal delivery
    deferred=pending;
    return 0;
}
}
