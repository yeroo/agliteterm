#include "../src/styled_text.h"
#include <cstdio>
#include <vector>

static int checks = 0, failures = 0;
static void check(bool yes, const char* name) { ++checks; if (!yes) { ++failures; std::printf("FAIL %s\n", name); } }
static FfiCell cell(int rune, uint32_t attrs = 0, uint32_t width = 1) {
    FfiCell c{}; c.rune = rune; c.attrs = attrs; c.width = width; return c;
}
static std::string runs(const std::vector<FfiCell>& cells) { return styled_text::rowRunsJson(cells.data(), (uint32_t)cells.size()); }
int main() {
    std::vector<FfiCell> row{cell('a'), cell('b', kAttrDim), cell('c', kAttrDim | kAttrBold |
        kAttrItalic | kAttrUnderline | kAttrInverse | kAttrStrike)};
    auto json = runs(row);
    check(json.find("\"text\":\"a\",\"faint\":false") != std::string::npos, "plain flag");
    check(json.find("\"text\":\"b\",\"faint\":true") != std::string::npos, "faint split");
    check(json.find("\"text\":\"c\",\"faint\":true,\"bold\":true,\"italic\":true,\"underline\":true,\"inverse\":true,\"strike\":true") != std::string::npos, "all flags");
    row = {cell('a'), cell('b')}; row[0].fg = 0; row[1].fg = 0xffffff;
    check(runs(row).find("\"text\":\"ab\"") != std::string::npos, "same spec merges despite resolved color");
    row[0].fgKind = 1; row[0].fgIndex = 196; row[1].fgKind = 2; row[1].fgRgb = 0x0102ff;
    json = runs(row);
    check(json.find("\"fg\":\"idx:196\"") != std::string::npos && json.find("\"fg\":\"#0102ff\"") != std::string::npos, "different specs split");
    row = {cell('A'), cell(0x1f680, kAttrDim, 2), cell(0, 0, 0), cell('B')};
    json = runs(row);
    check(json.find("\"col\":1,\"width\":2,\"text\":\"\\ud83d\\ude80\"") != std::string::npos, "astral wide glyph");
    check(json.find("\"col\":3,\"width\":1,\"text\":\"B\"") != std::string::npos, "column after spacer");
    check(styled_text::rowText(row.data(), (uint32_t)row.size()) == "A\xf0\x9f\x9a\x80" "B", "plain text skips spacer");
    row = {cell('x'), cell(' ', kAttrInverse), cell(' ', kAttrInverse)};
    check(runs(row).find("\"text\":\"x\"") != std::string::npos && runs(row).find("inverse\":true") == std::string::npos, "styled trailing spaces trimmed");
    row = {cell('x'), cell(' ', kAttrInverse), cell('y')};
    check(runs(row).find("\"text\":\" \"") != std::string::npos, "interior styled space kept");
    row = {cell(0), cell(' ')};
    check(styled_text::rowText(row.data(), 2).empty() && runs(row) == "[]", "all blank row");
    row = {cell('"'), cell('\\')};
    check(runs(row).find("\"text\":\"\\\"\\\\\"") != std::string::npos, "JSON escaping");
    row = {cell('a'), cell('b')}; row[0].bgKind = 1; row[0].bgIndex = 3;
    check(runs(row).find("\"bg\":\"idx:3\"") != std::string::npos, "background spec");
    std::printf("styled-text-unit: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
