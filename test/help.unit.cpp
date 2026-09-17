#include "../src/help.h"
#include <cstdio>
static int checks=0,failures=0;
static void check(bool yes,const char* what){++checks;if(!yes){++failures;std::printf("FAIL %s\n",what);}}
static bool has(const std::vector<std::wstring>& l,const std::wstring& s){for(const auto& x:l)if(x==s)return true;return false;}
static int indexOf(const std::vector<std::wstring>& l,const std::wstring& prefix){for(size_t i=0;i<l.size();++i)if(l[i].compare(0,prefix.size(),prefix)==0)return (int)i;return -1;}
int main(){
    using namespace help;
    // Headings: capitals only; a parenthetical or a body line never promotes.
    check(isSection(L"GETTING STARTED")&&isSection(L"FOCUS AND NAVIGATION"),"capital headings are sections");
    check(!isSection(L"KEY BINDINGS (keymap.conf)")&&!isSection(L"F1            this help")&&!isSection(L"")&&!isSection(L" X"),"body text and blanks are not sections");
    check(!isSection(L"1234")&&!isSection(std::wstring(60,L'A')),"digits-only and over-long lines are not sections");
    // Rows: the chord pads to the column, a wide chord keeps a gap.
    check(row({L"F2",L"Rename"})==L"F2                  Rename","row pads the chord to twenty columns");
    check(row({std::wstring(24,L'K'),L"Long"})==std::wstring(24,L'K')+L"  Long","a chord wider than the column keeps two spaces");
    // The card: version in the first section, bindings sorted by label, no custom section without input.
    auto plain=lines(L"1.2.3",{{L"Ctrl+Shift+P",L"Command Palette"},{L"Ctrl+Shift+A",L"Select All"},{L"F2",L"copy"}},{},L"");
    check(plain[0]==L"GETTING STARTED"&&plain[1].find(L"agliteterm 1.2.3 ")==0,"version rides the first body line");
    int pal=indexOf(plain,L"Ctrl+Shift+P"),sel=indexOf(plain,L"Ctrl+Shift+A"),cp=indexOf(plain,L"F2");
    check(pal>0&&cp>pal&&sel>cp,"built-in rows sort by label, case-insensitively");
    check(indexOf(plain,L"KEY BINDINGS")<pal,"rows follow the KEY BINDINGS heading");
    check(!has(plain,L"CUSTOM COMMANDS"),"no custom section without custom rows or a leader");
    check(has(plain,L"MORE")&&plain.back().find(L"About")!=std::wstring::npos,"the card ends with MORE");
    check(!has(plain,L"(no built-in action is bound)"),"no placeholder while something is bound");
    auto none=lines(L"9",{},{},L"");
    check(has(none,L"(no built-in action is bound)"),"unbound everything says so instead of an empty section");
    // Custom commands and the leader chord.
    auto custom=lines(L"1",{},{{L"Ctrl+K",L"command:Greet"},{L"leader, G",L"command:Go"}},L"Ctrl+Space");
    int cs=indexOf(custom,L"CUSTOM COMMANDS"),lead=indexOf(custom,L"Ctrl+Space"),greet=indexOf(custom,L"Ctrl+K"),go=indexOf(custom,L"leader, G");
    check(cs>0&&lead>cs&&greet>lead&&go>greet,"custom section: leader chord first, then rows in file order");
    check(custom[lead].find(L"leader chord")!=std::wstring::npos,"the leader row says what it is");
    check(indexOf(custom,L"From keymap.conf")>0&&custom[indexOf(custom,L"From keymap.conf")].find(L"%LOCALAPPDATA%\\agliteterm")!=std::wstring::npos,"the data-folder line carries a real backslash, not a BEL");
    auto leaderOnly=lines(L"1",{},{},L"F12");
    check(has(leaderOnly,L"CUSTOM COMMANDS")&&indexOf(leaderOnly,L"F12")>0,"a leader without sequences still shows the section");
    // Every line fits the 78-column card the host paints (an over-long line is cut with an ellipsis).
    bool fits=true;for(const auto& l:custom)if(l.size()>74)fits=false;for(const auto& l:plain)if(l.size()>74)fits=false;
    check(fits,"no help line exceeds 74 characters");
    // Scroll clamps.
    check(clampScroll(5,10,4)==5&&clampScroll(99,10,4)==6&&clampScroll(-3,10,4)==0,"scroll clamps to the last page and to zero");
    check(clampScroll(3,2,10)==0&&clampScroll(1,5,0)==1,"a short list never scrolls; a zero view counts as one line");
    std::printf("help unit: %d checks, %d failures\n",checks,failures);
    return failures?1:0;
}
