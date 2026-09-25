// #110: bounded session type/paste. The actual chunk/deadline/bracket logic, the reply wording, the
// input gate's writeRetaining, and the real bounded_pipe_write against a real named pipe. No host.
#include <windows.h>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>
#include <functional>
#include "bounded_pipe_write.h"
#include "bounded_input.h"
#include "shell_configuration.h"
using namespace bounded_input;
using Pending = bounded_pipe_write::Pending;
static int checks = 0, failures = 0;
static void check(bool ok, const char* what) { ++checks; if (!ok) { ++failures; std::printf("FAIL %d: %s\n", checks, what); } }
static bool has(const std::string& s, const char* part) { return s.find(part) != std::string::npos; }

// A scripted chunk writer: each call takes the next step. -1 = full, -2 = pending, n >= 0 = n bytes
// then stop (timedOut per `timeouts`). A fake clock advances by `tick` ms per call.
struct Script {
    std::vector<int> steps; bool timeouts = true; unsigned long long clock = 0, tick = 0;
    std::vector<std::string> chunks; std::vector<unsigned long> timeoutsSeen; std::vector<Pending*> made;
    Result<Pending> run(const std::string& bytes, size_t open = 0, size_t close = 0, Limits limits = {}) {
        size_t i = 0;
        return send<Pending>(bytes, open, close, limits,
            [&](const char* p, unsigned long n, unsigned long timeout, Pending*& deferred, bool& timedOut) -> unsigned long {
                chunks.emplace_back(p, n); timeoutsSeen.push_back(timeout); clock += tick;
                const int step = i < steps.size() ? steps[i++] : -1;
                if (step == -1) return n;
                if (step == -2) { deferred = new Pending; made.push_back(deferred); return 0; }
                timedOut = timeouts; return static_cast<unsigned long>(step);
            }, [&] { return clock; });
    }
    ~Script() { for (auto* p : made) delete p; }
};

static void chunking() {
    const std::string ascii(10000, 'a');
    check(chunkEnd(ascii, 0, ascii.size()) == 4096, "ascii chunk is 4096");
    check(chunkEnd(ascii, 8192, ascii.size()) == 10000, "last chunk stops at the limit");
    check(chunkEnd(ascii, 0, 100) == 100, "never past the limit");
    // A 3-byte character (E2 82 AC, the euro sign) straddling 4096 moves the cut back to its lead byte.
    std::string euro(4095, 'a'); euro += "\xE2\x82\xAC"; euro += std::string(100, 'b');
    check(chunkEnd(euro, 0, euro.size()) == 4095, "UTF-8 cut moves back to the lead byte");
    std::string four(4094, 'a'); four += "\xF0\x9F\x98\x80"; four += "zz";
    check(chunkEnd(four, 0, four.size()) == 4094, "4-byte sequence cut moves back 2");
    // No lead byte within 3 (invalid UTF-8 / binary): cut at the max.
    std::string bad(4090, 'a'); bad += std::string(10, '\x80');
    check(chunkEnd(bad, 0, bad.size()) == 4096, "invalid UTF-8 cuts at the max");
    std::string ascii80(4095, 'a'); ascii80 += '\x80'; ascii80 += "tail";
    check(chunkEnd(ascii80, 0, ascii80.size()) == 4096, "continuation after ASCII cuts at the max");
    // The whole text is chunked with no character split.
    Script s; std::string text; for (int k = 0; k < 3000; ++k) text += "\xE2\x82\xAC";
    auto r = s.run(text);
    check(r.stop == Stop::Done && r.written == text.size() && r.chunk == 0 && !r.pending, "full write");
    std::string joined; bool whole = true;
    for (auto& c : s.chunks) { joined += c; whole = whole && c.size() <= 4096 && c.size() % 3 == 0; }
    check(joined == text && whole && s.chunks.size() == 3, "chunks rejoin and never split a character");
}

