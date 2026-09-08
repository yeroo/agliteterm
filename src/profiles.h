// Strict, side-effect-free profile catalog parsing. No Windows, launches or file writes.
#pragma once
#include <map>
#include <string>
#include <vector>
#include <cstdint>

namespace profiles {
inline std::string folded(std::string s) {
    for (char& c : s) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return s;
}
struct Entry { std::string name, command; std::vector<std::string> args; std::string cwd; };
struct Catalog {
    std::string defaultName;
    std::vector<Entry> entries;
    const Entry* find(const std::string& name) const {
        const auto want = folded(name);
        for (const auto& e : entries) if (folded(e.name) == want) return &e;
        return nullptr;
    }
};
namespace detail {
struct Value {
    enum Kind { Null, String, Boolean, Object, Array } kind = Null;
    std::string text; bool boolean = false;
    std::map<std::string, Value> object; std::vector<Value> array;
};
class Parser {
    const std::string& s; size_t pos = 0;
    void ws() { while (pos < s.size() && (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\r' || s[pos] == '\n')) ++pos; }
    bool take(char c) { ws(); if (pos == s.size() || s[pos] != c) return false; ++pos; return true; }
    bool hex(uint32_t& code) {
        code = 0;
        for (int i = 0; i < 4; ++i) {
            if (pos == s.size()) return false;
            const char c = s[pos++];
            int n = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
            if (n < 0) return false;
            code = code * 16 + n;
        }
        return true;
    }
    static void utf8(uint32_t cp, std::string& out) {
        if (cp < 0x80) out += char(cp);
        else if (cp < 0x800) { out += char(0xc0 | (cp >> 6)); out += char(0x80 | (cp & 63)); }
        else if (cp < 0x10000) { out += char(0xe0 | (cp >> 12)); out += char(0x80 | ((cp >> 6) & 63)); out += char(0x80 | (cp & 63)); }
        else { out += char(0xf0 | (cp >> 18)); out += char(0x80 | ((cp >> 12) & 63)); out += char(0x80 | ((cp >> 6) & 63)); out += char(0x80 | (cp & 63)); }
    }
    bool string(std::string& out) {
        if (!take('"')) return false;
        while (pos < s.size()) {
            unsigned char c = static_cast<unsigned char>(s[pos++]);
            if (c == '"') return true;
            if (c < 0x20) return false;
            if (c == '\\') {
                if (pos == s.size()) return false;
                switch (s[pos++]) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    uint32_t cp;
                    if (!hex(cp)) return false;
                    if (cp >= 0xd800 && cp <= 0xdbff) {
                        if (s.compare(pos, 2, "\\u") != 0) return false;
                        pos += 2; uint32_t low;
                        if (!hex(low) || low < 0xdc00 || low > 0xdfff) return false;
                        cp = 0x10000 + ((cp - 0xd800) << 10) + low - 0xdc00;
                    } else if (cp >= 0xdc00 && cp <= 0xdfff) return false;
                    utf8(cp, out); break;
                }
                default: return false;
                }
            } else if (c < 0x80) out += char(c);
            else {
                int count = c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
                if (!count || pos + count - 1 > s.size()) return false;
                uint32_t cp = c & (count == 2 ? 31 : count == 3 ? 15 : 7);
                for (int n = 1; n < count; ++n) {
                    unsigned char next = static_cast<unsigned char>(s[pos++]);
                    if ((next & 0xc0) != 0x80) return false;
                    cp = (cp << 6) | (next & 63);
                }
                if ((count == 2 && cp < 0x80) || (count == 3 && cp < 0x800) || (count == 4 && cp < 0x10000) || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return false;
                utf8(cp, out);
            }
        }
        return false;
    }
    bool value(Value& out, unsigned depth) {
        if (depth > 12) return false;
        ws(); if (pos == s.size()) return false;
        if (s[pos] == '"') { out.kind = Value::String; return string(out.text); }
        if (s[pos] == '{') {
            ++pos; out.kind = Value::Object; if (take('}')) return true;
            for (;;) {
                std::string key; Value child;
                if (!string(key) || !take(':') || !value(child, depth + 1) || !out.object.emplace(key, std::move(child)).second) return false;
                if (take('}')) return true;
                if (!take(',')) return false;
            }
        }
        if (s[pos] == '[') {
            ++pos; out.kind = Value::Array; if (take(']')) return true;
            for (;;) {
                Value child; if (!value(child, depth + 1)) return false;
                out.array.push_back(std::move(child));
                if (take(']')) return true;
                if (!take(',')) return false;
            }
        }
        if (s.compare(pos, 4, "null") == 0) { pos += 4; return true; }
        if (s.compare(pos, 4, "true") == 0) { pos += 4; out.kind = Value::Boolean; out.boolean = true; return true; }
        if (s.compare(pos, 5, "false") == 0) { pos += 5; out.kind = Value::Boolean; return true; }
        return false; // No numeric fields are supported by this catalog schema.
    }
public:
    explicit Parser(const std::string& input) : s(input) {}
    bool parse(Value& out) {
        if (s.size() > 1024 * 1024) return false;
        if (s.compare(0, 3, "\xef\xbb\xbf") == 0) pos = 3;
        if (!value(out, 0)) return false;
        ws(); return pos == s.size();
    }
};
inline bool clean(const std::string& s, size_t max, bool allowWhitespace = false) {
    if (s.size() > max || s.find('\0') != std::string::npos) return false;
    if (!allowWhitespace) for (unsigned char c : s) if (c < 0x20 || c == 0x7f) return false;
    return true;
}
}
inline bool parse(const std::string& input, Catalog& output, std::string& error) {
    using detail::Value;
    Value root; Catalog candidate;
    auto fail = [&](const char* reason) { error = reason; return false; };
    if (!detail::Parser(input).parse(root) || root.kind != Value::Object) return fail("invalid profile JSON");
    for (const auto& item : root.object) if (item.first != "default" && item.first != "profiles") return fail("unsupported catalog property");
    auto def = root.object.find("default"), list = root.object.find("profiles");
    if (def == root.object.end() || def->second.kind != Value::String || list == root.object.end() || list->second.kind != Value::Array) return fail("default and profiles are required");
    candidate.defaultName = def->second.text;
    if (list->second.array.empty() || list->second.array.size() > 128) return fail("catalog requires 1..128 profiles");
    for (const auto& v : list->second.array) {
        if (v.kind != Value::Object) return fail("profile must be an object");
        Entry e;
        for (const auto& item : v.object) {
            const auto& k = item.first; const auto& x = item.second;
            if (k == "name" || k == "command" || k == "cwd") {
                if (k == "cwd" && x.kind == Value::Null) continue;
                if (x.kind != Value::String) return fail("profile name, command and cwd must be strings");
                (k == "name" ? e.name : k == "command" ? e.command : e.cwd) = x.text;
            } else if (k == "args") {
                if (x.kind == Value::Null) continue;
                if (x.kind != Value::Array || x.array.size() > 16) return fail("args must contain at most 16 strings");
                for (const auto& arg : x.array) {
                    if (arg.kind != Value::String || !detail::clean(arg.text, 2047)) return fail("invalid or oversized profile argument (control characters are unsupported)");
                    e.args.push_back(arg.text);
                }
            } else if (k == "elevate") {
                if (x.kind != Value::Boolean || x.boolean) return fail("elevated profiles are unsupported");
            } else if (k == "env") {
                if (x.kind != Value::Null && (x.kind != Value::Object || !x.object.empty())) return fail("custom profile env is unsupported");
            } else if (k == "icon") {
                if (x.kind != Value::Null && (x.kind != Value::String || !x.text.empty())) return fail("custom profile icons are unsupported");
            } else return fail("unsupported profile property");
        }
        if (e.name.empty() || e.name.find_first_not_of(' ') == std::string::npos || !detail::clean(e.name, 128) || e.command.empty() || e.command.find_first_not_of(' ') == std::string::npos || !detail::clean(e.command, 259) || !detail::clean(e.cwd, 259)) return fail("invalid or oversized profile name, command or cwd");
        if (candidate.find(e.name)) return fail("duplicate profile name");
        candidate.entries.push_back(std::move(e));
    }
    if (!candidate.find(candidate.defaultName)) return fail("default profile not found");
    output = std::move(candidate); error.clear(); return true;
}
}
