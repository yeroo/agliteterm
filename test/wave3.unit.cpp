#include "../src/wave3.h"
#include <cstdio>
#include <functional>
#pragma comment(lib,"normaliz.lib")
static int checks=0,failures=0;
static void check(bool yes,const char* what){++checks;if(!yes){++failures;std::printf("FAIL %s\n",what);}}
static void refuses(const std::function<void()>& f){bool refused=false;try{f();}catch(const std::invalid_argument&){refused=true;}check(refused,"invalid input refuses");}
int main(){
    using namespace wave3;
    for(auto json:{"{\"n\":0}","{\"n\":-1}","{\"n\":1.25}","{\"n\":1e2}"}){
        auto v=parse(json);check(field(v,"n")->kind==Value::Number,"opt-in typed number");
        Value original;check(!profiles::detail::Parser(json).parse(original),"profile numeric policy unchanged");
    }
    for(auto json:{"{\"n\":01}","{\"n\":-}","{\"n\":1.}","{\"n\":1e}","{\"n\":1e+}","{\"n\":1,\"n\":2}","{}x"})refuses([&]{parse(json);});
    for(auto json:{"{\"message\":true}","{\"message\":\" \"}","{\"message\":\"x\",\"size-percent\":\"50\"}","{\"message\":\"x\",\"size-percent\":1.5}","{\"message\":\"x\",\"unknown\":null}","{\"message\":\"x\\n\"}"})refuses([&]{hud(parse(json));});
    auto h=hud(parse("{\"message\":\"Cafe\\u0301\",\"detail\":\"\",\"size-percent\":100,\"color\":\"ABCDEF\"}"));
    check(h.message=="Café"&&h.detail.empty()&&h.width==80&&h.background=="#abcdef","HUD normalization and bounded width");
    check(h.json().find("\"detail\":null")!=std::string::npos,"HUD absent detail is null");
    for(auto p:positions){h.position=p;auto box=place({0,0,1000,600},200,80,h);check(box.left>=0&&box.right<=1000&&box.top>=0&&box.bottom<=600,"all nine HUD positions bounded");}
    for(auto spinner:spinners){h=hud(parse("{\"message\":\"x\",\"spinner\":"+quote(spinner)+"}"));check(h.spinner==spinner,"all spinner names accepted");check(frame(spinner,0).empty()==(std::string(spinner)=="none"),"spinner frame presence");}
    check(hudText(std::string(256,'x')).size()==256,"HUD scalar ceiling inclusive");refuses([]{hudText(std::string(257,'x'));});
    refuses([]{hudText("\xc2\x85");});
    check(hud(parse("{}"),true).message.empty(),"empty close accepted");refuses([]{hud(parse("{\"detail\":\"\"}"),true);});
    Pick p=pick(parse(R"({"items":[{"id":"z","label":"Zulu","subtitle":"Alpha consequence"},{"id":"a","label":"Alpha"},{"id":"b","label":"Alpine"}]})"));
    Selection s(p);check(s.matches==std::vector<int>({0,1,2}),"blank query preserves order");
    s.set(L"al");check(s.matches==std::vector<int>({1,2}),"labels only filtering");s.move(99);check(s.selected==1,"down clamps");
    check(s.choose().find("\"index\":2")!=std::string::npos,"choice original index");s.move(-99);check(s.selected==0,"up clamps");
    s.set(L"consequence");check(s.matches.empty()&&s.choose().empty(),"subtitle never matches");
    p.custom=true;Selection custom(p);custom.set(L"  New thing  ");check(custom.custom()&&custom.choose().find("\"query\":\"New thing\"")!=std::string::npos,"custom trimmed unmatched result");
    custom.set(L"Alpha");check(!custom.custom(),"matched query suppresses custom");custom.set(L"　");check(!custom.custom(),"Unicode whitespace suppresses custom");
    check(score(terms(L"abc abc"),L"a---b---c")==2*score(terms(L"abc"),L"a---b---c"),"duplicate terms retain ranking weight");
    for(auto bad:{R"({"items":[]})",R"({"items":true})",R"({"items":[{"id":"x","label":"x"},{"id":"x","label":"y"}]})",R"({"items":[{"id":true,"label":"x"}]})",R"({"items":[{"id":"x","label":""}]})",R"({"items":[],"allowCustom":"true"})"})refuses([&]{pick(parse(bad));});
    auto empty=pick(parse(R"({"items":[{"id":"","label":"中文 🦊"}],"prompt":""})"));check(empty.promptSet&&Selection(empty).choose().find("\"id\":\"\"")!=std::string::npos,"empty item id and prompt preserved");
    Pick big;for(int i=0;i<100;++i)big.items.push_back({std::to_string(i),std::string(4096,'a'),""});Selection bounded(big);
    std::wstring query;for(int i=0;i<170;++i)query+=L"term"+std::to_wstring(i)+L" ";refuses([&]{bounded.set(query);});check(bounded.query.empty()&&bounded.matches.size()==100,"complex query refuses without state mutation");
    for(int shape=0;shape<3;++shape)for(bool blink:{false,true})for(int terminal=0;terminal<=6;++terminal){auto c=cursor(shape,blink,terminal);check(c.shape==(terminal?terminal<=2?1:terminal<=4?2:0:shape)&&c.blink==(terminal?(terminal%2)==1:blink),"complete cursor precedence space");}
    check(destination(2,3,false,false,"next")==0&&destination(0,3,false,false,"previous")==2,"workspace wrap");
    check(destination(0,1,false,false,"next")==-1&&destination(0,3,true,false,"next")==-1&&destination(0,3,false,true,"next")==-1,"workspace visible-count guards");
    std::printf("wave3-unit: %d checks, %d failed\n",checks,failures);return failures?1:0;
}
