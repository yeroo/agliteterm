#include "agent_integration.h"

struct AgentHandle {
    HANDLE handle = nullptr;
    DWORD pid = 0;
    ULONGLONG born = 0;
    ~AgentHandle() { if (handle) CloseHandle(handle); }
    bool live() const { return handle && WaitForSingleObject(handle, 0) == WAIT_TIMEOUT; }
};
static std::shared_ptr<AgentHandle> agentHandle(DWORD pid, bool memory = false) {
    auto out = std::make_shared<AgentHandle>(); out->pid = pid;
    out->handle = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | (memory ? PROCESS_VM_READ : 0), FALSE, pid);
    FILETIME born{}, exit{}, kernel{}, user{};
    if (!out->handle || !GetProcessTimes(out->handle, &born, &exit, &kernel, &user) || !out->live()) return {};
    out->born = (static_cast<ULONGLONG>(born.dwHighDateTime) << 32) | born.dwLowDateTime;
    return out;
}
struct AgentEvidence {
    Session* pane = nullptr;
    std::string paneId, binding, bridge, image;
    std::shared_ptr<AgentHandle> shell, process;
    std::vector<std::shared_ptr<AgentHandle>> descendants;
    std::vector<std::string> argv;
    agent_integration::Identity identity;
};
static bool agentEvidence(Session* pane, AgentEvidence& out, std::string& why) {
    DWORD pid; ULONGLONG born;
    {
        LockG hold;
        if (!pane || indexOfSession(pane) < 0 || pane->exited || isCoverLocked(pane)) { why = "requires a live shell pane"; return false; }
        out.pane = pane; out.paneId = pane->paneId; out.binding = pane->agentResume; out.bridge = pane->agentBridgeToken;
        pid = pane->childPid; born = pane->childCreated;
    }
    out.shell = agentHandle(pid);
    if (!born || !out.shell || out.shell->born != born) { why = "shell process identity is unknown or changed"; return false; }
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) { why = "process snapshot unavailable"; return false; }
    std::map<DWORD,DWORD> parents;
    PROCESSENTRY32W entry{}; entry.dwSize = sizeof entry;
    BOOL found = Process32FirstW(snapshot, &entry);
    if (!found) { CloseHandle(snapshot); why = "process snapshot unreadable"; return false; }
    do { parents[entry.th32ProcessID] = entry.th32ParentProcessID; } while (Process32NextW(snapshot, &entry));
    auto error = GetLastError(); CloseHandle(snapshot);
    if (error != ERROR_NO_MORE_FILES) { why = "process enumeration incomplete"; return false; }
    std::map<DWORD,std::shared_ptr<AgentHandle>> handles{{pid,out.shell}};
    for (const auto& item : parents) {
        if (item.first == pid) continue;
        std::vector<DWORD> chain; DWORD cursor = item.first;
        for (int depth = 0; cursor && cursor != pid && depth < 64; ++depth) {
            chain.push_back(cursor); const auto p = parents.find(cursor);
            if (p == parents.end() || p->second == cursor) { cursor = 0; break; }
            cursor = p->second;
        }
        if (cursor != pid) continue;
        if (handles.size() + chain.size() > 256) { why = "too many descendants to prove ownership"; return false; }
        ULONGLONG parentBorn = out.shell->born;
        for (auto p = chain.rbegin(); p != chain.rend(); ++p) {
            auto& handle = handles[*p]; if (!handle) handle = agentHandle(*p, true);
            if (!handle || handle->born < parentBorn) { why = "descendant exited, inaccessible or PID reused during snapshot"; return false; }
            parentBorn = handle->born;
        }
    }
    for (const auto& item : handles) {
        if (item.first == pid) continue;
        out.descendants.push_back(item.second);
        wchar_t image[32768]{}; DWORD size = static_cast<DWORD>(std::size(image)); std::wstring command;
        if (!QueryFullProcessImageNameW(item.second->handle, 0, image, &size)) { why = "descendant image unavailable"; return false; }
        const auto base = agent_integration::basename(narrow(image));
        if (base != "claude.exe" && base != "node.exe") continue;
        if (!pebParamString(item.second->handle, 0x70, &command)) { why = "agent command line unavailable"; return false; }
        int count = 0; auto* words = CommandLineToArgvW(command.c_str(), &count);
        if (!words) { why = "agent command line cannot be parsed"; return false; }
        std::vector<std::string> argv; for (int i = 0; i < count; ++i) argv.push_back(narrow(words[i])); LocalFree(words);
        agent_integration::Identity identity;
        if (!agent_integration::identify(narrow(image), argv, identity)) continue;
        if (out.process) { why = "multiple Claude descendants; conversation is ambiguous"; return false; }
        out.process = item.second; out.argv = std::move(argv); out.identity = identity; out.image = narrow(image);
    }
    if (!out.process) { why = "no verified Claude process with one explicit conversation UUID; no transcript guessed"; return false; }
    for (const auto& item : handles) {
        if (item.first == pid) continue;
        auto reaches = [&](DWORD child, DWORD ancestor) {
            for (int i = 0; child && i < 64; ++i) {
                if (child == ancestor) return true;
                auto parent = parents.find(child); if (parent == parents.end() || parent->second == child) return false;
                child = parent->second;
            }
            return false;
        };
        if (!reaches(item.first, out.process->pid) && !reaches(out.process->pid, item.first)) {
            why = "unrelated foreground/background descendants; interruption would be ambiguous"; return false;
        }
    }
    if (!out.process->live() || !out.shell->live()) { why = "process exited during identity check"; return false; }
    return true;
}
static std::string agentResume(const AgentEvidence& evidence, bool yolo) {
    std::string command = "& " + shell_configuration::literal(evidence.image);
    for (size_t i = 1; i < evidence.identity.executableArgs; ++i) command += " " + shell_configuration::literal(evidence.argv[i]);
    for (const auto& arg : agent_integration::resumeArgs(evidence.argv, evidence.identity, yolo)) command += " " + shell_configuration::literal(arg);
    return command;
}
struct AgentOperation {
    AgentEvidence evidence;
    std::string command;
    unsigned long long lease = 0;
    std::atomic<bool> claimed{false};
    bool interrupting = false, offered = false, acknowledged = false; // under g_agentMutex
    ULONGLONG started = GetTickCount64();
    ~AgentOperation() { if (lease) evidence.pane->inputGate.release(lease); }
};
static std::mutex g_agentMutex;
static std::map<std::string,std::shared_ptr<AgentOperation>> g_agentOperations;
static bool agentStillEligible(const AgentOperation& op) {
    LockG hold; const auto* pane = op.evidence.pane;
    return indexOfSession(pane) >= 0 && !pane->exited && !pane->readOnly && !pane->overlay &&
        pane->paneId == op.evidence.paneId && pane->agentResume == op.evidence.binding &&
        pane->agentBridgeToken == op.evidence.bridge && op.evidence.shell->live() && IsWindowEnabled(g_hwnd);
}
static DWORD WINAPI agentInterruptWorker(void* opaque) {
    std::unique_ptr<std::shared_ptr<AgentOperation>> payload(static_cast<std::shared_ptr<AgentOperation>*>(opaque));
    auto op = *payload; std::string result = "timed out; no resume dispatched";
    bool first = false, second = false;
    while (GetTickCount64() - op->started < 30000) {
        bool interrupt = false;
        // Serialize claim/cancellation with Ctrl+C so a second interrupt cannot hit the new agent.
        {
            std::lock_guard<std::mutex> guard(g_agentMutex);
            if (op->claimed) return 0;
            if (!agentStillEligible(*op)) { result = "pane state changed; no resume dispatched"; break; }
            if (!op->offered && (!first || (!second && GetTickCount64() - op->started >= 350)) && op->evidence.process->live())
                op->interrupting = interrupt = true;
        }
        if (interrupt) {
            const auto written = ovIo(op->evidence.pane->data, true, "\x03", nullptr, 1, true, false, nullptr, op->lease, 1000);
            std::lock_guard<std::mutex> guard(g_agentMutex);
            op->interrupting = false;
            if (written != 1) { result = "interrupt write failed or timed out; no resume dispatched"; break; }
            if (first) second = true; else first = true;
        }
        Sleep(50);
    }
    {
        std::lock_guard<std::mutex> guard(g_agentMutex);
        if (op->claimed) return 0;
        if (op->acknowledged) result = "resume authorization issued; prompt receipt/startup unconfirmed";
        auto found = g_agentOperations.find(op->evidence.paneId);
        if (found != g_agentOperations.end() && found->second == op) g_agentOperations.erase(found);
    }
    op->evidence.pane->inputGate.release(op->lease);
    emitEvent("agent.restart", op->evidence.paneId, result); logWarn("agent restart: %s", result.c_str());
    return 0;
}
static std::string agentQueueRestart(AgentEvidence evidence, bool yolo) {
    auto op = std::make_shared<AgentOperation>(); op->evidence = std::move(evidence); op->command = agentResume(op->evidence, yolo);
    const auto simple = "claude --resume " + op->evidence.identity.conversation +
        (op->evidence.identity.dangerous ? " --dangerously-skip-permissions" : "");
    if (!op->evidence.binding.empty() && op->evidence.binding != simple && op->evidence.binding != agentResume(op->evidence, false))
        return ctlErr("custom binding differs from verified process arguments; preserved, nothing interrupted");
    if (op->evidence.bridge.empty()) return ctlErr("no prompt bridge in this shell; restart the shell or load bundled agliteterm-prompt.ps1 explicitly; nothing interrupted");
    std::lock_guard<std::mutex> guard(g_agentMutex);
    if (g_agentOperations.count(op->evidence.paneId)) return ctlErr("agent restart already pending");
    if (!agentStillEligible(*op)) return ctlErr("agent pane changed, is read-only, covered or modal; nothing interrupted");
    op->lease = op->evidence.pane->inputGate.reserve();
    if (!op->lease) return ctlErr("pane input is already reserved; nothing interrupted");
    g_agentOperations[op->evidence.paneId] = op;
    auto* payload = new std::shared_ptr<AgentOperation>(op);
    HANDLE worker = CreateThread(nullptr, 0, agentInterruptWorker, payload, 0, nullptr);
    if (!worker) { delete payload; g_agentOperations.erase(op->evidence.paneId); return ctlErr("restart worker could not start; nothing interrupted"); }
    CloseHandle(worker);
    return ctlOkStr("agent restart queued for " + op->evidence.paneId + "; completion is reported by agent.restart events");
}
static std::string agentBridge(const JsonReq& req) {
    const auto& token = req.get("args.token");
    if (!agent_integration::uuid(token)) return ctlErr("invalid bridge capability");
    Session* pane;
    {
        LockG hold; pane = resolveTarget(req.get("target"), nullptr);
        if (!pane || pane->paneId != req.get("target") || pane->exited ||
            req.get("args.pid") != std::to_string(pane->childPid) || !isPwshApp(pane->app.c_str())) return ctlErr("bridge shell identity mismatch");
        if (req.get("args.op") == "register") {
            if (!pane->agentBridgeToken.empty() && pane->agentBridgeToken != token) return ctlErr("bridge already registered");
            pane->agentBridgeToken = token; return ctlOkStr("");
        }
        if (pane->agentBridgeToken != token) return ctlErr("bridge capability mismatch");
    }
    const auto action = req.get("args.op");
    if (action != "claim" && action != "ack" && action != "received") return ctlErr("unknown bridge operation");
    std::shared_ptr<AgentOperation> op;
    {
        std::lock_guard<std::mutex> guard(g_agentMutex);
        const auto found = g_agentOperations.find(pane->paneId);
        if (found == g_agentOperations.end()) return ctlOkStr("");
        op = found->second;
        if (action != "claim" && req.get("args.lease") != std::to_string(op->lease)) return ctlErr("stale bridge offer");
        if (action == "received") {
            if (!op->acknowledged) return ctlErr("bridge offer was not acknowledged");
            op->claimed = true; g_agentOperations.erase(found);
            { LockG hold; pane->agentResume = op->command; }
        } else {
        if (req.get("args.console-pids") != std::to_string(op->evidence.shell->pid))
            return ctlErr("prompt has not proved sole console ownership; no resume dispatched");
        if (!agentStillEligible(*op) || GetTickCount64() - op->started >= 30000) return ctlErr("restart no longer eligible");
        if (op->interrupting) return ctlErr("interrupt still in flight; retry claim");
        for (const auto& child : op->evidence.descendants) if (WaitForSingleObject(child->handle, 0) != WAIT_OBJECT_0)
            return ctlErr("agent descendants have not all exited; no resume dispatched");
        // Catch descendants started after the original snapshot. At a prompt there must be no
        // surviving child of this retained shell; uncertainty is a refusal, never a fixed delay.
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == INVALID_HANDLE_VALUE) return ctlErr("exit verification snapshot failed");
        PROCESSENTRY32W entry{}; entry.dwSize = sizeof entry;
        bool clear = Process32FirstW(snapshot, &entry) != FALSE;
        if (clear) {
            do { if (entry.th32ParentProcessID == op->evidence.shell->pid) { clear = false; break; } }
            while (Process32NextW(snapshot, &entry));
            if (clear && GetLastError() != ERROR_NO_MORE_FILES) clear = false;
        }
        CloseHandle(snapshot);
        if (!clear) return ctlErr("shell has children or enumeration is incomplete; no resume dispatched");
        // Offers and acknowledgements are idempotent. No disk I/O or destructive consumption
        // precedes their replies; a lost reply can be retried against the same lease.
        if (action == "ack" && !op->offered) return ctlErr("bridge offer missing");
        op->offered = true;
        if (action == "ack") op->acknowledged = true;
        FILETIME now{}; GetSystemTimeAsFileTime(&now);
        const auto wall = (static_cast<ULONGLONG>(now.dwHighDateTime)<<32)|now.dwLowDateTime;
        const auto elapsed = GetTickCount64() - op->started;
        const auto deadline = wall + (elapsed < 30000 ? 30000-elapsed : 0)*10000;
        return ctlOkStr("{\"lease\":\"" + std::to_string(op->lease) + "\",\"deadline\":\"" + std::to_string(deadline) +
                        "\",\"command\":\"" + jsonEscape(op->command) + "\"}");
        }
    }
    op->evidence.pane->inputGate.release(op->lease);
    emitEvent("agent.restart", pane->paneId, "prompt acknowledged resume authorization; agent startup not confirmed");
    if (!saveSessionState()) emitEvent("agent.restart",pane->paneId,"resume binding persistence failed");
    return ctlOkStr("receipt recorded");
}
struct AgentUpdateOperation {
    std::vector<AgentEvidence> agents;
    Session* overlay = nullptr;
    std::wstring receipt;
    std::string nonce;
};
static std::atomic<bool> g_agentUpdateBusy{false};
static std::string agentUpdateOnUi(const JsonReq& req) {
    if (req.get("args.close") == "true") {
        Session* owner = nullptr;
        { LockG hold;
          for (auto* pane : g_sessions) if (pane->overlay && pane->overlay->paneId == req.get("target") && overlayExitOf(pane->overlay) == "exit 0") { owner = pane; break; } }
        return owner && closePaneOverlay(owner) ? ctlOkStr("closed completed owned update overlay") : ctlErr("update overlay changed; no restart authorized");
    }
    Session* shell;
    { LockG hold; shell = resolveTarget(req.get("target"), nullptr);
      if (!shell || shell->paneId != req.get("target") || shell->exited) return ctlErr("update target disappeared"); }
    const auto& script = req.get("args.script");
    if (overlayCommandLine(script).size() >= 2048) return ctlErr("update command exceeds host limit; nothing opened");
    std::string why; auto* overlay = openPaneOverlay(shell, script, &why);
    return overlay ? ctlOkStr(overlay->paneId) : ctlErr(why);
}
static DWORD WINAPI agentUpdateWorker(void* opaque) {
    std::unique_ptr<AgentUpdateOperation> op(static_cast<AgentUpdateOperation*>(opaque));
    std::string result = "update timed out; no agents restarted; overlay retained for inspection";
    bool expired = true;
    const auto start = GetTickCount64();
    while (GetTickCount64() - start < 300000) {
        std::string exit;
        { LockG hold;
          if (indexOfSession(op->overlay) < 0 || op->overlay->exited) { expired = false; result = "update overlay closed; no agents restarted"; break; }
          exit = overlayExitOf(op->overlay); }
        if (!exit.empty()) {
            expired = false;
            result = "update failed or did not install a newer version; no agents restarted";
            if (exit != "exit 0") break;
            HANDLE file = CreateFileW(op->receipt.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
            if (file == INVALID_HANDLE_VALUE) break;
            LARGE_INTEGER size{}; std::string bytes; DWORD read = 0;
            bool valid = GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart < 4096;
            if (valid) { bytes.resize(static_cast<size_t>(size.QuadPart)); valid = ReadFile(file, &bytes[0], static_cast<DWORD>(bytes.size()), &read, nullptr) && read == bytes.size(); }
            CloseHandle(file);
            JsonReq receipt; size_t pos = 0;
            if (!valid || !jsonParseObject(bytes, pos, "", receipt) || pos != bytes.size() ||
                receipt.get("nonce") != op->nonce || receipt.get("updated") != "true") break;
            JsonReq close; close.fields = {{"cmd","agent.update.open"},{"target",op->overlay->paneId},{"args.close","true"}};
            const auto closed = dispatchConfig(close);
            if (closed.find("\"ok\":true") == std::string::npos) { result = "updated, but owned overlay could not be closed; no agents restarted"; break; }
            result = "new version installed; restart requests:";
            for (auto& agent : op->agents) {
                const auto paneId = agent.paneId;
                result += "\n" + paneId + ": " + agentQueueRestart(std::move(agent), false);
            }
            break;
        }
        Sleep(100);
    }
    emitEvent("agent.update", op->overlay->paneId, result); logInfo("agent update: %s", result.c_str());
    // Expiration stops restart supervision, not the updater itself. Keep exclusion until the
    // owned overlay command has actually ended; this passive tail never schedules a restart.
    for (;;) {
        bool ended;
        { LockG hold; ended = indexOfSession(op->overlay) < 0 || op->overlay->exited || !overlayExitOf(op->overlay).empty(); }
        if (ended) break;
        Sleep(250);
    }
    // The uniquely created receipt is retained as diagnostic evidence, not mistaken for a release asset.
    g_agentUpdateBusy = false;
    if (expired) emitEvent("agent.update",op->overlay->paneId,"expired updater ended; exclusion released; no late restarts");
    return 0;
}
static std::string agentUpdate(const JsonReq& req) {
    bool expected = false;
    if (!g_agentUpdateBusy.compare_exchange_strong(expected, true)) return ctlErr("Claude update already running");
    struct Reset { bool armed = true; ~Reset() { if (armed) g_agentUpdateBusy = false; } } reset;
    auto op = std::make_unique<AgentUpdateOperation>(); std::vector<Session*> panes; std::string target;
    { LockG hold;
      auto* shell = resolveTarget(req.get("target"), nullptr);
      if (!shell || shell->exited || isCoverLocked(shell) || shell->overlay) return ctlErr("Claude update needs an uncovered live shell for its visible overlay");
      target = shell->paneId;
      for (auto* pane : g_sessions) if (!pane->exited && !isCoverLocked(pane)) panes.push_back(pane); }
    std::string image, nodeScript;
    for (auto* pane : panes) {
        AgentEvidence evidence; std::string why;
        if (!agentEvidence(pane, evidence, why)) continue;
        if (image.empty()) { image = evidence.image; if (evidence.identity.executableArgs == 2) nodeScript = evidence.argv[1]; }
        if (evidence.image == image && (evidence.identity.executableArgs == 1 ? nodeScript.empty() : evidence.argv[1] == nodeScript)) op->agents.push_back(std::move(evidence));
    }
    if (image.empty()) {
        // PATH only, never the working directory search used by unqualified CreateProcess.
        const auto path = environmentPath(L"PATH"); size_t begin = 0;
        while (begin <= path.size()) {
            const auto end = path.find(L';', begin); auto dir = path.substr(begin, end == std::wstring::npos ? end : end - begin);
            if (dir.size() >= 2 && dir.front() == L'"' && dir.back() == L'"') dir = dir.substr(1, dir.size() - 2);
            if (dir.size() > 2 && (dir[1] == L':' || dir.rfind(L"\\\\", 0) == 0)) {
                const auto candidate = dir + L"\\claude.exe"; const auto attrs = GetFileAttributesW(candidate.c_str());
                if (attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY)) { image = narrow(candidate); break; }
            }
            if (end == std::wstring::npos) break; begin = end + 1;
        }
    }
    if (image.empty()) return ctlErr("Claude executable not found on PATH or in a verified pane; nothing started");
    const auto helper = exeDir() + L"\\agliteterm-claude-update.ps1";
    if (GetFileAttributesW(helper.c_str()) == INVALID_FILE_ATTRIBUTES) return ctlErr("bundled Claude updater missing; nothing started");
    GUID guid{}; if (CoCreateGuid(&guid) != S_OK) return ctlErr("update receipt identity unavailable");
    wchar_t guidText[40]{}; StringFromGUID2(guid, guidText, 40); op->nonce = narrow(guidText);
    wchar_t temp[MAX_PATH]{}; if (!GetTempPathW(MAX_PATH, temp)) return ctlErr("update receipt directory unavailable");
    op->receipt = std::wstring(temp) + L"agliteterm-update-" + guidText + L".json";
    wchar_t system[MAX_PATH]{}; if (!GetSystemDirectoryW(system, MAX_PATH)) return ctlErr("system directory unavailable");
    const auto script = "& " + shell_configuration::literal(narrow(std::wstring(system) + L"\\WindowsPowerShell\\v1.0\\powershell.exe")) +
        " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + shell_configuration::literal(narrow(helper)) +
        " -Executable " + shell_configuration::literal(image) + " -Receipt " + shell_configuration::literal(narrow(op->receipt)) +
        " -Nonce " + shell_configuration::literal(op->nonce) + (nodeScript.empty() ? "" : " -NodeScript " + shell_configuration::literal(nodeScript));
    JsonReq open; open.fields = {{"cmd","agent.update.open"},{"target",target},{"args.script",script}};
    const auto reply = dispatchConfig(open); JsonReq answer; size_t pos = 0;
    if (!jsonParseObject(reply, pos, "", answer) || answer.get("ok") != "true") return reply;
    // From here a real updater may be running. A supervisor failure must fail closed rather
    // than admit a concurrent updater. In that rare case restart this app after closing it.
    reset.armed = false;
    { LockG hold; op->overlay = resolveTarget(answer.get("result"), nullptr); }
    if (!op->overlay) return ctlErr("update overlay disappeared; no restart worker started");
    HANDLE worker = CreateThread(nullptr, 0, agentUpdateWorker, op.get(), 0, nullptr);
    if (!worker) return ctlErr("update overlay opened but supervisor failed; no agents will be restarted");
    op.release(); CloseHandle(worker); reset.armed = false;
    return ctlOkStr("Claude update opened in owned overlay " + answer.get("result") + "; completion is reported by agent.update and agent.restart events");
}
static std::string agentDispatch(const JsonReq& req) {
    const auto& cmd = req.get("cmd");
    if (cmd == "agent.bridge") return agentBridge(req);
    if (cmd == "claude.update") return agentUpdate(req);
    if (!IsWindowEnabled(g_hwnd)) return ctlErr("modal dialog open; no agent changed");
    std::vector<Session*> panes;
    {
        LockG hold;
        if (cmd == "claude.adopt" && req.get("target").empty()) {
            for (auto* pane : g_sessions) if (!pane->exited && !isCoverLocked(pane)) panes.push_back(pane);
        } else {
            auto* pane = resolveTarget(req.get("target"), nullptr);
            if (!pane) return ctlErr("agent target not found");
            panes.push_back(pane);
        }
    }
    std::string result;
    for (auto* pane : panes) {
        AgentEvidence evidence; std::string why;
        if (!agentEvidence(pane, evidence, why)) {
            if (panes.size() == 1) return ctlErr(why);
            result += pane->paneId + ": skipped (" + why + ")\n"; continue;
        }
        if (cmd == "claude.yolo") return agentQueueRestart(std::move(evidence), true);
        {
            LockG hold;
            if (indexOfSession(pane) < 0 || pane->exited || !evidence.process->live()) return ctlErr("agent changed during adoption; nothing bound");
            if (!pane->agentResume.empty()) { result += pane->paneId + ": existing binding preserved\n"; continue; }
            pane->agentResume = agentResume(evidence, false);
        }
        if (!saveSessionState()) return ctlErr("adopted in memory but binding save failed; see log");
        result += evidence.paneId + ": adopted " + evidence.identity.conversation + " (permission mode unchanged)\n";
    }
    return ctlOkStr(result.empty() ? "no eligible agents" : result);
}
