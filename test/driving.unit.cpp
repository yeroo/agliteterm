#include "../src/driving.h"
#include "../src/control.h"
#include "../src/workspace_identity.h"
#include <cstdio>
#include <cstdlib>

struct Cell { int32_t rune; uint32_t width; };
static int checks;
static void check(bool ok, const char* name) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", name); std::exit(1); }
    ++checks; std::printf("PASS %s\n", name);
}
int main() {
    WorkspaceNames workspaces{L"first", L"duplicate", L"duplicate"};
    const auto destination = workspaces.token(2);
    int active = 1; // another caller selects a different workspace while the host create waits
    check(workspaces.destination(destination) == 2 && active == 1, "create destination is independent of current workspace");
    workspaces[2] = L"renamed";
    check(workspaces.destination(destination) == 2, "rename preserves in-flight identity");
    workspaces.erase(workspaces.begin());
    check(workspaces.destination(destination) == 1, "deleting an earlier workspace reindexes the same identity");
    workspaces.erase(workspaces.begin() + 1);
    workspaces.push_back(L"renamed");
    check(workspaces.destination(destination) == 0 && workspaces.token(1) != destination, "deleted workspace falls back, not to a replacement with the same name/index");
    workspaces = std::vector<std::wstring>{L"duplicate", L"renamed"};
    check(workspaces.index(destination) == -1, "whole catalog restore does not revive stale identities");
    for (int from = 0; from < 3; ++from) for (int to = 0; to < 3; ++to) {
        WorkspaceNames reordered{L"a", L"b", L"c"};
        const auto moving = reordered.token(from);
        const auto name = reordered[from];
        reordered.move(from, to);
        check(reordered.index(moving) == to && reordered[to] == name, "workspace reordering moves name and identity together");
    }
    Cell ascii[] = {{'x',1},{' ',1},{'I',1},{'g',1},{'l',1},{'A',1},{' ',1}};
    auto a = driving::rowCells(ascii, 7);
    auto hits = driving::matches(a, driving::queryPoints(L"igLA"));
    check(hits.size() == 1 && hits[0].first == 2 && hits[0].end == 6, "ASCII case and cell endpoints");
    check(driving::matches(a, U"").empty(), "empty query");
    check(driving::matches(a, U"absent").empty(), "no match");
    Cell cyrillic[] = {{'x',1},{'x',1},{' ',1},{0x438,1},{0x433,1},{0x43B,1},{0x430,1},{' ',1}};
    auto c = driving::rowCells(cyrillic, 8);
    hits = driving::matches(c, driving::queryPoints(L"\x418\x413\x41B\x410"));
    check(hits.size() == 1 && hits[0].first == 3 && hits[0].end == 7, "Cyrillic invariant casing, not UTF-8 offsets");
    Cell wide[] = {{0x6F22,2},{0,0},{0x5B57,2},{0,0},{' ',1},{'n',1},{'e',1},{'e',1},{'d',1},{'l',1},{'e',1}};
    auto w = driving::rowCells(wide, 11);
    hits = driving::matches(w, U"needle");
    check(hits.size() == 1 && hits[0].first == 5 && hits[0].end == 11, "needle after two wide glyphs");
    hits = driving::matches(w, driving::queryPoints(L"\x5B57"));
    check(hits.size() == 1 && hits[0].first == 2 && hits[0].end == 4, "wide match includes spacer");
    Cell astral[] = {{'x',1},{0x1F600,2},{0,0},{'y',1}};
    auto e = driving::rowCells(astral, 4);
    hits = driving::matches(e, driving::queryPoints(L"\xD83D\xDE00"));
    check(hits.size() == 1 && hits[0].first == 1 && hits[0].end == 3, "astral query decoded to one scalar");
    check(driving::lower(0x10400) == 0x10428, "astral Deseret case mapping");
    check(w.sameCells(driving::rowCells(wide, 11)), "unchanged row proof");
    wide[0].rune = 'z';
    check(!w.sameCells(driving::rowCells(wide, 11)), "changed row invalidates proof");
    wide[0].rune = 0x6F22; wide[0].width = 1;
    check(!w.sameCells(driving::rowCells(wide, 11)), "changed widths invalidate proof");
    Cell repeat[] = {{'a',1},{'a',1},{'a',1},{'a',1},{'a',1}};
    hits = driving::matches(driving::rowCells(repeat, 5), U"aa");
    check(hits.size() == 2 && hits[1].first == 2, "row-local nonoverlapping matches");
    const std::string commands[] = {"Claude --Resume C:\\Work\\A", "echo \"quoted\"\tvalue\nnext\r", std::string("a\0b",3), ""};
    for (const auto& command : commands) {
        std::string encoded = jsonEscape(command), decoded;
        check(encoded.find_first_of("\t\n\r") == std::string::npos && driving::decodeCommandField(encoded, decoded) && decoded == command,
              "R/B JSON-content field round-trip");
    }
    const std::string malformed[] = {"C:\\Work", "\\", "\\x41", "\\u123", "\\u12xz", "\\uD800", "\\uDC00", "\\uD800\\u0041", "unescaped\"quote", "raw\nline", std::string("\xC0\xAF",2), std::string("\xED\xA0\x80",3)};
    for (const auto& field : malformed) {
        std::string decoded = "unchanged";
        check(!driving::decodeCommandField(field, decoded) && decoded == "unchanged", "malformed replay field rejected without partial output");
    }
    std::string decoded;
    check(driving::decodeCommandField("\\uD83D\\uDE00", decoded) && decoded == "\xF0\x9F\x98\x80", "escaped surrogate pair produces UTF-8 scalar");
    check(driving::decodeCommandField("игла", decoded) && decoded == "игла", "literal valid UTF-8 is preserved");
    std::printf("%d driving unit checks passed\n", checks);
    return 0;
}
