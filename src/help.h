// F1 Help overlay - the host-free half (agwinterm parity: Help.cs). The host hands over what only
// it knows - its version, the EFFECTIVE built-in bindings (the registry, as File > Keyboard shows
// them), keymap.conf's custom bindings and its leader chord - and gets back the lines of the card,
// so a unit test can read the text, the ordering and the scroll arithmetic without a window.
#pragma once
#include <algorithm>
#include <cwctype>
#include <string>
#include <vector>

namespace help {

struct Row { std::wstring key, label; };

// A heading: capitals only, no lowercase letter anywhere, one line. Painted in the accent colour.
// The rule is by CONDITION so a body line that happens to start with a capital is never promoted:
// a body line always carries a lowercase letter.
inline bool isSection(const std::wstring& line) {
    if (line.empty() || line.size() >= 60 || line[0] == L' ') return false;
    bool letter = false;
    for (wchar_t c : line) {
        if (std::iswlower(c)) return false;
        if (std::iswupper(c)) letter = true;
    }
    return letter;
}

// One binding row: the chord padded to a column, then the action. A chord wider than the column
// keeps two spaces before the label rather than running into it.
inline std::wstring row(const Row& r, size_t column = 20) {
    std::wstring s = r.key;
    if (s.size() < column) s.append(column - s.size(), L' '); else s += L"  ";
    return s + r.label;
}

inline std::wstring fit(std::wstring s, size_t width = 74) {
    if (s.size() > width) s = s.substr(0, width - 3) + L"...";
    return s;
}

inline bool byLabel(const Row& a, const Row& b) {
    size_t n = (std::min)(a.label.size(), b.label.size());
    for (size_t i = 0; i < n; ++i) {
        wint_t x = std::towlower(a.label[i]), y = std::towlower(b.label[i]);
        if (x != y) return x < y;
    }
    return a.label.size() < b.label.size();
}

// The card's text - every line at most 74 characters, so it fits the 78-column card the host
// paints even in the 8-px raster font: the fixed text by construction, a binding row by `fit`
// (a long command label ends in "..." rather than being cut mid-word by the painter). `builtin` are the bound built-in actions (an unbound action has no row - the
// dialog lists those); `custom` are keymap.conf's bindings, a leader sequence's key already
// prefixed by the host ("leader, G"); `leader` is the leader chord's name or empty.
inline std::vector<std::wstring> lines(const std::wstring& version, std::vector<Row> builtin,
                                       std::vector<Row> custom, const std::wstring& leader) {
    std::vector<std::wstring> out{
        L"GETTING STARTED",
        L"agliteterm " + version + L" is a lightweight native terminal: sessions live in the",
        L"left sidebar, each with a status dot an agent can set via the control API",
        L"(agwintermctl). Workspaces group the sessions of one project.",
        L"",
        L"FOCUS AND NAVIGATION",
        L"F1            this help, also while a full-screen program runs",
        L"Alt           menu bar: arrows move, Enter opens, Esc leaves",
        L"Esc           closes this help, the command palette and the dashboard",
        L"Ctrl+C        copies a selection (copy-on-Ctrl+C on), else interrupts;",
        L"              Ctrl+Shift+C always copies; Paste is a Keyboard binding",
        L"",
        L"KEY BINDINGS",
        L"File > Keyboard... assigns them; unbound actions are not listed.",
    };
    std::stable_sort(builtin.begin(), builtin.end(), byLabel);
    if (builtin.empty()) out.push_back(L"(no built-in action is bound)");
    for (const auto& r : builtin) out.push_back(fit(row(r)));
    if (!custom.empty() || !leader.empty()) {
        out.push_back(L"");
        out.push_back(L"CUSTOM COMMANDS");
        out.push_back(L"From keymap.conf in agliteterm's data folder (%LOCALAPPDATA%\\agliteterm).");
        if (!leader.empty()) out.push_back(fit(row({ leader, L"leader chord (then a second key)" })));
        for (const auto& r : custom) out.push_back(fit(row(r)));
    }
    out.push_back(L"");
    out.push_back(L"MORE");
    out.push_back(L"Control API: agwintermctl --help.");
    out.push_back(L"Help > Install Agent Skill teaches an agent the control model.");
    out.push_back(L"Command palette lists every action; the About box names this build.");
    return out;
}

// Scroll position clamped to what the viewport can show: never past the last page, never negative.
inline int clampScroll(int scroll, int total, int view) {
    int maxScroll = (std::max)(0, total - (std::max)(1, view));
    return (std::max)(0, (std::min)(maxScroll, scroll));
}

}  // namespace help
