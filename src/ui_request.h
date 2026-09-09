// UI request publication/withdrawal. The payload is written before publishing Done.
#pragma once
#include <atomic>
namespace ui_request {
class State {
    enum Phase { Pending, Running, Done, Withdrawn };
    std::atomic<int> phase_{Pending};
public:
    bool start(){int expected=Pending;return phase_.compare_exchange_strong(expected,Running);}
    bool withdrawPending(){int expected=Pending;return phase_.compare_exchange_strong(expected,Withdrawn);}
    bool withdraw(){
        int expected=phase_.load();
        while(expected==Pending||expected==Running)
            if(phase_.compare_exchange_weak(expected,Withdrawn))return true;
        return false;
    }
    bool completed()const{return phase_.load()==Done;}
    void finish(){phase_.store(Done);} // ordinary requests report unknown outcome once running
    template<class Rollback> void publishPicker(Rollback rollback){
        int expected=Running;
        if(!phase_.compare_exchange_strong(expected,Done)&&expected==Withdrawn)rollback();
    }
};
}
