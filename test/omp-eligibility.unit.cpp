#include "shell_configuration.h"
#include <string>
#include <memory>
#include <cstdio>
static constexpr int INVALID_HANDLE_VALUE=-1;
struct FfiEmuInfo { bool isAltScreen=false; };
struct Emulator { bool readable=true,alt=false; };
static bool emu_info(Emulator* e,FfiEmuInfo* info){info->isAltScreen=e->alt;return e->readable;}
struct AgentHandle { int pid=3,born=4;bool alive=true;bool live()const{return alive;} };
struct Session {
    bool listed=true,exited=false,readOnly=false,adopted=false,cover=false;
    int data=1,childPid=3,childCreated=4;std::string agentBridgeToken="bridge";
    Emulator emulator;Emulator* emu=&emulator;shell_configuration::InputGate inputGate;
};
struct OmpOperation {
    std::shared_ptr<AgentHandle> shell=std::make_shared<AgentHandle>();
    std::string bridge="bridge";unsigned long long policyGeneration=0;
};
static int indexOfSession(Session* s){return s->listed?0:-1;}
static bool isCoverLocked(Session* s){return s->cover;}
// ACTUAL_ELIGIBILITY
int main(){
    int checks=0,failed=0;auto check=[&](bool b){++checks;if(!b)++failed;};
    Session s;OmpOperation op;check(ompPaneEligible(&s,op));
    for(bool* flag:{&s.exited,&s.readOnly,&s.adopted,&s.cover,&s.emulator.alt}){
        *flag=true;check(!ompPaneEligible(&s,op));*flag=false;check(ompPaneEligible(&s,op));
    }
    s.listed=false;check(!ompPaneEligible(&s,op));s.listed=true;
    s.emulator.readable=false;check(!ompPaneEligible(&s,op));s.emulator.readable=true;
    s.emu=nullptr;check(!ompPaneEligible(&s,op));s.emu=&s.emulator;
    s.data=INVALID_HANDLE_VALUE;check(!ompPaneEligible(&s,op));s.data=1;
    s.childPid++;check(!ompPaneEligible(&s,op));s.childPid--;
    s.childCreated++;check(!ompPaneEligible(&s,op));s.childCreated--;
    s.agentBridgeToken="replacement";check(!ompPaneEligible(&s,op));s.agentBridgeToken=op.bridge;
    op.shell->alive=false;check(!ompPaneEligible(&s,op));op.shell->alive=true;
    s.inputGate.setReadOnly(false);check(ompPaneEligible(&s,op));
    s.inputGate.setReadOnly(true);check(!ompPaneEligible(&s,op));
    s.inputGate.setReadOnly(false);check(!ompPaneEligible(&s,op));
    op.policyGeneration=s.inputGate.policyGeneration();check(ompPaneEligible(&s,op));
    s.inputGate.setReadOnly(false);check(ompPaneEligible(&s,op));
    std::printf("OMP eligibility: %d actual pane-policy checks, %d failed\n",checks,failed);return failed?1:0;
}
