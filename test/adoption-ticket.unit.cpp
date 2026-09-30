#include <string>
#include <vector>
#include <cstdint>
#include <cstdio>
struct Session {};
struct HostSession { std::string id, creationTicket; };
struct Spec { std::string app, cwd; std::vector<std::string> args; bool exactArgs = false; };
static std::vector<HostSession> g_hostLive;
static std::string received, current;
static Session live;
static bool profileSeen = false, exactSeen = false;
// Production asks the catalog; here a spec is a profile shell exactly when it is not exact.
static bool profileShellSpec(bool exact, const char*, const std::vector<std::string>*) { return !exact; }
static Session* attachSession(const char*, int, int, const char*, const std::vector<std::string>*,
                              const char*, bool repaint, bool hidden, uint64_t, const char* expected = "", bool exactArgs = false,
                              bool profileShell = false) {
    received = expected; exactSeen = exactArgs; profileSeen = profileShell;
    return repaint && !hidden && (received.empty() || received == current) ? &live : nullptr;
}
static Session* adopt(const Spec& sp = Spec{}) {
    const std::string want = "pane"; const int cols = 80, rows = 24;
    // The two locals production computes just above the lifted call (restoreSessions).
    const bool exact = sp.exactArgs || !sp.args.empty();
    const char* const specApp = sp.app.empty() ? "powershell.exe" : sp.app.c_str();
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
    // lite #116: the adopted session carries the exactness of its saved spec, and with it whether
    // it is a profile shell (an argv alone makes a spec exact - the E line is saved only for an
    // empty one).
    if (adopt() != &live || exactSeen || !profileSeen) ++failed;
    Spec command; command.app = "powershell.exe"; command.args = { "-NoExit", "-Command", "echo x" };
    if (adopt(command) != &live || !exactSeen || profileSeen) ++failed;
    Spec flagged; flagged.app = "cmd.exe"; flagged.exactArgs = true;
    if (adopt(flagged) != &live || !exactSeen || profileSeen) ++failed;
    std::printf("adoption: 6 actual list-to-attach wiring checks, %d failed; fake host only\n", failed);
    return failed ? 1 : 0;
}
