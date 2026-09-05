// agwinterm-lite control-API server (M1 phase 2): the same newline-JSON protocol
// the main app serves, so agwintermctl, the Claude skill, and hooks work against
// lite UNCHANGED (the control API deliberately stays JSON — it is the human/
// scripting surface; the pty-host protocol is the protobuf one).
//
// Serves a subset: ping, tree, session.new, session.select, session.close,
// session.type, session.text, session.status. Thread-per-client, sync pipes,
// strict request/response.
#pragma once

#include <windows.h>
#include <string>
#include <map>

// ---- tiny JSON: parse one request object into the fields the API subset uses.
// Full escapes on strings; nested "args" is flattened as "args.<key>". ----
struct JsonReq {
    std::map<std::string, std::string> fields;
    const std::string& get(const std::string& k) const {
        static const std::string empty;
        auto it = fields.find(k);
        return it == fields.end() ? empty : it->second;
    }
};

inline bool jsonParseString(const std::string& s, size_t& i, std::string& out) {
    if (s[i] != '"') return false;
    i++;
    out.clear();
    while (i < s.size() && s[i] != '"') {
        char c = s[i++];
        if (c == '\\' && i < s.size()) {
            char e = s[i++];
            switch (e) {
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'u': {
                    if (i + 4 > s.size()) return false;
                    unsigned code = strtoul(s.substr(i, 4).c_str(), nullptr, 16);
                    i += 4;
                    // UTF-8 encode (BMP; surrogate pairs re-combine)
                    if (code >= 0xD800 && code <= 0xDBFF && i + 6 <= s.size() && s[i] == '\\' && s[i + 1] == 'u') {
                        unsigned lo = strtoul(s.substr(i + 2, 4).c_str(), nullptr, 16);
                        i += 6;
                        unsigned cp = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00);
                        out += (char)(0xF0 | (cp >> 18));
                        out += (char)(0x80 | ((cp >> 12) & 0x3F));
                        out += (char)(0x80 | ((cp >> 6) & 0x3F));
                        out += (char)(0x80 | (cp & 0x3F));
                    } else if (code < 0x80) out += (char)code;
                    else if (code < 0x800) {
                        out += (char)(0xC0 | (code >> 6));
                        out += (char)(0x80 | (code & 0x3F));
                    } else {
                        out += (char)(0xE0 | (code >> 12));
                        out += (char)(0x80 | ((code >> 6) & 0x3F));
                        out += (char)(0x80 | (code & 0x3F));
                    }
                    break;
                }
                default: out += e; break;
            }
        } else out += c;
    }
    if (i >= s.size()) return false;
    i++; // closing quote
    return true;
}

inline void jsonSkipWs(const std::string& s, size_t& i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) i++;
}

// Parses {"k":"v"|number|true|false|{...}} one level deep (args flattened).
inline bool jsonParseObject(const std::string& s, size_t& i, const std::string& prefix, JsonReq& out) {
    jsonSkipWs(s, i);
    if (i >= s.size() || s[i] != '{') return false;
    i++;
    for (;;) {
        jsonSkipWs(s, i);
        if (i < s.size() && s[i] == '}') { i++; return true; }
        std::string key;
        if (!jsonParseString(s, i, key)) return false;
        jsonSkipWs(s, i);
        if (i >= s.size() || s[i] != ':') return false;
        i++;
        jsonSkipWs(s, i);
        if (i >= s.size()) return false;
        if (s[i] == '"') {
            std::string val;
            if (!jsonParseString(s, i, val)) return false;
            out.fields[prefix + key] = val;
        } else if (s[i] == '{') {
            if (!jsonParseObject(s, i, prefix + key + ".", out)) return false;
        } else if (s[i] == '[') {   // arrays: skip balanced (unused by the subset)
            int depth = 0;
            do {
                if (s[i] == '[') depth++;
                else if (s[i] == ']') depth--;
                else if (s[i] == '"') { std::string sk; if (!jsonParseString(s, i, sk)) return false; continue; }
                i++;
            } while (i < s.size() && depth > 0);
        } else {   // number / true / false / null
            size_t start = i;
            while (i < s.size() && s[i] != ',' && s[i] != '}') i++;
            std::string raw = s.substr(start, i - start);
            while (!raw.empty() && (raw.back() == ' ' || raw.back() == '\t')) raw.pop_back();
            out.fields[prefix + key] = raw;
        }
        jsonSkipWs(s, i);
        if (i < s.size() && s[i] == ',') { i++; continue; }
    }
}

// ASCII-SAFE output: every non-ASCII code point is written as \uXXXX (a surrogate pair above the
// BMP), the way agwinterm's server escapes its JSON. Raw UTF-8 in a reply is valid JSON, but it
// reaches most callers through agwintermctl's stdout and then a shell that decodes native output
// with ITS console code page — a caller without a UTF-8 profile (pwsh -NoProfile, a CI runner)
// read "café 🚀" back as "caf? ??" from `tree` while the raw pipe carried it intact (P3-lite,
// the round-1 suite run). Escaped, the bytes on the wire are ASCII and no code page on either side
// can change what the caller reads. A malformed UTF-8 byte is written as \ufffd rather than passed
// through, so the reply stays valid JSON whatever a session's name was built from.
inline std::string jsonEscape(const std::string& s) {
    std::string out;
    auto u16 = [&out](unsigned cp) {
        char b[16];
        if (cp >= 0x10000) {
            cp -= 0x10000;
            sprintf_s(b, "\\u%04x\\u%04x", 0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
        } else sprintf_s(b, "\\u%04x", cp);
        out += b;
    };
    for (size_t i = 0; i < s.size(); ++i) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) { char b[8]; sprintf_s(b, "\\u%04x", c); out += b; }
                else if (c < 0x80) out += (char)c;
                else {
                    // Decode one UTF-8 sequence; anything malformed becomes U+FFFD and consumes one byte.
                    int len = (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : (c & 0xF8) == 0xF0 ? 4 : 0;
                    unsigned cp = len == 2 ? (c & 0x1F) : len == 3 ? (c & 0x0F) : len == 4 ? (c & 0x07) : 0;
                    bool ok = len > 0 && i + len <= s.size();
                    for (int k = 1; ok && k < len; ++k) {
                        unsigned char cc = (unsigned char)s[i + k];
                        if ((cc & 0xC0) != 0x80) ok = false; else cp = (cp << 6) | (cc & 0x3F);
                    }
                    if (ok && (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) ||
                               (len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) || (len == 4 && cp < 0x10000)))
                        ok = false;   // out of range, a surrogate, or an overlong encoding
                    if (ok) { u16(cp); i += len - 1; }
                    else u16(0xFFFD);
                }
        }
    }
    return out;
}

inline std::string ctlOk(const std::string& resultJson) { return "{\"ok\":true,\"result\":" + resultJson + "}"; }
inline std::string ctlOkStr(const std::string& s) { return ctlOk("\"" + jsonEscape(s) + "\""); }
inline std::string ctlErr(const std::string& msg) { return "{\"ok\":false,\"error\":\"" + jsonEscape(msg) + "\"}"; }
