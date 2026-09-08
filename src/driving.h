#pragma once
#include <windows.h>
#include <string>
#include <vector>
#include <cstdint>
#include <algorithm>

namespace driving {
// Locale-independent simple lowercasing of one Unicode scalar. The C locale's towlower leaves
// Cyrillic unchanged; use Windows invariant casing without changing the process/thread locale.
inline char32_t lower(char32_t cp) {
    wchar_t src[2], dst[4];
    int n = 1;
    if (cp > 0xFFFF && cp <= 0x10FFFF) {
        src[0] = (wchar_t)(0xD800 + ((cp - 0x10000) >> 10));
        src[1] = (wchar_t)(0xDC00 + ((cp - 0x10000) & 0x3FF));
        n = 2;
    } else src[0] = (wchar_t)cp;
    int count = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, src, n, dst, 4, nullptr, nullptr, 0);
    if (count == 1) return dst[0];
    if (count == 2 && dst[0] >= 0xD800 && dst[0] <= 0xDBFF && dst[1] >= 0xDC00 && dst[1] <= 0xDFFF)
        return 0x10000 + ((dst[0] - 0xD800) << 10) + dst[1] - 0xDC00;
    return cp;   // no expanding case fold: endpoints always map to whole cells
}
inline std::u32string queryPoints(const std::wstring& text) {
    std::u32string result;
    for (size_t i = 0; i < text.size(); ++i) {
        char32_t cp = text[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < text.size() && text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF)
            cp = 0x10000 + ((cp - 0xD800) << 10) + text[++i] - 0xDC00;
        result.push_back(lower(cp));
    }
    return result;
}
struct Row {
    std::u32string text, folded;
    std::vector<int> starts, ends;
    bool sameCells(const Row& other) const {
        return text == other.text && starts == other.starts && ends == other.ends;
    }
};
template<class Cell> inline Row rowCells(const Cell* cells, int cols) {
    Row row;
    for (int c = 0; c < cols; ++c) {
        if (!cells[c].width && c > 0 && cells[c - 1].width == 2) continue;
        char32_t cp = cells[c].rune ? (char32_t)cells[c].rune : U' ';
        row.text.push_back(cp);
        row.folded.push_back(lower(cp));
        row.starts.push_back(c);
        row.ends.push_back((std::min)(cols, c + (cells[c].width == 2 ? 2 : 1)));
    }
    return row;
}
struct Span { int first, end; };
inline std::vector<Span> matches(const Row& row, const std::u32string& query) {
    std::vector<Span> result;
    if (query.empty()) return result;
    size_t at = 0;
    while ((at = row.folded.find(query, at)) != std::u32string::npos) {
        result.push_back({ row.starts[at], row.ends[at + query.size() - 1] });
        at += query.size();
    }
    return result;
}
}
