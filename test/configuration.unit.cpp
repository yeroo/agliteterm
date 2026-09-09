#include "../src/configuration.h"
#include "../src/profiles.h"
#include "../src/shell_configuration.h"
#include <cstdio>
#include <set>
#include <future>
#include <thread>
#include <cstdlib>
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
        check(parse(key, "", out) == (key.kind == Kind::Hotkey) && out == key.initial, "empty only disables hotkey");
        check(!parse(key, "no-such-value", out), "unknown value refuses");
        check(!parse(key, std::string("1\0x", 3), out), "embedded NUL refuses");
    }
    check(names.size() == 20 && registry.size() == 20, "all twenty supported keys covered");
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
    profiles::Catalog catalog; std::string error;
    for(auto key:{"bar","beam","line"})probe("cursor-style",key,true,0);
    for(auto key:{"block","box"})probe("cursor-style",key,true,1);
    for(auto key:{"underline","underscore"})probe("cursor-style",key,true,2);
    probe("cursor-blink","yes",true,1);probe("cursor-blink","no",true,0);
    probe("cursor-blink-ms","2147483647",true,2147483647);probe("cursor-blink-ms","0",false,0);
    probe("cursor-blink-ms","2147483648",false,0);
    probe("quick-terminal-size","40",true,40);probe("quick-terminal-size","90",true,90);
    probe("quick-terminal-size","39",false,0);probe("quick-terminal-size","91",false,0);
    for(auto raw:{"ctrl+alt+backtick","alt+f11","ctrl+shift+a","ctrl+1"}){
        uint32_t packed=0,again=0;check(parse(*find("quick-terminal-hotkey"),raw,packed)&&parse(*find("quick-terminal-hotkey"),format(*find("quick-terminal-hotkey"),packed),again)&&packed==again,"hotkey canonical roundtrip");
    }
    for(auto raw:{"ctrl+ctrl+a","shift+a","f5","win+a","ctrl+f12","ctrl++a","ctrl+a+","ctrl+a+b"})probe("quick-terminal-hotkey",raw,false,0);
    const std::string validProfile = R"({"default":"test","profiles":[{"name":"Test","command":"pwsh.exe","args":["","a b","x\\y","\"quoted\"","\ud83d\ude80"],"cwd":"C:\\work"}]})";
    check(profiles::parse(validProfile, catalog, error) && error.empty(), "valid profile catalog");
    check(catalog.find("TEST") && !catalog.find("Tes"), "profile names exact, ASCII case insensitive");
    check(catalog.entries[0].args == std::vector<std::string>({"", "a b", "x\\y", "\"quoted\"", "\xf0\x9f\x9a\x80"}), "profile argv preserves empty, whitespace, slash, quote, astral");
    check(profiles::parse("\xef\xbb\xbf\r\n" + validProfile, catalog, error), "UTF-8 BOM and JSON whitespace");
    auto badCatalog = [&](const std::string& s) {
        const auto previous = catalog.entries[0].args;
        check(!profiles::parse(s, catalog, error) && !error.empty() && catalog.entries[0].args == previous, "bad catalog preserves output");
    };
    for (const auto& bad : {"", "{}", "[]", "null", "{", "{\"default\":1}", "{\"default\":\"x\",\"profiles\":[]}",
            "{\"default\":\"x\",\"default\":\"x\",\"profiles\":[]}", "{\"default\":\"x\",\"profiles\":[],}",
            "{\"default\":\"x\",\"profiles\":[null]}"}) badCatalog(bad);
    auto envelope = [](const std::string& entry) { return "{\"default\":\"x\",\"profiles\":[" + entry + "]}"; };
    for (const std::string& field : {"\"env\":{\"K\":\"V\"}", "\"elevate\":true", "\"icon\":\"glyph\"", "\"unknown\":null",
            "\"args\":false", "\"args\":[1]", "\"args\":[\"\\u0000\"]", "\"cwd\":\"\\u0000\"", "\"cwd\":true",
            "\"args\":[\"\\uD800\"]", "\"args\":[\"\\uDC00\"]", "\"args\":[\"\\uD800\\u0000\"]",
            "\"args\":[\"\\uXXXX\"]", "\"args\":[\"\\q\"]", "\"args\":[\"x\",]", "\"args\":[\"a\\tb\"]", "\"args\":[\"a\\nb\"]"})
        badCatalog(envelope("{\"name\":\"x\",\"command\":\"pwsh.exe\"," + field + "}"));
    for (const auto& entry : {"{}", "{\"name\":\"x\"}", "{\"name\":\"x\",\"command\":\" \"}",
            "{\"name\":\"x\",\"command\":\"cmd\",\"name\":\"x\"}", "{\"name\":\"y\",\"command\":\"cmd\"}"}) badCatalog(envelope(entry));
    badCatalog(envelope("{\"name\":\"x\",\"command\":\"cmd\"},{\"name\":\"X\",\"command\":\"cmd\"}"));
    badCatalog(validProfile + "false");
    badCatalog(std::string(1024 * 1024 + 1, ' '));
    for (const auto& bytes : {std::string("\xc0\xaf"), std::string("\xed\xa0\x80"), std::string("\xf4\x90\x80\x80"), std::string("\xe2\x82")})
        badCatalog(envelope("{\"name\":\"x\",\"command\":\"" + bytes + "\"}"));
    check(profiles::parse(envelope("{\"name\":\"x\",\"command\":\"cmd.exe\",\"args\":null,\"cwd\":null,\"env\":{},\"icon\":null,\"elevate\":false}"), catalog, error), "optional inert canonical fields accepted");
    for (int count : {16, 17}) {
        std::string args; for (int n = 0; n < count; ++n) args += (n ? "," : "") + std::string("\"\"");
        check(profiles::parse(envelope("{\"name\":\"x\",\"command\":\"cmd\",\"args\":[" + args + "]}"), catalog, error) == (count == 16), "wire argument count boundary");
    }
    for (const auto& limit : {std::make_pair("name",128), std::make_pair("command",259), std::make_pair("cwd",259)}) {
        for (int length : {limit.second, limit.second + 1}) {
            const std::string value(length, 'x');
            const std::string entry = "{\"name\":\"" + (std::string(limit.first) == "name" ? value : "x") + "\",\"command\":\"" +
                (std::string(limit.first) == "command" ? value : "cmd") + "\",\"cwd\":\"" + (std::string(limit.first) == "cwd" ? value : "") + "\"}";
            const std::string input = std::string(limit.first) == "name" ? "{\"default\":\"" + value + "\",\"profiles\":[" + entry + "]}" : envelope(entry);
            check(profiles::parse(input, catalog, error) == (length == limit.second), "profile wire field boundary");
        }
    }
    for (const auto& app : {"powershell.exe", "C:\\Windows\\PowerShell.EXE", "pwsh", "C:/bin/pwsh.exe"}) check(shell_configuration::powershell(app), "exact PowerShell executable accepted");
    for (const auto& app : {"notpowershell.exe", "pwsh-helper.exe", "C:/pwsh/cmd.exe", "cmd.exe", ""}) check(!shell_configuration::powershell(app), "substring/non-PowerShell executable refused");
    check(shell_configuration::literal("C:\\theme's $x;name.omp.json") == "'C:\\theme''s $x;name.omp.json'", "PowerShell literal quotes metacharacters");
    for (int flags = 0; flags < 16; ++flags) {
        std::string b = flags & 1 ? "B" : "", r = flags & 2 ? "R" : "", k = flags & 4 ? "K" : "";
        const auto expected = !b.empty() ? b : !r.empty() ? r : (flags & 8) ? k : "";
        check(shell_configuration::replay(b, r, k, (flags & 8) != 0) == expected, "complete binding/pin/captured/opt-in precedence space");
    }
    {
        shell_configuration::InputGate gate;
        std::string bytes;
        check(gate.write(false, false, [&] { bytes += "REPLY"; }), "protocol response transfer succeeds");
        check(gate.write(true, true, [&] { bytes += "INIT"; }), "protocol response does not taint pristine input");
        check(!gate.write(true, true, [&] { bytes += "BAD"; }) && bytes == "REPLYINIT", "second pristine write refuses without bytes");
        check(gate.write(true, false, [&] { bytes += "DRAFT"; }) && bytes == "REPLYINITDRAFT", "normal input remains allowed after initialization");
        shell_configuration::InputGate other;
        check(other.write(true, true, [] {}), "input gates are per pane");
        shell_configuration::InputGate failedWrite;
        try { failedWrite.write(true, false, [] { throw 1; }); } catch (int) {}
        check(!failedWrite.write(true, true, [] {}), "failed transfer conservatively retains input history");
    }
    for (bool initializationFirst : {false, true}) {
        shell_configuration::InputGate gate;
        std::promise<void> firstEntered, secondStarted, releaseFirst, firstDone, secondDone;
        auto entered = firstEntered.get_future(), started = secondStarted.get_future();
        auto done1 = firstDone.get_future(), done2 = secondDone.get_future();
        auto await = [&](std::future<void>& signal) {
            if (signal.wait_for(std::chrono::seconds(10)) != std::future_status::ready) {
                check(false, "input serialization test timed out"); std::exit(1);
            }
        };
        auto release = releaseFirst.get_future().share();
        std::string bytes; bool firstOk = false, secondOk = false;
        std::thread first([&] {
            firstOk = gate.write(true, initializationFirst, [&] {
                firstEntered.set_value(); release.wait();
                bytes += initializationFirst ? "INIT\r" : "DRAFT; ";
            });
            firstDone.set_value();
        });
        await(entered); // first writer holds the gate through the controlled transfer
        std::promise<void> replyDone; auto replied = replyDone.get_future();
        bool replyOk = false;
        std::thread reply([&] {
            replyOk = gate.write(false, false, [] {});
            replyDone.set_value();
        });
        await(replied); reply.join();
        check(replyOk, "reader protocol reply does not wait behind editing input");
        std::thread second([&] {
            secondStarted.set_value();
            secondOk = gate.write(true, !initializationFirst, [&] {
                bytes += initializationFirst ? "DRAFT; " : "INIT\r";
            });
            secondDone.set_value();
        });
        await(started); releaseFirst.set_value(); await(done1); await(done2); first.join(); second.join();
        check(firstOk && secondOk == initializationFirst && bytes == (initializationFirst ? "INIT\rDRAFT; " : "DRAFT; "),
              initializationFirst ? "OMP first: concurrent draft follows complete initialization" : "draft first: concurrent OMP refuses without submission");
    }
    std::printf("configuration-unit: %d checks, %d failed\n", checks, failed);
    return failed ? 1 : 0;
}
