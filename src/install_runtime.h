// Opt-in only. Called on a control worker, never with g_lock held. No installer runs at startup.
static std::string installIntegration(const JsonReq& req) {
    const auto op = req.get("cmd").substr(8);
    const auto remove = req.get("args.remove");
    if (!remove.empty() && remove != "true" && remove != "false") return ctlErr("remove must be boolean; nothing installed");
    if (remove == "true" && op != "cli") return ctlErr("remove applies only to install.cli; nothing installed");
    const auto script = exeDir() + L"\\agliteterm-install.ps1";
    if (GetFileAttributesW(script.c_str()) == INVALID_FILE_ATTRIBUTES) return ctlErr("bundled installer helper is missing; nothing installed");
    wchar_t system[MAX_PATH]{}; if (!GetSystemDirectoryW(system, MAX_PATH)) return ctlErr("system directory unavailable");
    const auto shell = std::wstring(system) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    auto command = L"\"" + shell + L"\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + L"\" -Operation " + widen(op);
    if (remove == "true") command += L" -Remove";
    SECURITY_ATTRIBUTES security{sizeof security, nullptr, TRUE}; HANDLE read = nullptr, write = nullptr;
    if (!CreatePipe(&read, &write, &security, 0)) return ctlErr("installer output pipe failed; nothing started");
    SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0);
    HANDLE input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, nullptr);
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{}; limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits)) {
        if (job) CloseHandle(job); if (input != INVALID_HANDLE_VALUE) CloseHandle(input); CloseHandle(read); CloseHandle(write);
        return ctlErr("installer ownership job failed; nothing started");
    }
    STARTUPINFOW startup{}; startup.cb = sizeof startup; startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = write; startup.hStdError = write; startup.hStdInput = input;
    PROCESS_INFORMATION process{};
    bool launched = input != INVALID_HANDLE_VALUE && CreateProcessW(shell.c_str(), &command[0], nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, exeDir().c_str(), &startup, &process);
    CloseHandle(write); if (input != INVALID_HANDLE_VALUE) CloseHandle(input);
    if (!launched) { CloseHandle(job); CloseHandle(read); return ctlErr("installer helper could not start; nothing installed"); }
    if (!AssignProcessToJobObject(job, process.hProcess)) {
        TerminateProcess(process.hProcess, 1); WaitForSingleObject(process.hProcess, 5000);
        CloseHandle(process.hThread); CloseHandle(process.hProcess); CloseHandle(job); CloseHandle(read);
        return ctlErr("installer ownership could not be established; helper was not resumed");
    }
    ResumeThread(process.hThread); CloseHandle(process.hThread);
    std::string output; bool timedOut = false; auto start = GetTickCount64();
    for (;;) {
        DWORD available = 0;
        if (PeekNamedPipe(read, nullptr, 0, nullptr, &available, nullptr) && available) {
            char bytes[4096]; DWORD got = 0;
            if (ReadFile(read, bytes, (std::min)(available, static_cast<DWORD>(sizeof bytes)), &got, nullptr)) output.append(bytes, got);
            if (output.size() > 128 * 1024) { timedOut = true; break; }
            continue;
        }
        if (WaitForSingleObject(process.hProcess, 20) == WAIT_OBJECT_0) {
            if (PeekNamedPipe(read, nullptr, 0, nullptr, &available, nullptr) && available) continue;
            break;
        }
        if (GetTickCount64() - start > 20000) { timedOut = true; break; }
    }
    if (timedOut) { TerminateJobObject(job, 1); WaitForSingleObject(process.hProcess, 5000); }
    DWORD code = 1; GetExitCodeProcess(process.hProcess, &code);
    CloseHandle(process.hProcess); CloseHandle(read); CloseHandle(job);
    if (timedOut) return ctlErr("installer exceeded its deadline/output limit and was stopped; partial changes may exist; inspect backups before retrying");
    JsonReq answer;
    const auto report = commands::trim(output); size_t pos = 0;
    if (!jsonParseObject(report, pos, "", answer) || pos != report.size() || (answer.get("ok") != "true" && answer.get("ok") != "false"))
        return ctlErr("installer returned an unreadable report; changes may exist; inspect profile/settings backups");
    if (code != 0 || answer.get("ok") != "true") return ctlErr(answer.get("error").empty() ? "installer failed; inspect backups" : answer.get("error"));
    if (op == "cli") {
        DWORD_PTR ignored; SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, reinterpret_cast<LPARAM>(L"Environment"),
                                             SMTO_ABORTIFHUNG, 1000, &ignored);
    }
    return ctlOkStr(answer.get("result"));
}
