#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vector>
#include "ui_ownership.h"
#include "workspace_identity.h"
using LPARAM = intptr_t;
struct Session {};
static int held=0;
struct LockG { LockG(){++held;} ~LockG(){--held;} };
static std::vector<Session*> g_sessions;
static WorkspaceNames g_workspaces{L"one",L"two"};
static int indexOfSession(Session* s) {
    auto found=std::find(g_sessions.begin(),g_sessions.end(),s);
    return found==g_sessions.end()?-1:(int)(found-g_sessions.begin());
}
// ACTUAL_TREE_IDENTITY_HELPERS
int main() {
    int checks=0,failed=0;
    auto check=[&](bool ok){++checks;if(!ok)++failed;};
    for(const std::string cmd: {"tree","session.new","session.close","session.duplicate","session.select",
        "session.split","session.flag","session.rename","session.context","session.readonly","selection.copy",
        "workspace.select","workspace.delete","workspace.move","sidebar","sidebar.width","font","font.inc","quick"})
        check(ui_ownership::dispatchToUi(cmd));
    for(const std::string cmd: {"ping","events","session.type","session.paste","session.write",
        "session.text","session.output","session.copy","surface.cursor","agent.bridge"})
        check(!ui_ownership::dispatchToUi(cmd));
    Session a,b,c;g_sessions={&a,&b};
    LPARAM old=reinterpret_cast<LPARAM>(&b);
    check(treeSessionIndex(old)==1);
    g_sessions.insert(g_sessions.begin(),&c);check(treeSessionIndex(old)==2);
    g_sessions.erase(g_sessions.begin()+2);check(treeSessionIndex(old)==-1);
    g_sessions.push_back(&a);check(treeSessionIndex(old)==-1);
    check(treeSessionIndex(0)==-1);check(treeSessionIndex(-1)==-1);
    auto second=treeWorkspaceParam(1);check(treeWorkspaceIndex(second)==1);
    g_workspaces.move(1,0);check(treeWorkspaceIndex(second)==0);
    g_workspaces.erase(g_workspaces.begin());check(treeWorkspaceIndex(second)==-1);
    g_workspaces.push_back(L"replacement");check(treeWorkspaceIndex(second)==-1);
    check(treeWorkspaceIndex(0)==-1);check(treeWorkspaceIndex(INTPTR_MIN)==-1);
    check(treeWorkspaceParam(-1)==0);check(treeWorkspaceParam(999)==0);check(held==0);
    std::printf("UI ownership: %d private routing/actual identity checks, %d failed\n",checks,failed);
    return failed?1:0;
}
