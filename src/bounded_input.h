#pragma once
// session type / session paste: one bounded, chunked write into a pane, so the reply always comes
// well inside agwintermctl's 30 s reply deadline (#110). Pure C++: the Win32 chunk writer, the
// clock and the Pending type are supplied by the caller, so the stop/bracket logic is testable.
#include <string>
#include <utility>

namespace bounded_input {
constexpr unsigned long kGateWaitMs = 5000;      // wait for the pane's input gate
constexpr unsigned long kDeadlineMs = 15000;     // one deadline across the whole text
constexpr unsigned long kBracketCloseMs = 500;   // closing ESC[201~ after a stopped paste
constexpr unsigned long kCancelWaitMs = 1000;    // bounded_pipe_write::write's cancellation wait
constexpr unsigned long kChunkBytes = 4096;
static_assert(kGateWaitMs + kDeadlineMs + kCancelWaitMs + kBracketCloseMs + kCancelWaitMs < 25000,
              "type/paste must answer well inside agwintermctl's 30 s reply deadline");

struct Limits {
    unsigned long deadlineMs = kDeadlineMs, closeMs = kBracketCloseMs, cancelWaitMs = kCancelWaitMs;
    unsigned long capMs() const { return deadlineMs + cancelWaitMs + closeMs + cancelWaitMs; }
};

enum class Stop { Done, Refused, NoInput, TimedOut, Failed, Pending };
enum class Bracket {
    None,          // not a bracketed paste, or it completed normally
    Unknown,       // the opening ESC[200~ itself was stopped: it may have been partly delivered
    LeftOpen,      // opened; a chunk is still in flight, so no close was attempted
    NoTime,        // opened; no time left in the budget to close it
    Closed,        // opened; a separate ESC[201~ was written after the stop
    CloseStopped,  // the stopped chunk WAS the closing marker: it may have been partly delivered
    CloseFailed,   // the separate ESC[201~ was cancelled/failed and may have been partly delivered
    ClosePending,  // the closing ESC[201~ (its own chunk, or the separate close) is still in flight
};

template<class Pending> struct Result {
    unsigned long total = 0;    // M: bytes asked for (paste: markers included)
    unsigned long written = 0;  // N: confirmed written, from offset 0
    unsigned long chunk = 0;    // K: the stopped chunk at offset N (cancelled/failed/in flight)
    unsigned long closed = 0;   // the separately attempted ESC[201~: in neither N nor K; `bracket` reports it
    Stop stop = Stop::Done;
    Bracket bracket = Bracket::None;
    Pending* pending = nullptr; // unresolved write: the caller owns it and keeps the pane reserved
};

// End of the chunk starting at `from`, at most kChunkBytes and never past `limit`. A cut that would
// land inside a UTF-8 sequence moves back (at most 3 continuation bytes) to that sequence's lead
// byte; if there is no lead byte there (invalid UTF-8, or --allow-control binary), cut at the max.
inline size_t chunkEnd(const std::string& s, size_t from, size_t limit, size_t max = kChunkBytes) {
    size_t end = from + max;
    if (end >= limit) return limit;
    auto cont = [&](size_t i) { return (static_cast<unsigned char>(s[i]) & 0xC0) == 0x80; };
    size_t e = end;
    for (int n = 0; n < 3 && e > from && cont(e); ++n) --e;
    if (e == end) return end;
    if (e > from && (static_cast<unsigned char>(s[e]) & 0xC0) == 0xC0) return e;
    return end;
}

// write(ptr, len, timeoutMs, Pending*& deferred, bool& timedOut) -> bytes confirmed written.
// now() -> milliseconds, monotonic. openLen/closeLen > 0: the paste's ESC[200~ / ESC[201~, each
// written as its own chunk so whether the bracket was opened (or its close stopped) is known.
template<class Pending, class Write, class Now>
Result<Pending> send(const std::string& bytes, size_t openLen, size_t closeLen, const Limits& limits,
                     Write&& write, Now&& now) {
    Result<Pending> r;
    r.total = static_cast<unsigned long>(bytes.size());
    const auto start = now();
    const size_t bodyEnd = bytes.size() - closeLen;
    size_t off = 0;
    bool timedOut = false;
    while (off < bytes.size()) {
        const size_t end = openLen && off == 0 ? openLen : off < bodyEnd ? chunkEnd(bytes, off, bodyEnd) : bytes.size();
        const auto elapsed = static_cast<unsigned long>(now() - start);
        if (elapsed >= limits.deadlineMs) { r.stop = Stop::TimedOut; break; } // nothing issued for this chunk
        const auto n = static_cast<unsigned long>(end - off);
        Pending* deferred = nullptr;
        timedOut = false;
        const unsigned long w = write(bytes.data() + off, n, limits.deadlineMs - elapsed, deferred, timedOut);
        if (deferred) { r.pending = deferred; r.chunk = n; r.stop = Stop::Pending; break; }
        if (w >= n) { off = end; continue; }
        off += w; r.chunk = n - w; r.stop = timedOut ? Stop::TimedOut : Stop::Failed;
        break;
    }
    r.written = static_cast<unsigned long>(off);
    if (!openLen || r.stop == Stop::Done) return r;
    if (off < openLen) { r.bracket = off == 0 && r.chunk == 0 ? Bracket::None : Bracket::Unknown; return r; }
    if (r.stop == Stop::Pending) { r.bracket = off >= bodyEnd ? Bracket::ClosePending : Bracket::LeftOpen; return r; }
    if (off >= bodyEnd && r.chunk) { r.bracket = Bracket::CloseStopped; return r; }
    if (static_cast<unsigned long>(now() - start) + limits.closeMs + limits.cancelWaitMs > limits.capMs()) {
        r.bracket = Bracket::NoTime; return r;
    }
    const auto n = static_cast<unsigned long>(closeLen);
    Pending* deferred = nullptr;
    timedOut = false;
    const unsigned long w = write(bytes.data() + bodyEnd, n, limits.closeMs, deferred, timedOut);
    r.closed = n;
    if (deferred) { r.pending = deferred; r.bracket = Bracket::ClosePending; }
    else if (w < n) r.bracket = Bracket::CloseFailed;
    else if (off == bodyEnd) { r.stop = Stop::Done; r.written = r.total; r.closed = 0; r.bracket = Bracket::None; } // every byte went
    else r.bracket = Bracket::Closed;
    return r;
}

// The reply for a Result: {ok, text}. verb is "type" or "paste".
template<class Pending> std::pair<bool, std::string> outcome(const char* verb, const Result<Pending>& r) {
    const std::string v = verb, did = v == "type" ? "typed" : "pasted";
    const std::string head = "session " + v + ": ";
    switch (r.stop) {
    case Stop::Done: return {true, did};
    case Stop::Refused: return {false, head + "input to this pane is busy or reserved; nothing " + did};
    case Stop::NoInput: return {false, head + "pane has no live input; nothing " + did};
    default: break;
    }
    const auto num = [](unsigned long x) { return std::to_string(x); };
    const unsigned long rest = r.total - r.written - r.chunk - r.closed;
    std::string m = head + num(r.written) + " of " + num(r.total) + " bytes written";
    if (r.stop == Stop::TimedOut && !r.chunk)
        m += " before the " + num(kDeadlineMs / 1000) + " s input deadline";
    else if (r.stop == Stop::Pending)
        m += "; the " + num(r.chunk) + "-byte chunk at offset " + num(r.written) + " is still in flight and may still arrive";
    else
        m += "; the " + num(r.chunk) + "-byte chunk at offset " + num(r.written) +
             (r.stop == Stop::TimedOut ? " was cancelled at the " + num(kDeadlineMs / 1000) + " s input deadline" : " failed") +
             " and may have been partly delivered";
    m += "; the remaining " + num(rest) + " bytes were not written";
    switch (r.bracket) {
    case Bracket::None: break;
    case Bracket::Unknown: m += "; whether the bracketed paste was opened is unknown, so no ESC[201~ was sent"; break;
    case Bracket::LeftOpen: m += "; the bracketed paste is left open (no ESC[201~ sent)"; break;
    case Bracket::NoTime: m += "; the bracketed paste is left open: no time left to send ESC[201~"; break;
    case Bracket::Closed: m += "; the bracketed paste was then closed with a separate ESC[201~"; break;
    case Bracket::CloseStopped: m += "; that chunk was the closing ESC[201~, so the bracketed paste may be left open"; break;
    case Bracket::CloseFailed: m += "; a separate ESC[201~ to close the bracketed paste failed and may have been partly delivered"; break;
    case Bracket::ClosePending: m += r.closed ? "; a separate ESC[201~ to close the bracketed paste is still in flight and may still arrive"
                                              : "; that chunk is the closing ESC[201~"; break;
    }
    if (r.pending) m += "; this pane's input stays reserved until that write resolves";
    return {false, m};
}
}
