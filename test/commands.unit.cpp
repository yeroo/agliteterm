#include "../src/commands.h"
#include <cstdio>
static int checks = 0, failures = 0;
static void check(bool value, const char* name) { ++checks; if (!value) { ++failures; std::printf("FAIL %s\n",name); } }
int main() {
    for (const auto& key : {"a","0","f1","f12","tab","enter","escape","space","left","right","up","down",
         "comma","period","slash","semicolon","quote","backtick","minus","equals","lbracket","rbracket","backslash"}) {
        check(commands::chord(key) != 0,"plain chord");
        check(commands::chord("ctrl+alt+shift+"+std::string(key)) == (commands::chord(key)|0x700),"all modifiers");
    }
    for (const auto& key : {"", "+a", "a+", "ctrl", "ctrl++a", "a+b", "f0", "f13", "banana", "ctrl+☃"}) check(!commands::chord(key),"invalid chord refuses");
    check(commands::chord("Control+OPTION+SHIFT+Esc")==commands::chord("shift+alt+ctrl+escape"),"canonical modifiers and aliases");
    std::map<std::string,int> actions{{"select_all",1}}; commands::Catalog catalog; std::string error;
    auto parse = [&](const std::string& text){return commands::parse(text,actions,catalog,error);};
    check(parse("command Test = echo a=b # literal\nmap ctrl+b = command:TEST\nleader=ctrl+k\nmap leader x = select_all"),"full catalog");
    check(catalog.find("test") && catalog.find("Test")->text=="echo a=b # literal","exact case-insensitive label and literal body");
    check(!catalog.find("Te"),"no prefix matching");
    check(catalog.binding(commands::chord("ctrl+b"),false)!=nullptr && !catalog.binding(commands::chord("ctrl+b"),true),"leader namespaces distinct");
    check(catalog.binding(commands::chord("x"),true)->action=="select_all","leader builtin");
    for (const auto& mode : {"send","new","overlay","detached"}) check(parse("command ["+std::string(mode)+"] X = text") && catalog.commands[0].mode==mode,"all run modes");
    for (const auto& bad : {"command [bad] X = text", "command [new X = text", "command =x", "command X =",
         "command X = one\ncommand x = two", "leader=ctrl", "map x=unknown", "map x=command:missing", "map leader x=select_all",
         "ignored=value", "map x", "command A\tB=text"}) {
        auto before=catalog.commands[0].text;
        check(!parse(bad) && catalog.commands[0].text==before,"bad reload preserves previous catalog");
    }
    check(!parse(std::string(1048577,' ')),"oversized input refuses");
    check(!parse(std::string("command X=a\0b",13)),"NUL refuses");
    check(parse("\xef\xbb\xbf# bom\r\ncommand X = hi\r\nmap x=command:X\r\nmap x=select_all"),"BOM CRLF and replacement binding");
    check(catalog.binding(commands::chord("x"),false)->action=="select_all","last binding wins");
    std::map<std::string,std::string> values{{"AGW_SESSION","test"},{"AGW_CWD","C:\\a b"}};
    check(commands::expand("{AGW_SESSION}:{AGW_CWD}:{AGW_UNKNOWN}:{AGW_lower}",values)=="test:C:\\a b::{AGW_lower}","tokens known unknown and non-token");
    check(commands::expand("{AGW_SESSION",values)=="{AGW_SESSION","unterminated token literal");
    check(commands::expand("{AGW_SESSION}{AGW_SESSION}",values)=="testtest","repeated token");
    check(parse("") && catalog.commands.empty() && !catalog.leader,"empty catalog clears");
    std::printf("commands-unit: %d checks, %d failed\n",checks,failures); return failures?1:0;
}
