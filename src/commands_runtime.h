// Included after the pane/control primitives. Every entry here runs on the UI thread.
static const std::map<std::string,int> kCommandActions = {
    {"new_session",KB_NEW},{"new_workspace",KB_NEWWS},{"close_pane",KB_CLOSE},{"split_pane",KB_SPLIT},
    {"next_session",KB_NEXT},{"previous_session",KB_PREV},{"copy_selection",KB_COPY},{"paste",KB_PASTE},
    {"action_palette",KB_PALETTE},{"focus_left_pane",KB_FOCUSL},{"focus_top_pane",KB_FOCUSL},
    {"focus_right_pane",KB_FOCUSR},{"focus_bottom_pane",KB_FOCUSR},{"quick_terminal",KB_QUICK},
    {"toggle_scratch",KB_SCRATCH},{"reopen_session",KB_REOPEN},{"toggle_flag",KB_FLAG},
    {"toggle_flagged_view",KB_FLAGVIEW},{"next_attention",KB_ATTENTION},{"focus_workspace",KB_FOCUSWS},
    {"mark_mode",KB_MARK},{"select_all",KB_SELECTALL},{"toggle_read_only",KB_READONLY}
};
static bool loadCommands(std::string& error) {
    const auto dir = stateDir(); if (dir.empty()) { error = "app-data directory unavailable"; return false; }
    HANDLE file = CreateFileW((dir + L"\\keymap.conf").c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    std::string bytes;
    if (file == INVALID_HANDLE_VALUE) {
        auto code = GetLastError();
        if (code != ERROR_FILE_NOT_FOUND && code != ERROR_PATH_NOT_FOUND) { error = "keymap.conf is unreadable"; return false; }
    } else {
        LARGE_INTEGER size{}; DWORD read = 0;
        if (!GetFileSizeEx(file, &size) || size.QuadPart > 1024 * 1024 || size.QuadPart < 0) {
            CloseHandle(file); error = "keymap.conf exceeds 1 MiB"; return false;
        }
        bytes.resize(static_cast<size_t>(size.QuadPart));
        bool ok = bytes.empty() || (ReadFile(file, &bytes[0], static_cast<DWORD>(bytes.size()), &read, nullptr) && read == bytes.size());
        CloseHandle(file);
        if (!ok || (!bytes.empty() && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data(), static_cast<int>(bytes.size()), nullptr, 0))) {
            error = "keymap.conf is unreadable or not UTF-8"; return false;
        }
    }
    commands::Catalog next;
    if (!commands::parse(bytes, kCommandActions, next, error)) return false;
    g_commands = std::move(next); g_leaderPending = false; if (g_palette) palFilter(); return true;
}
static std::string commandAction(const std::string& action) {
    if (action.rfind("command:", 0) == 0) {
        JsonReq call; call.fields["cmd"] = "command.run"; call.fields["args.name"] = action.substr(8);
        return commandOnUi(call);
    }
    const auto found = kCommandActions.find(action);
    if (found == kCommandActions.end()) return ctlErr("unsupported action; nothing executed");
    runKbAction(found->second); return ctlOkStr("ran " + action);
}
static bool customKey(WORD combo) {
    if (g_settingsOpenQueued || !IsWindowEnabled(g_hwnd)) return false;
    if (g_leaderPending && GetTickCount64() - g_leaderAt > 2000) g_leaderPending = false;
    if (g_leaderPending) {
        g_leaderPending = false;
        if (LOBYTE(combo) != VK_ESCAPE) {
            if (const auto* binding = g_commands.binding(combo, true)) {
                const auto action = binding->action; const auto reply = commandAction(action);
                if (reply.find("\"ok\":false") != std::string::npos) logWarn("command: %s", reply.c_str());
            } else MessageBeep(MB_OK);
        }
        return true;
    }
    if (g_commands.leader && combo == g_commands.leader) { g_leaderPending = true; g_leaderAt = GetTickCount64(); return true; }
    if (const auto* binding = g_commands.binding(combo, false)) {
        const auto action = binding->action; const auto reply = commandAction(action);
        if (reply.find("\"ok\":false") != std::string::npos) logWarn("command: %s", reply.c_str());
        return true;
    }
    return false;
}
static std::string commandOnUi(const JsonReq& req) {
    const auto& cmd = req.get("cmd");
    if (cmd == "command.list") {
        std::string result;
        for (const auto& c : g_commands.commands) {
            std::string chord = "-";
            for (const auto& b : g_commands.bindings)
                if (commands::lower(b.action) == "command:" + commands::lower(c.label) &&
                    g_commands.binding(b.key, b.leader) == &b) { chord = (b.leader ? "leader " : "") + b.spelling; break; }
            if (!result.empty()) result += '\n';
            result += c.label + '\t' + c.mode + '\t' + chord + '\t' + c.text;
        }
        return ctlOkStr(result.empty() ? "(no custom commands defined in keymap.conf)" : result);
    }
    if (cmd == "command.leader") {
        if (g_leaderPending && GetTickCount64() - g_leaderAt > 2000) g_leaderPending = false;
        const auto op = commands::lower(req.get("args.op"));
        if (op.empty() || op == "state") return ctlOkStr(g_leaderPending ? "pending" : "idle");
        if (op == "cancel") { g_leaderPending = false; return ctlOkStr("idle"); }
        if (op == "begin") {
            if (!g_commands.leader) return ctlErr("no leader configured");
            g_leaderPending = true; g_leaderAt = GetTickCount64(); return ctlOkStr("pending");
        }
        if (op.rfind("key:", 0) != 0) return ctlErr("unknown leader operation");
        const auto key = commands::chord(op.substr(4)); if (!key) return ctlErr("bad chord");
        g_leaderPending = false;
        if (key == VK_ESCAPE) return ctlOkStr("idle");
        const auto* binding = g_commands.binding(key, true);
        if (!binding) return ctlErr("no leader binding");
        const auto action = binding->action; return commandAction(action);
    }
    if (cmd != "command.run") return ctlErr("unknown command operation");
    const auto name = req.get("args.name").empty() ? req.get("args.command") : req.get("args.name");
    if (commands::trim(name).empty() || name.find('\0') != std::string::npos) return ctlErr("command.run needs args.name or args.command");
    const auto* configured = g_commands.find(name);
    std::string mode = configured ? configured->mode : "new";
    if (req.fields.count("args.mode")) mode = commands::lower(req.get("args.mode"));
    if (!commands::mode(mode)) return ctlErr("unknown command mode; nothing executed");
    Session* pane; HANDLE data; int ws;
    std::map<std::string,std::string> values;
    {
        LockG hold; std::string why; pane = resolveTarget(req.get("target"), &why);
        if (!pane || pane->exited) return ctlErr("command target is absent or exited; nothing executed");
        if (mode == "send" && (pane->readOnly || pane->data == INVALID_HANDLE_VALUE)) return ctlErr("command send requires a live writable pane; nothing written");
        if (mode == "overlay" && (isCoverLocked(pane) || pane->overlay)) return ctlErr("command overlay requires an uncovered shell pane; nothing opened");
        auto* owner = pane->hidden ? splitOwnerOf(pane) : pane;
        Session* shell = pane;
        if (!owner) {
            for (auto* candidate : g_sessions) if (candidate->overlay == pane) { shell = candidate; owner = splitOwnerOf(candidate); if (!owner) owner = candidate; break; }
        }
        if (!owner) owner = displayedOwner(); // independent popup context follows the displayed session
        if (!owner) owner = pane;
        const int slot = (shell != owner ? 1 : 0) ^ (owner->swapped ? 1 : 0);
        ws = pane->ws; data = pane->data;
        values = {{"AGW_SESSION", owner->name.empty() ? owner->id : narrow(owner->name)}, {"AGW_SESSION_ID",owner->id},
            {"AGW_WORKSPACE", ws >= 0 && ws < static_cast<int>(g_workspaces.size()) ? narrow(g_workspaces[ws]) : ""},
            {"AGW_PANE_ID",pane->paneId},{"AGW_PANE",pane == g_quickSession ? "quick" : pane == g_scratchSession ? "scratch" :
                pane == g_overlaySession || isCoverLocked(pane) ? "overlay" : slot ? "right" : "left"},
            {"AGW_APP",GetFileAttributesW((exeDir() + L"\\agwintermctl.exe").c_str()) == INVALID_FILE_ATTRIBUTES ? "agwintermctl" : narrow(exeDir() + L"\\agwintermctl.exe")}};
    }
    values["AGW_CWD"] = sessionLiveCwd(pane);
    const auto text = commands::expand(configured ? configured->text : name, values);
    if (mode == "send") {
        std::string bytes; for (char c : text) if (c != '\r' && c != '\n') bytes += c;
        bytes += '\r';
        const auto sent = ovIo(data, true, bytes.data(), nullptr, static_cast<DWORD>(bytes.size()));
        return sent == bytes.size() ? ctlOkStr("command written; shell success not confirmed") : ctlErr("command write failed or was partial; shell outcome unknown");
    }
    const auto cwd = widen(values["AGW_CWD"]);
    if (mode == "detached") {
        std::map<std::wstring,std::wstring> env;
        auto* block = GetEnvironmentStringsW(); if (!block) return ctlErr("could not read environment; nothing launched");
        for (auto* entry = block; *entry; entry += wcslen(entry) + 1) {
            std::wstring item(entry); auto eq = item.find(L'=', 1); if (eq == std::wstring::npos) continue;
            auto key = item.substr(0, eq); for (auto& c : key) c = towupper(c); env[key] = item.substr(eq + 1);
        }
        FreeEnvironmentStringsW(block);
        for (const auto& value : values) env[widen(value.first)] = widen(value.second);
        std::vector<wchar_t> environment;
        for (const auto& value : env) { const auto item = value.first + L"=" + value.second; environment.insert(environment.end(), item.begin(), item.end()); environment.push_back(0); }
        environment.push_back(0);
        wchar_t system[MAX_PATH]{}; if (!GetSystemDirectoryW(system, MAX_PATH)) return ctlErr("system command interpreter unavailable");
        const auto interpreter = std::wstring(system) + L"\\cmd.exe";
        auto command = L"\"" + interpreter + L"\" /d /s /c \"" + widen(text) + L"\"";
        if (command.size() >= 32767) return ctlErr("detached command exceeds Windows limit; nothing launched");
        STARTUPINFOW startup{}; startup.cb = sizeof startup; PROCESS_INFORMATION process{};
        if (!CreateProcessW(interpreter.c_str(), &command[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                            environment.data(), cwd.empty() ? nullptr : cwd.c_str(), &startup, &process)) return ctlErr("detached process could not start");
        auto pid = process.dwProcessId; CloseHandle(process.hThread); CloseHandle(process.hProcess);
        return ctlOkStr("detached process started " + std::to_string(pid) + "; completion not confirmed");
    }
    std::string script;
    for (const auto& value : values) script += "$env:" + value.first + "=" + shell_configuration::literal(value.second) + ";";
    if (!values["AGW_CWD"].empty()) script += "Set-Location -LiteralPath " + shell_configuration::literal(values["AGW_CWD"]) + ";";
    script += text;
    if (mode == "overlay") {
        if (overlayCommandLine(script).size() >= 2048) return ctlErr("command plus context exceeds host argument limit; nothing opened");
        std::string why; auto* overlay = openPaneOverlay(pane, script, &why);
        return overlay ? ctlOkStr("command overlay opened " + overlay->paneId + "; completion not confirmed") : ctlErr(why);
    }
    if (script.size() >= 2048) return ctlErr("command plus context exceeds host argument limit; nothing created");
    int cols, rows; newSessionGrid(g_focus, &cols, &rows);
    std::vector<std::string> args{"-NoExit", "-Command", script};
    g_activeWs = ws;
    auto* created = newSession(cols, rows, "powershell.exe", &args, values["AGW_CWD"].empty() ? nullptr : values["AGW_CWD"].c_str());
    if (!created) return ctlErr("command session could not be created");
    selectPrimary(indexOfSession(created));
    return ctlOkStr("command session created " + created->paneId + "; completion not confirmed");
}
