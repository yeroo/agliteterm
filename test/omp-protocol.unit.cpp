#include "../src/omp_protocol.h"
#include <cstdio>
#include <initializer_list>
int main() {
    int checks=0; auto check=[&](bool ok) { ++checks; if(!ok){std::printf("FAIL check %d\n",checks);return false;}return true; };
    using namespace omp_protocol;
    for(bool eligible : {false,true}) for(bool success : {false,true}) for(bool late : {false,true}) {
        State s(100);
        if(!check(!s.claim(1,false)) || !check(s.phase==Phase::Queued))return 1;
        if(!check(s.claim(2,true)) || !check(!s.claim(3,true)))return 1;
        if(late)s.expire(100);
        if(!check(s.result(late?101:99,success,eligible)))return 1;
        if(!check(s.persistAllowed==(success&&eligible&&!late)))return 1;
        if(!check(s.phase==(success?Phase::Applied:Phase::Failed)) || !check(!s.active()))return 1;
        if(!check(!s.result(102,true,true)) || !check(!s.claim(102,true)))return 1;
    }
    State queued(100);if(!check(!queued.result(1,true,true)) || !check(!queued.claim(100,true)) || !check(queued.phase==Phase::Expired))return 1;
    State claimed(100);claimed.claim(1,true);claimed.expire(100);
    if(!check(claimed.phase==Phase::Unknown) || !check(claimed.active()) || !check(!claimed.claim(101,true)))return 1;
    std::printf("OMP protocol: %d checks passed; no host or shell\n",checks);return 0;
}
