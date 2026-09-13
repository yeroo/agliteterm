#include <cstdio>
#include <string>
#include <utility>
#include <vector>

struct Session {
    std::string id;
    std::string splitId;
    bool hidden = false;
};

static std::vector<Session*> g_sessions;
static int g_pane[2] = {0, -1};
static int g_focus = 0;
static int checks = 0;
static int failed = 0;

static int indexOfSessionId(const std::string& id) {
    if (id.empty()) return -1;
    for (int index = 0; index < (int)g_sessions.size(); index++)
        if (g_sessions[index]->id == id) return index;
    return -1;
}

static void setFocusedPane(int paneIndex) { g_focus = paneIndex; }

ACTUAL_SPLIT_RESOLVER

ACTUAL_CLOSE_PANE_REMAP

static void check(bool condition, const char* scenario, const char* property) {
    ++checks;
    if (!condition) {
        ++failed;
        std::printf("FAIL %s: %s (primary=%d, split=%d, focus=%d)\n", scenario, property,
                    g_pane[0], g_pane[1], g_focus);
    }
}

static void closeCase(const char* name, std::vector<Session*> sessions,
                      int primary, int companion, int focus, int closedIndex,
                      int expectedPrimary, int expectedCompanion, int expectedFocus) {
    g_sessions = std::move(sessions);
    g_pane[0] = primary;
    g_pane[1] = companion;
    g_focus = focus;
    g_sessions.erase(g_sessions.begin() + closedIndex);
    remapPanesAfterClose(closedIndex);
    check(g_pane[0] == expectedPrimary, name, "primary selection");
    check(g_pane[1] == expectedCompanion, name, "split selection");
    check(g_focus == expectedFocus, name, "focus");
    check(g_pane[0] < 0 || !g_sessions[g_pane[0]]->hidden, name, "primary must not be hidden");
}

int main() {
    Session owner{"workbench", "codex"};
    Session companion{"codex", "", true};
    Session temporary{"temporary", ""};
    Session popup{"popup", "", true};
    Session overlay{"overlay", "", true};
    Session first{"first", ""};
    Session next{"next", ""};

    closeCase("temporary after split", {&owner, &companion, &temporary}, 2, -1, 0, 2, 0, 1, 0);
    check(owner.splitId == "codex", "temporary after split", "owner link preserved");
    closeCase("multiple hidden predecessors", {&owner, &companion, &overlay, &temporary}, 3, -1, 0, 3, 0, 1, 0);
    closeCase("hidden predecessor before split", {&popup, &temporary, &owner, &companion}, 1, -1, 0, 1, 1, 2, 0);
    closeCase("hidden predecessor before single", {&popup, &temporary, &next}, 1, -1, 0, 1, 1, -1, 0);
    closeCase("temporary before split", {&temporary, &owner, &companion}, 0, -1, 0, 0, 0, 1, 0);
    closeCase("unrelated close before split", {&temporary, &owner, &companion}, 1, 2, 1, 0, 0, 1, 1);
    closeCase("unrelated close after split", {&owner, &companion, &temporary}, 0, 1, 1, 2, 0, 1, 1);
    closeCase("nearest visible predecessor", {&first, &temporary, &next}, 1, -1, 0, 1, 0, -1, 0);
    closeCase("only hidden predecessor remains", {&popup, &temporary}, 1, -1, 0, 1, -1, -1, 0);
    closeCase("only hidden successor remains", {&temporary, &popup}, 0, -1, 0, 0, -1, -1, 0);
    closeCase("last session closes", {&temporary}, 0, -1, 0, 0, -1, -1, 0);
    closeCase("split shell closes", {&owner, &companion}, 0, 1, 1, 1, 0, -1, 0);
    check(owner.splitId.empty(), "split shell closes", "dead companion link cleared");

    std::printf("Pane selection: %d production-code checks, %d failed\n", checks, failed);
    return failed ? 1 : 0;
}
