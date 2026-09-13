// agliteterm #82: a reader's end-of-stream is the shell EXITING only when the host says so.
//
// creation-protocol.unit.ps1 replaces the two markers below with the production `struct HostSession`
// and `hostListSaysAlive` extracted from src/main.cpp, so these checks run against the real rule and a
// renamed field or a changed rule fails here rather than silently. Only that decision is pure; the
// reader thread's call to the host is exercised end to end by control-honesty's split-exit check and
// wave3's quick-EOF check, which type `exit` - a real child exit - and must still collapse and close.
#include <cstdio>
#include <string>
#include <vector>

// ACTUAL_HOST_SESSION_STRUCT

// ACTUAL_HOST_LIST_SAYS_ALIVE

static int checks = 0;
static int failed = 0;

static void check(bool ok, const char* what) {
    ++checks;
    if (!ok) {
        ++failed;
        std::printf("FAIL %s\n", what);
    }
}

int main() {
    const std::string pane = "lite-7";
    const std::string ticket = "t-aaaa";

    // The cases that must stay an exit: today's behaviour, unchanged.
    std::vector<HostSession> none;
    check(!hostListSaysAlive(none, pane, ticket),
          "an empty list (host holds nothing, or could not be read) is not alive: EOF stays an exit");

    std::vector<HostSession> exited{ { pane, true, false, ticket } };
    check(!hostListSaysAlive(exited, pane, ticket),
          "listed and exited is not alive: a real exit still marks exited and collapses a split");

    std::vector<HostSession> other{ { "lite-8", false, false, ticket } };
    check(!hostListSaysAlive(other, pane, ticket),
          "a different pane that is running says nothing about this one");

    std::vector<HostSession> reused{ { pane, false, false, "t-bbbb" } };
    check(!hostListSaysAlive(reused, pane, ticket),
          "the same pane id under a NEWER incarnation is not ours: a reused id does not keep us alive");

    // The cases #82 is about: the stream ended while the shell kept running.
    std::vector<HostSession> superseded{ { pane, false, true, ticket } };
    check(hostListSaysAlive(superseded, pane, ticket),
          "listed, running and attached to another client is alive: a supersede is not an exit");

    std::vector<HostSession> detached{ { pane, false, false, ticket } };
    check(hostListSaysAlive(detached, pane, ticket),
          "listed, running and detached is alive: a dropped data pipe is not an exit");

    std::vector<HostSession> legacy{ { pane, false, false, "" } };
    check(hostListSaysAlive(legacy, pane, ""),
          "a session created before creation tickets matches by pane id alone");

    std::vector<HostSession> both{ { pane, true, false, "t-old" }, { pane, false, false, ticket } };
    check(hostListSaysAlive(both, pane, ticket),
          "an exited older incarnation listed first does not hide our running one");

    std::printf("Stream end: %d production-code checks, %d failed\n", checks, failed);
    return failed ? 1 : 0;
}
