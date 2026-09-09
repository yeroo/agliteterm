#pragma once
#include <string>
#include <cstdint>
#include <sstream>
namespace quick_settings {
// Packed virtual key + native MOD_ALT/CONTROL/SHIFT (not HOTKEYF_*).
inline bool valid(uint32_t value) {
    if(!value)return true;unsigned key=value&255,mods=value>>8;
    return mods<=7&&(mods&3)&&((key>='A'&&key<='Z')||(key>='0'&&key<='9')||(key>=112&&key<=122)||key==192);
}
inline bool parse(const std::string& text,uint32_t& result){
    if(text.empty()){result=0;return true;}
    std::istringstream in(text);std::string word;unsigned mods=0,key=0;
    while(std::getline(in,word,'+')){
        unsigned mod=word=="ctrl"?2:word=="alt"?1:word=="shift"?4:0;
        if(mod){if(mods&mod)return false;mods|=mod;continue;}
        if(key||word.empty())return false;
        if(word.size()==1&&((word[0]>='a'&&word[0]<='z')||(word[0]>='0'&&word[0]<='9')))key=word[0]>='a'?word[0]-'a'+'A':word[0];
        else if(word=="backtick")key=192;
        else for(unsigned n=1;n<=11;++n)if(word=="f"+std::to_string(n))key=111+n;
        if(!key)return false;
    }
    unsigned value=key|(mods<<8);if(text.back()=='+'||!key||!valid(value))return false;result=value;return true;
}
inline std::string format(uint32_t value){
    if(!value)return {};unsigned mods=value>>8,key=value&255;std::string s;
    if(mods&2)s+="ctrl+";if(mods&1)s+="alt+";if(mods&4)s+="shift+";
    if(key==192)return s+"backtick";if(key>=112&&key<=122)return s+'f'+std::to_string(key-111);
    return s+char(key>='A'&&key<='Z'?key-'A'+'a':key);
}
}