static void stops() {
    const std::string text(10000, 'x');
    { Script s; s.steps = {-1, 0}; auto r = s.run(text);
      check(r.stop == Stop::TimedOut && r.written == 4096 && r.chunk == 4096 && !r.pending, "deadline: N of M, cancelled chunk");
      auto m = outcome("type", r);
      check(!m.first && has(m.second, "4096 of 10000 bytes written") && has(m.second, "the 4096-byte chunk at offset 4096 was cancelled") &&
            has(m.second, "may have been partly delivered") && has(m.second, "remaining 1808 bytes were not written"), "deadline wording"); }
    { Script s; s.steps = {100}; s.timeouts = false; auto r = s.run(text);
      check(r.stop == Stop::Failed && r.written == 100 && r.chunk == 3996, "failure keeps confirmed partial count");
      auto m = outcome("paste", r);
      check(!m.first && has(m.second, "session paste: 100 of 10000") && has(m.second, "failed and may have been partly delivered"), "failure wording"); }
    { Script s; s.steps = {-1, -2}; auto r = s.run(text);
      check(r.stop == Stop::Pending && r.written == 4096 && r.chunk == 4096 && r.pending, "pending: owner receives Pending");
      auto m = outcome("type", r);
      check(has(m.second, "still in flight and may still arrive") && has(m.second, "stays reserved until that write resolves"), "pending wording"); }
    { Script s; s.tick = 8000; auto r = s.run(text); // each chunk "takes" 8 s: the third is never issued
      check(r.stop == Stop::TimedOut && r.written == 8192 && r.chunk == 0 && s.chunks.size() == 2, "deadline between chunks issues nothing more");
      check(s.timeoutsSeen[0] == kDeadlineMs && s.timeoutsSeen[1] == kDeadlineMs - 8000, "per-chunk timeout is the time left");
      auto m = outcome("type", r);
      check(has(m.second, "8192 of 10000 bytes written before the 15 s input deadline; the remaining 1808 bytes"), "between-chunk wording"); }
    { Script s; auto r = s.run(text); auto m = outcome("type", r); check(m.first && m.second == "typed", "typed unchanged"); }
    { Result<Pending> r; r.stop = Stop::Done; check(outcome("paste", r) == std::make_pair(true, std::string("pasted")), "pasted unchanged"); }
    { Result<Pending> r; r.stop = Stop::Refused; r.total = 5;
      check(outcome("type", r).second == "session type: input to this pane is busy or reserved; nothing typed", "refusal typed");
      check(outcome("paste", r).second == "session paste: input to this pane is busy or reserved; nothing pasted", "refusal pasted"); }
    { Result<Pending> r; r.stop = Stop::NoInput; check(has(outcome("paste", r).second, "no live input; nothing pasted"), "no input"); }
}

static void brackets() {
    const std::string open = "\x1b[200~", close = "\x1b[201~", body(5000, 'p');
    const std::string text = open + body + close; const auto M = text.size();
    { Script s; auto r = s.run(text, 6, 6);
      check(r.stop == Stop::Done && s.chunks.size() == 4 && s.chunks[0] == open && s.chunks[3] == close, "markers are their own chunks"); }
    { Script s; s.steps = {0}; auto r = s.run(text, 6, 6);
      check(r.bracket == Bracket::Unknown && s.chunks.size() == 1, "opening marker stopped: unknown, no close");
      check(has(outcome("paste", r).second, "whether the bracketed paste was opened is unknown"), "unknown wording"); }
    { Script s; s.steps = {-2}; auto r = s.run(text, 6, 6);
      check(r.bracket == Bracket::Unknown && r.pending && s.chunks.size() == 1, "opening marker pending: unknown, no close"); }
    { Script s; s.steps = {-1, 0}; auto r = s.run(text, 6, 6);
      check(r.bracket == Bracket::Closed && s.chunks.size() == 3 && s.chunks[2] == close && s.timeoutsSeen[2] == kBracketCloseMs, "body stopped: close sent with its own bound");
      check(r.written == 6 && r.chunk == 4096, "counts exclude the separate close");
      auto m = outcome("paste", r);
      check(has(m.second, ("6 of " + std::to_string(M) + " bytes written").c_str()) && has(m.second, "then closed (ESC[201~ written)"), "closed wording"); }
    { Script s; s.steps = {-1, -1, -2}; auto r = s.run(text, 6, 6);
      check(r.bracket == Bracket::LeftOpen && r.pending && s.chunks.size() == 3, "body pending: left open, no close attempted");
      check(has(outcome("paste", r).second, "left open (no ESC[201~ sent)"), "left open wording"); }
    { Script s; s.steps = {-1, 0, 0}; auto r = s.run(text, 6, 6);
      check(r.bracket == Bracket::CloseFailed && !r.pending, "close cancelled");
      check(has(outcome("paste", r).second, "ESC[201~ may have been partly delivered"), "close failed wording"); }
    { Script s; s.steps = {-1, 0, -2}; auto r = s.run(text, 6, 6);
      check(r.bracket == Bracket::ClosePending && r.pending && r.stop == Stop::TimedOut, "close pending keeps the reservation");
      auto m = outcome("paste", r).second;
      check(has(m, "closing ESC[201~ is still in flight") && has(m, "stays reserved"), "close pending wording"); }
    { Script s; s.steps = {-1, -1, -1, 0}; auto r = s.run(text, 6, 6);
      check(r.bracket == Bracket::CloseStopped && s.chunks.size() == 4 && r.written == 5006, "stopped IN the close marker: not retried"); }
    { Script s; s.steps = {-1, 0}; s.tick = 9000; auto r = s.run(text, 6, 6); // 18 s elapsed: 18+0.5+1 > 17.5
      check(r.bracket == Bracket::NoTime && s.chunks.size() == 2, "no budget: close not attempted");
      check(has(outcome("paste", r).second, "no time left"), "no time wording"); }
    { Script s; s.steps = {-1, 0}; s.tick = 7000; auto r = s.run(text, 6, 6); // 14 s: 14+1.5 <= 17.5
      check(r.bracket == Bracket::Closed, "close attempted while within the cap"); }
    check(Limits{}.capMs() + kGateWaitMs == 22500, "worst case 22.5 s");
}

