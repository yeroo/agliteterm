// P12 UI/control helpers. Included after the existing target/state/render primitives.
// All dashboard/banner state is UI-owned; session/workspace reads hold g_lock.
static void pruneDashboard() {
    LockG hold;
    const auto previous = g_dashIds;
    const auto selected = g_dashSelected < static_cast<int>(g_dashIds.size()) ? g_dashIds[g_dashSelected] : "";
    g_dashIds.erase(std::remove_if(g_dashIds.begin(), g_dashIds.end(), [](const std::string& id) {
        const int at = indexOfSessionId(id); return at < 0 || g_sessions[at]->hidden;
    }), g_dashIds.end());
    auto found = std::find(g_dashIds.begin(), g_dashIds.end(), selected);
    g_dashSelected = found == g_dashIds.end() ? 0 : static_cast<int>(found - g_dashIds.begin());
    if (g_dashIds != previous) { g_dashCells.clear(); InvalidateRect(g_hwnd,nullptr,FALSE); }
    if (g_dashIds.empty()) g_dashboard = false;
}
static void selectRemainderSession(const std::string& id) {
    { LockG hold; const int at = indexOfSessionId(id);
      if (at < 0 || g_sessions[at]->hidden) return;
      g_activeWs = g_sessions[at]->ws; g_pane[0] = at; g_focus = 0;
      g_sessions[at]->notifications = 0; touchMruLocked(g_sessions[at]); }
    syncSplitToPrimary(); refreshTree(); InvalidateRect(g_hwnd, nullptr, FALSE);
}
static void openDashboardSession(int cell) {
    std::string id;
    { LockG hold;
      if (cell < 0 || cell >= static_cast<int>(g_dashIds.size())) return;
      id = g_dashIds[cell]; }
    g_dashboard = false; g_dashCells.clear();
    selectRemainderSession(id);
    InvalidateRect(g_hwnd, nullptr, FALSE);
}
static bool dashboardKey(WPARAM key) {
    pruneDashboard();
    if (!g_dashboard) { InvalidateRect(g_hwnd, nullptr, FALSE); return true; }
    if (key == VK_ESCAPE) { g_dashboard = false; g_dashCells.clear(); }
    else if (key == VK_RETURN || key == VK_SPACE) openDashboardSession(g_dashSelected);
    else g_dashSelected = lite_remainder::navigate(g_dashSelected, static_cast<int>(g_dashIds.size()), static_cast<int>(key));
    InvalidateRect(g_hwnd, nullptr, FALSE);
    return true; // even unrecognized key combinations are view-only
}
static void dashboardClick(POINT pt) {
    // IDs and cell rectangles describe the same rendered frame. Re-resolve the chosen ID at activation.
    for (int i = 0; i < static_cast<int>(g_dashCells.size()); ++i)
        if (PtInRect(&g_dashCells[i], pt)) { openDashboardSession(i); break; }
}
static void paintDashboard(HDC dc, RECT rc) {
    pruneDashboard(); g_dashCells.clear();
    if (!g_dashboard) return;
    RECT area{sidebarSpan(), toolbarTop(), rc.right, rc.bottom - (g_showStatus ? g_statusH : 0)};
    HBRUSH bg = CreateSolidBrush(g_th.client); FillRect(dc, &area, bg); DeleteObject(bg);
    const int count = static_cast<int>(g_dashIds.size()), cols = lite_remainder::columns(count), rows = (count + cols - 1) / cols;
    const int width = (area.right - area.left - 8 * (cols + 1)) / cols;
    const int height = (area.bottom - area.top - 28 - 8 * (rows + 1)) / rows;
    if (width < 16 || height < 28) return;
    for (int i = 0; i < count; ++i) {
        RECT cell{area.left + 8 + (i % cols) * (width + 8), area.top + 8 + (i / cols) * (height + 8), 0, 0};
        cell.right = cell.left + width; cell.bottom = cell.top + height;
        g_dashCells.push_back(cell);
        Session* session = nullptr; std::wstring label;
        { LockG hold; const int at = indexOfSessionId(g_dashIds[i]);
          if (at >= 0) { session = g_sessions[at];
            label = (session->ws >= 0 && session->ws < static_cast<int>(g_workspaces.size()) ? g_workspaces[session->ws] : L"?") + L" / " + session->name;
            if (session->exited) label += L" (exited)";
            if (session->notifications) label += L" [notice]";
          } }
        RECT title{cell.left, cell.top, cell.right, cell.top + 22};
        HBRUSH accent = CreateSolidBrush(i == g_dashSelected ? g_th.accent : g_th.bar);
        FillRect(dc, &title, accent); FrameRect(dc, &cell, accent); DeleteObject(accent);
        int saved = SaveDC(dc);
        SelectObject(dc, g_uiFont ? g_uiFont : GetStockObject(DEFAULT_GUI_FONT));
        SetBkMode(dc, TRANSPARENT); SetTextColor(dc, g_th.text);
        InflateRect(&title, -4, 0); DrawTextW(dc, label.c_str(), -1, &title, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
        RECT body{cell.left + 2, cell.top + 24, cell.right - 2, cell.bottom - 2};
        IntersectClipRect(dc, body.left, body.top, body.right, body.bottom);
        if (session) paintPane(dc, body, session, -1, false, true);
        RestoreDC(dc, saved);
    }
    RECT footer{area.left + 8, area.bottom - 24, area.right - 8, area.bottom};
    int saved = SaveDC(dc); SelectObject(dc, g_uiFont ? g_uiFont : GetStockObject(DEFAULT_GUI_FONT));
    SetBkMode(dc, TRANSPARENT); SetTextColor(dc, g_th.text);
    DrawTextW(dc, L"Dashboard: arrows / Enter / click / Esc — fixed-strike previews", -1, &footer, DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
    RestoreDC(dc, saved);
}
static void paintAttention(HDC dc, RECT rc) {
    const int bottom = rc.bottom - (g_showStatus ? g_statusH : 0);
    int saved = SaveDC(dc); SelectObject(dc, g_uiFont ? g_uiFont : GetStockObject(DEFAULT_GUI_FONT));
    SetBkMode(dc, TRANSPARENT); SetTextColor(dc, RGB(255,255,255));
    if (g_broadcast) {
        RECT warning{sidebarSpan() + 4, toolbarTop() + 2, rc.right - 4, toolbarTop() + 24};
        HBRUSH red = CreateSolidBrush(RGB(150,35,25)); FillRect(dc, &warning, red); DeleteObject(red);
        DrawTextW(dc, L"BROADCAST ON — keyboard to this session's workspace; paste stays targeted", -1, &warning, DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    }
    g_noticeRect = {};
    if (g_noticeUntil > GetTickCount64()) {
        g_noticeRect = {sidebarSpan() + 8, max(toolbarTop(), bottom - 58), rc.right - 8, bottom - 6};
        HBRUSH blue = CreateSolidBrush(RGB(35,70,130)); FillRect(dc, &g_noticeRect, blue); DeleteObject(blue);
        RECT text = g_noticeRect; InflateRect(&text, -6, -3);
        DrawTextW(dc, g_noticeText.c_str(), -1, &text, DT_WORDBREAK | DT_END_ELLIPSIS | DT_NOPREFIX);
    }
    RestoreDC(dc, saved);
}
static bool noticeClick(POINT pt) {
    if (g_noticeUntil <= GetTickCount64() || !PtInRect(&g_noticeRect, pt)) return false;
    g_noticeUntil = 0; g_dashboard = false;
    selectRemainderSession(g_noticeId);
    InvalidateRect(g_hwnd, nullptr, FALSE); return true;
}
// Caller holds g_lock. Numeric IDs are order indices; exact names beat unique substring matches.
static int remainderWorkspace(const std::string& target) {
    if (target.empty() || target == "active") return g_activeWs;
    unsigned long long value = 0; bool digits = true;
    for (char c : target) { if (c < '0' || c > '9') { digits = false; break; }
        value = value * 10 + c - '0'; if (value > INT_MAX) return -1; }
    if (digits) return value < g_workspaces.size() ? static_cast<int>(value) : -1;
    const auto want = widen(target); int exact = -1, partial = -1; bool duplicate = false, ambiguous = false;
    for (int i = 0; i < static_cast<int>(g_workspaces.size()); ++i) {
        if (_wcsicmp(g_workspaces[i].c_str(), want.c_str()) == 0) { if (exact >= 0) duplicate = true; exact = i; }
        std::wstring name = g_workspaces[i], lower = want;
        for (auto& c : name) c = static_cast<wchar_t>(towlower(c));
        for (auto& c : lower) c = static_cast<wchar_t>(towlower(c));
        if (name.find(lower) != std::wstring::npos) { if (partial >= 0) ambiguous = true; partial = i; }
    }
    return exact >= 0 ? (duplicate ? -1 : exact) : (ambiguous ? -1 : partial);
}
static std::string clearRestoreState() {
    const auto path = stateFilePath(); if (path.empty()) return ctlErr("restore clear: no state directory");
    unsigned long long stamp;
    { LockG hold; stamp = ++g_saveStamp; }
    struct SaveHold { SaveHold() { EnterCriticalSection(&g_saveLock); } ~SaveHold() { LeaveCriticalSection(&g_saveLock); } } hold;
    if (g_savePublished > stamp) return ctlErr("restore clear: a newer save overtook this request; nothing cleared; retry");
    // Durable per-instance evidence that absence is intentional, not an untouched legacy profile.
    const auto marker = path + L".cleared";
    HANDLE receipt = CreateFileW(marker.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if (receipt != INVALID_HANDLE_VALUE) {
        const bool durable = FlushFileBuffers(receipt) != FALSE; CloseHandle(receipt);
        if (!durable) return ctlErr("restore clear: intent marker could not be flushed; no state files removed");
    } else {
        const DWORD why = GetLastError(), attrs = GetFileAttributesW(marker.c_str());
        if (why != ERROR_FILE_EXISTS || attrs == INVALID_FILE_ATTRIBUTES || (attrs & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)))
            return ctlErr("restore clear: intent marker unavailable; no state files removed");
    }
    // Fence older snapshots even on partial failure. Never nest the state lock inside the I/O lock.
    g_savePublished = stamp;
    int removed = 0; std::string failures;
    for (const auto& suffix : {L".bak", L".tmp", L""}) {
        const auto file = path + suffix;
        if (DeleteFileW(file.c_str())) ++removed;
        else { const DWORD error = GetLastError();
            if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
                failures += narrow(suffix) + " Windows error " + std::to_string(error) + "; "; }
    }
    if (!failures.empty()) return ctlErr("restore clear: removed " + std::to_string(removed) + " state files; partial failure: " + failures);
    return ctlOkStr(removed ? "restore state cleared; live sessions unchanged; later saves may recreate it" : "no restore state");
}
static std::string remainderOnUi(const JsonReq& req) {
    const auto& cmd = req.get("cmd");
    if (cmd == "workspace.move" || (cmd == "dashboard" && req.get("args.op") != "state" && req.get("args.close") != "true")) {
        GUITHREADINFO gui{sizeof(gui)};
        if (!GetGUIThreadInfo(GetCurrentThreadId(), &gui) ||
            (gui.flags & (GUI_INMENUMODE | GUI_POPUPMENUMODE | GUI_SYSTEMMENUMODE)) ||
            g_treeDrag || gui.hwndCapture == g_tree)
            return ctlErr(cmd + ": finish the menu or sidebar drag first; unchanged");
    }
    if (cmd == "broadcast") {
        bool next;
        if (!lite_remainder::toggle(req.get("args.op"), g_broadcast, next)) return ctlErr("broadcast: expected on/off/toggle/state/get; unchanged");
        if (next != g_broadcast) { g_broadcast = next; emitEvent("broadcast", "", next ? "on" : "off"); InvalidateRect(g_hwnd,nullptr,FALSE); }
        return ctlOkStr(g_broadcast ? "on" : "off");
    }
    if (cmd == "restore.clear") return clearRestoreState();
    if (cmd == "workspace.move") {
        { LockG hold; const int from = remainderWorkspace(req.get("target"));
          if (from < 0) return ctlErr("workspace not found or ambiguous");
          const int to = lite_remainder::destination(from, static_cast<int>(g_workspaces.size()), req.get("args.dir"));
          if (to < 0) return ctlErr("workspace move: expected up/down/top/bottom; unchanged");
          if (to == from) return ctlOkStr("already at boundary");
          auto name = g_workspaces[from]; g_workspaces.erase(g_workspaces.begin() + from); g_workspaces.insert(g_workspaces.begin() + to, name);
          for (auto* s : g_sessions) s->ws = lite_remainder::remap(s->ws, from, to);
          for (auto& s : g_closedStack) s.ws = lite_remainder::remap(s.ws, from, to);
          g_activeWs = lite_remainder::remap(g_activeWs, from, to); g_focusWs = lite_remainder::remap(g_focusWs, from, to);
        }
        emitEvent("tree"); refreshTree(false);
        if (!saveSessionState()) return ctlErr("workspace moved in memory, but state could not be saved");
        return ctlOkStr("moved");
    }
    if (cmd == "notify") {
        const auto& body = req.get("args.body"); const auto& title = req.get("args.title"); std::string id;
        if (body.size() > 4096 || title.size() > 256) return ctlErr("notify: maximum 4096 body / 256 title UTF-8 bytes");
        { LockG hold; std::string why; auto* s = resolveTarget(req.get("target"), &why);
          if (!s) return ctlErr(why.empty() ? "session not found" : why);
          if (s->hidden) s = splitOwnerOf(s);
          if (!s) return ctlErr("notify: popup/cover is not a tree session");
          id = s->id; s->notifications = min(999, s->notifications + 1);
        }
        g_noticeId = id; g_noticeText = (title.empty() ? L"agliteterm" : widen(title)) + L": " + widen(body);
        g_noticeUntil = GetTickCount64() + 8000;
        emitEvent("notification", id, title + ": " + body);
        g_nid.uFlags |= NIF_INFO;
        wcsncpy_s(g_nid.szInfoTitle, title.empty() ? L"agliteterm" : widen(title).c_str(), _TRUNCATE);
        wcsncpy_s(g_nid.szInfo, widen(body).c_str(), _TRUNCATE); g_nid.dwInfoFlags = NIIF_INFO;
        const bool balloon = Shell_NotifyIconW(NIM_MODIFY, &g_nid) != FALSE; g_nid.uFlags &= ~NIF_INFO;
        refreshTree(); InvalidateRect(g_hwnd, nullptr, FALSE);
        return ctlOkStr(balloon ? "notified; desktop display depends on Windows notification policy" : "notified in app; desktop notification unavailable");
    }
    if (cmd == "dashboard") {
        if (req.get("args.op") == "state") {
            pruneDashboard(); std::string ids = "[";
            for (const auto& id : g_dashIds) { if (ids.size() > 1) ids += ','; ids += '"' + jsonEscape(id) + '"'; }
            return "{\"ok\":true,\"result\":{\"open\":" + std::string(g_dashboard ? "true" : "false") + ",\"selected\":" + std::to_string(g_dashSelected) + ",\"ids\":" + ids + "]}}";
        }
        if (!req.get("args.op").empty()) return ctlErr("dashboard: unknown op; unchanged");
        if (req.fields.count("args.close") && req.get("args.close") != "true" && req.get("args.close") != "false") return ctlErr("dashboard: close must be boolean");
        if (!req.get("args.font-size").empty() && req.get("args.font-size") != "0") return ctlErr("dashboard: lite uses fixed-strike previews; font-size unsupported");
        if (req.get("args.close") == "true") {
            if (!req.get("args.ids").empty()) return ctlErr("dashboard: close cannot be combined with selectors; unchanged");
            g_dashboard = false; g_dashCells.clear(); InvalidateRect(g_hwnd,nullptr,FALSE); return ctlOkStr("dashboard closed");
        }
        if ((g_quickHwnd && IsWindowVisible(g_quickHwnd)) || (g_scratchHwnd && IsWindowVisible(g_scratchHwnd)) ||
            (g_overlayHwnd && IsWindowVisible(g_overlayHwnd))) return ctlErr("dashboard: close popup terminals first");
        std::vector<std::string> ids;
        { LockG hold;
          const auto& list = req.get("args.ids");
          if (!list.empty()) {
            size_t begin = 0;
            do { auto end = list.find(',', begin); const auto token = commands::trim(list.substr(begin, end == std::string::npos ? end : end - begin));
                std::string why; auto* s = token.empty() ? nullptr : resolveTarget(token, &why);
                if (!s || s->hidden) return ctlErr("dashboard: every selector must name a tree session; unchanged");
                if (std::find(ids.begin(),ids.end(),s->id) != ids.end()) return ctlErr("dashboard: duplicate session; unchanged");
                ids.push_back(s->id); if (ids.size() > 9) return ctlErr("dashboard: at most nine sessions; unchanged");
                if (end == std::string::npos) break; begin = end + 1;
            } while (true);
          } else {
            for (const auto& id : g_mru) { const int at = indexOfSessionId(id);
              if (at >= 0 && !g_sessions[at]->hidden && ids.size() < 9) ids.push_back(id); }
            for (const auto* s : g_sessions) if (!s->hidden && ids.size() < 9 && std::find(ids.begin(),ids.end(),s->id) == ids.end()) ids.push_back(s->id);
          }
        }
        if (ids.empty()) return ctlErr("dashboard: no sessions");
        cancelDrag(g_hwnd); g_splitDrag = false; if (GetCapture() == g_hwnd) ReleaseCapture();
        g_rbtnForwarded = false; g_palette = false; g_leaderPending = false;
        g_dashIds = std::move(ids); g_dashCells.clear(); g_dashSelected = 0; g_dashboard = true;
        InvalidateRect(g_hwnd, nullptr, FALSE); return ctlOkStr("dashboard");
    }
    return ctlErr("unsupported remainder verb");
}
