#include "../src/remainder.h"
#include <iostream>
#include <set>
int main() {
    int checks = 0, failed = 0;
    auto check = [&](bool ok) { ++checks; if (!ok) ++failed; };
    for (bool start : {false,true}) {
        for (const auto& op : {"", "toggle", "on", "off", "state", "get", "bad", "ON"}) {
            bool next = start;
            const bool valid = lite_remainder::toggle(op,start,next);
            const std::string s = op;
            check(valid == (s != "bad" && s != "ON"));
            check(next == (s == "on" ? true : s == "off" ? false : s.empty() || s == "toggle" ? !start : start));
        }
    }
    for (int n = 1; n <= 9; ++n) for (int from = 0; from < n; ++from) {
        for (const auto& op : {"up","down","top","bottom","bad"}) {
            int to = lite_remainder::destination(from,n,op);
            if (std::string(op)=="bad") { check(to==-1); continue; }
            check(to>=0 && to<n); std::set<int> mapped;
            for (int i=0;i<n;++i) { const int out=lite_remainder::remap(i,from,to); mapped.insert(out);
                check(out>=0 && out<n); check(lite_remainder::remap(out,to,from)==i); }
            check(mapped.size()==static_cast<size_t>(n)); check(lite_remainder::remap(-1,from,to)==-1);
        }
        for(int key : {35,36,37,38,39,40,65}) {
            int next=lite_remainder::navigate(from,n,key); check(next>=0 && next<n);
            if(key==35) check(next==n-1); if(key==36) check(next==0); if(key==65) check(next==from);
        }
    }
    check(lite_remainder::destination(-1,2,"up")==-1);
    check(lite_remainder::navigate(0,0,40)==0);
    check(lite_remainder::navigate(2,3,39)==2);
    check(lite_remainder::navigate(1,3,40)==1);
    std::cout << "remainder: " << checks << " checks, " << failed << " failed\n";
    return failed ? 1 : 0;
}
