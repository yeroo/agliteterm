#pragma once
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <string>
#include <algorithm>
#include <utility>
#include "control.h"

// Core ABI v18 cell layout; pinned by kRequiredAbi in main.cpp. Re-check against lib.rs on every
// ABI bump: emu_copy_grid and emu_copy_history_row write this exact layout.
struct FfiCell {
    int32_t rune;
    uint32_t fg, bg, attrs, width;
    uint32_t fgKind, fgIndex, fgRgb;
    uint32_t bgKind, bgIndex, bgRgb;
};
static constexpr uint32_t kAttrBold = 1, kAttrItalic = 2, kAttrUnderline = 4,
                          kAttrInverse = 8, kAttrDim = 16, kAttrStrike = 32;

namespace styled_text {
inline std::string cellText(const FfiCell& cell) {
    int cp = cell.rune ? cell.rune : ' ';
    wchar_t wbuf[2];
    int wn = 0;
    if (cp > 0xFFFF) {
        wbuf[wn++] = (wchar_t)(0xD800 + ((cp - 0x10000) >> 10));
        wbuf[wn++] = (wchar_t)(0xDC00 + ((cp - 0x10000) & 0x3FF));
    } else wbuf[wn++] = (wchar_t)cp;
    char u8[8];
    int n8 = WideCharToMultiByte(CP_UTF8, 0, wbuf, wn, u8, sizeof u8, nullptr, nullptr);
    return std::string(u8, n8);
}
inline std::string rowText(const FfiCell* cells, uint32_t cols) {
    std::string line;
    for (uint32_t c = 0; c < cols; ++c)
        if (cells[c].width) line += cellText(cells[c]);
    while (!line.empty() && line.back() == ' ') line.pop_back();
    return line;
}
inline std::string colorSpec(uint32_t kind, uint32_t index, uint32_t rgb) {
    if (kind == 1) return "idx:" + std::to_string(index);
    if (kind == 2) {
        char s[8];
        std::snprintf(s, sizeof s, "#%06x", rgb & 0xffffff);
        return s;
    }
    return "default";
}
inline std::string rowRunsJson(const FfiCell* cells, uint32_t cols) {
    // Plain text trims only ASCII spaces. Find the same end before grouping runs, so a
    // differently styled blank suffix cannot leak into the styled reply.
    uint32_t limit = 0;
    for (uint32_t c = 0; c < cols; ++c)
        if (cells[c].width && cells[c].rune != 0 && cells[c].rune != ' ') limit = c + 1;
    std::string out = "[";
    std::string runText, fg, bg;
    uint32_t attrs = 0, start = 0, end = 0;
    bool have = false;
    auto flush = [&]() {
        if (!have) return;
        if (out.size() > 1) out += ',';
        out += "{\"col\":" + std::to_string(start) + ",\"width\":" + std::to_string(end - start) +
               ",\"text\":\"" + jsonEscape(runText) + "\",\"faint\":" + ((attrs & kAttrDim) ? "true" : "false") +
               ",\"bold\":" + ((attrs & kAttrBold) ? "true" : "false") +
               ",\"italic\":" + ((attrs & kAttrItalic) ? "true" : "false") +
               ",\"underline\":" + ((attrs & kAttrUnderline) ? "true" : "false") +
               ",\"inverse\":" + ((attrs & kAttrInverse) ? "true" : "false") +
               ",\"strike\":" + ((attrs & kAttrStrike) ? "true" : "false") +
               ",\"fg\":\"" + fg + "\",\"bg\":\"" + bg + "\"}";
    };
    for (uint32_t c = 0; c < limit; ++c) {
        const FfiCell& cell = cells[c];
        if (!cell.width) continue;
        std::string nextFg = colorSpec(cell.fgKind, cell.fgIndex, cell.fgRgb);
        std::string nextBg = colorSpec(cell.bgKind, cell.bgIndex, cell.bgRgb);
        if (!have || attrs != cell.attrs || fg != nextFg || bg != nextBg) {
            flush();
            have = true; start = c; runText.clear(); attrs = cell.attrs;
            fg = std::move(nextFg); bg = std::move(nextBg);
        }
        end = (std::min)(cols, c + cell.width);
        runText += cellText(cell);
    }
    flush();
    return out + "]";
}
}
