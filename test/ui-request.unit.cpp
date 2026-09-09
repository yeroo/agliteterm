#include "../src/ui_request.h"
#include <cstdio>
#include <thread>
#include <atomic>
static int checked=0,failed=0;
static void check(bool ok){++checked;if(!ok)++failed;}
int main(){
    {ui_request::State state;check(state.withdraw());check(!state.start());check(!state.completed());}
    {ui_request::State state;check(state.start());check(!state.withdrawPending());state.finish();check(state.completed());check(!state.withdraw());}
    {ui_request::State state;check(state.start());check(state.withdraw());int rollback=0;state.publishPicker([&]{++rollback;});check(rollback==1);check(!state.completed());}
    {ui_request::State state;check(state.start());int rollback=0;state.publishPicker([&]{++rollback;});check(state.completed());check(!state.withdraw());check(rollback==0);}
    // Exercise both CAS winners. An abandoned construction must roll back exactly once;
    // a published result must remain readable and cannot be withdrawn afterward.
    for(int i=0;i<2000;++i){
        ui_request::State state;check(state.start());std::atomic<bool> go{false};bool withdrawn=false;int rollbacks=0;
        std::thread timeout([&]{while(!go.load())std::this_thread::yield();withdrawn=state.withdraw();});
        go=true;state.publishPicker([&]{++rollbacks;});timeout.join();
        check(withdrawn?(rollbacks==1&&!state.completed()):(rollbacks==0&&state.completed()));
    }
    std::printf("ui-request: %d checks, %d failed\n",checked,failed);return failed?1:0;
}
