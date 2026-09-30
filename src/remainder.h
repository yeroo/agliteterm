#pragma once
#include <string>
#include <algorithm>

namespace lite_remainder {
inline bool toggle(const std::string& op, bool current, bool& next) {
    if (op.empty() || op == "toggle") next = !current;
    else if (op == "on") next = true;
    else if (op == "off") next = false;
    else if (op == "state" || op == "get") next = current;
    else return false;
    return true;
}
inline int destination(int from, int count, const std::string& dir) {
    if (from < 0 || from >= count) return -1;
    if (dir == "up") return (std::max)(0, from - 1);
    if (dir == "down") return (std::min)(count - 1, from + 1);
    if (dir == "top") return 0;
    if (dir == "bottom") return count - 1;
    return -1;
}
inline int remap(int index, int from, int to) {
    if (index == from) return to;
    if (from < to && index > from && index <= to) return index - 1;
    if (from > to && index >= to && index < from) return index + 1;
    return index;
}
// Notification categories (agwinterm #335): the priority of an unread notice. The highest among a
// session's unread notices picks the pill colour; an untyped notice is `attention`, the red every
// notice had. The word is exact and lowercase, as agwintermctl sends it.
enum class Category { Ok = 0, Normal = 1, Attention = 2 };
inline bool category(const std::string& text, Category& out) {
    if (text == "ok") out = Category::Ok;
    else if (text == "normal") out = Category::Normal;
    else if (text == "attention") out = Category::Attention;
    else return false;
    return true;
}
inline Category highest(Category a, Category b) { return static_cast<int>(a) >= static_cast<int>(b) ? a : b; }
inline const char* name(Category c) { return c == Category::Ok ? "ok" : c == Category::Normal ? "normal" : "attention"; }
// Pill text: dark on a light pill, white on a dark one - agwinterm's rule (Lum >= 0.55 on the
// 0.299 / 0.587 / 0.114 weights), so a user-chosen yellow stays readable. rgb = packed 0xRRGGBB.
inline bool darkTextOn(unsigned rgb) {
    const unsigned r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255;
    return 299 * r + 587 * g + 114 * b >= 550 * 255;
}
inline int columns(int count) { return count > 4 ? 3 : count > 1 ? 2 : 1; }
inline int navigate(int at, int count, int key) {
    if (!count) return 0;
    at = (std::max)(0, (std::min)(count - 1, at));
    const int cols = columns(count);
    if (key == 36) return 0; // Home
    if (key == 35) return count - 1; // End
    if (key == 37 && at % cols) return at - 1;
    if (key == 39 && at % cols != cols - 1 && at + 1 < count) return at + 1;
    if (key == 38 && at >= cols) return at - cols;
    if (key == 40 && at + cols < count) return at + cols;
    return at;
}
}
