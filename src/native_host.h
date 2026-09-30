// What lite tells the pty-host about the terminal it serves (agwinterm #342), host-free.
#pragma once
#include <cstdint>
#include <cstdio>
#include <string>

namespace native_host {
// AGWINTERM_THEME_COLORS in a pane's environment: `rrggbb;rrggbb`, foreground then background.
// The pty-host reads it from the Create request and answers OSC 10 / OSC 11 with it while no
// window is attached: a program that asks during a restart would otherwise wait for an answer
// nobody sends. The host accepts exactly six hex digits a side, so the top byte is masked off.
inline std::string themeColors(uint32_t foreground, uint32_t background) {
    char text[16];
    std::snprintf(text, sizeof text, "%06x;%06x", foreground & 0xFFFFFFu, background & 0xFFFFFFu);
    return text;
}
// The pty-host's ConPTY argument. Always passed: a host started without it keeps the inbox
// conhost, which is what a client older than the query replies expects.
inline const wchar_t* conptyArgument(bool inbox) { return inbox ? L" --conpty inbox" : L" --conpty bundled"; }
}
