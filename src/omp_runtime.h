#include "omp_protocol.h"

struct OmpOperation {
    omp_protocol::State state;
    std::string nonce, path, bridge, result;
    std::shared_ptr<AgentHandle> shell;
    uint64_t configGeneration = 0;
    bool persist = false;
    explicit OmpOperation(uint64_t deadline) : state(deadline) {}
};
static std::string ompNonce() {
    GUID guid{}; if (CoCreateGuid(&guid) != S_OK) return {};
    wchar_t text[40]{}; StringFromGUID2(guid, text, 40);
    return narrow(std::wstring(text + 1, 36));
}
static bool ompPaneEligible(Session* pane, const OmpOperation& op) {
    return indexOfSession(pane) >= 0 && !pane->exited && !pane->readOnly && !pane->adopted && !isCoverLocked(pane) &&
        pane->data != INVALID_HANDLE_VALUE && pane->agentBridgeToken == op.bridge &&
        pane->childPid == op.shell->pid && pane->childCreated == op.shell->born && op.shell->live();
}
static std::string ompQueueOnUi(const JsonReq& req) {
    LockG hold;
    auto* pane = resolveTarget(req.get("target"), nullptr);
    if (!pane || pane->paneId != req.get("target") || !pane->ompReady || pane->adopted || isCoverLocked(pane) ||
        pane->readOnly || pane->exited || pane->data == INVALID_HANDLE_VALUE || !isPwshApp(pane->app.c_str()))
        return ctlErr("omp: requires live writable, non-adopted PowerShell with supported idle integration; nothing applied or saved");
    FfiEmuInfo info{};
    if (!pane->emu || !emu_info(pane->emu, &info) || info.isAltScreen)
        return ctlErr("omp: shell readiness is unknown; nothing applied or saved");
    if (pane->ompOperation) pane->ompOperation->state.expire(GetTickCount64());
    if (pane->ompOperation && pane->ompOperation->state.active())
        return ctlErr("omp: previous request is pending or outcome unknown; not replayed");
    auto op = std::make_shared<OmpOperation>(GetTickCount64() + 4000);
    op->shell = agentHandle(pane->childPid);
    if (!op->shell || !pane->childCreated || op->shell->born != pane->childCreated)
        return ctlErr("omp: shell identity changed; nothing applied or saved");
    op->nonce = req.get("args.omp-nonce");
    if (!agent_integration::uuid(op->nonce)) return ctlErr("omp: missing request identity");
    op->bridge = pane->agentBridgeToken; op->path = req.get("args.resolved-theme");
    op->persist = req.get("args.persist") == "true";
    { std::lock_guard<std::mutex> guard(g_ompMutex); op->configGeneration = g_ompGeneration; }
    pane->ompOperation = op;
    return ctlOkStr(op->nonce);
}
static std::string ompAwait(const JsonReq& req, const std::string& queued) {
    if (queued.find("\"ok\":true") == std::string::npos) return queued;
    std::shared_ptr<OmpOperation> op;
    { LockG hold; auto* pane = resolveTarget(req.get("target"), nullptr);
      if (pane) op = pane->ompOperation; }
    if (!op || op->nonce != req.get("args.omp-nonce")) return ctlErr("omp: target changed; outcome unknown; read back before retrying");
    for (;;) {
        { LockG hold;
          op->state.expire(GetTickCount64());
          if (!op->result.empty()) return op->result;
          if (op->state.phase == omp_protocol::Phase::Expired)
              return ctlErr("omp: empty editing buffer was not acknowledged before deadline; nothing applied or saved");
          if (op->state.phase == omp_protocol::Phase::Unknown)
              return ctlErr("omp: authorization claimed but result missing; outcome unknown, nothing saved; do not retry automatically"); }
        Sleep(20); // pipe worker, never the UI thread or a holder of g_lock
    }
}
static bool ompNoChildren(DWORD pid) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W entry{}; entry.dwSize = sizeof entry;
    bool clear = Process32FirstW(snapshot, &entry) != FALSE;
    if (clear) {
        do { if (entry.th32ParentProcessID == pid) { clear = false; break; } }
        while (Process32NextW(snapshot, &entry));
        if (clear && GetLastError() != ERROR_NO_MORE_FILES) clear = false;
    }
    CloseHandle(snapshot); return clear;
}
static std::string ompBridge(const JsonReq& req, Session* pane) {
    LockG hold;
    if (indexOfSession(pane) < 0 || pane->exited || pane->agentBridgeToken != req.get("args.token"))
        return ctlErr("omp: bridge target changed");
    const auto action = req.get("args.op");
    if (action == "omp-ready") {
        const bool wasReady = pane->ompReady;
        pane->ompReady = req.get("args.reader") == "psreadline-idle-v1";
        if (pane->ompReady && !wasReady) emitEvent("omp.ready", pane->paneId, "psreadline-idle-v1");
        return ctlOkStr("");
    }
    auto op = pane->ompOperation;
    if (!op) return ctlOkStr("");
    if (action == "omp-claim") {
        const bool eligible = ompPaneEligible(pane, *op) &&
            req.get("args.console-pids") == std::to_string(op->shell->pid) && ompNoChildren(op->shell->pid);
        if (!op->state.claim(GetTickCount64(), eligible)) return ctlOkStr("");
        // Environment.TickCount64 in the shell shares this monotonic Windows boot clock.
        return ctlOkStr("{\"lease\":\""+op->nonce+"\",\"path\":\""+jsonEscape(op->path)+"\",\"deadline\":\""+std::to_string(op->state.deadline)+"\"}");
    }
    if (action != "omp-result" || req.get("args.lease") != op->nonce ||
        (req.get("args.success") != "true" && req.get("args.success") != "false")) return ctlErr("omp: stale or invalid result");
    if (!op->result.empty()) return ctlOkStr("result already recorded");
    const bool eligible = ompPaneEligible(pane, *op);
    if (!op->state.result(GetTickCount64(), req.get("args.success") == "true", eligible)) return ctlErr("omp: no claimed authorization");
    if (op->state.phase == omp_protocol::Phase::Applied) {
        const bool saved = op->persist && op->state.persistAllowed && saveOmpTheme(op->path, op->configGeneration);
        if (op->persist && !saved) op->result = ctlErr("omp: shell applied theme, but persistence refused or failed (deadline, pane policy or newer configuration); nothing saved");
        else op->result = ctlOkStr("oh-my-posh theme applied" + std::string(saved ? "; saved for eligible new shells" : "; not persisted"));
    } else {
        auto stage = req.get("args.stage");
        if (stage != "idle" && stage != "tool" && stage != "native" && stage != "before-apply" && stage != "apply" && stage != "wrap") stage = "unknown";
        op->result = ctlErr("omp: shell initialization failed at " + stage + "; partial shell changes are possible; nothing saved");
    }
    emitEvent("omp.theme", pane->paneId, op->result);
    return ctlOkStr("result recorded");
}
