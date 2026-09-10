#include "../src/control_transport.h"
#include <atomic>
#include <cstdio>
#include <functional>
#include <string>
#include <cstdlib>
#include <thread>
static int checks = 0, failures = 0;
static void check(bool value, const char* label) { ++checks; if (!value) { ++failures; std::printf("FAIL %s\n", label); } }
struct Fixture {
    HANDLE server = INVALID_HANDLE_VALUE, client = INVALID_HANDLE_VALUE;
    std::thread worker;
    explicit Fixture(std::function<void(HANDLE)> serve) {
        static int sequence = 0;
        auto name = L"\\\\.\\pipe\\lite-control-unit-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(++sequence);
        server = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 256, 256, 0, nullptr);
        client = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
        if (server == INVALID_HANDLE_VALUE || client == INVALID_HANDLE_VALUE) std::abort();
        worker = std::thread([this, serve] { if (!ConnectNamedPipe(server, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) std::abort(); serve(server); DisconnectNamedPipe(server); });
    }
    ~Fixture() { if (client != INVALID_HANDLE_VALUE) CloseHandle(client); worker.join(); CloseHandle(server); }
};
static void readRequest(HANDLE pipe) { uint8_t buf[8]; DWORD n = 0; ReadFile(pipe, buf, sizeof(buf), &n, nullptr); }
static void put(HANDLE pipe, const void* bytes, DWORD length) { DWORD n = 0; WriteFile(pipe, bytes, length, &n, nullptr); }
static std::vector<uint8_t> request() { return { 4, 0, 0, 0, 'p', 'i', 'n', 'g' }; }
int main() {
    for (int mode = 0; mode < 7; ++mode) {
        Fixture f([mode](HANDLE pipe) {
            readRequest(pipe);
            uint32_t length = mode == 4 ? (1u << 20) + 1 : mode == 5 ? 0 : 4;
            if (mode == 1) { Sleep(250); return; }
            if (mode == 2) { put(pipe, &length, 2); Sleep(250); return; }
            put(pipe, &length, 4);
            if (mode == 4 || mode == 5) { Sleep(30); return; }
            if (mode == 3) { put(pipe, "po", 2); Sleep(250); return; }
            if (mode == 6) { put(pipe, "po", 2); return; }
            put(pipe, "pong", 4);
            // Keep the server open until the reply is read; DisconnectNamedPipe discards unread bytes.
            Sleep(30);
        });
        control_transport::Transport transport; auto req = request(); std::vector<uint8_t> reply;
        auto start = GetTickCount64(); bool ok = transport.exchange(f.client, req, reply, mode == 0 || mode == 5 ? 500 : 75);
        check(ok == (mode == 0 || mode == 5), "exchange status");
        check(GetTickCount64() - start < 500, "deadline is bounded");
        if (ok) check(mode == 5 ? reply.empty() : std::string(reply.begin(), reply.end()) == "pong", "complete response");
        else {
            check(f.client == INVALID_HANDLE_VALUE, "partial or failed channel is retired");
            check(reply.empty(), "no partial reply published");
            check(!transport.exchange(f.client, req, reply, 75), "no stale reply reused or request replayed");
        }
    }
    // All frame pieces share a deadline; byte-by-byte progress must not reset it.
    {
        Fixture f([](HANDLE pipe) { readRequest(pipe); const uint8_t bytes[] = {4,0,0,0,'p','o','n','g'}; for (auto b : bytes) { put(pipe, &b, 1); Sleep(25); } });
        control_transport::Transport transport; auto req = request(); std::vector<uint8_t> reply;
        auto start = GetTickCount64(); check(!transport.exchange(f.client, req, reply, 80), "drip feed cannot extend deadline");
        check(GetTickCount64() - start < 500 && f.client == INVALID_HANDLE_VALUE, "drip failure retires channel promptly");
    }
    {
        // Full successful transaction with partial reads and enough shared budget.
        Fixture f([](HANDLE pipe) { readRequest(pipe); const uint8_t bytes[] = {4,0,0,0,'p','o','n','g'}; for (auto b : bytes) { put(pipe, &b, 1); Sleep(5); } Sleep(30); });
        control_transport::Transport transport; auto req = request(); std::vector<uint8_t> reply;
        check(transport.exchange(f.client, req, reply, 500) && std::string(reply.begin(), reply.end()) == "pong", "partial reads accumulate exactly");
    }
    {
        // A contender times out without touching the in-flight transaction's handle.
        std::atomic<bool> entered{false};
        Fixture f([&](HANDLE pipe) { readRequest(pipe); entered = true; Sleep(150); uint32_t n = 4; put(pipe, &n, 4); put(pipe, "pong", 4); Sleep(30); });
        control_transport::Transport transport; bool first = false;
        std::thread caller([&] { auto req = request(); std::vector<uint8_t> reply; first = transport.exchange(f.client, req, reply, 500); });
        while (!entered.load()) Sleep(1);
        auto req = request(); std::vector<uint8_t> reply; auto start = GetTickCount64();
        check(!transport.exchange(f.client, req, reply, 25), "contention consumes caller deadline");
        check(GetTickCount64() - start < 500, "gate wait is bounded");
        caller.join(); check(first && f.client != INVALID_HANDLE_VALUE, "gate timeout preserves lock holder exchange");
    }
    {
        Fixture f([](HANDLE) { Sleep(250); });
        control_transport::Transport transport; std::vector<uint8_t> req(1024 * 1024, 'x'), reply;
        auto start = GetTickCount64(); check(!transport.exchange(f.client, req, reply, 75), "backpressured write is bounded");
        check(GetTickCount64() - start < 500 && f.client == INVALID_HANDLE_VALUE, "write timeout retires channel");
    }
    {
        control_transport::Transport transport; DWORD before = 0, after = 0;
        GetProcessHandleCount(GetCurrentProcess(), &before);
        for (int i = 0; i < 20; ++i) {
            Fixture f([](HANDLE pipe) { readRequest(pipe); Sleep(20); });
            auto req = request(); std::vector<uint8_t> reply;
            check(!transport.exchange(f.client, req, reply, 5), "repeated cancellation refuses");
        }
        HANDLE absent = INVALID_HANDLE_VALUE; auto req = request(); std::vector<uint8_t> reply;
        transport.exchange(absent, req, reply, 50); // reap completions after the last server exits
        GetProcessHandleCount(GetCurrentProcess(), &after);
        check(after <= before, "completed cancellation releases events and duplicated handles");
    }
    std::printf("control transport: %d checks, %d failed; private pipes only\n", checks, failures);
    return failures ? 1 : 0;
}
