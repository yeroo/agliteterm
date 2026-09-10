#include <string>
#include <mutex>
#include <thread>
#include <vector>
#include <cstdio>
static std::mutex gate;
static thread_local int held=0;
struct LockG { LockG(){gate.lock();++held;} ~LockG(){--held;gate.unlock();} };
struct Session { std::string id="pane",status; bool listed=true,cover=false; };
struct JsonReq { std::string status; std::string get(const char*) const{return status;} };
static int indexOfSession(Session* s){return s->listed?0:-1;}
static bool isCoverLocked(Session* s){return s->cover;}
static std::string ctlErr(const std::string& s){return "error:"+s;}
static std::string ctlOkStr(const std::string& s){return s;}
static std::string sessionIdentityCover(const char*,const std::string&,const char*){return "cover";}
static void setStatus(Session* s,const std::string& v){s->status=v;}
static Session pane;
static int checks=0,failed=0,events=0;
static void emitEvent(const char*,const std::string& id,const std::string& value){
    ++checks;if(!held||id!=pane.id||value!=pane.status)++failed;++events;
}
static void* g_hwnd=nullptr;
static constexpr int FALSE=0,WM_APP_REFRESHTREE=0;
static void InvalidateRect(void*,void*,int){}
static void PostMessageW(void*,int,int,int){}
static std::string status(const JsonReq& req,Session* target=&pane){
    std::string targetWhy,cmd="session.status";
    // ACTUAL_STATUS_BRANCH
    return "unhandled";
}
int main(){
    std::vector<std::thread> writers;
    for(int i=0;i<4;++i)writers.emplace_back([i]{for(int j=0;j<1000;++j)status({std::to_string(i)+"-"+std::to_string(j)});});
    for(auto& writer:writers)writer.join();
    auto check=[](bool ok){++checks;if(!ok)++failed;};
    check(events==4000);check(status({""}).find("error:")==0);
    check(status({"x"},nullptr).find("error:")==0);
    pane.listed=false;check(status({"x"}).find("error:")==0);pane.listed=true;
    pane.cover=true;check(status({"x"}).find("error:")==0);check(events==4000);
    std::printf("Status ownership: %d actual concurrent publication checks, %d failed\n",checks,failed);
    return failed?1:0;
}
