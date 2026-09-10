#include "../src/overlay_command.h"
#include <iostream>
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    if (overlay_command::encode("") != "" || overlay_command::encode("f") != "Zg==" ||
        overlay_command::encode("fo") != "Zm8=" || overlay_command::encode("foo") != "Zm9v" ||
        overlay_command::encode("\xE2\x98\x83") != "4piD") return 4;
    if (!overlay_command::fits(overlay_command::line(overlay_command::encode(std::string(670, 'x'))), 2048)) return 5;
    auto line = overlay_command::line(argv[1]);
    if (!overlay_command::fits(std::string(2047, 'x'), 2048) || overlay_command::fits(std::string(2048, 'x'), 2048)) return 3;
    std::cout << line;
}
