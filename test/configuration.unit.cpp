#include "../src/configuration.h"
#include <cstdio>
#include <set>
static int checks = 0, failed = 0;
static void check(bool yes, const char* label) {
    ++checks; if (!yes) ++failed;
    std::printf("%s %s\n", yes ? "PASS" : "FAIL", label);
}
int main() {
    using namespace configuration;
    std::set<std::string> names; std::set<std::wstring> registry;
    for (const auto& key : keys) {
        check(names.insert(key.name).second && registry.insert(key.registry).second, "unique key/registry mapping");
        check(find(key.name) == &key, "key lookup");
        check(valid(key, key.initial), "default is valid");
        uint32_t out = 0x12345678;
        check(parse(key, format(key, key.initial), out) && out == key.initial, "default roundtrip");
        check(!parse(key, "", out) && out == key.initial, "empty refuses without output mutation");
        check(!parse(key, "no-such-value", out), "unknown value refuses");
        check(!parse(key, std::string("1\0x", 3), out), "embedded NUL refuses");
    }
    check(names.size() == 14 && registry.size() == 14, "all fourteen supported keys covered");
    check(find("font-size") == nullptr && find("") == nullptr, "unsupported keys stay unsupported");
    check(normalized(" \tCoPy-On-SeLeCt\r\n") == "copy-on-select", "key normalization");
    auto probe = [](const char* key, const char* text, bool good, uint32_t expected) {
        uint32_t out = 0xdeadbeef;
        bool got = parse(*find(key), text, out);
        check(got == good && out == (good ? expected : 0xdeadbeef), text);
    };
    for (auto word : {"true", "on", "1", " TRUE "}) probe("copy-on-select", word, true, 1);
    for (auto word : {"false", "off", "0", " OFF "}) probe("copy-on-select", word, true, 0);
    for (auto word : {"yes", "toggle", "2", "-1", "1.0"}) probe("copy-on-select", word, false, 0);
    probe("theme", "auto", true, 0); probe("theme", "dark", true, 1);
    probe("theme", "light", true, 2); probe("theme", "classic", true, 3);
    probe("theme", "1", false, 0);
    probe("foreground", "#aBc123", true, 0xabc123);
    for (auto word : {"#123", "123456", "#1234567", "#gg1234", "#12345x"}) probe("foreground", word, false, 0);
    probe("sidebar-font-size", "0", true, 0); probe("sidebar-font-size", "6", true, 6);
    probe("sidebar-font-size", "24", true, 24);
    for (auto word : {"1", "5", "25", "-6", "+6", "6.0", "6x"}) probe("sidebar-font-size", word, false, 0);
    probe("scrollback-lines", "0", true, 0); probe("scrollback-lines", "1000000", true, 1000000);
    for (auto word : {"1000001", "4294967296", "99999999999999999999999999", "-1", "1e3"}) probe("scrollback-lines", word, false, 0);
    std::printf("configuration-unit: %d checks, %d failed\n", checks, failed);
    return failed ? 1 : 0;
}
