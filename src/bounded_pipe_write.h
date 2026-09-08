#pragma once
#include <windows.h>
#include <vector>

namespace bounded_pipe_write {
struct Pending {
    OVERLAPPED ov{};
    std::vector<char> bytes;
    ~Pending() { if (ov.hEvent) CloseHandle(ov.hEvent); }
};
inline DWORD WINAPI retire(void* value) {
    auto* pending = static_cast<Pending*>(value);
    WaitForSingleObject(pending->ov.hEvent, INFINITE);
    delete pending; return 0;
}
inline DWORD write(HANDLE pipe, const void* bytes, DWORD length, DWORD timeout) {
    auto* pending = new Pending;
    pending->bytes.assign(static_cast<const char*>(bytes),static_cast<const char*>(bytes)+length);
    pending->ov.hEvent = CreateEventW(nullptr,TRUE,FALSE,nullptr);
    if (!pending->ov.hEvent) { delete pending; return 0; }
    DWORD written = 0;
    const BOOL issued = WriteFile(pipe,pending->bytes.data(),length,nullptr,&pending->ov);
    if (!issued && GetLastError() != ERROR_IO_PENDING) { delete pending; return 0; }
    if (WaitForSingleObject(pending->ov.hEvent,timeout) == WAIT_OBJECT_0) {
        if (!GetOverlappedResult(pipe,&pending->ov,&written,FALSE)) written = 0;
        delete pending; return written;
    }
    CancelIoEx(pipe,&pending->ov);
    // Cancellation is asynchronous. Never free the OVERLAPPED/buffer until completion, and
    // never turn its cleanup into another unbounded wait on the control/lease worker.
    if (WaitForSingleObject(pending->ov.hEvent,1000) == WAIT_OBJECT_0) delete pending;
    else if (!QueueUserWorkItem(retire,pending,WT_EXECUTELONGFUNCTION)) {
        // Extremely low-resource failure: retain the allocation rather than risk kernel UAF.
        // The process owns it until shutdown. A failed write never authorizes a resume.
    }
    return 0;
}
}
