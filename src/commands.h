#pragma once
#include <string>
#include <vector>
#include <map>
#include <sstream>
#include <cstdint>

namespace commands {
inline std::string trim(const std::string& s) {
    const auto first = s.find_first_not_of(" \t\r\n");
    return first == std::string::npos ? "" : s.substr(first, s.find_last_not_of(" \t\r\n") - first + 1);
}
inline std::string lower(std::string s) { for (auto& c : s) if (c >= 'A' && c <= 'Z') c += 'a' - 'A'; return s; }
inline bool mode(const std::string& s) { return s == "send" || s == "new" || s == "overlay" || s == "detached"; }
inline uint16_t chord(const std::string& text) {
    int mods = 0, key = 0; std::istringstream in(lower(trim(text))); std::string part;
    const std::map<std::string,int> names = {{"tab",9},{"enter",13},{"escape",27},{"esc",27},{"space",32},
        {"left",37},{"up",38},{"right",39},{"down",40},{"semicolon",186},{"equals",187},{"comma",188},
        {"minus",189},{"period",190},{"slash",191},{"backtick",192},{"lbracket",219},{"backslash",220},
        {"rbracket",221},{"quote",222}};
    while (std::getline(in, part, '+')) {
        part = trim(part);
        if (part == "ctrl" || part == "control") mods |= 2;
        else if (part == "alt" || part == "option") mods |= 4;
        else if (part == "shift") mods |= 1;
        else {
            if (key || part.empty()) return 0;
            if (part.size() == 1 && ((part[0] >= 'a' && part[0] <= 'z') || (part[0] >= '0' && part[0] <= '9')))
                key = part[0] >= 'a' ? part[0] - 'a' + 'A' : part[0];
            else if (names.count(part)) key = names.at(part);
            else { for (int n = 1; n <= 12; ++n) if (part == "f" + std::to_string(n)) key = 111 + n; }
            if (!key) return 0;
        }
    }
    if (!key || (!text.empty() && text.back() == '+')) return 0;
    return static_cast<uint16_t>(key | (mods << 8));
}
struct Command { std::string label, text, mode; };
struct Binding { uint16_t key; std::string spelling, action; bool leader; int line = 0; };
struct Catalog {
    std::vector<Command> commands;
    std::vector<Binding> bindings;
    uint16_t leader = 0;
    const Command* find(const std::string& label) const {
        for (const auto& c : commands) if (lower(c.label) == lower(label)) return &c;
        return nullptr;
    }
    const Binding* binding(uint16_t key, bool second) const {
        for (auto it = bindings.rbegin(); it != bindings.rend(); ++it)
            if (it->key == key && it->leader == second) return &*it;
        return nullptr;
    }
};
inline bool parse(const std::string& input, const std::map<std::string,int>& actions, Catalog& output, std::string& error) {
    Catalog result; std::istringstream in(input); std::string line; int number = 0;
    if (input.size() > 1024 * 1024 || input.find('\0') != std::string::npos) { error = "invalid keymap size or NUL"; return false; }
    auto bad = [&](const char* why) { error = "line " + std::to_string(number) + ": " + why; return false; };
    while (std::getline(in, line)) {
        ++number; line = trim(line);
        if (number == 1 && line.compare(0, 3, "\xef\xbb\xbf") == 0) line = trim(line.substr(3));
        if (line.empty() || line[0] == '#') continue;
        auto eq = line.find('='); if (eq == std::string::npos) return bad("expected '='");
        auto head = trim(line.substr(0, eq)), value = trim(line.substr(eq + 1)), tag = lower(head);
        if (tag == "leader") { result.leader = chord(value); if (!result.leader) return bad("bad leader chord"); }
        else if (tag.rfind("command ", 0) == 0) {
            head = trim(head.substr(8)); std::string runMode = "send";
            if (!head.empty() && head[0] == '[') {
                auto end = head.find(']'); if (end == std::string::npos) return bad("missing mode bracket");
                runMode = lower(trim(head.substr(1, end - 1))); head = trim(head.substr(end + 1));
            }
            if (!mode(runMode)) return bad("unknown command mode");
            if (head.empty() || value.empty() || head.find('\t') != std::string::npos || result.find(head))
                return bad("empty or duplicate command label/text");
            result.commands.push_back({head, value, runMode});
        } else if (tag.rfind("map ", 0) == 0) {
            head = trim(head.substr(4)); bool second = lower(head).rfind("leader ", 0) == 0;
            if (second) head = trim(head.substr(7));
            auto key = chord(head); if (!key) return bad("bad chord");
            auto action = lower(value);
            if (action.rfind("command:", 0) == 0) value = "command:" + trim(value.substr(8));
            else { if (!actions.count(action)) return bad("unsupported action"); value = action; }
            result.bindings.push_back({key, lower(head), value, second, number});
        } else return bad("expected map, command or leader");
    }
    for (const auto& b : result.bindings) {
        number = b.line;
        if (b.leader && !result.leader) return bad("leader binding without leader");
        if (b.action.rfind("command:", 0) == 0 && !result.find(b.action.substr(8))) return bad("undefined command");
    }
    output = std::move(result); error.clear(); return true;
}
inline std::string expand(const std::string& input, const std::map<std::string,std::string>& values) {
    std::string output;
    for (size_t i = 0; i < input.size();) {
        if (input.compare(i, 5, "{AGW_") == 0) {
            auto end = input.find('}', i + 5);
            if (end != std::string::npos) {
                const auto key = input.substr(i + 1, end - i - 1);
                bool valid = true; for (auto c : key) if (!(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '_') valid = false;
                if (valid) { auto v = values.find(key); if (v != values.end()) output += v->second; i = end + 1; continue; }
            }
        }
        output += input[i++];
    }
    return output;
}
}
