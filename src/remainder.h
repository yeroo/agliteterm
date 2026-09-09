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
    if (dir.empty() || dir == "down") return (std::min)(count - 1, from + 1);
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