static void gate() {
    using shell_configuration::InputGate;
    unsigned long long retained = 99;
    { InputGate g; int ran = 0;
      check(g.writeRetaining(10, [&] { ++ran; return false; }, retained) && ran == 1 && retained == 0, "free gate: runs, no reservation");
      check(g.reserve(0) != 0, "nothing retained"); }
    { InputGate g; auto lease = g.reserve(0); int ran = 0;
      check(!g.writeRetaining(10, [&] { ++ran; return false; }, retained) && ran == 0, "refused while reserved, nothing written");
      g.release(lease);
      check(g.write(true, true, [] {}), "a refusal leaves the pane untouched (written not set)"); }
    { InputGate g; int ran = 0; HANDLE entered = CreateEventW(nullptr, TRUE, FALSE, nullptr), leave = CreateEventW(nullptr, TRUE, FALSE, nullptr);
      std::thread busy([&] { g.write(false, true, [&] { SetEvent(entered); WaitForSingleObject(leave, INFINITE); }); });
      WaitForSingleObject(entered, INFINITE);
      const auto t0 = GetTickCount64();
      check(!g.writeRetaining(200, [&] { ++ran; return false; }, retained) && ran == 0, "busy gate: bounded wait refuses");
      check(GetTickCount64() - t0 < 2000, "the wait is bounded");
      SetEvent(leave); busy.join(); CloseHandle(entered); CloseHandle(leave);
      check(g.write(true, true, [] {}), "lock-timeout refusal leaves written unset"); }
    { InputGate g; int later = 0; HANDLE entered = CreateEventW(nullptr, TRUE, FALSE, nullptr), leave = CreateEventW(nullptr, TRUE, FALSE, nullptr);
      std::thread first([&] { unsigned long long r2 = 0; g.writeRetaining(1000, [&] { SetEvent(entered); WaitForSingleObject(leave, INFINITE); return false; }, r2); });
      WaitForSingleObject(entered, INFINITE);
      std::thread second([&] { g.write(true, false, [&] { ++later; }); }); // an untokened writer queues, as before
      Sleep(50); check(later == 0, "other writers queue behind type/paste");
      SetEvent(leave); first.join(); second.join(); CloseHandle(entered); CloseHandle(leave);
      check(later == 1, "and run once it finishes"); }
    { InputGate g; g.setReadOnly(true); int ran = 0;
      check(g.writeRetaining(10, [&] { ++ran; return false; }, retained) && ran == 1, "read-only does not ban session type (P9)"); }
    // Injected unresolved write: the pane stays reserved until the Pending resolves, then is released.
    { InputGate g; Result<Pending> r; Script s; s.steps = {-1, -2};
      const bool entered = g.writeRetaining(10, [&] { r = s.run(std::string(9000, 'q')); return r.pending != nullptr; }, retained);
      check(entered && r.pending && retained != 0, "unresolved chunk retains a reservation");
      check(g.reserve(0) == 0, "human keys fail closed while it is unresolved");
      int ran = 0; check(!g.write(true, false, [&] { ++ran; }) && ran == 0, "untokened writers refused while unresolved");
      Pending* p = r.pending; s.made.clear();
      p->ov.hEvent = CreateEventW(nullptr, TRUE, TRUE, nullptr); // the write resolves
      DWORD ignored = 0; const auto token = retained;
      unsigned long long again = 0; check(!g.writeRetaining(10, [] { return false; }, again), "a second type is refused meanwhile");
      if (bounded_pipe_write::complete(p, ignored)) g.release(token);
      check(!p, "complete() took the Pending");
      check(g.reserve(0) != 0, "released after completion"); }
}

