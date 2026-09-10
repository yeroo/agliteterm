#include <string>
#include <vector>
#include <cstdint>
#include <cstdio>
struct Session {};
struct HostSession { std::string id, creationTicket; };
struct Spec { std::string app, cwd; std::vector<std::string> args; };
static std::vector<HostSession> g_hostLive;
static std::string received, current;
static Session live;
static Session* attachSession(const char*, int, int, const char*, const std::vector<std::string>*,
                              const char*, bool repaint, bool hidden, uint64_t, const char* expected = "") {
    received = expected;
    return repaint && !hidden && (received.empty() || received == current) ? &live : nullptr;
}
static Session* adopt() {
    const std::string want = "pane"; const Spec sp{}; const int cols = 80, rows = 24;
    Session* s = nullptr;
    // ACTUAL_ADOPTION_CALL
    return s;
}
int main() {
    int failed = 0;
    g_hostLive = {{ "unrelated", "other" }, { "pane", "old-incarnation" }};
    current = "replacement-incarnation";
    if (adopt() != nullptr || received != "old-incarnation") ++failed;
    current = "old-incarnation";
    if (adopt() != &live || received != "old-incarnation") ++failed;
    g_hostLive[1].creationTicket.clear();
    if (adopt() != &live || !received.empty()) ++failed;
    std::printf("adoption: 3 actual list-to-attach wiring checks, %d failed; fake host only\n", failed);
    return failed ? 1 : 0;
}
