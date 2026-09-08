// P10a: the supported registry-backed surface, independent of the UI and registry I/O.
#pragma once
#include <cstdint>
#include <string>

namespace configuration {
enum class Id { Theme, CustomColors, Foreground, Background, DosPalette, SidebarFont,
    ShowSidebar, ShowToolbar, ShowStatus, FlagView, RightClickPaste, CopyOnCtrlC,
    CopyOnSelect, Scrollback, RestoreCommands };
enum class Kind { Boolean, Color, Theme, SidebarFont, Scrollback };
struct Key { const char* name; const wchar_t* registry; Id id; Kind kind; uint32_t initial; };
static const Key keys[] = {
    {"theme", L"Theme", Id::Theme, Kind::Theme, 0},
    {"custom-colors", L"CustomColors", Id::CustomColors, Kind::Boolean, 0},
    {"foreground", L"DefFg", Id::Foreground, Kind::Color, 0xC0C0C0},
    {"background", L"DefBg", Id::Background, Kind::Color, 0},
    {"dos-palette", L"DosPalette", Id::DosPalette, Kind::Boolean, 1},
    {"sidebar-font-size", L"SidebarFontPt", Id::SidebarFont, Kind::SidebarFont, 0},
    {"show-sidebar", L"ShowSidebar", Id::ShowSidebar, Kind::Boolean, 1},
    {"show-toolbar", L"ShowToolbar", Id::ShowToolbar, Kind::Boolean, 1},
    {"show-status", L"ShowStatus", Id::ShowStatus, Kind::Boolean, 1},
    {"flag-view", L"FlagView", Id::FlagView, Kind::Boolean, 0},
    {"right-click-paste", L"RightClickPaste", Id::RightClickPaste, Kind::Boolean, 1},
    {"copy-on-ctrl-c", L"CopyOnCtrlC", Id::CopyOnCtrlC, Kind::Boolean, 1},
    {"copy-on-select", L"CopyOnSelect", Id::CopyOnSelect, Kind::Boolean, 1},
    {"scrollback-lines", L"ScrollbackLines", Id::Scrollback, Kind::Scrollback, 5000},
    {"restore-commands", L"RestoreCommands", Id::RestoreCommands, Kind::Boolean, 0},
};
inline std::string normalized(std::string text) {
    const auto first = text.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    text = text.substr(first, text.find_last_not_of(" \t\r\n") - first + 1);
    for (char& c : text) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return text;
}
inline const Key* find(const std::string& name) {
    for (const auto& key : keys) if (name == key.name) return &key;
    return nullptr;
}
inline bool valid(const Key& key, uint32_t value) {
    switch (key.kind) {
    case Kind::Boolean: return value <= 1;
    case Kind::Color: return value <= 0xffffff;
    case Kind::Theme: return value <= 3;
    case Kind::SidebarFont: return value == 0 || (value >= 6 && value <= 24);
    case Kind::Scrollback: return value <= 1000000;
    }
    return false;
}
inline std::string format(const Key& key, uint32_t value) {
    switch (key.kind) {
    case Kind::Boolean: return value ? "true" : "false";
    case Kind::Theme: {
        static const char* modes[] = {"auto", "dark", "light", "classic"};
        return value <= 3 ? modes[value] : "invalid";
    }
    case Kind::Color: {
        const char* hex = "0123456789ABCDEF"; std::string s = "#000000";
        for (int i = 6; i >= 1; --i) { s[i] = hex[value & 15]; value >>= 4; }
        return s;
    }
    default: return std::to_string(value);
    }
}
// Failure leaves out untouched, including overflow and partially valid input.
inline bool parse(const Key& key, const std::string& raw, uint32_t& out) {
    const std::string s = normalized(raw); uint32_t value = 0;
    if (s.empty()) return false;
    if (key.kind == Kind::Boolean) {
        if (s == "true" || s == "on" || s == "1") value = 1;
        else if (s != "false" && s != "off" && s != "0") return false;
    } else if (key.kind == Kind::Theme) {
        if (s == "dark") value = 1;
        else if (s == "light") value = 2;
        else if (s == "classic") value = 3;
        else if (s != "auto") return false;
    } else if (key.kind == Kind::Color) {
        if (s.size() != 7 || s[0] != '#') return false;
        for (size_t i = 1; i < s.size(); ++i) {
            char c = s[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
            value = value * 16 + (c <= '9' ? c - '0' : c - 'a' + 10);
        }
    } else {
        for (char c : s) {
            if (c < '0' || c > '9' || value > (UINT32_MAX - (c - '0')) / 10) return false;
            value = value * 10 + c - '0';
        }
    }
    if (!valid(key, value)) return false;
    out = value; return true;
}
}