// The real bounded_pipe_write, through send(), against a real named pipe.
static void realPipe() {
    wchar_t name[96]; swprintf_s(name, L"\\\\.\\pipe\\agliteterm-bounded-input-%lu", GetCurrentProcessId());
    auto server = [&] { return CreateNamedPipeW(name, PIPE_ACCESS_INBOUND, PIPE_TYPE_BYTE | PIPE_WAIT, 1, 0, 4096, 0, nullptr); };
    auto client = [&] { return CreateFileW(name, GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr); };
    auto now = [] { return GetTickCount64(); };
    std::string text; for (int k = 0; k < 20000; ++k) text += k % 7 ? "ab\xE2\x82\xAC" : "\r\n";
    { HANDLE srv = server(); HANDLE cli = client(); std::string got;
      std::thread reader([&] { char buf[1024]; DWORD n = 0; while (ReadFile(srv, buf, sizeof buf, &n, nullptr) && n) got.append(buf, n); });
      auto r = send<Pending>(text, 0, 0, Limits{}, [&](const char* p, unsigned long n, unsigned long t, Pending*& d, bool& to) {
          return bounded_pipe_write::write(cli, p, n, t, d, &to); }, now);
      CloseHandle(cli); reader.join(); CloseHandle(srv);
      check(r.stop == Stop::Done && r.written == text.size() && got == text, "real pipe, draining reader: every byte, in order"); }
    { HANDLE srv = server(); HANDLE cli = client(); // nobody reads: the pipe fills and the deadline hits
      Limits quick; quick.deadlineMs = 400;
      const auto t0 = GetTickCount64();
      auto r = send<Pending>(text, 0, 0, quick, [&](const char* p, unsigned long n, unsigned long t, Pending*& d, bool& to) {
          return bounded_pipe_write::write(cli, p, n, t, d, &to); }, now);
      const auto took = GetTickCount64() - t0;
      check(r.stop == Stop::TimedOut && r.written < text.size() && r.chunk > 0 && !r.pending, "real pipe, stalled reader: stops at the deadline");
      check(took < quick.deadlineMs + kCancelWaitMs + 500, "and answers inside deadline + cancellation wait");
      std::string got; char buf[4096]; DWORD avail = 0;
      while (PeekNamedPipe(srv, nullptr, 0, nullptr, &avail, nullptr) && avail) { DWORD n = 0; if (!ReadFile(srv, buf, sizeof buf, &n, nullptr)) break; got.append(buf, n); }
      check(got.size() >= r.written && got.size() <= r.written + r.chunk && got == text.substr(0, got.size()),
            "delivered = N confirmed, plus at most the cancelled chunk");
      auto m = outcome("paste", r).second;
      check(has(m, (std::to_string(r.written) + " of " + std::to_string(text.size())).c_str()), "reply reports N of M");
      CloseHandle(cli); CloseHandle(srv); }
}

int main() {
    // An unbounded write is the bug under test: fail, never hang the suite.
    std::thread([] { Sleep(30000); std::printf("FAIL: bounded input checks still running after 30 s (unbounded write?)\n");
                     std::fflush(stdout); ExitProcess(3); }).detach();
    chunking(); stops(); brackets(); gate(); realPipe();
    std::printf("bounded input: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
