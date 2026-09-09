// Wave 3 value models. NLS calls only: no windows, processes, registry or clipboard.
#pragma once
#include <windows.h>
#include <algorithm>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <stdexcept>
#include "profiles.h"

namespace wave3 {
using Value = profiles::detail::Value;
inline const Value* field(const Value& v, const std::string& name) {
    if (v.kind != Value::Object) throw std::invalid_argument("expected an object");
    auto at = v.object.find(name); return at == v.object.end() ? nullptr : &at->second;
}
inline std::wstring wide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0);
    if (!n) throw std::invalid_argument("invalid UTF-8");
    std::wstring out(n, 0);
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), &out[0], n)) throw std::invalid_argument("UTF-8 conversion failed");
    return out;
}
inline std::string utf8(const std::wstring& s) {
    if (s.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    if (!n) throw std::invalid_argument("invalid UTF-16");
    std::string out(n, 0);
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), (int)s.size(), &out[0], n, nullptr, nullptr)) throw std::invalid_argument("UTF-16 conversion failed");
    return out;
}
inline std::string quote(const std::string& s) {
    std::string out="\""; const char* hex="0123456789abcdef";
    for(unsigned char c:s) {
        if(c=='"'||c=='\\'){out+='\\';out+=char(c);}
        else if(c<32){out+="\\u00";out+=hex[c>>4];out+=hex[c&15];}
        else out+=char(c);
    }
    return out+'"';
}
inline std::string nullable(const std::string& s) { return s.empty()?"null":quote(s); }
inline bool space(wchar_t c) {
    return (c>=9&&c<=13)||c==32||c==0x85||c==0xa0||c==0x1680||(c>=0x2000&&c<=0x200a)||c==0x2028||c==0x2029||c==0x202f||c==0x205f||c==0x3000;
}
inline std::wstring trim(std::wstring s) {
    size_t a=0,b=s.size();while(a<b&&space(s[a]))++a;while(b>a&&space(s[b-1]))--b;return s.substr(a,b-a);
}
inline std::wstring lower(const std::wstring& s) {
    if(s.empty())return {};
    int n=LCMapStringEx(LOCALE_NAME_INVARIANT,LCMAP_LOWERCASE,s.data(),(int)s.size(),nullptr,0,nullptr,nullptr,0);
    if(!n)throw std::invalid_argument("case mapping failed");
    std::wstring out(n,0);
    if(!LCMapStringEx(LOCALE_NAME_INVARIANT,LCMAP_LOWERCASE,s.data(),(int)s.size(),&out[0],n,nullptr,nullptr,0))throw std::invalid_argument("case mapping failed");
    return out;
}
inline std::string text(const Value& v,const std::string& name,bool required=false,size_t limit=4096) {
    const auto* f=field(v,name);
    if(!f||f->kind==Value::Null){if(required)throw std::invalid_argument("missing "+name);return {};}
    if(f->kind!=Value::String||wide(f->text).size()>limit)throw std::invalid_argument("invalid or oversized "+name);
    return f->text;
}
inline bool boolean(const Value& v,const std::string& name) {
    const auto* f=field(v,name);if(!f||f->kind==Value::Null)return false;
    if(f->kind!=Value::Boolean)throw std::invalid_argument(name+" must be boolean");return f->boolean;
}
inline int integer(const Value& v,int low,int high) {
    if(v.kind!=Value::Number||v.text.empty())throw std::invalid_argument("expected a whole number");
    int n=0;for(char c:v.text){if(c<'0'||c>'9'||n>(high-(c-'0'))/10)throw std::invalid_argument("number outside range");n=n*10+c-'0';}
    if(n<low||n>high)throw std::invalid_argument("number outside range");return n;
}
inline Value parse(const std::string& raw) {
    Value v;if(!profiles::detail::Parser(raw,true).parse(v)||v.kind!=Value::Object)throw std::invalid_argument("invalid bounded JSON object");return v;
}
inline std::string color(const std::string& raw) {
    auto s=raw;if(!s.empty()&&s[0]=='#')s.erase(0,1);
    if(s.size()!=6)throw std::invalid_argument("color must have six hex digits");
    for(auto& c:s){if(c>='A'&&c<='F')c+='a'-'A';if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))throw std::invalid_argument("invalid color");}
    return '#'+s;
}
inline COLORREF rgb(const std::string& s,COLORREF fallback) {
    if(s.empty())return fallback;unsigned n=0;for(size_t i=1;i<s.size();++i)n=n*16+(s[i]<='9'?s[i]-'0':s[i]-'a'+10);
    return RGB((n>>16)&255,(n>>8)&255,n&255);
}
inline std::string hudText(const std::string& raw) {
    auto s=wide(raw);if(s.empty())return {};
    for(auto c:s)if(c<32||(c>=127&&c<=159))throw std::invalid_argument("HUD text contains controls");
    int n=NormalizeString(NormalizationC,s.data(),(int)s.size(),nullptr,0);
    std::wstring out;
    for(int attempt=0;attempt<4;++attempt){
        if(n<=0||n>1024*1024)throw std::invalid_argument("normalization failed");
        out.assign(n,0);int got=NormalizeString(NormalizationC,s.data(),(int)s.size(),&out[0],n);
        if(got>0){out.resize(got);size_t scalars=0;for(auto c:out)if(c<0xdc00||c>0xdfff)++scalars;
            if(scalars>256)throw std::invalid_argument("HUD text exceeds 256 Unicode scalars");return utf8(out);}
        if(GetLastError()!=ERROR_INSUFFICIENT_BUFFER)throw std::invalid_argument("normalization failed");n=-got;
    }
    throw std::invalid_argument("normalization did not converge");
}
static const char* const positions[]={"top-left","top-center","top-right","center-left","center","center-right","bottom-left","bottom-center","bottom-right"};
static const char* const spinners[]={"none","bar","braille","circle","blocks","dot"};
struct Hud {
    std::string message,detail,spinner="none",background,foreground,position="center";int width=0;
    std::string json()const{return "{\"message\":"+quote(message)+",\"detail\":"+nullable(detail)+",\"spinner\":"+quote(spinner)+
        ",\"backgroundColor\":"+nullable(background)+",\"textColor\":"+nullable(foreground)+",\"sizePercent\":"+(width?std::to_string(width):"null")+",\"position\":"+quote(position)+"}";}
};
inline Hud hud(const Value& args,bool close=false) {
    if(args.kind!=Value::Object)throw std::invalid_argument("HUD args must be an object");
    Hud h;
    for(const auto& kv:args.object){
        if(close)throw std::invalid_argument("HUD close takes no display arguments");
        const auto& k=kv.first;const auto& v=kv.second;
        if(k=="size-percent"){h.width=(std::max)(10,(std::min)(80,integer(v,1,100)));continue;}
        if(v.kind!=Value::String)throw std::invalid_argument("HUD argument must be text");
        if(k=="message")h.message=hudText(v.text);else if(k=="detail")h.detail=hudText(v.text);
        else if(k=="spinner")h.spinner=v.text;else if(k=="position")h.position=v.text;
        else if(k=="color")h.background=color(v.text);else if(k=="text-color")h.foreground=color(v.text);
        else throw std::invalid_argument("unknown HUD argument "+k);
    }
    if(close)return h;
    if(trim(wide(h.message)).empty())throw std::invalid_argument("HUD message must be nonblank");
    if(h.position=="top")h.position="top-center";if(h.position=="bottom")h.position="bottom-center";
    if(std::find(std::begin(positions),std::end(positions),h.position)==std::end(positions))throw std::invalid_argument("unknown HUD position");
    if(std::find(std::begin(spinners),std::end(spinners),h.spinner)==std::end(spinners))throw std::invalid_argument("unknown HUD spinner");
    return h;
}
inline RECT place(RECT area,int neededWidth,int neededHeight,const Hud& h) {
    int w=(std::max)(0,(int)(area.right-area.left)),ht=(std::max)(0,(int)(area.bottom-area.top));
    int width=h.width?w*h.width/100:(std::max)(w/10,(std::min)(w*8/10,neededWidth));
    int height=(std::max)(0,(std::min)(ht*8/10,neededHeight)),p=4;
    for(int i=0;i<9;++i)if(h.position==positions[i])p=i;
    auto offset=[](int extent,int size,int band){return band==0?extent/10:band==2?extent*9/10-size:(extent-size)/2;};
    LONG x=area.left+offset(w,width,p%3),y=area.top+offset(ht,height,p/3);return {x,y,x+width,y+height};
}
inline std::wstring frame(const std::string& kind,ULONGLONG ms) {
    std::wstring frames;unsigned interval=100;
    if(kind=="bar")frames=L"|/-\\";else if(kind=="braille"){frames=L"⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";interval=80;}
    else if(kind=="circle"){frames=L"◐◓◑◒";interval=120;}else if(kind=="blocks"){frames=L"▁▃▄▅▆▇▆▅▄▃";interval=80;}
    else if(kind=="dot"){frames=L"● ";interval=450;}
    return frames.empty()?L"":std::wstring(1,frames[(ms/interval)%frames.size()]);
}
struct Item{std::string id,label,subtitle;};
struct Pick{std::vector<Item> items;std::string prompt,query;bool promptSet=false,custom=false,follow=false;};
inline bool display(const std::wstring& s){if(s.size()>4096)return false;for(auto c:s)if(c<32||c==127)return false;return true;}
inline std::map<std::wstring,int> terms(const std::wstring& query){
    auto q=lower(query);std::map<std::wstring,int> out;size_t i=0;
    while(i<q.size()){while(i<q.size()&&space(q[i]))++i;auto begin=i;while(i<q.size()&&!space(q[i]))++i;if(i>begin)++out[q.substr(begin,i-begin)];}return out;
}
inline void work(const Pick& p,const std::map<std::wstring,int>& t){
    uint64_t units=0;for(const auto& i:p.items)units+=wide(i.label).size();
    if(units*t.size()>64ull*1024*1024)throw std::invalid_argument("picker query exceeds matching work limit");
}
inline Pick pick(const Value& args){
    Pick p;const auto* items=field(args,"items");if(!items||items->kind!=Value::Array||items->array.size()>1000)throw std::invalid_argument("picker needs at most 1000 items");
    p.custom=boolean(args,"allowCustom");p.follow=boolean(args,"follow");
    p.prompt=text(args,"prompt");p.query=text(args,"query");const auto* prompt=field(args,"prompt");p.promptSet=prompt&&prompt->kind==Value::String;
    if(!display(wide(p.prompt))||!display(wide(p.query)))throw std::invalid_argument("picker display controls refused");
    std::set<std::string> ids;
    for(const auto& v:items->array){Item i{text(v,"id",true),text(v,"label",true),text(v,"subtitle")};
        if(!ids.insert(i.id).second||i.label.empty()||!display(wide(i.label))||!display(wide(i.subtitle)))throw std::invalid_argument("invalid or duplicate picker item");p.items.push_back(std::move(i));}
    if(p.items.empty()&&!p.custom)throw std::invalid_argument("picker needs items or allowCustom");
    work(p,terms(wide(p.query)));return p;
}
inline int score(const std::map<std::wstring,int>& query,const std::wstring& raw){
    const auto label=lower(raw);int total=0;
    for(const auto& t:query){if(label.compare(0,t.first.size(),t.first)==0)continue;auto at=label.find(t.first);
        if(at!=std::wstring::npos){total+=(5+(int)(std::min)(at,size_t(34)))*t.second;continue;}
        size_t cursor=0;for(auto c:label)if(c==t.first[cursor]&&++cursor==t.first.size())break;
        if(cursor!=t.first.size())return -1;total+=(40+(int)label.size()-(int)t.first.size())*t.second;}
    return total;
}
struct Selection {
    Pick spec;std::wstring query;std::vector<int> matches;int selected=0;
    explicit Selection(Pick p):spec(std::move(p)){set(wide(spec.query));}
    bool custom()const{return spec.custom&&matches.empty()&&!trim(query).empty();}
    int count()const{return custom()?1:(int)matches.size();}
    void set(const std::wstring& q){
        if(!display(q))throw std::invalid_argument("invalid picker query");auto ts=terms(q);work(spec,ts);
        std::vector<std::pair<int,int>> ranked;
        for(int i=0;i<(int)spec.items.size();++i){int s=ts.empty()?0:score(ts,wide(spec.items[i].label));if(s>=0)ranked.push_back({i,s});}
        if(!ts.empty())std::stable_sort(ranked.begin(),ranked.end(),[&](const auto& a,const auto& b){
            if(a.second!=b.second)return a.second<b.second;
            auto x=wide(spec.items[a.first].label),y=wide(spec.items[b.first].label);
            int cmp=CompareStringOrdinal(x.data(),(int)x.size(),y.data(),(int)y.size(),TRUE);return cmp==CSTR_LESS_THAN;});
        std::vector<int> next;for(auto r:ranked)next.push_back(r.first);query=q;matches=std::move(next);selected=0;
    }
    void select(int n){selected=(std::max)(0,(std::min)((std::max)(0,count()-1),n));}
    void move(int delta){select(selected+delta);}
    std::string choose()const{
        if(custom())return "{\"result\":\"custom\",\"query\":"+quote(utf8(trim(query)))+"}";
        if(matches.empty())return {};int index=matches[selected];const auto& i=spec.items[index];
        return "{\"result\":\"picked\",\"id\":"+quote(i.id)+",\"label\":"+quote(i.label)+",\"index\":"+std::to_string(index)+"}";
    }
};
struct Cursor{int shape;bool blink;}; // 0 bar, 1 block, 2 underline
inline Cursor cursor(int configured,bool blink,int terminal){
    if(terminal>=1&&terminal<=6)return {terminal<=2?1:terminal<=4?2:0,(terminal%2)==1};return {configured,blink};
}
inline int destination(int current,int count,bool flagged,bool focused,const std::string& dir){
    if(flagged||focused||count<2||current<0||current>=count)return -1;
    if(dir=="next")return (current+1)%count;if(dir=="prev"||dir=="previous")return (current+count-1)%count;return -1;
}
}
