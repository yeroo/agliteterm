#include "../src/overlay_command.h"
#include <iostream>
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    auto line = overlay_command::line(argv[1]);
    if (!overlay_command::fits(std::string(2047, 'x'), 2048) || overlay_command::fits(std::string(2048, 'x'), 2048)) return 3;
    std::cout << line;
}
