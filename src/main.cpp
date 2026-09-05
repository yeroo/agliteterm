// agliteterm (was agwinterm-lite) M1 phase 1 (issue #134): layout core over the Rust server.
//
// M0 gave one session on the full stack (Rust pty-host + agwinterm-core replica
// + GDI ExtTextOutW/lpDx). M1p1 adds the layout skeleton with main-app parity:
//   - multiple sessions + sidebar (click to select, status marker)
//   - SPLITS from the start (Boris's #134 decision): vertical two-pane split,
//     per-pane session + focus, per-pane host resize
//   - text styles: bold/italic fonts, underline/strike lines, dim, inverse
//   - scrollback view (mouse wheel / Shift+PgUp/PgDn) over the replica history
// Keys: Ctrl+T new session · Ctrl+W close · Ctrl+Tab cycle · Ctrl+Shift+D
// split toggle · Ctrl+Shift+Left/Right focus pane.
// Still M1 phase 2: selection+clipboard, palette, astral glyphs, control API.
//
// Protocol v2 (protobuf; proto/ptyhost.proto). Zero terminal logic, zero ConPTY.

#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>   // native TreeView (SysTreeView32) sidebar — ships with Windows, no external deps
#include <shlobj.h>     // SHBrowseForFolder (New Session in Folder…)
#include <dwmapi.h>     // dark title bar (DWMWA_USE_IMMERSIVE_DARK_MODE)
#include <uxtheme.h>    // SetWindowTheme — dark scrollbars on the tree
#include <winhttp.h>    // self-update HTTP
#include <bcrypt.h>     // self-update SHA-256

// Stamped by build.ps1 from installer/agliteterm.iss so exe and setup can never disagree;
// an unstamped ("dev") build never triggers a self-update.
#ifndef AGWL_VERSION_STR
#define AGWL_VERSION_STR "dev"
#endif
#include <algorithm>    // std::stable_sort (command-palette ranking)
#include <ctime>        // time(): the statusChangedAt stamp is epoch seconds
#include <string>
#include <vector>
#include <deque>
#include <memory>     // unique_ptr: the heap payload a posted WM_APP_OVERLAY carries

// ---- WTL (third_party/wtl, MS-PL) — the UI layer is built on ATL/WTL -------------------------
// Header-only over Win32: same window messages and the same native controls underneath, but with
// typed control wrappers, message-map crackers and RAII GDI objects instead of hand-rolled switches.
#include <atlbase.h>
#include <atlapp.h>
CAppModule _Module;
#include <atlwin.h>
#include <atlframe.h>
#include <atlctrls.h>
#include <atlcrack.h>
#include <atlmisc.h>
#include <atlgdi.h>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "uxtheme.lib")
// comctl32 v6: needed so DarkMode_* visual styles (incl. DARK SCROLLBARS) can render. Classic mode
// stays pixel-classic regardless: applyTheme strips the visual style per control there, and an
// untheme'd v6 control paints with the classic engine — same look as the old no-manifest build.
#pragma comment(linker, "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")   // registry (persisted font choice)
#pragma comment(lib, "winhttp.lib")    // self-update: GitHub releases over HTTPS
#pragma comment(lib, "bcrypt.lib")     // self-update: SHA-256 digest verification

#include "proto/ptyhost.pb.h"
#include "proto/pb_encode.h"
#include "proto/pb_decode.h"
#include "control.h"

// ---- agwinterm-core C ABI (ABI v18) ----
struct FfiCell {
    int32_t rune;
    uint32_t fg, bg, attrs, width;
    uint32_t fgKind, fgIndex, fgRgb;
    uint32_t bgKind, bgIndex, bgRgb;
};
struct FfiEmuInfo {
    uint32_t cols, rows, cursorRow, cursorCol, cursorVisible, isAltScreen, historyCount;
    int64_t scrollGeneration;
    // mouseSgrPixels (?1016) arrived in v18 BETWEEN mouseSgr and bracketedPaste. This struct is
    // filled by the core, so a missing field here is not a stale value but a write past the end of
    // the caller's stack frame - a /GS fail-fast (0xC0000409) on the first emu_info call.
    uint32_t mouseClick, mouseDrag, mouseMotion, mouseSgr, mouseSgrPixels, bracketedPaste;
    int32_t keyboardFlags;
    uint32_t scrollTop, scrollBottom, markCount, focusReporting, synchronizedOutput, win32InputMode, dynamicBg;
    int32_t cursorShape;
};
struct FfiMark {   // FTCS / OSC 133 boundary; lines are buffer-absolute, -1 = unset
    int64_t promptLine, commandLine, outputLine, endLine;
    uint32_t hasExit;
    int32_t exitCode;
};
static uint32_t (*core_abi)();
static void* (*emu_new)(uint32_t, uint32_t);
static void (*emu_free)(void*);
static bool (*emu_feed)(void*, const uint8_t*, uint32_t);
static bool (*emu_resize)(void*, uint32_t, uint32_t);
static bool (*emu_info)(void*, FfiEmuInfo*);
static bool (*emu_copy_grid)(void*, FfiCell*, uint32_t);
static bool (*emu_copy_history_row)(void*, uint32_t, FfiCell*, uint32_t);
static uint32_t (*emu_marks)(void*, FfiMark*, uint32_t);
static uint8_t* (*emu_get_text)(void*, uint32_t, uint32_t*);   // 0 title, 1 cwd (OSC 7), 2 modes
// Side effects the emulator QUEUED rather than performed: OSC 52 clipboard writes, the replies
// it owes a program that asked the terminal a question, notifications, BEL. None of it happens
// until the host drains them (see runHostActions).
static uint8_t* (*emu_take_host_actions)(void*, uint32_t*);
static void (*core_free_buf)(uint8_t*, uint32_t);

// v16 added agwcore_emu_set_scrollback. v18 (agwinterm 0.17.10; there was no 17) inserted
// mouseSgrPixels into FfiEmuInfo above and added or changed NO export - a bump can be a struct
// alone. The core handshake is an EXACT match and the structs are shared, so the pin moves with
// the core it is built against and every struct above is re-checked against lib.rs on each bump.
static constexpr uint32_t kRequiredAbi = 18;
static constexpr uint32_t kAttrBold = 1, kAttrItalic = 2, kAttrUnderline = 4,
                          kAttrInverse = 8, kAttrDim = 16, kAttrStrike = 32;
static constexpr uint32_t kProtocolVersion = 2;
static constexpr int kSidebarW = 180;
static constexpr int kSplitterW = 5;   // draggable divider between the sidebar and the terminal
static constexpr int kSidebarMinW = 90;   // the splitter will not shrink the left pane past this
// The `sidebar width` API range is 90..900 (pixels): Min is what the splitter already refuses to
// go under, Max is what the registry loader has always accepted, so the API allows exactly what
// the two existing paths allow and nothing a hand-edited value could not already produce. Outside
// it is REFUSED, not clamped (P2 contract: a clamp answers ok to a script that checks nothing else).
// A width inside the range can still leave no room for a terminal in a narrow window, so a set is
// also refused when the content region would drop under kMinContentCols cells of the live font —
// the #23 trigger a setter would otherwise add (a pane at 2 columns).
static constexpr int kSidebarMaxW = 900;
static constexpr int kMinContentCols = 20;
static int g_sidebarW = kSidebarW;     // sidebar width IN EFFECT (what the layout uses)
// The width the user ASKED for. Only the splitter drag, `sidebar width` and the registry loader
// write it; it is what gets persisted. fitSidebarToClient derives g_sidebarW from it on every
// layout instead of shrinking the preference itself, so narrowing the window for a moment and then
// hiding the sidebar (saveColors runs on a toggle) no longer replaces a wide monitor's 900 with
// whatever fitted the laptop (revmux r1 of P2-lite).
static int g_sidebarWPref = kSidebarW;
static bool g_showSidebar = true, g_showToolbar = true, g_showStatus = true;   // View menu toggles (persisted)
static bool g_flagView = false;   // sidebar shows only flagged sessions (toolbar pennant / View menu)
static int g_focusWs = -1;        // focused workspace: the sidebar shows only this one (-1 = all)

static std::string narrow(const std::wstring& w);   // fwd (utf conversions live further down)

// ---- launch arguments (same names as the full app; unknown args are ignored) ------------------
static std::wstring g_argProfile;         // -p/--profile <name>: profile for the launch session
static std::string  g_argDir;             // -d/--dir/--startingDirectory <path>: its working dir
static bool g_argMaximized = false;       // --maximized
static bool g_argNoRestore = false;       // --no-restore: don't rebuild the saved sessions
static bool g_argBenchAgbf = false;       // --bench-agbf: print pack benchmarks to the console, exit
static bool g_argDiagnose = false;        // --diagnose: print an environment/state report, exit
static std::wstring g_argPipe;            // --pipe <name>: control-pipe name (default agliteterm)

static HWND g_hwnd;   // main frame (declared early: the instance registry compares against it)

// ---- multi-window (multi-process): each lite window is one process ---------------------------
// The instance name comes from --pipe; the default instance is "agliteterm". It namespaces the
// session ids on the SHARED pty-host, the state file, and the saved window geometry — that is what
// lets any number of lite windows coexist. Instances see each other through a registry of
// name -> {pid, hwnd} entries under HKCU, which the window.* control verbs act on.
static std::wstring g_instance = L"agliteterm";   // resolved in parseLaunchArgs
static std::wstring g_instanceRaw;                    // --pipe as TYPED, when sanitizing changed it
static std::string  g_idPrefix = "lite";              // session-id prefix ("<prefix>-N")
static bool g_isDefaultInstance = true;
// ---- product identity ------------------------------------------------------------------------
// agwinterm-lite became agliteterm, its own product in its own repository
// (docs/plans/2026-08-17-agliteterm-product-split.md). Every name lives HERE, once: the rename has
// to be paired with a migration, and a scattered literal is a stranded user — the settings key and
// the state directory own fonts, colours, keybindings and saved sessions.
// The diagnostics log is defined further down; migrateFromLegacy (just below) reports through it.
static void logInfo(const char* fmt, ...);
// fwd: the control-API event bus is defined with the rest of the control code, but the places
// that have something to report (session created, status changed) come long before it.
static void emitEvent(const char* type, const std::string& session = {}, const std::string& info = {});
static std::string installAgentSkill();   // fwd: the Help menu offers it, the control API too
static void logWarn(const char* fmt, ...);
static const wchar_t* kProduct       = L"agliteterm";
static const wchar_t* kRegKey        = L"Software\\agliteterm";
static const wchar_t* kInstKey       = L"Software\\agliteterm\\Instances";
// The 0.17.x names. Read-only: migration copies FROM them and never writes back, so a user who
// rolls back still finds their old install intact.
static const wchar_t* kLegacyProduct = L"agwinterm-lite";
static const wchar_t* kLegacyRegKey  = L"Software\\agwinterm-lite";

/// The per-user state root. One helper, because the rename has to be paired with a migration and
/// every caller must agree on where "old" and "new" live: sessions, the .bak generation, the log
/// and the update payloads all sit here.
static std::wstring stateDir(bool legacy = false) {
    wchar_t base[MAX_PATH];
    if (GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH) == 0) return {};
    return std::wstring(base) + L"\\" + (legacy ? kLegacyProduct : kProduct);
}

/// Adopt 0.17.x state on first run as agliteterm.
///
/// The rename moved four things that belong to the USER, not to us: saved sessions and their .bak
/// generation, the font, the colours and the keybindings. Renaming without this is indistinguishable
/// from the data loss the restore matrix exists to prevent — the window simply comes up empty.
///
/// COPY, never move. A user who rolls back to agwinterm-lite must still find their install working,
/// so the legacy directory and key are read-only here. Runs only when the new side is untouched:
/// if agliteterm already has state, it wins and the legacy copy is left exactly as it is.
static void migrateFromLegacy() {
    std::wstring cur = stateDir(), old = stateDir(true);
    if (cur.empty() || old.empty() || cur == old) return;
    if (GetFileAttributesW(old.c_str()) == INVALID_FILE_ATTRIBUTES) return;   // nothing to adopt

    // "Untouched" means no session state, not "no directory": logInit has already created the
    // directory and written a line into it by the time we run.
    bool haveNew = false;
    WIN32_FIND_DATAW fd{};
    HANDLE h = FindFirstFileW((cur + L"\\sessions*.tsv").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) { haveNew = true; FindClose(h); }
    if (haveNew) { logInfo("migrate: agliteterm state already present - legacy state left untouched"); return; }

    int files = 0;
    CreateDirectoryW(cur.c_str(), nullptr);
    for (const wchar_t* pat : { L"\\sessions*.tsv", L"\\sessions*.tsv.bak" }) {
        WIN32_FIND_DATAW f{};
        HANDLE fh = FindFirstFileW((old + pat).c_str(), &f);
        if (fh == INVALID_HANDLE_VALUE) continue;
        do {
            if (f.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
            if (CopyFileW((old + L"\\" + f.cFileName).c_str(),
                          (cur + L"\\" + f.cFileName).c_str(), TRUE)) files++;
            else logWarn("migrate: could not copy %s (err %lu)", narrow(f.cFileName).c_str(), GetLastError());
        } while (FindNextFileW(fh, &f));
        FindClose(fh);
    }

    // Settings: copy every value under the legacy key. Enumerated rather than listed by name so a
    // key this build does not know about (an older or newer build's) travels too.
    int values = 0;
    HKEY src{};
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kLegacyRegKey, 0, KEY_READ, &src) == ERROR_SUCCESS) {
        HKEY dst{};
        if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegKey, 0, nullptr, 0, KEY_WRITE, nullptr, &dst, nullptr) == ERROR_SUCCESS) {
            for (DWORD idx = 0;; idx++) {
                wchar_t name[256]; DWORD nlen = 256, type = 0;
                BYTE data[2048]; DWORD dlen = sizeof data;
                LONG r = RegEnumValueW(src, idx, name, &nlen, nullptr, &type, data, &dlen);
                if (r == ERROR_NO_MORE_ITEMS) break;
                if (r != ERROR_SUCCESS) continue;
                if (RegSetValueExW(dst, name, 0, type, data, dlen) == ERROR_SUCCESS) values++;
            }
            RegCloseKey(dst);
        }
        RegCloseKey(src);
    }
    if (files || values)
        logInfo("migrate: adopted %d state file(s) and %d setting(s) from %s",
                files, values, narrow(old).c_str());
}


/// The instance name as it will actually be used. It becomes a FILENAME (sessions-<name>.tsv,
/// lite-<name>.log) and is interpolated into the "Restart everything" command line, so drop the
/// characters that make either of those mean something else: path separators (--pipe "..\..\x"
/// would write outside the state directory), and the quoting/chaining metacharacters cmd.exe acts
/// on. `& ^ %` and anything past 32 characters ARE legal in a filename, so a name already in use
/// can change here — and a changed name reads its state from a different file, i.e. "my sessions
/// are gone" with no explanation. g_instanceRaw keeps the requested name so logInit can say so.
///
/// EVERY producer of an instance name must run it through here. `--pipe` does (parseLaunchArgs) and
/// so does `window.new`: the child sanitizes whatever it is handed, so a caller told it got
/// "build&test" would then find `window select build&test` answering "window not found".
static std::wstring sanitizeInstanceName(const std::wstring& raw) {
    std::wstring clean;
    for (wchar_t c : raw)
        if (c >= 32 && !wcschr(L"\\/:*?\"<>|&^%", c)) clean += c;
    // Length matters as much as content: the name also becomes the session-id prefix, and ids are
    // formatted into a fixed 64-byte buffer (newSession). 32 is longer than any name worth typing
    // and leaves room for "-<n>" many times over.
    if (clean.size() > 32) clean.resize(32);
    while (!clean.empty() && (clean.back() == L' ' || clean.back() == L'.')) clean.pop_back();
    return clean.empty() ? L"lite" : clean;
}

static void announceInstance(HWND hwnd) {   // name -> [pid, hwnd] (REG_BINARY, 16 bytes)
    unsigned long long v[2] = { GetCurrentProcessId(), (unsigned long long)(uintptr_t)hwnd };
    RegSetKeyValueW(HKEY_CURRENT_USER, kInstKey, g_instance.c_str(), REG_BINARY, v, sizeof v);
}
static void retractInstance() {
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kInstKey, 0, KEY_SET_VALUE, &k) == ERROR_SUCCESS) {
        RegDeleteValueW(k, g_instance.c_str());
        RegCloseKey(k);
    }
}
struct InstanceInfo { std::wstring name; DWORD pid; HWND hwnd; };
static std::vector<InstanceInfo> listInstances() {   // live entries only; stale ones are pruned
    std::vector<InstanceInfo> out;
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kInstKey, 0, KEY_READ | KEY_SET_VALUE, &k) != ERROR_SUCCESS) return out;
    wchar_t name[128]; BYTE data[16];
    std::vector<std::wstring> stale;
    for (DWORD i = 0;; i++) {
        DWORD nl = 128, dl = sizeof data, type = 0;
        LONG r = RegEnumValueW(k, i, name, &nl, nullptr, &type, data, &dl);
        if (r == ERROR_NO_MORE_ITEMS) break;
        if (r != ERROR_SUCCESS || type != REG_BINARY || dl != 16) continue;
        unsigned long long pid = *(unsigned long long*)data, hw = *(unsigned long long*)(data + 8);
        HWND hwnd = (HWND)(uintptr_t)hw;
        bool alive = IsWindow(hwnd);
        if (alive) {   // confirm the pid still owns it (guards against hwnd reuse)
            DWORD wp = 0; GetWindowThreadProcessId(hwnd, &wp);
            alive = (wp == (DWORD)pid);
        }
        if (alive) out.push_back({ name, (DWORD)pid, hwnd });
        else stale.push_back(name);
    }
    for (const auto& s : stale) RegDeleteValueW(k, s.c_str());
    RegCloseKey(k);
    return out;
}
static const InstanceInfo* findInstance(const std::vector<InstanceInfo>& v, const std::wstring& sel) {
    if (sel.empty() || sel == L"active") {
        for (const auto& e : v) if (e.hwnd == g_hwnd) return &e;   // "active" = this instance
        return nullptr;
    }
    for (const auto& e : v) if (lstrcmpiW(e.name.c_str(), sel.c_str()) == 0) return &e;
    return nullptr;
}

// ---- sessions & layout ----
// Epoch seconds, the unit `statusChangedAt` is published in (agwinterm: DateTimeOffset.UtcNow
// .ToUnixTimeSeconds()). Not milliseconds, not ticks: a caller subtracts it from its own clock.
static long long epochNow() { return (long long)time(nullptr); }

struct Session {
    std::string id;
    std::string status = "idle";   // control-API agent status (sidebar dot)
    // When `status` was last WRITTEN (epoch seconds), reported on every `tree` node as
    // statusChangedAt. Seeded at construction, so a session whose status was never set reports its
    // own age rather than 0 — and since status is not persisted, a restored session is constructed
    // fresh and gets a fresh stamp: a stamp from a previous run would describe a hook that is not
    // running. Stamped again on EVERY write, whoever writes: go through setStatus, never assign
    // status directly (see the session.status verb for why every write, not every change).
    long long statusChangedAt = epochNow();
    std::wstring name;             // custom name (rename); empty = "session N"
    // session.context (P3): one line of "what is this pane for", set over the API, drawn dimmed
    // after the name in the sidebar row, carried by `tree --json` as "context" only when set,
    // persisted as a `C` line. Empty = none. Separate from `name`: a rename leaves it alone and a
    // context never enters the label. The rules are contextRefusal's (agwinterm's SessionContexts).
    std::wstring context;
    int ws = 0;                    // workspace this session belongs to (index into g_workspaces)
    // The id of THIS session's right-hand terminal, empty when it has none. A split belongs to the
    // session, not to the window: switching sessions shows that session's split (or no split), the
    // way panes work in the full app. Held by id rather than index because g_sessions shifts under
    // every close. Only a visible session owns one; the shell it names is hidden.
    std::string splitId;
    bool flagged = false;          // user-flagged (working set); amber pennant in the tree, persisted
    int seenDone = 0;              // completed-command (FTCS) count when the session was last visible
    int unread = 0;                // commands finished while NOT visible — red count pill in the tree
    bool hidden = false;          // split-pane shell: a real shell, but NOT a sidebar/tree session
    std::string app, cwd;          // launch spec, remembered so the session can be restored on next launch
    std::vector<std::string> args; // ("" app = default PowerShell; empty args = wrap/bare per app)
    DWORD childPid = 0;            // shell pid from the attach reply (live-cwd query for restore)
    void* emu = nullptr;
    HANDLE data = INVALID_HANDLE_VALUE;
    HANDLE reader = nullptr;
    int cols = 0, rows = 0;     // geometry last pushed to the host (0 = never sized yet)
    int scrollOff = 0;          // rows scrolled up into history (0 = live)
    bool exited = false;
    // Refusals in ONE episode of chasing a resize on the timer — not refusals ever. The retry timer
    // is armed from the rollback, and a host that keeps refusing would otherwise make that a 60 ms
    // forever-loop: a synchronous round trip per pane and popup sixteen times a second, each writing
    // a log line that opens, appends to and closes the file (revmux r5). An episode ends at an
    // accepted resize, or at the next real layout request that REACHES the decide block — one that
    // is demoted to the timer carries `resizeWanted` so it still counts as real. Only the automatic
    // chasing stops; a drag after a give-up starts a new episode and is heard again.
    int resizeRefusals = 0;
    // Set when the UI thread hands a REAL layout event (a drag, a select, a font change) to the
    // relayout timer because g_resizeLock was busy. The timer cannot tell its two owners apart —
    // lock contention and a refusal backoff both arm the same id — so without this the sweep looks
    // like an automatic retry, and a session that had given up dropped the user's resize in silence
    // (revmux r8). Consumed by the attempt that follows.
    bool resizeWanted = false;
    // Restore placeholder: this spec's app would not start on THIS machine, so there is no shell
    // behind it. The entry is kept anyway (empty id, exited) so the name/workspace/cwd/args survive
    // instead of vanishing — a failed spec used to be dropped, and the user was never told.
    bool failed = false;
    std::vector<FfiCell> grid;  // paint snapshot buffer
    std::vector<FfiCell> hrow;
    // Scrollback eviction, counted so a SELECTION can survive it. Buffer-absolute rows renumber
    // when the core drops the oldest history lines, and a selection that ignores that silently
    // covers different text than the one highlighted — you would paste something you never
    // selected. The reader thread maintains these under g_lock; nothing else writes them.
    int64_t lastGen = 0;        // scrollGeneration last seen (one per line pushed into history)
    int64_t lastHist = 0;       // historyCount last seen; scrolled-but-not-kept == evicted
    int64_t evicted = 0;        // total lines dropped off the front of this session's history
};

// Session::status is a std::string written from control-pipe threads (the session.status verb)
// AND the UI thread (the Esc/Ctrl+C clear), and read from both (tree replies on pipe threads, the
// sidebar and its custom-draw on the UI thread). g_lock deliberately does not cover it (it guards
// the emulators and the list shape), so it has its own section, like the event log has g_evtLock.
// Short values live in the small-string buffer and never reallocate, which is why an unlocked
// `waiting-for-user-approval` written under a concurrent `tree` was a use-after-free nobody had
// hit yet. Every read goes through statusOf(); the stamp rides along so the pair is a snapshot.
static CRITICAL_SECTION g_statusLock;
struct StatusSnap { std::string status; long long changedAt; };
static StatusSnap statusOf(const Session* s) {
    EnterCriticalSection(&g_statusLock);
    StatusSnap r{ s->status, s->statusChangedAt };
    LeaveCriticalSection(&g_statusLock);
    return r;
}
// The ONLY writer of Session::status. Stamps statusChangedAt on EVERY write, including a re-assert
// of the same status. This is not a bug: the question callers ask of statusChangedAt is "is this
// agent's hook still alive", and a hook re-asserting `active` every 30 s is precisely the liveness
// signal - collapsing repeats would report the age of the FIRST write and make a healthy agent
// look dead. agwinterm stamps the same way through its one entry point (TerminalSession.SetStatus:
// "every write, not every change"); a second bare `s->status =` here is how the two drift apart.
// (clearWorkingStatus below decides under the lock and then calls this - not a second writer.)
static void setStatus(Session* s, const std::string& st) {
    EnterCriticalSection(&g_statusLock);
    s->status = st;
    s->statusChangedAt = epochNow();
    LeaveCriticalSection(&g_statusLock);
}

// Agent status classification for the sidebar: BLOCKED = agent needs you (bold name),
// WORKING = agent busy (italic name + "(working…)"), NONE = plain.
enum { AGST_NONE, AGST_WORKING, AGST_BLOCKED };
static int statusClass(const std::string& s) {
    if (s == "working" || s == "busy" || s == "active" || s == "running") return AGST_WORKING;
    if (s == "blocked" || s == "waiting" || s == "attention" || s == "input") return AGST_BLOCKED;
    return AGST_NONE;
}
// The user-interrupt clear (Esc / Ctrl+C typed into the pane): idle ONLY IF the status is still
// working-class, decided and written under one hold. As a statusOf() check followed by setStatus()
// a hook's `blocked` landing between the two would have been overwritten with idle - the one
// transition the policy says must not happen. The write itself still goes through setStatus (the
// section is recursive), so that stays the one writer. Returns whether anything was written.
static bool clearWorkingStatus(Session* s) {
    EnterCriticalSection(&g_statusLock);
    bool cleared = statusClass(s->status) == AGST_WORKING;
    if (cleared) setStatus(s, "idle");
    LeaveCriticalSection(&g_statusLock);
    return cleared;
}
static HFONT g_treeItalic;      // italic variant of the sidebar font (agent "working" rows)
// Quick + scratch terminals: modal-ish popup windows, each hosting a dedicated (hidden) session. The
// overlay is a scratch that runs a one-shot command. g_focusOverride redirects input/paint focus to a
// popup's session while it's active.
static HWND g_quickHwnd, g_scratchHwnd, g_overlayHwnd;
static Session* g_quickSession, *g_scratchSession, *g_overlaySession, *g_focusOverride;
static HWND g_toolbar;          // native toolbar (New Session / New Workspace / Split)
static int g_toolbarH = 0;      // its height; the tree + terminal start below it
static HWND g_status;           // native status bar (msctls_statusbar32)
static int g_statusH = 0;       // its height; the terminal ends above it
// Effective chrome extents (respect the View toggles): content sits between these.
static int sidebarSpan() { return g_showSidebar ? g_sidebarW + kSplitterW : 0; }
static int toolbarTop()  { return g_showToolbar ? g_toolbarH : 0; }
static bool g_splitDrag = false;   // dragging the sidebar splitter
static bool g_treeDrag = false;    // dragging a session row in the sidebar (drag & drop)
static int  g_dragIdx = -1;        // session index being dragged
static HIMAGELIST g_dragImg = nullptr;   // TreeView_CreateDragImage ghost
static int  g_armIdx = -1;         // session under a fresh left-press (drag candidate)
static POINT g_armPt{};            // where that press landed (drag threshold)
static HTREEITEM g_armItem = nullptr;
static void relayout() {   // re-run the WM_SIZE layout + repaint after a toggle / splitter drag
    RECT c; GetClientRect(g_hwnd, &c);
    SendMessageW(g_hwnd, WM_SIZE, SIZE_RESTORED, MAKELPARAM(c.right, c.bottom));
    InvalidateRect(g_hwnd, nullptr, TRUE);
}
static bool inSplitter(int x, int y) {
    if (!g_showSidebar) return false;
    RECT c; GetClientRect(g_hwnd, &c);
    return x >= g_sidebarW && x < g_sidebarW + kSplitterW && y >= toolbarTop() && y < c.bottom - (g_showStatus ? g_statusH : 0);
}
static HIMAGELIST g_tbImages;   // 16x16 toolbar glyphs, drawn per theme (see drawToolbarGlyph)
static HWND g_tree;             // native SysTreeView32 sidebar (sessions)
static bool g_treeSyncing;      // suppress TVN_SELCHANGED while we rebuild the tree
static bool g_treeRenaming;     // an inline rename is starting: let the tree hold the keyboard
static bool g_restoring;         // true while rebuilding sessions at startup (suppresses state saves)
static bool g_userEmptied;      // the user closed the LAST session: the one legitimate zero-session save
static HTREEITEM g_ctxItem;     // right-clicked tree node (for the context menu)
static LPARAM g_ctxParam;       // its lParam: >=0 session index, <0 = -(workspace+1)
static HFONT g_fonts[4];        // [bold][italic]
static std::wstring g_ttFace;   // the bundled TrueType face (Meslo Nerd, or Consolas fallback)
// A font catalog entry: a face + the sizes it offers (cmd.exe-style face list + size dropdown).
// kind: 0 = scalable TrueType (antialiased), 1 = raster .fon (OEM charset, crisp), 2 = bitmap-embedded
// TrueType (crisp, exact strike). Size {h,w}: raster/bitmap use positive px (w 0 = auto); scalable uses
// negative h (point-ish) with w 0.
// face: per-size family override for fonts that ship one family PER strike (Spleen 8x16 / unscii-8...).
struct FontSize { const wchar_t* label; int h, w; const wchar_t* face = nullptr; };
struct FontEntry { const wchar_t* label; const wchar_t* face; int kind; bool avail; std::vector<FontSize> sizes; };
static std::vector<FontEntry> g_catalog;
static int g_faceIdx = 0, g_sizeIdx = 0;   // current selection into g_catalog
static bool g_haveCozette = false, g_haveTamzen = false;   // bundled bitmap fonts actually loaded
static bool g_haveTerminus = false, g_haveSpleen = false, g_haveUnscii = false, g_haveUnifont = false;
static bool g_haveAgbf = false;     // agwin-bitmap-16.agbf found next to the exe
static bool g_haveAgbfC = false;    // agwin-bitmap-complete-16.agbf found next to the exe
static HFONT g_uiFont;          // shell UI font (Segoe UI) for the toolbar buttons
static HFONT g_treeFont;        // sidebar font — the shell UI face at g_treeFontPt (0 = system size)
static int   g_treeFontPt = 0;  // sidebar point size; 0 means "whatever the shell says", the default
static bool g_customColors = false;   // Properties->Colors: override the terminal's default fg/bg
static uint32_t g_defFg = 0xC0C0C0;   // packed 0xRRGGBB, legacy cmd.exe light gray on...
static uint32_t g_defBg = 0x000000;   // ...black
static bool g_dosPalette = true;      // Properties->Colors: remap ANSI indices to the muted EGA/VGA DOS palette

// Caret state. A terminal cursor has to say two things: "input lands here" (blink) and "this window
// has focus" (solid vs hollow). lite drew a static invert regardless, so switching sessions or
// windows gave no cue at all that typing had moved. kCaretBlinkMs matches the main app's default
// cursor-blink-ms. lite runs two timers: this one, always, and kRelayoutTimer, armed on demand.
static bool g_winFocused = true;      // frame has keyboard focus (solid caret) vs not (hollow)
static bool g_caretOn = true;         // blink phase
static const UINT_PTR kCaretTimer = 1;
// The relayout retry (see hostResize) — lite's SECOND timer, beside the caret blink. A ONE-SHOT
// timer, not a posted message: a posted retry
// outranks paint and input and re-posts itself from its own handler, so while a control-pipe thread
// held g_resizeLock the UI thread spun at 100 % CPU painting nothing and accepting no keystrokes —
// strictly worse than the dropped resize it was fixing, and unbounded when the host is wedged
// (#27). WM_TIMER is delivered only when the queue is empty, so the loop idles between attempts.
static const UINT_PTR kRelayoutTimer = 2;
static const UINT kRelayoutRetryMs = 60;
// How many times in a row a REFUSED resize re-arms the timer before it gives up (60, 120, 240 ms).
// The lock-contention retry is bounded by the lock freeing; a refusing host is not bounded by
// anything, so it needs a count of its own (revmux r5).
static const int kResizeRetryAttempts = 3;
static const UINT kCaretBlinkMs = 530;

// ---- UI theme (Properties -> Appearance) -----------------------------------------------------
// Four modes. CLASSIC means "hands off": every control keeps whatever the OS draws, which is the
// look lite shipped with. DARK/LIGHT paint the chrome ourselves (comctl32 will not do it for us).
// AUTO follows the Windows "app mode" setting and re-resolves on WM_SETTINGCHANGE.
enum { TH_AUTO = 0, TH_DARK = 1, TH_LIGHT = 2, TH_CLASSIC = 3 };
static int g_themeMode = TH_AUTO;     // persisted as "Theme"
struct UiTheme {
    bool     dark;      // drives the DWM title bar + which control themes we ask for
    bool     classic;   // true = don't custom-draw anything, let the system do it
    COLORREF bar;       // toolbar / status bar / menu bar background
    COLORREF client;    // deepest surface (tree background)
    COLORREF text;      // normal label text
    COLORREF dim;       // secondary text
    COLORREF hot;       // hover fill
    COLORREF sel;       // selected row fill
    COLORREF accent;    // focus / hot border
    COLORREF border;    // separators, grooves
    uint32_t termFg;    // terminal default foreground (packed 0xRRGGBB)
    uint32_t termBg;    // terminal default background
};
static UiTheme g_th;
static HBRUSH g_thBrBar = nullptr, g_thBrClient = nullptr;   // cached theme brushes (dialog surfaces)

// Windows "Choose your mode" -> Dark returns 0 here.
static bool systemUsesDarkApps() {
    DWORD v = 1, sz = sizeof v;
    if (RegGetValueW(HKEY_CURRENT_USER,
                     L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &v, &sz) != ERROR_SUCCESS) return false;
    return v == 0;
}
static bool themeIsDark() { return g_themeMode == TH_DARK || (g_themeMode == TH_AUTO && systemUsesDarkApps()); }

static void resolveTheme() {
    UiTheme t{};
    t.classic = (g_themeMode == TH_CLASSIC);
    t.dark    = !t.classic && themeIsDark();
    if (t.classic) {                      // whatever the OS uses for dialogs/controls
        t.bar = GetSysColor(COLOR_BTNFACE);   t.client = GetSysColor(COLOR_WINDOW);
        t.text = GetSysColor(COLOR_BTNTEXT);  t.dim    = GetSysColor(COLOR_GRAYTEXT);
        t.hot = GetSysColor(COLOR_BTNHIGHLIGHT); t.sel  = GetSysColor(COLOR_HIGHLIGHT);
        t.accent = GetSysColor(COLOR_HIGHLIGHT); t.border = GetSysColor(COLOR_BTNSHADOW);
        t.termFg = 0xC0C0C0; t.termBg = 0x000000;   // the terminal itself stays a terminal
    } else if (t.dark) {
        t.bar = RGB(45,45,48); t.client = RGB(30,30,30);
        t.text = RGB(241,241,241); t.dim = RGB(150,150,150);
        t.hot = RGB(62,62,64); t.sel = RGB(38,79,120);
        t.accent = RGB(0,122,204); t.border = RGB(63,63,70);
        t.termFg = 0xC0C0C0; t.termBg = 0x000000;
    } else {
        t.bar = RGB(240,240,240); t.client = RGB(255,255,255);
        t.text = RGB(26,26,26); t.dim = RGB(110,110,110);
        t.hot = RGB(229,243,255); t.sel = RGB(205,232,255);
        t.accent = RGB(0,120,215); t.border = RGB(205,205,205);
        t.termFg = 0xC0C0C0; t.termBg = 0x000000;
    }
    g_th = t;
    if (g_thBrBar) DeleteObject(g_thBrBar);
    if (g_thBrClient) DeleteObject(g_thBrClient);
    g_thBrBar = CreateSolidBrush(t.bar);
    g_thBrClient = CreateSolidBrush(t.client);
}
// Terminal defaults: an explicit Properties override always wins over the theme.
static uint32_t themeFg() { return g_customColors ? g_defFg : g_th.termFg; }
static uint32_t themeBg() { return g_customColors ? g_defBg : g_th.termBg; }

// Undocumented uxtheme entry points (Win10 1903+), exported by ordinal only. These are what File
// Explorer itself uses; opting the process into dark mode is what makes USER32 draw the MENU BAR and
// popup menus dark, and gives the tree dark scrollbars. Resolved defensively: absent = no-op.
namespace darkmode {
    enum PreferredAppMode { Default_, AllowDark, ForceDark, ForceLight, Max_ };
    typedef PreferredAppMode (WINAPI* fnSetPreferredAppMode)(PreferredAppMode);
    typedef BOOL (WINAPI* fnAllowDarkModeForWindow)(HWND, BOOL);
    typedef void (WINAPI* fnFlushMenuThemes)();
    typedef void (WINAPI* fnRefreshImmersiveColorPolicyState)();
    static fnSetPreferredAppMode    pSetPreferredAppMode    = nullptr;
    static fnAllowDarkModeForWindow pAllowDarkModeForWindow = nullptr;
    static fnFlushMenuThemes        pFlushMenuThemes        = nullptr;
    static fnRefreshImmersiveColorPolicyState pRefreshImmersive = nullptr;
    static void resolve() {
        static bool done = false; if (done) return; done = true;
        HMODULE ux = GetModuleHandleW(L"uxtheme.dll");
        if (!ux) ux = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!ux) return;
        pSetPreferredAppMode    = (fnSetPreferredAppMode)   GetProcAddress(ux, MAKEINTRESOURCEA(135));
        pAllowDarkModeForWindow = (fnAllowDarkModeForWindow)GetProcAddress(ux, MAKEINTRESOURCEA(133));
        pFlushMenuThemes        = (fnFlushMenuThemes)       GetProcAddress(ux, MAKEINTRESOURCEA(136));
        pRefreshImmersive       = (fnRefreshImmersiveColorPolicyState)GetProcAddress(ux, MAKEINTRESOURCEA(104));
    }
    static void setAppMode(int mode) {   // TH_* -> process-wide app mode
        resolve();
        if (pSetPreferredAppMode)
            pSetPreferredAppMode(mode == TH_CLASSIC ? Default_ : (themeIsDark() ? ForceDark : ForceLight));
        if (pRefreshImmersive) pRefreshImmersive();   // without this the DarkMode_* styles don't render
        if (pFlushMenuThemes) pFlushMenuThemes();
    }
    static void allowWindow(HWND h, bool dark) {
        resolve();
        if (pAllowDarkModeForWindow && h) pAllowDarkModeForWindow(h, dark ? TRUE : FALSE);
    }
}

static void darkTitleBar(HWND h, bool dark) {
    if (!h) return;
    BOOL v = dark ? TRUE : FALSE;
    if (FAILED(DwmSetWindowAttribute(h, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, &v, sizeof v)))
        DwmSetWindowAttribute(h, 19, &v, sizeof v);   // older Win10 builds used attribute 19
}

// ---- dark menu bar (WM_UAH*) ------------------------------------------------------------------
// The process dark-mode opt-in themes popup MENUS, but USER32 never themes the menu BAR. The
// undocumented WM_UAH* messages are the hook Explorer/Notepad++ use to custom-draw it while keeping
// native behaviour (checkmarks, accelerators, keyboard navigation) everywhere else.
#define WM_UAHDRAWMENU        0x0091
#define WM_UAHDRAWMENUITEM    0x0092
typedef union  { struct { DWORD cx, cy; } rgSizes[2]; } UAHMENUITEMMETRICS;
typedef struct { DWORD rgcx[4]; DWORD fUpdateMaxWidths : 2; } UAHMENUPOPUPMETRICS;
typedef struct { HMENU hmenu; HDC hdc; DWORD dwFlags; } UAHMENU;
typedef struct { int iPosition; UAHMENUITEMMETRICS umim; UAHMENUPOPUPMETRICS umpm; } UAHMENUITEM;
typedef struct { DRAWITEMSTRUCT dis; UAHMENU um; UAHMENUITEM umi; } UAHDRAWMENUITEM;

// USER32 also paints a light 3-pixel 3-D edge UNDER the menu bar, in the non-client area, that the
// UAH draw never covers — overpaint it after every non-client paint while a themed look is active.
static void themeMenuSeam(HWND h) {
    if (!GetMenu(h)) return;
    RECT wr, cr; POINT cp{ 0, 0 };
    GetWindowRect(h, &wr); GetClientRect(h, &cr); ClientToScreen(h, &cp);
    RECT strip{ cp.x - wr.left, 0, 0, cp.y - wr.top };
    strip.right = strip.left + cr.right;
    strip.top = strip.bottom - 4;
    MENUBARINFO mbi{ sizeof mbi };
    if (GetMenuBarInfo(h, OBJID_MENU, 0, &mbi)) {
        int b = mbi.rcBar.bottom - wr.top;
        if (b < strip.bottom && b > 0) strip.top = b;
    }
    if (strip.top >= strip.bottom) return;
    if (HDC dc = GetWindowDC(h)) {
        HBRUSH br = CreateSolidBrush(g_th.bar);
        FillRect(dc, &strip, br);
        DeleteObject(br);
        ReleaseDC(h, dc);
    }
}

// ---- themed dialogs ---------------------------------------------------------------------------
// The hand-built dialogs (Properties / Keyboard / New Session) are plain windows, so dark mode is:
// dark title bar, DarkMode_* visual styles on the children (buttons/lists/combos/scrollbars), and
// WM_CTLCOLOR* + WM_ERASEBKGND answered with theme brushes. Light/Classic keep the system look.
static BOOL CALLBACK themeDlgChild(HWND c, LPARAM) {
    wchar_t cls[32]{};
    GetClassNameW(c, cls, 32);
    darkmode::allowWindow(c, g_th.dark);
    // Dark gets the DarkMode_* styles (v6 manifest makes them real — incl. dark scrollbars on the
    // list boxes); light/classic strip so the dialogs keep their pre-v6 look exactly.
    if (!lstrcmpW(cls, L"ComboBox")) {
        if (g_th.dark) SetWindowTheme(c, L"DarkMode_CFD", nullptr); else SetWindowTheme(c, L"", L"");
    } else if (!lstrcmpW(cls, L"Button") || !lstrcmpW(cls, L"ListBox") || !lstrcmpW(cls, L"ScrollBar") ||
               !lstrcmpW(cls, L"Edit")) {
        if (g_th.dark) SetWindowTheme(c, L"DarkMode_Explorer", nullptr); else SetWindowTheme(c, L"", L"");
    }
    else if (!lstrcmpW(cls, L"msctls_hotkey32")) {
        SetWindowTheme(c, L"", L"");   // classic engine in every mode; dark fully custom-paints it
        // dark hotkeys are fully custom-painted (see hotkeyProc); swap the light system WS_BORDER
        // for the painted one so no bright frame remains
        LONG st = (LONG)GetWindowLongPtrW(c, GWL_STYLE);
        LONG want = (g_th.dark && !g_th.classic) ? (st & ~WS_BORDER) : (st | WS_BORDER);
        if (want != st) {
            SetWindowLongPtrW(c, GWL_STYLE, want);
            SetWindowPos(c, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
    }
    InvalidateRect(c, nullptr, TRUE);
    return TRUE;
}
static void themeDialog(HWND dlg) {
    if (!dlg) return;
    darkmode::allowWindow(dlg, g_th.dark);
    darkTitleBar(dlg, g_th.dark);
    EnumChildWindows(dlg, themeDlgChild, 0);
    InvalidateRect(dlg, nullptr, TRUE);
}
// Owner-drawn dialog buttons (push / checkbox / radio) + combo paint — see drawDlgButton below.
// Without a comctl32 v6 manifest these are v5/user32 classic controls: DarkMode_* styles cannot
// render on them, so the themed looks draw them by hand; Classic uses DrawFrameControl, which is
// the exact classic renderer, so nothing changes there.
static void drawDlgButton(LPDRAWITEMSTRUCT d);
static LRESULT CALLBACK comboProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR);

// Shared message handling for the dialog procs; returns true (with *r set) when the theme answered.
static bool themeDlgMsg(HWND h, UINT m, WPARAM w, LRESULT* r) {
    if (!g_th.dark || g_th.classic) return false;
    HDC dc = (HDC)w;
    switch (m) {
        case WM_ERASEBKGND: {
            RECT rc; GetClientRect(h, &rc);
            FillRect(dc, &rc, g_thBrBar);
            *r = 1; return true;
        }
        case WM_CTLCOLORSTATIC:   // also checkboxes/radios (non-push buttons report as STATIC)
        case WM_CTLCOLORBTN:
            SetTextColor(dc, g_th.text); SetBkColor(dc, g_th.bar);
            *r = (LRESULT)g_thBrBar; return true;
        case WM_CTLCOLORLISTBOX:
        case WM_CTLCOLOREDIT:
            SetTextColor(dc, g_th.text); SetBkColor(dc, g_th.client);
            *r = (LRESULT)g_thBrClient; return true;
    }
    return false;
}

// ---- dark hotkey fields -----------------------------------------------------------------------
// msctls_hotkey32 never sends WM_CTLCOLOR* and ignores SetWindowTheme, so dark mode takes over its
// WM_PAINT outright: dark field, themed border (accent when focused), and the binding text redrawn
// from HKM_GETHOTKEY (same names the control itself would show).
static LRESULT CALLBACK hotkeyProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
    if (m == WM_NCDESTROY) RemoveWindowSubclass(h, hotkeyProc, id);
    if (g_th.dark && !g_th.classic) {
        if (m == WM_NCPAINT) {   // the classic WS_BORDER ring is drawn here — paint it dark instead
            if (HDC dc = GetWindowDC(h)) {
                RECT wr; GetWindowRect(h, &wr);
                RECT r{ 0, 0, wr.right - wr.left, wr.bottom - wr.top };
                FrameRect(dc, &r, g_thBrClient);   // outer ring matches the field; painted border inside
                ReleaseDC(h, dc);
            }
            return 0;
        }
        if (m == WM_ERASEBKGND) return 1;
        if (m == WM_SETFOCUS || m == WM_KILLFOCUS) InvalidateRect(h, nullptr, TRUE);   // focus ring
        if (m == WM_PAINT) {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(h, &ps);
            RECT rc; GetClientRect(h, &rc);
            FillRect(dc, &rc, g_thBrClient);
            HBRUSH fr = CreateSolidBrush(GetFocus() == h ? g_th.accent : g_th.border);
            FrameRect(dc, &rc, fr); DeleteObject(fr);
            WORD hk = (WORD)SendMessageW(h, HKM_GETHOTKEY, 0, 0);
            std::wstring txt;
            if (!hk) txt = L"None";
            else {
                BYTE mod = HIBYTE(hk), vk = LOBYTE(hk);
                if (mod & HOTKEYF_CONTROL) txt += L"Ctrl + ";
                if (mod & HOTKEYF_SHIFT)   txt += L"Shift + ";
                if (mod & HOTKEYF_ALT)     txt += L"Alt + ";
                UINT sc = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC) << 16;
                if (mod & HOTKEYF_EXT) sc |= 0x01000000;
                wchar_t name[64]{};
                txt += (GetKeyNameTextW((LONG)sc, name, 64) > 0) ? name : L"?";
            }
            HFONT of = g_uiFont ? (HFONT)SelectObject(dc, g_uiFont) : nullptr;
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, hk ? g_th.text : g_th.dim);
            RECT tr = rc; tr.left += 6;
            DrawTextW(dc, txt.c_str(), -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
            if (of) SelectObject(dc, of);
            EndPaint(h, &ps);
            return 0;
        }
    }
    return DefSubclassProc(h, m, w, l);
}

// ---- dark field bezels ------------------------------------------------------------------------
// v5 listboxes draw their WS_BORDER / WS_EX_CLIENTEDGE bezel with classic system colours that no
// theme reaches. Let the default NC paint run (it also draws the scrollbar), then repaint the outer
// bezel rings dark. Classic/light leave the system bezel alone.
static LRESULT CALLBACK fieldRingProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
    if (m == WM_NCDESTROY) RemoveWindowSubclass(h, fieldRingProc, id);
    if (m == WM_NCPAINT && g_th.dark && !g_th.classic) {
        LRESULT r = DefSubclassProc(h, m, w, l);   // border + scrollbar first
        if (HDC dc = GetWindowDC(h)) {
            RECT wr; GetWindowRect(h, &wr);
            RECT rc{ 0, 0, wr.right - wr.left, wr.bottom - wr.top };
            HBRUSH br = CreateSolidBrush(g_th.border);
            FrameRect(dc, &rc, br);                              // outer ring
            DWORD ex = (DWORD)GetWindowLongPtrW(h, GWL_EXSTYLE);
            if (ex & WS_EX_CLIENTEDGE) {                          // client edge is 2px deep
                InflateRect(&rc, -1, -1);
                HBRUSH in = CreateSolidBrush(g_th.client);
                FrameRect(dc, &rc, in);
                DeleteObject(in);
            }
            DeleteObject(br);
            ReleaseDC(h, dc);
        }
        return r;
    }
    return DefSubclassProc(h, m, w, l);
}

// ---- dark status bar --------------------------------------------------------------------------
// The native status bar ignores colour requests entirely; a full WM_PAINT takeover (via comctl32
// subclassing) is the only clean way. Reads the theme at paint time, so switching just repaints.
static LRESULT CALLBACK statusProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
    if (m == WM_NCDESTROY) RemoveWindowSubclass(h, statusProc, id);
    if (g_th.dark && !g_th.classic) {
        if (m == WM_ERASEBKGND) return 1;
        if (m == WM_PAINT) {
            InvalidateRect(h, nullptr, FALSE);   // repaint whole bar (comctl32 invalidates only the changed part)
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(h, &ps);
            RECT rc; GetClientRect(h, &rc);
            HBRUSH chrome = CreateSolidBrush(g_th.bar), border = CreateSolidBrush(g_th.border);
            FillRect(dc, &rc, chrome);
            RECT line{ rc.left, rc.top, rc.right, rc.top + 1 };
            FillRect(dc, &line, border);   // hairline against the terminal
            int edges[8];
            int n = (int)SendMessageW(h, SB_GETPARTS, 8, (LPARAM)edges);
            HFONT of = g_uiFont ? (HFONT)SelectObject(dc, g_uiFont) : nullptr;
            SetBkMode(dc, TRANSPARENT); SetTextColor(dc, g_th.text);
            for (int i = 0; i < n; i++) {
                wchar_t buf[256]{};
                SendMessageW(h, SB_GETTEXTW, i, (LPARAM)buf);
                int x0 = i ? edges[i - 1] : 0, x1 = edges[i];
                if (x1 < 0 || x1 > rc.right) x1 = rc.right;
                RECT tr{ x0 + 7, rc.top + 2, x1 - 4, rc.bottom };
                DrawTextW(dc, buf, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
                if (i < n - 1) { RECT sep{ x1, rc.top + 4, x1 + 1, rc.bottom - 3 }; FillRect(dc, &sep, border); }
            }
            if (of) SelectObject(dc, of);
            DeleteObject(chrome); DeleteObject(border);
            EndPaint(h, &ps);
            return 0;
        }
    }
    return DefSubclassProc(h, m, w, l);
}

static void buildToolbarImages();   // fwd — the image list is re-flattened per theme

// Re-theme every live window/control. Safe to call before the frame exists (all handles null-checked).
static void applyTheme() {
    resolveTheme();
#ifdef AGW_THEME_DEBUG
    { FILE* f = nullptr; _wfopen_s(&f, L"C:\\Users\\boris\\AppData\\Local\\Temp\\lite-theme.txt", L"a");
      if (f) { fwprintf(f, L"mode=%d dark=%d classic=%d tree=%p hwnd=%p client=%06X\n",
                        g_themeMode, (int)g_th.dark, (int)g_th.classic, (void*)g_tree, (void*)g_hwnd,
                        (unsigned)g_th.client); fclose(f); } }
#endif
    darkmode::setAppMode(g_themeMode);                     // menu bar + popup menus follow this
    for (HWND h : { g_hwnd, g_quickHwnd, g_scratchHwnd, g_overlayHwnd }) {
        if (!h) continue;
        darkmode::allowWindow(h, g_th.dark);
        darkTitleBar(h, g_th.dark);
    }
    if (g_tree) {
        darkmode::allowWindow(g_tree, g_th.dark);
        // Dark rides the native DarkMode_Explorer theme (dark rows, dark SCROLLBAR); light keeps the
        // stripped-style look with our colours; Classic strips too — an untheme'd v6 control paints
        // with the classic engine, so Classic stays exactly the old no-manifest look.
        if (g_th.dark) SetWindowTheme(g_tree, L"DarkMode_Explorer", nullptr);
        else SetWindowTheme(g_tree, L"", L"");
        TreeView_SetBkColor(g_tree,   g_th.classic ? (COLORREF)-1 : g_th.client);
        TreeView_SetTextColor(g_tree, g_th.classic ? (COLORREF)-1 : g_th.text);
        TreeView_SetLineColor(g_tree, g_th.classic ? (COLORREF)-1 : g_th.border);
        // The sunken WS_EX_CLIENTEDGE is drawn with light system colours — drop it on dark.
        DWORD ex = (DWORD)GetWindowLongPtrW(g_tree, GWL_EXSTYLE);
        DWORD want = g_th.dark ? (ex & ~WS_EX_CLIENTEDGE) : (ex | WS_EX_CLIENTEDGE);
        if (want != ex) {
            SetWindowLongPtrW(g_tree, GWL_EXSTYLE, want);
            SetWindowPos(g_tree, nullptr, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
        InvalidateRect(g_tree, nullptr, TRUE);
    }
    if (g_toolbar) {
        // v6 would theme the toolbar's default painting — strip it outside dark so Classic keeps the
        // raised 3-D buttons (an untheme'd v6 control uses the classic engine); themed modes are
        // fully owner-drawn anyway.
        SetWindowTheme(g_toolbar, g_th.dark ? nullptr : L"", g_th.dark ? nullptr : L"");
        // The classic toolbar draws a #A0A0A0/#FFFFFF 3-D divider at its top — THE white line under
        // the menu on dark. Themed looks drop it (CCS_NODIVIDER); Classic keeps its classic groove.
        LONG st = (LONG)GetWindowLongPtrW(g_toolbar, GWL_STYLE);
        LONG want = g_th.classic ? (st & ~CCS_NODIVIDER) : (st | CCS_NODIVIDER);
        if (want != st) {
            SetWindowLongPtrW(g_toolbar, GWL_STYLE, want);
            SetWindowPos(g_toolbar, nullptr, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
        buildToolbarImages();   // re-flatten the PNG icons against the new bar colour
    }
    if (g_status) {
        SetWindowTheme(g_status, L"", L"");   // always classic-engine: dark own-paints, light/classic keep the old bar
        InvalidateRect(g_status, nullptr, TRUE);
    }
    if (g_hwnd) {
        DrawMenuBar(g_hwnd);
        RedrawWindow(g_hwnd, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_FRAME);
    }
}
// Configurable key bindings for every lite action. ALL UNBOUND BY DEFAULT so no combo is stolen from
// the shell/TUI until the user assigns one in File -> Keyboard. Stored HOTKEY-format: LOBYTE = vk,
// HIBYTE = HOTKEYF_* (SHIFT 1 / CONTROL 2 / ALT 4). 0 = unbound.
enum { KB_NEW, KB_NEWWS, KB_CLOSE, KB_SPLIT, KB_NEXT, KB_PREV, KB_COPY, KB_PASTE,
       KB_PALETTE, KB_FOCUSL, KB_FOCUSR, KB_SCROLLUP, KB_SCROLLDN, KB_QUICK, KB_SCRATCH, KB_REOPEN,
       KB_FLAG, KB_FLAGVIEW, KB_ATTENTION, KB_FOCUSWS, KB_COUNT };
struct KbInfo { const wchar_t* label; const wchar_t* reg; };
static const KbInfo kKbInfo[KB_COUNT] = {
    { L"New Session",      L"Key_New" },     { L"New Workspace",    L"Key_NewWs" },
    { L"Close Session",    L"Key_Close" },   { L"Split / Unsplit",  L"Key_Split" },
    { L"Next Session",     L"Key_Next" },    { L"Previous Session", L"Key_Prev" },
    { L"Copy",             L"Key_Copy" },    { L"Paste",            L"Key_Paste" },
    { L"Command Palette",  L"Key_Palette" }, { L"Focus Left Pane",  L"Key_FocusL" },
    { L"Focus Right Pane", L"Key_FocusR" },  { L"Scroll Up",        L"Key_ScrollUp" },
    { L"Scroll Down",      L"Key_ScrollDn" }, { L"Quick Terminal",   L"Key_Quick" },
    { L"Scratch Terminal", L"Key_Scratch" },  { L"Reopen Closed",    L"Key_Reopen" },
    { L"Flag / Unflag",    L"Key_Flag" },
    { L"Flagged View",     L"Key_FlagView" },  { L"Next Blocked",    L"Key_Attention" },
    { L"Focus Workspace",  L"Key_FocusWs" },
};
static WORD g_keys[KB_COUNT] = { 0 };
static bool g_swallowChar = false;   // set when a keydown was consumed by a binding, to drop its WM_CHAR
// The authentic 16-colour EGA/VGA text palette (0x00/0x55/0xAA/0xFF steps) — dimmer than modern ANSI,
// the classic MS-DOS look (e.g. Far's blue becomes 0x0000AA, not a bright 0x0000FF). Indexed in ANSI
// order (0 black, 1 red, 2 green, 3 yellow, 4 blue, 5 magenta, 6 cyan, 7 white; +8 = bright) to match
// the emulator's colour indices — NOT the CGA hardware order, or red/blue would swap.
static const uint32_t kEgaPalette[16] = {
    0x000000, 0xAA0000, 0x00AA00, 0xAA5500, 0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
    0x555555, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF };

// Menu command ids (the command palette posts these too — one implementation per action).
enum { IDM_NEW = 1, IDM_CLOSE = 2, IDM_SPLIT = 3, IDM_NEXT = 4, IDM_COPY = 5, IDM_PASTE = 6, IDM_PREV = 7,
       IDM_EXIT = 100, IDM_ABOUT = 101, IDM_NEWWS = 102, IDM_RESTART = 103, IDM_SHOW = 104,
       IDM_DUP = 105, IDM_RENAME = 106, IDM_DELWS = 107, IDM_PROPERTIES = 108, IDM_KEYBOARD = 109,
       IDM_QUICK = 120, IDM_SCRATCH = 121, IDM_REOPEN = 122,
       IDM_TG_SIDEBAR = 123, IDM_TG_TOOLBAR = 124, IDM_TG_STATUS = 125,
       IDM_FLAG = 126, IDM_FLAGVIEW = 127, IDM_ATTENTION = 128, IDM_FOCUSWS = 129, IDM_PALETTE = 130,
       IDM_UPDATE = 131, IDM_INSTALLSKILL = 132 };
#define IDM_MOVE_BASE 300   // "Move to workspace <w>" = IDM_MOVE_BASE + w
enum { ID_TREE = 200, ID_TRAY = 201, ID_TOOLBAR = 202, ID_STATUS = 203 };

// Toolbar: every full-app chrome button that has a lite equivalent, in the full app's order
// (sidebar toggle | session/workspace | split/scratch/quick | recent | settings). Icons are the
// full app's vector glyphs, redrawn in GDI per theme (see drawToolbarGlyph).
static const struct { int id; int img; bool check; const wchar_t* tip; } kTbButtons[] = {
    { IDM_TG_SIDEBAR, 0, false, L"Toggle Sidebar" },
    { IDM_NEW,        1, false, L"New Session" },
    { IDM_NEWWS,      2, false, L"New Workspace" },
    { IDM_SPLIT,      3, false, L"Split / Unsplit" },
    { IDM_SCRATCH,    4, false, L"Scratch Terminal" },
    { IDM_QUICK,      5, false, L"Quick Terminal" },
    { IDM_FLAGVIEW,   8, true,  L"Flagged View" },
    { IDM_ATTENTION,  9, false, L"Attention — next blocked session" },
    { IDM_REOPEN,     6, false, L"Reopen Closed Session" },
    { IDM_PROPERTIES, 7, false, L"Properties" },
};
static constexpr int kTbCount = (int)(sizeof kTbButtons / sizeof kTbButtons[0]);
static constexpr int kTbImgCount = 11;   // 0..9 per the table + 10 = the bell in the alert colour
static int tbImageOf(int cmdId) {
    for (const auto& b : kTbButtons) if (b.id == cmdId) return b.img;
    return -1;
}
#define WM_APP_REFRESHTREE (WM_APP + 3)   // posted from worker threads to rebuild the tree on the UI thread
#define WM_APP_TRAY        (WM_APP + 4)   // system-tray icon notifications
#define WM_APP_OVERLAY     (WM_APP + 5)   // control thread -> UI thread: open (wParam OVL_OPEN, creates a window) or resize (OVL_RESIZE) the overlay
enum { OVL_OPEN = 0, OVL_RESIZE = 1 };   // WM_APP_OVERLAY wParam
#define WM_APP_UPDATE      (WM_APP + 6)   // self-update worker -> UI thread (balloon / message / apply)
#define WM_APP_FOCUSTERM   (WM_APP + 7)   // "give the terminal keyboard focus back", posted (see OnNotify)
#define WM_APP_HOSTACT     (WM_APP + 8)   // reader thread -> UI thread: a drained host action
enum { HA_CLIP = 1, HA_NOTIFY = 2, HA_BELL = 3 };   // WM_APP_HOSTACT wParam
#define WM_APP_SIDEBARW    (WM_APP + 9)   // control thread -> UI thread: g_sidebarW changed; relayout (if shown) and persist
struct NotifyMsg { std::wstring title, body; };
// Heap payload for one posted WM_APP_OVERLAY, freed by the handler — the way WM_APP_HOSTACT
// already carries a NotifyMsg. Two globals used to hold this, so a queued open picked up the size
// a LATER resize had stored and ran at a number nobody was told (revmux r1 of P2-lite).
struct OverlayReq { std::string cmd; int sizePct; };
static HICON g_appIcon;         // big (taskbar / alt-tab)
static HICON g_appIconSm;       // small (title bar / tray)
static NOTIFYICONDATAW g_nid{};
static int g_cw = 8, g_ch = 16;
static CRITICAL_SECTION g_lock; // guards every session's emu + the session list shape
// Serialises hostResize: one resize reaches the pty-host at a time, so the latch, the host and the
// emulator cannot disagree. Deliberately NOT g_lock — the round trip under it is unbounded, and
// g_lock is what paintPane and every reader thread need (see hostResize). The invariant, stated as
// a rule rather than a sequence: **g_lock must not be held when g_resizeLock is acquired.**
// hostResize is the only taker, and it takes g_lock briefly several times — read that function for
// the current set; the one that matters here is its FIRST, the early out, which releases before the
// try-lock precisely for this reason. The rule is what to preserve, not the count: no hold may be
// widened across the acquisition of g_resizeLock. (This sentence has gone stale twice by listing the
// holds, so it no longer lists them.)
static CRITICAL_SECTION g_resizeLock;
// Scoped hold of g_lock. The section is recursive, so nesting (a reconcile inside a paint that
// already holds it) is safe.
struct LockG {
    LockG() { EnterCriticalSection(&g_lock); }
    ~LockG() { LeaveCriticalSection(&g_lock); }
    LockG(const LockG&) = delete;
    LockG& operator=(const LockG&) = delete;
};
static HANDLE g_control = INVALID_HANDLE_VALUE;
static std::vector<Session*> g_sessions;
static std::vector<std::wstring> g_workspaces = { L"workspace 1" };  // session "folders" (groups)
static int g_activeWs = 0;           // workspace new sessions are created into
static int g_pane[2] = { 0, -1 };   // session index per pane; pane[1] = -1 → no split
static int g_focus = 0;             // focused pane (0/1)
static int g_seq = 1;
static const wchar_t* kAppId = L"agliteterm";
static const wchar_t* kLegacyAppId = L"agwinterm-lite";   // control-pipe alias, see ctlServerThread

// ---- selection (buffer-absolute rows; the same viewport composition as paint) ----
struct Sel {
    int pane = -1;                  // which pane the selection lives in (-1 = none)
    // The SESSION the selection belongs to. A pane index alone is not identity: switching sessions
    // reuses the same pane, and the selection then painted over unrelated content AND suppressed
    // the cursor (see the !has() guard in paintPane) — which read as "the caret is lost when I
    // switch sessions". Selection state is per-session, so it must be keyed by session.
    void* sess = nullptr;
    bool active = false;            // a drag is in progress
    int aRow = 0, aCol = 0;         // anchor (buffer-absolute row, column)
    int bRow = 0, bCol = 0;         // current end
    int64_t epoch = 0;              // the session's evicted-line count when these rows were taken
    bool alt = false;               // was the ALT screen showing? it is a different buffer entirely
    bool has() const { return pane >= 0 && sess && (aRow != bRow || aCol != bCol); }
    // Bound = the rows and the epoch mean something, even while the drag is still degenerate
    // (mouse-down, before the pointer has left the anchor cell). The reconciler must use THIS:
    // skipping a degenerate selection leaves the anchor in the old numbering while the first
    // extended end is written in the new one, and the next reconcile then shifts that fresh end too.
    bool bound() const { return pane >= 0 && sess; }
    bool isFor(const void* s) const { return has() && sess == s; }
    void clear() { *this = Sel{}; }
    void norm(int& r0, int& c0, int& r1, int& c1) const {
        if (aRow < bRow || (aRow == bRow && aCol <= bCol)) { r0 = aRow; c0 = aCol; r1 = bRow; c1 = bCol; }
        else { r0 = bRow; c0 = bCol; r1 = aRow; c1 = aCol; }
    }
};
static Sel g_sel;
static void syncSelection();   // fwd: the paint path uses it above the definition
// Main-app parity (TerminalConfig.RightClickPaste / .CopyOnCtrlC, both on by default). No UI:
// they are the behaviour nearly everyone wants, and the registry is the escape hatch for the
// rest - HKCU\Software\agliteterm, DWORD 0 to turn either off.
static bool g_rightClickPaste = true;
static bool g_copyOnCtrlC = true;
static bool g_rbtnForwarded = false;   // did the app get the button-2 PRESS? then it gets the release

// ---- command palette: type-to-filter overlay over every action -------------------------------
// One entry per action lite has (menu commands, keyboard-only actions, theme switches). Executed
// via the same WM_COMMAND / runKbAction paths the menu and bindings use — the palette adds no
// second implementation of anything. Shortcut column shows the user's LIVE binding (g_keys).
static bool g_palette = false;
struct PalAction {
    const wchar_t* label;
    int idm;     // WM_COMMAND id to post (0 = none, use kb)
    int kb;      // KB_* action for the live-shortcut label / direct dispatch (-1 = none)
    int theme;   // TH_* to switch to (-1 = not a theme entry)
};
static const PalAction kPalActions[] = {
    { L"New Session",              IDM_NEW,        KB_NEW,       -1 },
    { L"New Workspace",            IDM_NEWWS,      KB_NEWWS,     -1 },
    { L"Close Session",            IDM_CLOSE,      KB_CLOSE,     -1 },
    { L"Duplicate Session",        IDM_DUP,        -1,           -1 },
    { L"Rename",                   IDM_RENAME,     -1,           -1 },
    { L"Reopen Closed Session",    IDM_REOPEN,     KB_REOPEN,    -1 },
    { L"Split / Unsplit",          IDM_SPLIT,      KB_SPLIT,     -1 },
    { L"Next Session",             IDM_NEXT,       KB_NEXT,      -1 },
    { L"Previous Session",         IDM_PREV,       KB_PREV,      -1 },
    { L"Copy",                     IDM_COPY,       KB_COPY,      -1 },
    { L"Paste",                    IDM_PASTE,      KB_PASTE,     -1 },
    { L"Quick Terminal",           IDM_QUICK,      KB_QUICK,     -1 },
    { L"Scratch Terminal",         IDM_SCRATCH,    KB_SCRATCH,   -1 },
    { L"Flag / Unflag Session",    IDM_FLAG,       KB_FLAG,      -1 },
    { L"Flagged View",             IDM_FLAGVIEW,   KB_FLAGVIEW,  -1 },
    { L"Next Blocked Session",     IDM_ATTENTION,  KB_ATTENTION, -1 },
    { L"Focus Workspace",          IDM_FOCUSWS,    KB_FOCUSWS,   -1 },
    { L"Delete Workspace",         IDM_DELWS,      -1,           -1 },
    { L"Focus Left Pane",          0,              KB_FOCUSL,    -1 },
    { L"Focus Right Pane",         0,              KB_FOCUSR,    -1 },
    { L"Toggle Sidebar",           IDM_TG_SIDEBAR, -1,           -1 },
    { L"Toggle Toolbar",           IDM_TG_TOOLBAR, -1,           -1 },
    { L"Toggle Status Bar",        IDM_TG_STATUS,  -1,           -1 },
    { L"Theme: Follow Windows",    0,              -1,           TH_AUTO },
    { L"Theme: Dark",              0,              -1,           TH_DARK },
    { L"Theme: Light",             0,              -1,           TH_LIGHT },
    { L"Theme: Classic",           0,              -1,           TH_CLASSIC },
    { L"Keyboard…",           IDM_KEYBOARD,   -1,           -1 },
    { L"Properties…",         IDM_PROPERTIES, -1,           -1 },
    { L"Check for Updates",        IDM_UPDATE,     -1,           -1 },
    { L"Install Agent Skill",      IDM_INSTALLSKILL, -1,         -1 },
    { L"Restart Everything",       IDM_RESTART,    -1,           -1 },
    { L"About agliteterm",         IDM_ABOUT,      -1,           -1 },
    { L"Exit",                     IDM_EXIT,       -1,           -1 },
};
static constexpr int kPalCount = (int)(sizeof kPalActions / sizeof kPalActions[0]);
static constexpr int kPalMaxRows = 12;         // list viewport height (rows)
static std::wstring g_palQuery;
static std::vector<int> g_palHits;             // filtered indices into kPalActions, best first
static int g_paletteSel = 0;                   // selection: index into g_palHits
static int g_palTop = 0;                       // first visible row of the viewport
static RECT g_palBox{}, g_palList{};           // last painted geometry (mouse hit-testing)

// Fuzzy match: every query char must appear in order; starts of words score higher, consecutive
// runs higher still. Returns <0 for no match. Case-insensitive.
static int palScore(const wchar_t* label, const std::wstring& q) {
    if (q.empty()) return 0;
    int score = 0, run = 0;
    size_t qi = 0;
    bool boundary = true;                       // previous label char started a word
    for (const wchar_t* p = label; *p && qi < q.size(); p++) {
        if (towlower(*p) == towlower(q[qi])) {
            score += 1 + run + (boundary ? 4 : 0) + (p == label ? 4 : 0);
            run = 2; qi++;
        } else run = 0;
        boundary = !iswalnum(*p);
    }
    return qi == q.size() ? score : -1;
}

static void palFilter() {
    g_palHits.clear();
    int scores[kPalCount];
    for (int i = 0; i < kPalCount; i++)
        if ((scores[i] = palScore(kPalActions[i].label, g_palQuery)) >= 0) g_palHits.push_back(i);
    std::stable_sort(g_palHits.begin(), g_palHits.end(),
                     [&](int a, int b) { return scores[a] > scores[b]; });
    g_paletteSel = 0; g_palTop = 0;
}

// "Ctrl+Shift+P" for a MAKEWORD(vk, HOTKEYF_*) combo — the Keyboard dialog's storage format.
static std::wstring palKeyName(WORD combo) {
    if (!combo) return L"";
    BYTE vk = LOBYTE(combo), m = HIBYTE(combo);
    std::wstring s;
    if (m & HOTKEYF_CONTROL) s += L"Ctrl+";
    if (m & HOTKEYF_SHIFT)   s += L"Shift+";
    if (m & HOTKEYF_ALT)     s += L"Alt+";
    UINT sc = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
    switch (vk) {   // extended keys need the KF_EXTENDED bit or GetKeyNameText says "Num 8" etc.
        case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN: case VK_INSERT: case VK_DELETE:
        case VK_HOME: case VK_END: case VK_PRIOR: case VK_NEXT: sc |= KF_EXTENDED; break;
    }
    wchar_t name[64];
    if (GetKeyNameTextW((LONG)(sc << 16), name, 64) > 0) s += name;
    return s;
}

static void fatal(const wchar_t* msg) {
    MessageBoxW(nullptr, msg, L"agliteterm", MB_ICONERROR);
    ExitProcess(1);
}

// ---- diagnostics log ------------------------------------------------------------------------
// Every lite field report so far ("restore doesn't work", "can't type after switching", the render
// artefacts) arrived from a machine we cannot attach a debugger to, and left nothing behind — so
// each one cost hours of re-enactment that mostly failed to reproduce. lite now records its own
// decisions (paths, counts, error codes, focus transitions) to a small rotating file next to its
// state, so the NEXT report comes with evidence.
//
// Deliberately NOT logged: terminal output, pasted text, typed keys, session command lines. The log
// is about what lite did, so it can be attached to an issue without leaking what you were doing.
//
// Rules: never fatal, never blocking, no-op forever if the file can't be opened. Callers span the UI
// thread, one readerThread per session, the control server + a thread per client, and the update
// worker, so it carries its own lock (g_lock guards emulator state, not this).
static CRITICAL_SECTION g_logLock;
static std::wstring g_logPath;
static bool g_logReady = false;      // logInit ran and the file opened at least once
static bool g_logDead = false;       // an open failed: degrade to a no-op rather than retry forever
static const DWORD kLogRotateBytes = 1024 * 1024;

static void logRotateIfBig() {   // call under g_logLock
    WIN32_FILE_ATTRIBUTE_DATA fa{};
    if (!GetFileAttributesExW(g_logPath.c_str(), GetFileExInfoStandard, &fa)) return;
    if (fa.nFileSizeHigh == 0 && fa.nFileSizeLow < kLogRotateBytes) return;
    MoveFileExW(g_logPath.c_str(), (g_logPath + L".old").c_str(), MOVEFILE_REPLACE_EXISTING);
}

static void logWriteV(const char* level, const char* fmt, va_list ap) {
    if (!g_logReady || g_logDead) return;
    char body[1024];
    _vsnprintf_s(body, sizeof body, _TRUNCATE, fmt, ap);
    SYSTEMTIME t; GetLocalTime(&t);
    char line[1200];
    int n = _snprintf_s(line, sizeof line, _TRUNCATE, "%04d-%02d-%02d %02d:%02d:%02d.%03d  %-4s  %s\r\n",
                        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds,
                        level, body);
    if (n <= 0) return;
    EnterCriticalSection(&g_logLock);
    logRotateIfBig();
    // FILE_SHARE_READ|WRITE so the file can be tailed (and a second instance never blocks) while lite runs.
    HANDLE f = CreateFileW(g_logPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) {
        g_logDead = true;   // unwritable profile: stop trying, lite carries on unchanged
    } else {
        DWORD wr; WriteFile(f, line, (DWORD)n, &wr, nullptr);
        CloseHandle(f);
    }
    LeaveCriticalSection(&g_logLock);
}

static void logInfo(const char* fmt, ...) { va_list ap; va_start(ap, fmt); logWriteV("INFO", fmt, ap); va_end(ap); }
static void logWarn(const char* fmt, ...) { va_list ap; va_start(ap, fmt); logWriteV("WARN", fmt, ap); va_end(ap); }

/// Resolve the per-instance log path and record the startup line. Per-instance because multi-window
/// lite is one process per window — a shared file would interleave four writers' lines.
static void logInit(int argc, wchar_t** argv) {
    InitializeCriticalSection(&g_logLock);
    std::wstring dir = stateDir();
    if (dir.empty()) { g_logDead = true; return; }
    CreateDirectoryW(dir.c_str(), nullptr);
    g_logPath = dir + (g_isDefaultInstance ? L"\\agliteterm.log" : (L"\\agliteterm-" + g_instance + L".log"));
    g_logReady = true;

    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring cmd;
    for (int i = 1; i < argc; i++) { if (i > 1) cmd += L" "; cmd += argv[i]; }
    logInfo("---- agliteterm %s starting ----", AGWL_VERSION_STR);
    logInfo("instance=%s exe=%s args=[%s]",
            narrow(g_isDefaultInstance ? L"(default)" : g_instance).c_str(),
            narrow(exe).c_str(), narrow(cmd).c_str());
    // The instance name IS the state-file name, so a sanitized name reads a different file and the
    // window comes up empty. Silently that is indistinguishable from "restore is broken".
    if (!g_instanceRaw.empty())
        logWarn("instance name '%s' is not usable as a filename — running as '%s' instead; state is in "
                "sessions-%s.tsv, not sessions-%s.tsv",
                narrow(g_instanceRaw).c_str(), narrow(g_instance).c_str(),
                narrow(g_instance).c_str(), narrow(g_instanceRaw).c_str());
}

// ---- control pipe: protobuf frames (4-byte LE length prefix) ----
static CRITICAL_SECTION g_reqLock;   // the control pipe is shared by the UI thread and the ctl server thread
// Why a request failed, for the one caller that has to tell the reasons apart. "The host sent a
// frame lite could not decode" and "the host refused the command" look identical through the bool,
// and the startup liveness probe needs them separated — see controlHandshake().
enum class ReqOutcome { NoReply, Undecodable, Refused, Ok };
static bool request(const agwinterm_ptyhost_Request& req, agwinterm_ptyhost_Reply* reply,
                    ReqOutcome* outcome = nullptr) {
    ReqOutcome sink;
    if (!outcome) outcome = &sink;
    *outcome = ReqOutcome::NoReply;
    EnterCriticalSection(&g_reqLock);
    struct Unlock { ~Unlock() { LeaveCriticalSection(&g_reqLock); } } unlock;
    // Sized from the generated worst case, not a round number: a Create carries 16 args of 2048 bytes
    // (35572 total), and the old 4 KB buffer meant a spec whose fields each passed fitsField could
    // still overflow the FRAME — pb_encode failed, request returned false with no log at all, and the
    // session came back as a nameless "FAILED to start". Restore feeds these straight from the state
    // file, so it was reachable from a file, which is exactly the silent failure this branch removes.
    std::vector<uint8_t> buf(agwinterm_ptyhost_Request_size + 4);
    pb_ostream_t os = pb_ostream_from_buffer(buf.data() + 4, buf.size() - 4);
    if (!pb_encode(&os, agwinterm_ptyhost_Request_fields, &req)) {
        logWarn("control: request (cmd %d) did not encode: %s", (int)req.which_cmd, PB_GET_ERROR(&os));
        return false;
    }
    uint32_t len = (uint32_t)os.bytes_written;
    memcpy(buf.data(), &len, 4);
    DWORD n = 0;
    if (!WriteFile(g_control, buf.data(), len + 4, &n, nullptr)) return false;

    uint32_t rlen = 0;
    DWORD got = 0, need = 4;
    while (need && ReadFile(g_control, (uint8_t*)&rlen + (4 - need), need, &got, nullptr) && got) need -= got;
    if (need || rlen > 1 << 20) return false;
    std::vector<uint8_t> payload(rlen);
    need = rlen;
    while (need && ReadFile(g_control, payload.data() + (rlen - need), need, &got, nullptr) && got) need -= got;
    if (need) return false;
    pb_istream_t is = pb_istream_from_buffer(payload.data(), rlen);
    *reply = agwinterm_ptyhost_Reply_init_default;
    if (!pb_decode(&is, agwinterm_ptyhost_Reply_fields, reply)) { *outcome = ReqOutcome::Undecodable; return false; }
    if (!reply->ok) { *outcome = ReqOutcome::Refused; return false; }
    *outcome = ReqOutcome::Ok;
    return true;
}

static HANDLE openPipe(const std::wstring& name, int timeoutMs, bool overlapped) {
    // DATA pipes must be overlapped: a non-overlapped duplex pipe SERIALIZES the handle
    // (pending reader ReadFile blocks the UI thread's keystroke write — both the Rust
    // host and this client hit that identical deadlock). Control stays sync.
    std::wstring full = L"\\\\.\\pipe\\" + name;
    DWORD flags = overlapped ? FILE_FLAG_OVERLAPPED : 0;
    for (int waited = 0; waited <= timeoutMs; waited += 100) {
        HANDLE h = CreateFileW(full.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, flags, nullptr);
        if (h != INVALID_HANDLE_VALUE) return h;
        Sleep(100);
    }
    return INVALID_HANDLE_VALUE;
}

static DWORD ovIo(HANDLE h, bool write, const void* wbuf, void* rbuf, DWORD len) {
    OVERLAPPED ov{};
    ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    BOOL issued = write ? WriteFile(h, wbuf, len, nullptr, &ov) : ReadFile(h, rbuf, len, nullptr, &ov);
    DWORD n = 0;
    if (issued || GetLastError() == ERROR_IO_PENDING) {
        if (!GetOverlappedResult(h, &ov, &n, TRUE)) n = 0;
    }
    CloseHandle(ov.hEvent);
    return n;
}

static std::wstring exeDir() {
    wchar_t buf[MAX_PATH];
    GetModuleFileNameW(nullptr, buf, MAX_PATH);
    std::wstring s = buf;
    return s.substr(0, s.find_last_of(L'\\'));
}

static void loadCore() {
    HMODULE m = LoadLibraryW((exeDir() + L"\\agwinterm_core.dll").c_str());
    if (!m) fatal(L"agwinterm_core.dll not found next to the exe");
    core_abi = (decltype(core_abi))GetProcAddress(m, "agwcore_abi_version");
    emu_new = (decltype(emu_new))GetProcAddress(m, "agwcore_emu_new");
    emu_free = (decltype(emu_free))GetProcAddress(m, "agwcore_emu_free");
    emu_feed = (decltype(emu_feed))GetProcAddress(m, "agwcore_emu_feed");
    emu_resize = (decltype(emu_resize))GetProcAddress(m, "agwcore_emu_resize");
    emu_info = (decltype(emu_info))GetProcAddress(m, "agwcore_emu_info");
    emu_copy_grid = (decltype(emu_copy_grid))GetProcAddress(m, "agwcore_emu_copy_grid");
    emu_copy_history_row = (decltype(emu_copy_history_row))GetProcAddress(m, "agwcore_emu_copy_history_row");
    emu_marks = (decltype(emu_marks))GetProcAddress(m, "agwcore_emu_marks");
    emu_get_text = (decltype(emu_get_text))GetProcAddress(m, "agwcore_emu_get_text");
    emu_take_host_actions = (decltype(emu_take_host_actions))GetProcAddress(m, "agwcore_emu_take_host_actions");
    core_free_buf = (decltype(core_free_buf))GetProcAddress(m, "agwcore_free_buf");
    if (!core_abi || !emu_new || !emu_feed || !emu_info || !emu_copy_grid || !emu_resize || !emu_free || !emu_copy_history_row || !emu_marks || !emu_get_text || !emu_take_host_actions || !core_free_buf)
        fatal(L"agwinterm_core.dll: exports missing");
    // Name BOTH numbers. The old message hardcoded "need v15", so it went stale on every bump and
    // never said what the dll actually reported — the one fact you need when the exe and the core
    // ship from different repositories (see docs/plans/2026-08-17-agliteterm-product-split.md).
    if (core_abi() != kRequiredAbi) {
        wchar_t msg[160];
        wsprintfW(msg, L"agwinterm_core.dll: ABI mismatch - the dll is v%u, this build requires v%u",
                  core_abi(), kRequiredAbi);
        fatal(msg);
    }
}

/// Handshake + liveness probe. `hello` alone is NOT enough: a pty-host whose client was killed is
/// tearing down but still accepts a connection and answers hello for a moment, while refusing every
/// real command. Believing that host is what made restore fail wholesale after lite was killed —
/// every create came back false in the same millisecond and the sessions were simply gone. `list`
/// is the cheapest request that actually touches the session table, so it is the real probe.
///
/// The probe asks whether the host ANSWERED, not whether the answer decoded: a reply lite's own
/// field storage can't hold is still proof the host is alive and serving, and refusing to launch
/// over one is far worse than the fault it was guarding against (lite has to start; adoption is a
/// bonus). Decode failures are logged where they matter — in hostSessions().
enum class HostHealth { Dead, HelloOnly, Healthy };
static HostHealth controlHandshake() {
    agwinterm_ptyhost_Request req = agwinterm_ptyhost_Request_init_default;
    agwinterm_ptyhost_Reply rep = agwinterm_ptyhost_Reply_init_default;
    req.which_cmd = agwinterm_ptyhost_Request_hello_tag;
    req.cmd.hello.protocol = kProtocolVersion;
    if (!request(req, &rep) || rep.which_body != agwinterm_ptyhost_Reply_hello_tag) return HostHealth::Dead;
    req = agwinterm_ptyhost_Request_init_default;
    rep = agwinterm_ptyhost_Reply_init_default;
    req.which_cmd = agwinterm_ptyhost_Request_list_tag;
    ReqOutcome out = ReqOutcome::NoReply;
    if (request(req, &rep, &out))
        return rep.which_body == agwinterm_ptyhost_Reply_list_tag ? HostHealth::Healthy : HostHealth::HelloOnly;
    if (out == ReqOutcome::Undecodable) {
        logWarn("pty-host: list replied with something this build cannot decode — the host is alive, "
                "so lite starts; adoption of live sessions is unavailable this run");
        return HostHealth::Healthy;
    }
    return HostHealth::HelloOnly;
}

static void connectControl() {
    std::wstring control = std::wstring(kAppId) + L"-ptyhost";
    std::wstring cmd = L"\"" + exeDir() + L"\\agwinterm-ptyhost.exe\" --pipe " + kAppId;
    // At most ONE host is started per launch. The host serves its pipe with PIPE_UNLIMITED_INSTANCES,
    // so a second one can bind the same name and clients get split between them — sessions created
    // against host A are invisible to a client that lands on host B. Retrying is for waiting out a
    // dying host, not for stacking up replacements.
    bool spawned = false;
    const int kAttempts = 4;
    for (int attempt = 0; attempt < kAttempts; attempt++) {
        g_control = openPipe(control, 0, false);
        if (g_control == INVALID_HANDLE_VALUE && !spawned) {   // no host yet: start one
            spawned = true;
            STARTUPINFOW si{ sizeof(si) };
            PROCESS_INFORMATION pi{};
            std::vector<wchar_t> buf(cmd.begin(), cmd.end());
            buf.push_back(0);
            if (!CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
                fatal(L"could not start agwinterm-ptyhost.exe");
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            g_control = openPipe(control, 5000, false);
        }
        HostHealth health = g_control != INVALID_HANDLE_VALUE ? controlHandshake() : HostHealth::Dead;
        if (health == HostHealth::Healthy) {
            if (attempt) logInfo("pty-host: healthy on attempt %d", attempt + 1);
            return;
        }
        // A host that answers hello but refuses `list` is usually on its way out — the retries are
        // there to wait for it to release the pipe name so a fresh one can take over. But it can
        // also be a host that is alive and serving other windows and simply cannot answer this one
        // command. Never refuse to launch over that: a terminal with no adoption beats no terminal
        // at all, which is the whole reason the probe returns Healthy for an undecodable reply too.
        if (health == HostHealth::HelloOnly && attempt == kAttempts - 1) {
            logWarn("pty-host: answers hello but not list after %d attempts — starting anyway; live "
                    "sessions cannot be adopted this run", attempt + 1);
            return;
        }
        // Either nothing answered, or what answered is on its way out. Drop it and give the dying
        // host time to release the pipe name; the next attempt starts a fresh one if it hasn't yet.
        logWarn("pty-host: connection unusable (attempt %d) — retrying%s", attempt + 1,
                spawned ? "" : " with a fresh host");
        if (g_control != INVALID_HANDLE_VALUE) { CloseHandle(g_control); g_control = INVALID_HANDLE_VALUE; }
        Sleep(400);
    }
    fatal(L"pty-host did not become usable (protocol mismatch, or a previous host is stuck)");
}

// ---- pane geometry ----
static void paneRect(int pane, RECT client, RECT* out) {
    int contentX = sidebarSpan();               // right of the sidebar + splitter (0 if hidden)
    int top = toolbarTop();                     // below the toolbar (0 if hidden)
    int bottom = client.bottom - (g_showStatus ? g_statusH : 0);   // above the status bar
    int contentW = client.right - contentX;
    if (g_pane[1] < 0) { *out = { contentX, top, client.right, bottom }; return; }
    int half = contentW / 2;
    if (pane == 0) *out = { contentX, top, contentX + half - 1, bottom };
    else *out = { contentX + half + 1, top, client.right, bottom };
}

// The grid a pane's rect holds, or false when there is no rect to size from — the window is
// minimised (its client rect is 0x0, and IsIconic is the same guard OnSize has as SIZE_MINIMIZED),
// the sidebar is wider than the client, or a pane holds less than one cell. It used to answer 2x2
// in every one of those cases, and every caller pushed that to the pty-host and the emulator: the
// shell reflowed at 2 columns and the pane never recovered (#23). A false here is "do not resize",
// not "resize to something small"; the next real WM_SIZE (restore, widen) asks again.
static bool paneGridSize(int pane, int* cols, int* rows) {
    if (IsIconic(g_hwnd)) return false;
    RECT rc;
    GetClientRect(g_hwnd, &rc);
    RECT pr;
    paneRect(pane, rc, &pr);
    long w = pr.right - pr.left, h = pr.bottom - pr.top;
    if (w <= 0 || h <= 0 || g_cw <= 0 || g_ch <= 0) return false;
    long c = w / g_cw, r = h / g_ch;
    if (c < 1 || r < 1) return false;
    *cols = (int)c;
    *rows = (int)r;
    return true;
}

// The grid a NEW session is created with. A create needs a number even when the window has no
// viable rect (`session new` over the pipe while the window sits minimised in the taskbar is the
// #23 report); the grid the pane's session was last sized to is the best guess, else the other
// pane's, else 80x24 — never 2x2. The first layout after the window is viable again (OnSize ->
// syncPaneSizes) corrects it, which it could not do for a shell that had already reflowed at 2.
static void newSessionGrid(int pane, int* cols, int* rows) {
    if (paneGridSize(pane, cols, rows)) return;
    // Under g_lock like resolveTarget and callerWorkspace: this fallback runs on control-pipe
    // threads (session.new / duplicate / split), and attachSession's push_back frees the vector's
    // old buffer under the same lock. paneGridSize above touches no shared list, so only this walk
    // needs the hold. Reached exactly when the window is not viable — which is when the stress
    // suite is creating and closing sessions, so it is a real interleaving, not a theoretical one.
    LockG hold;
    for (int p : { pane, 1 - pane }) {
        int idx = (p >= 0 && p < 2) ? g_pane[p] : -1;
        if (idx < 0 || idx >= (int)g_sessions.size()) continue;
        Session* s = g_sessions[idx];
        if (s->cols >= 1 && s->rows >= 1) { *cols = s->cols; *rows = s->rows; return; }
    }
    *cols = 80;
    *rows = 24;
}

// The widest sidebar that leaves kMinContentCols cells of the live font for the terminal in a
// client `clientW` wide — the one rule `sidebar width` refuses against, the splitter drag stops at,
// and OnSize re-clamps to (fitSidebarToClient). It is under kSidebarMinW in a window narrower than
// a minimum sidebar plus the columns; the sidebar then keeps its minimum and paneGridSize decides
// whether what is left is a pane at all.
static int maxSidebarW(int clientW) { return clientW - kSplitterW - kMinContentCols * g_cw; }

// Re-clamp g_sidebarW against the client the window HAS. Two persisted values (SidebarW, and the
// WinW-<instance> rect) are each valid on their own and can still be impossible together — a
// sidebar saved at 900 from a wide monitor and a window rect saved at 700 on the laptop — and until
// this the layout honoured the sidebar and gave the terminal a negative width (#23). Applied only
// while the sidebar is SHOWN: a hidden sidebar's width is not in effect, and `sidebar show` runs
// this layout again. Not persisted here: the value in effect is what `sidebar width` reads, and the
// existing save paths (a drag, a set, a toggle) write it when the user next touches it, so a
// window narrowed for a moment does not overwrite a wide monitor's preference.
static bool fitSidebarToClient(int clientW) {
    if (!g_showSidebar || clientW <= 0) return false;
    // Derived from the PREFERENCE every time, never from the last fit: a window that gets wider
    // again restores the width the user asked for, and no save path can persist a transient clamp.
    int fit = max(kSidebarMinW, min(g_sidebarWPref, maxSidebarW(clientW)));
    if (fit == g_sidebarW) return false;
    if (fit < g_sidebarWPref)
        logWarn("sidebar width %d leaves under %d columns of the terminal in a %d px client; using %d (not saved; the preference is kept)",
                g_sidebarWPref, kMinContentCols, clientW, fit);
    g_sidebarW = fit;
    return true;
}

static Session* focusedSession() {
    if (g_focusOverride) return g_focusOverride;   // a popup terminal owns input while it's focused
    int idx = g_pane[g_focus];
    return (idx >= 0 && idx < (int)g_sessions.size()) ? g_sessions[idx] : nullptr;
}
// The window that displays a session (a popup terminal, else the main window) — repaint target.
static HWND windowForSession(Session* s) {
    if (s == g_quickSession && g_quickHwnd) return g_quickHwnd;
    if (s == g_scratchSession && g_scratchHwnd) return g_scratchHwnd;
    if (s == g_overlaySession && g_overlayHwnd) return g_overlayHwnd;
    return g_hwnd;
}

// fromRetry: this call came from the relayout TIMER, not from a real layout event (a WM_SIZE, a
// select, a split, a font change). The difference decides two things — whether the refusal counter
// starts a new episode, and whether a session that has already exhausted its retries is asked
// again — so it is passed explicitly rather than kept in shared state a pipe thread would race
// (revmux r6).
static void hostResize(Session* s, int cols, int rows, bool fromRetry = false) {
    // syncPaneSizes() runs on every session switch / select / split change, so most calls here ask
    // for the geometry the session already has. Forwarding those is not free: ConPTY reflows and
    // re-emits its screen on ANY resize, which garbles a full-screen TUI (the app was never told
    // anything changed, so it never redraws). Only a real change goes to the host.
    //
    // Serialised on g_resizeLock, NOT on g_lock. This runs on the UI thread (WM_SIZE) and on
    // control-pipe threads (session.select / split / new through syncPaneSizes) at once, and the
    // latch has to be decided and the host told in one order, or thread A latches 120 and goes to
    // the host while B latches 80 and does the same, and whichever reply lands last leaves the
    // latch, the host and the emulator disagreeing for good — the pane stuck at a size nothing
    // asked for (#23).
    //
    // g_lock is NOT held across request(). request() is a synchronous WriteFile/ReadFile on a
    // non-overlapped pipe with no timeout, so a pty-host that is alive but not answering blocks
    // this thread forever — and a child that stops draining its input can make exactly that happen
    // (the host's input pump blocks in write_all holding that session's pty mutex, and every Resize
    // for it queues behind). With g_lock held that stall freezes paintPane, every reader thread,
    // `tree` and the status bar: the whole window, unrecoverably (revmux r1 of P2-lite). The lock
    // is taken for the latch, dropped for the round trip, and re-taken to publish the result.
    //
    // The UI thread never WAITS for this lock: if a pipe thread is mid-round-trip the UI thread
    // leaves the resize rather than blocking the message loop, and re-arms the retry timer below.
    // Nothing to do? Answer before taking g_resizeLock — under g_lock, which this scope RELEASES
    // before the try-lock below, because g_lock must never be held while g_resizeLock is acquired
    // (a thread inside the body holds g_resizeLock and wants g_lock; holding them the other way
    // round here would be a real inversion). Do not merge this block into the locked block below.
    // It is what keeps a retry that finds every grid already correct from arming another one
    // (revmux r3); the authoritative compare-and-set is still the one under g_lock inside.
    {
        LockG hold;
        if (s->cols == cols && s->rows == rows) return;
    }
    // g_hwnd null or already destroyed answers 0, which no thread id equals, so this falls to the
    // blocking branch — right for a pipe thread, and unreachable for the UI thread, which cannot be
    // in here without its own window.
    bool onUi = GetWindowThreadProcessId(g_hwnd, nullptr) == GetCurrentThreadId();
    if (onUi) {
        // Skipped, not dropped. Nothing polls: every syncPaneSizes caller is an event (WM_SIZE, a
        // select, a split, a font change), so the next WM_SIZE is not something anyone owns — a drag
        // that ends while a pipe thread holds the lock would leave the pane at the old grid, and a
        // popup has no fallback layout at all (popup sessions are never in g_pane).
        //
        // A ONE-SHOT TIMER, not a posted message: a posted retry is dispatched ahead of paint and
        // input and re-arms from its own handler, so the UI thread spun at 100 % CPU for as long as
        // the lock was held — forever, with a wedged pty-host (#27). WM_TIMER is delivered only when
        // the queue is empty, and SetTimer with the same id just restarts the one timer, so there is
        // nothing to stack and nothing to leak (revmux r3).
        if (!TryEnterCriticalSection(&g_resizeLock)) {
            // Remember WHAT was demoted, not just that something was: the timer's sweep passes
            // fromRetry=true for both of its owners, and an exhausted session would otherwise skip
            // the very layout event the timer is carrying for it.
            if (!fromRetry) { LockG hold; s->resizeWanted = true; }
            SetTimer(g_hwnd, kRelayoutTimer, kRelayoutRetryMs, nullptr);
            return;
        }
    }
    else EnterCriticalSection(&g_resizeLock);
    struct ResizeGuard { ~ResizeGuard() { LeaveCriticalSection(&g_resizeLock); } } resizeGuard;
    int hadCols, hadRows;
    {
        // ONE hold, and the order inside it is load-bearing. Every exit between the latch write and
        // the host's answer must either roll the latch back or complete the resize — a return that
        // leaves it advanced publishes a grid the shell and the emulator do not have, which `tree`
        // then reports and newSessionGrid then inherits (revmux r7 found exactly that: the
        // exhausted-retry check sat AFTER the write). So: decide, THEN commit.
        //
        // A real layout event starts a NEW refusal episode — the count is "refusals in a row while
        // chasing this on the timer", not "refusals ever". Left as a lifetime count it went silent
        // after the give-up: every later drag, split or font change refused with no log line and no
        // retry, indefinitely, which is the one state (an undecodable control pipe) the log is the
        // only diagnostic for. A timer sweep, conversely, must NOT re-ask a session that has already
        // given up — another session's SetTimer would otherwise retry it past its own cap.
        LockG hold;
        if (s->cols == cols && s->rows == rows) return;                       // decided (nothing consumed)
        // A timer sweep is only an automatic retry when it is not carrying a demoted real event for
        // THIS session; resizeWanted is how that survives the hand-off, and this attempt consumes it.
        bool real = !fromRetry || s->resizeWanted;
        s->resizeWanted = false;
        if (!real && s->resizeRefusals > kResizeRetryAttempts) return;        // decided
        if (real) s->resizeRefusals = 0;
        hadCols = s->cols; hadRows = s->rows;                                 // committed
        s->cols = cols;
        s->rows = rows;
    }
    if (!s->id.empty()) {   // a restore placeholder has no host session — only its emulator resizes
        agwinterm_ptyhost_Request req = agwinterm_ptyhost_Request_init_default;
        agwinterm_ptyhost_Reply rep = agwinterm_ptyhost_Reply_init_default;
        req.which_cmd = agwinterm_ptyhost_Request_resize_tag;
        strcpy_s(req.cmd.resize.id, s->id.c_str());
        req.cmd.resize.cols = (uint32_t)cols;
        req.cmd.resize.rows = (uint32_t)rows;
        ReqOutcome why;
        if (!request(req, &rep, &why) && !s->exited) {
            // The host did not take it: roll the latch back and ARM THE RETRY. "The next
            // syncPaneSizes asks again" is not something anyone owns (see the top of this
            // function), and the early out above makes that reachable: while this request was in
            // flight the latch already advertised the new size, so a concurrent caller asking for
            // the SAME grid returned without arming anything, and an already-armed timer that fired
            // in that window killed itself for the same reason. The timer is the one thing that
            // outlives both, so the rollback owes it (revmux r4). The emulator keeps the size the
            // host still has.
            // An EXITED session is the one exception — there is no shell behind it to reflow, the
            // host has nothing to say about it, and the emulator is the only thing left to fit.
            LockG hold;
            s->cols = hadCols;
            s->rows = hadRows;
            const char* reason = why == ReqOutcome::Refused ? "refused"
                               : why == ReqOutcome::Undecodable ? "undecodable reply" : "no reply";
            // BOUNDED. The retry cannot fix what is refusing — it re-issues the same request — so it
            // backs off (60, 120, 240 ms) and then stops. A host that keeps saying no is not a
            // transient busy lock, and the unbounded version of this was the r3 Major all over
            // again: the UI thread waking 16 times a second, one synchronous round trip per pane and
            // popup, a log line each time. The next real layout event still asks; only the automatic
            // chasing stops. Logged on the first refusal and on the give-up, not on every tick.
            if (++s->resizeRefusals <= kResizeRetryAttempts) {
                SetTimer(g_hwnd, kRelayoutTimer, kRelayoutRetryMs << (s->resizeRefusals - 1), nullptr);
                if (s->resizeRefusals == 1)   // once per episode; the retries below are the same refusal
                    logWarn("resize %s to %dx%d not accepted by the pty-host (%s) — kept %dx%d, retrying on the layout timer",
                            s->id.c_str(), cols, rows, reason, hadCols, hadRows);
            } else if (s->resizeRefusals == kResizeRetryAttempts + 1) {
                logWarn("resize %s to %dx%d not accepted %d times (%s), %d automatic retries — kept %dx%d and STOPPED chasing it; the next layout event starts over",
                        s->id.c_str(), cols, rows, s->resizeRefusals, reason, kResizeRetryAttempts, hadCols, hadRows);
            }
            return;
        }
    }
    LockG hold;
    s->resizeRefusals = 0;   // the host took it: the next refusal starts its own backoff
    emu_resize(s->emu, cols, rows);
}

// Fit each shown pane's session to its rect. A pane with no viable rect (paneGridSize) is left
// alone — not resized to 2x2 — so this is safe from the pipe threads while the window is minimised.
static void syncPaneSizes(bool fromRetry = false) {
    // The pointers come out under g_lock and the host round trip happens outside it — the same
    // shape newSessionGrid, resolveTarget and callerWorkspace take. This runs on control-pipe
    // threads too (session.select / split / duplicate through selectPrimary), where another
    // thread's attachSession push_back reallocates g_sessions and frees the buffer this loop was
    // indexing (revmux r2: the sibling of the walk r1 locked). No lock spans hostResize.
    Session* want[2] = { nullptr, nullptr };
    int grid[2][2]{};
    {
        LockG hold;
        for (int p = 0; p < 2; p++) {
            int idx = g_pane[p];
            if (idx < 0 || idx >= (int)g_sessions.size()) continue;
            want[p] = g_sessions[idx];
        }
    }
    for (int p = 0; p < 2; p++) {
        if (!want[p]) continue;
        if (!paneGridSize(p, &grid[p][0], &grid[p][1])) continue;
        hostResize(want[p], grid[p][0], grid[p][1], fromRetry);
    }
}

// Fit each live popup's session to its own window. syncPaneSizes cannot: a quick / scratch /
// overlay session is never written into g_pane, so the only thing that ever sizes one is its own
// WM_SIZE — and a resize skipped there (g_resizeLock busy) has nothing else to correct it. UI
// thread only, like syncPaneSizes.
static void refitPopupSessions(bool fromRetry = false) {
    const std::pair<HWND, Session*> popups[] = {
        { g_quickHwnd, g_quickSession }, { g_scratchHwnd, g_scratchSession }, { g_overlayHwnd, g_overlaySession },
    };
    for (const auto& pr : popups) {
        HWND hw = pr.first; Session* s = pr.second;
        if (!hw || !s || !IsWindow(hw) || !IsWindowVisible(hw) || IsIconic(hw)) continue;
        RECT rc; GetClientRect(hw, &rc);
        if (rc.right <= 0 || rc.bottom <= 0 || g_cw <= 0 || g_ch <= 0) continue;
        hostResize(s, max(1, (int)(rc.right / g_cw)), max(1, (int)(rc.bottom / g_ch)), fromRetry);
    }
}

// ---- FTCS prompt wrap: chain the user's prompt so it emits OSC 133 D;<exit> + A each turn,
// giving lite the prompt pips out of the box while preserving oh-my-posh/starship. Passed as
// -EncodedCommand (base64 of UTF-16LE) so there is zero quoting to mangle. ----
static std::string base64(const std::wstring& s) {
    static const char* T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const uint8_t* p = (const uint8_t*)s.data();
    size_t n = s.size() * sizeof(wchar_t);
    std::string out;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = p[i] << 16 | (i + 1 < n ? p[i + 1] << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
        out += T[(v >> 18) & 63];
        out += T[(v >> 12) & 63];
        out += (i + 1 < n) ? T[(v >> 6) & 63] : '=';
        out += (i + 2 < n) ? T[v & 63] : '=';
    }
    return out;
}

static const wchar_t* kPromptWrap =
    L"if(-not $global:__agwLiteWrap){$global:__agwLiteWrap=$true;$global:__agwLiteP=$function:prompt;"
    L"function global:prompt{$ec=if($?){0}else{1};$e=[char]27;$b=[char]7;"
    // Sync the PROCESS cwd to the shell's location: Set-Location alone doesn't move it, and the
    // process cwd (read from the PEB at save time) is how session restore learns the live dir —
    // conhost/ConPTY filters cwd OSC sequences (7 and 9;9) out of the stream, so VT can't carry it.
    L"$l=$executionContext.SessionState.Path.CurrentLocation;"
    L"if($l.Provider.Name -eq 'FileSystem'){[Environment]::CurrentDirectory=$l.ProviderPath};"
    L"[Console]::Write(\"$e]133;D;$ec$b$e]133;A$b\");"
    L"if($global:__agwLiteP){& $global:__agwLiteP}else{\"PS $($executionContext.SessionState.Path.CurrentLocation)> \"}}}";

// ---- session lifecycle ----
// Completed FTCS commands (OSC 133 with an end boundary) in the session's buffer. Call under g_lock.
static int completedMarks(Session* s) {
    FfiEmuInfo info{};
    if (!s->emu || !emu_info(s->emu, &info) || info.markCount == 0) return 0;
    std::vector<FfiMark> mk(info.markCount);
    uint32_t nm = emu_marks(s->emu, mk.data(), info.markCount);
    int done = 0;
    for (uint32_t i = 0; i < nm; i++) if (mk[i].endLine >= 0) done++;
    return done;
}

// ---- host actions ---------------------------------------------------------------------------
// The emulator performs no side effects of its own: it QUEUES them and the host drains them after
// each feed. lite never drained, and the cost was larger than it looks. OSC 52 clipboard writes
// were dropped, so a program that copies through the terminal (Claude Code does) put nothing on
// the clipboard - and every REPLY the terminal owed a program went unsent, because a query answer
// is a host action too. To the program that asked, the terminal simply never answered.
//
// Wire format from agwcore_emu_take_host_actions: u32 count, then per action a u8 tag and its
// payload; strings are u32 length + UTF-8 bytes.
static std::wstring widen(const std::string& s);   // fwd (the drain sits above the utf helpers)
static bool haStr(const uint8_t* p, uint32_t len, uint32_t& off, std::string& out) {
    uint32_t n;
    if (off + 4 > len) return false;
    memcpy(&n, p + off, 4);
    off += 4;
    if (n > len || off + n > len) return false;
    out.assign((const char*)p + off, n);
    off += n;
    return true;
}
// Call with g_lock RELEASED: a reply goes straight back down the pty, and everything else is
// posted to the UI thread, which owns the clipboard and the tray icon.
static void runHostActions(Session* s, const uint8_t* buf, uint32_t len) {
    if (!buf || len < 4) return;
    uint32_t count;
    memcpy(&count, buf, 4);
    uint32_t off = 4;
    for (uint32_t i = 0; i < count && off < len; i++) {
        uint8_t tag = buf[off++];
        std::string a, b;
        switch (tag) {
            case 1:   // Notify(title, body): OSC 9 / OSC 777
                if (!haStr(buf, len, off, a) || !haStr(buf, len, off, b)) return;
                PostMessageW(g_hwnd, WM_APP_HOSTACT, HA_NOTIFY, (LPARAM)new NotifyMsg{ widen(a), widen(b) });
                break;
            case 2:   // Progress(state, value): OSC 9;4 taskbar progress, which lite does not draw
                if (off + 8 > len) return;
                off += 8;
                break;
            case 3:   // Clipboard(text): an OSC 52 write, already base64-decoded by the core
                if (!haStr(buf, len, off, a)) return;
                PostMessageW(g_hwnd, WM_APP_HOSTACT, HA_CLIP, (LPARAM)new std::string(a));
                break;
            case 4:   // Respond(reply): the answer to a query - back down the pty, from this thread
                if (!haStr(buf, len, off, a)) return;
                if (s->data != INVALID_HANDLE_VALUE && !a.empty())
                    ovIo(s->data, true, a.data(), nullptr, (DWORD)a.size());
                break;
            case 5:   // Unhandled(kind, detail): the VT tap. lite's log is the equivalent of
                      // AGWINTERM_VT_LOG - "app misbehaves here but works elsewhere" starts here.
                if (!haStr(buf, len, off, a) || !haStr(buf, len, off, b)) return;
                logInfo("vt unhandled %s: %s", a.c_str(), b.c_str());
                break;
            case 6:   // Bell
                PostMessageW(g_hwnd, WM_APP_HOSTACT, HA_BELL, 0);
                break;
            default:
                return;   // an unknown tag makes the rest of the buffer unparseable - stop
        }
    }
}

static DWORD WINAPI readerThread(void* param) {
    Session* s = (Session*)param;
    std::vector<uint8_t> buf(64 * 1024);
    DWORD n;
    while ((n = ovIo(s->data, false, nullptr, buf.data(), (DWORD)buf.size())) > 0) {
        bool bump = false;
        uint32_t haLen = 0;
        uint8_t* ha = nullptr;
        EnterCriticalSection(&g_lock);
        emu_feed(s->emu, buf.data(), n);
        ha = emu_take_host_actions(s->emu, &haLen);   // taken under the lock, RUN outside it
        // Count what fell off the front of history. scrollGeneration ticks once per line PUSHED
        // into history (main screen only — the alt screen never pushes), so anything that scrolled
        // without growing history was evicted at the far end. Only a counter is updated here; the
        // selection is reconciled against it in syncSelection. g_sel is shared state — the control
        // thread answers session.copy — so EVERY access to it is under g_lock, this one included.
        {
            FfiEmuInfo si{};
            if (emu_info(s->emu, &si)) {
                int64_t scrolled = si.scrollGeneration - s->lastGen;
                if (scrolled > 0) {
                    int64_t ev = scrolled - ((int64_t)si.historyCount - s->lastHist);
                    if (ev > 0) s->evicted += ev;
                }
                s->lastGen = si.scrollGeneration;
                s->lastHist = (int64_t)si.historyCount;
            }
        }
        // Unread: commands that FINISHED while the session wasn't on screen (noise-free — prompt
        // repaints don't move the completed count). Visible panes track instead of accumulating.
        if (!s->hidden) {
            bool visible = false;
            for (int p2 = 0; p2 < 2; p2++)
                if (g_pane[p2] >= 0 && g_pane[p2] < (int)g_sessions.size() && g_sessions[g_pane[p2]] == s) visible = true;
            int done = completedMarks(s);
            if (visible) { s->seenDone = done; if (s->unread) { s->unread = 0; bump = true; } }
            else { int u = done > s->seenDone ? done - s->seenDone : 0; if (u != s->unread) { s->unread = u; bump = true; } }
        }
        LeaveCriticalSection(&g_lock);
        if (ha) { runHostActions(s, ha, haLen); core_free_buf(ha, haLen); }
        InvalidateRect(windowForSession(s), nullptr, FALSE);
        if (bump) PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);   // repaint the badge
    }
    s->exited = true;   // EOF: child exited, host shut down, or we were superseded
    InvalidateRect(windowForSession(s), nullptr, FALSE);
    PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);   // reflect the exited marker in the tree
    return 0;
}

// A launchable shell "voice" for the New Session dialog.
struct Profile { std::wstring name; std::string app; std::vector<std::string> args; };

static bool isPwshApp(const char* app) {
    if (!app) return true;
    std::string a(app);
    for (char& c : a) c = (char)tolower((unsigned char)c);
    return a.find("powershell") != std::string::npos || a.find("pwsh") != std::string::npos;
}

// Detected shells on this machine (the "voices"). PowerShell + cmd are always present.
static std::vector<Profile> detectProfiles() {
    auto have = [](const char* p) { return GetFileAttributesA(p) != INVALID_FILE_ATTRIBUTES; };
    std::vector<Profile> v;
    v.push_back({ L"Windows PowerShell", "powershell.exe", {} });
    if (have("C:\\Program Files\\PowerShell\\7\\pwsh.exe"))
        v.push_back({ L"PowerShell 7", "C:\\Program Files\\PowerShell\\7\\pwsh.exe", {} });
    v.push_back({ L"Command Prompt", "cmd.exe", {} });
    if (have("C:\\Program Files\\Git\\bin\\bash.exe"))
        v.push_back({ L"Git Bash", "C:\\Program Files\\Git\\bin\\bash.exe", { "-i", "-l" } });
    char sys[MAX_PATH]; GetSystemDirectoryA(sys, MAX_PATH);
    std::string wsl = std::string(sys) + "\\wsl.exe";
    if (have(wsl.c_str())) v.push_back({ L"WSL", wsl, {} });
    return v;
}

// cols/rows + an optional profile (app/args) and cwd. Default (no app) = PowerShell with the prompt wrap.
static Session* attachSession(const char* id, int cols, int rows, const char* app,
                              const std::vector<std::string>* pargs, const char* cwd,
                              bool repaint = false);   // fwd

// The protocol's string fields are FIXED-SIZE arrays, and MSVC's strcpy_s does not truncate on an
// oversize source — it invokes the CRT invalid-parameter handler, whose default terminates the
// process outright: no window, no message box, no log line. Every value copied below can come from
// the state file, and saveSessionState persists sessionLiveCwd(), which reads the shell's cwd out of
// its PEB — a UNICODE_STRING with no MAX_PATH limit. So a session sitting in a deep directory could
// be saved perfectly and then hard-kill the NEXT launch, which is exactly the unexplainable "lite
// won't start" shape this branch exists to remove. Check before every copy.
static bool fitsField(const char* s, size_t cap) { return s && strlen(s) < cap; }

// ---- per-session split ----
//
// g_pane[1] used to be pure window state: it kept whatever shell it had while g_pane[0] changed
// under it, so switching sessions left the previous session's right-hand terminal on screen beside
// the new one. The split is a property of the SESSION now; these two keep the window agreeing with
// it.

static int indexOfSessionId(const std::string& id) {
    if (id.empty()) return -1;
    for (int i = 0; i < (int)g_sessions.size(); i++) if (g_sessions[i]->id == id) return i;
    return -1;
}

static int indexOfSession(const Session* s) {
    for (int i = 0; i < (int)g_sessions.size(); i++) if (g_sessions[i] == s) return i;
    return -1;
}

/// Point pane 1 at the primary session's own split shell, or at nothing. A link whose shell has died
/// (the user typed exit in it) is cleared here rather than left dangling.
///
/// PURE: it touches pane state only. closeSessionAt needs that — it runs this while holding g_lock
/// and before it has decided whether the user deliberately emptied the window, and a resize from
/// here would let a save land ahead of that decision and overwrite the state the guard exists to
/// protect. (It did: two restore-matrix cells caught it.)
static void resolveSplitForPrimary() {
    int p0 = g_pane[0];
    Session* prim = (p0 >= 0 && p0 < (int)g_sessions.size()) ? g_sessions[p0] : nullptr;
    int comp = prim ? indexOfSessionId(prim->splitId) : -1;
    if (prim && !prim->splitId.empty() && comp < 0) prim->splitId.clear();
    g_pane[1] = comp;
    if (g_pane[1] < 0 && g_focus != 0) g_focus = 0;   // nothing to focus on the right any more
}

/// The same, then lay the panes out. Call after ANY change to g_pane[0] — that is what makes the
/// split follow the session.
static void syncSplitToPrimary() {
    resolveSplitForPrimary();
    syncPaneSizes();
}

/// Show a session in the main pane, bringing its own split with it.
static void selectPrimary(int idx) {
    if (idx < 0 || idx >= (int)g_sessions.size()) return;
    g_pane[0] = idx;
    g_focus = 0;
    syncSplitToPrimary();
}

static Session* newSession(int cols, int rows, const char* app = nullptr,
                           const std::vector<std::string>* pargs = nullptr, const char* cwd = nullptr) {
    char idbuf[64];
    // _snprintf_s, not wsprintfA: wsprintfA does not bound its output to the destination, and the
    // prefix comes from --pipe (see parseLaunchArgs, which caps it — this is the second lock).
    _snprintf_s(idbuf, _TRUNCATE, "%s-%d", g_idPrefix.c_str(), g_seq++);
    agwinterm_ptyhost_Request req = agwinterm_ptyhost_Request_init_default;
    agwinterm_ptyhost_Reply rep = agwinterm_ptyhost_Reply_init_default;
    req.which_cmd = agwinterm_ptyhost_Request_create_tag;
    strcpy_s(req.cmd.create.id, idbuf);
    req.cmd.create.cols = (uint32_t)cols;
    req.cmd.create.rows = (uint32_t)rows;
    const char* useApp = app ? app : "powershell.exe";
    if (!fitsField(useApp, sizeof agwinterm_ptyhost_Create::app)) {
        // Nothing could launch this anyway. Returning nullptr lets restore keep it as a named dead
        // session (failedSpecSession) instead of losing the entry — or killing the process.
        logWarn("session create refused: app is %zu bytes, the protocol field holds %zu",
                strlen(useApp), sizeof agwinterm_ptyhost_Create::app - 1);
        return nullptr;
    }
    strcpy_s(req.cmd.create.app, useApp);
    if (cwd && *cwd) {
        // An over-long cwd is not worth failing the session over — start in the inherited directory
        // and say why, which beats both a dead pane and a terminated process.
        if (fitsField(cwd, sizeof agwinterm_ptyhost_Create::cwd)) strcpy_s(req.cmd.create.cwd, cwd);
        else logWarn("session create: cwd is %zu bytes and does not fit the protocol field (%zu) — "
                     "starting in the default directory instead", strlen(cwd), sizeof agwinterm_ptyhost_Create::cwd - 1);
    }
    std::string enc;
    if (pargs && !pargs->empty()) {                     // explicit profile args -> run app + args as-is
        // The wire holds 16 args (proto/ptyhost.options). The old cap of 4 silently rewrote the
        // command line of any profile with more than four — saved in full, relaunched truncated.
        const int kMaxArgs = (int)(sizeof agwinterm_ptyhost_Create::args / sizeof agwinterm_ptyhost_Create::args[0]);
        int n = (int)pargs->size();
        if (n > kMaxArgs) {
            logWarn("session create: %d args, the protocol carries %d — dropping the rest", n, kMaxArgs);
            n = kMaxArgs;
        }
        req.cmd.create.args_count = n;
        for (int i = 0; i < n; i++) {
            if (!fitsField((*pargs)[i].c_str(), sizeof agwinterm_ptyhost_Create::args[0])) {
                logWarn("session create refused: arg %d is %zu bytes, the protocol field holds %zu",
                        i, (*pargs)[i].size(), sizeof agwinterm_ptyhost_Create::args[0] - 1);
                return nullptr;                         // a truncated arg is a DIFFERENT command
            }
            strcpy_s(req.cmd.create.args[i], (*pargs)[i].c_str());
        }
    } else if (isPwshApp(useApp)) {                     // PowerShell: keep the interactive prompt wrap
        // -NoExit keeps the shell interactive after the wrap runs; -EncodedCommand runs AFTER the
        // profile so it chains (not replaces) the user's prompt.
        enc = base64(kPromptWrap);
        req.cmd.create.args_count = 4;
        strcpy_s(req.cmd.create.args[0], "-NoLogo");
        strcpy_s(req.cmd.create.args[1], "-NoExit");
        strcpy_s(req.cmd.create.args[2], "-EncodedCommand");
        strcpy_s(req.cmd.create.args[3], enc.c_str());
    } else {
        req.cmd.create.args_count = 0;                  // cmd / bash / wsl: launch bare
    }
    // AGWINTERM_* identity env, so the Claude skill / hooks / agwintermctl inside the
    // session auto-target LITE's control pipe (all non-UI features are protocol).
    auto setEnv = [&](int i, const char* k, const char* v) {
        strcpy_s(req.cmd.create.env[i].key, k);
        strcpy_s(req.cmd.create.env[i].value, v);
    };
    req.cmd.create.env_count = 6;
    setEnv(0, "AGWINTERM", "1");
    setEnv(1, "AGWINTERM_ENABLED", "1");
    std::string pipeNarrow = g_argPipe.empty() ? narrow(kAppId) : narrow(g_argPipe);
    setEnv(2, "AGWINTERM_PIPE", pipeNarrow.c_str());
    setEnv(3, "AGWINTERM_SESSION_ID", idbuf);
    setEnv(4, "AGWINTERM_PANE_ID", idbuf);
    // TERM_PROGRAM names the TERMINAL, so it takes the new name. The AGWINTERM_* vars above
    // deliberately do NOT: the agent skill, the status hooks and agwintermctl all read them.
    setEnv(5, "TERM_PROGRAM", "agliteterm");
    // An id the host already holds is REFUSED, and that single rejection is what used to sink every
    // spec of a restore at once. scanHostSessions() reserves the ids it can see, but it only sees
    // what `list` returns: a reply this build cannot decode (more sessions than its field storage
    // holds), a refused or unanswered list, or a host that gained sessions since startup all leave
    // g_seq pointing at an id already in use. So don't depend on the scan — take the host's "already
    // exists" at face value and step over it. Any other refusal is a real failure and returns.
    ReqOutcome oc = ReqOutcome::NoReply;
    for (int tries = 0; !request(req, &rep, &oc); tries++) {
        if (oc != ReqOutcome::Refused || !strstr(rep.error, "already exists") || tries >= 64) return nullptr;
        _snprintf_s(idbuf, _TRUNCATE, "%s-%d", g_idPrefix.c_str(), g_seq++);
        strcpy_s(req.cmd.create.id, idbuf);
        strcpy_s(req.cmd.create.env[3].value, idbuf);   // AGWINTERM_SESSION_ID
        strcpy_s(req.cmd.create.env[4].value, idbuf);   // AGWINTERM_PANE_ID
        rep = agwinterm_ptyhost_Reply_init_default;
        logWarn("session create refused (id in use) — retrying as '%s'", idbuf);
    }
    Session* s = attachSession(idbuf, cols, rows, app, pargs, cwd);
    if (!s) {
        // The create SUCCEEDED and only the attach failed, so the host is now holding a shell
        // nothing drives. Leaving it there leaks a process per attempt — and restore retries the
        // same spec on every launch, so the leak compounds. Take it back.
        logWarn("session '%s' was created but could not be attached — killing it rather than leaking it", idbuf);
        agwinterm_ptyhost_Request k = agwinterm_ptyhost_Request_init_default;
        agwinterm_ptyhost_Reply kr = agwinterm_ptyhost_Reply_init_default;
        k.which_cmd = agwinterm_ptyhost_Request_kill_tag;
        strcpy_s(k.cmd.kill.id, idbuf);
        request(k, &kr);
    }
    return s;
}

/// Attach to a session the host already has and wire it into the UI. Used for both halves of a
/// normal create (create-then-attach) and for ADOPTING a session that outlived a previous lite:
/// the pty-host is designed to survive the UI, so after a kill/crash/sign-out its shells are still
/// running and can simply be picked back up, scrollback and all.
static Session* attachSession(const char* id, int cols, int rows, const char* app,
                              const std::vector<std::string>* pargs, const char* cwd,
                              bool repaint) {
    agwinterm_ptyhost_Request req = agwinterm_ptyhost_Request_init_default;
    agwinterm_ptyhost_Reply rep = agwinterm_ptyhost_Reply_init_default;
    req.which_cmd = agwinterm_ptyhost_Request_attach_tag;
    // Adoption feeds this straight from the state file's D line, so the id is as untrusted as the
    // rest of the file. See fitsField: an over-long one would terminate the process, not truncate.
    if (!fitsField(id, sizeof agwinterm_ptyhost_Attach::id)) {
        logWarn("attach refused: session id is %zu bytes, the protocol field holds %zu",
                strlen(id ? id : ""), sizeof agwinterm_ptyhost_Attach::id - 1);
        return nullptr;
    }
    strcpy_s(req.cmd.attach.id, id);
    // ADOPTION only: the shell has been running without a client and has already painted its screen,
    // but the adopting side gets a brand-new empty emulator and the host forwards only NEW output.
    // Today the screen does come back anyway — syncPaneSizes() after restore almost always asks for
    // a size that differs from the one the restore placeholder was built with, and ConPTY re-emits
    // on any real resize. That is incidental, not a guarantee: restore at exactly the saved geometry
    // and there is no resize to piggyback on. `repaint` asks the host for the redraw outright (the
    // same thing the full app does via JiggleRepaint) so an adopted pane is never blank by luck.
    // A create-then-attach must NOT ask for it: there is nothing on that screen yet, and the jiggle
    // would race the shell's startup.
    req.cmd.attach.repaint = repaint;
    if (!request(req, &rep) || rep.which_body != agwinterm_ptyhost_Reply_attach_tag) return nullptr;
    // Adoption decides on g_hostLive, a snapshot taken before the window, the fonts, the toolbar and
    // the update check — seconds before this call. A shell that exits in between is still "adoptable"
    // per that snapshot, and attaching to it yields an immediate EOF: the saved session comes back as
    // a permanently dead pane instead of being relaunched, which is the outcome the exited filter
    // exists to prevent. The reply carries the answer first-hand, so use it and let the caller create.
    if (repaint && rep.body.attach.has_exited) {
        logWarn("session '%s' exited between the startup scan and restore — relaunching it instead of adopting", id);
        // Reap it while we know first-hand that it is dead: nothing is running behind an exited
        // session, and the record would otherwise outlive every future launch (see reapExited).
        agwinterm_ptyhost_Request k = agwinterm_ptyhost_Request_init_default;
        agwinterm_ptyhost_Reply kr = agwinterm_ptyhost_Reply_init_default;
        k.which_cmd = agwinterm_ptyhost_Request_kill_tag;
        strcpy_s(k.cmd.kill.id, id);
        request(k, &kr);
        return nullptr;
    }

    Session* s = new Session();
    s->id = id;
    s->app = app ? app : "";        // remember the launch spec for session restore
    if (pargs) s->args = *pargs;
    s->cwd = cwd ? cwd : "";
    s->ws = (g_activeWs >= 0 && g_activeWs < (int)g_workspaces.size()) ? g_activeWs : 0;   // into the active workspace
    s->emu = emu_new(cols, rows);
    // A CREATED session's host and emulator are both at this grid, so the latch says so: the first
    // syncPaneSizes at the same geometry is then the no-op it should be (it used to forward a
    // 0 -> N "change" the host reflowed on), and a session created while the window is minimised
    // reports its real grid in `tree` instead of 0 (#23). An ADOPTED session's host is at whatever
    // grid it had; the latch stays 0 so the first layout really does resize it.
    if (!repaint) { s->cols = cols; s->rows = rows; }
    s->childPid = rep.body.attach.child_pid;
    s->data = openPipe(std::wstring(rep.body.attach.pipe, rep.body.attach.pipe + strlen(rep.body.attach.pipe)), 5000, true);
    if (s->data == INVALID_HANDLE_VALUE) { emu_free(s->emu); delete s; return nullptr; }
    // NOTE: AttachReply.scrollback stays callback-decoded (unbounded), so an adopted session comes
    // back without its HISTORY — the repaint above brings back the current screen, which is what
    // makes the pane look alive. The shell itself, and anything running in it, survives either way;
    // seeding the scrollback is a separate improvement.
    s->reader = CreateThread(nullptr, 0, readerThread, s, 0, nullptr);
    EnterCriticalSection(&g_lock);
    g_sessions.push_back(s);
    emitEvent("session", s->id, "created");
    emitEvent("tree");
    g_userEmptied = false;   // the window has sessions again: a later empty list is transient, not deliberate
    LeaveCriticalSection(&g_lock);
    PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);   // add the session to the tree (UI thread)
    return s;
}

/// The sessions the host currently holds. On a normal start this is empty; after lite was killed it
/// still lists the shells from the previous run, which is what makes adoption possible (and what
/// made every restore create collide with `session '<id>' already exists`).
struct HostSession {
    std::string id;
    bool exited = false;     // the shell behind it is gone: the host keeps the entry, attaching gets an EOF
    bool attached = false;   // another window is driving it right now — attaching would STEAL it
    bool adoptable() const { return !exited && !attached; }
};
static std::vector<HostSession> hostSessions() {
    std::vector<HostSession> out;
    agwinterm_ptyhost_Request req = agwinterm_ptyhost_Request_init_default;
    agwinterm_ptyhost_Reply rep = agwinterm_ptyhost_Reply_init_default;
    req.which_cmd = agwinterm_ptyhost_Request_list_tag;
    ReqOutcome oc = ReqOutcome::NoReply;
    if (!request(req, &rep, &oc) || rep.which_body != agwinterm_ptyhost_Reply_list_tag) {
        // Say it: an empty list here is indistinguishable from "the host holds nothing", and the
        // difference decides whether restore adopts or re-creates.
        if (oc != ReqOutcome::Ok)
            logWarn("pty-host: could not read the live session list (%s) — restore will create fresh sessions",
                    oc == ReqOutcome::Undecodable ? "reply did not decode"
                                                  : oc == ReqOutcome::Refused ? "host refused" : "no reply");
        return out;
    }
    for (pb_size_t i = 0; i < rep.body.list.sessions_count; i++) {
        const auto& si = rep.body.list.sessions[i];
        out.push_back({ si.id, si.has_exited, si.attached });
    }
    return out;
}

// What the host held when this lite connected, read ONCE at startup (the list is also the handshake
// probe, so asking twice was a wasted round trip). Filled by scanHostSessions().
static std::vector<HostSession> g_hostLive;
static std::vector<std::string> g_adoptedIds;   // ids this launch picked back up (never reaped)

/// Read the host's sessions and make sure this window can never mint an id the host already has.
/// Must run for EVERY launch, not just a restoring one: with --no-restore (or a state file that
/// parsed to nothing) after a kill, the host still holds `<prefix>-1`, and a create it rejects used
/// to take the whole launch down with "could not create the first session".
static void scanHostSessions() {
    g_hostLive = hostSessions();
    for (const auto& hs : g_hostLive) {
        size_t dash = hs.id.rfind('-');
        if (dash != std::string::npos && hs.id.compare(0, dash, g_idPrefix) == 0) {
            int n = atoi(hs.id.c_str() + dash + 1);
            if (n >= g_seq) g_seq = n + 1;
        }
    }
}

static void killSession(Session* s) {
    { LockG lk; if (g_sel.sess == s) g_sel.clear(); }   // keyed by session: don't outlive it
    if (s->id.empty()) return;            // restore placeholder: nothing on the host to kill
    agwinterm_ptyhost_Request req = agwinterm_ptyhost_Request_init_default;
    agwinterm_ptyhost_Reply rep = agwinterm_ptyhost_Reply_init_default;
    req.which_cmd = agwinterm_ptyhost_Request_kill_tag;
    strcpy_s(req.cmd.kill.id, s->id.c_str());
    request(req, &rep);
}

// What undo-close (Ctrl+Shift+T) puts back: the launch spec plus the two per-session texts, name
// and context — a reopened session that came back with its name but not its context would have
// lost a value the user was told was set (P3).
struct ClosedSpec { std::wstring name; int ws; std::string app, cwd; std::vector<std::string> args; std::wstring context; };
static std::vector<ClosedSpec> g_closedStack;   // recently closed sessions, for Reopen Closed Session

static void closeSessionAt(int idx) {
    if (idx < 0 || idx >= (int)g_sessions.size()) return;
    Session* cs = g_sessions[idx];
    // A split shell exists only to be one session's right-hand pane, so it dies with that session -
    // otherwise closing the owner would strand a running shell nothing can reach: it is hidden, so
    // it is in no tree and no sidebar. One level of recursion only; a split owns no split of its own.
    if (!cs->splitId.empty()) {
        int ci = indexOfSessionId(cs->splitId);
        cs->splitId.clear();
        if (ci >= 0 && ci != idx) {
            closeSessionAt(ci);
            idx = indexOfSession(cs);          // the erase above may have shifted us
            if (idx < 0) return;
        }
    }
    // ...and the other direction: a split shell that dies on its own (the user typed exit in it)
    // must not leave its owner pointing at nothing.
    for (Session* other : g_sessions) if (other->splitId == cs->id) other->splitId.clear();
    if (!cs->hidden) {   // remember the launch spec so it can be reopened (skip transient split/popup shells)
        if (g_closedStack.size() >= 16) g_closedStack.erase(g_closedStack.begin());
        g_closedStack.push_back({ cs->name, cs->ws, cs->app, cs->cwd, cs->args, cs->context });
    }
    killSession(g_sessions[idx]);
    EnterCriticalSection(&g_lock);
    // Taken BEFORE the erase: the split pane's shell is hidden (never persisted, never in the tree)
    // but it is on screen in this window, so it still counts against "the window is empty". After the
    // erase the pane fixup below can repoint a pane at ANY surviving session — including a quick
    // popup's, which lives in its own window — so the pane indices can no longer answer this.
    const Session* splitShell = (g_pane[1] >= 0 && g_pane[1] < (int)g_sessions.size() && g_pane[1] != idx)
                                ? g_sessions[g_pane[1]] : nullptr;
    emitEvent("session", g_sessions[idx]->id, "closed");
    g_sessions.erase(g_sessions.begin() + idx);
    emitEvent("tree");
    for (int p = 0; p < 2; p++) {
        if (g_pane[p] == idx) g_pane[p] = g_sessions.empty() ? -1 : max(0, idx - 1);
        else if (g_pane[p] > idx) g_pane[p]--;
    }
    if (g_sessions.empty()) g_pane[1] = -1;   // unsplit when the last pane dies
    resolveSplitForPrimary();                // pane 1 follows whichever session pane 0 now shows
    // "Emptied" means NOTHING IS LEFT ON SCREEN IN THIS WINDOW, which is neither the raw session
    // count nor the save's count. The save writes only non-hidden sessions, so a quick/scratch popup
    // (its own window) keeps g_sessions non-empty while the save sees zero — judged by the raw vector
    // the guard would refuse that save and the sessions the user just closed would be read straight
    // back out of the untouched file on the next launch. A split shell is hidden too, but it is
    // right there in pane 1: the window is not empty, so this is not the one save allowed to write a
    // zero-session file (and to drop the .bak).
    //
    // Since a split BELONGS to its session (it closes with it), a split shell should no longer be
    // able to outlive the session it was opened from — so the splitShell clause below is now a
    // belt-and-braces guard rather than the live case it was written for. It stays because the cost
    // is one pointer compare and the failure it prevents is overwriting good state.
    bool anyVisible = false;
    for (const Session* vs : g_sessions) if (!vs->hidden || vs == splitShell) { anyVisible = true; break; }
    bool allGone = g_sessions.empty();
    // Set under the lock, with the session list it was judged from: this runs on the control-pipe
    // thread as well as the UI one, and saveSessionState reads the flag to decide whether it may
    // write a zero-session file and drop the .bak.
    if (!anyVisible) g_userEmptied = true;
    LeaveCriticalSection(&g_lock);
    // The user closed the last session, so the window goes with it. This is the ONLY path that may
    // legitimately write a zero-session state file; every other empty list is transient and the save
    // refuses it (see saveSessionState). The flag describes THIS empty, not the process: driven over
    // the control pipe the DestroyWindow below is a no-op (wrong thread) and the window lives on, so
    // adding a session clears it again — otherwise the guard would stay off for good.
    if (allGone) { DestroyWindow(g_hwnd); return; }
    syncPaneSizes();
    InvalidateRect(g_hwnd, nullptr, FALSE);
    PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);   // drop the session from the tree
}

// Reopen the most recently closed session, relaunched with its remembered profile + cwd.
static void reopenClosed() {
    if (g_closedStack.empty()) return;
    ClosedSpec sp = g_closedStack.back(); g_closedStack.pop_back();
    if (sp.ws >= 0 && sp.ws < (int)g_workspaces.size()) g_activeWs = sp.ws;
    int c, r; newSessionGrid(g_focus, &c, &r);
    Session* s = newSession(c, r, sp.app.empty() ? nullptr : sp.app.c_str(),
                            sp.args.empty() ? nullptr : &sp.args, sp.cwd.empty() ? nullptr : sp.cwd.c_str());
    if (s) {
        { LockG hold; s->name = sp.name; s->context = sp.context; }   // `tree` reads both on pipe threads
        selectPrimary((int)g_sessions.size() - 1); InvalidateRect(g_hwnd, nullptr, FALSE);
    }
}
static void toggleSplit();   // fwd
static void closeFocused() {
    if (g_focus == 1 && g_pane[1] >= 0) { toggleSplit(); return; }   // closing the split pane = unsplit
    closeSessionAt(g_pane[0]);
}

// Toggle the 2-pane split. Splitting spawns an INDEPENDENT new shell for the second pane (separate
// output) — but marked hidden, so it is NOT a sidebar/tree session (agterm: a split isn't a new
// session). Unsplitting removes that shell.
static void toggleSplit() {
    int p0 = g_pane[0];
    Session* prim = (p0 >= 0 && p0 < (int)g_sessions.size()) ? g_sessions[p0] : nullptr;
    if (!prim) return;                               // nothing to attach a split to
    if (g_pane[1] < 0) {
        int c, r; newSessionGrid(g_focus, &c, &r);   // approximate; syncPaneSizes resizes both after
        Session* s = newSession(c, r);
        if (s) {
            s->hidden = true;
            prim->splitId = s->id;                   // the split belongs to THIS session
            g_pane[1] = (int)g_sessions.size() - 1; g_focus = 1;
        }
    } else {
        int sp = g_pane[1];
        g_pane[1] = -1; g_focus = 0;
        prim->splitId.clear();
        if (sp >= 0 && sp < (int)g_sessions.size()) {   // remove the hidden split shell
            killSession(g_sessions[sp]);
            EnterCriticalSection(&g_lock);
            g_sessions.erase(g_sessions.begin() + sp);
            if (g_pane[0] > sp) g_pane[0]--;            // fix the surviving pane's index
            LeaveCriticalSection(&g_lock);
        }
    }
    syncPaneSizes();
    PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
    InvalidateRect(g_hwnd, nullptr, FALSE);
}

// Cycle the MAIN pane through visible sessions (skips hidden split shells). dir = +1 next, -1 prev.
static void cycleSession(int dir) {
    int n = (int)g_sessions.size();
    if (n == 0) return;
    int i = g_pane[0];
    for (int k = 0; k < n; k++) {
        i = (i + dir + n) % n;
        if (i >= 0 && i < n && !g_sessions[i]->hidden) { selectPrimary(i); break; }
    }
    syncPaneSizes();
    PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
    InvalidateRect(g_hwnd, nullptr, FALSE);
}

// Build one GDI font for a catalog spec + weight/slant. The kind selects charset/precision/quality so
// raster (.fon) and bitmap-embedded (TTF) faces render crisp while scalable faces stay antialiased.
static HFONT createFontSpec(const FontEntry& e, const FontSize& s, bool bold, bool italic) {
    int charset = (e.kind == 1) ? OEM_CHARSET : DEFAULT_CHARSET;
    int precis  = (e.kind == 1) ? OUT_RASTER_PRECIS : (e.kind == 2 ? OUT_DEFAULT_PRECIS : OUT_TT_PRECIS);
    int quality = (e.kind == 0) ? CLEARTYPE_QUALITY : NONANTIALIASED_QUALITY;
    return CreateFontW(s.h, s.w, 0, 0, bold ? FW_BOLD : FW_NORMAL, italic, FALSE, FALSE,
                       charset, precis, CLIP_DEFAULT_PRECIS, quality, FIXED_PITCH | FF_MODERN,
                       s.face ? s.face : e.face);
}
// (Re)create the four terminal fonts from the current catalog selection, recompute the character cell
// (g_cw/g_ch) from the regular font's metrics, and relayout every session.
static bool agbfLoad(int strike, bool complete);   // fwd (AGWin Bitmap pack module, defined pre-painter)
static bool g_agbf;                          // active: render from the pack, not GDI text
struct AgbfCell { uint16_t w, h; };
static AgbfCell agbfCell(int strike);        // cell geometry of the loaded pack

static void applyFont() {
    if (g_catalog.empty()) return;
    if (g_faceIdx < 0 || g_faceIdx >= (int)g_catalog.size()) g_faceIdx = 0;
    FontEntry& e = g_catalog[g_faceIdx];
    if (g_sizeIdx < 0 || g_sizeIdx >= (int)e.sizes.size()) g_sizeIdx = 0;
    FontSize& s = e.sizes[g_sizeIdx];
    // AGWin Bitmap (kind 3): cell metrics come from the pack header, no GDI font is measured. The
    // GDI fonts below are still (re)built as a fallback for non-pack UI paths (dialog preview etc).
    g_agbf = false;
    if (e.kind == 3 && agbfLoad(s.h, wcscmp(e.face, L"AGWin Bitmap Complete") == 0)) {
        AgbfCell cc = agbfCell(s.h);
        g_agbf = true; g_cw = cc.w; g_ch = cc.h;
    }
    HFONT nf[4];
    for (int i = 0; i < 4; i++) nf[i] = createFontSpec(e, s, i & 1, (i & 2) != 0);
    HDC dc = GetDC(nullptr);
    HGDIOBJ old = SelectObject(dc, nf[0]);
    TEXTMETRICW tm; GetTextMetricsW(dc, &tm);
    // Cell width from 'X', not tmAveCharWidth: identical for pure-mono fonts, but dual-width fonts
    // (GNU Unifont: 8px Latin + 16px CJK) report the WIDE advance as the average, which would give
    // every ASCII char a double cell. CJK still draws 16px wide and the emulator gives it 2 cells.
    int xw = 0;
    GetCharWidth32W(dc, L'X', L'X', &xw);
    if (!g_agbf) { g_cw = xw > 0 ? xw : tm.tmAveCharWidth; g_ch = tm.tmHeight; }   // pack owns the cell
    SelectObject(dc, old);
    ReleaseDC(nullptr, dc);
    for (int i = 0; i < 4; i++) { if (g_fonts[i]) DeleteObject(g_fonts[i]); g_fonts[i] = nf[i]; }
    if (g_hwnd) {                       // live switch: resize every session to the new cell + repaint
        if (!g_sessions.empty()) syncPaneSizes();
        InvalidateRect(g_hwnd, nullptr, TRUE);
    }
}
// Populate the font catalog: bundled Meslo + the classic cmd.exe faces (Terminal at its DOS sizes,
// Fixedsys, Consolas, Lucida Console) + the bundled bitmap fonts that actually loaded.
static void buildFontCatalog() {
    g_catalog.clear();
    g_catalog.push_back({ L"Nerd Font", g_ttFace.c_str(), 0, true,
        { {L"14",-14,0},{L"16",-16,0},{L"18",-18,0},{L"20",-20,0},{L"24",-24,0} } });
    g_catalog.push_back({ L"Terminal", L"Terminal", 1, true,
        { {L"4×6",6,4},{L"5×8",8,5},{L"6×8",8,6},{L"7×12",12,7},{L"8×8",8,8},
          {L"8×12",12,8},{L"8×16",16,8},{L"10×18",18,10},{L"12×16",16,12},{L"16×12",12,16} } });
    g_catalog.push_back({ L"Fixedsys", L"Fixedsys", 1, true, { {L"8×15",15,0} } });
    g_catalog.push_back({ L"Consolas", L"Consolas", 0, true,
        { {L"14",-14,0},{L"16",-16,0},{L"18",-18,0},{L"20",-20,0},{L"24",-24,0} } });
    g_catalog.push_back({ L"Lucida Console", L"Lucida Console", 0, true,
        { {L"14",-14,0},{L"16",-16,0},{L"18",-18,0},{L"20",-20,0},{L"24",-24,0} } });
    if (g_haveCozette)
        g_catalog.push_back({ L"Cozette", L"CozetteVector", 0, true,
            { {L"13",-13,0},{L"16",-16,0},{L"20",-20,0},{L"26",-26,0} } });
    if (g_haveTamzen)
        g_catalog.push_back({ L"Tamzen", L"TamzenForPowerline", 2, true,
            { {L"7×14",14,0},{L"8×16",16,0},{L"10×20",20,0} } });
    // The classic console bitmap families (bundled as crisp TTF/OTF conversions; NONANTIALIASED at
    // their native strikes so they render pixel-exact). Labels = original bitmap cell sizes.
    if (g_haveTerminus)
        g_catalog.push_back({ L"Terminus", L"Terminus (TTF)", 2, true,
            { {L"6×12",12,0},{L"8×14",14,0},{L"8×16",16,0},{L"10×18",18,0},{L"10×20",20,0},
              {L"11×22",22,0},{L"12×24",24,0},{L"14×28",28,0},{L"16×32",32,0} } });
    if (g_haveSpleen)   // one family PER strike upstream -> per-size face overrides
        g_catalog.push_back({ L"Spleen", L"Spleen 8x16", 2, true,
            { {L"6×12",12,0,L"Spleen 6x12"},{L"8×16",16,0,L"Spleen 8x16"},{L"12×24",24,0,L"Spleen 12x24"},
              {L"16×32",32,0,L"Spleen 16x32"},{L"32×64",64,0,L"Spleen 32x64"} } });
    if (g_haveUnscii)   // negative h = em height; the probed values that yield the true 8px advance
        g_catalog.push_back({ L"UNSCII", L"unscii", 2, true,
            { {L"8×8",-7,0,L"unscii-8"},{L"8×16",-13,0,L"unscii"} } });
    if (g_haveUnifont)
        g_catalog.push_back({ L"GNU Unifont", L"Unifont", 2, true,
            { {L"8×16",16,0},{L"16×32",32,0} } });
    // AGWin Bitmap: pre-rasterized .agbf packs (kind 3). The number is an EM size, exactly like
    // the TrueType faces — "AGWin Bitmap 16" is the same visual size as "Nerd Font 16"; the pack
    // header carries the actual cell (e.g. em 16 -> a 10×21 cell for JetBrainsMono).
    if (g_haveAgbf)
        g_catalog.push_back({ L"AGWin Bitmap", L"AGWin Bitmap", 3, true,
            { {L"14",14,0},{L"16",16,0},{L"18",18,0},{L"20",20,0} } });
    if (g_haveAgbfC)   // the full-repertoire family (every glyph of the source Nerd Font)
        g_catalog.push_back({ L"AGWin Bitmap Complete", L"AGWin Bitmap Complete", 3, true,
            { {L"14",14,0},{L"16",16,0},{L"18",18,0},{L"20",20,0} } });
}
static int catFace(const wchar_t* label) {
    for (int i = 0; i < (int)g_catalog.size(); i++) if (wcscmp(g_catalog[i].label, label) == 0) return i;
    return -1;
}
// First-run font. AGWin Bitmap Complete 16 when its pack shipped alongside the exe: it carries the
// FULL repertoire of the source Nerd Font (68k glyphs — CJK, powerline, box drawing, emoji), so a
// prompt engine or a TUI renders correctly out of the box instead of showing tofu until the user
// finds Properties. Falls back to Terminal 8x12, then the first catalog entry.
static void setDefaultFont() {
    int c = catFace(L"AGWin Bitmap Complete");
    if (c >= 0) { g_faceIdx = c; g_sizeIdx = 1; return; }   // 1 = "16"
    int t = catFace(L"Terminal");
    g_faceIdx = t >= 0 ? t : 0; g_sizeIdx = t >= 0 ? 5 : 0;   // 5 = "8x12" in the Terminal size list
}
// Persist the selection by face + size (survives catalog reordering across versions).
static void saveFontSel() {
    if (g_faceIdx < 0 || g_faceIdx >= (int)g_catalog.size()) return;
    const FontEntry& e = g_catalog[g_faceIdx]; const FontSize& s = e.sizes[g_sizeIdx];
    RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"FontFace", REG_SZ, e.face, (DWORD)((wcslen(e.face) + 1) * sizeof(wchar_t)));
    DWORD h = (DWORD)(int)s.h, w = (DWORD)(int)s.w;
    RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"FontH", REG_DWORD, &h, sizeof(h));
    RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"FontW", REG_DWORD, &w, sizeof(w));
}
static bool g_fontFromReg = false;   // did the remembered selection resolve, or did we fall back?
static void loadFontSel() {
    g_fontFromReg = false;
    wchar_t face[64] = L""; DWORD sz = sizeof(face);
    if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"FontFace", RRF_RT_REG_SZ, nullptr, face, &sz) != ERROR_SUCCESS) { setDefaultFont(); return; }
    DWORD h = 0, w = 0, s = sizeof(DWORD);
    RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"FontH", RRF_RT_REG_DWORD, nullptr, &h, &s); s = sizeof(DWORD);
    RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"FontW", RRF_RT_REG_DWORD, nullptr, &w, &s);
    for (int fi = 0; fi < (int)g_catalog.size(); fi++) {
        if (wcscmp(g_catalog[fi].face, face) != 0) continue;
        for (int si = 0; si < (int)g_catalog[fi].sizes.size(); si++)
            if ((DWORD)(int)g_catalog[fi].sizes[si].h == h && (DWORD)(int)g_catalog[fi].sizes[si].w == w) { g_faceIdx = fi; g_sizeIdx = si; g_fontFromReg = true; return; }
        g_faceIdx = fi; g_sizeIdx = 0; g_fontFromReg = true; return;   // face matched, size didn't — keep the face
    }
    setDefaultFont();
}
static void loadColors() {   // Properties->Colors overrides (default fg/bg + on/off), persisted like the font
    DWORD v, sz;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"CustomColors", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_customColors = v != 0;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"DefFg", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_defFg = v & 0xFFFFFF;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"DefBg", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_defBg = v & 0xFFFFFF;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"DosPalette", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_dosPalette = v != 0;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"Theme", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS && v <= TH_CLASSIC) g_themeMode = (int)v;
    // The same range `sidebar width` accepts (kSidebarMinW..kSidebarMaxW): one number set, two readers.
    // In range is not the same as fitting the window this instance saved (WinW-<instance>, read
    // later by loadWindowRect): the pair is checked against each other at the first WM_SIZE, once
    // the client width exists — fitSidebarToClient, from OnSize.
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"SidebarW", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS && (int)v >= kSidebarMinW && (int)v <= kSidebarMaxW) g_sidebarW = g_sidebarWPref = v;
    // 0 = follow the shell. The range is clamped rather than trusted: this is a font height, and a
    // hand-edited 2000 would make the sidebar a single unreadable row.
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"SidebarFontPt", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS && (v == 0 || (v >= 6 && v <= 24))) g_treeFontPt = (int)v;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"ShowSidebar", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_showSidebar = v != 0;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"ShowToolbar", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_showToolbar = v != 0;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"ShowStatus", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_showStatus = v != 0;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"FlagView", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_flagView = v != 0;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"RightClickPaste", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_rightClickPaste = v != 0;
    sz = sizeof(v); if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"CopyOnCtrlC", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_copyOnCtrlC = v != 0;
}
static void loadKeys() {   // configurable key bindings; absent = unbound (0)
    // One seeded default: Ctrl+Shift+P opens the command palette (parity with the full app).
    // Any saved Keyboard settings override it — the dialog writes every action, including 0s.
    g_keys[KB_PALETTE] = MAKEWORD('P', HOTKEYF_CONTROL | HOTKEYF_SHIFT);
    for (int a = 0; a < KB_COUNT; a++) {
        DWORD v = 0, sz = sizeof(v);
        if (RegGetValueW(HKEY_CURRENT_USER, kRegKey, kKbInfo[a].reg, RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS) g_keys[a] = (WORD)v;
    }
    // Font zoom was removed (raster faces only exist at their pack's strike sizes). The Keyboard
    // dialog wrote every action, so these linger in the registry on any machine that saved keys;
    // sweep them so an inspected key list matches the actions lite actually has.
    for (const wchar_t* dead : { L"Key_ZoomIn", L"Key_ZoomOut", L"Key_ZoomReset" })
        RegDeleteKeyValueW(HKEY_CURRENT_USER, kRegKey, dead);
}
static void saveKeys() {
    for (int a = 0; a < KB_COUNT; a++) {
        DWORD v = g_keys[a];
        RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, kKbInfo[a].reg, REG_DWORD, &v, sizeof(v));
    }
}
static void saveColors() {
    DWORD v;
    v = g_customColors ? 1 : 0; RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"CustomColors", REG_DWORD, &v, sizeof(v));
    v = g_defFg; RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"DefFg", REG_DWORD, &v, sizeof(v));
    v = g_defBg; RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"DefBg", REG_DWORD, &v, sizeof(v));
    v = g_dosPalette ? 1 : 0; RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"DosPalette", REG_DWORD, &v, sizeof(v));
    v = (DWORD)g_themeMode;   RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"Theme", REG_DWORD, &v, sizeof(v));
    v = g_sidebarWPref; RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"SidebarW", REG_DWORD, &v, sizeof(v));   // the ASKED width, never a transient fit
    v = (DWORD)g_treeFontPt; RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"SidebarFontPt", REG_DWORD, &v, sizeof(v));
    v = g_showSidebar ? 1 : 0; RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"ShowSidebar", REG_DWORD, &v, sizeof(v));
    v = g_showToolbar ? 1 : 0; RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"ShowToolbar", REG_DWORD, &v, sizeof(v));
    v = g_showStatus ? 1 : 0; RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"ShowStatus", REG_DWORD, &v, sizeof(v));
    v = g_flagView ? 1 : 0;   RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, L"FlagView", REG_DWORD, &v, sizeof(v));
}
// Window geometry persistence. loadWindowRect resolves the saved rect (clamped onto a visible monitor
// so an unplugged screen / resolution change can't strand the window off-screen) and is applied at
// CreateWindow time so the window appears there directly — no create-then-move flash.
static std::wstring geoName(const wchar_t* base) {   // per-instance geometry value names
    return g_isDefaultInstance ? base : (std::wstring(base) + L"-" + g_instance);
}
static bool loadWindowRect(RECT* out, bool* maxed) {
    const wchar_t* k = kRegKey;
    DWORD x, y, w, h, mx = 0, sz;
    sz = sizeof(DWORD); if (RegGetValueW(HKEY_CURRENT_USER, k, geoName(L"WinW").c_str(), RRF_RT_REG_DWORD, nullptr, &w, &sz) != ERROR_SUCCESS) return false;
    sz = sizeof(DWORD); if (RegGetValueW(HKEY_CURRENT_USER, k, geoName(L"WinH").c_str(), RRF_RT_REG_DWORD, nullptr, &h, &sz) != ERROR_SUCCESS) return false;
    sz = sizeof(DWORD); if (RegGetValueW(HKEY_CURRENT_USER, k, geoName(L"WinX").c_str(), RRF_RT_REG_DWORD, nullptr, &x, &sz) != ERROR_SUCCESS) return false;
    sz = sizeof(DWORD); if (RegGetValueW(HKEY_CURRENT_USER, k, geoName(L"WinY").c_str(), RRF_RT_REG_DWORD, nullptr, &y, &sz) != ERROR_SUCCESS) return false;
    sz = sizeof(DWORD); RegGetValueW(HKEY_CURRENT_USER, k, geoName(L"WinMax").c_str(), RRF_RT_REG_DWORD, nullptr, &mx, &sz);
    if ((int)w < 200 || (int)h < 120) return false;   // sanity guard against a corrupt/degenerate rect
    RECT rc{ (LONG)(int)x, (LONG)(int)y, (LONG)((int)x + (int)w), (LONG)((int)y + (int)h) };
    if (!MonitorFromRect(&rc, MONITOR_DEFAULTTONULL)) {   // fully off every screen -> centre on the nearest
        MONITORINFO mi{ sizeof(mi) }; GetMonitorInfoW(MonitorFromRect(&rc, MONITOR_DEFAULTTONEAREST), &mi);
        int cw = mi.rcWork.right - mi.rcWork.left, ch = mi.rcWork.bottom - mi.rcWork.top;
        int ww = min((int)w, cw), hh = min((int)h, ch);
        rc = { mi.rcWork.left + (cw - ww) / 2, mi.rcWork.top + (ch - hh) / 2, 0, 0 };
        rc.right = rc.left + ww; rc.bottom = rc.top + hh;
    }
    *out = rc; *maxed = mx != 0; return true;
}
static void saveWindowRect() {
    WINDOWPLACEMENT wp{ sizeof(wp) };
    if (!g_hwnd || !GetWindowPlacement(g_hwnd, &wp)) return;
    RECT rc = wp.rcNormalPosition;   // the restore rect (correct even while maximized/minimized)
    const wchar_t* k = kRegKey;
    DWORD x = (DWORD)rc.left, y = (DWORD)rc.top, w = (DWORD)(rc.right - rc.left), h = (DWORD)(rc.bottom - rc.top);
    DWORD mx = (wp.showCmd == SW_SHOWMAXIMIZED || (wp.flags & WPF_RESTORETOMAXIMIZED)) ? 1 : 0;
    RegSetKeyValueW(HKEY_CURRENT_USER, k, geoName(L"WinX").c_str(), REG_DWORD, &x, sizeof(x));
    RegSetKeyValueW(HKEY_CURRENT_USER, k, geoName(L"WinY").c_str(), REG_DWORD, &y, sizeof(y));
    RegSetKeyValueW(HKEY_CURRENT_USER, k, geoName(L"WinW").c_str(), REG_DWORD, &w, sizeof(w));
    RegSetKeyValueW(HKEY_CURRENT_USER, k, geoName(L"WinH").c_str(), REG_DWORD, &h, sizeof(h));
    RegSetKeyValueW(HKEY_CURRENT_USER, k, geoName(L"WinMax").c_str(), REG_DWORD, &mx, sizeof(mx));
}

// ---- session/workspace restore ----
static std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, 0); WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr); return s;
}
static std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, 0); MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n); return w;
}
// State file: %LOCALAPPDATA%\agliteterm\sessions.tsv (per-user, created on demand).
static std::wstring stateFilePath() {
    std::wstring dir = stateDir();
    if (dir.empty()) { return {}; }
    if (!CreateDirectoryW(dir.c_str(), nullptr)) {
        DWORD e = GetLastError();
        if (e != ERROR_ALREADY_EXISTS) logWarn("state dir could not be created: %s (err %lu)", narrow(dir).c_str(), e);
    }
    // Named instances keep their own session state; the default instance keeps the classic name.
    return dir + (g_isDefaultInstance ? L"\\sessions.tsv" : (L"\\sessions-" + g_instance + L".tsv"));
}
// Snapshot the workspaces + (visible) sessions so next launch can rebuild them. Tab-separated; a
// The session's LIVE working directory: the prompt wrap (and starship/omp shell integration) emits
// OSC 7 file:// URLs, which the core emulator tracks. Convert "file://host/C:/dir%20x" -> "C:\dir x";
// empty (no OSC 7 seen, or the dir vanished) means "fall back to the creation cwd". Call under g_lock.
// Read a process's live current directory from its PEB (ProcessParameters.CurrentDirectory) —
// conhost/ConPTY filters cwd OSC sequences out of the output stream, so asking the shell process
// itself is the only reliable channel. Returns "" on any failure.
static std::string processCwd(DWORD pid) {
    typedef LONG(WINAPI* fnQIP)(HANDLE, int, void*, ULONG, ULONG*);
    static fnQIP qip = (fnQIP)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess");
    if (!qip || !pid) return "";
    HANDLE h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
    if (!h) return "";
    std::string out;
    struct { PVOID Reserved1; PVOID PebBaseAddress; PVOID Reserved2[2]; ULONG_PTR UniqueProcessId; PVOID Reserved3; } pbi{};
    if (qip(h, 0 /*ProcessBasicInformation*/, &pbi, sizeof pbi, nullptr) == 0 && pbi.PebBaseAddress) {
        PVOID params = nullptr; SIZE_T rd = 0;
        // PEB+0x20 = ProcessParameters (x64); RTL_USER_PROCESS_PARAMETERS+0x38 = CurrentDirectory.DosPath (UNICODE_STRING)
        if (ReadProcessMemory(h, (char*)pbi.PebBaseAddress + 0x20, &params, sizeof params, &rd) && params) {
            struct { USHORT Len, Max; PWSTR Buf; } us{};
            if (ReadProcessMemory(h, (char*)params + 0x38, &us, sizeof us, &rd) && us.Buf && us.Len) {
                std::wstring w(us.Len / 2, L'\0');
                if (ReadProcessMemory(h, us.Buf, &w[0], us.Len, &rd)) {
                    while (!w.empty() && w.back() == L'\\' && w.size() > 3) w.pop_back();   // "C:\x\" -> "C:\x", keep "C:\"
                    out = narrow(w);
                }
            }
        }
    }
    CloseHandle(h);
    return out;
}

static std::string sessionLiveCwd(const Session* s) {
    std::string cw = processCwd(s->childPid);            // the shell's real cwd, straight from its PEB
    if (!cw.empty()) return cw;
    if (!s->emu) return "";
    uint32_t len = 0;                                    // fallback: OSC 7/9;9 seen by the emulator
    uint8_t* buf = emu_get_text(s->emu, 1, &len);
    if (!buf) return "";
    std::string url((const char*)buf, len);
    core_free_buf(buf, len);
    if (url.rfind("file://", 0) == 0) {
        size_t slash = url.find('/', 7);                 // skip the host part
        url = (slash == std::string::npos) ? "" : url.substr(slash + 1);
    }
    std::string path;
    for (size_t i = 0; i < url.size(); i++) {            // %-decode + URL slashes -> backslashes
        if (url[i] == '%' && i + 2 < url.size())
            { path += (char)strtol(url.substr(i + 1, 2).c_str(), nullptr, 16); i += 2; }
        else path += (url[i] == '/') ? '\\' : url[i];
    }
    if (path.size() < 2 || path[1] != ':') return "";    // not a drive path (WSL etc.) — keep fallback
    DWORD attr = GetFileAttributesA(path.c_str());
    return (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY)) ? path : "";
}

// Read a whole file into memory. false = could not be opened at all (missing, locked, no profile).
static bool readWholeFile(const std::wstring& path, std::string& out, DWORD* err = nullptr) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) { if (err) *err = GetLastError(); return false; }
    out.clear(); char buf[4096]; DWORD rd;
    while (ReadFile(f, buf, sizeof buf, &rd, nullptr) && rd) out.append(buf, rd);
    CloseHandle(f);
    if (err) *err = 0;
    return true;
}
// How many session lines a state file on disk holds; -1 when it can't be read at all. `err` tells
// the two -1s apart: a file that ISN'T THERE has nothing to lose (every first run), while a file
// that exists and won't open is the locked-profile case a save must not steamroll. Cheap enough to
// ask before every save, and it is what "would this write throw sessions away?" actually means.
static int stateFileSessionCount(const std::wstring& path, DWORD* err = nullptr) {
    std::string d;
    if (!readWholeFile(path, d, err)) return -1;
    int n = 0;
    for (size_t i = 0; i < d.size();) {
        size_t e = d.find('\n', i);
        size_t len = (e == std::string::npos) ? d.size() - i : e - i;
        // Count what parseStateFile would actually RESTORE, not every line that merely starts "S\t".
        // A record cut mid-write (what an interrupted in-place save leaves) parses to nothing, so
        // counting it as a session would let the save rotate that wreckage into the .bak — over the
        // one generation that still held the sessions — and let it call a good file "not empty".
        if (d.compare(i, 2, "S\t") == 0 &&
            std::count(d.begin() + i, d.begin() + i + len, '\t') >= 4) n++;
        if (e == std::string::npos) break;
        i = e + 1;
    }
    return n;
}

// A field written into a tab-separated, newline-delimited record must not CONTAIN a tab or a
// newline. Names reach here from the control API — session.rename takes a JSON string, and
// jsonParseString decodes \t, \n and \uXXXX — so an unescaped name could shift every field after it
// on its own line, or append a whole synthetic `S` line that the NEXT launch would faithfully start
// as a real session. It also breaks the S/D pairing guard, which then disables adoption for the
// entire file. One choke point on the way out covers every ingest path, present and future.
static std::string tsvField(const std::string& s) {
    std::string o = s;
    for (char& c : o) if (c == '\t' || c == '\n' || c == '\r') c = ' ';
    return o;
}

// session line is: S <ws> <name> <app> <cwd> <arg0> <arg1>...  Split-shells (hidden) aren't persisted.
//
// The write is atomic and keeps one previous generation: build the buffer, write it to
// sessions.tsv.tmp, then publish it with ReplaceFileW, which rotates the current file to
// sessions.tsv.bak and swaps the temp in as ONE operation. A crash, a full disk or a killed process
// can therefore never leave a truncated file where a good one was — the old CREATE_ALWAYS wrote in
// place, so the only copy was destroyed the instant the write began.
static void saveSessionState() {
    std::wstring path = stateFilePath();
    if (path.empty()) {
        // The last silent save failure left: no state directory means nothing is written and, before
        // this line, nothing said so — "restore doesn't work" with an empty log, on exactly the kind
        // of redirected/policy-locked profile the field reports come from.
        logWarn("save FAILED: no state directory (%%LOCALAPPDATA%% is not set) — nothing was saved");
        return;
    }
    std::string out = "V1\n";
    // The hold starts BEFORE the workspace walk: g_workspaces is pushed/erased/reassigned under
    // g_lock on pipe threads, and this is the UI thread reading names into the file. (It was
    // one line too low; refreshTree's former function-wide hold hid that on the common path.)
    EnterCriticalSection(&g_lock);
    for (const auto& w : g_workspaces) out += "W\t" + tsvField(narrow(w)) + "\n";
    std::string flagLine;   // "F\t<i>..." = indices (in S-line order) of flagged sessions; old builds skip it
    // "D\t<id>..." = the host session ids, in S-line order — same in-order idiom as the F line, and
    // additive so a 0.17.x file (which has no D line) still restores, just without adoption.
    std::string idLine;
    std::vector<const Session*> savedOrder;   // S-line order, so a split can name its owner by position
    int saved = 0;
    for (const Session* s : g_sessions) {
        if (s->hidden) continue;
        std::string cw = sessionLiveCwd(s);              // live dir (OSC 7) wins over the creation dir
        // Never persist a cwd the next launch cannot use: Create.cwd is a fixed 260-byte wire field,
        // while the PEB path sessionLiveCwd() reads has no such limit. Falling back to the creation
        // dir loses a little accuracy; writing it would lose the session (see fitsField).
        if (cw.size() >= sizeof agwinterm_ptyhost_Create::cwd) cw.clear();
        out += "S\t" + std::to_string(s->ws) + "\t" + tsvField(narrow(s->name)) + "\t" + tsvField(s->app)
             + "\t" + tsvField(cw.empty() ? s->cwd : cw);
        for (const auto& a : s->args) out += "\t" + tsvField(a);
        out += "\n";
        if (s->flagged) flagLine += "\t" + std::to_string(saved);
        idLine += "\t" + s->id;
        savedOrder.push_back(s);
        saved++;
    }
    // ...then each saved session's split shell, named by its owner's POSITION among the S lines.
    // Written after them so a reader that stops at an unknown line type still gets every session,
    // and a build that does not know P ignores it and restores without the split.
    std::string splitLines;
    const std::string tab(1, (char)9);       // the field separator, spelled without an escape
    for (size_t oi = 0; oi < savedOrder.size(); oi++) {
        const Session* owner = savedOrder[oi];
        if (owner->splitId.empty()) continue;
        const Session* sh = nullptr;
        for (const Session* c : g_sessions) if (c->id == owner->splitId) { sh = c; break; }
        if (!sh) continue;                               // its shell is gone; nothing to restore
        std::string scw = sessionLiveCwd(sh);
        if (scw.size() >= sizeof agwinterm_ptyhost_Create::cwd) scw.clear();
        splitLines += "P" + tab + std::to_string(oi) + tab + tsvField(sh->app)
                    + tab + tsvField(scw.empty() ? sh->cwd : scw);
        for (const auto& a : sh->args) splitLines += tab + tsvField(a);
        splitLines += "\n";
    }
    // Read under the lock, with the session list it describes: the flag is written from the
    // control-pipe thread (closeSessionAt) while this can run on the UI one, and it gates both the
    // zero-session refusal and the .bak delete — the two decisions that can cost saved sessions.
    bool userEmptied = g_userEmptied;
    LeaveCriticalSection(&g_lock);
    if (!flagLine.empty()) out += "F" + flagLine + "\n";
    if (!idLine.empty()) out += "D" + idLine + "\n";
    out += splitLines;                       // P lines: each session's own right-hand shell
    out += "A\t" + std::to_string(g_activeWs) + "\n";

    // Anything that rebuilds the tree while the session list is momentarily empty used to rewrite the
    // file with zero S lines — a good file replaced by a useless one, with nothing to fall back to.
    // The one legitimate zero-session save is the user closing the last session (g_userEmptied).
    if (saved == 0 && !userEmptied) {
        DWORD hadErr = 0;
        int had = stateFileSessionCount(path, &hadErr);
        // No file yet is not a file that "could not be read" — that is every first run, and saying
        // so in the log the field reports are read from sends the reader after a fault that isn't
        // there. Nothing on disk means nothing to lose, so treat it as the empty case.
        if (had < 0 && (hadErr == ERROR_FILE_NOT_FOUND || hadErr == ERROR_PATH_NOT_FOUND)) had = 0;
        if (had != 0) {   // -1 = the file exists but could not be read: unknown is NOT permission to overwrite
            if (had > 0)
                logWarn("save SKIPPED: refusing to replace %s (%d saved session(s)) with a zero-session save",
                        narrow(path).c_str(), had);
            else
                logWarn("save SKIPPED: %s could not be read (err %lu), so a zero-session save might be "
                        "throwing sessions away — refusing", narrow(path).c_str(), hadErr);
            return;
        }
    }

    std::wstring tmp = path + L".tmp", bak = path + L".bak";
    HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) {
        // Writing through a temp needs a permission the old in-place save did not: creating a NEW
        // file in the state directory. Somewhere that allows writing the existing sessions.tsv but
        // not creating beside it (a policy-locked profile, a DLP/AV agent that blocks new files) this
        // build would save nothing where the previous one saved fine — the atomic write turning into
        // the very "restore doesn't work" it was added to fix. So fall back to the old route rather
        // than give up. It is not atomic: an interrupted write leaves a truncated file. That is the
        // right trade only because the alternative here is no file at all, and it is what every build
        // before this one did on every save.
        DWORD terr = GetLastError();
        // Keep the generation by hand, because CREATE_ALWAYS below truncates the only copy the
        // instant it opens — the atomic path's rotation (ReplaceFileW) is exactly what this path
        // does not get. Copying first is best effort: if it fails the in-place write still has to
        // happen, since the alternative here is no file at all.
        if (!(saved == 0 && userEmptied) && stateFileSessionCount(path) > 0 &&
            !CopyFileW(path.c_str(), bak.c_str(), FALSE))
            logWarn("save: could not keep a .bak generation of %s (err %lu) before writing in place",
                    narrow(path).c_str(), GetLastError());
        HANDLE g = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (g == INVALID_HANDLE_VALUE) {
            // The silent return that made "restore doesn't work" unanswerable in the field: if the
            // state file can't be opened, nothing is saved and nothing says so. Name the STATE file as
            // well as the temp: the overwhelmingly likely cause is that the directory is not writable
            // (a policy-locked %LOCALAPPDATA%), and a reader handed only a .tmp path they have never
            // seen before is one indirection away from the thing they have to go fix.
            logWarn("save FAILED to open %s (err %lu) or %s (err %lu) — %d session(s) not saved "
                    "(is the state directory writable?)",
                    narrow(tmp).c_str(), terr, narrow(path).c_str(), GetLastError(), saved);
            return;
        }
        DWORD wr2 = 0;
        BOOL ok2 = WriteFile(g, out.data(), (DWORD)out.size(), &wr2, nullptr);
        DWORD werr2 = ok2 ? 0 : GetLastError();
        if (ok2) FlushFileBuffers(g);
        CloseHandle(g);
        if (ok2 && wr2 == out.size()) {
            // The same rule the atomic path applies: the user emptying the window on purpose drops
            // the previous generation. Left behind, restore's fallback reads it on the next launch
            // and brings back exactly the sessions they just closed.
            if (saved == 0 && userEmptied) DeleteFileW(bak.c_str());
            logWarn("save ok (IN PLACE): %d session(s), %zu bytes -> %s — %s could not be created "
                    "(err %lu), so this save was not atomic",
                    saved, out.size(), narrow(path).c_str(), narrow(tmp).c_str(), terr);
        } else
            logWarn("save FAILED in place to %s: wrote %lu of %zu bytes (err %lu) after %s could not "
                    "be created (err %lu)", narrow(path).c_str(), wr2, out.size(), werr2,
                    narrow(tmp).c_str(), terr);
        return;
    }
    DWORD wr = 0;
    BOOL ok = WriteFile(f, out.data(), (DWORD)out.size(), &wr, nullptr);
    DWORD werr = ok ? 0 : GetLastError();
    if (ok) FlushFileBuffers(f);       // the rename below must publish bytes that actually reached disk
    CloseHandle(f);
    if (!ok || wr != out.size()) {
        logWarn("save PARTIAL to %s: wrote %lu of %zu bytes (err %lu) — previous state left intact",
                narrow(tmp).c_str(), wr, out.size(), werr);
        DeleteFileW(tmp.c_str());
        return;
    }
    // Keep exactly one previous generation, but only rotate a file that is actually worth keeping, so
    // a good .bak is never overwritten by an empty primary. The user emptying the window ON PURPOSE is
    // the one case that drops the .bak: keeping it would resurrect on the next launch exactly what
    // they just closed. A primary that exists but cannot be READ right now (an AV scan, a transient
    // lock) still holds the saved sessions, so it counts as worth keeping — publishing over it with no
    // .bak is the one outcome that loses them. Only "there is no file at all" — every first save —
    // means there is nothing to preserve, and that is also the case ReplaceFileW cannot serve (it
    // needs an existing target).
    DWORD prevErr = 0;
    int prev = stateFileSessionCount(path, &prevErr);
    bool havePrev = prev > 0 || (prev < 0 && prevErr != ERROR_FILE_NOT_FOUND && prevErr != ERROR_PATH_NOT_FOUND);
    bool rotate = !(saved == 0 && userEmptied) && havePrev;
    if (saved == 0 && userEmptied) DeleteFileW(bak.c_str());
    // ReplaceFileW does the rotation and the publish as ONE operation, and never unlinks the target
    // in between. Doing it as two renames leaves a window in which no primary exists at all — and a
    // shutdown landing in that window (the OnDestroy save is exactly when Windows is killing things)
    // costs a whole generation, which is "some of my sessions are gone" with a log line claiming the
    // save worked. It needs an existing target, so the two-rename path stays for the first save.
    if (rotate && ReplaceFileW(path.c_str(), tmp.c_str(), bak.c_str(),
                               REPLACEFILE_IGNORE_MERGE_ERRORS | REPLACEFILE_WRITE_THROUGH, nullptr, nullptr)) {
        logInfo("save ok: %d session(s), %zu bytes -> %s", saved, out.size(), narrow(path).c_str());
        return;
    }
    bool rotated = rotate && MoveFileExW(path.c_str(), bak.c_str(), MOVEFILE_REPLACE_EXISTING);
    if (rotate && !rotated)
        logWarn("save: could not rotate %s to .bak (err %lu)", narrow(path).c_str(), GetLastError());
    if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DWORD perr = GetLastError();
        // Put the primary back. Without this a failed publish leaves NO primary at all — the state
        // lives only in a .bak nothing but the fallback path reads, and --diagnose (the first thing
        // a reader runs) reports the session file as missing.
        bool restored = rotated && MoveFileExW(bak.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
        logWarn("save FAILED to publish %s (err %lu) — %d session(s) not saved; %s",
                narrow(path).c_str(), perr, saved,
                restored  ? "the previous state was put back"
                : rotated ? "the previous state is in the .bak"
                          : "the previous state is untouched");
        DeleteFileW(tmp.c_str());
        return;
    }
    logInfo("save ok: %d session(s), %zu bytes -> %s", saved, out.size(), narrow(path).c_str());
}

// Select a face+size, apply it, and persist the choice (used by the Properties dialog).
static void pickFont(int faceIdx, int sizeIdx) {
    g_faceIdx = faceIdx; g_sizeIdx = sizeIdx;
    applyFont(); saveFontSel();
}
// No font zoom, by design: lite renders raster/bitmap faces, which exist only at the strike sizes
// their pack ships. "Zooming" could only hop between those fixed sizes — a scaling gesture that
// doesn't scale. The face and its size are picked once in Properties. (Boris, 2026-07-29.)

// ---- Procedural box-drawing ----
// The raster Terminal/Fixedsys fonts have no Unicode cmap for U+2500.., so GDI draws blanks for the
// CP437/866 pseudographic borders that Far Manager (and other DOS-heritage TUIs) rely on. Draw them
// ourselves with GDI so they render crisply in ANY font. Covers the DOS single/double line set plus
// the solid/half blocks; returns 0 for runes we don't handle (those fall through to the font).
static uint8_t boxArms(uint32_t r) {
    // packed (up<<6)|(down<<4)|(left<<2)|right, each 2 bits: 0 none, 1 light, 2 double
    switch (r) {
        case 0x2500: return (1 << 2) | 1;                                     // ─
        case 0x2502: return (1 << 6) | (1 << 4);                              // │
        case 0x250C: return (1 << 4) | 1;                                     // ┌
        case 0x2510: return (1 << 4) | (1 << 2);                              // ┐
        case 0x2514: return (1 << 6) | 1;                                     // └
        case 0x2518: return (1 << 6) | (1 << 2);                              // ┘
        case 0x251C: return (1 << 6) | (1 << 4) | 1;                          // ├
        case 0x2524: return (1 << 6) | (1 << 4) | (1 << 2);                   // ┤
        case 0x252C: return (1 << 4) | (1 << 2) | 1;                          // ┬
        case 0x2534: return (1 << 6) | (1 << 2) | 1;                          // ┴
        case 0x253C: return (1 << 6) | (1 << 4) | (1 << 2) | 1;               // ┼
        case 0x2550: return (2 << 2) | 2;                                     // ═
        case 0x2551: return (2 << 6) | (2 << 4);                              // ║
        case 0x2554: return (2 << 4) | 2;                                     // ╔
        case 0x2557: return (2 << 4) | (2 << 2);                              // ╗
        case 0x255A: return (2 << 6) | 2;                                     // ╚
        case 0x255D: return (2 << 6) | (2 << 2);                              // ╝
        case 0x2560: return (2 << 6) | (2 << 4) | 2;                          // ╠
        case 0x2563: return (2 << 6) | (2 << 4) | (2 << 2);                   // ╣
        case 0x2566: return (2 << 4) | (2 << 2) | 2;                          // ╦
        case 0x2569: return (2 << 6) | (2 << 2) | 2;                          // ╩
        case 0x256C: return (2 << 6) | (2 << 4) | (2 << 2) | 2;               // ╬
        case 0x2552: return (1 << 4) | 2;                                     // ╒
        case 0x2553: return (2 << 4) | 1;                                     // ╓
        case 0x2555: return (1 << 4) | (2 << 2);                              // ╕
        case 0x2556: return (2 << 4) | (1 << 2);                              // ╖
        case 0x2558: return (1 << 6) | 2;                                     // ╘
        case 0x2559: return (2 << 6) | 1;                                     // ╙
        case 0x255B: return (1 << 6) | (2 << 2);                              // ╛
        case 0x255C: return (2 << 6) | (1 << 2);                              // ╜
        case 0x255E: return (1 << 6) | (1 << 4) | 2;                          // ╞
        case 0x255F: return (2 << 6) | (2 << 4) | 1;                          // ╟
        case 0x2561: return (1 << 6) | (1 << 4) | (2 << 2);                   // ╡
        case 0x2562: return (2 << 6) | (2 << 4) | (1 << 2);                   // ╢
        case 0x2564: return (1 << 4) | (2 << 2) | 2;                          // ╤
        case 0x2565: return (2 << 4) | (1 << 2) | 1;                          // ╥
        case 0x2567: return (1 << 6) | (2 << 2) | 2;                          // ╧
        case 0x2568: return (2 << 6) | (1 << 2) | 1;                          // ╨
        case 0x256A: return (1 << 6) | (1 << 4) | (2 << 2) | 2;               // ╪
        case 0x256B: return (2 << 6) | (2 << 4) | (1 << 2) | 1;               // ╫
    }
    return 0;
}
static bool isBoxGlyph(uint32_t r) {
    if (boxArms(r)) return true;
    switch (r) { case 0x2580: case 0x2584: case 0x2588: case 0x258C: case 0x2590: return true; }
    return false;
}
static void drawBoxGlyph(HDC dc, int x, int y, int cw, int ch, uint32_t r, COLORREF fg) {
    HBRUSH br = CreateSolidBrush(fg);
    switch (r) {   // solid + half blocks (scrollbars, shadows, fills)
        case 0x2588: { RECT b{ x, y, x + cw, y + ch }; FillRect(dc, &b, br); DeleteObject(br); return; }
        case 0x2580: { RECT b{ x, y, x + cw, y + ch / 2 }; FillRect(dc, &b, br); DeleteObject(br); return; }
        case 0x2584: { RECT b{ x, y + ch / 2, x + cw, y + ch }; FillRect(dc, &b, br); DeleteObject(br); return; }
        case 0x258C: { RECT b{ x, y, x + cw / 2, y + ch }; FillRect(dc, &b, br); DeleteObject(br); return; }
        case 0x2590: { RECT b{ x + cw / 2, y, x + cw, y + ch }; FillRect(dc, &b, br); DeleteObject(br); return; }
    }
    uint8_t a = boxArms(r);
    int up = (a >> 6) & 3, down = (a >> 4) & 3, left = (a >> 2) & 3, right = a & 3;
    int cx = x + cw / 2, cy = y + ch / 2, d = 1;   // d = half-gap between the two strokes of a double line
    auto hline = [&](int x0, int x1, int yy) { RECT rr{ x0, yy, x1, yy + 1 }; FillRect(dc, &rr, br); };
    auto vline = [&](int y0, int y1, int xx) { RECT rr{ xx, y0, xx + 1, y1 }; FillRect(dc, &rr, br); };
    // Light arms run edge->center; double arms are two parallel strokes that cross the center by d so
    // corners/junctions close cleanly.
    if (left == 1) hline(x, cx + 1, cy);
    if (left == 2) { hline(x, cx + d + 1, cy - d); hline(x, cx + d + 1, cy + d); }
    if (right == 1) hline(cx, x + cw, cy);
    if (right == 2) { hline(cx - d, x + cw, cy - d); hline(cx - d, x + cw, cy + d); }
    if (up == 1) vline(y, cy + 1, cx);
    if (up == 2) { vline(y, cy + d + 1, cx - d); vline(y, cy + d + 1, cx + d); }
    if (down == 1) vline(cy, y + ch, cx);
    if (down == 2) { vline(cy - d, y + ch, cx - d); vline(cy - d, y + ch, cx + d); }
    DeleteObject(br);
}

// ---- GDI paint ----
static COLORREF toColorRef(uint32_t packed, bool dim) {
    uint32_t r = (packed >> 16) & 0xFF, g = (packed >> 8) & 0xFF, b = packed & 0xFF;
    if (dim) { r = r * 6 / 10; g = g * 6 / 10; b = b * 6 / 10; }
    return RGB(r, g, b);
}

static HFONT styleFont(uint32_t attrs) {
    return g_fonts[((attrs & kAttrBold) ? 1 : 0) | ((attrs & kAttrItalic) ? 2 : 0)];
}

// Render one session's viewport into rect pr. `pane` selects the selection-highlight span (-1 = none,
// e.g. popup windows); `showCursor` draws the cursor (the focused main pane, or a popup terminal).
// ---- AGWin Bitmap (.agbf) — pre-rasterized font packs, no vector fonts at runtime -------------
// Format v1 (fonts/generate.py): 172-byte header, sorted glyph records, 8-bit alpha atlas.
// Record flags: 1 = synthesized, 2 = 1-bit glyph (rows bit-packed MSB-first, byte-padded —
// the Complete family's GNU Unifont fallback), 4 = fallback source, 8 = hand-corrected
// override, 16 = color glyph (BGRA rows, straight alpha — Noto emoji). Wide glyphs (cellW 2)
// just render across two cells; the emulator's cell.width drives layout, not the record.
#pragma pack(push, 1)
struct AgbfHeader {
    char magic[4]; uint32_t version, strike;
    uint16_t cellW, cellH, baseline, ulPos, ulTh, stPos;
    uint32_t glyphCount, recordsOff, atlasOff, atlasLen, crc;
    char family[64], source[64];
};
struct AgbfRec { uint32_t cp, off; int16_t bx, by; uint16_t w, h; uint8_t cellW, flags; uint16_t pad; };
#pragma pack(pop)
static_assert(sizeof(AgbfHeader) == 172 && sizeof(AgbfRec) == 20, "agbf layout");

static struct {
    std::vector<uint8_t> bytes;
    const AgbfHeader* h = nullptr; const AgbfRec* recs = nullptr; const uint8_t* atlas = nullptr;
    int strike = 0; bool complete = false; bool ok = false;
} g_agbfPack;

static AgbfCell agbfCell(int) { return { g_agbfPack.h->cellW, g_agbfPack.h->cellH }; }

static bool agbfLoad(int strike, bool complete) {
    if (g_agbfPack.ok && g_agbfPack.strike == strike && g_agbfPack.complete == complete) return true;
    wchar_t name[64];
    wsprintfW(name, complete ? L"\\agwin-bitmap-complete-%d.agbf" : L"\\agwin-bitmap-%d.agbf", strike);
    HANDLE f = CreateFileW((exeDir() + name).c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    DWORD sz = GetFileSize(f, nullptr), rd = 0;
    std::vector<uint8_t> bytes(sz);
    bool read = sz > sizeof(AgbfHeader) && ReadFile(f, bytes.data(), sz, &rd, nullptr) && rd == sz;
    CloseHandle(f);
    if (!read) return false;
    auto* h = (const AgbfHeader*)bytes.data();
    if (memcmp(h->magic, "AGBF", 4) != 0 || h->version != 1) return false;
    if (h->recordsOff + (uint64_t)h->glyphCount * sizeof(AgbfRec) > sz || (uint64_t)h->atlasOff + h->atlasLen > sz) return false;
    typedef DWORD(WINAPI* fnCrc)(DWORD, const void*, ULONG);   // corrupted-pack rejection
    static fnCrc crc32 = (fnCrc)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlComputeCrc32");
    if (crc32 && crc32(0, bytes.data() + h->recordsOff, (ULONG)(sz - h->recordsOff)) != h->crc) return false;
    g_agbfPack.bytes = std::move(bytes);
    g_agbfPack.h = (const AgbfHeader*)g_agbfPack.bytes.data();
    g_agbfPack.recs = (const AgbfRec*)(g_agbfPack.bytes.data() + g_agbfPack.h->recordsOff);
    g_agbfPack.atlas = g_agbfPack.bytes.data() + g_agbfPack.h->atlasOff;
    g_agbfPack.strike = strike; g_agbfPack.complete = complete; g_agbfPack.ok = true;
    return true;
}

static const AgbfRec* agbfFind(uint32_t cp) {          // records are cp-sorted -> binary search
    const AgbfRec* lo = g_agbfPack.recs; const AgbfRec* hi = lo + g_agbfPack.h->glyphCount;
    while (lo < hi) {
        const AgbfRec* mid = lo + (hi - lo) / 2;
        if (mid->cp == cp) return mid;
        if (mid->cp < cp) lo = mid + 1; else hi = mid;
    }
    return nullptr;
}

static uint32_t agbfDim(uint32_t rgb, bool dim) {
    if (!dim) return rgb;
    return ((((rgb >> 16) & 0xFF) * 6 / 10) << 16) | ((((rgb >> 8) & 0xFF) * 6 / 10) << 8) | ((rgb & 0xFF) * 6 / 10);
}

// Missing glyph: a bordered cell carrying the code point in hex (3x5 digit micro-font), so an
// uncovered character is identifiable instead of an empty box (spec: readable missing-glyph cells).
static const uint16_t kHex35[16] = { 0x7B6F,0x2492,0x73E7,0x73CF,0x5BC9,0x79CF,0x79EF,0x7249,0x7BEF,0x7BC9,
                                     0x7BED,0x6BAE,0x7927,0x6B6E,0x79E7,0x79E4 };
static void agbfMissing(uint32_t* fb, int fbw, int x0, int y0, int cw, int ch, uint32_t cp, uint32_t fg) {
    for (int x = 0; x < cw; x++) { fb[y0 * fbw + x0 + x] = fg; fb[(y0 + ch - 1) * fbw + x0 + x] = fg; }
    for (int y = 0; y < ch; y++) { fb[(y0 + y) * fbw + x0] = fg; fb[(y0 + y) * fbw + x0 + cw - 1] = fg; }
    char hex[7]; int n = 0;
    for (uint32_t v = cp; v && n < 6; v >>= 4) hex[n++] = "0123456789ABCDEF"[v & 15];
    int perRow = (cw - 2) / 4, rows = (ch - 2) / 6;
    if (perRow < 1 || rows < 1) return;
    for (int i = 0; i < n; i++) {                       // digits stored low->high; draw high first
        int d = n - 1 - i, row = i / perRow, col = i % perRow;
        if (row >= rows) break;
        int dx = x0 + 2 + col * 4, dy = y0 + 2 + row * 6;
        uint16_t bits = kHex35[(uint8_t)(hex[d] <= '9' ? hex[d] - '0' : hex[d] - 'A' + 10)];
        for (int py = 0; py < 5; py++)
            for (int px = 0; px < 3; px++)
                if (bits & (1 << (14 - (py * 3 + px)))) fb[(dy + py) * fbw + dx + px] = fg;
    }
}

// Paint the whole grid from the pack into a 32bpp DIB and blit once — no GDI text at all.
static void agbfPaintGrid(HDC mem, RECT pr, const FfiCell* view, const FfiEmuInfo& info) {
    int cw = g_cw, ch = g_ch;
    int W = min((int)info.cols * cw, (int)(pr.right - pr.left));
    int H = min((int)info.rows * ch, (int)(pr.bottom - pr.top));
    if (W <= 0 || H <= 0) return;
    static std::vector<uint32_t> fb;
    fb.assign((size_t)W * H, 0);
    for (uint32_t r = 0; r < info.rows; r++) {
        int y0 = (int)r * ch;
        if (y0 + ch > H) break;
        for (uint32_t c = 0; c < info.cols; ) {
            const FfiCell& cell = view[r * info.cols + c];
            uint32_t w = cell.width ? cell.width : 1;
            int x0 = (int)c * cw, cellPx = (int)w * cw;
            if (x0 + cellPx > W) break;
            uint32_t fg = cell.fg, bg = cell.bg, attrs = cell.attrs;
            if (g_customColors) { if (cell.fgKind == 0) fg = g_defFg; if (cell.bgKind == 0) bg = g_defBg; }
            if (g_dosPalette) {
                if (cell.fgKind == 1) { int ix = cell.fgIndex & 15; if (ix < 8 && (attrs & kAttrBold)) ix += 8; fg = kEgaPalette[ix]; }
                if (cell.bgKind == 1) bg = kEgaPalette[cell.bgIndex & 15];
            }
            if (attrs & kAttrInverse) { uint32_t t = fg; fg = bg; bg = t; }
            fg = agbfDim(fg, (attrs & kAttrDim) != 0);
            for (int y = 0; y < ch; y++)                 // background fill
                for (int x = 0; x < cellPx; x++) fb[(size_t)(y0 + y) * W + x0 + x] = bg;
            if (cell.rune && cell.rune != ' ') {
                const AgbfRec* rec = agbfFind(cell.rune);
                if (rec && rec->w) {
                    bool onebit = (rec->flags & 2) != 0;        // Unifont fallback: bit-packed rows
                    bool color = (rec->flags & 16) != 0;        // emoji: BGRA rows, own colors
                    size_t stride = color ? (size_t)rec->w * 4 : onebit ? ((size_t)rec->w + 7) / 8 : rec->w;
                    int passes = (attrs & kAttrBold) && !color ? 2 : 1;   // synthetic bold: 1px overstrike
                    // Some records are rasterized WIDER than the cell they claim: U+2714 is 17px in a
                    // 10px cell, U+2B24 15px, U+23FA 12px. Clipping at the cell edge cut them in half —
                    // a bisected symbol, which is what "strange glyphs rendered in half" looked like.
                    // (agwin-bitmap-14 is the worst: 2671 of 3840 records run past their 8px cell.)
                    //
                    // So an oversized glyph is SCALED to fit rather than cropped. Only when it actually
                    // overruns by a visible amount: a 1px overhang is invisible, and resampling a bitmap
                    // font needlessly is exactly how a crisp pack starts looking mushy.
                    int inkR = rec->bx + (int)rec->w;
                    bool fit = inkR > cellPx + 1;
                    int sw = rec->w, sh = rec->h, sbx = rec->bx, sby = rec->by;
                    if (fit) {
                        // Uniform scale, bottom-anchored so the glyph keeps sitting on its baseline,
                        // then centred in the cell. Squashing one axis would turn a circle into an egg.
                        sw = max(1, (int)rec->w * cellPx / inkR);
                        sh = max(1, (int)rec->h * cellPx / inkR);
                        sbx = (cellPx - sw) / 2;
                        sby = rec->by + (int)rec->h - sh;
                    }
                    for (int p = 0; p < passes; p++)
                        for (int dy = 0; dy < sh; dy++) {
                            int py = y0 + sby + dy;
                            if (py < y0 || py >= y0 + ch) continue;
                            // Nearest-neighbour back-mapping. Iterating DESTINATION pixels is what makes a
                            // downscale work at all: walking the source would skip destination rows and
                            // leave a comb pattern through the glyph.
                            int gy = fit ? dy * (int)rec->h / sh : dy;
                            if (gy < 0 || gy >= (int)rec->h) continue;
                            const uint8_t* src = g_agbfPack.atlas + rec->off + (size_t)gy * stride;
                            for (int dx2 = 0; dx2 < sw; dx2++) {
                                int px = x0 + sbx + dx2 + p;
                                if (px < x0 || px >= x0 + cellPx) continue;
                                int gx = fit ? dx2 * (int)rec->w / sw : dx2;
                                if (gx < 0 || gx >= (int)rec->w) continue;
                                uint32_t a = color ? src[gx * 4 + 3]
                                           : onebit ? ((src[gx >> 3] & (0x80u >> (gx & 7))) ? 255u : 0u)
                                           : src[gx];
                                if (!a) continue;
                                uint32_t* dst = &fb[(size_t)py * W + px];
                                uint32_t dr = (*dst >> 16) & 0xFF, dg = (*dst >> 8) & 0xFF, db = *dst & 0xFF;
                                uint32_t sr, sg, sb;
                                if (color) { sr = src[gx * 4 + 2]; sg = src[gx * 4 + 1]; sb = src[gx * 4]; }
                                else       { sr = (fg >> 16) & 0xFF; sg = (fg >> 8) & 0xFF; sb = fg & 0xFF; }
                                *dst = (((sr * a + dr * (255 - a)) / 255) << 16) |
                                       (((sg * a + dg * (255 - a)) / 255) << 8) |
                                        ((sb * a + db * (255 - a)) / 255);
                            }
                        }
                } else if (!rec) {
                    agbfMissing(fb.data(), W, x0, y0, cellPx, ch, cell.rune, fg);
                }
            }
            if (attrs & kAttrUnderline) {
                int uy = min(ch - 1, (int)g_agbfPack.h->ulPos);
                for (int t = 0; t < (int)g_agbfPack.h->ulTh && uy + t < ch; t++)
                    for (int x = 0; x < cellPx; x++) fb[(size_t)(y0 + uy + t) * W + x0 + x] = fg;
            }
            if (attrs & kAttrStrike)
                for (int x = 0; x < cellPx; x++) fb[(size_t)(y0 + ch / 2) * W + x0 + x] = fg;
            c += w;
        }
    }
    BITMAPINFO bi{};
    bi.bmiHeader = { sizeof(BITMAPINFOHEADER), W, -H, 1, 32, BI_RGB };
    SetDIBitsToDevice(mem, pr.left, pr.top, W, H, 0, 0, 0, H, fb.data(), &bi, DIB_RGB_COLORS);
}

// What "Restart everything" relaunches. Rebuilt from THIS instance, not a bare exe: a named window
// restarted as the bare exe comes back as the DEFAULT instance and reads a different sessions file,
// which is indistinguishable from "restore lost everything". --diagnose prints this so the rule is
// checkable without launching (and clobbering) the default instance.
static std::wstring restartCommandLine() {
    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring cmd = L"\"" + std::wstring(exe) + L"\"";
    if (!g_isDefaultInstance) cmd += L" --pipe \"" + g_instance + L"\"";
    return cmd;
}

// --bench-agbf: the spec's benchmark deliverable — load time, glyph lookup, full-grid render and
// resident size for every committed pack, printed to the launching console. No window, no session.
// --diagnose: one report you can run on a machine that misbehaves and paste into an issue. Strictly
// read-only — it never writes state, never opens the control pipe, and is safe while lite is running.
// It answers the questions that cost this project the most time: where does state live, can lite
// actually write there, what is in it, and what did the font/pack resolution decide.
static int liteDiagnose() {
    AttachConsole(ATTACH_PARENT_PROCESS);
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    auto say = [&](const std::string& s) { DWORD wr; WriteFile(out, s.data(), (DWORD)s.size(), &wr, nullptr); };
    auto line = [&](const char* k, const std::string& v) { say(std::string("  ") + k + ": " + v + "\r\n"); };

    wchar_t exe[MAX_PATH]{}; GetModuleFileNameW(nullptr, exe, MAX_PATH);
    wchar_t lad[MAX_PATH]{}; DWORD ladOk = GetEnvironmentVariableW(L"LOCALAPPDATA", lad, MAX_PATH);

    say("\nagliteterm --diagnose\r\n\r\n");
    line("version", AGWL_VERSION_STR);
    line("exe", narrow(exe));
    line("instance", g_isDefaultInstance ? "(default)" : narrow(g_instance));
    line("restart cmdline", narrow(restartCommandLine()));
    line("LOCALAPPDATA", ladOk ? narrow(lad) : "(not set!)");

    std::wstring dir = std::wstring(ladOk ? lad : L"") + L"\\" + kProduct;
    std::wstring state = dir + (g_isDefaultInstance ? L"\\sessions.tsv" : (L"\\sessions-" + g_instance + L".tsv"));
    std::wstring log = dir + (g_isDefaultInstance ? L"\\agliteterm.log" : (L"\\agliteterm-" + g_instance + L".log"));

    say("\r\nstate\r\n");
    line("dir", narrow(dir));
    line("dir exists", (GetFileAttributesW(dir.c_str()) != INVALID_FILE_ATTRIBUTES) ? "yes" : "NO");
    // A real write probe, not an attribute guess: redirected or policy-locked profiles fail here.
    std::wstring probe = dir + L"\\.diagnose-probe";
    HANDLE ph = CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (ph == INVALID_HANDLE_VALUE) {
        line("dir writable", "NO (err " + std::to_string(GetLastError()) + ")  <-- saves cannot work here");
    } else {
        CloseHandle(ph); DeleteFileW(probe.c_str());
        line("dir writable", "yes");
    }

    WIN32_FILE_ATTRIBUTE_DATA fa{};
    if (GetFileAttributesExW(state.c_str(), GetFileExInfoStandard, &fa)) {
        SYSTEMTIME st{}; FILETIME lt{};
        FileTimeToLocalFileTime(&fa.ftLastWriteTime, &lt); FileTimeToSystemTime(&lt, &st);
        char when[64];
        _snprintf_s(when, sizeof when, _TRUNCATE, "%04d-%02d-%02d %02d:%02d:%02d",
                    st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
        line("session file", narrow(state));
        line("  size", std::to_string(fa.nFileSizeLow) + " bytes");
        line("  modified", when);
        HANDLE f = CreateFileW(state.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f != INVALID_HANDLE_VALUE) {
            std::string data; char buf[4096]; DWORD rd;
            while (ReadFile(f, buf, sizeof buf, &rd, nullptr) && rd) data.append(buf, rd);
            CloseHandle(f);
            say("\r\nsession file contents\r\n");
            say(data.empty() ? std::string("  (empty)\r\n") : ("  " + data + "\r\n"));
        }
    } else {
        line("session file", narrow(state) + "  <-- DOES NOT EXIST (nothing to restore)");
    }
    // The previous generation kept by every save; restore falls back to it when the primary is
    // missing, empty, or parses to zero sessions.
    WIN32_FILE_ATTRIBUTE_DATA ba{};
    line("backup file", GetFileAttributesExW((state + L".bak").c_str(), GetFileExInfoStandard, &ba)
                            ? narrow(state) + ".bak (" + std::to_string(ba.nFileSizeLow) + " bytes)"
                            : narrow(state) + ".bak  (none yet)");

    say("\r\nlog\r\n");
    line("path", narrow(log));
    if (GetFileAttributesExW(log.c_str(), GetFileExInfoStandard, &fa))
        line("size", std::to_string(fa.nFileSizeLow) + " bytes");
    else
        line("size", "(no log yet)");

    say("\r\nfonts\r\n");
    std::wstring ed = exeDir();
    for (const wchar_t* p : { L"agwin-bitmap-14.agbf", L"agwin-bitmap-16.agbf", L"agwin-bitmap-18.agbf",
                              L"agwin-bitmap-20.agbf", L"agwin-bitmap-complete-14.agbf",
                              L"agwin-bitmap-complete-16.agbf", L"agwin-bitmap-complete-18.agbf",
                              L"agwin-bitmap-complete-20.agbf", L"MesloLGLDZNerdFont-Regular.ttf" }) {
        std::wstring fp = ed + L"\\" + p;
        line(narrow(p).c_str(), GetFileAttributesW(fp.c_str()) != INVALID_FILE_ATTRIBUTES ? "present" : "missing");
    }
    wchar_t face[64] = L""; DWORD sz = sizeof(face);
    bool haveReg = RegGetValueW(HKEY_CURRENT_USER, kRegKey, L"FontFace",
                                RRF_RT_REG_SZ, nullptr, face, &sz) == ERROR_SUCCESS;
    line("remembered face", haveReg ? narrow(face) : "(none -> first-run default)");
    say("\r\n");
    return 0;
}

static int agbfBench() {
    AttachConsole(ATTACH_PARENT_PROCESS);
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    auto say = [&](const char* s) { DWORD wr; WriteFile(out, s, (DWORD)strlen(s), &wr, nullptr); };
    LARGE_INTEGER f, t0, t1;
    QueryPerformanceFrequency(&f);
    auto us = [&](LARGE_INTEGER a, LARGE_INTEGER b) { return (b.QuadPart - a.QuadPart) * 1000000 / f.QuadPart; };
    say("\npack                          load        lookup     grid 120x40   resident\n");
    HDC screen = GetDC(nullptr);
    for (int complete = 0; complete <= 1; complete++)
        for (int s : { 14, 16, 18, 20 }) {
            g_agbfPack.ok = false;                       // force a cold reload
            QueryPerformanceCounter(&t0);
            bool ok = agbfLoad(s, complete != 0);
            QueryPerformanceCounter(&t1);
            char name[48], line[160];
            sprintf_s(name, complete ? "agwin-bitmap-complete-%d" : "agwin-bitmap-%d", s);
            if (!ok) { sprintf_s(line, "%-28s MISSING\n", name); say(line); continue; }
            long long loadUs = us(t0, t1);
            uint32_t n = g_agbfPack.h->glyphCount;       // lookups: 1M deterministic LCG-picked cps
            uint64_t seed = 0x243F6A8885A308D3ull;
            const AgbfRec* volatile sink = nullptr;
            QueryPerformanceCounter(&t0);
            for (int i = 0; i < 1000000; i++) {
                seed = seed * 6364136223846793005ull + 1442695040888963407ull;
                sink = agbfFind(g_agbfPack.recs[(seed >> 33) % n].cp);
            }
            QueryPerformanceCounter(&t1);
            long long lookupNs = us(t0, t1) / 1000;      // total us over 1M ops -> ns per lookup
            AgbfCell cc = agbfCell(s);
            g_cw = cc.w; g_ch = cc.h;
            FfiEmuInfo info{}; info.cols = 120; info.rows = 40;
            std::vector<FfiCell> grid((size_t)info.cols * info.rows);
            static const uint32_t runes[] = { 'A', 'z', '0', 0x2500, 0x2551, 0x2588, 0x0416, 0xE0B0, 0x4E2D };
            for (size_t i = 0; i < grid.size(); i++) {   // mixed content incl. a wide CJK every 9th cell
                FfiCell& c = grid[i];
                c.rune = runes[i % 9]; c.width = 1;
                if (c.rune == 0x4E2D) { if ((i % info.cols) + 1 < info.cols) { c.width = 2; grid[++i].rune = 0; } else c.rune = 'A'; }
                c.fgKind = 2; c.fg = 0xC0C0C0; c.bgKind = 2; c.bg = 0x101010;
            }
            RECT pr{ 0, 0, (LONG)info.cols * g_cw, (LONG)info.rows * g_ch };
            HDC mem = CreateCompatibleDC(screen);
            HBITMAP bmp = CreateCompatibleBitmap(screen, pr.right, pr.bottom);
            HGDIOBJ old = SelectObject(mem, bmp);
            agbfPaintGrid(mem, pr, grid.data(), info);   // warm-up (fb vector alloc)
            QueryPerformanceCounter(&t0);
            for (int i = 0; i < 100; i++) agbfPaintGrid(mem, pr, grid.data(), info);
            QueryPerformanceCounter(&t1);
            long long frameUs = us(t0, t1) / 100;
            SelectObject(mem, old); DeleteObject(bmp); DeleteDC(mem);
            sprintf_s(line, "%-28s %5lld.%lld ms %6lld ns/op %8lld us/frame %7zu KiB\n",
                      name, loadUs / 1000, loadUs % 1000 / 100, lookupNs, frameUs,
                      g_agbfPack.bytes.size() / 1024);
            say(line);
            (void)sink;
        }
    ReleaseDC(nullptr, screen);
    return 0;
}

static void paintPane(HDC mem, RECT pr, Session* s, int pane, bool showCursor) {
    if (!s) return;
    FfiEmuInfo info{};
    EnterCriticalSection(&g_lock);
    emu_info(s->emu, &info);
    size_t need = (size_t)info.cols * info.rows;
    if (s->grid.size() < need) s->grid.resize(need);
    if (s->hrow.size() < info.cols) s->hrow.resize(info.cols);
    emu_copy_grid(s->emu, s->grid.data(), (uint32_t)s->grid.size());
    int off = min(s->scrollOff, (int)info.historyCount);
    s->scrollOff = off;
    // Compose the viewport: history tail above, live grid below (main-app semantics).
    std::vector<FfiCell> view((size_t)info.cols * info.rows);
    for (uint32_t r = 0; r < info.rows; r++) {
        int abs = (int)info.historyCount - off + (int)r;
        if (abs < (int)info.historyCount) {
            if (emu_copy_history_row(s->emu, (uint32_t)abs, s->hrow.data(), info.cols))
                memcpy(&view[r * info.cols], s->hrow.data(), info.cols * sizeof(FfiCell));
        } else {
            int live = abs - (int)info.historyCount;
            if (live < (int)info.rows)
                memcpy(&view[r * info.cols], &s->grid[live * info.cols], info.cols * sizeof(FfiCell));
        }
    }
    LeaveCriticalSection(&g_lock);

    std::vector<wchar_t> text;
    std::vector<INT> dx;
    if (g_agbf && g_agbfPack.ok) {   // AGWin Bitmap: every pixel from the pack atlas, no GDI text
        agbfPaintGrid(mem, pr, view.data(), info);
        goto afterGridPaint;
    }
    for (uint32_t r = 0; r < info.rows; r++) {
        int y = pr.top + (int)r * g_ch;
        if (y + g_ch > pr.bottom) break;
        uint32_t c = 0;
        while (c < info.cols) {
            const FfiCell& cell = view[r * info.cols + c];
            if (cell.width == 0) { c++; continue; }
            uint32_t attrs = cell.attrs;
            uint32_t fg = cell.fg, bgc = cell.bg;
            if (g_customColors) { if (cell.fgKind == 0) fg = g_defFg; if (cell.bgKind == 0) bgc = g_defBg; }
            if (g_dosPalette) {   // remap ANSI indices to the muted DOS palette (fg brightens on bold)
                if (cell.fgKind == 1) { int ix = cell.fgIndex & 15; if (ix < 8 && (attrs & kAttrBold)) ix += 8; fg = kEgaPalette[ix]; }
                if (cell.bgKind == 1) bgc = kEgaPalette[cell.bgIndex & 15];
            }
            if (attrs & kAttrInverse) { uint32_t t = fg; fg = bgc; bgc = t; }
            uint32_t styleKey = attrs & (kAttrBold | kAttrItalic | kAttrUnderline | kAttrStrike | kAttrDim);
            uint32_t start = c;
            text.clear();
            dx.clear();
            while (c < info.cols) {
                const FfiCell& cc = view[r * info.cols + c];
                if (cc.width == 0) { c++; continue; }
                uint32_t f2 = cc.fg, b2 = cc.bg, a2 = cc.attrs;
                if (g_customColors) { if (cc.fgKind == 0) f2 = g_defFg; if (cc.bgKind == 0) b2 = g_defBg; }
                if (g_dosPalette) {
                    if (cc.fgKind == 1) { int ix = cc.fgIndex & 15; if (ix < 8 && (a2 & kAttrBold)) ix += 8; f2 = kEgaPalette[ix]; }
                    if (cc.bgKind == 1) b2 = kEgaPalette[cc.bgIndex & 15];
                }
                if (a2 & kAttrInverse) { uint32_t t = f2; f2 = b2; b2 = t; }
                if (f2 != fg || b2 != bgc ||
                    (a2 & (kAttrBold | kAttrItalic | kAttrUnderline | kAttrStrike | kAttrDim)) != styleKey) break;
                if (cc.rune > 0xFFFF) {
                    // Astral: surrogate pair with the advance on the FIRST unit (GDI draws the
                    // pair as one glyph when the font covers it; U+FFFD look comes free otherwise).
                    uint32_t v = cc.rune - 0x10000;
                    text.push_back((wchar_t)(0xD800 + (v >> 10)));
                    dx.push_back(g_cw * (int)cc.width);
                    text.push_back((wchar_t)(0xDC00 + (v & 0x3FF)));
                    dx.push_back(0);
                } else {
                    // Box-drawing runes are painted procedurally after the run (see below); feed the
                    // font a space so ETO_OPAQUE still lays down the background cell.
                    text.push_back(isBoxGlyph(cc.rune) ? L' ' : (wchar_t)(cc.rune ? cc.rune : L' '));
                    dx.push_back(g_cw * (int)cc.width);
                }
                c += cc.width;
            }
            int x = pr.left + (int)start * g_cw;
            if (x >= pr.right) break;
            SelectObject(mem, styleFont(styleKey));
            SetTextColor(mem, toColorRef(fg, (styleKey & kAttrDim) != 0));
            SetBkColor(mem, toColorRef(bgc, false));
            SetBkMode(mem, OPAQUE);
            RECT clip{ x, y, min((LONG)(pr.left + (LONG)c * g_cw), pr.right), y + g_ch };
            ExtTextOutW(mem, x, y, ETO_OPAQUE | ETO_CLIPPED, &clip, text.data(), (UINT)text.size(), dx.data());
            // Overlay CP437/866 pseudographics with GDI primitives (all cells in this run share fg).
            {
                COLORREF boxCol = toColorRef(fg, (styleKey & kAttrDim) != 0);
                for (uint32_t col = start; col < c; ) {
                    const FfiCell& bc = view[r * info.cols + col];
                    uint32_t w = bc.width ? bc.width : 1;
                    int bx = pr.left + (int)col * g_cw;
                    if (bx >= pr.right) break;
                    if (isBoxGlyph(bc.rune)) drawBoxGlyph(mem, bx, y, g_cw, g_ch, bc.rune, boxCol);
                    col += w;
                }
            }
            if (styleKey & (kAttrUnderline | kAttrStrike)) {
                HBRUSH b = CreateSolidBrush(toColorRef(fg, (styleKey & kAttrDim) != 0));
                if (styleKey & kAttrUnderline) { RECT u{ x, y + g_ch - 2, clip.right, y + g_ch - 1 }; FillRect(mem, &u, b); }
                if (styleKey & kAttrStrike) { RECT k{ x, y + g_ch / 2, clip.right, y + g_ch / 2 + 1 }; FillRect(mem, &k, b); }
                DeleteObject(b);
            }
        }
    }
afterGridPaint:;

    // Selection highlight (invert the selected span, buffer-absolute rows mapped into the view).
    syncSelection();   // the rows may have been renumbered by eviction since the last paint
    if (g_sel.isFor(s) && g_sel.pane == pane) {
        int r0, c0, r1, c1;
        g_sel.norm(r0, c0, r1, c1);
        int base = (int)info.historyCount - off;   // buffer-absolute row of the top visible line
        for (uint32_t r = 0; r < info.rows; r++) {
            int abs = base + (int)r;
            if (abs < r0 || abs > r1) continue;
            int from = (abs == r0) ? c0 : 0;
            int to = (abs == r1) ? c1 : (int)info.cols;   // exclusive end column
            from = max(0, min(from, (int)info.cols));
            to = max(0, min(to, (int)info.cols));
            if (to <= from) continue;
            RECT sr{ pr.left + from * g_cw, pr.top + (int)r * g_ch,
                     min((LONG)(pr.left + to * g_cw), pr.right), pr.top + (int)(r + 1) * g_ch };
            InvertRect(mem, &sr);
        }
    }

    // Cursor (only at live view, only in the focused pane, not while selecting). Solid and blinking
    // while the window has focus, a hollow outline when it doesn't — the standard terminal cue for
    // "typing lands here", and the thing lite was missing: a static block that never blinks and
    // looks identical focused or not reads as though input focus went somewhere else.
    if (off == 0 && info.cursorVisible && showCursor && info.cursorCol < info.cols && !g_sel.isFor(s)) {
        RECT cur{ pr.left + (LONG)info.cursorCol * g_cw, pr.top + (LONG)info.cursorRow * g_ch,
                  pr.left + (LONG)(info.cursorCol + 1) * g_cw, pr.top + (LONG)(info.cursorRow + 1) * g_ch };
        if (cur.right <= pr.right) {
            if (!g_winFocused) {
                HBRUSH cb = CreateSolidBrush(toColorRef(g_customColors ? g_defFg : 0xC0C0C0, false));
                FrameRect(mem, &cur, cb);
                DeleteObject(cb);
            } else if (g_caretOn) {
                InvertRect(mem, &cur);
            }
        }
    }
    // FTCS prompt pips (OSC 133): a small right-edge marker at each prompt line — green ok,
    // red failed, accent for a still-running command. The agent-status cue for Claude sessions.
    int doneMarks = 0;   // completed commands seen this paint (unread bookkeeping)
    if (info.markCount > 0) {
        std::vector<FfiMark> marks(info.markCount);
        EnterCriticalSection(&g_lock);
        uint32_t nm = emu_marks(s->emu, marks.data(), info.markCount);
        LeaveCriticalSection(&g_lock);
        int base = (int)info.historyCount - off;   // buffer-absolute row of the top visible line
        for (uint32_t mi = 0; mi < nm; mi++) {
            if (marks[mi].endLine >= 0) doneMarks++;
            int vr = (int)marks[mi].promptLine - base;
            if (vr < 0 || vr >= (int)info.rows) continue;
            COLORREF col = RGB(120, 130, 200);   // running (no end yet)
            if (marks[mi].endLine >= 0)
                col = (marks[mi].hasExit && marks[mi].exitCode == 0) ? RGB(60, 180, 90)
                    : marks[mi].hasExit ? RGB(210, 70, 70) : RGB(120, 130, 200);
            RECT pip{ pr.right - 3, pr.top + vr * g_ch + 2, pr.right, pr.top + vr * g_ch + g_ch - 2 };
            HBRUSH b = CreateSolidBrush(col);
            FillRect(mem, &pip, b);
            DeleteObject(b);
        }
    }
    if (!s->hidden) {   // painting = visible: mark as seen, clear the badge the moment you land here
        s->seenDone = doneMarks;
        if (s->unread) { s->unread = 0; PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0); }
    }

    // Scrollback indicator: thin right-edge stripe while scrolled.
    if (off > 0) {
        RECT bar{ pr.right - 3, pr.top, pr.right, pr.bottom };
        HBRUSH b = CreateSolidBrush(RGB(90, 140, 200));
        FillRect(mem, &bar, b);
        DeleteObject(b);
    }
}

static void paint(HDC dc, RECT rc) {
    HDC mem = CreateCompatibleDC(dc);
    HBITMAP bmp = CreateCompatibleBitmap(dc, rc.right, rc.bottom);
    HGDIOBJ oldBmp = SelectObject(mem, bmp);
    HBRUSH bg = CreateSolidBrush(g_customColors ? toColorRef(g_defBg, false) : RGB(0, 0, 0));
    FillRect(mem, &rc, bg);
    DeleteObject(bg);

    // The sidebar is now the native SysTreeView32 child (0..kSidebarW); WS_CLIPCHILDREN keeps this
    // paint out of it. Only the terminal content area (>= kSidebarW) is drawn here.
    for (int p = 0; p < 2; p++) {
        if (g_pane[p] < 0 || g_pane[p] >= (int)g_sessions.size()) continue;
        RECT pr;
        paneRect(p, rc, &pr);
        paintPane(mem, pr, g_sessions[g_pane[p]], p, p == g_focus);
    }
    if (g_pane[1] >= 0) {   // split divider
        RECT pr0;
        paneRect(0, rc, &pr0);
        RECT div{ pr0.right, pr0.top, pr0.right + 2, pr0.bottom };
        HBRUSH b = CreateSolidBrush(g_th.classic ? RGB(60, 62, 70) : g_th.border);
        FillRect(mem, &div, b);
        DeleteObject(b);
    }
    if (g_showSidebar) {   // draggable splitter bar between the sidebar and the terminal
        RECT sp{ g_sidebarW, toolbarTop(), g_sidebarW + kSplitterW, rc.bottom - (g_showStatus ? g_statusH : 0) };
        HBRUSH f = CreateSolidBrush(g_th.bar);
        FillRect(mem, &sp, f); DeleteObject(f);
        // Classic keeps the 3-D etched groove; the themed looks use a flat 1px rule instead, because
        // DrawEdge only ever draws the system's light/shadow pair and reads as a bright seam on dark.
        if (g_th.classic) DrawEdge(mem, &sp, EDGE_ETCHED, BF_LEFT | BF_RIGHT);
        else { RECT ln{ sp.left, sp.top, sp.left + 1, sp.bottom }; HBRUSH lb = CreateSolidBrush(g_th.border);
               FillRect(mem, &ln, lb); ln.left = sp.right - 1; ln.right = sp.right; FillRect(mem, &ln, lb); DeleteObject(lb); }
    }

    if (g_palette) {   // command palette overlay: query row + filtered, scrollable action list
        int n = (int)g_palHits.size();
        int rowH = g_ch + 8, rows = min(n, kPalMaxRows);
        int pw = min(520, (int)(rc.right - sidebarSpan()) - 24); if (pw < 240) pw = 240;
        int ph = rowH + 14 + max(rows, 1) * rowH + 8;
        int px = sidebarSpan() + ((rc.right - sidebarSpan()) - pw) / 2, py = toolbarTop() + 16;
        g_palBox = { px, py, px + pw, py + ph };
        HBRUSH bb = CreateSolidBrush(g_th.bar);
        FillRect(mem, &g_palBox, bb); DeleteObject(bb);
        HBRUSH fr = CreateSolidBrush(g_th.accent);
        FrameRect(mem, &g_palBox, fr); DeleteObject(fr);
        SelectObject(mem, g_fonts[0]);
        SetBkMode(mem, TRANSPARENT);

        RECT qbox{ px + 6, py + 6, px + pw - 6, py + 6 + rowH };   // query field on the client surface
        HBRUSH qb = CreateSolidBrush(g_th.client);
        FillRect(mem, &qbox, qb); DeleteObject(qb);
        HBRUSH qf = CreateSolidBrush(g_th.border);
        FrameRect(mem, &qbox, qf); DeleteObject(qf);
        RECT qr{ qbox.left + 8, qbox.top + 4, qbox.right - 8, qbox.bottom - 4 };
        if (g_palQuery.empty()) {
            SetTextColor(mem, g_th.dim);
            DrawTextW(mem, L"Type a command…", -1, &qr, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        } else {
            SetTextColor(mem, g_th.text);
            DrawTextW(mem, g_palQuery.c_str(), -1, &qr, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        }
        SIZE qe{};   // caret after the query text
        GetTextExtentPoint32W(mem, g_palQuery.c_str(), (int)g_palQuery.size(), &qe);
        int cx = min((int)qr.left + qe.cx + 1, (int)qr.right - 2);
        RECT caret{ cx, qr.top + 1, cx + 1, qr.bottom - 1 };
        HBRUSH cb = CreateSolidBrush(g_th.accent);
        FillRect(mem, &caret, cb); DeleteObject(cb);

        int ly = qbox.bottom + 8;
        g_palList = { px + 4, ly, px + pw - 4, ly + max(rows, 1) * rowH };
        if (!n) {
            SetTextColor(mem, g_th.dim);
            RECT er{ px + 16, ly, px + pw - 8, ly + rowH };
            DrawTextW(mem, L"No matching commands", -1, &er, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
        }
        COLORREF selText = g_th.classic ? GetSysColor(COLOR_HIGHLIGHTTEXT) : g_th.text;
        for (int v = 0; v < rows; v++) {
            int i = g_palTop + v;
            if (i >= n) break;
            const PalAction& a = kPalActions[g_palHits[i]];
            int iy = ly + v * rowH;
            bool cur = (i == g_paletteSel);
            if (cur) {
                RECT sel{ px + 4, iy, px + pw - 4, iy + rowH };
                HBRUSH sb = CreateSolidBrush(g_th.sel);
                FillRect(mem, &sel, sb); DeleteObject(sb);
            }
            RECT ir{ px + 16, iy, px + pw - 16, iy + rowH };
            SetTextColor(mem, cur ? selText : g_th.text);
            DrawTextW(mem, a.label, -1, &ir, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
            std::wstring key = a.kb >= 0 ? palKeyName(g_keys[a.kb]) : L"";
            if (a.theme >= 0 && a.theme == g_themeMode) key = L"✓";   // active theme check
            if (!key.empty()) {
                SetTextColor(mem, cur ? selText : g_th.dim);
                DrawTextW(mem, key.c_str(), -1, &ir, DT_RIGHT | DT_SINGLELINE | DT_VCENTER);
            }
        }
        if (n > rows) {   // proportional scroll thumb on the list's right edge
            int th = max(rowH, rows * rows * rowH / n);
            int ty = ly + (rows * rowH - th) * g_palTop / max(1, n - rows);
            RECT tr{ px + pw - 7, ty, px + pw - 4, ty + th };
            HBRUSH tb = CreateSolidBrush(g_th.dim);
            FillRect(mem, &tr, tb); DeleteObject(tb);
        }
    }

    BitBlt(dc, 0, 0, rc.right, rc.bottom, mem, 0, 0, SRCCOPY);
    SelectObject(mem, oldBmp);
    DeleteObject(bmp);
    DeleteDC(mem);
}

// ---- selection: pixel → (pane, buffer-absolute row, col) ----
static bool hitTest(int x, int y, int* pane, int* absRow, int* col) {
    RECT rc;
    GetClientRect(g_hwnd, &rc);
    for (int p = 0; p < 2; p++) {
        if (g_pane[p] < 0) continue;
        RECT pr;
        paneRect(p, rc, &pr);
        if (x < pr.left || x >= pr.right || y < pr.top || y >= pr.bottom) continue;
        Session* s = g_sessions[g_pane[p]];
        FfiEmuInfo info{};
        EnterCriticalSection(&g_lock);
        emu_info(s->emu, &info);
        LeaveCriticalSection(&g_lock);
        int r = (y - pr.top) / g_ch;
        int c = (x - pr.left) / g_cw;
        *pane = p;
        *absRow = (int)info.historyCount - min(s->scrollOff, (int)info.historyCount) + r;
        *col = max(0, min(c, (int)info.cols));
        return true;
    }
    return false;
}

// Bring the selection's buffer-absolute rows up to date with any scrollback eviction since it was
// made, and drop it if its own lines are the ones that went.
//
// The reader thread only ever increments the counter; the selection is written here. But "here" is
// not always the UI thread — the control server answers `session.copy` on its own thread — so the
// whole read-modify-write runs under g_lock, the same lock the counter is written under. The lock
// is recursive, so callers that already hold it (the paint path) are fine.
static void syncSelection() {
    LockG lk;   // the WHOLE read-modify-write, including the reads that decide to clear
    if (!g_sel.bound()) return;
    Session* s = (Session*)g_sel.sess;
    if (!s) { g_sel.clear(); return; }
    // The alt screen is a different buffer: an index into one names unrelated text in the other, so
    // a selection cannot cross the boundary in either direction. (A full-screen app switching in is
    // the common case — the highlight would otherwise sit on top of its UI and copy that.)
    FfiEmuInfo ai{};
    bool gotInfo = s->emu && emu_info(s->emu, &ai);
    if (gotInfo && (ai.isAltScreen != 0) != g_sel.alt) { g_sel.clear(); return; }
    int64_t ev = s->evicted - g_sel.epoch;
    if (ev <= 0) return;
    g_sel.epoch = s->evicted;
    if ((int64_t)min(g_sel.aRow, g_sel.bRow) < ev) { g_sel.clear(); return; }   // its text is gone
    g_sel.aRow -= (int)ev;
    g_sel.bRow -= (int)ev;
}

// Extract the selected text (buffer-absolute rows), trailing spaces trimmed per line.
static std::string selectionText() {
    // One hold across reconcile AND extraction: released in between, a reader feed could evict
    // another line and the text would come from a different buffer than the rows were checked against.
    LockG lk;
    syncSelection();
    if (!g_sel.has()) return "";
    Session* s = (Session*)g_sel.sess;   // the session the selection was made in, not whatever the pane shows now
    int r0, c0, r1, c1;
    g_sel.norm(r0, c0, r1, c1);
    std::string out;
    FfiEmuInfo info{};
    EnterCriticalSection(&g_lock);
    emu_info(s->emu, &info);
    std::vector<FfiCell> row(info.cols);
    for (int abs = r0; abs <= r1; abs++) {
        bool got = false;
        if (abs < (int)info.historyCount) got = emu_copy_history_row(s->emu, (uint32_t)abs, row.data(), info.cols);
        else {
            int live = abs - (int)info.historyCount;
            if (live < (int)info.rows && s->grid.size() >= (size_t)info.cols * info.rows) {
                memcpy(row.data(), &s->grid[live * info.cols], info.cols * sizeof(FfiCell));
                got = true;
            }
        }
        if (!got) { out += '\n'; continue; }
        int from = (abs == r0) ? c0 : 0;
        int to = (abs == r1) ? c1 : (int)info.cols;
        std::string line;
        for (int c = from; c < to && c < (int)info.cols; c++) {
            const FfiCell& cell = row[c];
            if (cell.width == 0) continue;
            int cp = cell.rune ? cell.rune : ' ';
            wchar_t wb[2];
            int wn = 0;
            if (cp > 0xFFFF) { wb[wn++] = (wchar_t)(0xD800 + ((cp - 0x10000) >> 10)); wb[wn++] = (wchar_t)(0xDC00 + ((cp - 0x10000) & 0x3FF)); }
            else wb[wn++] = (wchar_t)cp;
            char u8[8];
            int n8 = WideCharToMultiByte(CP_UTF8, 0, wb, wn, u8, sizeof u8, nullptr, nullptr);
            line.append(u8, n8);
        }
        while (!line.empty() && line.back() == ' ') line.pop_back();
        out += line;
        if (abs < r1) out += "\r\n";
    }
    LeaveCriticalSection(&g_lock);
    return out;
}

// Put UTF-8 text on the clipboard. UI thread only (the clipboard is per-thread-owned): a host
// action arriving on a reader thread is posted across rather than setting it there.
static void setClipboardUtf8(const std::string& utf8) {
    if (utf8.empty() || !OpenClipboard(g_hwnd)) return;
    EmptyClipboard();
    int wn = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), nullptr, 0);
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, (wn + 1) * sizeof(wchar_t));
    if (h) {
        wchar_t* p = (wchar_t*)GlobalLock(h);
        MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), p, wn);
        p[wn] = 0;
        GlobalUnlock(h);
        SetClipboardData(CF_UNICODETEXT, h);
    }
    CloseClipboard();
}

// Copy the selection; false when there was nothing to copy.
//
// A LIVE selection can still hold no text - a full-screen app repaints and blanks the cells under
// it. selectionText joins its rows with CRLF whether or not a row contributed a character, so a
// blanked six-row selection is ten characters of pure separator. Deciding by emptiness of the
// STRING reads that as a successful copy: the clipboard is overwritten with newlines and, worse,
// Ctrl+C is consumed, so the interrupt the user actually wanted never reaches the app. Decide on
// content instead. (agwinterm hit exactly this in its own fix and corrected it in 0.17.7 -
// Program.Input.cs CopySelection.)
static bool copySelection() {
    std::string t = selectionText();
    if (t.find_first_not_of("\r\n ") == std::string::npos) return false;
    setClipboardUtf8(t);
    return true;
}

// ---- input ----
static void sendBytes(const char* bytes, int len) {
    Session* s = focusedSession();
    if (s && s->data != INVALID_HANDLE_VALUE) ovIo(s->data, true, bytes, nullptr, (DWORD)len);
}

// Clipboard text on Windows is CRLF-delimited, but a terminal wants a bare CR per line: send the
// LF too and the app sees two line breaks (inside a bracketed paste Claude Code renders doubled
// blank lines; a shell may run the line early). The main app normalises before bracketing —
// Program.Input.cs PasteTextInto — and lite has to agree, or the same paste behaves differently
// in the two clients.
static std::string pasteNormalize(std::string t) {
    std::string out;
    out.reserve(t.size());
    for (size_t i = 0; i < t.size(); i++) {
        if (t[i] == '\r' && i + 1 < t.size() && t[i + 1] == '\n') { out += '\r'; i++; }
        else if (t[i] == '\n') out += '\r';
        else out += t[i];
    }
    return out;
}

static void pasteClipboard() {
    Session* s = focusedSession();
    if (!s || s->data == INVALID_HANDLE_VALUE || !OpenClipboard(g_hwnd)) return;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        wchar_t* w = (wchar_t*)GlobalLock(h);
        if (w) {
            int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
            std::string u8(n > 0 ? n - 1 : 0, 0);
            if (!u8.empty()) WideCharToMultiByte(CP_UTF8, 0, w, -1, &u8[0], n, nullptr, nullptr);
            u8 = pasteNormalize(std::move(u8));
            // Bracketed paste when the app enabled it (safer multiline paste), else raw.
            FfiEmuInfo info{};
            EnterCriticalSection(&g_lock);
            emu_info(s->emu, &info);
            LeaveCriticalSection(&g_lock);
            if (info.bracketedPaste) { ovIo(s->data, true, "\x1b[200~", nullptr, 6); }
            ovIo(s->data, true, u8.data(), nullptr, (DWORD)u8.size());
            if (info.bracketedPaste) { ovIo(s->data, true, "\x1b[201~", nullptr, 6); }
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
}


static void sendUtf8(wchar_t wc) {
    // User interrupt: Esc / Ctrl+C typed into the terminal clears a "working" agent status — an
    // interrupted agent turn never fires its Stop hook, so the status would stick forever (agterm
    // #185 / main-app parity: scoped to working-class; blocked stays until the agent or user acts).
    if (wc == 0x1B || wc == 0x03) {
        Session* s = focusedSession();
        if (s && clearWorkingStatus(s)) {
            emitEvent("status", s->id, "idle");
            PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        }
    }
    char utf8[8];
    int n = WideCharToMultiByte(CP_UTF8, 0, &wc, 1, utf8, sizeof utf8, nullptr, nullptr);
    if (n > 0) sendBytes(utf8, n);
}

static bool ctrlDown() { return (GetKeyState(VK_CONTROL) & 0x8000) != 0; }
static bool shiftDown() { return (GetKeyState(VK_SHIFT) & 0x8000) != 0; }
static bool altDown() { return (GetKeyState(VK_MENU) & 0x8000) != 0; }

// Forward a mouse event to the app when the pane under (x,y) has mouse reporting on (so full-screen
// apps like Far Manager get clicks/drags/wheel). Returns true if it was forwarded OR deliberately
// swallowed (a reporting pane), so the caller skips selection/paste; false = do the normal UI action.
// cb: 0 left, 1 middle, 2 right, 64 wheel-up, 65 wheel-down.
static bool mouseReport(int x, int y, int cb, bool press, bool motion) {
    RECT rc; GetClientRect(g_hwnd, &rc);
    for (int p = 0; p < 2; p++) {
        if (g_pane[p] < 0) continue;
        RECT pr; paneRect(p, rc, &pr);
        if (x < pr.left || x >= pr.right || y < pr.top || y >= pr.bottom) continue;
        Session* s = g_sessions[g_pane[p]];
        FfiEmuInfo info{};
        EnterCriticalSection(&g_lock);
        emu_info(s->emu, &info);
        LeaveCriticalSection(&g_lock);
        if (!info.mouseClick && !info.mouseDrag && !info.mouseMotion) return false;  // no reporting -> selection path
        if (motion && !info.mouseDrag && !info.mouseMotion) return true;             // click-only app: swallow motion
        if (s->data == INVALID_HANDLE_VALUE) return true;
        int col = (x - pr.left) / g_cw + 1;
        int row = (y - pr.top) / g_ch + 1;
        int mods = (shiftDown() ? 4 : 0) + (altDown() ? 8 : 0) + (ctrlDown() ? 16 : 0);
        char buf[48];
        int len;
        if (info.mouseSgr) {
            int b = cb + (motion ? 32 : 0) + mods;
            len = wsprintfA(buf, "\x1b[<%d;%d;%d%c", b, col, row, press ? 'M' : 'm');   // SGR 1006
        } else {
            int b = (press ? cb : 3) + (motion ? 32 : 0) + mods;                       // legacy X10/normal
            int cc = col > 223 ? 0 : col, rr = row > 223 ? 0 : row;
            len = wsprintfA(buf, "\x1b[M%c%c%c", 32 + b, 32 + cc, 32 + rr);
        }
        ovIo(s->data, true, buf, nullptr, (DWORD)len);
        return true;
    }
    return false;
}

static void scrollFocused(int deltaRows) {
    Session* s = focusedSession();
    if (!s) return;
    FfiEmuInfo info{};
    EnterCriticalSection(&g_lock);
    emu_info(s->emu, &info);
    LeaveCriticalSection(&g_lock);
    int off = s->scrollOff + deltaRows;
    s->scrollOff = max(0, min(off, (int)info.historyCount));
    InvalidateRect(g_hwnd, nullptr, FALSE);
}

// ---- self-update (parity with the full app's app-update): GitHub releases/latest -> pick the
// lite setup asset -> SHA-256-verified download (the release API's per-asset digest is the
// integrity gate; we have no Authenticode cert) -> detached helper waits for exit, runs the
// setup silently, relaunches. FAIL-CLOSED at every step: no digest / bad digest / parse mismatch
// -> abort, nothing applied. Only the INSTALLED copy (%LOCALAPPDATA%\Programs\agliteterm)
// self-updates; dev/portable copies get pointed at GitHub instead.
enum { UPD_BALLOON = 1, UPD_MSG = 2, UPD_APPLY = 3 };   // WM_APP_UPDATE wParam
struct UpdApply { std::wstring ver, payload, helper; };
static bool g_updBusy = false;   // UI thread only: one interactive flow at a time

static std::wstring updVersion() {
    // Test seam. The return is the length WITHOUT the terminator on success, and the size WITH it
    // when the buffer is too small - and then nothing was written, so a >0 check alone would hand
    // back uninitialised stack. Now on every `ping`, so a 64-char override must not do that.
    wchar_t v[64];
    DWORD n = GetEnvironmentVariableW(L"AGWINTERM_VERSION_OVERRIDE", v, 64);
    if (n > 0 && n < 64) return std::wstring(v, n);
    std::wstring s;
    for (const char* p = AGWL_VERSION_STR; *p; p++) s += (wchar_t)*p;
    return s;
}
static bool updParses(const std::wstring& v) { int a, b, c; return swscanf_s(v.c_str(), L"%d.%d.%d", &a, &b, &c) == 3; }
static int updCmpVer(const std::wstring& a, const std::wstring& b) {   // >0 = a newer than b
    int av[3]{}, bv[3]{};
    swscanf_s(a.c_str(), L"%d.%d.%d", &av[0], &av[1], &av[2]);
    swscanf_s(b.c_str(), L"%d.%d.%d", &bv[0], &bv[1], &bv[2]);
    for (int i = 0; i < 3; i++) if (av[i] != bv[i]) return av[i] < bv[i] ? -1 : 1;
    return 0;
}
static bool updChannelInstalled() {
    wchar_t env[16];
    if (GetEnvironmentVariableW(L"AGWINTERM_LITE_UPDATE_CHANNEL", env, 16) > 0)        // test seam
        return wcscmp(env, L"installed") == 0;
    wchar_t base[MAX_PATH], exe[MAX_PATH];
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH) || !GetModuleFileNameW(nullptr, exe, MAX_PATH)) return false;
    std::wstring dir = std::wstring(base) + L"\\Programs\\" + kProduct + L"\\";
    return _wcsnicmp(exe, dir.c_str(), dir.size()) == 0;
}
static std::wstring updDir() {   // downloads + helper live here; cleaned on startup
    std::wstring d = stateDir();
    if (d.empty()) return {};
    CreateDirectoryW(d.c_str(), nullptr);
    d += L"\\updates";
    CreateDirectoryW(d.c_str(), nullptr);
    return d;
}
static void updCleanup() {   // best-effort: drop payloads/logs a previous update left behind
    std::wstring d = updDir();
    if (d.empty()) return;
    WIN32_FIND_DATAW fd;
    HANDLE f = FindFirstFileW((d + L"\\*").c_str(), &fd);
    if (f == INVALID_HANDLE_VALUE) return;
    do {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) DeleteFileW((d + L"\\" + fd.cFileName).c_str());
    } while (FindNextFileW(f, &fd));
    FindClose(f);
}

static bool updHttpGet(const std::wstring& url, std::vector<uint8_t>& out) {
    URL_COMPONENTS uc{ sizeof uc };
    wchar_t host[256], path[2048];
    uc.lpszHostName = host; uc.dwHostNameLength = 256;
    uc.lpszUrlPath = path; uc.dwUrlPathLength = 2048;
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return false;
    HINTERNET ses = WinHttpOpen(kProduct, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!ses) return false;
    HINTERNET con = WinHttpConnect(ses, host, uc.nPort, 0);
    HINTERNET req = con ? WinHttpOpenRequest(con, L"GET", path, nullptr, WINHTTP_NO_REFERER,
                                             WINHTTP_DEFAULT_ACCEPT_TYPES,
                                             uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)
                        : nullptr;
    bool ok = false;
    if (req && WinHttpSendRequest(req, L"Accept: application/vnd.github+json\r\n", (DWORD)-1, nullptr, 0, 0, 0)
            && WinHttpReceiveResponse(req, nullptr)) {
        DWORD status = 0, sz = sizeof status;
        WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &status, &sz, WINHTTP_NO_HEADER_INDEX);
        if (status == 200) {
            for (;;) {
                DWORD avail = 0;
                if (!WinHttpQueryDataAvailable(req, &avail) || !avail) break;
                size_t off = out.size(); out.resize(off + avail);
                DWORD rd = 0;
                if (!WinHttpReadData(req, out.data() + off, avail, &rd) || !rd) { out.resize(off); break; }
                out.resize(off + rd);
            }
            ok = !out.empty();
        }
    }
    if (req) WinHttpCloseHandle(req);
    if (con) WinHttpCloseHandle(con);
    if (ses) WinHttpCloseHandle(ses);
    return ok;
}
static bool updFetch(const std::wstring& src, std::vector<uint8_t>& out) {   // local paths = test seam
    DWORD at = GetFileAttributesW(src.c_str());
    if (at != INVALID_FILE_ATTRIBUTES && !(at & FILE_ATTRIBUTE_DIRECTORY)) {
        HANDLE f = CreateFileW(src.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (f == INVALID_HANDLE_VALUE) return false;
        DWORD sz = GetFileSize(f, nullptr), rd = 0;
        out.resize(sz);
        bool ok = ReadFile(f, out.data(), sz, &rd, nullptr) && rd == sz;
        CloseHandle(f);
        return ok && !out.empty();
    }
    return updHttpGet(src, out);
}

static std::wstring updSha256(const std::vector<uint8_t>& data) {
    BCRYPT_ALG_HANDLE alg = nullptr; BCRYPT_HASH_HANDLE h = nullptr;
    UCHAR digest[32]; std::wstring hex;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return {};
    if (BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0) == 0) {
        if (BCryptHashData(h, (PUCHAR)data.data(), (ULONG)data.size(), 0) == 0 &&
            BCryptFinishHash(h, digest, 32, 0) == 0)
            for (UCHAR b : digest) { wchar_t x[3]; swprintf_s(x, L"%02x", b); hex += x; }
        BCryptDestroyHash(h);
    }
    BCryptCloseAlgorithmProvider(alg, 0);
    return hex;
}

// Scan the /releases/latest JSON for tag_name + the lite-setup asset's url and digest. The window
// [asset name .. next "name":] keeps the digest/url reads inside that asset's object (GitHub user
// objects inside assets carry "login", never "name", so the next "name" is the next asset).
static std::string updJsonStr(const std::string& j, size_t from, size_t to, const char* key) {
    std::string k = std::string("\"") + key + "\":\"";
    size_t i = j.find(k, from);
    if (i == std::string::npos || i >= to) return {};
    i += k.size();
    size_t e = j.find('"', i);
    if (e == std::string::npos || e > to) return {};
    return j.substr(i, e - i);
}
struct UpdRelease { std::wstring ver; std::string url, sha256; bool ok = false; };
static UpdRelease updParse(const std::string& j) {
    UpdRelease r;
    std::string tag = updJsonStr(j, 0, j.size(), "tag_name");
    if (!tag.empty() && (tag[0] == 'v' || tag[0] == 'V')) tag.erase(0, 1);
    if (tag.empty()) return r;
    for (char c : tag) r.ver += (wchar_t)c;
    size_t a = j.find("\"name\":\"agliteterm-setup-");
    if (a == std::string::npos) return r;
    size_t end = j.find("\"name\":\"", a + 8);
    if (end == std::string::npos) end = j.size();
    r.url = updJsonStr(j, a, end, "browser_download_url");
    std::string dig = updJsonStr(j, a, end, "digest");   // "sha256:<hex>"
    if (dig.rfind("sha256:", 0) == 0) r.sha256 = dig.substr(7);
    r.ok = !r.url.empty();
    return r;
}

static const char kUpdHelper[] =
    "param([int]$ProcId, [string]$Payload, [string]$Exe, [string]$Instance)\n"
    "function Log([string]$m) { try { Add-Content -Path ($Payload + '.log') -Value (\"{0:HH:mm:ss.fff} {1}\" -f (Get-Date), $m) } catch { } }\n"
    "Log \"wait pid=$ProcId\"\n"
    "try { Wait-Process -Id $ProcId -Timeout 120 -ErrorAction SilentlyContinue } catch { }\n"
    "if (Get-Process -Id $ProcId -ErrorAction SilentlyContinue) { Log 'ABORT: app never exited'; exit 1 }\n"
    "Start-Sleep -Milliseconds 500\n"
    "Log 'applying'\n"
    "Start-Process $Payload -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES' -Wait\n"
    "Log 'setup finished'\n"
    // The instance name has to survive the round trip intact: a name with
    // a space ("--pipe my win") came back through CommandLineToArgvW as instance "my", which is a
    // different pipe AND a different state file — the "my sessions are gone" shape, self-inflicted by
    // the update. Passing it as its own -ArgumentList element is NOT enough: Start-Process joins
    // the list with spaces and quotes nothing, so the quotes have to be part of the value. The
    // app parses its own command line with CommandLineToArgvW, which strips them again.
    "if ($Instance) { Start-Process $Exe -ArgumentList '--pipe', ('\"' + $Instance + '\"') } else { Start-Process $Exe }\n"
    "Log 'relaunched'\n";

static std::wstring* updHeapStr(const std::wstring& s) { return new std::wstring(s); }   // freed by the UI handler

static DWORD WINAPI updWorker(LPVOID p) {
    bool interactive = p != nullptr;
    auto post = [](WPARAM code, void* data) { PostMessageW(g_hwnd, WM_APP_UPDATE, code, (LPARAM)data); };
    if (!interactive) Sleep(8000);   // background check: stay out of startup's way
    std::wstring cur = updVersion();
    wchar_t apiw[512];
    std::wstring api = GetEnvironmentVariableW(L"AGWINTERM_UPDATE_API", apiw, 512) > 0
                     ? apiw : L"https://api.github.com/repos/yeroo/agliteterm/releases/latest";
    std::vector<uint8_t> buf;
    if (!updFetch(api, buf)) {
        if (interactive) post(UPD_MSG, updHeapStr(L"update check failed (offline or rate-limited) — try again later"));
        return 0;
    }
    UpdRelease rel = updParse(std::string((const char*)buf.data(), buf.size()));
    if (!rel.ok || !updParses(rel.ver)) {
        if (interactive) post(UPD_MSG, updHeapStr(L"could not read the release feed"));
        return 0;
    }
    if (updCmpVer(rel.ver, cur) <= 0) {
        if (interactive) post(UPD_MSG, updHeapStr(L"agliteterm " + cur + L" is already the latest"));
        return 0;
    }
    if (!interactive) { post(UPD_BALLOON, updHeapStr(rel.ver)); return 0; }
    if (rel.sha256.empty()) {
        post(UPD_MSG, updHeapStr(L"release asset carries no SHA-256 digest — refusing an unverifiable update"));
        return 0;
    }
    std::wstring urlw;
    for (char c : rel.url) urlw += (wchar_t)c;
    std::vector<uint8_t> payload;
    if (!updFetch(urlw, payload)) { post(UPD_MSG, updHeapStr(L"download failed — update aborted")); return 0; }
    std::wstring want;
    for (char c : rel.sha256) want += (wchar_t)towlower(c);
    if (updSha256(payload) != want) {
        post(UPD_MSG, updHeapStr(L"download failed SHA-256 verification — update aborted"));
        return 0;
    }
    std::wstring dir = updDir();
    if (dir.empty()) { post(UPD_MSG, updHeapStr(L"cannot resolve %LOCALAPPDATA% — update aborted")); return 0; }
    auto writeAll = [](const std::wstring& path, const void* data, DWORD len) {
        HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
        if (f == INVALID_HANDLE_VALUE) return false;
        DWORD wr = 0;
        bool ok = WriteFile(f, data, len, &wr, nullptr) && wr == len;
        CloseHandle(f);
        return ok;
    };
    UpdApply* a = new UpdApply;
    a->ver = rel.ver;
    a->payload = dir + L"\\agliteterm-setup-" + rel.ver + L".exe";
    a->helper = dir + L"\\apply-update.ps1";
    if (!writeAll(a->payload, payload.data(), (DWORD)payload.size()) ||
        !writeAll(a->helper, kUpdHelper, (DWORD)(sizeof kUpdHelper - 1))) {
        delete a;
        post(UPD_MSG, updHeapStr(L"could not write the update files — update aborted"));
        return 0;
    }
    post(UPD_APPLY, a);
    return 0;
}

static void updCheck(bool interactive) {
    if (interactive) {
        if (g_updBusy) return;
        if (!updChannelInstalled()) {
            MessageBoxW(g_hwnd,
                L"This copy of agliteterm is not the installed one, so it does not self-update.\n"
                L"Get releases at github.com/yeroo/agliteterm/releases.",
                L"agliteterm update", MB_OK | MB_ICONINFORMATION);
            return;
        }
        g_updBusy = true;
    } else if (!updChannelInstalled() || !updParses(updVersion())) return;   // dev builds stay silent
    HANDLE t = CreateThread(nullptr, 0, updWorker, interactive ? (LPVOID)1 : nullptr, 0, nullptr);
    if (t) CloseHandle(t);
    else g_updBusy = false;
}

static void togglePalette() {
    g_palette = !g_palette;
    g_palQuery.clear();
    palFilter();
    InvalidateRect(g_hwnd, nullptr, FALSE);
}

static void togglePopupTerminal(bool scratch);   // fwd (quick/scratch popup windows, defined below)
static void toggleFlag(Session* s);              // fwd (flagged sessions, defined below)
static void toggleFlagView();                    // fwd
static void nextBlocked();                       // fwd (attention bell)
static void toggleFocusWs(int w);                // fwd (workspace focus)
static void runKbAction(int a);                  // fwd (palExec dispatches keyboard-only actions)

// Run a palette entry through the same path the menu / key binding would take. Menu commands are
// POSTED (never run from inside the key handler — several open dialogs), so the palette closes
// and repaints first and re-entrancy can't bite.
static void palExec(int idx) {
    const PalAction& a = kPalActions[idx];
    g_palette = false;
    InvalidateRect(g_hwnd, nullptr, FALSE);
    if (a.theme >= 0) {
        g_themeMode = a.theme;
        saveColors();
        applyTheme();
    } else if (a.idm) {
        PostMessageW(g_hwnd, WM_COMMAND, a.idm, 0);
    } else if (a.kb >= 0) {
        runKbAction(a.kb);
    }
}

static void palChar(wchar_t wc) {   // printable input -> query (both frame + popup char handlers)
    if (wc < 0x20) return;          // Enter/Esc/Backspace are handled at keydown
    g_palQuery += wc;
    palFilter();
    InvalidateRect(g_hwnd, nullptr, FALSE);
}

static void runKbAction(int a) {
    switch (a) {
        case KB_NEW: { int c, r; newSessionGrid(g_focus, &c, &r); Session* s = newSession(c, r); if (s) { selectPrimary((int)g_sessions.size() - 1); InvalidateRect(g_hwnd, nullptr, FALSE); } break; }
        case KB_NEWWS: SendMessageW(g_hwnd, WM_COMMAND, IDM_NEWWS, 0); break;
        case KB_CLOSE: closeFocused(); break;
        case KB_SPLIT: toggleSplit(); break;
        case KB_NEXT: cycleSession(1); break;
        case KB_PREV: cycleSession(-1); break;
        case KB_COPY: copySelection(); break;
        case KB_PASTE: pasteClipboard(); break;
        case KB_PALETTE: togglePalette(); break;
        case KB_FOCUSL: g_focus = 0; InvalidateRect(g_hwnd, nullptr, FALSE); break;
        case KB_FOCUSR: if (g_pane[1] >= 0) g_focus = 1; InvalidateRect(g_hwnd, nullptr, FALSE); break;
        case KB_SCROLLUP: scrollFocused(+10); break;
        case KB_SCROLLDN: scrollFocused(-10); break;
        case KB_QUICK: togglePopupTerminal(false); break;
        case KB_SCRATCH: togglePopupTerminal(true); break;
        case KB_REOPEN: reopenClosed(); break;
        case KB_FLAG: toggleFlag(focusedSession()); break;
        case KB_FLAGVIEW: toggleFlagView(); break;
        case KB_ATTENTION: nextBlocked(); break;
        case KB_FOCUSWS: toggleFocusWs(g_focusWs >= 0 ? g_focusWs : g_activeWs); break;
    }
}
static bool handleKeyDown(WPARAM vk) {
    if (g_palette) {   // palette captures navigation while open; plain chars flow to WM_CHAR -> query
        int n = (int)g_palHits.size();
        auto move = [&](int d) {
            if (!n) return;
            g_paletteSel = (g_paletteSel + d % n + n) % n;
            if (g_paletteSel < g_palTop) g_palTop = g_paletteSel;
            if (g_paletteSel >= g_palTop + kPalMaxRows) g_palTop = g_paletteSel - kPalMaxRows + 1;
            InvalidateRect(g_hwnd, nullptr, FALSE);
        };
        switch (vk) {
            case VK_ESCAPE: togglePalette(); return true;
            case VK_UP:     move(-1); return true;
            case VK_DOWN:   move(+1); return true;
            case VK_PRIOR:  move(-(kPalMaxRows - 1)); return true;
            case VK_NEXT:   move(+(kPalMaxRows - 1)); return true;
            case VK_HOME:   if (g_palQuery.empty()) { g_paletteSel = 0; g_palTop = 0; InvalidateRect(g_hwnd, nullptr, FALSE); return true; } return false;
            case VK_RETURN: if (n) palExec(g_palHits[g_paletteSel]); return true;
            case VK_BACK:
                if (!g_palQuery.empty()) { g_palQuery.pop_back(); palFilter(); InvalidateRect(g_hwnd, nullptr, FALSE); }
                return true;
        }
        // the palette's own binding toggles it closed again
        BYTE mods = (BYTE)((shiftDown() ? HOTKEYF_SHIFT : 0) | (ctrlDown() ? HOTKEYF_CONTROL : 0) | (altDown() ? HOTKEYF_ALT : 0));
        if (mods && g_keys[KB_PALETTE] == MAKEWORD((BYTE)vk, mods)) { togglePalette(); return true; }
        return false;   // anything else: let WM_CHAR through for the query (OnChar routes it)
    }
    // Configurable key bindings (all unbound by default, so every combo otherwise reaches the shell).
    // Match the pressed vk + modifiers against the user's bindings; the same actions are always on the
    // menu + toolbar. Checked before the xterm-key encoding so a bound combo wins over the default key.
    {
        BYTE mods = (BYTE)((shiftDown() ? HOTKEYF_SHIFT : 0) | (ctrlDown() ? HOTKEYF_CONTROL : 0) | (altDown() ? HOTKEYF_ALT : 0));
        WORD combo = MAKEWORD((BYTE)vk, mods);
        if (mods) for (int a = 0; a < KB_COUNT; a++) if (g_keys[a] == combo) { runKbAction(a); return true; }
    }

    // Ctrl+C with a selection COPIES; with nothing selected it falls straight through and the shell
    // still gets its ^C. That ordering is the whole point - the interrupt is never taken away, you
    // only get the copy when there is something to copy. Ctrl+Shift+C copies unconditionally, so
    // there is a chord that never interrupts. (Main-app parity: Program.Input.cs, CopyOnCtrlC.)
    if (vk == 'C' && ctrlDown() && !altDown()) {
        if (shiftDown()) { copySelection(); return true; }
        // Reconcile and test as one: an evicted selection must fall through to the interrupt rather
        // than swallow it, and the answer must not change between the two.
        bool live;
        { LockG lk; syncSelection(); live = g_sel.has(); }
        // ...and only CONSUME the key if something was actually copied, so a selection over cells
        // a TUI has blanked falls through to the interrupt instead of swallowing it.
        if (g_copyOnCtrlC && live && copySelection()) return true;
    }

    // Terminal special keys, encoded with xterm modifiers (mod = 1 + shift + 2*alt + 4*ctrl) so
    // full-screen apps like Far Manager get F1-F12 and Ctrl/Shift/Alt combinations. Three forms:
    //   csiFinal  -> ESC [ [1;mod] <A/B/C/D/H/F>   (arrows, Home, End)
    //   ss3       -> ESC O <P/Q/R/S>  or  ESC [ 1;mod <P/Q/R/S>   (F1-F4)
    //   tilde     -> ESC [ <n> [;mod] ~   (Insert, Delete, PgUp/Dn, F5-F12)
    int mod = 1 + (shiftDown() ? 1 : 0) + (altDown() ? 2 : 0) + (ctrlDown() ? 4 : 0);
    const char* csiFinal = nullptr; char ss3 = 0; int tilde = 0;
    switch (vk) {
        case VK_UP: csiFinal = "A"; break;
        case VK_DOWN: csiFinal = "B"; break;
        case VK_RIGHT: csiFinal = "C"; break;
        case VK_LEFT: csiFinal = "D"; break;
        case VK_HOME: csiFinal = "H"; break;
        case VK_END: csiFinal = "F"; break;
        case VK_INSERT: tilde = 2; break;
        case VK_DELETE: tilde = 3; break;
        case VK_PRIOR: tilde = 5; break;
        case VK_NEXT: tilde = 6; break;
        case VK_F1: ss3 = 'P'; break;
        case VK_F2: ss3 = 'Q'; break;
        case VK_F3: ss3 = 'R'; break;
        case VK_F4: ss3 = 'S'; break;
        case VK_F5: tilde = 15; break;
        case VK_F6: tilde = 17; break;
        case VK_F7: tilde = 18; break;
        case VK_F8: tilde = 19; break;
        case VK_F9: tilde = 20; break;
        case VK_F10: tilde = 21; break;
        case VK_F11: tilde = 23; break;
        case VK_F12: tilde = 24; break;
        case VK_TAB: if (shiftDown()) { sendBytes("\x1b[Z", 3); if (Session* s = focusedSession()) s->scrollOff = 0; return true; } return false; // Shift+Tab = back-tab; plain Tab -> WM_CHAR
        // Backspace: the raw WM_CHAR bytes are INVERTED vs the xterm/Windows Terminal convention
        // (plain -> 0x08 which apps read as Ctrl+Backspace "kill word", Ctrl+ -> 0x7F). Encode at
        // keydown instead: plain DEL 0x7F, Ctrl+Backspace 0x08 (word delete stays available).
        case VK_BACK: sendBytes(ctrlDown() ? "\x08" : "\x7f", 1); if (Session* s = focusedSession()) s->scrollOff = 0; return true;
        default: return false;
    }
    char buf[32];
    if (csiFinal) {
        if (mod > 1) wsprintfA(buf, "\x1b[1;%d%s", mod, csiFinal);
        else wsprintfA(buf, "\x1b[%s", csiFinal);
    } else if (ss3) {
        if (mod > 1) wsprintfA(buf, "\x1b[1;%d%c", mod, ss3);
        else wsprintfA(buf, "\x1bO%c", ss3);
    } else {
        if (mod > 1) wsprintfA(buf, "\x1b[%d;%d~", tilde, mod);
        else wsprintfA(buf, "\x1b[%d~", tilde);
    }
    if (Session* s = focusedSession()) s->scrollOff = 0;   // typing snaps back to live
    sendBytes(buf, (int)strlen(buf));
    return true;
}

static void newSessionDialog(const char* cwd = nullptr);   // fwd (defined below, used by the context menu)

// Fill the status bar's four parts: workspace · session count · terminal size · font.
static void updateStatus() {
    if (!g_status) return;
    wchar_t buf[160];
    // Its own hold: this reads g_workspaces (a reference INTO the vector) and walks g_sessions,
    // both mutated under g_lock on pipe threads, and refreshTree no longer wraps this call. The
    // status-bar SendMessages are same-thread and the emu_info hold below nests (recursive), so
    // the hold spans only in-memory reads, never I/O.
    LockG hold;
    const std::wstring& ws = (g_activeWs >= 0 && g_activeWs < (int)g_workspaces.size()) ? g_workspaces[g_activeWs] : g_workspaces[0];
    std::wstring ws0 = (g_focusWs >= 0) ? ws + L"  (focused)" : ws;
    SendMessageW(g_status, SB_SETTEXTW, 0, (LPARAM)ws0.c_str());
    int n = 0; for (auto* s : g_sessions) if (!s->hidden) n++;
    wsprintfW(buf, L"%d session%s  \x00B7  Rust pty-host", n, n == 1 ? L"" : L"s");
    SendMessageW(g_status, SB_SETTEXTW, 1, (LPARAM)buf);
    if (Session* s = focusedSession()) {
        FfiEmuInfo info{}; EnterCriticalSection(&g_lock); emu_info(s->emu, &info); LeaveCriticalSection(&g_lock);
        wsprintfW(buf, L"%u \x00D7 %u", info.cols, info.rows); SendMessageW(g_status, SB_SETTEXTW, 2, (LPARAM)buf);
    }
    if (!g_catalog.empty() && g_faceIdx >= 0 && g_faceIdx < (int)g_catalog.size()) {
        const FontEntry& e = g_catalog[g_faceIdx];
        const wchar_t* sz = (g_sizeIdx >= 0 && g_sizeIdx < (int)e.sizes.size()) ? e.sizes[g_sizeIdx].label : L"";
        wsprintfW(buf, L"%s %s", e.label, sz); SendMessageW(g_status, SB_SETTEXTW, 3, (LPARAM)buf);
    }
}
// Rebuild the native TreeView sidebar from the session list; select the focused pane's session.
// UI-thread only (worker threads post WM_APP_REFRESHTREE instead).
static void refreshTree() {
    if (!g_tree) return;
    // Enforced, not merely documented: session.move, workspace.delete and workspace.focus reached
    // here inline on a control-pipe thread, driving the UI thread's TreeView by cross-thread
    // SendMessage. Under g_lock (below) that is a deadlock - the UI thread waits for g_lock in
    // paintPane while this thread waits for the UI thread to pump - and even unlocked it was a
    // worker thread mutating the tree control. Any other thread gets the posted rebuild instead.
    if (GetWindowThreadProcessId(g_hwnd, nullptr) != GetCurrentThreadId()) {
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        return;
    }
    {
    // Held for the rebuild only: this walks g_sessions and reads names that pipe threads mutate
    // under g_lock. updateStatus and saveSessionState below each take the lock themselves (the
    // first for its whole body, the second for its reads, released before the flushed writes);
    // a hold from here would keep every pty reader and control verb waiting through the disk I/O.
    LockG hold;
    g_treeSyncing = true;
    TreeView_DeleteAllItems(g_tree);
    HTREEITEM sel = nullptr;
    int focusIdx = g_pane[g_focus];
    // Group sessions under their workspace ("folder"). lParam encodes the node: >=0 session index,
    // <0 = -(workspace index + 1).
    bool anyShown = false;
    for (int w = 0; w < (int)g_workspaces.size(); w++) {
        if (g_focusWs >= 0 && w != g_focusWs) continue;   // focused workspace: show only it
        int count = 0, flaggedCount = 0;
        for (auto* s : g_sessions) if (s->ws == w && !s->hidden) { count++; if (s->flagged) flaggedCount++; }
        if (g_flagView && flaggedCount == 0) continue;   // flagged view: only workspaces with flagged sessions
        wchar_t wlabel[96];
        wsprintfW(wlabel, L"%s  (%d)", g_workspaces[w].c_str(), g_flagView ? flaggedCount : count);
        TVINSERTSTRUCTW wt{};
        wt.hParent = TVI_ROOT;
        wt.hInsertAfter = TVI_LAST;
        wt.item.mask = TVIF_TEXT | TVIF_PARAM;
        wt.item.pszText = wlabel;
        wt.item.lParam = -(w + 1);
        HTREEITEM wh = TreeView_InsertItem(g_tree, &wt);
        anyShown = true;
        int vis = 0;   // visible session number within the workspace
        for (int i = 0; i < (int)g_sessions.size(); i++) {
            if (g_sessions[i]->ws != w || g_sessions[i]->hidden) continue;   // skip split shells
            Session* s = g_sessions[i];
            ++vis;   // stable numbering: count ALL the workspace's sessions, filtered or not
            if (g_flagView && !s->flagged) continue;                         // flagged view filter
            // Agent status cue: name goes bold when the agent needs you (blocked), italic + "(working…)"
            // while it's busy (italic applied in the tree's NM_CUSTOMDRAW). Others show plain.
            int cls = s->exited ? AGST_NONE : statusClass(statusOf(s).status);
            std::wstring label = s->name.empty() ? (L"session " + std::to_wstring(vis)) : s->name;
            if (s->failed) label += L"  (failed to start)";   // restored spec whose app won't run here
            else if (s->exited) label += L"  (exited)";
            else if (cls == AGST_WORKING) label += L"  (working…)";
            TVINSERTSTRUCTW tis{};
            tis.hParent = wh;
            tis.hInsertAfter = TVI_LAST;
            tis.item.mask = TVIF_TEXT | TVIF_PARAM | TVIF_STATE;
            tis.item.stateMask = TVIS_BOLD;
            tis.item.state = (cls == AGST_BLOCKED) ? TVIS_BOLD : 0;
            tis.item.pszText = (LPWSTR)label.c_str();
            tis.item.lParam = i;
            HTREEITEM h = TreeView_InsertItem(g_tree, &tis);
            if (i == focusIdx) sel = h;
        }
        TreeView_Expand(g_tree, wh, TVE_EXPAND);
    }
    if (g_flagView && !anyShown) {   // hint row; lParam sentinel is out of range for every handler
        TVINSERTSTRUCTW ti{};
        ti.hParent = TVI_ROOT; ti.hInsertAfter = TVI_LAST;
        ti.item.mask = TVIF_TEXT | TVIF_PARAM;
        ti.item.pszText = (LPWSTR)L"No flagged sessions (right-click one to flag)";
        ti.item.lParam = -100000;
        TreeView_InsertItem(g_tree, &ti);
    }
    if (sel) TreeView_SelectItem(g_tree, sel);
    g_treeSyncing = false;
    }   // g_lock released
    updateStatus();
    if (!g_restoring) saveSessionState();   // persist the workspace/session structure on every change
}

// Remove a workspace; its sessions fall back to the first workspace (indices shift down).
static void deleteWorkspace(int w) {
    {   // under g_lock: reached from workspace.delete on a pipe thread while `tree` (another pipe
        // thread) and refreshTree index this vector under the lock; the erase moves every later
        // name down and destroys the last, and the ws fixups must land with it
        LockG hold;
        if ((int)g_workspaces.size() <= 1 || w < 0 || w >= (int)g_workspaces.size()) return;
        g_workspaces.erase(g_workspaces.begin() + w);
        for (auto* s : g_sessions) {
            if (s->ws == w) s->ws = 0;
            else if (s->ws > w) s->ws--;
        }
        if (g_activeWs == w) g_activeWs = 0;
        else if (g_activeWs > w) g_activeWs--;
        if (g_focusWs == w) g_focusWs = -1;
        else if (g_focusWs > w) g_focusWs--;
    }
    refreshTree();
}

// Right-click menu on a tree node — session or workspace, mirroring the full app's sidebar menus.
// Acts on the RIGHT-CLICKED node (g_ctxParam), not the focused session, and dispatches inline via
// TPM_RETURNCMD (no WM_COMMAND re-entrancy, no selection change — so the active terminal doesn't jump).
static void showTreeContextMenu() {
    bool isSession = g_ctxParam >= 0;
    int si = isSession ? (int)g_ctxParam : -1;
    int cws = isSession ? (si < (int)g_sessions.size() ? g_sessions[si]->ws : 0) : (int)(-g_ctxParam - 1);
    if (!isSession && (cws < 0 || cws >= (int)g_workspaces.size())) return;   // hint row etc.
    POINT pt; GetCursorPos(&pt);
    HMENU m = CreatePopupMenu();
    if (isSession) {   // ---- session node ----
        AppendMenuW(m, MF_STRING, IDM_NEW, L"&New Session…");
        AppendMenuW(m, MF_STRING, IDM_DUP, L"&Duplicate Session");
        AppendMenuW(m, MF_STRING, IDM_RENAME, L"Re&name");
        AppendMenuW(m, MF_STRING, IDM_FLAG,
                    (si < (int)g_sessions.size() && g_sessions[si]->flagged) ? L"Unfla&g" : L"Fla&g");
        if ((int)g_workspaces.size() > 1) {
            HMENU sub = CreatePopupMenu();
            for (int w = 0; w < (int)g_workspaces.size(); w++)
                if (w != cws) AppendMenuW(sub, MF_STRING, IDM_MOVE_BASE + w, g_workspaces[w].c_str());
            AppendMenuW(m, MF_POPUP, (UINT_PTR)sub, L"&Move to");
        }
        AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(m, MF_STRING, IDM_CLOSE, L"&Close Session");
    } else {           // ---- workspace node ----
        AppendMenuW(m, MF_STRING, IDM_NEW, L"&New Session");
        AppendMenuW(m, MF_STRING, IDM_NEWWS, L"New &Workspace");
        AppendMenuW(m, MF_STRING, IDM_RENAME, L"Re&name");
        AppendMenuW(m, MF_STRING, IDM_FOCUSWS, g_focusWs == cws ? L"Unf&ocus Workspace" : L"F&ocus Workspace");
        AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(m, MF_STRING | ((int)g_workspaces.size() <= 1 ? MF_GRAYED : 0), IDM_DELWS, L"&Delete Workspace");
    }
    SetForegroundWindow(g_hwnd);
    int id = (int)TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_RETURNCMD, pt.x, pt.y, 0, g_hwnd, nullptr);
    DestroyMenu(m);
    if (id == 0) return;   // dismissed
    switch (id) {
        case IDM_NEW: g_activeWs = cws; newSessionDialog(); break;
        case IDM_NEWWS: {
            wchar_t nm[32]; wsprintfW(nm, L"workspace %d", (int)g_workspaces.size() + 1);
            { LockG hold; g_workspaces.push_back(nm); g_activeWs = (int)g_workspaces.size() - 1; }   // `tree` walks it under g_lock
            refreshTree();
            break;
        }
        case IDM_DUP:
            if (isSession) {
                g_activeWs = cws;
                int c, r; newSessionGrid(g_focus, &c, &r);
                Session* s = newSession(c, r);
                if (s) { selectPrimary((int)g_sessions.size() - 1); InvalidateRect(g_hwnd, nullptr, FALSE); }
            }
            break;
        case IDM_RENAME:
            // g_treeRenaming keeps treeProc's WM_SETFOCUS bounce out of the way until the edit
            // control exists (after that TreeView_GetEditControl answers for it).
            if (g_ctxItem) { g_treeRenaming = true; SetFocus(g_tree); TreeView_EditLabel(g_tree, g_ctxItem); g_treeRenaming = false; }
            break;
        case IDM_FLAG:
            if (isSession && si < (int)g_sessions.size()) toggleFlag(g_sessions[si]);
            break;
        case IDM_CLOSE:
            if (isSession) closeSessionAt(si);
            break;
        case IDM_DELWS:
            if (!isSession) deleteWorkspace(cws);
            break;
        case IDM_FOCUSWS:
            if (!isSession) toggleFocusWs(cws);
            break;
        default:
            if (isSession && id >= IDM_MOVE_BASE && id < IDM_MOVE_BASE + (int)g_workspaces.size()
                && si < (int)g_sessions.size()) {
                g_sessions[si]->ws = id - IDM_MOVE_BASE;   // move to workspace
                refreshTree();
            }
            break;
    }
}

static HMENU buildMenuBar() {
    HMENU file = CreatePopupMenu();
    AppendMenuW(file, MF_STRING, IDM_NEW, L"&New Session…");
    AppendMenuW(file, MF_STRING, IDM_NEWWS, L"New &Workspace");
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, IDM_CLOSE, L"&Close Session");
    AppendMenuW(file, MF_STRING, IDM_REOPEN, L"Reop&en Closed Session");
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, IDM_KEYBOARD, L"&Keyboard…");
    AppendMenuW(file, MF_STRING, IDM_PROPERTIES, L"P&roperties…");
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, IDM_RESTART, L"&Restart everything");
    AppendMenuW(file, MF_STRING, IDM_EXIT, L"E&xit");
    HMENU edit = CreatePopupMenu();
    AppendMenuW(edit, MF_STRING, IDM_COPY, L"&Copy");
    AppendMenuW(edit, MF_STRING, IDM_PASTE, L"&Paste");
    HMENU view = CreatePopupMenu();
    AppendMenuW(view, MF_STRING, IDM_SPLIT, L"&Split / Unsplit");
    AppendMenuW(view, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(view, MF_STRING, IDM_NEXT, L"&Next Session");
    AppendMenuW(view, MF_STRING, IDM_PREV, L"&Previous Session");
    AppendMenuW(view, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(view, MF_STRING, IDM_PALETTE, L"Co&mmand Palette");
    AppendMenuW(view, MF_STRING, IDM_QUICK, L"&Quick Terminal");
    AppendMenuW(view, MF_STRING, IDM_SCRATCH, L"Sc&ratch Terminal");
    AppendMenuW(view, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(view, MF_STRING, IDM_FLAG, L"Fla&g / Unflag Session");
    AppendMenuW(view, MF_STRING | (g_flagView ? MF_CHECKED : 0), IDM_FLAGVIEW, L"Flagged Vie&w");
    AppendMenuW(view, MF_STRING | (g_focusWs >= 0 ? MF_CHECKED : 0), IDM_FOCUSWS, L"F&ocus Workspace");
    AppendMenuW(view, MF_STRING, IDM_ATTENTION, L"Next Bloc&ked Session");
    AppendMenuW(view, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(view, MF_STRING | (g_showSidebar ? MF_CHECKED : 0), IDM_TG_SIDEBAR, L"Side&bar");
    AppendMenuW(view, MF_STRING | (g_showToolbar ? MF_CHECKED : 0), IDM_TG_TOOLBAR, L"&Toolbar");
    AppendMenuW(view, MF_STRING | (g_showStatus ? MF_CHECKED : 0), IDM_TG_STATUS, L"Status &Bar");
    // Font selection lives in File -> Properties now (no separate View -> Font submenu).
    HMENU help = CreatePopupMenu();
    AppendMenuW(help, MF_STRING, IDM_INSTALLSKILL, L"Install Agent &Skill…");
    AppendMenuW(help, MF_STRING, IDM_UPDATE, L"Check for &Updates…");
    AppendMenuW(help, MF_STRING, IDM_ABOUT, L"&About agliteterm");
    HMENU bar = CreateMenu();
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)file, L"&File");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)edit, L"&Edit");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)view, L"&View");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)help, L"&Help");
    return bar;
}

// ---- New Session modal dialog (native popup + listbox, no .rc resource) ----
static HWND g_dlgList;
static int g_dlgResult;   // -1 = cancel, else selected profile index

static LRESULT CALLBACK profileDlgProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    { LRESULT tr; if (themeDlgMsg(h, m, w, &tr)) return tr; }   // dark background + control colours
    if (m == WM_DRAWITEM) { drawDlgButton((LPDRAWITEMSTRUCT)l); return TRUE; }
    if (m == DM_GETDEFID) return MAKELRESULT(IDOK, DC_HASDEFID);
    switch (m) {
        case WM_COMMAND:
            if (LOWORD(w) == IDOK || (LOWORD(w) == 1000 && HIWORD(w) == LBN_DBLCLK)) {
                g_dlgResult = (int)SendMessageW(g_dlgList, LB_GETCURSEL, 0, 0);
                DestroyWindow(h);
                return 0;
            }
            if (LOWORD(w) == IDCANCEL) { g_dlgResult = -1; DestroyWindow(h); return 0; }
            break;
        case WM_CLOSE: g_dlgResult = -1; DestroyWindow(h); return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

// Modal profile picker; returns the chosen index or -1. Runs a local loop with the parent disabled.
static int pickProfileDialog(const std::vector<Profile>& profs) {
    static bool reg = false;
    HINSTANCE inst = GetModuleHandleW(nullptr);
    if (!reg) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = profileDlgProc;
        wc.hInstance = inst;
        wc.lpszClassName = L"AgwintermLiteDlg";
        wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
        wc.hCursor = LoadCursorW(nullptr, (LPCWSTR)IDC_ARROW);
        RegisterClassW(&wc);
        reg = true;
    }
    const int W = 300, H = 250;
    RECT pw; GetWindowRect(g_hwnd, &pw);
    HWND dlg = CreateWindowExW(WS_EX_DLGMODALFRAME, L"AgwintermLiteDlg", L"New Session",
                               WS_POPUP | WS_CAPTION | WS_SYSMENU,
                               pw.left + 70, pw.top + 70, W, H, g_hwnd, nullptr, inst, nullptr);
    HFONT gui = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    RECT cr; GetClientRect(dlg, &cr);
    HWND lbl = CreateWindowExW(0, L"STATIC", L"Choose a shell:", WS_CHILD | WS_VISIBLE,
                               12, 10, cr.right - 24, 18, dlg, nullptr, inst, nullptr);
    g_dlgList = CreateWindowExW(WS_EX_CLIENTEDGE, L"LISTBOX", L"",
                                WS_CHILD | WS_VISIBLE | WS_VSCROLL | LBS_NOTIFY,
                                12, 32, cr.right - 24, cr.bottom - 84, dlg, (HMENU)1000, inst, nullptr);
    SetWindowSubclass(g_dlgList, fieldRingProc, 1, 0);   // dark bezel over the classic client edge
    for (const auto& p : profs) SendMessageW(g_dlgList, LB_ADDSTRING, 0, (LPARAM)p.name.c_str());
    SendMessageW(g_dlgList, LB_SETCURSEL, 0, 0);
    HWND ok = CreateWindowExW(0, L"BUTTON", L"OK", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                              cr.right - 176, cr.bottom - 40, 78, 26, dlg, (HMENU)IDOK, inst, nullptr);
    HWND cancel = CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                                  cr.right - 90, cr.bottom - 40, 78, 26, dlg, (HMENU)IDCANCEL, inst, nullptr);
    for (HWND c : { lbl, g_dlgList, ok, cancel }) SendMessageW(c, WM_SETFONT, (WPARAM)gui, TRUE);
    g_dlgResult = -1;
    themeDialog(dlg);
    EnableWindow(g_hwnd, FALSE);
    ShowWindow(dlg, SW_SHOW);
    SetFocus(g_dlgList);
    MSG msg;
    while (IsWindow(dlg)) {
        if (!GetMessageW(&msg, nullptr, 0, 0)) { PostQuitMessage((int)msg.wParam); break; }  // WM_QUIT — bail
        if (!IsDialogMessageW(dlg, &msg)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    }
    EnableWindow(g_hwnd, TRUE);
    SetForegroundWindow(g_hwnd);
    SetFocus(g_hwnd);
    return g_dlgResult;
}

// Open the New Session dialog and create the chosen shell (in an optional folder).
static void newSessionDialog(const char* cwd) {
    auto profs = detectProfiles();
    int i = pickProfileDialog(profs);
    if (i < 0 || i >= (int)profs.size()) return;
    int c, r; newSessionGrid(g_focus, &c, &r);
    Session* s = newSession(c, r, profs[i].app.c_str(), &profs[i].args, cwd);
    if (s) { selectPrimary((int)g_sessions.size() - 1); InvalidateRect(g_hwnd, nullptr, FALSE); }
}

// ---- Properties dialog (cmd.exe-style: font + colors, live preview) ----
// The legacy Windows console 16-colour palette, so the swatches feel like the old cmd.exe Colors tab.
static const COLORREF kConsolePalette[16] = {
    RGB(0,0,0),     RGB(0,0,128),   RGB(0,128,0),   RGB(0,128,128),
    RGB(128,0,0),   RGB(128,0,128), RGB(128,128,0), RGB(192,192,192),
    RGB(128,128,128),RGB(0,0,255),  RGB(0,255,0),   RGB(0,255,255),
    RGB(255,0,0),   RGB(255,0,255), RGB(255,255,0), RGB(255,255,255),
};
enum { PID_FONTLIST = 3001, PID_SIZECOMBO = 3002, PID_THEME = 3003, PID_USECOLORS = 3030, PID_TEXT = 3010, PID_BG = 3011, PID_APPLY = 3020, PID_DOSPAL = 3031, PID_SIDEFONT = 3004 };
static const int SW_X0 = 16, SW_Y = 186, SW = 20, SW_GAP = 22;   // swatch grid geometry (WM_PAINT + hit-test)
static const wchar_t* kThemeNames[4] = { L"Auto (follow Windows)", L"Dark", L"Light", L"Classic" };
// Working copies edited by the dialog; committed to the globals on OK/Apply.
static int g_pFace, g_pSize, g_pTheme; static uint32_t g_pFg, g_pBg; static int g_pTarget; static bool g_pUse, g_pDos;
static void applyTreeFont();   // fwd: propCommit applies the sidebar size, defined with the tree
static HFONT g_pPrev; static HWND g_pHwnd, g_pSizeCombo, g_pSideFontCombo;

static int g_pSidePt;   // pending sidebar point size (0 = follow the shell)

// ---- owner-drawn dialog buttons ---------------------------------------------------------------
// Roles are known by id; check/radio state lives in the working copies (the buttons are plain
// BS_OWNERDRAW, so nothing auto-toggles — the WM_COMMAND handlers flip the state and repaint).
static bool dlgBtnChecked(int id) {
    switch (id) {
        case PID_USECOLORS: return g_pUse;
        case PID_DOSPAL:    return g_pDos;
        case PID_TEXT:      return g_pTarget == 0;
        case PID_BG:        return g_pTarget == 1;
    }
    return false;
}
static void drawDlgButton(LPDRAWITEMSTRUCT d) {
    if (!d || d->CtlType != ODT_BUTTON) return;
    HDC dc = d->hDC; RECT rc = d->rcItem;
    int id = (int)d->CtlID;
    bool check = (id == PID_USECOLORS || id == PID_DOSPAL);
    bool radio = (id == PID_TEXT || id == PID_BG);
    bool push  = !check && !radio;
    bool sel   = (d->itemState & ODS_SELECTED) != 0;
    bool focus = (d->itemState & ODS_FOCUS) != 0;
    wchar_t txt[128]{};
    GetWindowTextW(d->hwndItem, txt, 128);
    HFONT of = g_uiFont ? (HFONT)SelectObject(dc, g_uiFont) : nullptr;
    SetBkMode(dc, TRANSPARENT);
    if (g_th.classic) {   // DrawFrameControl IS the classic renderer — pixel-faithful
        if (push) {
            DrawFrameControl(dc, &rc, DFC_BUTTON, DFCS_BUTTONPUSH | (sel ? DFCS_PUSHED : 0));
            RECT tr = rc; if (sel) OffsetRect(&tr, 1, 1);
            SetTextColor(dc, GetSysColor(COLOR_BTNTEXT));
            DrawTextW(dc, txt, -1, &tr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            if (focus) { RECT fr = rc; InflateRect(&fr, -4, -4); DrawFocusRect(dc, &fr); }
        } else {
            HBRUSH bg = (HBRUSH)(COLOR_BTNFACE + 1);
            FillRect(dc, &rc, bg);
            RECT gl{ rc.left, (rc.top + rc.bottom) / 2 - 7, rc.left + 13, (rc.top + rc.bottom) / 2 + 6 };
            DrawFrameControl(dc, &gl, DFC_BUTTON,
                             (radio ? DFCS_BUTTONRADIO : DFCS_BUTTONCHECK) | (dlgBtnChecked(id) ? DFCS_CHECKED : 0));
            RECT tr{ rc.left + 18, rc.top, rc.right, rc.bottom };
            SetTextColor(dc, GetSysColor(COLOR_BTNTEXT));
            DrawTextW(dc, txt, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
            if (focus) { RECT fr = tr; fr.bottom = fr.top + (rc.bottom - rc.top); DrawFocusRect(dc, &fr); }
        }
    } else {   // themed: flat fill + painted glyphs, dark and light alike
        FillRect(dc, &rc, g_thBrBar);
        SetTextColor(dc, g_th.text);
        if (push) {
            HBRUSH face = CreateSolidBrush(sel ? g_th.sel : g_th.hot);
            FillRect(dc, &rc, face); DeleteObject(face);
            HBRUSH fr = CreateSolidBrush(focus || sel ? g_th.accent : g_th.border);
            FrameRect(dc, &rc, fr); DeleteObject(fr);
            DrawTextW(dc, txt, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        } else {
            int cy = (rc.top + rc.bottom) / 2;
            RECT gl{ rc.left, cy - 7, rc.left + 13, cy + 6 };
            HBRUSH bb = CreateSolidBrush(g_th.dim);
            if (radio) {   // circle + dot
                HPEN pen = CreatePen(PS_SOLID, 1, g_th.dim);
                HGDIOBJ op = SelectObject(dc, pen), ob = SelectObject(dc, GetStockObject(NULL_BRUSH));
                Ellipse(dc, gl.left, gl.top, gl.right, gl.bottom);
                SelectObject(dc, op); SelectObject(dc, ob); DeleteObject(pen);
                if (dlgBtnChecked(id)) {
                    HBRUSH dot = CreateSolidBrush(g_th.accent);
                    HGDIOBJ od = SelectObject(dc, dot); HPEN np = CreatePen(PS_SOLID, 1, g_th.accent);
                    HGDIOBJ onp = SelectObject(dc, np);
                    Ellipse(dc, gl.left + 4, gl.top + 4, gl.right - 4, gl.bottom - 4);
                    SelectObject(dc, od); SelectObject(dc, onp); DeleteObject(dot); DeleteObject(np);
                }
            } else {       // box + check mark
                FrameRect(dc, &gl, bb);
                if (dlgBtnChecked(id)) {
                    HPEN pen = CreatePen(PS_SOLID, 2, g_th.accent);
                    HGDIOBJ op = SelectObject(dc, pen);
                    MoveToEx(dc, gl.left + 3, gl.top + 6, nullptr);
                    LineTo(dc, gl.left + 5, gl.top + 9);
                    LineTo(dc, gl.left + 10, gl.top + 3);
                    SelectObject(dc, op); DeleteObject(pen);
                }
            }
            DeleteObject(bb);
            RECT tr{ rc.left + 18, rc.top, rc.right, rc.bottom };
            DrawTextW(dc, txt, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
            if (focus) { HBRUSH fr = CreateSolidBrush(g_th.border); RECT fb = rc; FrameRect(dc, &fb, fr); DeleteObject(fr); }
        }
    }
    if (of) SelectObject(dc, of);
}

// v5 combo boxes draw a classic light face + arrow that no theme can reach; themed looks take over
// the whole closed-field paint. The dropdown list is already dark via WM_CTLCOLORLISTBOX.
static LRESULT CALLBACK comboProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
    if (m == WM_NCDESTROY) RemoveWindowSubclass(h, comboProc, id);
    if (m == WM_NCPAINT && g_th.dark && !g_th.classic) {   // the WS_BORDER ring outside our paint
        LRESULT r = DefSubclassProc(h, m, w, l);
        if (HDC dc = GetWindowDC(h)) {
            RECT wr; GetWindowRect(h, &wr);
            RECT rc{ 0, 0, wr.right - wr.left, wr.bottom - wr.top };
            HBRUSH br = CreateSolidBrush(g_th.border);
            FrameRect(dc, &rc, br); DeleteObject(br);
            ReleaseDC(h, dc);
        }
        return r;
    }
    if (!g_th.classic && (m == WM_PAINT || m == WM_ERASEBKGND)) {
        if (m == WM_ERASEBKGND) return 1;
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        bool dropped = SendMessageW(h, CB_GETDROPPEDSTATE, 0, 0) != 0;
        bool focus = GetFocus() == h;
        FillRect(dc, &rc, g_thBrClient);
        HBRUSH fr = CreateSolidBrush((dropped || focus) ? g_th.accent : g_th.border);
        FrameRect(dc, &rc, fr); DeleteObject(fr);
        int sel = (int)SendMessageW(h, CB_GETCURSEL, 0, 0);
        wchar_t txt[128]{};
        if (sel >= 0) SendMessageW(h, CB_GETLBTEXT, sel, (LPARAM)txt);
        HFONT of = g_uiFont ? (HFONT)SelectObject(dc, g_uiFont) : nullptr;
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, IsWindowEnabled(h) ? g_th.text : g_th.dim);
        RECT tr{ rc.left + 6, rc.top, rc.right - 20, rc.bottom };
        DrawTextW(dc, txt, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        int cx = rc.right - 11, cy = (rc.top + rc.bottom) / 2 - 1;   // ▼
        POINT a[3] = { { cx - 4, cy - 1 }, { cx + 4, cy - 1 }, { cx, cy + 3 } };
        HBRUSH ab = CreateSolidBrush(g_th.text); HPEN ap = CreatePen(PS_SOLID, 1, g_th.text);
        HGDIOBJ ob = SelectObject(dc, ab), op = SelectObject(dc, ap);
        Polygon(dc, a, 3);
        SelectObject(dc, ob); SelectObject(dc, op); DeleteObject(ab); DeleteObject(ap);
        if (of) SelectObject(dc, of);
        EndPaint(h, &ps);
        return 0;
    }
    return DefSubclassProc(h, m, w, l);
}

static HFONT makePreviewFontSel() {
    if (g_pFace < 0 || g_pFace >= (int)g_catalog.size()) return nullptr;
    FontEntry& e = g_catalog[g_pFace];
    int si = (g_pSize >= 0 && g_pSize < (int)e.sizes.size()) ? g_pSize : 0;
    return createFontSpec(e, e.sizes[si], false, false);
}
static void refreshPreview(HWND h) {
    if (g_pPrev) DeleteObject(g_pPrev);
    g_pPrev = makePreviewFontSel();
    InvalidateRect(h, nullptr, TRUE);
}
static void fillSizeCombo(int sel) {   // sizes for the current face; disabled if the face has only one
    SendMessageW(g_pSizeCombo, CB_RESETCONTENT, 0, 0);
    if (g_pFace < 0 || g_pFace >= (int)g_catalog.size()) return;
    FontEntry& e = g_catalog[g_pFace];
    for (auto& s : e.sizes) SendMessageW(g_pSizeCombo, CB_ADDSTRING, 0, (LPARAM)s.label);
    SendMessageW(g_pSizeCombo, CB_SETCURSEL, (sel >= 0 && sel < (int)e.sizes.size()) ? sel : 0, 0);
    EnableWindow(g_pSizeCombo, e.sizes.size() > 1);
}
static void propCommit() {
    pickFont(g_pFace, g_pSize);   // applies the font, persists face+size
    g_customColors = g_pUse; g_defFg = g_pFg; g_defBg = g_pBg; g_dosPalette = g_pDos;
    if (g_pSidePt != g_treeFontPt) { g_treeFontPt = g_pSidePt; applyTreeFont(); relayout(); }
    if (g_pTheme != g_themeMode) {   // theme switch: re-skin everything live, incl. this open dialog
        g_themeMode = g_pTheme;
        applyTheme();
        themeDialog(g_pHwnd);
    }
    saveColors();
    InvalidateRect(g_hwnd, nullptr, TRUE);
}
static LRESULT CALLBACK propDlgProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    { LRESULT tr; if (themeDlgMsg(h, m, w, &tr)) return tr; }   // dark background + control colours
    if (m == WM_DRAWITEM) { drawDlgButton((LPDRAWITEMSTRUCT)l); return TRUE; }
    if (m == DM_GETDEFID) return MAKELRESULT(IDOK, DC_HASDEFID);   // Enter = OK (owner-draw lost BS_DEFPUSHBUTTON)
    switch (m) {
        case WM_COMMAND:
            switch (LOWORD(w)) {
                case PID_THEME:
                    if (HIWORD(w) == CBN_SELCHANGE) g_pTheme = (int)SendMessageW((HWND)l, CB_GETCURSEL, 0, 0);
                    break;
                case PID_SIDEFONT:
                    if (HIWORD(w) == CBN_SELCHANGE) {
                        int i = (int)SendMessageW((HWND)l, CB_GETCURSEL, 0, 0);
                        g_pSidePt = (i <= 0) ? 0 : 8 + i - 1;   // item 0 is "System default"
                    }
                    break;
                case PID_FONTLIST:
                    if (HIWORD(w) == LBN_SELCHANGE) {
                        g_pFace = (int)SendMessageW((HWND)l, LB_GETCURSEL, 0, 0);
                        g_pSize = 0; fillSizeCombo(0);   // new face -> repopulate sizes, default first
                        refreshPreview(h);
                    }
                    break;
                case PID_SIZECOMBO:
                    if (HIWORD(w) == CBN_SELCHANGE) { g_pSize = (int)SendMessageW((HWND)l, CB_GETCURSEL, 0, 0); refreshPreview(h); }
                    break;
                // Owner-drawn buttons don't auto-toggle: flip the working state and repaint them.
                case PID_USECOLORS: g_pUse = !g_pUse; InvalidateRect((HWND)l, nullptr, TRUE); InvalidateRect(h, nullptr, TRUE); break;
                case PID_DOSPAL: g_pDos = !g_pDos; InvalidateRect((HWND)l, nullptr, TRUE); break;
                case PID_TEXT: case PID_BG:
                    g_pTarget = (LOWORD(w) == PID_BG) ? 1 : 0;
                    InvalidateRect(GetDlgItem(h, PID_TEXT), nullptr, TRUE);
                    InvalidateRect(GetDlgItem(h, PID_BG), nullptr, TRUE);
                    InvalidateRect(h, nullptr, TRUE);
                    break;
                case PID_APPLY: propCommit(); break;
                case IDOK: propCommit(); DestroyWindow(h); break;
                case IDCANCEL: DestroyWindow(h); break;
            }
            return 0;
        case WM_LBUTTONDOWN: {
            int mx = GET_X_LPARAM(l), my = GET_Y_LPARAM(l);
            if (my >= SW_Y && my < SW_Y + SW) {
                int i = (mx - SW_X0) / SW_GAP;
                if (i >= 0 && i < 16 && mx >= SW_X0 + i * SW_GAP && mx < SW_X0 + i * SW_GAP + SW) {
                    COLORREF cr = kConsolePalette[i];
                    uint32_t packed = (GetRValue(cr) << 16) | (GetGValue(cr) << 8) | GetBValue(cr);
                    if (g_pTarget == 0) g_pFg = packed; else g_pBg = packed;
                    if (!g_pUse) { g_pUse = true; CheckDlgButton(h, PID_USECOLORS, BST_CHECKED); }
                    InvalidateRect(h, nullptr, TRUE);
                }
            }
            return 0;
        }
        case WM_PAINT: {
            PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
            HGDIOBJ uiOld = SelectObject(dc, g_uiFont ? g_uiFont : (HFONT)GetStockObject(DEFAULT_GUI_FONT));   // never the System bitmap default
            SetTextColor(dc, g_th.classic ? GetSysColor(COLOR_BTNTEXT) : g_th.text);   // labels follow the theme
            // Colour swatches
            for (int i = 0; i < 16; i++) {
                RECT s{ SW_X0 + i * SW_GAP, SW_Y, SW_X0 + i * SW_GAP + SW, SW_Y + SW };
                HBRUSH b = CreateSolidBrush(kConsolePalette[i]); FillRect(dc, &s, b); DeleteObject(b);
                FrameRect(dc, &s, (HBRUSH)GetStockObject(BLACK_BRUSH));
            }
            // Selected text/bg colour chips
            auto chip = [&](int x, const wchar_t* lbl, uint32_t packed) {
                RECT lr{ x, SW_Y + 30, x + 90, SW_Y + 46 };
                SetBkMode(dc, TRANSPARENT); DrawTextW(dc, lbl, -1, &lr, DT_LEFT | DT_SINGLELINE);
                RECT cr{ x + 92, SW_Y + 28, x + 118, SW_Y + 48 };
                HBRUSH b = CreateSolidBrush(RGB((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF));
                FillRect(dc, &cr, b); DeleteObject(b); FrameRect(dc, &cr, (HBRUSH)GetStockObject(BLACK_BRUSH));
            };
            chip(16, g_pTarget == 0 ? L"\x25B6 Text" : L"Text", g_pFg);
            chip(150, g_pTarget == 1 ? L"\x25B6 Background" : L"Background", g_pBg);
            // Live preview: sample terminal text in the working font + colours
            RECT pv{ 16, SW_Y + 60, 372, SW_Y + 170 };
            HBRUSH pb = CreateSolidBrush(RGB((g_pBg >> 16) & 0xFF, (g_pBg >> 8) & 0xFF, g_pBg & 0xFF));
            FillRect(dc, &pv, pb); DeleteObject(pb);
            FrameRect(dc, &pv, (HBRUSH)GetStockObject(GRAY_BRUSH));
            HGDIOBJ of = SelectObject(dc, g_pPrev ? g_pPrev : (HFONT)GetStockObject(OEM_FIXED_FONT));
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, RGB((g_pFg >> 16) & 0xFF, (g_pFg >> 8) & 0xFF, g_pFg & 0xFF));
            TextOutW(dc, pv.left + 6, pv.top + 6,  L"C:\\> dir", 8);
            TextOutW(dc, pv.left + 6, pv.top + 24, L"Volume in drive C is SYSTEM", 27);
            TextOutW(dc, pv.left + 6, pv.top + 42, L"abcdefghij 0123456789 +-*/=", 27);
            SelectObject(dc, of);
            SelectObject(dc, uiOld);
            EndPaint(h, &ps);
            return 0;
        }
        case WM_CLOSE: DestroyWindow(h); return 0;
        case WM_DESTROY: if (g_pPrev) { DeleteObject(g_pPrev); g_pPrev = nullptr; } return 0;
    }
    return DefWindowProcW(h, m, w, l);
}
static void showPropertiesDialog() {
    static bool reg = false;
    HINSTANCE inst = GetModuleHandleW(nullptr);
    if (!reg) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = propDlgProc; wc.hInstance = inst; wc.lpszClassName = L"AgwintermLiteProps";
        wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1); wc.hCursor = LoadCursorW(nullptr, (LPCWSTR)IDC_ARROW);
        RegisterClassW(&wc); reg = true;
    }
    // Seed working state from the live settings.
    g_pFace = g_faceIdx; g_pSize = g_sizeIdx; g_pFg = g_defFg; g_pBg = g_defBg; g_pUse = g_customColors; g_pDos = g_dosPalette; g_pTarget = 0;
    g_pTheme = g_themeMode;
    if (g_pPrev) DeleteObject(g_pPrev);
    g_pPrev = makePreviewFontSel();
    const int W = 396, H = 518;   // grew for the Theme row (452 -> 490), then the Sidebar row
    RECT pw; GetWindowRect(g_hwnd, &pw);
    g_pHwnd = CreateWindowExW(WS_EX_DLGMODALFRAME, L"AgwintermLiteProps", L"agliteterm — Properties",
                              WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN,   // erase-on-repaint won't flicker the controls
                              pw.left + 60, pw.top + 40, W, H, g_hwnd, nullptr, inst, nullptr);
    HFONT gui = g_uiFont ? g_uiFont : (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    auto mk = [&](const wchar_t* cls, const wchar_t* txt, DWORD st, int x, int y, int w, int hh, int id) {
        HWND c = CreateWindowExW(0, cls, txt, WS_CHILD | WS_VISIBLE | st, x, y, w, hh, g_pHwnd, (HMENU)(INT_PTR)id, inst, nullptr);
        SendMessageW(c, WM_SETFONT, (WPARAM)gui, TRUE); return c;
    };
    mk(L"STATIC", L"Font:", 0, 16, 12, 120, 16, 0);
    HWND fl = mk(L"LISTBOX", L"", WS_BORDER | WS_VSCROLL | LBS_NOTIFY, 16, 30, 200, 96, PID_FONTLIST);
    SetWindowSubclass(fl, fieldRingProc, 1, 0);   // dark bezel
    for (const auto& e : g_catalog) SendMessageW(fl, LB_ADDSTRING, 0, (LPARAM)e.label);
    SendMessageW(fl, LB_SETCURSEL, g_pFace, 0);
    mk(L"STATIC", L"Size:", 0, 228, 12, 120, 16, 0);
    g_pSizeCombo = mk(L"COMBOBOX", L"", WS_BORDER | WS_VSCROLL | CBS_DROPDOWNLIST, 228, 30, 140, 240, PID_SIZECOMBO);
    fillSizeCombo(g_pSize);
    // All buttons are BS_OWNERDRAW (drawDlgButton): the v5 classic controls can't be themed, and in
    // Classic mode DrawFrameControl reproduces the stock look exactly. State lives in g_pUse etc.
    mk(L"BUTTON", L"Override default colors", BS_OWNERDRAW, 16, 134, 172, 18, PID_USECOLORS);
    mk(L"BUTTON", L"MS-DOS palette (EGA)", BS_OWNERDRAW, 194, 134, 180, 18, PID_DOSPAL);
    mk(L"BUTTON", L"Screen &Text", WS_GROUP | BS_OWNERDRAW, 28, 158, 110, 18, PID_TEXT);
    mk(L"BUTTON", L"Screen &Background", BS_OWNERDRAW, 150, 158, 150, 18, PID_BG);
    mk(L"STATIC", L"Theme:", 0, 16, 400, 56, 16, 0);
    HWND th = mk(L"COMBOBOX", L"", WS_BORDER | WS_VSCROLL | CBS_DROPDOWNLIST, 76, 396, 180, 140, PID_THEME);
    for (const wchar_t* n : kThemeNames) SendMessageW(th, CB_ADDSTRING, 0, (LPARAM)n);
    SendMessageW(th, CB_SETCURSEL, g_pTheme, 0);
    SetWindowSubclass(th, comboProc, 1, 0);              // themed closed-field paint (v5 combo)
    SetWindowSubclass(g_pSizeCombo, comboProc, 1, 0);
    // Sidebar text size. Separate from the terminal font on purpose: the terminal face is a raster
    // pack that only exists at its strike sizes, while the sidebar is ordinary UI text that can be
    // any size — and wanting a bigger session list is not wanting a bigger terminal.
    // BELOW the preview box, which ends at SW_Y + 170 = 356. Placed at 340 it drew straight over
    // the sample text - the one control in this dialog whose position is not free.
    mk(L"STATIC", L"Sidebar text:", 0, 16, 372, 80, 16, 0);
    g_pSideFontCombo = mk(L"COMBOBOX", L"", WS_BORDER | WS_VSCROLL | CBS_DROPDOWNLIST, 100, 368, 156, 220, PID_SIDEFONT);
    SendMessageW(g_pSideFontCombo, CB_ADDSTRING, 0, (LPARAM)L"System default");
    for (int pt = 8; pt <= 20; pt++) {
        wchar_t lbl[16]; wsprintfW(lbl, L"%d pt", pt);
        SendMessageW(g_pSideFontCombo, CB_ADDSTRING, 0, (LPARAM)lbl);
    }
    g_pSidePt = g_treeFontPt;
    SendMessageW(g_pSideFontCombo, CB_SETCURSEL, g_pSidePt ? (g_pSidePt - 8 + 1) : 0, 0);
    SetWindowSubclass(g_pSideFontCombo, comboProc, 1, 0);
    mk(L"BUTTON", L"OK", BS_OWNERDRAW, 120, 436, 78, 26, IDOK);
    mk(L"BUTTON", L"Cancel", BS_OWNERDRAW, 204, 436, 78, 26, IDCANCEL);
    mk(L"BUTTON", L"Apply", BS_OWNERDRAW, 288, 436, 78, 26, PID_APPLY);
    themeDialog(g_pHwnd);   // dark title bar + DarkMode styles when the dark theme is active
    EnableWindow(g_hwnd, FALSE);
    ShowWindow(g_pHwnd, SW_SHOW);
    MSG msg;
    while (IsWindow(g_pHwnd)) {
        if (!GetMessageW(&msg, nullptr, 0, 0)) { PostQuitMessage((int)msg.wParam); break; }
        if (!IsDialogMessageW(g_pHwnd, &msg)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    }
    EnableWindow(g_hwnd, TRUE);
    SetForegroundWindow(g_hwnd);
    SetFocus(g_hwnd);
}

// ---- Keyboard bindings dialog (native hotkey controls; all unbound by default) ----
static HWND g_kbHwnd, g_kbCtl[KB_COUNT];
enum { KBID_CLEAR = 4001, KBID_BASE = 4100 };   // KBID_BASE + action = that action's hotkey control
static LRESULT CALLBACK kbDlgProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    { LRESULT tr; if (themeDlgMsg(h, m, w, &tr)) return tr; }   // dark background + control colours
    if (m == WM_DRAWITEM) { drawDlgButton((LPDRAWITEMSTRUCT)l); return TRUE; }
    if (m == DM_GETDEFID) return MAKELRESULT(IDOK, DC_HASDEFID);
    switch (m) {
        case WM_COMMAND:
            switch (LOWORD(w)) {
                case KBID_CLEAR: for (int a = 0; a < KB_COUNT; a++) SendMessageW(g_kbCtl[a], HKM_SETHOTKEY, 0, 0); return 0;
                case IDOK:
                    for (int a = 0; a < KB_COUNT; a++) g_keys[a] = (WORD)SendMessageW(g_kbCtl[a], HKM_GETHOTKEY, 0, 0);
                    saveKeys(); DestroyWindow(h); return 0;
                case IDCANCEL: DestroyWindow(h); return 0;
            }
            return 0;
        case WM_CLOSE: DestroyWindow(h); return 0;
    }
    return DefWindowProcW(h, m, w, l);
}
static void showKeyboardDialog() {
    static bool reg = false;
    HINSTANCE inst = GetModuleHandleW(nullptr);
    if (!reg) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = kbDlgProc; wc.hInstance = inst; wc.lpszClassName = L"AgwintermLiteKeys";
        wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1); wc.hCursor = LoadCursorW(nullptr, (LPCWSTR)IDC_ARROW);
        RegisterClassW(&wc); reg = true;
    }
    const int W = 360, H = 96 + KB_COUNT * 26 + 56;
    RECT pw; GetWindowRect(g_hwnd, &pw);
    g_kbHwnd = CreateWindowExW(WS_EX_DLGMODALFRAME, L"AgwintermLiteKeys", L"agliteterm — Keyboard",
                               WS_POPUP | WS_CAPTION | WS_SYSMENU, pw.left + 60, pw.top + 40, W, H, g_hwnd, nullptr, inst, nullptr);
    HFONT gui = g_uiFont ? g_uiFont : (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    auto mk = [&](const wchar_t* cls, const wchar_t* txt, DWORD st, int x, int y, int ww, int hh, int id) {
        HWND c = CreateWindowExW(0, cls, txt, WS_CHILD | WS_VISIBLE | st, x, y, ww, hh, g_kbHwnd, (HMENU)(INT_PTR)id, inst, nullptr);
        SendMessageW(c, WM_SETFONT, (WPARAM)gui, TRUE); return c;
    };
    mk(L"STATIC", L"Assign a shortcut to each action (Backspace clears; unset = passed to the shell):",
       0, 16, 10, W - 40, 30, 0);
    for (int a = 0; a < KB_COUNT; a++) {
        int y = 50 + a * 26;
        mk(L"STATIC", kKbInfo[a].label, SS_CENTERIMAGE, 16, y, 150, 22, 0);
        g_kbCtl[a] = mk(HOTKEY_CLASSW, L"", WS_BORDER, 176, y, 160, 22, KBID_BASE + a);
        SetWindowSubclass(g_kbCtl[a], hotkeyProc, 1, 0);   // dark-theme paint takeover
        SendMessageW(g_kbCtl[a], HKM_SETRULES, HKCOMB_NONE, MAKEWORD(HOTKEYF_CONTROL, 0));   // bare key -> add Ctrl
        SendMessageW(g_kbCtl[a], HKM_SETHOTKEY, g_keys[a], 0);
    }
    int by = 50 + KB_COUNT * 26 + 8;
    mk(L"BUTTON", L"Clear all", BS_OWNERDRAW, 16, by, 90, 26, KBID_CLEAR);
    mk(L"BUTTON", L"OK", BS_OWNERDRAW, W - 190, by, 82, 26, IDOK);
    mk(L"BUTTON", L"Cancel", BS_OWNERDRAW, W - 100, by, 82, 26, IDCANCEL);
    themeDialog(g_kbHwnd);
    EnableWindow(g_hwnd, FALSE);
    ShowWindow(g_kbHwnd, SW_SHOW);
    MSG msg;
    while (IsWindow(g_kbHwnd)) {
        if (!GetMessageW(&msg, nullptr, 0, 0)) { PostQuitMessage((int)msg.wParam); break; }
        if (!IsDialogMessageW(g_kbHwnd, &msg)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    }
    EnableWindow(g_hwnd, TRUE);
    SetForegroundWindow(g_hwnd);
    SetFocus(g_hwnd);
}

// Restart everything: relaunch a fresh instance AFTER this one (and its pty-host) has fully exited,
// then quit. The ~1s ping delay avoids the new instance connecting to the dying pty-host.
// The relaunch carries this instance's --pipe (see restartCommandLine) so it reads the same state.
static void restartApp() {
    std::wstring cmd = L"cmd.exe /c ping -n 2 127.0.0.1 >nul & start \"\" " + restartCommandLine();
    logInfo("restart: relaunching as %s", narrow(restartCommandLine()).c_str());
    STARTUPINFOW si{ sizeof si };
    PROCESS_INFORMATION pi{};
    if (CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
    DestroyWindow(g_hwnd);   // WM_DESTROY kills sessions + shuts down the pty-host
}

static void showMainWindow() {
    ShowWindow(g_hwnd, SW_SHOW);
    if (IsIconic(g_hwnd)) ShowWindow(g_hwnd, SW_RESTORE);
    SetForegroundWindow(g_hwnd);
}

static void showTrayMenu() {
    POINT pt; GetCursorPos(&pt);
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING, IDM_SHOW, L"&Show agliteterm");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, IDM_NEW, L"&New Session…");
    AppendMenuW(m, MF_STRING, IDM_RESTART, L"&Restart");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, IDM_EXIT, L"E&xit");
    SetForegroundWindow(g_hwnd);   // Win32 quirk: needed so the menu dismisses on click-away
    TrackPopupMenu(m, TPM_RIGHTBUTTON, pt.x, pt.y, 0, g_hwnd, nullptr);   // posts WM_COMMAND
    DestroyMenu(m);
}

// A 2000's-style app icon drawn at runtime (no .ico asset, no deps): a classic gray 3D-beveled tile
// with a sunken black "screen" and a green >_ prompt — the Win2000/XP-era terminal look.
// Toolbar icons are the full app's vector glyphs drawn in GDI at runtime (no PNG assets, no GDI+).
// Toolbar icons: exactly what the full app shows. Four of its buttons ARE Segoe Fluent Icons font
// glyphs (hamburger/add/terminal/gear) — we render the same codepoints with the icon font. The other
// four are its custom D2D vector glyphs (card+plus, split panes, scratch pad, recents clock) — we
// redraw those 4x supersampled with round-capped pens and HALFTONE-downscale, so the stroke weight
// (~1.5px) and smoothness match the font glyphs.
static const wchar_t kTbFontGlyph[kTbImgCount] = {
    0xE700,   // 0 sidebar  — GlobalNavButton (same as the full app)
    0xE710,   // 1 new sess — Add
    0,        // 2 new ws   — custom (card + plus)
    0,        // 3 split    — custom (two panes)
    0,        // 4 scratch  — custom (pad)
    0xE756,   // 5 quick    — CommandPrompt
    0,        // 6 reopen   — custom (recents clock)
    0xE713,   // 7 settings — Settings gear
    0,        // 8 flag     — custom (pennant, DrawFlagGlyph)
    0,        // 9 bell     — custom (DrawBellGlyph)
    0,        // 10 bell    — same shape, alert colour (any session blocked)
};
// Custom glyphs drawn on a 64x64 canvas (scaled 4x from the full app's 16px-cell geometry).
static void drawToolbarGlyph4x(HDC dc, int idx, COLORREF c) {
    LOGBRUSH lb{ BS_SOLID, c, 0 };
    HPEN pen = ExtCreatePen(PS_GEOMETRIC | PS_SOLID | PS_ENDCAP_ROUND | PS_JOIN_ROUND, 6, &lb, 0, nullptr);
    HGDIOBJ op = SelectObject(dc, pen), ob = SelectObject(dc, GetStockObject(NULL_BRUSH));
    auto ln = [&](int x0, int y0, int x1, int y1) { MoveToEx(dc, x0, y0, nullptr); LineTo(dc, x1, y1); };
    switch (idx) {
        case 2:   // new workspace: card upper-left + plus lower-right (DrawNewWorkspaceGlyph)
            RoundRect(dc, 8, 8, 46, 46, 14, 14);
            ln(50, 26, 50, 50); ln(38, 38, 62, 38);
            break;
        case 3:   // split: two panes, centre divider (DrawSplitGlyph)
            RoundRect(dc, 4, 12, 60, 52, 14, 14);
            ln(32, 12, 32, 51);
            break;
        case 4:   // scratch: rounded pad (DrawScratchGlyph)
            RoundRect(dc, 4, 12, 60, 52, 18, 18);
            break;
        case 6:   // reopen closed: recents clock (DrawClockGlyph)
            Ellipse(dc, 6, 6, 58, 58);
            ln(32, 32, 32, 15); ln(32, 32, 43, 39);
            break;
        case 8: { // flagged view: pennant (DrawFlagGlyph)
            ln(22, 8, 22, 56);
            POINT p[3] = { { 22, 10 }, { 50, 19 }, { 22, 28 } };
            Polygon(dc, p, 3);
            break;
        }
        case 9:
        case 10:  // attention bell (DrawBellGlyph); 10 = alert-coloured build of the same shape
            Arc(dc, 16, 10, 48, 42, 48, 26, 16, 26);   // dome
            ln(16, 26, 13, 42); ln(48, 26, 51, 42);    // walls
            ln(9, 42, 55, 42);                          // rim
            Ellipse(dc, 28, 46, 36, 53);                // clapper
            break;
    }
    SelectObject(dc, op); SelectObject(dc, ob);
    DeleteObject(pen);
}
static void buildToolbarImages() {
    // Rebuilt on every theme switch: icons are composed onto the bar colour in the theme's text
    // colour (no alpha image lists without a v6 manifest, and none needed).
    if (g_tbImages) ImageList_Destroy(g_tbImages);
    g_tbImages = ImageList_Create(16, 16, ILC_COLOR24, kTbImgCount, 0);
    COLORREF bg = g_th.classic ? GetSysColor(COLOR_BTNFACE) : g_th.bar;
    COLORREF fg = g_th.classic ? GetSysColor(COLOR_BTNTEXT) : g_th.text;
    // The icon font: Segoe Fluent Icons on Win11; Segoe MDL2 Assets carries the same codepoints on
    // Win10. ANTIALIASED (grayscale) rather than ClearType: no subpixel fringing on the bar colour.
    HFONT icoFont = CreateFontW(-15, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
                                OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                                DEFAULT_PITCH, L"Segoe Fluent Icons");
    HDC sdc = GetDC(nullptr);
    for (int i = 0; i < kTbImgCount; i++) {
        COLORREF gfg = (i == 10) ? RGB(230, 150, 50) : fg;   // the alert bell is amber in every theme
        HDC mem = CreateCompatibleDC(sdc);
        HBITMAP bm = CreateCompatibleBitmap(sdc, 16, 16);
        HGDIOBJ obm = SelectObject(mem, bm);
        RECT r{ 0, 0, 16, 16 };
        HBRUSH bb = CreateSolidBrush(bg);
        FillRect(mem, &r, bb);
        if (kTbFontGlyph[i]) {   // authentic Fluent glyph, centred
            HGDIOBJ of = SelectObject(mem, icoFont);
            wchar_t ch[2] = { kTbFontGlyph[i], 0 };
            // Fall back to MDL2 if Fluent isn't installed (pre-Win11): same codepoints there.
            wchar_t face[LF_FACESIZE] = L"";
            GetTextFaceW(mem, LF_FACESIZE, face);
            if (lstrcmpiW(face, L"Segoe Fluent Icons") != 0) {
                static HFONT mdl2 = CreateFontW(-15, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
                                                OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                                                DEFAULT_PITCH, L"Segoe MDL2 Assets");
                SelectObject(mem, mdl2);
            }
            SetBkMode(mem, TRANSPARENT);
            SetTextColor(mem, gfg);
            SIZE sz{};
            GetTextExtentPoint32W(mem, ch, 1, &sz);
            TextOutW(mem, (16 - sz.cx) / 2, (16 - sz.cy) / 2, ch, 1);
            SelectObject(mem, of);
        } else {                 // custom vector glyph: 4x supersample -> HALFTONE downscale
            HDC big = CreateCompatibleDC(sdc);
            HBITMAP bigBm = CreateCompatibleBitmap(sdc, 64, 64);
            HGDIOBJ obig = SelectObject(big, bigBm);
            RECT br{ 0, 0, 64, 64 };
            FillRect(big, &br, bb);
            drawToolbarGlyph4x(big, i, gfg);
            SetStretchBltMode(mem, HALFTONE);
            SetBrushOrgEx(mem, 0, 0, nullptr);
            StretchBlt(mem, 0, 0, 16, 16, big, 0, 0, 64, 64, SRCCOPY);
            SelectObject(big, obig); DeleteObject(bigBm); DeleteDC(big);
        }
        DeleteObject(bb);
        SelectObject(mem, obm); DeleteDC(mem);
        ImageList_Add(g_tbImages, bm, nullptr);
        DeleteObject(bm);
    }
    ReleaseDC(nullptr, sdc);
    DeleteObject(icoFont);
    if (g_toolbar) {
        SendMessageW(g_toolbar, TB_SETIMAGELIST, 0, (LPARAM)g_tbImages);
        InvalidateRect(g_toolbar, nullptr, TRUE);
    }
}
// App icon: the embedded VGA black+cyan .ico (resource id 1 in lite.rc). Big (taskbar/alt-tab)
// and small (title bar/tray) sizes are loaded separately so neither gets scaled.
static HICON loadAppIcon(bool small_) {
    int w = GetSystemMetrics(small_ ? SM_CXSMICON : SM_CXICON);
    int h = GetSystemMetrics(small_ ? SM_CYSMICON : SM_CYICON);
    return (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON, w, h, 0);
}

// ---- Quick / Scratch popup terminals ----
static void paintPopup(HWND h, Session* s) {
    PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
    RECT rc; GetClientRect(h, &rc);
    HDC mem = CreateCompatibleDC(dc);
    HBITMAP bmp = CreateCompatibleBitmap(dc, rc.right, rc.bottom);
    HGDIOBJ ob = SelectObject(mem, bmp);
    HBRUSH bg = CreateSolidBrush(g_customColors ? toColorRef(g_defBg, false) : RGB(0, 0, 0));
    FillRect(mem, &rc, bg); DeleteObject(bg);
    if (s) paintPane(mem, rc, s, -1, true);   // -1 pane = no selection span; cursor always shown
    BitBlt(dc, 0, 0, rc.right, rc.bottom, mem, 0, 0, SRCCOPY);
    SelectObject(mem, ob); DeleteObject(bmp); DeleteDC(mem);
    EndPaint(h, &ps);
}
static LRESULT CALLBACK popupProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    // A MATCH, not a fallthrough. CreateWindowExW dispatches WM_SIZE before it returns, so during a
    // quick popup's creation g_quickHwnd is still null — and the old `: g_overlaySession` default
    // then handed the QUICK window's grid to an open overlay's session, reflowing a running command
    // in a window that never changed size, permanently (revmux r2, pre-existing). A window this
    // proc does not yet know drives nothing.
    Session* s = (h == g_quickHwnd) ? g_quickSession
               : (h == g_scratchHwnd) ? g_scratchSession
               : (h == g_overlayHwnd) ? g_overlaySession : nullptr;
    switch (m) {
        case WM_SETFOCUS:  g_focusOverride = s; return 0;
        case WM_KILLFOCUS: if (g_focusOverride == s) g_focusOverride = nullptr; return 0;
        case WM_ERASEBKGND: return 1;
        case WM_PAINT: paintPopup(h, s); return 0;
        case WM_SIZE:
            if (s && w != SIZE_MINIMIZED) {
                RECT rc; GetClientRect(h, &rc);
                hostResize(s, max(1, (int)(rc.right / g_cw)), max(1, (int)(rc.bottom / g_ch)));
                InvalidateRect(h, nullptr, FALSE);
            }
            return 0;
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN:
            g_focusOverride = s;
            g_swallowChar = handleKeyDown(w);
            InvalidateRect(h, nullptr, FALSE);
            if (g_swallowChar) return 0;
            break;
        case WM_CHAR: {
            g_focusOverride = s;
            if (g_palette) { if (g_swallowChar) g_swallowChar = false; else palChar((wchar_t)w); return 0; }
            if (g_swallowChar) { g_swallowChar = false; return 0; }
            wchar_t wc = (wchar_t)w;
            if (s) s->scrollOff = 0;
            if (wc == L'\r') sendBytes("\r", 1); else sendUtf8(wc);
            return 0;
        }
        case WM_MOUSEWHEEL:
            if (s) { s->scrollOff = max(0, s->scrollOff + (GET_WHEEL_DELTA_WPARAM(w) > 0 ? 3 : -3)); InvalidateRect(h, nullptr, FALSE); }
            return 0;
        case WM_SYSCOMMAND:
            if ((w & 0xFFF0) == SC_MINIMIZE) { ShowWindow(g_hwnd, SW_MINIMIZE); return 0; }   // minimize -> all windows
            break;
        case WM_CLOSE:
            // Overlay and SCRATCH are transient: closing tears the window AND its session down (a
            // scratch pad you closed is gone — reopening starts fresh). Quick hides and keeps its
            // session, that being the point of a quick terminal.
            // No SetForegroundWindow(g_hwnd) here or in WM_DESTROY (#24): the popup is OWNED by the
            // main window, and Windows hands activation back to the owner by itself when an owned
            // window hides or dies. The explicit raise only mattered when the foreground was
            // elsewhere — and then it was a steal from whatever the user was doing.
            if (h == g_overlayHwnd || h == g_scratchHwnd) { DestroyWindow(h); return 0; }
            ShowWindow(h, SW_HIDE); return 0;
        case WM_DESTROY: {
            Session** slot = (h == g_overlayHwnd) ? &g_overlaySession
                           : (h == g_scratchHwnd) ? &g_scratchSession : nullptr;
            if (slot) {   // kill the transient window's session + clear its state
                if (g_focusOverride == *slot) g_focusOverride = nullptr;
                if (*slot)
                    for (int i = 0; i < (int)g_sessions.size(); i++)
                        if (g_sessions[i] == *slot) { closeSessionAt(i); break; }
                *slot = nullptr;
                if (h == g_overlayHwnd) g_overlayHwnd = nullptr; else g_scratchHwnd = nullptr;
            }
            return 0;
        }
    }
    return DefWindowProcW(h, m, w, l);
}
static void ensurePopupClass() {
    static bool reg = false;
    if (reg) return;
    WNDCLASSW wc{};
    wc.lpfnWndProc = popupProc; wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"AgwintermLitePopup";
    wc.hCursor = LoadCursorW(nullptr, (LPCWSTR)IDC_IBEAM); wc.hIcon = g_appIcon;
    RegisterClassW(&wc); reg = true;
}
static constexpr DWORD kPopupStyle = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN;
// The smallest popup that can host a prompt, in OUTER pixels: 30x8 cells of the live font plus the
// frame. A physical minimum, applied HERE to every popup. It is never applied silently: the verb
// raises the percentage it reports to overlayMinPercentRaw() first, so the reply names the size the
// popup will actually have. Refusing under the floor was tried and reverted — it made lite answer
// ok:false to the shared contract's `--size-percent 40` step, which agwinterm's frameless cover
// (no floor) answers ok. Any new entry point that creates a popup owes the same raise.
static void popupFloorPx(int& W, int& H) {
    RECT r{ 0, 0, 30 * g_cw, 8 * g_ch };
    AdjustWindowRectEx(&r, kPopupStyle, FALSE, 0);
    W = r.right - r.left; H = r.bottom - r.top;
}
// A popup terminal window of W x H OUTER pixels, owned by the main window (floats above, hides when
// it minimizes, never behind it). CENTRED over the main window and then kept inside the monitor's
// work area: at --size-percent 100 the popup is as wide as the main window's client plus its frame,
// so the old fixed +80/+60 offset put its right and bottom edges off the screen entirely.
static HWND createPopupWindowPx(const wchar_t* title, int W, int H) {
    ensurePopupClass();
    RECT mw; GetWindowRect(g_hwnd, &mw);
    int fw, fh; popupFloorPx(fw, fh);
    W = max(fw, W); H = max(fh, H);
    int x = mw.left + ((mw.right - mw.left) - W) / 2, y = mw.top + ((mw.bottom - mw.top) - H) / 2;
    MONITORINFO mi{ sizeof(mi) };
    if (GetMonitorInfoW(MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST), &mi)) {
        x = max((int)mi.rcWork.left, min(x, (int)mi.rcWork.right - W));
        y = max((int)mi.rcWork.top, min(y, (int)mi.rcWork.bottom - H));
    }
    HWND h = CreateWindowExW(0, L"AgwintermLitePopup", title, kPopupStyle,
                             x, y, W, H, g_hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
    darkTitleBar(h, g_th.dark);   // popup terminals follow the theme's title bar
    return h;
}
// A popup terminal window sized wf x hf fractions of the main WINDOW rect (quick / scratch).
static HWND createPopupWindow(const wchar_t* title, double wf, double hf) {
    RECT mw; GetWindowRect(g_hwnd, &mw);
    return createPopupWindowPx(title, (int)((mw.right - mw.left) * wf), (int)((mw.bottom - mw.top) * hf));
}
// The overlay's OUTER size for a fraction f of the main window's CLIENT area: the contract says
// "--size-percent N is that fraction of the content area", so the popup's client rect is what
// carries N, and the frame is added on top of it (the check in test/control-honesty.ps1 measures
// the popup's client rect against the main window's).
static void overlayOuterSize(double f, int& W, int& H) {
    RECT mc; GetClientRect(g_hwnd, &mc);
    RECT r{ 0, 0, (LONG)(mc.right * f), (LONG)(mc.bottom * f) };
    AdjustWindowRectEx(&r, kPopupStyle, FALSE, 0);
    W = r.right - r.left; H = r.bottom - r.top;
}
// The smallest --size-percent this window can show, as a raw percentage that may exceed 100 (a
// client under 30x8 cells cannot show the minimum popup at any percentage) and is 0 when the
// question cannot be answered at all — the window is minimised, or there are no font metrics yet.
// Below it the 30x8-cell popup minimum decides the size instead. lite REPORTS the percentage
// actually in effect rather than echoing the number asked for (revmux r1 found it echoing) and
// rather than refusing — the shared contract runs `session overlay open --size-percent 40` and
// expects ok, and on a small window 40 % of the client is under the minimum, so a refusal would
// diverge from agwinterm, whose overlay is a cover inside the content region with no window frame
// and no such floor.
static int overlayMinPercentRaw() {
    if (IsIconic(g_hwnd) || g_cw <= 0 || g_ch <= 0) return 0;
    RECT mc; GetClientRect(g_hwnd, &mc);
    if (mc.right <= 0 || mc.bottom <= 0) return 0;
    int pw = (30 * g_cw * 100 + (int)mc.right - 1) / (int)mc.right;     // ceil, in percent
    int ph = (8 * g_ch * 100 + (int)mc.bottom - 1) / (int)mc.bottom;
    return pw > ph ? pw : ph;
}
// How the reply names the size, given what was asked for. The caller compares this with what it
// asked for, as `sidebar width` already makes it — so it must never be a number the popup will not
// have (revmux r2: a minimised window answered "at 40%" for a popup at the 30x8-cell floor, and an
// absent flag answered "at 70%" for the same). The two states that cannot carry a percentage say so
// instead, the way `sidebar width` answers applied:false with a note.
static bool overlaySizeIsPercent(int rawMin) { return rawMin > 0 && rawMin <= 100; }
static std::string overlaySizeReason(int rawMin) {
    return rawMin == 0 ? "the smallest size this window can show (it is minimised, so the percentage could not be applied)"
                       : "the smallest size this window can show (its client is under 30x8 cells, so no percentage fits)";
}
// Whether the foreground window belongs to THIS process — the user is in this window or one of its
// popups, rather than working in another application.
static bool foregroundIsOurs() {
    HWND fg = GetForegroundWindow();
    DWORD fgPid = 0;
    if (fg) GetWindowThreadProcessId(fg, &fgPid);
    return fg && fgPid == GetCurrentProcessId();
}
// #24: bring `h` to the front only when this process ALREADY holds the foreground, so the raise is
// a hand-off between our own windows. When the foreground belongs to another process, the user is
// working somewhere else: never take it (a `quick on` or `session overlay open` from an agent loop
// used to pop the window over whatever they were typing into, every time — the report). Flash the
// taskbar button instead, the HA_BELL pattern, unless the caller says the moment is not worth a
// flash (dismissing a popup). Windows itself refuses a background SetForegroundWindow while the
// user is actively typing, but grants it once the input has gone quiet for the foreground-lock
// timeout — which is exactly when an agent loop runs.
// Returns whether the raise was made (not whether Windows honoured it; window.select checks that).
static bool raiseIfAllowed(HWND h, bool flashOtherwise = true) {
    if (foregroundIsOurs()) { SetForegroundWindow(h); return true; }
    if (flashOtherwise) FlashWindow(g_hwnd, TRUE);
    return false;
}
// Show a popup and raise it under the same rule. SW_SHOW ACTIVATES the window it shows, and
// activation is a second road to the foreground that Windows grants a background process under
// the same idle-timeout rule — so when the foreground is not ours the popup is shown WITHOUT
// activation (SW_SHOWNA; it still sits above its owner, being owned) and the button flashes.
// Returns whether the popup was ACTIVATED. That answer is load-bearing: g_focusOverride routes the
// MAIN window's keystrokes into the popup's session, and it is cleared only by the popup's own
// WM_KILLFOCUS — which never fires for a window that never had focus. Set unconditionally, a
// background `quick on` left every keystroke the user then typed into the main window going to the
// hidden quick session, silently (revmux r1 of P2-lite). Only an activated popup claims input.
static bool showPopupRaised(HWND h) {
    if (foregroundIsOurs()) { ShowWindow(h, SW_SHOW); SetForegroundWindow(h); return true; }
    ShowWindow(h, SW_SHOWNA);
    FlashWindow(g_hwnd, TRUE);
    return false;
}
// Toggle a quick (scratch=false) or scratch (scratch=true) popup terminal: show/hide, creating its
// window + dedicated hidden session on first use.
static void togglePopupTerminal(bool scratch) {
    HWND& hw = scratch ? g_scratchHwnd : g_quickHwnd;
    Session*& sess = scratch ? g_scratchSession : g_quickSession;
    if (hw && IsWindowVisible(hw)) {
        // Dismissing: quick hides (its session is the point), scratch is torn down — a dismissed
        // scratch pad is gone, however you dismissed it (toggle key, X button, anything). The
        // owner gets activation back from Windows; the raise is only for when the popup WAS the
        // foreground and the main window should follow it, and a dismiss is not worth a flash.
        if (scratch) DestroyWindow(hw);
        else ShowWindow(hw, SW_HIDE);
        // A hide generates no WM_KILLFOCUS when the popup never had focus (it was shown
        // unactivated), so the override is dropped here rather than left pointing at a window the
        // user cannot see. Only ours to drop: another popup may own input.
        if (g_focusOverride == sess) g_focusOverride = nullptr;
        raiseIfAllowed(g_hwnd, false);
        return;
    }
    if (!hw) {
        hw = createPopupWindow(scratch ? L"agliteterm — scratch" : L"agliteterm — quick", 0.66, 0.6);
        RECT rc; GetClientRect(hw, &rc);
        sess = newSession(max(1, (int)(rc.right / g_cw)), max(1, (int)(rc.bottom / g_ch)));   // windowForSession routes to hw (set above)
        if (sess) { sess->hidden = true; sess->name = scratch ? L"scratch" : L"quick"; }      // not in the sidebar / not persisted
    }
    // Only when it was actually activated: an unactivated popup gets the override from its own
    // WM_SETFOCUS if the user clicks into it.
    if (showPopupRaised(hw)) g_focusOverride = sess;
    InvalidateRect(hw, nullptr, FALSE);
}
// Overlay: run a command in a popup over the active session (control-API session.overlay). One at a
// time; opening a new overlay replaces the previous.
//
// sizePct is the 1..100 the verb POSTED, and the popup is built from it. When
// overlayMinPercentRaw() could answer, that is also the percentage the caller was told: the verb
// raised the request — or lite's 70 % default, when the flag was absent — to the 30x8-cell minimum
// and posted THAT. When it could not answer (the window is minimised, or its client is under 30x8
// cells) there is no percentage to name, the reply says what it got and why, and the number arriving
// here is just the request or the default, with createPopupWindowPx's physical floor applied to the
// pixels below. Nothing clamps the PERCENTAGE here — 100 means the whole client area.
// overlayFraction still has a 0 arm; nothing on this path reaches it any more (revmux r4/r5), and it
// is kept only so a future caller cannot trip on it. lite's 70 %
// default is its own and differs from agwinterm's (a cover over the full content region): the
// shared contract pins the reply shape and the refusals, not the default geometry, and the skill
// says which default each product has. An empty command is refused by the verb, and the verb is
// the only caller (WM_APP_OVERLAY is posted from nowhere else), so there is no empty arm here.
//
// The command runs the way `session new --command` runs one — PowerShell -NoExit -Command <it> —
// so a command WITH arguments ("git log --oneline", "cmd /k") runs and its popup stays up after
// it. Handed to the pty-host as the app it was taken as an executable path: "cmd /k" spawned
// nothing, newSession answered nullptr, and the popup opened EMPTY while the verb had already
// answered "overlay opened" (found by qa/control-honesty.md's first case, P2-lite task 8). If the
// create still fails there is no popup to leave behind either: the window goes, and the log says.
static const double kOverlayDefaultFraction = 0.7;
static double overlayFraction(int sizePct) { return sizePct > 0 ? sizePct / 100.0 : kOverlayDefaultFraction; }
static void openOverlay(const std::string& command, int sizePct) {
    if (g_overlayHwnd) DestroyWindow(g_overlayHwnd);   // one at a time; WM_DESTROY kills the old session + clears state
    int W, H; overlayOuterSize(overlayFraction(sizePct), W, H);
    g_overlayHwnd = createPopupWindowPx(L"agliteterm — overlay", W, H);
    RECT rc; GetClientRect(g_overlayHwnd, &rc);
    int cols = max(1, (int)(rc.right / g_cw)), rows = max(1, (int)(rc.bottom / g_ch));
    std::vector<std::string> cargs{ "-NoExit", "-Command", command };
    g_overlaySession = newSession(cols, rows, "powershell.exe", &cargs);
    if (!g_overlaySession) {
        logWarn("overlay: the session for '%s' could not be created; the popup was not shown", command.c_str());
        DestroyWindow(g_overlayHwnd);   // WM_DESTROY clears g_overlayHwnd; a later `resize` is refused truthfully
        return;
    }
    g_overlaySession->hidden = true; g_overlaySession->name = L"overlay";
    if (showPopupRaised(g_overlayHwnd)) g_focusOverride = g_overlaySession;   // see showPopupRaised
    InvalidateRect(g_overlayHwnd, nullptr, FALSE);
}
// `session overlay resize`: the popup that is open takes the new fraction; WM_SIZE in popupProc
// re-grids its session. UI thread only (SetWindowPos on a window this thread owns) — the verb posts
// here. The pipe thread checked g_overlayHwnd before posting, but the user can close the popup by
// hand between the check and this running, so "nothing open" is a silent no-op here and not a bug.
static void resizeOverlay(int sizePct) {
    if (!g_overlayHwnd) return;
    int W, H; overlayOuterSize(overlayFraction(sizePct), W, H);
    int fw, fh; popupFloorPx(fw, fh);
    W = max(fw, W); H = max(fh, H);
    // Re-centred, not SWP_NOMOVE: pinning the top-left grew the popup down and to the right, so a
    // resize to 100 pushed it off the screen and off the "centred over the main window" the QA case
    // describes. Kept inside the work area, as createPopupWindowPx does.
    RECT mw; GetWindowRect(g_hwnd, &mw);
    int x = mw.left + ((mw.right - mw.left) - W) / 2, y = mw.top + ((mw.bottom - mw.top) - H) / 2;
    MONITORINFO mi{ sizeof(mi) };
    if (GetMonitorInfoW(MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST), &mi)) {
        x = max((int)mi.rcWork.left, min(x, (int)mi.rcWork.right - W));
        y = max((int)mi.rcWork.top, min(y, (int)mi.rcWork.bottom - H));
    }
    SetWindowPos(g_overlayHwnd, nullptr, x, y, W, H, SWP_NOZORDER | SWP_NOACTIVATE);
}

// ---- sidebar drag & drop ----------------------------------------------------------------------
// Reorder g_sessions: take `from` out, put it into `targetWs`, inserted before `insertBefore`
// (session index in the PRE-move vector; -1 = append at the end). Panes hold indices, so they are
// remapped through the same removal+insertion the vector undergoes.
static void moveSessionTo(int from, int targetWs, int insertBefore) {
    int n = (int)g_sessions.size();
    if (from < 0 || from >= n || targetWs < 0 || targetWs >= (int)g_workspaces.size()) return;
    if (insertBefore == from) insertBefore = -1;   // dropping on yourself = just a workspace move
    EnterCriticalSection(&g_lock);
    Session* moved = g_sessions[from];
    g_sessions.erase(g_sessions.begin() + from);
    int ins = insertBefore < 0 ? (int)g_sessions.size()
            : (insertBefore > from ? insertBefore - 1 : insertBefore);   // index after the removal
    g_sessions.insert(g_sessions.begin() + ins, moved);
    moved->ws = targetWs;
    auto remap = [&](int idx) {
        if (idx < 0) return idx;
        if (idx == from) return ins;
        int t = idx > from ? idx - 1 : idx;   // removal shift
        return t >= ins ? t + 1 : t;          // insertion shift
    };
    g_pane[0] = remap(g_pane[0]);
    g_pane[1] = remap(g_pane[1]);
    LeaveCriticalSection(&g_lock);
    refreshTree();   // rebuild labels/lParams + persist the new order
    InvalidateRect(g_hwnd, nullptr, FALSE);
}
static void endTreeDrag(bool drop, POINT treePt) {   // treePt in TREE-client coords
    if (!g_treeDrag) return;
    g_treeDrag = false;   // FIRST: ReleaseCapture re-enters via WM_CAPTURECHANGED
    ImageList_DragLeave(g_tree);
    ImageList_EndDrag();
    if (g_dragImg) { ImageList_Destroy(g_dragImg); g_dragImg = nullptr; }
    ReleaseCapture();
    TreeView_SelectDropTarget(g_tree, nullptr);
    int from = g_dragIdx; g_dragIdx = -1;
    if (!drop || from < 0) return;
    TVHITTESTINFO ht{};
    ht.pt = treePt;
    HTREEITEM it = TreeView_HitTest(g_tree, &ht);
    if (!it) return;
    TVITEMW ti{}; ti.mask = TVIF_PARAM; ti.hItem = it;
    TreeView_GetItem(g_tree, &ti);
    if (ti.lParam >= 0 && ti.lParam < (LPARAM)g_sessions.size()) {          // onto a session: insert before it
        int tj = (int)ti.lParam;
        if (tj != from) moveSessionTo(from, g_sessions[tj]->ws, tj);
    } else {                                                                 // onto a workspace: append there
        int w = (int)(-ti.lParam - 1);
        if (w >= 0 && w < (int)g_workspaces.size()) moveSessionTo(from, w, -1);
    }
}
// Drag & drop lives in a tree subclass: comctl32's own TVN_BEGINDRAG detection proved unreliable
// with TVS_EDITLABELS in play, so the press/threshold/move/drop loop is ours — the same
// deterministic approach as the rest of this port. All coordinates are tree-client.
// The sidebar font: the shell UI FACE at a chosen point size, never a stock object. The tree was
// on DEFAULT_GUI_FONT, which is a bitmap face that ignores the user's shell font entirely and looks
// nothing like the rest of the window. Size 0 keeps whatever the shell says, so the default still
// tracks a system that has been set to large text.
static void applyTreeFont() {
    NONCLIENTMETRICSW ncm{ sizeof(ncm) };
    if (!SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0)) return;
    LOGFONTW lf = ncm.lfMessageFont;
    if (g_treeFontPt > 0) {
        HDC dc = GetDC(nullptr);
        lf.lfHeight = -MulDiv(g_treeFontPt, GetDeviceCaps(dc, LOGPIXELSY), 72);
        ReleaseDC(nullptr, dc);
    }
    // OUT_TT_PRECIS + CLEARTYPE: a TrueType face, antialiased — the point of not using the stock font.
    lf.lfOutPrecision = OUT_TT_PRECIS;
    lf.lfQuality = CLEARTYPE_QUALITY;
    HFONT old = g_treeFont, oldItalic = g_treeItalic;
    g_treeFont = CreateFontIndirectW(&lf);
    // The "working" rows are the SAME face, italic. Built here rather than once at startup: it used
    // to come from DEFAULT_GUI_FONT and never move, so changing the sidebar size left every agent
    // that was busy rendered in the old font at the old size, next to rows that had resized.
    LOGFONTW it = lf;
    it.lfItalic = TRUE;
    g_treeItalic = CreateFontIndirectW(&it);
    if (g_tree && g_treeFont) {
        SendMessageW(g_tree, WM_SETFONT, (WPARAM)g_treeFont, TRUE);
        // The row height follows the font, and the tree only recomputes it on a real relayout.
        TreeView_SetItemHeight(g_tree, -1);
        InvalidateRect(g_tree, nullptr, TRUE);
    }
    if (old) DeleteObject(old);   // after the swap: deleting a font still selected paints nothing
    if (oldItalic) DeleteObject(oldItalic);
}

static LRESULT CALLBACK treeProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR) {
    if (m == WM_NCDESTROY) RemoveWindowSubclass(h, treeProc, id);
    switch (m) {
        case WM_SETFOCUS:
            // The sidebar never keeps the keyboard. It is a real SysTreeView32 child (the main app
            // draws its sidebar, so the question never arises there), which means clicking a row —
            // or just Alt-Tabbing back, since Windows restores focus to the child that had it —
            // left the tree focused and the next keystroke went to the sidebar instead of the
            // shell. Renaming is the one case that legitimately wants the keyboard here.
            if (!g_treeRenaming && !TreeView_GetEditControl(h)) {
                logInfo("focus: sidebar took focus -> bouncing back to the terminal");
                ::PostMessageW(g_hwnd, WM_APP_FOCUSTERM, 0, 0);
            } else {
                logInfo("focus: sidebar keeps focus (inline rename in progress)");
            }
            break;
        case WM_CHAR:
            // A TreeView's type-ahead SELECTS A ROW, and in this sidebar selecting a row switches
            // session. So a stray keystroke while the sidebar happens to hold focus does not merely
            // go to the wrong place — it moves the user to a terminal they were not looking at, and
            // the rest of what they type lands there. The WM_SETFOCUS bounce above cannot catch this
            // on its own: it only fires when the tree RECEIVES focus, never when it already has it.
            //
            // So printable input is handed to the shell instead, which is what the person typing
            // meant. Renaming is the one case that legitimately wants these keys.
            if (!g_treeRenaming && !TreeView_GetEditControl(h)) {
                ::PostMessageW(g_hwnd, WM_APP_FOCUSTERM, 0, 0);
                ::PostMessageW(g_hwnd, WM_CHAR, w, l);
                return 0;                       // swallowed: no type-ahead, no session switch
            }
            break;
        case WM_LBUTTONDOWN: {
            g_armIdx = -1;
            TVHITTESTINFO ht{};
            ht.pt = { GET_X_LPARAM(l), GET_Y_LPARAM(l) };
            HTREEITEM it = TreeView_HitTest(h, &ht);
            if (it && (ht.flags & (TVHT_ONITEM | TVHT_ONITEMRIGHT | TVHT_ONITEMINDENT))) {
                TVITEMW ti{}; ti.mask = TVIF_PARAM; ti.hItem = it;
                TreeView_GetItem(h, &ti);
                if (ti.lParam >= 0 && ti.lParam < (LPARAM)g_sessions.size()) {
                    g_armIdx = (int)ti.lParam; g_armPt = ht.pt; g_armItem = it;   // drag candidate
                }
            }
            break;   // default handling still selects the row
        }
        case WM_MOUSEMOVE: {
            POINT pt{ GET_X_LPARAM(l), GET_Y_LPARAM(l) };
            if (g_treeDrag) {   // live drag: move the ghost + highlight the drop target
                ImageList_DragShowNolock(FALSE);
                TVHITTESTINFO ht{}; ht.pt = pt;
                TreeView_SelectDropTarget(h, TreeView_HitTest(h, &ht));
                ImageList_DragShowNolock(TRUE);
                ImageList_DragMove(pt.x, pt.y);
                return 0;
            }
            if (g_armIdx >= 0 && (w & MK_LBUTTON) &&
                (abs(pt.x - g_armPt.x) > 4 || abs(pt.y - g_armPt.y) > 4)) {   // passed the drag threshold
                g_dragIdx = g_armIdx; g_armIdx = -1;
                g_dragImg = TreeView_CreateDragImage(h, g_armItem);
                if (g_dragImg) { ImageList_BeginDrag(g_dragImg, 0, 8, 8); ImageList_DragEnter(h, pt.x, pt.y); }
                g_treeDrag = true;
                SetCapture(h);
                return 0;
            }
            break;
        }
        case WM_LBUTTONUP:
            if (g_treeDrag) { endTreeDrag(true, { GET_X_LPARAM(l), GET_Y_LPARAM(l) }); return 0; }
            g_armIdx = -1;
            break;
        case WM_CAPTURECHANGED:
            if (g_treeDrag) endTreeDrag(false, { 0, 0 });   // something stole the mouse: cancel cleanly
            break;
        case WM_KEYDOWN:
            if (g_treeDrag && w == VK_ESCAPE) { endTreeDrag(false, { 0, 0 }); return 0; }
            break;
    }
    return DefSubclassProc(h, m, w, l);
}

// ---- flagged sessions + attention -------------------------------------------------------------
static bool anyBlocked() {
    for (auto* s : g_sessions)
        if (!s->hidden && !s->exited && statusClass(statusOf(s).status) == AGST_BLOCKED) return true;
    return false;
}
// Jump to the next blocked session (cycling from the current one). The agent-terminal loop: the
// bell lights, you click it, you're on the session that needs you.
static void nextBlocked() {
    int n = (int)g_sessions.size();
    if (n == 0) return;
    int start = g_pane[0] >= 0 ? g_pane[0] : 0;
    for (int k = 1; k <= n; k++) {
        int i = (start + k) % n;
        Session* s = g_sessions[i];
        if (s->hidden || s->exited || statusClass(statusOf(s).status) != AGST_BLOCKED) continue;
        selectPrimary(i);
        g_activeWs = s->ws;
        if (g_focusWs >= 0) g_focusWs = s->ws;   // focus follows the jump (the row must be visible)
        syncPaneSizes();
        refreshTree();   // re-selects the tree row for the new pane-0 session
        InvalidateRect(g_hwnd, nullptr, FALSE);
        SetFocus(g_hwnd);
        return;
    }
    MessageBeep(MB_OK);   // nothing blocked right now
}
static void toggleFlag(Session* s) {
    if (!s || s->hidden) return;   // popup/split shells aren't tree sessions
    s->flagged = !s->flagged;
    refreshTree();                 // repaints the pennant + persists via saveSessionState
}
static void toggleFlagView() {
    g_flagView = !g_flagView;
    if (g_hwnd) CheckMenuItem(GetMenu(g_hwnd), IDM_FLAGVIEW, MF_BYCOMMAND | (g_flagView ? MF_CHECKED : MF_UNCHECKED));
    if (g_toolbar) SendMessageW(g_toolbar, TB_CHECKBUTTON, IDM_FLAGVIEW, MAKELPARAM(g_flagView, 0));
    refreshTree();
    saveColors();   // FlagView persists with the other view toggles
}
// Focus a workspace: the sidebar narrows to it (the full app's focus pill, lite-style — the toggle
// lives on the workspace's context menu and in View). Focusing again, or focusing -1, unfocuses.
static void toggleFocusWs(int w) {
    g_focusWs = (g_focusWs == w || w < 0 || w >= (int)g_workspaces.size()) ? -1 : w;
    if (g_focusWs >= 0) g_activeWs = g_focusWs;   // new sessions land in the focused workspace
    if (g_hwnd) CheckMenuItem(GetMenu(g_hwnd), IDM_FOCUSWS, MF_BYCOMMAND | (g_focusWs >= 0 ? MF_CHECKED : MF_UNCHECKED));
    refreshTree();   // re-filters + updates the status bar + persists (O record)
}

// ---- main frame (WTL) -------------------------------------------------------------------------
// CFrameWindowImpl gives the frame window traits, class registration and the message-map plumbing;
// the sidebar tree / toolbar / status bar are WTL control wrappers over the same native controls.
// Message crackers (MSG_WM_*) replace the old hand-rolled switch — the semantics are unchanged.
class CMainFrame : public CFrameWindowImpl<CMainFrame> {
public:
    DECLARE_FRAME_WND_CLASS_EX(L"AgwintermLite", 0, CS_DBLCLKS, COLOR_WINDOW)

    CTreeViewCtrl  m_tree;      // sidebar (sessions grouped by workspace)
    CToolBarCtrl   m_toolbar;   // New Session / New Workspace / Split
    CStatusBarCtrl m_status;    // workspace · count · grid · font

    BEGIN_MSG_MAP(CMainFrame)
        MSG_WM_PAINT(OnPaint)
        MSG_WM_ERASEBKGND(OnEraseBkgnd)
        MSG_WM_CHAR(OnChar)
        MSG_WM_MOUSEWHEEL(OnMouseWheel)
        MSG_WM_LBUTTONDOWN(OnLButtonDown)
        MSG_WM_MOUSEMOVE(OnMouseMove)
        MSG_WM_LBUTTONUP(OnLButtonUp)
        MSG_WM_RBUTTONDOWN(OnRButtonDown)
        MSG_WM_RBUTTONUP(OnRButtonUp)
        MSG_WM_SIZE(OnSize)
        MSG_WM_EXITSIZEMOVE(OnExitSizeMove)
        MSG_WM_SETTINGCHANGE(OnSettingChange)
        MSG_WM_ACTIVATE(OnActivateFrame)
        MSG_WM_TIMER(OnTimer)
        MSG_WM_SETFOCUS(OnSetFocusFrame)
        MSG_WM_KILLFOCUS(OnKillFocusFrame)
        MSG_WM_DESTROY(OnDestroy)
        MESSAGE_HANDLER(WM_KEYDOWN, OnKey)
        MESSAGE_HANDLER(WM_SYSKEYDOWN, OnKey)
        MESSAGE_HANDLER(WM_SETCURSOR, OnSetCursor)
        MESSAGE_HANDLER(WM_APP_REFRESHTREE, OnRefreshTree)
        MESSAGE_HANDLER(WM_APP_TRAY, OnTray)
        MESSAGE_HANDLER(WM_APP_OVERLAY, OnOverlay)
        MESSAGE_HANDLER(WM_APP_UPDATE, OnAppUpdate)
        MESSAGE_HANDLER(WM_APP_FOCUSTERM, OnFocusTerm)
        MESSAGE_HANDLER(WM_APP_HOSTACT, OnHostAction)
        MESSAGE_HANDLER(WM_APP_SIDEBARW, OnSidebarWidth)
        MESSAGE_HANDLER(WM_NOTIFY, OnNotify)
        MESSAGE_HANDLER(WM_COMMAND, OnCommand)
        MESSAGE_HANDLER(WM_UAHDRAWMENU, OnUahDrawMenu)
        MESSAGE_HANDLER(WM_UAHDRAWMENUITEM, OnUahDrawMenuItem)
        MESSAGE_HANDLER(WM_NCPAINT, OnNcPaintSeam)
        MESSAGE_HANDLER(WM_NCACTIVATE, OnNcPaintSeam)
        MESSAGE_HANDLER(WM_EXITMENULOOP, OnMenuSeamTouch)
        MESSAGE_HANDLER(WM_MENUSELECT, OnMenuSeamTouch)
        CHAIN_MSG_MAP(CFrameWindowImpl<CMainFrame>)
    END_MSG_MAP()

    // ---- dark menu bar ----
    LRESULT OnUahDrawMenu(UINT, WPARAM, LPARAM lp, BOOL& bHandled) {
        if (!g_th.dark) { bHandled = FALSE; return 0; }
        auto* um = (UAHMENU*)lp;
        MENUBARINFO mbi{ sizeof mbi };
        if (!GetMenuBarInfo(m_hWnd, OBJID_MENU, 0, &mbi)) { bHandled = FALSE; return 0; }
        RECT wr; GetWindowRect(&wr);
        RECT r = mbi.rcBar; OffsetRect(&r, -wr.left, -wr.top);
        HBRUSH b = CreateSolidBrush(g_th.bar);
        FillRect(um->hdc, &r, b);
        DeleteObject(b);
        return TRUE;
    }
    LRESULT OnUahDrawMenuItem(UINT, WPARAM, LPARAM lp, BOOL& bHandled) {
        if (!g_th.dark) { bHandled = FALSE; return 0; }
        auto* dmi = (UAHDRAWMENUITEM*)lp;
        wchar_t txt[256]{};
        MENUITEMINFOW mii{ sizeof mii, MIIM_STRING };
        mii.dwTypeData = txt; mii.cch = 255;
        GetMenuItemInfoW(dmi->um.hmenu, dmi->umi.iPosition, TRUE, &mii);
        DWORD st = dmi->dis.itemState;
        bool hot = (st & (ODS_HOTLIGHT | ODS_SELECTED)) != 0;
        HBRUSH b = CreateSolidBrush(hot ? g_th.hot : g_th.bar);
        FillRect(dmi->um.hdc, &dmi->dis.rcItem, b);
        DeleteObject(b);
        SetBkMode(dmi->um.hdc, TRANSPARENT);
        SetTextColor(dmi->um.hdc, (st & (ODS_GRAYED | ODS_DISABLED)) ? g_th.dim : g_th.text);
        HFONT of = g_uiFont ? (HFONT)SelectObject(dmi->um.hdc, g_uiFont) : nullptr;
        DrawTextW(dmi->um.hdc, txt, -1, &dmi->dis.rcItem,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE | ((st & ODS_NOACCEL) ? DT_HIDEPREFIX : 0));
        if (of) SelectObject(dmi->um.hdc, of);
        return TRUE;
    }
    LRESULT OnNcPaintSeam(UINT msg, WPARAM wp, LPARAM lp, BOOL&) {
        LRESULT r = DefWindowProc(msg, wp, lp);
        if (g_th.dark) themeMenuSeam(m_hWnd);
        return r;
    }
    LRESULT OnMenuSeamTouch(UINT msg, WPARAM wp, LPARAM lp, BOOL&) {
        LRESULT r = DefWindowProc(msg, wp, lp);
        if (g_th.dark) themeMenuSeam(m_hWnd);
        return r;
    }

    // ---- painting ----
    void OnPaint(CDCHandle) {
        CPaintDC dc(m_hWnd);
        RECT rc; GetClientRect(&rc);
        paint(dc.m_hDC, rc);
    }
    BOOL OnEraseBkgnd(CDCHandle) { return TRUE; }   // everything is double-buffered in paint()

    // ---- keyboard ----
    void OnChar(TCHAR chr, UINT, UINT) {
        if (g_palette) { if (g_swallowChar) g_swallowChar = false; else palChar((wchar_t)chr); return; }
        if (g_swallowChar) { g_swallowChar = false; return; }   // belongs to a keydown a binding consumed
        if (Session* s = focusedSession()) s->scrollOff = 0;
        if (chr == L'\r') { sendBytes("\r", 1); return; }
        sendUtf8((wchar_t)chr);
    }
    LRESULT OnKey(UINT, WPARAM wp, LPARAM, BOOL& bHandled) {
        if (g_treeDrag && wp == VK_ESCAPE) { endTreeDrag(false, { 0, 0 }); return 0; }   // cancel the drag
        // Reset per keydown; if a binding handled it, swallow the WM_CHAR TranslateMessage emits.
        g_swallowChar = handleKeyDown(wp);
        if (g_swallowChar) return 0;
        bHandled = FALSE;   // unhandled: let DefWindowProc do its thing (menu keys etc.)
        return 0;
    }

    // ---- mouse ----
    BOOL OnMouseWheel(UINT nFlags, short zDelta, CPoint pt) {
        if (g_palette) {   // scroll the palette list
            int n = (int)g_palHits.size(), rows = min(n, kPalMaxRows);
            if (n > rows) {
                g_palTop = max(0, min(n - rows, g_palTop + (zDelta > 0 ? -3 : 3)));
                g_paletteSel = max(g_palTop, min(g_palTop + rows - 1, g_paletteSel));
                Invalidate(FALSE);
            }
            return TRUE;
        }
        ScreenToClient(&pt);                                                        // wheel coords are screen-relative
        bool up = zDelta > 0;
        if (mouseReport(pt.x, pt.y, up ? 64 : 65, true, false)) return TRUE;        // to the app if it reports mouse
        scrollFocused(up ? 3 : -3);
        return TRUE;
    }
    void OnLButtonDown(UINT, CPoint pt) {
        if (inSplitter(pt.x, pt.y)) { g_splitDrag = true; SetCapture(); return; }   // grab the sidebar splitter
        if (g_palette) {   // click an item to run it; click anywhere else to dismiss
            if (PtInRect(&g_palList, POINT{ pt.x, pt.y })) {
                int i = g_palTop + (pt.y - g_palList.top) / (g_ch + 8);
                if (i >= 0 && i < (int)g_palHits.size()) { palExec(g_palHits[i]); return; }
            }
            if (!PtInRect(&g_palBox, POINT{ pt.x, pt.y })) { g_palette = false; Invalidate(FALSE); SetFocus(); }
            return;
        }
        // The sidebar is the native tree child, so clicks here are always in the terminal area.
        int pane, absRow, col;
        // One hold for the hit-test, the alt-screen flag and the eviction count: absRow is derived
        // from historyCount, and if the reader evicts between reading the row and reading the count
        // the two describe different buffers — permanently, since nothing later can detect it.
        LockG lk;
        if (hitTest(pt.x, pt.y, &pane, &absRow, &col)) {
            g_focus = pane;
            if (mouseReport(pt.x, pt.y, 0, true, false)) { SetFocus(); Invalidate(FALSE); return; }
            int si = g_pane[pane];                              // begin drag-select, bound to THIS session
            Session* ss = (si >= 0 && si < (int)g_sessions.size()) ? g_sessions[si] : nullptr;
            FfiEmuInfo ai{};
            bool alt = false;
            if (ss && ss->emu && emu_info(ss->emu, &ai)) alt = ai.isAltScreen != 0;
            g_sel = { pane, (void*)ss, true, absRow, col, absRow, col,
                      ss ? ss->evicted : 0,                     // rows are relative to THIS eviction count
                      alt };                                    // ...and to THIS buffer
            SetCapture();
            Invalidate(FALSE);
        }
        SetFocus();
    }
    void OnMouseMove(UINT nFlags, CPoint pt) {
        if (g_splitDrag) {   // the splitter resizes the LEFT pane (the sidebar); terminal takes the rest
            RECT c; GetClientRect(&c);
            // 60 % of the client at most, and never past what leaves kMinContentCols for the
            // terminal — the same wall `sidebar width` refuses against (#23).
            g_sidebarW = g_sidebarWPref = max(kSidebarMinW, min(min((int)(c.right * 0.6), maxSidebarW((int)c.right)), (int)pt.x));   // a drag IS the preference
            relayout();
            return;
        }
        if (nFlags & (MK_LBUTTON | MK_RBUTTON | MK_MBUTTON)) {   // report drags to a mouse-aware app
            int held = (nFlags & MK_LBUTTON) ? 0 : (nFlags & MK_RBUTTON) ? 2 : 1;
            if (mouseReport(pt.x, pt.y, held, true, true)) return;
        }
        if (g_sel.active && (nFlags & MK_LBUTTON)) {
            int pane, absRow, col;
            // Held across hit-test, reconcile and store, for the same reason as mouse-down: an
            // eviction landing between any two of them puts the ends in different numberings.
            LockG lk;
            if (hitTest(pt.x, pt.y, &pane, &absRow, &col) && pane == g_sel.pane) {
                // Reconcile BEFORE writing: absRow is in today's numbering while the anchor may
                // still be in the numbering from when the drag started, and storing the two
                // together would leave the next reconcile shifting this fresh end as well.
                syncSelection();
                if (!g_sel.bound()) return;   // it was dropped under us
                g_sel.bRow = absRow; g_sel.bCol = col;
                Invalidate(FALSE);
            }
        }
    }
    void OnLButtonUp(UINT, CPoint pt) {
        if (g_splitDrag) { g_splitDrag = false; ReleaseCapture(); saveColors(); return; }   // persist the new width
        if (mouseReport(pt.x, pt.y, 0, false, false)) return;
        {
            // ReleaseCapture unconditionally: syncSelection can DROP the selection mid-drag (its
            // rows evicted, or the app switched to the alt screen), which clears `active` — and the
            // mouse then stayed captured with no drag in progress.
            bool wasDragging;
            {
                LockG lk;
                wasDragging = g_sel.active;
                g_sel.active = false;
            }
            if (GetCapture() == m_hWnd) ReleaseCapture();
            if (wasDragging && g_sel.has()) copySelection();   // auto-copy on release (convention)
        }
    }
    void OnRButtonDown(UINT, CPoint pt) {
        if (pt.x < sidebarSpan()) return;                        // sidebar/splitter: no paste
        // Everything a LEFT click does about focus, a right click must do too. It did neither, and
        // both omissions bite:
        //   - no g_focus: in a split, right-clicking one pane pasted into the OTHER one, because
        //     pasteClipboard() targets the focused pane rather than the pane under the cursor.
        //   - no SetFocus: the keyboard stayed wherever it was. If that was the sidebar — and it can
        //     be, since the bounce only fires when the tree RECEIVES focus, not when it already has
        //     it — the next keystroke drove the TreeView's type-ahead instead of the shell, which
        //     selects a different row and so silently SWITCHES SESSION. Pasting a command and typing
        //     Enter then landed in a terminal the user was not looking at.
        int pane, absRow, col;
        if (hitTest(pt.x, pt.y, &pane, &absRow, &col)) g_focus = pane;
        SetFocus();                                              // before the early return below
        // Paste WINS over the app's mouse reporting (main-app parity, Program.WndProc.cs). It used
        // to lose, and that made right-click paste dead exactly where it is wanted most: a TUI like
        // Claude Code holds mouse mode on for its entire run, so every right-click went to the app
        // as a button-2 report - which it ignores - and nothing was ever pasted. An app that really
        // needs the right button still gets it with RightClickPaste off.
        if (g_rightClickPaste) { pasteClipboard(); return; }
        if (mouseReport(pt.x, pt.y, 2, true, false)) { g_rbtnForwarded = true; return; }
        pasteClipboard();
    }
    // Only report the release if the press was reported: a paste must not leak an orphan button-2
    // release into an app that never saw the press.
    void OnRButtonUp(UINT, CPoint pt) {
        if (!g_rbtnForwarded) return;
        g_rbtnForwarded = false;
        mouseReport(pt.x, pt.y, 2, false, false);
    }

    // ---- caret blink + focus cue ----
    // Only the caret cell needs repainting, so invalidate that instead of the whole client: on the
    // low-end machines lite targets, a full 2 Hz recompose for a blinking block would be pure waste.
    void InvalidateCaret() {
        RECT rc; GetClientRect(&rc);
        for (int p = 0; p < 2; p++) {
            if (g_pane[p] < 0 || g_pane[p] >= (int)g_sessions.size()) continue;
            if (p != g_focus) continue;
            RECT pr; paneRect(p, rc, &pr);
            FfiEmuInfo info{};
            EnterCriticalSection(&g_lock);
            emu_info(g_sessions[g_pane[p]]->emu, &info);
            LeaveCriticalSection(&g_lock);
            RECT cur{ pr.left + (LONG)info.cursorCol * g_cw, pr.top + (LONG)info.cursorRow * g_ch,
                      pr.left + (LONG)(info.cursorCol + 1) * g_cw, pr.top + (LONG)(info.cursorRow + 1) * g_ch };
            if (cur.right <= pr.right && cur.bottom <= pr.bottom) InvalidateRect(&cur, FALSE);
        }
    }
    void OnTimer(UINT_PTR id) {
        if (id == kRelayoutTimer) {
            // A resize that did not happen: the UI thread skipped it because a control-pipe thread
            // held g_resizeLock, or the pty-host refused one and the rollback armed this. Kill the
            // timer FIRST: hostResize re-arms it if the reason persists — immediately for the lock,
            // and backing off 60/120/240 ms for a refusal before it gives up (kResizeRetryAttempts).
            // Either way the loop is idle between attempts, unlike the posted message this replaced,
            // which re-posted itself ahead of paint and input (revmux r3). Both sweeps pass
            // fromRetry, so a session that has already given up is not asked again here. The panes
            // go through syncPaneSizes; the popups need refitPopupSessions, since their sessions are
            // never in g_pane.
            KillTimer(kRelayoutTimer);
            if (!g_sessions.empty()) syncPaneSizes(true);   // fromRetry: see hostResize
            refitPopupSessions(true);
            return;
        }
        if (id != kCaretTimer) return;
        if (!g_winFocused) return;            // hollow caret doesn't blink
        g_caretOn = !g_caretOn;
        InvalidateCaret();
    }
    // Coming back to the window (Alt-Tab, taskbar, clicking the title bar) must land in the shell.
    // Windows restores focus to whichever child held it last, which after any sidebar interaction
    // is the tree — so returning to lite left you typing into the sidebar.
    void OnActivateFrame(UINT state, BOOL, CWindow) {
        if (state != WA_INACTIVE) {
            logInfo("focus: window activated -> reclaiming the keyboard for the terminal");
            ::PostMessageW(m_hWnd, WM_APP_FOCUSTERM, 0, 0);
        }
    }
    void OnSetFocusFrame(CWindow) { g_winFocused = true;  g_caretOn = true; InvalidateCaret(); }
    void OnKillFocusFrame(CWindow) { g_winFocused = false; g_caretOn = true; InvalidateCaret(); }

    LRESULT OnSetCursor(UINT, WPARAM wp, LPARAM lp, BOOL& bHandled) {
        // Children (toolbar/tree/status) forward WM_SETCURSOR here; wParam names the window the
        // cursor is actually in. Only claim the cursor for OUR client area — otherwise the toolbar
        // ends up with an I-beam whenever the sidebar is hidden (sidebarSpan() becomes 0).
        if ((HWND)wp == m_hWnd && LOWORD(lp) == HTCLIENT) {
            POINT p; GetCursorPos(&p); ScreenToClient(&p);
            if (inSplitter(p.x, p.y)) { SetCursor(LoadCursorW(nullptr, (LPCWSTR)IDC_SIZEWE)); return TRUE; }
            if (p.x >= sidebarSpan()) { SetCursor(LoadCursorW(nullptr, (LPCWSTR)IDC_IBEAM)); return TRUE; }
        }
        bHandled = FALSE;   // a child's cursor is the child's business
        return 0;
    }

    // ---- layout ----
    void OnSize(UINT nType, CSize size) {
        if (nType == SIZE_MINIMIZED) return;
        if (m_toolbar.IsWindow()) {   // standard toolbar spans the top; capture height (0 when hidden)
            m_toolbar.ShowWindow(g_showToolbar ? SW_SHOW : SW_HIDE);
            if (g_showToolbar) {
                m_toolbar.AutoSize();
                RECT tr; m_toolbar.GetWindowRect(&tr); g_toolbarH = tr.bottom - tr.top;
            }
        }
        if (m_status.IsWindow()) {    // standard status bar auto-docks bottom; capture its height
            m_status.ShowWindow(g_showStatus ? SW_SHOW : SW_HIDE);
            if (g_showStatus) {
                m_status.SendMessage(WM_SIZE, 0, 0);
                RECT sr; m_status.GetWindowRect(&sr); g_statusH = sr.bottom - sr.top;
            }
        }
        // Before the tree is placed: the sidebar never takes more than leaves kMinContentCols for
        // the terminal (#23). This is also where the two persisted values meet for the first time
        // — SidebarW and the WinW-<instance> rect — because the first WM_SIZE comes from CreateEx,
        // with the fonts already measured; loadColors alone cannot see the client width.
        fitSidebarToClient(size.cx);
        if (m_tree.IsWindow()) {      // resizable sidebar between the toolbar and the status bar
            m_tree.ShowWindow(g_showSidebar ? SW_SHOW : SW_HIDE);
            if (g_showSidebar)
                m_tree.SetWindowPos(nullptr, 0, toolbarTop(), g_sidebarW,
                                    size.cy - toolbarTop() - (g_showStatus ? g_statusH : 0),
                                    SWP_NOZORDER | SWP_NOACTIVATE);
        }
        if (!g_sessions.empty()) syncPaneSizes();
    }
    void OnExitSizeMove() { saveWindowRect(); }   // remember geometry after a user move/resize

    // Windows "app mode" flipped (or any policy change): AUTO re-resolves, the rest are unaffected.
    void OnSettingChange(UINT, LPCTSTR lpszSection) {
        if (g_themeMode != TH_AUTO) return;
        if (lpszSection && lstrcmpiW(lpszSection, L"ImmersiveColorSet") != 0) return;
        applyTheme();
    }

    // ---- app messages ----
    /// Restore keyboard focus to the terminal after the sidebar finished handling a click. Skipped
    /// while a tree label is being edited (rename) — that edit box legitimately owns the keyboard.
    LRESULT OnFocusTerm(UINT, WPARAM, LPARAM, BOOL&) {
        if (g_tree && TreeView_GetEditControl(g_tree)) { logInfo("focus: restore SKIPPED (rename edit owns the keyboard)"); return 0; }
        SetFocus();
        logInfo("focus: terminal has the keyboard (focus owner now %p)", (void*)::GetFocus());
        return 0;
    }

    LRESULT OnRefreshTree(UINT, WPARAM, LPARAM, BOOL&) {
        refreshTree();
        if (g_toolbar) ::InvalidateRect(g_toolbar, nullptr, FALSE);   // bell re-reads anyBlocked()
        return 0;
    }
    LRESULT OnTray(UINT, WPARAM, LPARAM lp, BOOL&) {
        if (LOWORD(lp) == WM_RBUTTONUP || LOWORD(lp) == WM_CONTEXTMENU) showTrayMenu();
        else if (LOWORD(lp) == WM_LBUTTONDBLCLK) showMainWindow();
        return 0;
    }
    LRESULT OnOverlay(UINT, WPARAM wp, LPARAM lp, BOOL&) {   // marshaled from the control thread
        std::unique_ptr<OverlayReq> r((OverlayReq*)lp);       // this message owns it
        if (!r) return 0;
        if (wp == OVL_RESIZE) resizeOverlay(r->sizePct);
        else openOverlay(r->cmd, r->sizePct);
        return 0;
    }
    // `sidebar width N` stored g_sidebarW on a control-pipe thread and posted this. The layout runs
    // HERE because relayout() SENDS WM_SIZE — from a pipe thread that is a cross-thread SendMessage,
    // which is never made while g_lock may be held (#20). Hidden: nothing to lay out, the width is
    // what the next show uses; it is still persisted so it survives a restart. Same save path as
    // the splitter drag and the View toggles.
    LRESULT OnSidebarWidth(UINT, WPARAM, LPARAM, BOOL&) {
        if (g_showSidebar) relayout();   // repositions the tree (OnSize) and syncPaneSizes()
        saveColors();
        return 0;
    }
    // A host action the reader thread drained (see runHostActions): the clipboard and the tray
    // icon both belong to this thread, so it does that half of the work.
    LRESULT OnHostAction(UINT, WPARAM wp, LPARAM lp, BOOL&) {
        if (wp == HA_CLIP) {                       // OSC 52: the program wrote the clipboard
            std::string* t = (std::string*)lp;
            setClipboardUtf8(*t);
            delete t;
        } else if (wp == HA_NOTIFY) {              // OSC 9 / OSC 777
            NotifyMsg* n = (NotifyMsg*)lp;
            g_nid.uFlags |= NIF_INFO;
            wcscpy_s(g_nid.szInfoTitle, n->title.empty() ? L"agliteterm" : n->title.c_str());
            wcscpy_s(g_nid.szInfo, n->body.c_str());
            g_nid.dwInfoFlags = NIIF_INFO;
            Shell_NotifyIconW(NIM_MODIFY, &g_nid);
            g_nid.uFlags &= ~NIF_INFO;
            delete n;
        } else if (wp == HA_BELL) {                // BEL: beep, and flash only when unattended
            MessageBeep(MB_OK);
            if (GetForegroundWindow() != m_hWnd) FlashWindow(TRUE);
        }
        return 0;
    }
    LRESULT OnAppUpdate(UINT, WPARAM wp, LPARAM lp, BOOL&) {   // self-update worker -> UI thread
        if (wp == UPD_BALLOON) {   // background check: one tray balloon, no interruption
            std::wstring* v = (std::wstring*)lp;
            g_nid.uFlags |= NIF_INFO;
            wcscpy_s(g_nid.szInfoTitle, L"agliteterm");
            swprintf_s(g_nid.szInfo, L"%s is out (you have %s) — Help → Check for Updates",
                       v->c_str(), updVersion().c_str());
            g_nid.dwInfoFlags = NIIF_INFO;
            Shell_NotifyIconW(NIM_MODIFY, &g_nid);
            g_nid.uFlags &= ~NIF_INFO;
            delete v;
        } else if (wp == UPD_MSG) {
            std::wstring* m = (std::wstring*)lp;
            g_updBusy = false;
            MessageBoxW(m->c_str(), L"agliteterm update", MB_OK | MB_ICONINFORMATION);
            delete m;
        } else if (wp == UPD_APPLY) {   // verified payload on disk; confirm, hand off, exit
            UpdApply* a = (UpdApply*)lp;
            if (listInstances().size() > 1) {
                g_updBusy = false;
                MessageBoxW(L"Close the other agliteterm windows first — the installer can't "
                            L"replace a running exe.", L"agliteterm update", MB_OK | MB_ICONWARNING);
            } else {
                std::wstring msg = L"agliteterm " + updVersion() + L" → " + a->ver +
                                   L"\n\nDownload verified (SHA-256). Update and restart now?\n"
                                   L"Sessions are saved and restored.";
                if (MessageBoxW(msg.c_str(), L"agliteterm update", MB_OKCANCEL | MB_ICONQUESTION) == IDOK) {
                    wchar_t exe[MAX_PATH];
                    GetModuleFileNameW(nullptr, exe, MAX_PATH);
                    std::wstring cmd = L"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden"
                                       L" -File \"" + a->helper + L"\" -ProcId " + std::to_wstring(GetCurrentProcessId()) +
                                       L" -Payload \"" + a->payload + L"\" -Exe \"" + exe + L"\"";
                    if (!g_isDefaultInstance)   // named instances come back under their own pipe
                        cmd += L" -Instance \"" + g_instance + L"\"";
                    STARTUPINFOW si{ sizeof si }; PROCESS_INFORMATION pi{};
                    if (CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                                       nullptr, nullptr, &si, &pi)) {
                        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
                        DestroyWindow();        // graceful: saves sessions, drops tray, quits
                    } else {
                        g_updBusy = false;
                        MessageBoxW(L"Failed to start the update helper.", L"agliteterm update", MB_OK | MB_ICONERROR);
                    }
                } else g_updBusy = false;
            }
            delete a;
        }
        return 0;
    }

    // ---- notifications ----
    LRESULT OnNotify(UINT, WPARAM, LPARAM lp, BOOL&) {
        auto* nm = (NMHDR*)lp;
        if (nm->idFrom == ID_TREE && nm->code == NM_CUSTOMDRAW) {
            auto* cd = (NMTVCUSTOMDRAW*)lp;
            if (cd->nmcd.dwDrawStage == CDDS_PREPAINT) return CDRF_NOTIFYITEMDRAW;
            if (cd->nmcd.dwDrawStage == CDDS_ITEMPREPAINT) {
                LRESULT r = CDRF_DODEFAULT;
                // Themed looks paint rows from the palette (clearing CDIS_SELECTED so neither the
                // system highlight nor the theme's selection pill draws over them). Dark keeps the
                // DarkMode_Explorer window theme purely for its native dark scrollbar.
                if (!g_th.classic) {
                    bool sel = (cd->nmcd.uItemState & (CDIS_SELECTED | CDIS_FOCUS)) != 0;
                    cd->clrText   = g_th.text;
                    cd->clrTextBk = sel ? g_th.sel : g_th.client;
                    cd->nmcd.uItemState &= ~(CDIS_SELECTED | CDIS_FOCUS);
                    r = CDRF_NEWFONT;
                }
                LPARAM p = cd->nmcd.lItemlParam;   // italicise "working" agent rows
                if (p >= 0 && p < (LPARAM)g_sessions.size() && !g_sessions[p]->exited &&
                    statusClass(statusOf(g_sessions[p]).status) == AGST_WORKING && g_treeItalic) {
                    SelectObject(cd->nmcd.hdc, g_treeItalic);
                    r = CDRF_NEWFONT;
                }
                if (p >= 0 && p < (LPARAM)g_sessions.size() && (g_sessions[p]->flagged || g_sessions[p]->unread > 0))
                    r |= CDRF_NOTIFYPOSTPAINT;   // pennant / unread badge drawn after the row
                return r;
            }
            if (cd->nmcd.dwDrawStage == CDDS_ITEMPOSTPAINT) {
                LPARAM p = cd->nmcd.lItemlParam;
                if (p >= 0 && p < (LPARAM)g_sessions.size()) {
                    RECT rr;
                    if (TreeView_GetItemRect(g_tree, (HTREEITEM)cd->nmcd.dwItemSpec, &rr, FALSE)) {
                        HDC dc = cd->nmcd.hdc;
                        int cy = (rr.top + rr.bottom) / 2;
                        if (g_sessions[p]->flagged) {   // amber pennant (full app's flag marker)
                            int x = rr.right - 15;
                            COLORREF amber = RGB(245, 194, 66);
                            HPEN pen = CreatePen(PS_SOLID, 1, amber);
                            HBRUSH br = CreateSolidBrush(amber);
                            HGDIOBJ op = SelectObject(dc, pen), ob = SelectObject(dc, br);
                            MoveToEx(dc, x, cy - 6, nullptr); LineTo(dc, x, cy + 6);
                            POINT tri[3] = { { x, cy - 6 }, { x + 8, cy - 3 }, { x, cy } };
                            Polygon(dc, tri, 3);
                            SelectObject(dc, op); SelectObject(dc, ob);
                            DeleteObject(pen); DeleteObject(br);
                        }
                        if (g_sessions[p]->unread > 0) {   // red count pill (full app's notification badge)
                            wchar_t bn[8];
                            wsprintfW(bn, L"%d", g_sessions[p]->unread > 99 ? 99 : g_sessions[p]->unread);
                            HFONT bf = g_uiFont ? g_uiFont : (HFONT)GetStockObject(DEFAULT_GUI_FONT);
                            HGDIOBJ of = SelectObject(dc, bf);
                            SIZE sz{}; GetTextExtentPoint32W(dc, bn, lstrlenW(bn), &sz);
                            int w2 = sz.cx + 10, x1 = rr.right - 20, x0 = x1 - w2;
                            RECT pill{ x0, cy - 8, x1, cy + 8 };
                            HBRUSH rb = CreateSolidBrush(RGB(205, 72, 58));
                            HPEN rp = CreatePen(PS_SOLID, 1, RGB(205, 72, 58));
                            HGDIOBJ ob2 = SelectObject(dc, rb), op2 = SelectObject(dc, rp);
                            RoundRect(dc, pill.left, pill.top, pill.right, pill.bottom, 12, 12);
                            SelectObject(dc, ob2); SelectObject(dc, op2);
                            DeleteObject(rb); DeleteObject(rp);
                            SetBkMode(dc, TRANSPARENT);
                            SetTextColor(dc, RGB(255, 255, 255));
                            DrawTextW(dc, bn, -1, &pill, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
                            SelectObject(dc, of);
                        }
                    }
                }
                return CDRF_DODEFAULT;
            }
            return CDRF_DODEFAULT;
        }
        if (nm->idFrom == ID_TOOLBAR && nm->code == NM_CUSTOMDRAW && !g_th.classic) {
            auto* cd = (NMTBCUSTOMDRAW*)lp;   // flat dark/light toolbar; comctl32 draws 3-D otherwise
            if (cd->nmcd.dwDrawStage == CDDS_PREPAINT) {
                RECT r; m_toolbar.GetClientRect(&r);
                HBRUSH b = CreateSolidBrush(g_th.bar); FillRect(cd->nmcd.hdc, &r, b); DeleteObject(b);
                return CDRF_NOTIFYITEMDRAW;
            }
            if (cd->nmcd.dwDrawStage == CDDS_ITEMPREPAINT) {
                // comctl32 v5 (no manifest) ignores TBCDRF_NOBACKGROUND and paints its raised 3-D
                // face over any fill — so draw the whole button ourselves and skip the default.
                bool hot = (cd->nmcd.uItemState & CDIS_HOT) != 0;
                bool prs = (cd->nmcd.uItemState & (CDIS_SELECTED | CDIS_CHECKED)) != 0;
                RECT rc = cd->nmcd.rc;
                HBRUSH b = CreateSolidBrush(prs ? g_th.sel : hot ? g_th.hot : g_th.bar);
                FillRect(cd->nmcd.hdc, &rc, b); DeleteObject(b);
                int img = tbImageOf((int)cd->nmcd.dwItemSpec);
                if (cd->nmcd.dwItemSpec == IDM_ATTENTION && anyBlocked()) img = 10;   // amber bell
                int ix = rc.left + (rc.right - rc.left - 16) / 2;
                int iy = rc.top + (rc.bottom - rc.top - 16) / 2 + (prs ? 1 : 0);   // classic 1px press nudge
                if (img >= 0) ImageList_Draw(g_tbImages, img, cd->nmcd.hdc, ix, iy, ILD_NORMAL);
                if (hot || prs) { HBRUSH f = CreateSolidBrush(g_th.accent); FrameRect(cd->nmcd.hdc, &rc, f); DeleteObject(f); }
                return CDRF_SKIPDEFAULT;
            }
            return CDRF_DODEFAULT;
        }
        if (nm->code == TBN_GETINFOTIPW) {   // toolbar button hover tooltips ("hints")
            auto* it = (NMTBGETINFOTIPW*)lp;
            const wchar_t* tip = L"";
            for (const auto& b : kTbButtons) if (b.id == it->iItem) { tip = b.tip; break; }
            lstrcpynW(it->pszText, tip, it->cchTextMax);
            return 0;
        }
        if (nm->idFrom == ID_TREE && nm->code == TVN_SELCHANGEDW && !g_treeSyncing) {
            auto* nt = (NMTREEVIEWW*)lp;
            LPARAM p = nt->itemNew.lParam;
            if (p >= 0) {                                   // session node -> show it in the MAIN pane
                int i = (int)p;
                if (i < (int)g_sessions.size()) {
                    selectPrimary(i);                      // tree drives the main pane, not the split shell
                    g_activeWs = g_sessions[i]->ws;         // new sessions follow the selected one's workspace
                    syncPaneSizes();
                    Invalidate(FALSE);
                }
            } else {                                        // workspace node -> make it the active "folder"
                int w = (int)(-p - 1);
                if (w >= 0 && w < (int)g_workspaces.size()) g_activeWs = w;
            }
            // Keep typing going to the terminal, not the tree — but NOT with a direct SetFocus():
            // TVN_SELCHANGED arrives while the tree is still handling WM_LBUTTONDOWN, and the tree
            // takes focus back when that returns, so the click left the sidebar focused and the
            // next keystroke went nowhere useful. Post it and restore focus once the tree is done.
            ::PostMessageW(m_hWnd, WM_APP_FOCUSTERM, 0, 0);
        }
        // A click on the ALREADY-selected row sends no TVN_SELCHANGED at all, so it needs the same
        // treatment or clicking the current session (the obvious "put me back in the terminal"
        // gesture) leaves focus in the tree.
        if (nm->idFrom == ID_TREE && (nm->code == NM_CLICK || nm->code == NM_DBLCLK))
            ::PostMessageW(m_hWnd, WM_APP_FOCUSTERM, 0, 0);
        if (nm->idFrom == ID_TREE && nm->code == NM_RCLICK) {   // right-click a node -> context menu
            POINT cp; GetCursorPos(&cp); ::ScreenToClient(g_tree, &cp);
            TVHITTESTINFO ht{}; ht.pt = cp;
            HTREEITEM it = TreeView_HitTest(g_tree, &ht);
            if (it) {
                TVITEMW ti{}; ti.mask = TVIF_PARAM; ti.hItem = it;
                TreeView_GetItem(g_tree, &ti);
                g_ctxItem = it; g_ctxParam = ti.lParam;   // right-click doesn't change the selection
                showTreeContextMenu();
            }
            return 1;
        }
        if (nm->idFrom == ID_TREE && nm->code == TVN_BEGINLABELEDITW) {   // seed the edit box with the bare name
            auto* di = (NMTVDISPINFOW*)lp;
            if (HWND ed = TreeView_GetEditControl(g_tree)) {
                if (di->item.lParam >= 0) {
                    int i = (int)di->item.lParam;
                    std::wstring bn = (i < (int)g_sessions.size() && !g_sessions[i]->name.empty())
                                      ? g_sessions[i]->name : (L"session " + std::to_wstring(i + 1));
                    ::SetWindowTextW(ed, bn.c_str());
                } else {
                    int w = (int)(-di->item.lParam - 1);
                    if (w >= 0 && w < (int)g_workspaces.size()) ::SetWindowTextW(ed, g_workspaces[w].c_str());
                }
            }
            return 0;   // FALSE = allow the edit
        }
        if (nm->idFrom == ID_TREE && nm->code == TVN_ENDLABELEDITW) {   // apply the new name
            auto* di = (NMTVDISPINFOW*)lp;
            if (di->item.pszText && di->item.pszText[0]) {
                std::wstring txt = di->item.pszText;
                if (di->item.lParam >= 0) { int i = (int)di->item.lParam; if (i < (int)g_sessions.size()) g_sessions[i]->name = txt; }
                else { LockG hold; int w = (int)(-di->item.lParam - 1); if (w >= 0 && w < (int)g_workspaces.size()) g_workspaces[w] = txt; }   // read under g_lock by `tree`
                ::PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);   // re-decorate with status/count
            }
            return 0;   // FALSE — we refresh the label ourselves
        }
        return 0;
    }

    // ---- commands ----
    LRESULT OnCommand(UINT, WPARAM wp, LPARAM lp, BOOL&) {
        int id = LOWORD(wp);
        // Accept only menu/accelerator commands (lParam == 0) and toolbar button clicks. The tree
        // FORWARDS its label-edit control's EN_* notifications here as WM_COMMAND, and their control
        // id can collide with command ids (EN_CHANGE arrived as id 1 == IDM_NEW — so renaming a
        // workspace opened the New Session dialog).
        if (lp != 0 && (HWND)lp != g_toolbar) return 0;
        if (HIWORD(wp) > 1) return 0;   // BN_CLICKED/menu/accel only, never EN_*/CBN_*
        switch (id) {
            case IDM_NEW: newSessionDialog(); break;                                     // profile picker
            case IDM_NEWWS: {                                                            // new workspace ("folder")
                wchar_t nm[32]; wsprintfW(nm, L"workspace %d", (int)g_workspaces.size() + 1);
                { LockG hold; g_workspaces.push_back(nm); g_activeWs = (int)g_workspaces.size() - 1; }   // `tree` walks it under g_lock
                refreshTree();
                break;
            }
            case IDM_PROPERTIES: showPropertiesDialog(); break;
            case IDM_KEYBOARD: showKeyboardDialog(); break;
            case IDM_PALETTE: togglePalette(); break;
            case IDM_QUICK: togglePopupTerminal(false); break;
            case IDM_SCRATCH: togglePopupTerminal(true); break;
            case IDM_REOPEN: reopenClosed(); break;
            case IDM_TG_SIDEBAR: case IDM_TG_TOOLBAR: case IDM_TG_STATUS: {
                bool& b = id == IDM_TG_SIDEBAR ? g_showSidebar : id == IDM_TG_TOOLBAR ? g_showToolbar : g_showStatus;
                b = !b;
                CheckMenuItem(GetMenu(), id, MF_BYCOMMAND | (b ? MF_CHECKED : MF_UNCHECKED));
                relayout(); saveColors();
                break;
            }
            case IDM_FLAG: toggleFlag(focusedSession()); break;
            case IDM_FLAGVIEW: toggleFlagView(); break;
            case IDM_FOCUSWS: toggleFocusWs(g_focusWs >= 0 ? g_focusWs : g_activeWs); break;   // toggle on active ws
            case IDM_ATTENTION: nextBlocked(); break;
            case IDM_RESTART: restartApp(); break;
            case IDM_SHOW: showMainWindow(); break;
            case IDM_EXIT: DestroyWindow(); break;
            case IDM_UPDATE: updCheck(true); break;
            case IDM_INSTALLSKILL: {
                // Teaches Claude Code / Codex to drive THIS terminal. Explicit rather than
                // automatic: it writes into the user's ~/.claude, which is not ours to touch
                // on their behalf at startup.
                std::string r = installAgentSkill();
                ::MessageBoxW(g_hwnd, widen(r).c_str(), L"agliteterm", MB_OK | MB_ICONINFORMATION);
                break;
            }
            case IDM_ABOUT: {
                std::wstring about = L"agliteterm " + updVersion() +
                                     L"\nA lightweight native terminal over the Rust pty-host.";
                MessageBoxW(about.c_str(), L"About", MB_OK | MB_ICONINFORMATION);
                break;
            }
            default:   // menu-bar / tray: close / split / next / copy / paste / previous
                if (id >= IDM_CLOSE && id <= IDM_PREV) {
                    static const int kb[] = { KB_CLOSE, KB_SPLIT, KB_NEXT, KB_COPY, KB_PASTE, KB_PREV };
                    runKbAction(kb[id - IDM_CLOSE]);
                    Invalidate(FALSE); SetFocus();
                }
                break;
        }
        return 0;
    }

    void OnDestroy() {
        KillTimer(kCaretTimer);
        saveWindowRect();                        // remember window size + position for next launch
        saveSessionState();                      // final save with LIVE cwds — while the shells are
                                                 // still alive to answer the PEB query; the periodic
                                                 // saves only fire on structural changes, not on cd
        Shell_NotifyIconW(NIM_DELETE, &g_nid);   // remove the tray icon
        for (Session* s : g_sessions) killSession(s);
        retractInstance();
        // The pty-host is SHARED between windows: only the last one out turns off the lights.
        if (listInstances().empty()) {
            agwinterm_ptyhost_Request req = agwinterm_ptyhost_Request_init_default;
            agwinterm_ptyhost_Reply rep = agwinterm_ptyhost_Reply_init_default;
            req.which_cmd = agwinterm_ptyhost_Request_shutdown_tag;
            request(req, &rep);
        }
        PostQuitMessage(0);
    }
};

static CMainFrame g_frame;


// ---- control-API server (newline JSON, agwintermctl/skill-compatible subset) ----
// id (exact), then id prefix, then NAME. The name is what a human says and therefore what an agent
// is told — "run it in the ralphex02 session" — and an id-only lookup made that the one phrasing
// that could not work, while every other verb happily reported "session not found".
//
// An ambiguous name resolves to NOTHING rather than to the first match: two panes can share a name,
// and silently typing into the wrong terminal is worse than refusing. resolveTargetWhy() spells that
// out for the caller instead of leaving them to guess.
// ---- control-API event bus -------------------------------------------------------------------
// A bounded, cursor-polled log of what happened: status changes, session lifecycle, tree edits.
// An agent that can only read the screen has to poll and diff it to notice a command finished;
// this lets it ask "what changed since cursor N" instead. Same shape as the full app, so one
// script works against both.
//
// Emitted from the UI thread AND the reader threads; polled from the pipe thread. Hence its own
// lock rather than g_lock, which is already held across emulator work when a status changes.
struct CtlEvent { long long seq; std::string type, session, info; };
static CRITICAL_SECTION g_evtLock;
static std::deque<CtlEvent> g_evtLog;
static long long g_evtSeq = 0;
static bool g_evtReady = false;

static void emitEvent(const char* type, const std::string& session, const std::string& info) {
    if (!g_evtReady) return;             // before initControl(): nothing is polling yet
    EnterCriticalSection(&g_evtLock);
    g_evtLog.push_back({ ++g_evtSeq, type, session, info });
    while (g_evtLog.size() > 1000) g_evtLog.pop_front();   // bounded history, oldest first
    LeaveCriticalSection(&g_evtLock);
}

// ---- session.context rules (P3) ----
// The rules and the wording are agwinterm's SessionContexts (src/Agwinterm.Pty/SessionContexts.cs),
// copied, not paraphrased: one API, one answer. Used by the verb AND by the state-file loader, so a
// value read back from disk is held to exactly what the verb would have accepted.
//
// The ceiling, in UTF-16 code units (.NET string.Length — the unit agwinterm counts in, so the same
// text is over or under the ceiling in both apps). This is a DISPLAY budget, not a storage limit:
// the sidebar row draws the context as a dimmed run after the name, clipped to the row. Do not
// raise it without widening that surface.
static constexpr size_t kContextMaxLength = 200;
static const char* const kContextBlank =
    "session context: the text is blank; a context is one line of printable text, and `session context --clear` removes one. Nothing changed.";
// Text and --clear together: two sources for one field, refused rather than ranked (the rule
// `session type --stdin` set in P2).
static const char* const kContextTextAndClear =
    "session context: text and --clear cannot be combined (one says what the context is, the other that there is none). Nothing changed.";
// The target resolves to no session — the same "session not found" session.rename answers, so a
// script sees one wording for one condition.
static const char* const kContextNoSession = "session not found; nothing changed";

// The refusal for `decoded` (the JSON-decoded UTF-8 text as the caller sent it), or "" when it is
// acceptable — in which case *normalized holds the value to store. Checks, in agwinterm's order:
//   1. a control character (below U+0020, or U+007F..U+009F) anywhere in the text AS GIVEN, before
//      trimming, naming the character and its OFFSET in UTF-16 code units of the decoded string —
//      the index a caller finds in what they sent (jsonParseString has already turned \t, \n and
//      \u0001 into the bytes themselves, so an escape in the request is a control character here);
//      checking before trim also refuses a trailing tab or NEL instead of silently eating it;
//   2. trim both ends (the .NET char.IsWhiteSpace set; the control range is already gone);
//   3. blank after the trim — naming --clear as the way to remove a context;
//   4. over kContextMaxLength code units — naming the ceiling.
// A refusal changes nothing: the caller keeps the old context and nothing is saved.
static std::string contextRefusal(const std::string& decoded, std::string* normalized) {
    std::wstring w = widen(decoded);
    for (size_t i = 0; i < w.size(); i++) {
        unsigned c = (unsigned)w[i];
        if (c < 0x20 || (c >= 0x7F && c <= 0x9F)) {
            char b[200];
            sprintf_s(b, "session context: control character U+%04X at offset %zu; a context is one line of printable text (no newline, tab or escape). Nothing changed.", c, i);
            return b;
        }
    }
    auto isWs = [](wchar_t c) {   // char.IsWhiteSpace, minus the control range refused above
        return c == 0x20 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) ||
               c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
    };
    size_t b = 0, e = w.size();
    while (b < e && isWs(w[b])) b++;
    while (e > b && isWs(w[e - 1])) e--;
    std::wstring t = w.substr(b, e - b);
    if (t.empty()) return kContextBlank;
    if (t.size() > kContextMaxLength)
        return "session context: " + std::to_string(t.size()) + " characters is over the ceiling of " +
               std::to_string(kContextMaxLength) +
               "; the ceiling is a display budget (the title bar and the sidebar row draw the context beside the name). Nothing changed.";
    if (normalized) *normalized = narrow(t);
    return {};
}

static Session* resolveTarget(const std::string& target, std::string* why = nullptr) {
    if (target.empty() || target == "active") return focusedSession();
    LockG hold;   // the list shape and the names change under g_lock on other threads (see `tree`)
    for (Session* s : g_sessions)
        if (s->id == target) return s;
    for (Session* s : g_sessions)
        if (target.size() >= 4 && s->id.compare(0, target.size(), target) == 0) return s;

    std::wstring wanted = widen(target);
    Session* hit = nullptr;
    int matches = 0;
    for (Session* s : g_sessions) {
        if (s->hidden) continue;                       // quick/scratch/overlay are not addressable by name
        if (lstrcmpiW(s->name.c_str(), wanted.c_str()) == 0) { hit = s; matches++; }
    }
    if (matches == 1) return hit;
    if (matches > 1 && why)
        *why = "'" + target + "' names " + std::to_string(matches) + " sessions — target one by id "
               "(agwintermctl tree --json lists them)";
    return nullptr;
}

// The workspace of the pane that RAN a command, for `session.new` with no workspace named (P2,
// agwinterm task 5a). `caller` is the pane's own AGWINTERM_SESSION_ID, which the CLI sends beside
// the other args; it is an ID, so this resolves by exact id and then by the same >=4-char id prefix
// resolveTarget accepts — and NEVER by name (agwinterm's CallerIsNeverASessionName). resolveTarget's
// name arm is not reused on purpose: a session named like some other session's id would place the
// new session in the wrong workspace by accident, which is the exact bug the caller rule removes.
//
// -1 when nothing resolves — a closed pane, a script run from an unrelated shell, the conformance
// runner (which scrubs the env) — and the verb falls back rather than refusing: a working script
// must not break to fix a preference. A hidden session (quick / scratch / overlay) also answers -1:
// lite gives those the workspace that happened to be active when they were made, which is not a
// workspace the caller can see in `tree`, so "the caller's workspace" has no honest answer there.
static int callerWorkspace(const std::string& caller, std::wstring* nameOut = nullptr) {
    if (caller.empty() || caller == "active") return -1;   // "active" is a target word, never an id
    LockG hold;   // the list and s->ws change under g_lock on other threads (see `tree`)
    Session* hit = nullptr;
    for (Session* s : g_sessions)
        if (s->id == caller) { hit = s; break; }
    if (!hit && caller.size() >= 4)
        for (Session* s : g_sessions)
            if (s->id.compare(0, caller.size(), caller) == 0) { hit = s; break; }
    if (!hit || hit->hidden) return -1;
    if (hit->ws < 0 || hit->ws >= (int)g_workspaces.size()) return -1;
    if (nameOut) *nameOut = g_workspaces[hit->ws];   // the identity, for the re-find after the create
    return hit->ws;
}

// Buffer text, optionally limited to an absolute line range [from, to]. "Absolute" numbers the
// scrollback and the screen as one sequence, which is the numbering FfiMark already speaks, so a
// mark's outputLine..endLine can be handed straight in.
static std::string dumpBufferRange(Session* s, int64_t from, int64_t to) {
    FfiEmuInfo info{};
    std::string out;
    int64_t abs = 0;
    EnterCriticalSection(&g_lock);
    emu_info(s->emu, &info);
    std::vector<FfiCell> row(info.cols);
    auto appendRow = [&](const FfiCell* cells) {
        std::string line;
        for (uint32_t c = 0; c < info.cols; c++) {
            const FfiCell& cell = cells[c];
            if (cell.width == 0) continue;
            int cp = cell.rune ? cell.rune : ' ';
            wchar_t wbuf[2];
            int wn = 0;
            if (cp > 0xFFFF) {
                wbuf[wn++] = (wchar_t)(0xD800 + ((cp - 0x10000) >> 10));
                wbuf[wn++] = (wchar_t)(0xDC00 + ((cp - 0x10000) & 0x3FF));
            } else wbuf[wn++] = (wchar_t)cp;
            char u8[8];
            int n8 = WideCharToMultiByte(CP_UTF8, 0, wbuf, wn, u8, sizeof u8, nullptr, nullptr);
            line.append(u8, n8);
        }
        while (!line.empty() && line.back() == ' ') line.pop_back();
        out += line;
        out += '\n';
    };
    auto wanted = [&](int64_t line) { return from < 0 || (line >= from && line <= to); };
    for (uint32_t h = 0; h < info.historyCount; h++, abs++)
        if (wanted(abs) && emu_copy_history_row(s->emu, h, row.data(), info.cols)) appendRow(row.data());
    if (s->grid.size() >= (size_t)info.cols * info.rows)
        for (uint32_t r = 0; r < info.rows; r++, abs++)
            if (wanted(abs)) appendRow(&s->grid[r * info.cols]);
    LeaveCriticalSection(&g_lock);
    while (out.size() >= 2 && out[out.size() - 1] == '\n' && out[out.size() - 2] == '\n') out.pop_back();
    return out;
}
static std::string dumpBufferText(Session* s) { return dumpBufferRange(s, -1, -1); }

// The output of the last COMPLETED command, delimited by the shell's FTCS (OSC 133) marks.
// This is what an agent needs after asking a terminal to do something: not the whole screen,
// and not a guess at which lines were the answer.
//
// It depends on the shell emitting 133;A/B/C/D. Without that there are no marks at all, and
// saying so beats returning "" — which reads as "the command printed nothing".
static std::string lastCommandOutput(Session* s, bool* haveMarks) {
    FfiEmuInfo info{};
    EnterCriticalSection(&g_lock);
    emu_info(s->emu, &info);
    std::vector<FfiMark> marks(info.markCount ? info.markCount : 1);
    uint32_t nm = info.markCount ? emu_marks(s->emu, marks.data(), info.markCount) : 0;
    LeaveCriticalSection(&g_lock);

    const FfiMark* last = nullptr;
    for (uint32_t k = 0; k < nm; k++)
        if (marks[k].endLine >= 0) last = &marks[k];   // completed only: a running command has no end
    *haveMarks = last != nullptr;
    if (!last) return {};

    // Output starts after the command's input row: 133;C when the shell emits it, else the line
    // after 133;B, else after the prompt. Mirrors the full app so both answer the same question.
    int64_t from = last->outputLine >= 0 ? last->outputLine
                 : last->commandLine >= 0 ? last->commandLine + 1
                 : last->promptLine + 1;
    if (from > last->endLine - 1) return {};          // the command printed nothing
    return dumpBufferRange(s, from, last->endLine - 1);
}

// ---- bundled agent skill --------------------------------------------------------------------
// A SKILL.md that teaches Claude Code / Codex to drive THIS terminal. It documents only the verbs
// agliteterm actually implements, and says plainly which of the full app's it does not.
//
// That restraint is the whole point. agwinterm's skill teaches events/output/search/command.run/
// notify/install.*, and an agent following it against this client walked straight into
// "unknown command '...' (lite subset)" — which reads as a broken terminal rather than a smaller
// one. A skill that overpromises is worse than no skill.
static const char* kSkillMarkdown = R"SKILL(---
name: agliteterm
description: Use when running inside the agliteterm terminal (env AGWINTERM_ENABLED=1, TERM_PROGRAM=agliteterm) to control it - report agent status, create/switch/close sessions, run commands in named sessions, read a command's output, check a pane's caret column before typing into it, and poll for events - via the agwintermctl CLI or its control pipe.
---

# agliteterm

agliteterm is a small native Windows terminal from the agwinterm family. It speaks the same
control API as the full app, over the same `agwintermctl` CLI, with a smaller verb set.

## Detect

You are inside agliteterm when `AGWINTERM_ENABLED=1` and `TERM_PROGRAM=agliteterm`.

- `AGWINTERM_SESSION_ID` - your session id, and the default target when you pass none. Read
  that twice: a command with no `--target` goes to YOUR OWN pane. Pass `--target` whenever you
  mean a different one, or you will type into your own prompt
- `AGWINTERM_PANE_ID` - same value; use it when you specifically mean the pane
- `AGWINTERM_PIPE` - the control pipe name (full path `\.\pipe\<name>`)

The variables keep the `AGWINTERM_` prefix on purpose: the same hooks and scripts work in both
products.

## Targeting a session

`--target` takes an id, an id prefix (4+ chars), or a session NAME. A name that matches more than
one session is refused rather than guessed - ask `tree --json` and target an id instead.

```
agwintermctl session type "npm test" --target build      # by name
agwintermctl tree --json                                 # ids, names, status, flags, unread
```

## Report your status - do this, it is the point

The sidebar shows a per-session cue, so the user can see at a glance which agent needs them:

```
agwintermctl session status working     # busy
agwintermctl session status blocked     # waiting for the user
agwintermctl session status idle        # done
```

## Run something in a session

One call creates the session, names it, and runs the command as its shell:

```
agwintermctl session new --name build --command "npm test" --cwd C:\src\app
```

**A bare `session new` lands in YOUR workspace** - the one holding the pane whose
`AGWINTERM_SESSION_ID` the CLI sends as the caller - not in whichever workspace happens to be
active. Active is a global the UI rewrites on every click, every selection and every
`workspace new`, so a run of sessions created against it used to scatter across whatever the user
was clicking; now they land next to you, however the user clicks around meanwhile. The active
workspace is the LAST fallback, used only when the caller does not resolve (an unrelated shell, a
closed pane). Name a workspace to go somewhere else - the id is the index `tree` reports:

```
agwintermctl session new --name build --workspace 1
agwintermctl session new --name build --workspace-name review [--create-workspace]
```

A workspace that does not exist is refused, not silently swapped for the active one, and no session
is created. `--workspace` beside `--workspace-name` is refused as two answers to one question.

## Typing, and the two verbs that are not the same thing

`session type` sends keystrokes to the shell. A newline is Enter; every other control byte is
REFUSED rather than stripped, because a NUL truncates your command while its Return still fires.
Pass `--allow-control` when you mean one (an escape sequence for a TUI, a lone ^C).

`session type --stdin --target <id>` takes the text from standard input, as bytes. This is how
text with quotes, newlines, runs of spaces or a leading `--` is sent: on the argv path a shell
splits words (a run of spaces and a newline are gone before the CLI sees them), the option parser
eats a `--word` and the word after it, and a quote has to survive two shells' quoting rules -
every one of those losses is silent and the call still answers ok. Pipe a here-string
(`@"..."@ | agwintermctl session type --stdin --target <id>`) or redirect a file. Exactly one
trailing newline is dropped (the one the pipe adds), so end the text with TWO newlines to press
Enter. Invalid UTF-8 is refused by the CLI with the byte offset and NOTHING is sent (exit 2).
`--stdin` beside positional text is refused as ambiguous. `--allow-control` still applies, and
lite's side is unchanged: the same decoder, the same control-byte refusal, whichever way the text
came in.

There is no `quick type` verb. The quick terminal is a hidden session: `quick on` answers `ok`,
not an id; the id arrives as a `session` / `created` event (`events --since <cursor>`), the
session is not in `tree`, and it is targeted by that id ONLY - `--target quick`, the name, is
refused. So `session type --stdin --target <quick session id>` types into it.

`session write` does NOT reach the shell. It injects bytes into the terminal's display, so it paints
a pane without any program having printed anything — useful for a banner or a marker, and no use at
all for sending keys.

## A second pane, beside you

`session split` opens the CURRENT SESSION's right-hand pane and RETURNS ITS SESSION ID. That id is
the only handle it has: the split shell is hidden, so it appears in no tree listing and has no name.

The split belongs to that session: switch to another session and the right pane shows that one's
split, or none at all. It closes with its owner.

```
id=$(agwintermctl session split)
agwintermctl session type "ralphex docs/plans/my-plan.md\n" --target $id
```

Keep the id if you want to read that pane later (`session text --target $id`). Closing the split
kills the shell. For something durable and visible instead, make a NAMED session - it shows in the
sidebar and can be addressed by name - it simply will not sit side by side.

For a session that already exists, type into it (`\n` is sent as Enter):

```
agwintermctl session type "npm test`n" --target build
```

## A command in a popup over the window

```
agwintermctl session overlay open "git log --oneline" [--size-percent N]
agwintermctl session overlay resize --size-percent N
agwintermctl session overlay close
```

`open` runs the command in a popup terminal over the main window and answers a status word, not
a session id (the popup is created after the reply is written). The popup is `--size-percent` of
the window's client area on each side, **a whole number in 1..100** (anything else refused). A popup
cannot be smaller than 30x8 cells, so on a small window a low percentage comes back RAISED to what
fits and the reply says the percentage IN EFFECT (`overlay opened at N%`, `resized N%`) - compare it
with what you asked for, as `sidebar width` already makes you. When the window cannot be measured at
all - it is minimised, or its client is under 30x8 cells - there is no percentage to name and the
reply says so instead (`overlay opened at the smallest size this window can show (...)`, `resized to
the smallest size ...`), so a caller matching `at (\d+)%` must handle the miss:
`0`, `150`, `-5` and `sixty` are refused naming the value and the range, and NO popup opens or
moves. Omit the flag for lite's default popup (70 %; the full app's default is the whole region -
the contract pins the reply and the refusal, not the geometry). `open` with no command is refused;
so is an action other than `open`, `close`, `resize`; so is a `--target` that names no session
(nothing opened, resized or closed). `resize` with no overlay open is refused - open one first;
`close` with none open answers `no overlay`, which is true afterwards. lite's overlay is one popup
per window, so a target that does resolve is accepted whichever session it names.

## The sidebar

```
agwintermctl sidebar show|hide|toggle          # on/off are show/hide
agwintermctl sidebar state                     # {visible, width}
agwintermctl sidebar width [N]                 # read, or set (pixels)
```

`width N` answers the width IN EFFECT with `visible` and `applied`, which is how you tell an
honoured request from anything else; the divider actually moves and the setting is saved. Two
limits, each refused by name: the range is **90..900** px (what the splitter and the saved setting
already allow), and a width that would leave the terminal under 20 columns in the window as it is
now - widen the window or ask for less. A set while the sidebar is hidden is remembered, answers
`applied:false`, and takes effect on the next `show`. Any op not listed - `sideways`, a typo -
is refused naming the five, and **nothing changes** (it used to toggle the sidebar).

## Find out what happened

Two ways, and prefer the first:

```
agwintermctl events --since <cursor>            # what changed; the reply carries the new cursor
agwintermctl session output --target build      # the last COMPLETED command's output
agwintermctl session text --target build        # the whole buffer, when you need context
```

`events` is cursor-polled: start with `agwintermctl events` to get a cursor, then pass it as
`--since`. Event types are `session` (info: created/closed), `status` (info: the new status), and
`tree`. The reply always carries the current cursor, even when nothing happened, so a quiet
terminal still moves you forward.

`session output` needs FTCS shell integration (OSC 133) in the shell. Without it you get
"no completed command marks" rather than a wrong answer - fall back to `session text`.

Every session node of `tree --json` carries `statusChangedAt`: epoch SECONDS of the last status
**write** - that agent's liveness clock. Every write restamps it - each `session status`,
including a re-assert of the same status, and the Esc/Ctrl+C clear of a working status typed into
the pane - so `now - statusChangedAt` is how long ago the status last moved or was re-asserted: a
large age beside `"status":"active"` means its hook died, not that work is still running. Always
present, even for a session that never set a status (then it is the session's own age).

## Before typing into another agent's composer

```
agwintermctl surface cursor --target <id|name>     # the caret COLUMN, a bare integer
```

An empty composer parks the caret at a known column, so a **different** column means a draft is
sitting there: do not send. One number, one compare - it replaces reading the rendered text and
guessing at placeholder strings. Column `0` is a real answer (the caret at the left margin), not
"no answer"; a miss is `ok:false`. The row is deliberately not reported. The target resolves
exactly as `session text` / `session type` do, so the pane you check is the pane you type into.

Two caveats:

- the same column is necessary, not sufficient: a draft exactly one wrap width long parks the
  caret back where it started, so back a match with `session text` of that row before typing
- after a print into the last column the answer EQUALS the pane width (the wrap is deferred to the
  next character), so do not use it as an index into a `session text` row without clamping

## Which binary, which app

```
agwintermctl version [--json]
```

Two greppable lines: `cli` (the agwintermctl you actually ran, version and resolved path - several
can coexist and none need be on PATH) and `app` (what answered on the pipe). The app line is what
`ping` answers, `agliteterm <version>`, so it names the build that is really running. It exits 0
and still prints the `cli` half when nothing is listening, marking the app `unavailable`.

## Sessions, workspaces, windows

```
agwintermctl session new|select|close|rename|duplicate|move|go|flag|seen|split|scratch|overlay|write
agwintermctl session copy|paste|type|text|output|status
agwintermctl surface cursor
agwintermctl workspace new|rename|select|delete|collapse|expand|focus
agwintermctl window new|list|select|close|delete|rename|move|resize|state|zoom
agwintermctl tree --json | ping | version | sidebar show|hide|toggle|state|width | quick on|off|toggle
```

Every window is its own process with its own pipe, so `--pipe <name>` picks the window and
`window list` enumerates them.

Nothing here takes the foreground from the user: `quick on` and `session overlay open` raise
their popup only when this process already holds the foreground, and flash the taskbar button
otherwise. `window select <name>` is the one verb whose purpose IS the raise, so it is attempted -
and the reply says what happened: `selected` only when the window is in front afterwards, and a
string starting `not raised:` (Windows kept the foreground with the app the user is working in;
the button flashes) when it is not. Both are `ok` - the window exists and the request was made,
which is the shape the contract pins and what the full app answers - so test the result, not
`ok`: `ok:false` means the window was not found.

## What this terminal does NOT have

Do not reach for these - they exist in the full agwinterm and will be refused here with
"unknown command '<verb>' (lite subset)":

`session search`, `session readonly`, `session bind`, `session restore`, `session background`,
`command run`, `command list`, `command leader`, `notify`, `broadcast`, `dashboard`,
`config get|set|list`, `profiles list|reload`, `theme list|set`, `omp list|set`, `image show|sixel`,
`font`, `keymap reload`, `selection *`, `restore clear`, `install hooks|shell|cli`, `claude *`.

For anything not listed as available, drive the shell directly with `session type` and read the
result with `session output` or `session text`.
)SKILL";

// Written next to the other tools' skills so an agent self-discovers it. Copy-per-tool rather than
// one shared file: each tool owns its own directory, and a missing tool is skipped rather than
// created (installing into ~/.codex for someone who does not use Codex is litter).
static std::string installAgentSkill() {
    wchar_t home[MAX_PATH];
    if (!GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH)) return "cannot resolve %USERPROFILE%";
    int written = 0;
    std::string where, looked;
    for (const wchar_t* tool : { L".claude", L".codex" }) {
        std::wstring base = std::wstring(home) + L"\\" + tool;
        if (!looked.empty()) looked += ", ";
        looked += narrow(base);
        if (GetFileAttributesW(base.c_str()) == INVALID_FILE_ATTRIBUTES) continue;   // tool not installed
        std::wstring dir = base + L"\\skills";
        CreateDirectoryW(dir.c_str(), nullptr);
        dir += L"\\agliteterm";
        CreateDirectoryW(dir.c_str(), nullptr);
        std::wstring file = dir + L"\\SKILL.md";
        HANDLE h = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) continue;
        DWORD wr = 0;
        bool ok = WriteFile(h, kSkillMarkdown, (DWORD)strlen(kSkillMarkdown), &wr, nullptr) && wr == strlen(kSkillMarkdown);
        CloseHandle(h);
        if (!ok) continue;
        written++;
        if (!where.empty()) where += ", ";
        where += narrow(file);
    }
    // Name the paths that were checked. "Not found" without a path sends the reader looking in the
    // wrong home directory, which is exactly what happened the first time this ran under a test.
    if (!written) return "no agent tool directory found - looked in: " + looked;
    return "installed the agliteterm skill to " + std::to_string(written) + " location(s): " + where;
}


static std::string ctlDispatch(const std::string& line) {
    JsonReq req;
    size_t i = 0;
    if (!jsonParseObject(line, i, "", req)) return ctlErr("invalid JSON");
    const std::string& cmd = req.get("cmd");

    // The compiled version, never a literal: `agwintermctl version` reports the app serving the pipe
    // from this reply (the way agwinterm's ping says "agwinterm " + AppVersion()), and the About box
    // and the self-updater read the same updVersion(), so all three name the same build.
    if (cmd == "ping") return ctlOkStr("agliteterm " + narrow(updVersion()));
    if (cmd == "tree") {   // real structure: workspaces with their sessions, flags, unread, focus
        // This runs on a control-pipe thread while another pipe thread's session.new can push_back
        // into g_sessions (a realloc frees the buffer this loop indexes) and session.rename can
        // reassign a name this loop reads. Both mutate under g_lock, so the walk holds it too.
        LockG hold;
        std::string wss;
        for (int w = 0; w < (int)g_workspaces.size(); w++) {
            if (w) wss += ",";
            std::string sess;
            bool first = true;
            for (int i2 = 0; i2 < (int)g_sessions.size(); i2++) {
                Session* s = g_sessions[i2];
                if (s->ws != w || s->hidden) continue;
                if (!first) sess += ",";
                first = false;
                std::string nm = s->name.empty() ? s->id : narrow(s->name);
                StatusSnap st = statusOf(s);   // one snapshot: the status and ITS stamp, never a mixed pair
                sess += "{\"id\":\"" + jsonEscape(s->id) + "\",\"name\":\"" + jsonEscape(nm) +
                        "\",\"active\":" + (g_pane[g_focus] == i2 ? "true" : "false") +
                        ",\"status\":\"" + jsonEscape(st.status) + "\"" +
                        // ALWAYS present, never omitted for the default: `tree` says "active" with
                        // no age, and a consumer that has to tell "absent" from "old" gains nothing
                        // from an omission. Epoch seconds of the last status WRITE (see Session).
                        ",\"statusChangedAt\":" + std::to_string(st.changedAt) +
                        ",\"flagged\":" + (s->flagged ? "true" : "false") +
                        ",\"exited\":" + (s->exited ? "true" : "false") +
                        // a spec that could not be relaunched on this machine: kept, not dropped
                        ",\"failed\":" + (s->failed ? "true" : "false") +
                        ",\"unread\":" + std::to_string(s->unread) +
                        // Beyond the contract (extra fields are allowed): the grid the session was
                        // last resized to. It is how a caller sees that `sidebar width` moved the
                        // content region, and the oracle #23 needs (a pane that collapsed to 2).
                        ",\"cols\":" + std::to_string(s->cols) + ",\"rows\":" + std::to_string(s->rows);
                // "context" is emitted ONLY when one is set — deliberately agwinterm's rule
                // (ControlServer.cs: `if (n.Context is not null)`), and deliberately unlike lite's
                // always-emitted booleans above: a script tests PRESENCE of the key ("has this
                // session a context?"), and absent is the one spelling of "none" both apps agree on.
                // An always-present "context":"" would make a set-then-clear look like a set of "".
                if (!s->context.empty()) sess += ",\"context\":\"" + jsonEscape(narrow(s->context)) + "\"";
                sess += "}";
            }
            wss += "{\"id\":\"" + std::to_string(w) + "\",\"name\":\"" + jsonEscape(narrow(g_workspaces[w])) +
                   "\",\"active\":" + (w == g_activeWs ? "true" : "false") +
                   ",\"focused\":" + (w == g_focusWs ? "true" : "false") +
                   ",\"sessions\":[" + sess + "]}";
        }
        return ctlOk("{\"workspaces\":[" + wss + "]}");
    }
    if (cmd == "session.new") {
        // agwintermctl sends name/cwd/command and the full app honours all three; this dropped them
        // on the floor and handed back a session called "<pipe>-<n>". An agent asked to "run X in the
        // build session" then cannot find what it just made — not by the name it chose, and not in
        // the tree — which looks like the control API is broken rather than one argument ignored.
        std::string name = req.get("args.name");
        std::string cwd  = req.get("args.cwd");
        std::string command = req.get("args.command");

        // Which workspace to create into. Same arguments and the same precedence as the full app
        // (Program.ControlHost.cs NewSession, ControlServer.cs session.new), in one place:
        //   1. an explicit --workspace (an index, what `tree` publishes) or --workspace-name, refused
        //      when unknown (--create-workspace makes a missing name rather than falling back);
        //      BOTH given is refused before anything is created — two answers to "where?" are not
        //      ranked (before P2, --workspace silently won by being tested first);
        //   2. else the CALLER's workspace: `caller` is the pane that ran `session new` (the CLI
        //      sends its AGWINTERM_SESSION_ID), so an agent gets sessions next to itself however
        //      the user has clicked around meanwhile. Resolved by id only (callerWorkspace); a
        //      caller that does not resolve is NOT refused, it falls through;
        //   3. else the active workspace — the LAST answer, not the first. "Active" is a global the
        //      UI rewrites on every click, every selection and every workspace.new over the API, so
        //      an agent creating several sessions used to scatter them wherever the user had last
        //      clicked. That was a lite report, and it is what step 2 ends.
        // The CLI puts `caller` inside args (Program.cs: cargs["caller"], and cargs IS "args" on the
        // wire); a top-level `caller` is accepted too for a hand-written line. It is never the
        // target: session.new stays targetless, and a target would turn a stale value into "session
        // not found" instead of the fallback.
        int wantWs = -1;
        // The NAME of the workspace wantWs points at, captured with the index and re-found under the
        // lock after the create: an index is only valid until someone deletes an earlier workspace
        // (revmux r2). Empty when wantWs stays -1.
        std::wstring wantWsName;
        std::string wsArg = req.get("args.workspace");
        std::string wsName = req.get("args.workspace-name");
        std::string wsCreate = req.get("args.create-workspace");
        if (!wsArg.empty() && !wsName.empty())   // agwinterm's SessionNewWorkspaces.TwoSources, verbatim
            return ctlErr("session.new: --workspace '" + wsArg + "' and --workspace-name '" + wsName +
                          "' are two answers to one question; pass one of them. No session was created.");
        if (!wsArg.empty()) {
            bool digits = wsArg.find_first_not_of("0123456789") == std::string::npos;
            int n = digits ? atoi(wsArg.c_str()) : -1;
            { LockG hold; if (n >= 0 && n < (int)g_workspaces.size()) { wantWs = n; wantWsName = g_workspaces[n]; } }
            if (wantWs < 0) return ctlErr("no workspace '" + wsArg + "' (ids are the indices `tree` reports)");
        } else if (!wsName.empty()) {
            std::wstring want = widen(wsName);
            { LockG hold;
              for (int w = 0; w < (int)g_workspaces.size(); w++)
                  if (_wcsicmp(g_workspaces[w].c_str(), want.c_str()) == 0) { wantWs = w; wantWsName = g_workspaces[w]; break; } }
            if (wantWs < 0) {
                if (wsCreate != "true" && wsCreate != "1")
                    return ctlErr("no workspace named '" + wsName + "' (pass --create-workspace to make it)");
                // `tree` walks this vector under g_lock; the index is taken under the SAME hold, or two
                // concurrent creators both read the trailing size and are told the same number
                { LockG hold; g_workspaces.push_back(want); wantWs = (int)g_workspaces.size() - 1; wantWsName = want; }
            }
        } else {
            std::string caller = req.get("args.caller");
            if (caller.empty()) caller = req.get("caller");
            wantWs = callerWorkspace(caller, &wantWsName);   // -1 = fall through to the active workspace (step 3)
        }

        int cols, rows;
        newSessionGrid(g_focus, &cols, &rows);

        // --command runs it as the session's shell, which is the whole point: the caller wants the
        // command RUNNING, not typed into a prompt that may not be ready to receive it yet.
        std::vector<std::string> cargs;
        const char* app = nullptr;
        if (!command.empty()) {
            app = "powershell.exe";
            cargs.push_back("-NoExit");     // keep the pane alive after it finishes, like the full app
            cargs.push_back("-Command");
            cargs.push_back(command);
        }
        Session* s = newSession(cols, rows, app, cargs.empty() ? nullptr : &cargs,
                                cwd.empty() ? nullptr : cwd.c_str());
        if (!s) return ctlErr("create failed");
        // tsvField: the name reaches the state file, where a tab or newline would forge a record.
        if (!name.empty()) s->name = widen(tsvField(name));
        // Re-checked under the lock for all three sources of wantWs (--workspace, a created
        // --workspace-name, the caller's own). The INDEX is the answer and the name is only how a
        // shift is detected: the index was resolved BEFORE the host round trip that made the
        // session, and another client's workspace.delete erases a name and shifts every later index
        // down under g_lock in between. Checking only the RANGE (r1) left the worse half —
        // [A,B,C,D] with B deleted makes index 2 name D, so the session lands in a workspace nobody
        // asked for (r2). Re-resolving by NAME FIRST was worse still, because nothing keeps names
        // unique and the first match won (r3). So: the index if the name still sits there, else the
        // nearest match, else the active workspace with a log line.
        {
            LockG hold;
            if (wantWs >= 0) {
                // The INDEX is the answer; the name only detects that it moved. Re-resolving by name
                // first was worse than the range check it replaced: nothing keeps workspace names
                // unique (`workspace new --name dev` twice, or a delete making the generated
                // "workspace 3" repeat), so the first-match scan sent the session to a DIFFERENT
                // workspace with the same name, deterministically and unlogged (revmux r3).
                int found = -1;
                if (wantWs < (int)g_workspaces.size() && g_workspaces[wantWs] == wantWsName)
                    found = wantWs;                                  // nothing moved: the common path
                else
                    // It moved. Prefer the first match AT OR AFTER where it was; failing that the
                    // NEAREST one below, because a delete shifts indices down by as little as one
                    // and the first match in the list can be a different workspace that happens to
                    // share the name — `[A, dev, X, dev]` with X deleted leaves the target at 2,
                    // not at 1 (revmux r4).
                    for (int w = 0; w < (int)g_workspaces.size(); w++)
                        if (g_workspaces[w] == wantWsName) {
                            if (found < 0 || w >= wantWs || w > found) found = w;
                            if (w >= wantWs) break;
                        }
                if (found < 0)
                    logWarn("session.new: workspace '%s' is gone (deleted or renamed) since it was resolved; the session lands in the active one instead",
                            narrow(wantWsName).c_str());
                s->ws = found >= 0 ? found
                      : (g_activeWs >= 0 && g_activeWs < (int)g_workspaces.size() ? g_activeWs : 0);
            }
        }
        selectPrimary((int)g_sessions.size() - 1);
        InvalidateRect(g_hwnd, nullptr, FALSE);
        return ctlOkStr(s->id);
    }
    std::string targetWhy;
    Session* target = resolveTarget(req.get("target"), &targetWhy);
    if (cmd == "session.select") {
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        for (int i2 = 0; i2 < (int)g_sessions.size(); i2++)
            if (g_sessions[i2] == target) selectPrimary(i2);   // brings that session's own split
        // The sidebar highlight never followed an API select (pre-existing): the tree is rebuilt on
        // WM_APP_REFRESHTREE and nothing posted it here, so the previous session stayed highlighted
        // while a different one was on screen. Worth more now that selecting also changes the layout.
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        InvalidateRect(g_hwnd, nullptr, FALSE);
        return ctlOkStr("selected");
    }
    if (cmd == "session.type") {
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        std::string text = req.get("args.text");
        // \n → \r (keystroke semantics, like the main app's session.type)
        for (char& ch : text) if (ch == '\n') ch = '\r';
        // Every other control byte is REFUSED, not stripped. agterm hardened this in v0.25.0 after
        // a NUL truncated an injection while the call still answered ok - and because the text and
        // its Return are separate keystrokes, the shortened line got its Return and ran. Stripping
        // produces that same shortened line. TAB stays: completion is typing. A caller that MEANS
        // the byte passes allow-control. (NOT session.write: that injects into the emulator and
        // never reaches the shell, here as in the full app.)
        std::string allowCtl = req.get("args.allow-control");
        if (allowCtl != "true" && allowCtl != "1") {
            for (size_t bi = 0; bi < text.size(); bi++) {
                unsigned char uc = (unsigned char)text[bi];
                if ((uc >= ' ' && uc != 0x7f) || uc == '\r' || uc == '\t') continue;
                char emsg[176];
                sprintf_s(emsg, "session.type refuses control byte 0x%02X at index %u "
                                "(CR, LF and TAB are fine) - pass --allow-control if you mean it",
                          uc, (unsigned)bi);
                return ctlErr(emsg);
            }
        }
        if (target->data != INVALID_HANDLE_VALUE)
            ovIo(target->data, true, text.data(), nullptr, (DWORD)text.size());
        return ctlOkStr("typed");
    }
    if (cmd == "session.write") {
        // Feed bytes into the EMULATOR only - display injection, never the shell. Same meaning as
        // the full app (ISession.Inject): useful for painting into a pane, and useless as a way to
        // send keystrokes, which is exactly why session.type refuses control bytes instead of
        // pointing here.
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        std::string bytes = req.get("args.text");
        EnterCriticalSection(&g_lock);
        if (target->emu) emu_feed(target->emu, (const uint8_t*)bytes.data(), (uint32_t)bytes.size());
        LeaveCriticalSection(&g_lock);
        InvalidateRect(g_hwnd, nullptr, FALSE);
        return ctlOkStr("written");
    }
    if (cmd == "install.skill") return ctlOkStr(installAgentSkill());
    if (cmd == "events") {
        // Cursor-polled: pass the cursor from the previous reply as --since and get only what is
        // new. The reply always carries the CURRENT cursor, even when the list is empty, so a
        // caller that polls a quiet terminal still moves forward instead of re-reading history.
        long long since = atoll(req.get("args.since").c_str());
        int limit = atoi(req.get("args.limit").c_str());
        std::string items;
        long long cursor;
        EnterCriticalSection(&g_evtLock);
        cursor = g_evtSeq;
        int n = 0;
        for (const CtlEvent& e : g_evtLog) {
            if (e.seq <= since) continue;
            if (limit > 0 && n >= limit) break;
            if (n++) items += ",";
            items += "{\"seq\":" + std::to_string(e.seq) + ",\"type\":\"" + jsonEscape(e.type) + "\"";
            if (!e.session.empty()) items += ",\"session\":\"" + jsonEscape(e.session) + "\"";
            if (!e.info.empty()) items += ",\"info\":\"" + jsonEscape(e.info) + "\"";
            items += "}";
        }
        LeaveCriticalSection(&g_evtLock);
        return ctlOk("{\"cursor\":" + std::to_string(cursor) + ",\"events\":[" + items + "]}");
    }
    if (cmd == "session.output") {
        if (!target) return ctlErr("session not found");
        bool haveMarks = false;
        std::string res = lastCommandOutput(target, &haveMarks);
        if (!haveMarks) return ctlOkStr("no completed command marks (FTCS shell integration not active?)");
        return ctlOkStr(res);
    }
    if (cmd == "session.text") {
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        return ctlOkStr(dumpBufferText(target));
    }
    if (cmd == "surface.cursor") {
        // The caret COLUMN of the pane, as a bare JSON integer: {"ok":true,"result":<int>}. That is
        // agterm's shape and agwinterm's (P1, agwinterm #221), so a script written against either
        // product's cookbook works here unchanged; the conformance contract pins it as an integer.
        // Column 0 is a real answer, not "no answer" - it goes out as the number 0, never omitted.
        //
        // Column ONLY, deliberately. The question this exists to answer is "is that composer empty
        // before I type into it": the caret rests at a known column in an empty box, so a different
        // column means a draft is sitting there and the send must refuse. One number, one compare.
        // The row says nothing about that, and reporting it would only tempt callers into screen
        // geometry that the two products lay out differently.
        //
        // The target resolves exactly as session.text / session.type do (the shared resolveTarget
        // above), so the pane you CHECK is the pane you then TYPE INTO - a check against a different
        // pane would be worse than no check. A pane whose child has exited still answers: its grid
        // is still there to be read, and a caller deciding whether to type must get a number, not an
        // error. Only a target that no longer resolves is refused - a hidden split pane still
        // answers by id, though `tree` never lists it.
        //
        // Deferred wrap: after printing into the last column the core leaves the caret ONE PAST it
        // (== cols) and wraps on the next print. That is reported as it is, so a caller must not use
        // the value as a cell index without clamping. Same info.cursorCol the renderer paints from,
        // so WHEN a caret is painted it is this cell; none is painted at column == cols, in a
        // scrolled-back or unfocused pane, or while a selection is live (see paintPane).
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        FfiEmuInfo info{};
        EnterCriticalSection(&g_lock);
        bool have = target->emu && emu_info(target->emu, &info);
        LeaveCriticalSection(&g_lock);
        if (!have) return ctlErr("no emulator behind that session");   // cannot happen for a listed session; refuse rather than invent a 0
        return ctlOk(std::to_string(info.cursorCol));
    }
    if (cmd == "session.status") {
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        std::string st = req.get("args.status");
        if (st.empty()) return ctlErr("session status needs a state");
        setStatus(target, st);
        emitEvent("status", target->id, st);
        InvalidateRect(g_hwnd, nullptr, FALSE);
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);   // update the tree's status label
        return ctlOkStr("status set");
    }
    if (cmd == "session.close") {
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        // Close the session that was ASKED for, by index. The old form pointed the focused pane at it
        // and called closeFocused(), which with the split pane focused reroutes into toggleSplit() —
        // so it killed the repointed target through the unsplit path, ORPHANING the hidden split
        // shell (a live process with no pane, no tree entry and no kill until exit) and skipping
        // everything closeSessionAt does: the reopen stack, the deliberate-empty mark, the teardown.
        for (int i2 = 0; i2 < (int)g_sessions.size(); i2++)
            if (g_sessions[i2] == target) {
                if (g_pane[1] == i2) toggleSplit();   // it IS the split pane's shell: closing it unsplits
                else closeSessionAt(i2);
                break;
            }
        return ctlOkStr("closed");
    }
    if (cmd == "session.overlay") {   // run a command in an overlay popup over the main window
        // P2-lite. Every branch that does not do what was asked answers ctlErr, and a refusal
        // leaves the world untouched: before this, `--size-percent` was read from the wrong key
        // (`size`, which the CLI never sends) so every N was ignored; an unknown action fell
        // through to open; open with no command opened a plain shell; the target was never read;
        // close with nothing open said "closed". The wordings are agwinterm's — the unit suites
        // there assert them, and one API gives one answer.
        std::string action = req.get("args.action");
        if (action.empty()) action = "open";
        if (action != "open" && action != "close" && action != "resize")
            return ctlErr("overlay action '" + action + "' is not one of open, close, resize; nothing done");
        // --size-percent: validated, not clamped. Absent -> 0 -> lite's default popup (70 % of the
        // client area; openOverlay says why that differs from agwinterm's full region). Present ->
        // all digits in 1..100, else refused naming the value, the range and the way to get the
        // default. JsonReq::get answers "" for absent AND empty, so presence is read from the map.
        // The parser keeps a number as its raw text and a string as its content, so a quoted "60"
        // arrives as 60 and is accepted — lite cannot see the JSON kind; the CLI never sends a
        // string (it refuses a non-number client-side, agwinterm Program.cs), and anything that is
        // not all digits ("sixty", 60.5, -5, true) is refused here.
        int sizePct = 0;
        auto sp = req.fields.find("args.size-percent");
        if (sp != req.fields.end()) {
            const std::string& raw = sp->second;
            bool digits = !raw.empty() && raw.size() <= 3;
            for (char c : raw) if (c < '0' || c > '9') digits = false;
            int n = digits ? atoi(raw.c_str()) : 0;
            if (!digits || n < 1 || n > 100)
                return ctlErr("size-percent " + (raw.empty() ? std::string("\"\"") : raw) +
                              " is not a whole number in 1..100; omit --size-percent to use the default popup size");
            sizePct = n;
        }
        // The percentage IN EFFECT: what was asked for — or lite's default when the flag was
        // absent, which is raised by the same rule and was not before (revmux r2) — unless the
        // 30x8-cell popup minimum is bigger, in which case that is what the caller gets and what
        // the reply says. Never silently the caller's own number for a popup that is not that size.
        int rawMin = overlayMinPercentRaw();
        int effectivePct = sizePct > 0 ? sizePct : (int)(kOverlayDefaultFraction * 100);
        if (rawMin > 0 && rawMin <= 100 && effectivePct < rawMin) effectivePct = rawMin;
        std::string command = req.get("args.command");
        // The command is checked BEFORE the target (agwinterm's order; its fake host asserts it).
        if (action == "open" && command.empty()) return ctlErr("overlay open needs a command; nothing opened");
        // A NAMED target (not empty, not `active`) that resolves to no session is refused for all
        // three actions with one wording: the overlay the caller meant may still be up, and ok
        // would say it is gone. lite's overlay is a window-level popup, not per-session, so a
        // target that DOES resolve is accepted whichever session it names — the popup covers the
        // main window either way. Empty / `active` stays accepted even with no active session, so
        // a bare close in an empty window is not contract-dependent on a session existing.
        const std::string& tgt = req.get("target");
        if (!tgt.empty() && tgt != "active" && !target)
            return ctlErr(targetWhy.empty() ? "no session matches that target; nothing opened, resized or closed" : targetWhy);
        // g_overlayHwnd is written on the UI thread; this read is the same one close always made.
        // The user can close the popup by hand between this read and the posted message running —
        // resizeOverlay then does nothing, and the caller's next `resize` is refused truthfully.
        bool open = g_overlayHwnd != nullptr;
        if (action == "close") {
            if (!open) return ctlOkStr("no overlay");   // idempotent: "no overlay open" is true afterwards
            PostMessageW(g_overlayHwnd, WM_CLOSE, 0, 0);
            return ctlOkStr("closed");
        }
        if (action == "resize") {
            if (!open) return ctlErr("no overlay to resize on that target; open one first");
            // effectivePct, never 0: with the flag absent it is exactly lite's default (70), so
            // overlayFraction gives the same fraction it always did — and when the floor raised it,
            // the popup is built from the number the reply just named. Posting 0 here meant
            // openOverlay re-derived 70 % and only the binding AXIS got the floor, so a reply saying
            // "80%" could describe a popup 80 % wide and 70 % tall (revmux r3).
            auto* rq = new OverlayReq{ std::string(), effectivePct };
            if (!PostMessageW(g_hwnd, WM_APP_OVERLAY, OVL_RESIZE, (LPARAM)rq)) { delete rq; return ctlErr("the window is closing; nothing was resized"); }
            // The size IN EFFECT, never the number asked for when the popup will not have it.
            // "resized N%" (the documented shape) on a window that can answer; otherwise what it
            // got and why.
            return ctlOkStr(overlaySizeIsPercent(rawMin) ? "resized " + std::to_string(effectivePct) + "%"
                                                         : "resized to " + overlaySizeReason(rawMin));
        }
        auto* rq = new OverlayReq{ command, effectivePct };   // the number the reply names (see resize above)
        if (!PostMessageW(g_hwnd, WM_APP_OVERLAY, OVL_OPEN, (LPARAM)rq)) { delete rq; return ctlErr("the window is closing; nothing was opened"); }
        // A status word carrying the size IN EFFECT, not the overlay's session id: the session does
        // not exist yet when this reply is written (it is created by the posted message). Known gap,
        // written down in the plan; the contract pins only that the reply is a string.
        return ctlOkStr("overlay opened at " + (overlaySizeIsPercent(rawMin) ? std::to_string(effectivePct) + "%"
                                                                              : overlaySizeReason(rawMin)));
    }
    // ---- agwintermctl-dialect verbs over the features lite has -------------------------------
    auto wsResolve = [&](const std::string& sel, bool defaultActive) -> int {
        if (sel.empty() || sel == "active") return defaultActive ? g_activeWs : -1;
        bool num = !sel.empty();
        for (char c : sel) if (!isdigit((unsigned char)c)) { num = false; break; }
        if (num) { int i2 = atoi(sel.c_str()); return (i2 >= 0 && i2 < (int)g_workspaces.size()) ? i2 : -1; }
        std::wstring want = widen(sel);
        for (auto& c : want) c = (wchar_t)towlower(c);
        for (int i2 = 0; i2 < (int)g_workspaces.size(); i2++) {
            std::wstring n = g_workspaces[i2];
            for (auto& c : n) c = (wchar_t)towlower(c);
            if (n == want || n.find(want) != std::wstring::npos) return i2;
        }
        return -1;
    };
    auto idxOf = [&](Session* s) -> int {
        for (int i2 = 0; i2 < (int)g_sessions.size(); i2++) if (g_sessions[i2] == s) return i2;
        return -1;
    };
    auto selectIdx = [&](int i2) {   // the tree-click effects, control-thread safe
        selectPrimary(i2); g_activeWs = g_sessions[i2]->ws;
        syncPaneSizes();
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        InvalidateRect(g_hwnd, nullptr, FALSE);
    };
    auto wantOn = [&](const std::string& op, bool cur) { return op == "on" ? true : op == "off" ? false : !cur; };

    if (cmd == "session.flag") {   // op: on|off|toggle|clear (clear = unflag everything)
        std::string op = req.get("args.op");
        if (op == "clear") {
            for (auto* s : g_sessions) s->flagged = false;
            PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
            return ctlOkStr("cleared");
        }
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        target->flagged = wantOn(op, target->flagged);
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        return ctlOkStr(target->flagged ? "flagged" : "unflagged");
    }
    if (cmd == "session.seen") {   // clear the unread badge
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        EnterCriticalSection(&g_lock);
        target->seenDone = completedMarks(target);
        target->unread = 0;
        LeaveCriticalSection(&g_lock);
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        return ctlOkStr("seen");
    }
    if (cmd == "session.rename") {
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        std::string nm = req.get("args.name");
        if (nm.empty()) return ctlErr("rename needs a name");
        {   // under g_lock: `tree` and resolveTarget read the name on other threads (a std::wstring
            // reassignment frees the old buffer once the name outgrows the small-string buffer)
            LockG hold;
            // The name and the context (session.context, below) are two separate fields: a rename
            // writes this one and leaves `context` exactly as it was, and neither is derived from
            // the other.
            target->name = widen(tsvField(nm));   // JSON carries \t and \n; a name is one line (see tsvField)
        }
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        return ctlOkStr("renamed");
    }
    if (cmd == "session.context") {   // P3: one line of "what is this pane for", per session
        // The value is read from the field map, not from get(): get() answers "" for absent AND
        // for a present empty string, and the two are different verbs here — absent with --clear is
        // a clear, present-empty is the blank refusal, present beside --clear is TextAndClear.
        // `--clear` arrives as the raw token `true` (the CLI sends a JSON boolean; the parser keeps
        // a non-string as its text), so this is a comparison against that token, never against the
        // value of some string field (agwinterm #234 item 6 is the bug that comparison makes).
        auto cf = req.fields.find("args.context");
        bool haveText = cf != req.fields.end();
        bool clear = req.get("args.clear") == "true";
        if (clear && haveText) return ctlErr(kContextTextAndClear);
        std::string text;
        if (!clear) {
            // A missing text with no --clear is the blank refusal, with --clear named as the way
            // to remove one (SessionContexts.TryNormalize: a null raw is "" and "" is blank).
            std::string why = contextRefusal(haveText ? cf->second : std::string(), &text);
            if (!why.empty()) return ctlErr(why);
        }
        // Target refusals come AFTER the text rules, as in agwinterm (the server validates before
        // the host is reached), so a bad value on a bad target names the value.
        if (!target) return ctlErr(targetWhy.empty() ? kContextNoSession : targetWhy);
        {
            LockG hold;
            // resolveTarget handed back a pointer without a lock across the two calls: re-check the
            // session is still in the list before writing through it (#21's defect class), and
            // answer "not found" if it closed in between — exactly what agwinterm's in-hop lookup
            // does.
            if (indexOfSession(target) < 0) return ctlErr(kContextNoSession);
            // A hidden session — a split shell, a quick, scratch or overlay cover — is reachable by
            // id through resolveTarget, but it has no sidebar row to draw the context in, no `S` line
            // and therefore no `C` slot to save it under: accepting would answer ok:true for a value
            // that is shown nowhere and gone at the next start. Refused for the reason
            // restore.capture refuses a cover pane (RestoreCaptureReply.CoverPane's rule), naming
            // the id. The value is untouched (a hidden session never has one).
            if (target->hidden)
                return ctlErr("session context: '" + target->id + "' is a split, scratch, overlay or quick pane, "
                              "which has no sidebar row and is never restored, so it has no context to set. Nothing changed.");
            target->context = clear ? std::wstring() : widen(text);
            // The reply is read BACK from the session under the same hold — the value in effect,
            // not an echo of the request (agwinterm's SessionContexts.Reply is built from ses.Context).
            std::string reply = "{\"session\":\"" + jsonEscape(target->id) + "\",\"context\":" +
                                (target->context.empty() ? std::string("null")
                                                         : "\"" + jsonEscape(narrow(target->context)) + "\"") + "}";
            PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);   // the row (task 2) and the save
            return ctlOk(reply);
        }
    }
    if (cmd == "session.duplicate") {   // clone the target's launch spec into its workspace
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        int cols, rows; newSessionGrid(0, &cols, &rows);
        g_activeWs = target->ws;
        std::string app = target->app; std::vector<std::string> targs = target->args; std::string cwd = target->cwd;
        Session* s = newSession(cols, rows, app.empty() ? nullptr : app.c_str(),
                                targs.empty() ? nullptr : &targs, cwd.empty() ? nullptr : cwd.c_str());
        if (!s) return ctlErr("create failed");
        selectIdx((int)g_sessions.size() - 1);
        return ctlOkStr(s->id);
    }
    if (cmd == "session.split") {   // op: on|off|toggle over the window's second pane
        // Returns the split pane's SESSION ID, because a pane an agent cannot address is a pane it
        // cannot use. The split shell is hidden — it never appears in the tree and has no name — so
        // the id handed back here is the only way to reach it. Without it, `session type` with no
        // --target falls back to $AGWINTERM_SESSION_ID, which for an agent running INSIDE a session
        // is its own pane: the launch command lands in the agent's own prompt instead of the pane
        // that was just opened.
        //
        // Created here rather than by posting IDM_SPLIT, for the same reason session.new does it
        // here: a posted message is asynchronous and there would be nothing to return.
        int p0 = g_pane[0];
        Session* prim = (p0 >= 0 && p0 < (int)g_sessions.size()) ? g_sessions[p0] : nullptr;
        if (!prim) return ctlErr("no session to split");
        bool cur = g_pane[1] >= 0;
        bool want = wantOn(req.get("args.op"), cur);
        if (want && !cur) {
            int c, r;
            newSessionGrid(1, &c, &r);        // approximate; syncPaneSizes fixes both below
            Session* s = newSession(c, r);
            if (!s) return ctlErr("split failed");
            s->hidden = true;               // a split shell, not a tree session
            prim->splitId = s->id;          // ...and it belongs to the session being split, so it
                                            // travels with it when the user switches away and back
            g_pane[1] = (int)g_sessions.size() - 1;
            // Focus deliberately NOT moved: the menu split is a human asking to type over there,
            // but an API split is an agent opening a pane beside a user who is still typing.
            syncPaneSizes();
            PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
            InvalidateRect(g_hwnd, nullptr, FALSE);
            return ctlOkStr(s->id);
        }
        if (!want && cur) { PostMessageW(g_hwnd, WM_COMMAND, IDM_SPLIT, 0); return ctlOkStr("ok"); }
        // Already in the requested state — still hand back the id, so a caller that does not know
        // whether it split gets something addressable either way.
        if (cur && g_pane[1] >= 0 && g_pane[1] < (int)g_sessions.size())
            return ctlOkStr(g_sessions[g_pane[1]]->id);
        return ctlOkStr("ok");
    }
    if (cmd == "session.scratch" || cmd == "quick") {   // op on|off|toggle (window creation -> UI thread)
        bool scratch = (cmd == "session.scratch");
        HWND hw = scratch ? g_scratchHwnd : g_quickHwnd;
        bool cur = hw && IsWindowVisible(hw);
        if (wantOn(req.get("args.op"), cur) != cur)
            PostMessageW(g_hwnd, WM_COMMAND, scratch ? IDM_SCRATCH : IDM_QUICK, 0);
        return ctlOkStr("ok");
    }
    if (cmd == "session.move") {   // workspace <sel> = relocate; dir up|down = reorder within its workspace
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        int from = idxOf(target);
        std::string wsSel = req.get("args.workspace");
        if (!wsSel.empty()) {
            int w = wsResolve(wsSel, false);
            if (w < 0) return ctlErr("workspace not found");
            moveSessionTo(from, w, -1);
            return ctlOkStr("moved");
        }
        std::string dir = req.get("args.dir");
        int step = (dir == "up") ? -1 : 1;
        for (int j = from + step; j >= 0 && j < (int)g_sessions.size(); j += step) {
            if (g_sessions[j]->ws != target->ws || g_sessions[j]->hidden) continue;
            moveSessionTo(from, target->ws, step < 0 ? j : (j + 1 < (int)g_sessions.size() ? j + 1 : -1));
            return ctlOkStr("moved");
        }
        return ctlOkStr("unchanged");   // already at the edge
    }
    if (cmd == "session.copy") {   // the selection's text (the selection belongs to one session)
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        if (!g_sel.isFor(target)) return ctlOkStr("");
        return ctlOkStr(selectionText());
    }
    if (cmd == "session.paste") {   // paste text (or the clipboard) into the target
        if (!target) return ctlErr(targetWhy.empty() ? "session not found" : targetWhy);
        std::string text = req.get("args.text");
        if (text.empty() && OpenClipboard(nullptr)) {   // no text -> clipboard contents
            if (HANDLE h = GetClipboardData(CF_UNICODETEXT)) {
                if (const wchar_t* wz = (const wchar_t*)GlobalLock(h)) { text = narrow(wz); GlobalUnlock(h); }
            }
            CloseClipboard();
        }
        // Same normalisation + bracketing as Ctrl+V (the main app shares one PasteTextInto for both);
        // this used to map \n -> \r WITHOUT collapsing CRLF, so clipboard text arrived as \r\r.
        text = pasteNormalize(std::move(text));
        if (!text.empty() && target->data != INVALID_HANDLE_VALUE) {
            FfiEmuInfo pinfo{};
            EnterCriticalSection(&g_lock);
            emu_info(target->emu, &pinfo);
            LeaveCriticalSection(&g_lock);
            if (pinfo.bracketedPaste) ovIo(target->data, true, "\x1b[200~", nullptr, 6);
            ovIo(target->data, true, text.data(), nullptr, (DWORD)text.size());
            if (pinfo.bracketedPaste) ovIo(target->data, true, "\x1b[201~", nullptr, 6);
        }
        return ctlOkStr("pasted");
    }
    if (cmd == "session.go") {   // dir: next|prev|first|last|next-attention|prev-attention
        std::string dir = req.get("args.dir");
        std::vector<int> vis;
        for (int i2 = 0; i2 < (int)g_sessions.size(); i2++)
            if (!g_sessions[i2]->hidden && !g_sessions[i2]->exited) vis.push_back(i2);
        if (vis.empty()) return ctlErr("no sessions");
        int cur = g_pane[0], pos = 0;
        for (int k = 0; k < (int)vis.size(); k++) if (vis[k] == cur) pos = k;
        int pick = -1;
        if (dir == "first") pick = vis.front();
        else if (dir == "last") pick = vis.back();
        else if (dir == "prev") pick = vis[(pos - 1 + (int)vis.size()) % vis.size()];
        else if (dir == "next-attention" || dir == "prev-attention") {
            int step = (dir[0] == 'p') ? -1 : 1;
            for (int k = 1; k <= (int)vis.size(); k++) {
                int i2 = vis[(pos + step * k % (int)vis.size() + (int)vis.size()) % vis.size()];
                if (statusClass(statusOf(g_sessions[i2]).status) == AGST_BLOCKED) { pick = i2; break; }
            }
            if (pick < 0) return ctlOkStr("none blocked");
        } else pick = vis[(pos + 1) % vis.size()];   // next (default)
        selectIdx(pick);
        return ctlOkStr(g_sessions[pick]->id);
    }
    if (cmd == "workspace.new") {
        std::string nm = req.get("args.name");
        int made;
        {   // under g_lock: `tree` (another pipe thread) and refreshTree walk this vector under it;
            // a push_back that reallocates frees the std::wstring array they are reading. The index
            // is taken under the same hold: two concurrent creators must not both be told the
            // trailing one, and the reply must name the workspace THIS call made.
            LockG hold;
            g_workspaces.push_back(nm.empty() ? (L"workspace " + std::to_wstring(g_workspaces.size() + 1)) : widen(nm));
            made = (int)g_workspaces.size() - 1;
            g_activeWs = made;
        }
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        return ctlOkStr(std::to_string(made));
    }
    if (cmd == "workspace.rename") {
        int w = wsResolve(req.get("target"), true);
        std::string nm = req.get("args.name");
        if (w < 0) return ctlErr("workspace not found");
        if (nm.empty()) return ctlErr("rename needs a name");
        { LockG hold; g_workspaces[w] = widen(tsvField(nm)); }   // read under g_lock by `tree`
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        return ctlOkStr("renamed");
    }
    if (cmd == "workspace.delete") {
        int w = wsResolve(req.get("target"), true);
        if (w < 0) return ctlErr("workspace not found");
        if ((int)g_workspaces.size() <= 1) return ctlErr("cannot delete the last workspace");
        deleteWorkspace(w);
        return ctlOkStr("deleted");
    }
    if (cmd == "workspace.select") {
        int w = wsResolve(req.get("target"), false);
        if (w < 0) return ctlErr("workspace not found");
        g_activeWs = w;
        PostMessageW(g_hwnd, WM_APP_REFRESHTREE, 0, 0);
        return ctlOkStr("selected");
    }
    if (cmd == "workspace.focus") {   // op on|off|toggle, acts on the active workspace
        std::string op = req.get("args.op");
        bool cur = g_focusWs >= 0;
        bool want = wantOn(op, cur);
        if (want != cur) toggleFocusWs(want ? g_activeWs : g_focusWs);
        return ctlOkStr(g_focusWs >= 0 ? "focused" : "unfocused");
    }
    if (cmd == "workspace.collapse" || cmd == "workspace.expand") {
        int w = wsResolve(req.get("target"), true);
        if (w < 0) return ctlErr("workspace not found");
        for (HTREEITEM it = TreeView_GetRoot(g_tree); it; it = TreeView_GetNextSibling(g_tree, it)) {
            TVITEMW ti{}; ti.mask = TVIF_PARAM; ti.hItem = it;
            TreeView_GetItem(g_tree, &ti);
            if (ti.lParam == -(w + 1)) { TreeView_Expand(g_tree, it, cmd == "workspace.expand" ? TVE_EXPAND : TVE_COLLAPSE); break; }
        }
        return ctlOkStr("ok");
    }
    if (cmd == "sidebar") {   // op show|hide|toggle|state|width (on/off = show/hide)
        // P2 (agwinterm #226 mirror). This used to run every op through wantOn, which treats
        // anything that is not `on`/`off` as "toggle": `sidebar width`, `sidebar state`, `sidebar
        // show` and a typo all FLIPPED the sidebar and answered ok. Now an explicit table, and an
        // op that is not in it is refused and changes nothing. The wordings are agwinterm's, minus
        // the ops lite does not have (expand/collapse/mode). Absent op: the CLI sends `toggle`, and
        // the raw-pipe "" is read the same way (JsonReq::get cannot tell absent from empty).
        std::string op = req.get("args.op");
        if (op.empty() || op == "on") op = op.empty() ? "toggle" : "show";
        else if (op == "off") op = "hide";
        // `width` is the width IN EFFECT: the caller compares what it asked for with what it got,
        // which is how a request the window could not honour (a 900 sidebar in a 600 px client) is
        // told apart from an honoured one. The remembered PREFERENCE is what a set that could not
        // be applied reports, and what a later widen restores to — never a transient fit.
        auto sidebarJson = [&](bool withApplied, bool applied = true, const char* note = nullptr) {   // {width, visible[, applied[, note]]}
            int shown = applied && g_showSidebar ? g_sidebarW : g_sidebarWPref;
            std::string j = "{\"width\":" + std::to_string(shown) +
                            ",\"visible\":" + (g_showSidebar ? "true" : "false");
            if (withApplied) {
                j += std::string(",\"applied\":") + (applied ? "true" : "false");
                if (note) j += std::string(",\"note\":\"") + note + "\"";
            }
            return j + "}";
        };
        // `state` is not in the cross-product contract (agwinterm's is a string with a mode lite
        // has no equivalent of); an object with the visibility AND the width is the honest shape
        // here, the same one `width` answers so a reader has one parser.
        if (op == "state") return ctlOk(sidebarJson(false, g_showSidebar));
        if (op == "width") {
            // The strict reader, the shape --size-percent has: absent -> a read; present and all
            // digits in kSidebarMinW..kSidebarMaxW -> a set; anything else (0, -5, 901, 60.5, a
            // string, a boolean) -> refused naming the value and the range. Presence comes from the
            // field map, and a quoted "300" is indistinguishable from 300 to this parser (the CLI
            // never sends a string; it refuses a non-number on its own side).
            auto wf = req.fields.find("args.width");
            if (wf == req.fields.end()) return ctlOk(sidebarJson(false, g_showSidebar));
            const std::string& raw = wf->second;
            bool digits = !raw.empty() && raw.size() <= 4;
            for (char c : raw) if (c < '0' || c > '9') digits = false;
            int want = digits ? atoi(raw.c_str()) : 0;
            if (!digits || want < kSidebarMinW || want > kSidebarMaxW)
                return ctlErr("sidebar width " + (raw.empty() ? std::string("\"\"") : raw) + " is not a whole number in " +
                              std::to_string(kSidebarMinW) + ".." + std::to_string(kSidebarMaxW) +
                              " (pixels); `sidebar width` with no value reads the current width, `sidebar hide` hides it. Nothing changed.");
            // The second limit, against the LIVE client width: in range for the sidebar is not the
            // same as leaving room for a terminal. Named separately from the range refusal above, so
            // the caller knows whether to ask for less or to widen the window. Checked whether or
            // not the sidebar is shown — a remembered width would hit the same wall on `show`.
            // GetClientRect is a plain read, safe from this thread.
            RECT c{}; GetClientRect(g_hwnd, &c);
            // A minimised window has a 0x0 client, so EVERY width in range would fail the live
            // check with advice the caller cannot follow ("widen the window" — no verb can). Store
            // it, say it is not applied, and let OnSize's fitSidebarToClient decide at the first
            // real layout after the restore — the same shape the hidden-sidebar branch uses, and
            // the same "do not act now" paneGridSize answers for a non-viable rect.
            bool viable = !IsIconic(g_hwnd) && c.right > 0;
            int content = (int)c.right - (want + kSplitterW), minContent = kMinContentCols * g_cw;
            if (viable && want > maxSidebarW((int)c.right))   // == content < minContent; one rule with OnSize and the drag
                return ctlErr("sidebar width " + raw + " would leave " + std::to_string(content < 0 ? 0 : content) +
                              " px for the terminal in a " + std::to_string(c.right) + " px window, under the " +
                              std::to_string(kMinContentCols) + "-column minimum (" + std::to_string(minContent) +
                              " px at this font); widen the window or ask for less. Nothing changed.");
            // Store the PREFERENCE here (the same write the splitter drag makes; the layout that
            // consumes it is posted, never run from this thread), so the reply and the next read
            // agree at once. fitSidebarToClient derives what is in effect from it.
            g_sidebarWPref = want;
            if (viable && g_showSidebar) g_sidebarW = want;
            PostMessageW(g_hwnd, WM_APP_SIDEBARW, 0, 0);
            if (!viable)
                return ctlOk(sidebarJson(true, false, "window is minimised: width remembered, not applied; it takes effect on the next layout"));
            if (!g_showSidebar)
                return ctlOk(sidebarJson(true, false, "sidebar is hidden: width remembered, not applied; it takes effect on the next `sidebar show`"));
            return ctlOk(sidebarJson(true));
        }
        if (op != "show" && op != "hide" && op != "toggle")
            return ctlErr("sidebar: unknown op '" + op + "'. One of: show|hide|toggle|state|width (on/off = show/hide). Nothing changed.");
        bool cur = g_showSidebar;
        bool want = op == "show" ? true : op == "hide" ? false : !cur;
        if (want != cur) PostMessageW(g_hwnd, WM_COMMAND, IDM_TG_SIDEBAR, 0);
        return ctlOkStr("ok");
    }
    // ---- window.* — each lite window is a process; the instance registry is the "library" ------
    if (cmd.rfind("window.", 0) == 0) {
        auto insts = listInstances();
        std::wstring sel = widen(req.get("target"));
        if (cmd == "window.list") {
            HWND fg = GetForegroundWindow();
            std::string out;
            for (size_t i2 = 0; i2 < insts.size(); i2++) {
                if (i2) out += ",";
                out += "{\"id\":\"" + jsonEscape(narrow(insts[i2].name)) +
                       "\",\"name\":\"" + jsonEscape(narrow(insts[i2].name)) +
                       "\",\"open\":true,\"active\":" + (insts[i2].hwnd == fg ? "true" : "false") + "}";
            }
            // WRAPPED in an object, matching agwinterm: a bare array breaks every script that reads
            // .result.windows, and "same control API" is the promise this product ships on.
            return ctlOk("{\"windows\":[" + out + "]}");
        }
        if (cmd == "window.new") {
            std::wstring nm = widen(req.get("args.name"));
            // Sanitize BEFORE the duplicate check and before building the command line: the child
            // will do it anyway, so an unsanitized name here would be compared against (and
            // returned instead of) the name the new window actually registers under.
            if (!nm.empty()) nm = sanitizeInstanceName(nm);
            if (nm.empty()) {   // pick a free name
                for (int n = 2;; n++) {
                    nm = L"win-" + std::to_wstring(n);
                    if (!findInstance(insts, nm)) break;
                }
            } else if (findInstance(insts, nm)) return ctlErr("window '" + narrow(nm) + "' already exists");
            wchar_t exe[MAX_PATH];
            GetModuleFileNameW(nullptr, exe, MAX_PATH);
            // Quote the name: unquoted, "my win" would reach the child as two args and it would come
            // up as instance "my" while the caller is told it got "my win".
            std::wstring cl = L"\"" + std::wstring(exe) + L"\" --pipe \"" + nm + L"\"";
            STARTUPINFOW si{ sizeof si }; PROCESS_INFORMATION pi{};
            std::vector<wchar_t> buf(cl.begin(), cl.end()); buf.push_back(0);
            if (!CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi))
                return ctlErr("spawn failed");
            CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
            return ctlOkStr(narrow(nm));
        }
        const InstanceInfo* w = findInstance(insts, sel);
        if (!w) return ctlErr("window not found");
        if (cmd == "window.select") {
            // The raise IS this verb's purpose, so it is made unconditionally (not raiseIfAllowed) —
            // but Windows decides whether a process that is not in the foreground may take it, and
            // it refuses while the user is working in another app. The reply says what happened
            // (#24, the same defect class as the rest of this batch: `selected` was answered
            // whether or not the window came to the front). The truth is GetForegroundWindow
            // afterwards, polled briefly because activation of another instance's window lands on
            // that instance's thread; SetForegroundWindow's own return is not trusted.
            // The refused case stays `ok` with a DIFFERENT string, not ctlErr: the cross-product
            // contract pins window.select on an existing window as ok + string (agwinterm answers
            // `selected` unconditionally there), and ok:false here would make one script behave
            // differently against the two products on a busy desktop. `selected` is answered only
            // when it is true; a caller reads the result, not just ok. ok:false is "window not found".
            bool wasIconic = IsIconic(w->hwnd) != FALSE;
            if (wasIconic) ShowWindow(w->hwnd, SW_RESTORE);
            SetForegroundWindow(w->hwnd);
            bool granted = false;
            for (int i = 0; i < 12 && !granted; i++) {
                granted = GetForegroundWindow() == w->hwnd;
                if (!granted) Sleep(20);
            }
            if (granted) return ctlOkStr("selected");
            FlashWindow(w->hwnd, TRUE);   // what Windows does for a refused raise; made explicit
            return ctlOkStr("not raised: window '" + narrow(w->name) + "' was not brought to the front, Windows kept the "
                            "foreground with another process (the raise was refused" +
                            std::string(wasIconic ? "; the window was restored from the taskbar" : "") +
                            "). Its taskbar button flashes instead.");
        }
        if (cmd == "window.close" || cmd == "window.delete") {
            std::wstring nm = w->name;   // copy before the instance dies
            PostMessageW(w->hwnd, WM_CLOSE, 0, 0);
            if (cmd == "window.delete" && lstrcmpiW(nm.c_str(), kAppId) != 0) {
                // The name becomes a FILENAME here, and it arrives from the HKCU instance registry —
                // which an older build, or a hand edit, can have written unsanitized. "..\..\x" would
                // then delete outside the state directory. Only ever delete state belonging to a name
                // this build would itself have registered; the window is closed either way.
                if (sanitizeInstanceName(nm) != nm)
                    return ctlErr("window '" + narrow(nm) + "' was closed, but its name is not one "
                                  "this build would create, so its state file was left alone");
                Sleep(800);   // let it finish its teardown writes, then drop its saved state
                wchar_t base[MAX_PATH];
                if (GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH)) {
                    std::wstring f = stateDir() + L"\\sessions-" + nm + L".tsv";
                    // The .bak too, or restore's fallback brings the deleted window's sessions
                    // straight back on the next --pipe <name>; the .tmp so no wreckage is left.
                    DeleteFileW(f.c_str());
                    DeleteFileW((f + L".bak").c_str());
                    DeleteFileW((f + L".tmp").c_str());
                }
            }
            return ctlOkStr(cmd == "window.delete" ? "deleted" : "closed");
        }
        if (cmd == "window.rename") {   // identity is the pipe name; rename retitles the window
            std::string nm = req.get("args.name");
            if (nm.empty()) return ctlErr("rename needs a name");
            SetWindowTextW(w->hwnd, (L"agliteterm \x2014 " + widen(nm)).c_str());
            return ctlOkStr("renamed");
        }
        if (cmd == "window.zoom") {
            ShowWindow(w->hwnd, IsZoomed(w->hwnd) ? SW_RESTORE : SW_MAXIMIZE);
            return ctlOkStr(IsZoomed(w->hwnd) ? "maximized" : "restored");
        }
        if (cmd == "window.move" || cmd == "window.resize") {
            RECT rc; GetWindowRect(w->hwnd, &rc);
            int x = rc.left, y = rc.top, cw = rc.right - rc.left, chh = rc.bottom - rc.top;
            std::string sx = req.get("args.x"), sy = req.get("args.y"), sw = req.get("args.w"), sh = req.get("args.h");
            if (!sx.empty()) x = atoi(sx.c_str());
            if (!sy.empty()) y = atoi(sy.c_str());
            if (!sw.empty()) cw = atoi(sw.c_str());
            if (!sh.empty()) chh = atoi(sh.c_str());
            SetWindowPos(w->hwnd, nullptr, x, y, cw, chh, SWP_NOZORDER | SWP_NOACTIVATE);
            return ctlOkStr("ok");
        }
        if (cmd == "window.state") {
            // agwinterm answers this for any window because all its windows share one process. Here
            // each window IS a process, so the UI flags of another instance are not ours to report —
            // asking it on its own pipe is the honest answer, not this window's flags with its name.
            if (w->hwnd != g_hwnd)
                return ctlErr("window '" + narrow(w->name) + "' is a separate process; ask it on its "
                              "own pipe (agwintermctl --pipe " + narrow(w->name) + " window state)");
            RECT rc; GetWindowRect(w->hwnd, &rc);
            const std::wstring& aws = (g_activeWs >= 0 && g_activeWs < (int)g_workspaces.size())
                                    ? g_workspaces[g_activeWs] : g_workspaces[0];
            Session* fs = focusedSession();
            return ctlOk(std::string("{") +
                         "\"sidebarVisible\":" + (g_showSidebar ? "true" : "false") +
                         // Always false, and not a stub: this client has no fullscreen mode at all,
                         // so the field is reported honestly rather than omitted from the contract.
                         ",\"fullscreen\":false"
                         ",\"maximized\":" + (IsZoomed(w->hwnd) ? "true" : "false") +
                         ",\"quickTerminalVisible\":" + ((g_quickHwnd && IsWindowVisible(g_quickHwnd)) ? "true" : "false") +
                         ",\"activeWorkspace\":\"" + jsonEscape(narrow(aws)) + "\"" +
                         ",\"activeSession\":\"" + jsonEscape(fs ? narrow(fs->name) : std::string()) + "\"" +
                         // Beyond the contract, and kept: the geometry is what a tiling script wants,
                         // and extra fields are allowed.
                         ",\"name\":\"" + jsonEscape(narrow(w->name)) + "\"" +
                         ",\"x\":" + std::to_string(rc.left) + ",\"y\":" + std::to_string(rc.top) +
                         ",\"w\":" + std::to_string(rc.right - rc.left) +
                         ",\"h\":" + std::to_string(rc.bottom - rc.top) +
                         ",\"minimized\":" + (IsIconic(w->hwnd) ? "true" : "false") +
                         ",\"active\":" + (GetForegroundWindow() == w->hwnd ? "true" : "false") + "}");
        }
        return ctlErr("unknown command '" + cmd + "' (lite subset)");
    }
    return ctlErr("unknown command '" + cmd + "' (lite subset)");
}

static DWORD WINAPI ctlClientThread(void* param) {
    HANDLE pipe = (HANDLE)param;
    std::string line;
    char ch;
    DWORD n;
    while (ReadFile(pipe, &ch, 1, &n, nullptr) && n == 1) {
        if (ch == '\n') {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (!line.empty()) {
                std::string reply = ctlDispatch(line) + "\n";
                DWORD w;
                if (!WriteFile(pipe, reply.data(), (DWORD)reply.size(), &w, nullptr)) break;
            }
            line.clear();
        } else line += ch;
    }
    CloseHandle(pipe);
    return 0;
}

/// Serves ONE control pipe. Started twice for the default instance: once on agliteterm, once on the
/// 0.17.x name, so `agwintermctl --pipe agwinterm-lite` and any script a user already wrote keep
/// working through the rename. The agent skill and the hooks need no alias — they read
/// AGWINTERM_PIPE, which sessions get with the new name.
static DWORD WINAPI ctlServerThreadFor(void* arg) {
    std::wstring pipeName = L"\\\\.\\pipe\\" + std::wstring((const wchar_t*)arg);
    for (;;) {
        HANDLE pipe = CreateNamedPipeW(pipeName.c_str(), PIPE_ACCESS_DUPLEX,
                                       PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                                       PIPE_UNLIMITED_INSTANCES, 64 * 1024, 64 * 1024, 0, nullptr);
        if (pipe == INVALID_HANDLE_VALUE) return 1;
        BOOL ok = ConnectNamedPipe(pipe, nullptr);
        if (!ok && GetLastError() != ERROR_PIPE_CONNECTED) { CloseHandle(pipe); continue; }
        if (pipeName.find(kLegacyAppId) != std::wstring::npos) {
            static bool warned = false;
            if (!warned) { warned = true; logInfo("ctl: a client used the legacy pipe name '%s' - alias still in use", narrow(kLegacyAppId).c_str()); }
        }
        CreateThread(nullptr, 0, ctlClientThread, pipe, 0, nullptr);
    }
}

// One parsed state file. `opened` separates "no file" from "a file that says nothing useful" — the
// two used to look identical from outside, which is half of why the field report was unanswerable.
struct RestoreSpec { int ws; std::string name, app, cwd; std::vector<std::string> args; bool flagged = false; };
// A split shell, and which S line owns it. It has no name and no workspace of its own - it is one
// session's right-hand pane, so it is restored only if that session was.
struct SplitSpec { int owner = -1; RestoreSpec spec; };

struct ParsedState {
    std::vector<std::wstring> wss;
    std::vector<RestoreSpec> specs;
    std::vector<SplitSpec> splits;       // from P lines; empty for any file written before 0.17.13
    int sLines = 0;                      // RAW S lines seen, valid or not - see the P-line guard
    std::vector<std::string> savedIds;   // from the D line; empty for a pre-0.17.3 file
    int activeWs = 0, focusWs = -1;
    int version = 0;                     // from the V header; 0 = there wasn't one
    size_t bytes = 0;
    DWORD err = 0;
    bool opened = false;
};

static ParsedState parseStateFile(const std::wstring& path) {
    ParsedState ps;
    std::string data;
    ps.opened = readWholeFile(path, data, &ps.err);
    if (!ps.opened) return ps;
    ps.bytes = data.size();
    size_t i = 0;
    auto split = [](const std::string& l) {
        std::vector<std::string> ff; size_t p = 0;
        for (;;) { size_t t = l.find('\t', p); ff.push_back(l.substr(p, t == std::string::npos ? std::string::npos : t - p)); if (t == std::string::npos) break; p = t + 1; }
        return ff;
    };
    while (i < data.size()) {
        size_t e = data.find('\n', i);
        std::string l = data.substr(i, e == std::string::npos ? std::string::npos : e - i);
        i = (e == std::string::npos) ? data.size() : e + 1;
        if (!l.empty() && l.back() == '\r') l.pop_back();
        if (l.empty()) continue;
        auto ff = split(l);
        // The format grows by ADDING line types (that is how D arrived), so a file from a newer
        // build is read for the lines this one recognises rather than thrown away — discarding it
        // would lose the sessions AND overwrite the newer file on the next save. Recorded so the
        // log can say so; unknown line types are ignored by the same principle.
        if (ff[0].size() >= 2 && ff[0][0] == 'V' && isdigit((unsigned char)ff[0][1])) ps.version = atoi(ff[0].c_str() + 1);
        else if (ff[0] == "W" && ff.size() >= 2) ps.wss.push_back(widen(ff[1]));
        else if (ff[0] == "S") {
            ps.sLines++;                 // counted even when malformed: the P guard below needs it
            if (ff.size() >= 5) {
                RestoreSpec sp; sp.ws = atoi(ff[1].c_str()); sp.name = ff[2]; sp.app = ff[3]; sp.cwd = ff[4];
                for (size_t k = 5; k < ff.size(); k++) sp.args.push_back(ff[k]);
                ps.specs.push_back(sp);
            }
        } else if (ff[0] == "P" && ff.size() >= 4) {   // a session's split shell: owner, app, cwd, args
            SplitSpec sp; sp.owner = atoi(ff[1].c_str()); sp.spec.app = ff[2]; sp.spec.cwd = ff[3];
            for (size_t k = 4; k < ff.size(); k++) sp.spec.args.push_back(ff[k]);
            ps.splits.push_back(sp);
        } else if (ff[0] == "F") {   // flagged indices, in S-line order
            for (size_t k = 1; k < ff.size(); k++) {
                int fi = atoi(ff[k].c_str());
                if (fi >= 0 && fi < (int)ps.specs.size()) ps.specs[fi].flagged = true;
            }
        } else if (ff[0] == "D") {   // host session ids, in S-line order (absent in 0.17.x files)
            for (size_t k = 1; k < ff.size(); k++) ps.savedIds.push_back(ff[k]);
        } else if (ff[0] == "O" && ff.size() >= 2) ps.focusWs = atoi(ff[1].c_str());
        else if (ff[0] == "A" && ff.size() >= 2) ps.activeWs = atoi(ff[1].c_str());
    }
    // The D line pairs POSITIONALLY with the S lines: id k belongs to spec k. A malformed S line is
    // dropped by the >= 5 check above, which slides every later id onto the wrong spec — and restore
    // would then adopt a live shell belonging to a different session, relabel it with this spec's
    // name/app/cwd, and save that wrong pairing back. Damaged files are exactly what the .bak
    // fallback exists to read, so refuse the ids rather than misapply them; the specs still restore,
    // just as fresh sessions.
    // P lines name their owner by POSITION among the S lines, so a dropped S line slides every
    // later owner index onto the wrong session - and a split would then open beside a session that
    // never had one. Same reasoning as the D line below: refuse the splits, keep the sessions.
    if (!ps.splits.empty() && ps.sLines != (int)ps.specs.size()) {
        logWarn("state: %d session line(s) but %zu parsed - refusing %zu split line(s) rather than "
                "attaching them to the wrong sessions", ps.sLines, ps.specs.size(), ps.splits.size());
        ps.splits.clear();
    }
    if (!ps.savedIds.empty() && ps.savedIds.size() != ps.specs.size()) {
        logWarn("state: %zu saved id(s) for %zu session line(s) — the file is inconsistent, so live "
                "sessions will not be adopted from it", ps.savedIds.size(), ps.specs.size());
        ps.savedIds.clear();
    }
    return ps;
}

// A spec that would not start on THIS machine (a profile whose exe only exists on the other one, a
// cwd on a drive that isn't mounted). Dropping it silently loses the name, workspace, cwd and args —
// which is precisely why "restore doesn't work" was unreportable in the field. Keep a dead session
// instead: no shell behind it, marked "(failed to start)" the way an exited one is marked, and still
// persisted by the next save so the entry can be retried where the app does exist.
static Session* failedSpecSession(const RestoreSpec& sp, int cols, int rows) {
    Session* s = new Session();
    s->name = widen(sp.name);
    s->flagged = sp.flagged;
    s->app = sp.app;
    s->args = sp.args;
    s->cwd = sp.cwd;
    s->ws = (g_activeWs >= 0 && g_activeWs < (int)g_workspaces.size()) ? g_activeWs : 0;
    s->exited = true;
    s->failed = true;
    s->cols = cols; s->rows = rows;
    s->emu = emu_new(cols, rows);
    // Say it in the pane as well as the tree: the terminal is where the user looks first, and "why
    // is this session dead?" has to be answerable without opening the log.
    std::string msg = "\r\n  [agliteterm] this session could not be restored on this machine.\r\n"
                      "  app: " + (sp.app.empty() ? std::string("(default shell)") : sp.app) + "\r\n";
    if (!sp.cwd.empty()) msg += "  cwd: " + sp.cwd + "\r\n";
    msg += "  The entry is kept so its name and settings are not lost.\r\n";
    EnterCriticalSection(&g_lock);
    if (s->emu) emu_feed(s->emu, (const uint8_t*)msg.data(), (uint32_t)msg.size());
    g_sessions.push_back(s);
    g_userEmptied = false;   // see attachSession: the deliberate-empty flag is per-empty, not per-process
    LeaveCriticalSection(&g_lock);
    return s;
}

// Host records whose shell has EXITED are tombstones only an explicit kill removes, and no other code
// path ever sends one: nothing here closed them, so nothing here killed them. They survive every
// future launch, and enough of them push `list` past this build's field storage (ListReply.sessions
// is max_count:64), at which point the whole reply stops decoding and adoption — plus the id
// reservation that rides along with it — is off PERMANENTLY. Sweep them once adoption has had its
// chance. Runs on EVERY launch, not just a restoring one: --no-restore, a missing state file and a
// file that parsed to nothing all leave the host holding the same tombstones, and those are exactly
// the launches after which nobody ever comes back to clear them. Deliberately narrow: only this
// instance's id prefix (another window's sessions are not ours to touch), only entries the host
// reported exited, never one it reported attached, and never one this run just adopted.
static void reapExitedHostSessions() {
    for (const auto& hs : g_hostLive) {
        if (!hs.exited || hs.attached) continue;
        size_t dash = hs.id.rfind('-');
        if (dash == std::string::npos || hs.id.compare(0, dash, g_idPrefix) != 0) continue;
        if (!fitsField(hs.id.c_str(), sizeof agwinterm_ptyhost_SessionRef::id)) continue;
        bool mine = false;
        for (const auto& t : g_adoptedIds) if (t == hs.id) { mine = true; break; }
        if (mine) continue;
        agwinterm_ptyhost_Request k = agwinterm_ptyhost_Request_init_default;
        agwinterm_ptyhost_Reply kr = agwinterm_ptyhost_Reply_init_default;
        k.which_cmd = agwinterm_ptyhost_Request_kill_tag;
        strcpy_s(k.cmd.kill.id, hs.id.c_str());
        if (request(k, &kr)) logInfo("restore: reaped exited host session '%s'", hs.id.c_str());
    }
}

// Rebuild the saved workspaces + sessions on launch. Returns false (caller opens a default session) if
// there's nothing to restore. Sessions relaunch with their remembered profile + creation cwd.
static bool restoreSessions() {
    std::wstring path = stateFilePath(), bakPath = path + L".bak", usedPath = path;
    ParsedState ps = parseStateFile(path);
    if (ps.specs.empty()) {
        // Exits 1-3 of 4. "No state file", "empty state file" and "a file I could not make sense of"
        // look identical from outside, so each one says which it was.
        if (!ps.opened)          logInfo("restore: no state file at %s (err %lu)", narrow(path).c_str(), ps.err);
        else if (ps.bytes == 0)  logWarn("restore: state file is EMPTY: %s", narrow(path).c_str());
        else                     logWarn("restore: %s parsed to 0 session specs (%zu bytes, %zu workspace lines)",
                                         narrow(path).c_str(), ps.bytes, ps.wss.size());
        // Second chance: the previous generation kept by the save. Restore had none before, so a
        // single bad write was permanent.
        ParsedState bak = parseStateFile(bakPath);
        if (bak.specs.empty()) {
            logInfo("restore: no usable %s either — starting fresh", narrow(bakPath).c_str());
            return false;
        }
        logWarn("restore: falling back to %s (%zu spec(s), %zu bytes)",
                narrow(bakPath).c_str(), bak.specs.size(), bak.bytes);
        ps = bak;
        usedPath = bakPath;
    }
    const std::vector<RestoreSpec>& specs = ps.specs;
    const std::vector<std::string>& savedIds = ps.savedIds;
    const std::vector<std::wstring>& wss = ps.wss;
    int activeWs = ps.activeWs, focusWs = ps.focusWs;
    logInfo("restore: %zu spec(s) from %s (%zu bytes)", specs.size(), narrow(usedPath).c_str(), ps.bytes);
    // Only a NEWER format is worth a warning. Version 0 just means "no V header", which is every
    // 0.17.x file and every hand-edited one — the documented backward-compatible case, not a fault,
    // and crying about it in the log the field reports are read from helps nobody.
    if (ps.version > 1)
        logWarn("restore: %s is format V%d, this build writes V1 — reading the line types it recognises",
                narrow(usedPath).c_str(), ps.version);

    g_restoring = true;
    if (!wss.empty()) g_workspaces = wss;
    int cols, rows; newSessionGrid(0, &cols, &rows);
    int firstIdx = -1, built = 0, adopted = 0, dead = 0;
    std::vector<Session*> bySpec;   // spec index -> the session it produced (null if it could not start)

    // Sessions the host still holds (read at startup by scanHostSessions, which also reserved their
    // ids). lite was killed rather than closed if this is non-empty: the pty-host outlives the UI by
    // design, so those shells are STILL RUNNING. Adopt them instead of creating new ones — which
    // also fixes the wholesale restore failure, because a create against an id the host already has
    // is rejected ("session '<id>' already exists") and used to sink every single spec.
    size_t adoptable = 0;
    for (const auto& hs : g_hostLive) if (hs.adoptable()) adoptable++;
    logInfo("restore: %zu saved id(s) in the file, host holds %zu session(s), %zu adoptable",
            savedIds.size(), g_hostLive.size(), adoptable);
    // Only sessions that are neither exited nor already being driven by another window. Attaching to
    // an attached session supersedes its current client — a second window on the same instance would
    // silently steal the first one's shells — and attaching to an exited one yields an immediate EOF,
    // i.e. a dead pane where a relaunched shell belongs.
    // Ids already taken by this restore. g_hostLive is a snapshot and nothing marks it as adoption
    // proceeds, so without this a D line carrying the same id twice — a hand-edited or damaged file,
    // which is the case the .bak fallback exists for — adopts one host session into TWO panes: the
    // second attach supersedes the first, the first goes dead on EOF, and closing either kills the
    // shell out from under the other.
    std::vector<std::string>& taken = g_adoptedIds;   // the reap below must never touch these
    taken.clear();
    auto isAdoptable = [&](const std::string& id) {
        if (id.empty()) return false;
        for (const auto& t : taken) if (t == id) return false;
        for (const auto& hs : g_hostLive) if (hs.id == id) return hs.adoptable();
        return false;
    };

    for (size_t si = 0; si < specs.size(); si++) {
        const auto& sp = specs[si];
        g_activeWs = (sp.ws >= 0 && sp.ws < (int)g_workspaces.size()) ? sp.ws : 0;
        std::string want = si < savedIds.size() ? savedIds[si] : std::string();
        Session* s = nullptr;
        if (isAdoptable(want)) {
            s = attachSession(want.c_str(), cols, rows, sp.app.empty() ? nullptr : sp.app.c_str(),
                              sp.args.empty() ? nullptr : &sp.args, sp.cwd.empty() ? nullptr : sp.cwd.c_str(),
                              true);   // repaint: the shell already has a screen, ask it to redraw
            if (s) { adopted++; taken.push_back(want); logInfo("restore: adopted live session '%s' (%s)", want.c_str(), sp.name.c_str()); }
            // The shell itself is untouched by a failed adopt (attach may well have succeeded and
            // only the data pipe refused), so it keeps running under an id nothing points at any
            // more — a duplicate for the same spec is created beside it. Name the id: that orphan is
            // otherwise invisible, and it is the reader's only handle on "why are there two?".
            else logWarn("restore: adopt of live session '%s' failed — creating a fresh one; the "
                         "host may still be running the old shell under that id", want.c_str());
        }
        if (!s)
            s = newSession(cols, rows, sp.app.empty() ? nullptr : sp.app.c_str(),
                           sp.args.empty() ? nullptr : &sp.args, sp.cwd.empty() ? nullptr : sp.cwd.c_str());
        if (s) {
            s->name = widen(sp.name); s->flagged = sp.flagged;
            if (firstIdx < 0) firstIdx = (int)g_sessions.size() - 1;
            built++;
            bySpec.push_back(s);
        } else {
            // A spec that won't start used to be invisible AND gone: the session didn't come back and
            // the next save rewrote the file without it. Keep it as a dead entry and name it in the log.
            logWarn("restore: session '%s' FAILED to start (app='%s' cwd='%s') — kept as a dead session",
                    sp.name.c_str(), sp.app.c_str(), sp.cwd.c_str());
            failedSpecSession(sp, cols, rows);
            dead++;
            bySpec.push_back(nullptr);   // keep spec positions aligned for the P lines
        }
    }
    // Each session gets its own split shell back. A P line names its owner by position, and the
    // parser has already refused the whole set if the S lines it counts on did not all parse.
    // The shell is created fresh rather than adopted: only the S lines carry host ids (the D line),
    // so a killed lite leaves the old split shells to the reap, as it always did.
    int splitsBuilt = 0;
    for (const auto& sp : ps.splits) {
        if (sp.owner < 0 || sp.owner >= (int)bySpec.size() || !bySpec[sp.owner]) continue;
        Session* sh = newSession(cols, rows, sp.spec.app.empty() ? nullptr : sp.spec.app.c_str(),
                                 sp.spec.args.empty() ? nullptr : &sp.spec.args,
                                 sp.spec.cwd.empty() ? nullptr : sp.spec.cwd.c_str());
        if (!sh) { logWarn("restore: a split shell FAILED to start (app=%s cwd=%s) - its session comes back without it",
                           sp.spec.app.c_str(), sp.spec.cwd.c_str()); continue; }
        sh->hidden = true;                       // a split shell, not a tree session
        bySpec[sp.owner]->splitId = sh->id;
        splitsBuilt++;
    }
    if (!ps.splits.empty())
        logInfo("restore: %d of %zu split shell(s) rebuilt", splitsBuilt, ps.splits.size());
    g_restoring = false;
    logInfo("restore: %d of %zu session(s) built (%d adopted live from the pty-host, %d kept as dead)",
            built, specs.size(), adopted, dead);
    if (firstIdx < 0) {   // exit 4 of 4: specs parsed but nothing could be started
        // The dead entries stay in the tree; the caller opens a working session beside them, so the
        // window is usable and the specs are still there to look at (and still saved).
        logWarn("restore: no session could be started from %zu spec(s) — starting fresh (%d dead entr%s kept)",
                specs.size(), dead, dead == 1 ? "y" : "ies");
        if (dead) refreshTree();
        return false;
    }
    g_pane[0] = firstIdx; g_focus = 0;
    resolveSplitForPrimary();   // ...and the restored session shows its own split, if it had one
    g_activeWs = (activeWs >= 0 && activeWs < (int)g_workspaces.size()) ? activeWs : 0;
    g_focusWs = (focusWs >= 0 && focusWs < (int)g_workspaces.size()) ? focusWs : -1;
    syncPaneSizes();
    refreshTree();
    return true;
}

// Launch arguments — the full app's flags, minus the ones whose feature lite doesn't have
// (--fullscreen, --pty-host, --app-id, --default-session-host). Unknown args are ignored.
static void parseLaunchArgs() {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return;
    for (int i = 1; i < argc; i++) {
        std::wstring a = argv[i];
        for (auto& c : a) c = (wchar_t)towlower(c);
        const wchar_t* v = (i + 1 < argc) ? argv[i + 1] : nullptr;
        if ((a == L"-p" || a == L"--profile") && v)                            { g_argProfile = v; i++; }
        else if ((a == L"-d" || a == L"--dir" || a == L"--startingdirectory") && v) { g_argDir = narrow(v); i++; }
        else if (a == L"--maximized")  g_argMaximized = true;
        else if (a == L"--no-restore") g_argNoRestore = true;
        else if (a == L"--bench-agbf") g_argBenchAgbf = true;
        else if (a == L"--diagnose")   g_argDiagnose = true;
        else if (a == L"--pipe" && v)  { g_argPipe = v; i++; }
    }
    LocalFree(argv);
    if (!g_argDir.empty()) {   // a bad directory is ignored, like the full app
        DWORD at = GetFileAttributesA(g_argDir.c_str());
        if (at == INVALID_FILE_ATTRIBUTES || !(at & FILE_ATTRIBUTE_DIRECTORY)) g_argDir.clear();
    }
    if (!g_argPipe.empty() && g_argPipe != kAppId) {   // named instance
        std::wstring clean = sanitizeInstanceName(g_argPipe);
        if (clean != g_argPipe) g_instanceRaw = g_argPipe;   // logInit reports it; see sanitizeInstanceName
        g_argPipe = clean;
        g_instance = clean;
        g_isDefaultInstance = false;
        // Session-id prefix: ASCII alnum/dash only. `(char)towlower(wchar_t)` on anything above
        // U+007F truncates to a lone high byte, and the id travels as a protobuf STRING — the Rust
        // host's decode rejects invalid UTF-8, so every create would come back "unknown command"
        // and the window could never open a session. `--pipe café` was enough to do it.
        std::string p;
        for (wchar_t c : g_argPipe)
            if (c < 128 && (iswalnum(c) || c == L'-' || c == L'_')) p += (char)towlower(c);
        g_idPrefix = p.empty() ? "lite" : p;
    }
}
// Map -p/--profile onto a detected profile (case-insensitive substring, so "-p pwsh" or
// "-p PowerShell 7" both land on PowerShell 7). Returns false = default shell.
static bool resolveLaunchProfile(std::string& app, std::vector<std::string>& args) {
    if (g_argProfile.empty()) return false;
    std::wstring want = g_argProfile;
    for (auto& c : want) c = (wchar_t)towlower(c);
    for (const auto& p : detectProfiles()) {
        std::wstring n = p.name;
        for (auto& c : n) c = (wchar_t)towlower(c);
        if (n.find(want) != std::wstring::npos) { app = p.app; args = p.args; return true; }
    }
    return false;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
    _Module.Init(nullptr, inst);   // ATL/WTL module (window class registration lives here)
    parseLaunchArgs();
    if (g_argBenchAgbf) return agbfBench();   // headless pack benchmark, no window/session
    if (g_argDiagnose) return liteDiagnose();  // headless state/environment report, no window/session
    {   // diagnostics log: after parseLaunchArgs so it lands in the right per-instance file
        int argc = 0;
        wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        logInit(argc, argv);
        if (argv) LocalFree(argv);
    }
    // Before ANY read of settings or state: loadColors/loadFontSel/loadKeys and restoreSessions
    // all resolve through the new names, so the adoption has to have happened already.
    migrateFromLegacy();
    InitializeCriticalSection(&g_lock);
    InitializeCriticalSection(&g_resizeLock);
    InitializeCriticalSection(&g_reqLock);
    InitializeCriticalSection(&g_evtLock);
    InitializeCriticalSection(&g_statusLock);
    g_evtReady = true;   // from here on, anything worth reporting goes into the event log
    loadCore();

    // Bundled fonts (process-private): Meslo Nerd (default TrueType), plus the optional bitmap fonts
    // Cozette + Tamzen if their .ttf shipped next to the exe. Consolas is the fallback if Meslo is absent.
    std::wstring dir = exeDir();
    bool haveMeslo = AddFontResourceExW((dir + L"\\MesloLGLDZNerdFont-Regular.ttf").c_str(), FR_PRIVATE, 0) > 0;
    g_ttFace = haveMeslo ? L"MesloLGLDZ Nerd Font" : L"Consolas";
    g_haveCozette = AddFontResourceExW((dir + L"\\CozetteVector.ttf").c_str(), FR_PRIVATE, 0) > 0;
    AddFontResourceExW((dir + L"\\CozetteVectorBold.ttf").c_str(), FR_PRIVATE, 0);
    int tam = 0;
    for (const wchar_t* f : { L"TamzenForPowerline7x14r.ttf", L"TamzenForPowerline7x14b.ttf",
                              L"TamzenForPowerline8x16r.ttf", L"TamzenForPowerline8x16b.ttf",
                              L"TamzenForPowerline10x20r.ttf", L"TamzenForPowerline10x20b.ttf" })
        tam += AddFontResourceExW((dir + L"\\" + f).c_str(), FR_PRIVATE, 0);
    g_haveTamzen = tam > 0;
    g_haveTerminus = AddFontResourceExW((dir + L"\\TerminusTTF.ttf").c_str(), FR_PRIVATE, 0) > 0;
    AddFontResourceExW((dir + L"\\TerminusTTF-Bold.ttf").c_str(), FR_PRIVATE, 0);
    int spl = 0;
    for (const wchar_t* f : { L"Spleen-6x12.otf", L"Spleen-8x16.otf", L"Spleen-12x24.otf",
                              L"Spleen-16x32.otf", L"Spleen-32x64.otf" })
        spl += AddFontResourceExW((dir + L"\\" + f).c_str(), FR_PRIVATE, 0);
    g_haveSpleen = spl > 0;
    g_haveUnscii = AddFontResourceExW((dir + L"\\unscii-16.ttf").c_str(), FR_PRIVATE, 0) > 0;
    AddFontResourceExW((dir + L"\\unscii-8.ttf").c_str(), FR_PRIVATE, 0);
    g_haveUnifont = AddFontResourceExW((dir + L"\\Unifont.otf").c_str(), FR_PRIVATE, 0) > 0;
    g_haveAgbf = GetFileAttributesW((dir + L"\\agwin-bitmap-16.agbf").c_str()) != INVALID_FILE_ATTRIBUTES;
    g_haveAgbfC = GetFileAttributesW((dir + L"\\agwin-bitmap-complete-16.agbf").c_str()) != INVALID_FILE_ATTRIBUTES;
    buildFontCatalog();
    loadColors();      // Properties->Colors overrides, remembered across restarts
    loadKeys();        // configurable key bindings (unbound by default)
    loadFontSel();     // resolve the remembered face+size (first run -> AGWin Bitmap Complete 16)
    applyFont();       // creates g_fonts + sets g_cw/g_ch (g_hwnd still null, so no relayout yet)
    if (g_faceIdx >= 0 && g_faceIdx < (int)g_catalog.size())
        logInfo("font: %s %s (%s) cell=%dx%d | packs: agbf=%d complete=%d",
                narrow(g_catalog[g_faceIdx].label).c_str(),
                narrow(g_catalog[g_faceIdx].sizes[g_sizeIdx].label).c_str(),
                g_fontFromReg ? "remembered" : "first-run default", g_cw, g_ch,
                g_haveAgbf ? 1 : 0, g_haveAgbfC ? 1 : 0);

    connectControl();
    scanHostSessions();   // what the host already holds — reserves their ids and feeds adoption

    INITCOMMONCONTROLSEX icc{ sizeof icc, ICC_TREEVIEW_CLASSES | ICC_BAR_CLASSES | ICC_HOTKEY_CLASS };
    InitCommonControlsEx(&icc);

    g_appIcon = loadAppIcon(false);
    g_appIconSm = loadAppIcon(true);
    applyTheme();   // resolve the saved theme BEFORE any window exists, so nothing flashes light

    // The default rect (no saved WinW-<instance>): the PERSISTED sidebar plus the splitter, then 100
    // columns of the live font. It used the constant kSidebarW, so a saved SidebarW of 400 opened a
    // first window whose terminal was 45 columns narrower than the 100 this rect promises (#23's
    // other half: the two values are each valid alone and were never sized together).
    RECT want{ 0, 0, g_sidebarW + kSplitterW + 100 * g_cw, 30 * g_ch };
    // WS_CLIPCHILDREN keeps the terminal paint out of the native tree child.
    AdjustWindowRect(&want, WS_OVERLAPPEDWINDOW, TRUE);   // TRUE = has a menu bar
    int wx = CW_USEDEFAULT, wy = CW_USEDEFAULT, ww = want.right - want.left, wh = want.bottom - want.top;
    RECT sr; bool startMax = false;
    if (loadWindowRect(&sr, &startMax)) { wx = sr.left; wy = sr.top; ww = sr.right - sr.left; wh = sr.bottom - sr.top; }
    bool haveRect = (wx != CW_USEDEFAULT);
    RECT frameRc{ wx, wy, wx + ww, wy + wh };
    // WTL frame: CFrameWinTraits already carries WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN.
    g_hwnd = g_frame.CreateEx(nullptr, haveRect ? &frameRc : nullptr);
    if (!g_hwnd) fatal(L"could not create the main window");
    g_frame.SetWindowText(g_isDefaultInstance ? L"agliteterm"
                                              : (L"agliteterm \x2014 " + g_instance).c_str());
    SetTimer(g_hwnd, kCaretTimer, kCaretBlinkMs, nullptr);   // the caret blink (the other is kRelayoutTimer, armed on demand)
    announceInstance(g_hwnd);   // visible to the other windows' window.* verbs
    g_frame.SetMenu(buildMenuBar());
    g_frame.SetIcon(g_appIcon, TRUE);    // VGA black+cyan terminal icon (window + taskbar)
    g_frame.SetIcon(g_appIconSm, FALSE);
    if (wx == CW_USEDEFAULT) g_frame.SetWindowPos(nullptr, 0, 0, ww, wh, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);

    // Native SysTreeView32 sidebar docked on the left; picking a node selects that session.
    RECT cr; GetClientRect(g_hwnd, &cr);
    RECT trc{ 0, 0, g_sidebarW, cr.bottom };
    g_frame.m_tree.Create(g_hwnd, trc, nullptr,
                          WS_CHILD | WS_VISIBLE | TVS_SHOWSELALWAYS | TVS_NOHSCROLL |
                          TVS_HASBUTTONS | TVS_HASLINES | TVS_LINESATROOT | TVS_EDITLABELS,
                          WS_EX_CLIENTEDGE, (UINT)ID_TREE);
    g_tree = g_frame.m_tree;   // the rest of the file talks to the raw handle
    SetWindowSubclass(g_tree, treeProc, 1, 0);   // session drag & drop (own drag-detect loop)
    applyTreeFont();   // shell UI face at the saved size, not the stock bitmap font
    // g_treeItalic is built by applyTreeFont() alongside g_treeFont, so it tracks the sidebar size.

    // Native status bar (msctls_statusbar32) — a real standard control, docks itself at the bottom.
    RECT zr{ 0, 0, 0, 0 };
    g_frame.m_status.Create(g_hwnd, zr, nullptr, WS_CHILD | WS_VISIBLE | SBARS_SIZEGRIP, 0, (UINT)ID_STATUS);
    g_status = g_frame.m_status;
    { int parts[4] = { 120, 360, 470, -1 }; g_frame.m_status.SetParts(4, parts); }
    SetWindowSubclass(g_status, statusProc, 1, 0);   // dark paint takeover (no-op in light/classic)

    // Native toolbar across the top: every full-app chrome button, drawn at runtime as the full
    // app's vector glyphs (see drawToolbarGlyph), with hover tooltips (TBSTYLE_TOOLTIPS). No
    // TBSTYLE_FLAT: classic raised 3D buttons suit the old-skool Classic look; themed modes
    // owner-draw the buttons anyway.
    buildToolbarImages();
    g_frame.m_toolbar.Create(g_hwnd, zr, nullptr,
                             WS_CHILD | WS_VISIBLE | TBSTYLE_TOOLTIPS | CCS_TOP, 0, (UINT)ID_TOOLBAR);
    g_toolbar = g_frame.m_toolbar;
    g_frame.m_toolbar.SetButtonStructSize(sizeof(TBBUTTON));
    g_frame.m_toolbar.SetImageList(g_tbImages);
    TBBUTTON tb[kTbCount] = {};
    for (int i = 0; i < kTbCount; i++) {
        tb[i].iBitmap = kTbButtons[i].img;
        tb[i].idCommand = kTbButtons[i].id;
        tb[i].fsState = TBSTATE_ENABLED;
        if (kTbButtons[i].check && kTbButtons[i].id == IDM_FLAGVIEW && g_flagView) tb[i].fsState |= TBSTATE_CHECKED;
        tb[i].fsStyle = BTNS_AUTOSIZE | (kTbButtons[i].check ? BTNS_CHECK : 0);
    }
    g_frame.m_toolbar.AddButtons(kTbCount, tb);
    g_frame.m_toolbar.AutoSize();
    RECT tbr; GetWindowRect(g_toolbar, &tbr); g_toolbarH = tbr.bottom - tbr.top;

    // Shell UI font (Segoe UI on Win10/11) for the dialogs (Properties / New Session).
    NONCLIENTMETRICSW ncm{ sizeof(ncm) };
    SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
    g_uiFont = CreateFontIndirectW(&ncm.lfMessageFont);
    applyTreeFont();

    // System-tray icon (right-click for a menu incl. Restart / Exit; double-click restores).
    g_nid.cbSize = sizeof g_nid;
    g_nid.hWnd = g_hwnd;
    g_nid.uID = ID_TRAY;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_APP_TRAY;
    g_nid.hIcon = g_appIconSm;
    wcscpy_s(g_nid.szTip, L"agliteterm");
    Shell_NotifyIconW(NIM_ADD, &g_nid);

    updCleanup();       // drop payloads a previous update left behind
    updCheck(false);    // background "a new lite is out" balloon (installed copies only)

    applyTheme();   // now that the controls exist, colour them (and the title bar) for real

    ShowWindow(g_hwnd, (startMax || g_argMaximized) ? SW_SHOWMAXIMIZED : show);

    std::string argApp; std::vector<std::string> argAppArgs;
    bool haveProf = resolveLaunchProfile(argApp, argAppArgs);
    bool wantLaunch = haveProf || !g_argDir.empty();   // -p/-d ask for a specific session
    bool restored = !g_argNoRestore && restoreSessions();
    reapExitedHostSessions();   // after adoption has had its chance, on every launch path
    if (!restored || wantLaunch) {   // fresh first session, or an EXTRA one for the launch args
        int cols, rows;
        newSessionGrid(0, &cols, &rows);
        Session* s = newSession(cols, rows, haveProf ? argApp.c_str() : nullptr,
                                (haveProf && !argAppArgs.empty()) ? &argAppArgs : nullptr,
                                g_argDir.empty() ? nullptr : g_argDir.c_str());
        // Only when there is NOTHING to show. restoreSessions() returns false while still having kept
        // the specs it could not start as dead "(failed to start)" entries — the whole point of
        // failedSpecSession — and a window listing them, with the log line naming each one, is far
        // better than a message box that throws them away. Judged by `restored` alone this killed
        // exactly the launch it was built to explain.
        if (!s && g_sessions.empty()) fatal(L"could not create the first session");
        if (s) { selectPrimary((int)g_sessions.size() - 1); }
        refreshTree();
    }
    static std::wstring ctlName = g_argPipe.empty() ? std::wstring(kAppId) : g_argPipe;
    CreateThread(nullptr, 0, ctlServerThreadFor, (void*)ctlName.c_str(), 0, nullptr);   // agwintermctl --pipe agliteterm
    // Deprecation alias: only the DEFAULT instance answers to the old product name. Gated on
    // g_isDefaultInstance, not on g_argPipe being empty - `--pipe agliteterm` names the default
    // instance explicitly, and it must behave identically to omitting the flag.
    if (g_isDefaultInstance)
        CreateThread(nullptr, 0, ctlServerThreadFor, (void*)kLegacyAppId, 0, nullptr);
    InvalidateRect(g_hwnd, nullptr, FALSE);

    CMessageLoop loop;          // WTL message pump (adds PreTranslateMessage / OnIdle hooks)
    _Module.AddMessageLoop(&loop);
    int rc = loop.Run();
    _Module.RemoveMessageLoop();
    _Module.Term();
    return rc;
}
