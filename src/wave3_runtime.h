// Included after main's session/control helpers. All mutations below execute on the UI thread.
static bool waveCommand(const std::string& cmd){
    return cmd.rfind("session.hud.",0)==0||cmd.rfind("pick.",0)==0||cmd=="workspace.go"||cmd=="workspace.collapse"||cmd=="workspace.expand"||cmd=="quick";
}
static void waveWindow(const wave3::Value& root){
    auto* selector=wave3::field(root,"window");if(!selector||selector->kind==wave3::Value::Null)return;
    if(selector->kind!=wave3::Value::String||selector->text.empty())throw std::invalid_argument("invalid window selector");
    if(selector->text=="active")return; // a lite pipe is one library window
    const auto own=narrow(g_instance);if(selector->text==own)return;
    int matches=0;bool ours=false;
    for(const auto& instance:listInstances()){auto id=narrow(instance.name);if(id.compare(0,selector->text.size(),selector->text)==0){++matches;ours=id==own;}}
    if(matches!=1||!ours)throw std::invalid_argument("window not in this instance or ambiguous; address its pipe explicitly");
}
static bool waveBusy(){
    GUITHREADINFO gui{sizeof gui};
    return g_settingsOpenQueued||!IsWindowEnabled(g_hwnd)||g_treeRenaming||(g_tree&&TreeView_GetEditControl(g_tree))||
        g_dashboard||g_treeDrag||g_splitDrag||GetCapture()!=nullptr||!GetGUIThreadInfo(GetCurrentThreadId(),&gui)||
        (gui.flags&(GUI_INMENUMODE|GUI_POPUPMENUMODE|GUI_SYSTEMMENUMODE));
}
static Session* hudTarget(const wave3::Value& root){ // caller holds g_lock
    auto* selector=wave3::field(root,"target");
    if(selector&&selector->kind!=wave3::Value::Null&&selector->kind!=wave3::Value::String)throw std::invalid_argument("invalid HUD target");
    auto target=selector&&selector->kind==wave3::Value::String?selector->text:"active";
    if(target.empty())throw std::invalid_argument("empty HUD target");
    if(target=="active"){
        auto* focused=focusedSession();
        if(focused&&(focused==g_quickSession||focused==g_scratchSession||focused==g_overlaySession))throw std::invalid_argument("HUD requires its owning session");
        auto* owner=displayedOwner();if(!owner)throw std::invalid_argument("no HUD session");return owner;
    }
    for(auto* s:g_sessions)if(!s->hidden&&s->id==target)return s;
    for(auto* s:g_sessions)if((s->hidden&&s->id==target)||(s->paneId==target&&s->paneId!=s->id))throw std::invalid_argument("HUD target is an auxiliary pane");
    Session* found=nullptr;int count=0;
    for(auto* s:g_sessions){
        bool prefix=s->id.compare(0,target.size(),target)==0||s->paneId.compare(0,target.size(),target)==0;
        if(prefix){if(s->hidden||s->id.compare(0,target.size(),target)!=0)throw std::invalid_argument("HUD prefix includes an auxiliary pane");found=s;++count;}
    }
    if(count==1)return found;if(count>1)throw std::invalid_argument("ambiguous HUD target");
    for(auto* s:g_sessions)if(!s->hidden&&CompareStringOrdinal(s->name.data(),(int)s->name.size(),wave3::wide(target).data(),(int)wave3::wide(target).size(),TRUE)==CSTR_EQUAL){found=s;++count;}
    if(count!=1)throw std::invalid_argument("HUD session not found or ambiguous");return found;
}
static void abortPicker(const std::string& id){
    if(g_pendingPick==id){g_pickPublished=false;g_pendingPick.clear();}
    if(g_picker&&g_picker->id==id)g_picker->dispose();
    g_pickAnswers.erase(std::remove_if(g_pickAnswers.begin(),g_pickAnswers.end(),[&](const auto& a){return a.first==id;}),g_pickAnswers.end());
}
static std::string navigateWorkspace(const std::string& direction){
    if(waveBusy()||(g_picker&&g_picker->active()))return ctlErr("workspace navigation: finish the active UI operation first");
    int to=-1,first=-1;
    {LockG hold;to=wave3::destination(g_activeWs,(int)g_workspaces.size(),g_flagView,g_focusWs>=0,direction);
        if(to<0)return ctlErr("workspace go needs next/prev and at least two visible workspaces");
        g_activeWs=to;for(int i=0;i<(int)g_sessions.size();++i)if(!g_sessions[i]->hidden&&g_sessions[i]->ws==to){first=i;break;}}
    if(first>=0)selectPrimary(first);else refreshTree(false);
    InvalidateRect(g_hwnd,nullptr,FALSE);return ctlOkStr(std::to_string(to));
}
static void collapseCurrentWorkspace(){
    {LockG hold;if(g_collapsedWorkspaces.count(g_activeWs))g_collapsedWorkspaces.erase(g_activeWs);else g_collapsedWorkspaces.insert(g_activeWs);}
    refreshTree(false);
}
static std::string waveOnUi(const JsonReq& request){
    try{
        auto root=wave3::parse(request.get("wave3.raw"));
        if(!(wave3::text(root,"cmd",true)=="quick"&&wave3::text(root,"window")=="quick"))waveWindow(root);
        const auto cmd=wave3::text(root,"cmd",true);const auto* input=wave3::field(root,"args");
        wave3::Value empty;empty.kind=wave3::Value::Object;const auto& args=input?*input:empty;
        if(args.kind!=wave3::Value::Object)throw std::invalid_argument("args must be an object");
        if(cmd.rfind("session.hud.",0)==0){
            auto action=cmd.substr(12);if(action!="open"&&action!="update"&&action!="close")throw std::invalid_argument("unknown HUD action");
            auto spec=wave3::hud(args,action=="close");LockG hold;auto* session=hudTarget(root);
            if(action=="close")session->hud.reset();else{
                if(g_overlayHwnd&&g_overlayOwnerId==session->id)throw std::invalid_argument("a session-wide program overlay owns the HUD slot");
                if(action=="update"){if(!session->hud)throw std::invalid_argument("no HUD to update");spec.background=session->hud->background;}
                session->hud=std::make_shared<const wave3::Hud>(std::move(spec));}
            InvalidateRect(g_hwnd,nullptr,FALSE);return ctlOk("{\"session\":"+wave3::quote(session->id)+",\"hud\":"+(session->hud?session->hud->json():"null")+"}");
        }
        if(cmd=="workspace.go"){
            const auto* target=wave3::field(root,"target");if(target&&target->kind!=wave3::Value::Null)throw std::invalid_argument("workspace go takes no target");
            return navigateWorkspace(wave3::text(args,"to",true));
        }
        if(cmd=="workspace.collapse"||cmd=="workspace.expand"){
            const auto target=wave3::text(root,"target");
            {LockG hold;int w=remainderWorkspace(target);if(w<0)throw std::invalid_argument("workspace not found");if(cmd=="workspace.collapse")g_collapsedWorkspaces.insert(w);else g_collapsedWorkspaces.erase(w);}
            refreshTree(false);return ctlOkStr("ok");
        }
        if(cmd=="quick"){
            if(waveBusy()||(g_picker&&g_picker->active()))throw std::invalid_argument("quick: finish the active UI operation first");
            auto op=wave3::text(args,"op");if(op.empty())op="toggle";
            if(op!="on"&&op!="off"&&op!="toggle")throw std::invalid_argument("quick expects on/off/toggle");
            quickVisibility(op,false);return ctlOkStr(g_quickHwnd&&IsWindowVisible(g_quickHwnd)?"shown":"hidden");
        }
        if(cmd=="pick.open"){
            const auto* target=wave3::field(root,"target");if(target&&target->kind!=wave3::Value::Null)throw std::invalid_argument("pick.open takes no session target");
            auto spec=wave3::pick(args);
            if(!g_pendingPick.empty())throw std::invalid_argument("pick already pending");
            if(waveBusy())throw std::invalid_argument("another UI operation owns the window");
            if(g_palette)togglePalette();g_leaderPending=false;
            GUID guid{};if(FAILED(CoCreateGuid(&guid)))throw std::runtime_error("picker id creation failed");wchar_t id[40]{};StringFromGUID2(guid,id,40);
            const auto created=wave3::utf8(id);g_pendingPick=created;g_pickPublished=false;
            try{
                g_picker.reset(new NativePicker(g_hwnd,std::move(spec),[created](const std::string& answer){
                    if(g_pendingPick!=created)return;g_pendingPick.clear();
                    if(g_pickPublished){g_pickAnswers.push_back({created,answer});while(g_pickAnswers.size()>8)g_pickAnswers.pop_front();}
                },[](const std::string& error){logWarn("picker: %s",error.c_str());}));
                g_picker->id=created;g_picker->show();g_pickPublished=true;return ctlOk("{\"id\":"+wave3::quote(created)+"}");
            }catch(...){abortPicker(created);throw;}
        }
        if(cmd=="pick.result"||cmd=="pick.cancel"){
            auto id=wave3::text(root,"target",true);if(id.empty())throw std::invalid_argument("exact picker id required");
            if(id==g_pendingPick){if(cmd=="pick.cancel"){g_picker->finish("{\"result\":\"cancelled\"}");return ctlOkStr("cancelled");}return ctlOk("{\"pick\":{\"result\":\"pending\"}}");}
            for(const auto& a:g_pickAnswers)if(a.first==id)return cmd=="pick.cancel"?ctlOkStr("cancelled"):ctlOk("{\"pick\":"+a.second+"}");
            throw std::invalid_argument("unknown picker id in this process");
        }
        throw std::invalid_argument("unknown Wave 3 operation");
    }catch(const std::exception& ex){return ctlErr(ex.what());}
}
static void paintHud(HDC dc,RECT area){
    std::shared_ptr<const wave3::Hud> spec;
    {LockG hold;auto* owner=displayedOwner();if(owner)spec=owner->hud;}
    if(!spec||g_dashboard||(g_scratchHwnd&&IsWindowVisible(g_scratchHwnd))||(g_quickHwnd&&IsWindowVisible(g_quickHwnd)))return;
    area.left=sidebarSpan();area.top=toolbarTop();area.bottom-=g_showStatus?g_statusH:0;
    if(area.right<=area.left||area.bottom<=area.top)return;
    auto text=wave3::frame(spec->spinner,GetTickCount64());if(!text.empty())text+=L" ";text+=wave3::wide(spec->message);
    if(!spec->detail.empty())text+=L"\n"+wave3::wide(spec->detail);
    HFONT font=g_uiFont?g_uiFont:(HFONT)GetStockObject(DEFAULT_GUI_FONT);auto old=SelectObject(dc,font);int padding=12;
    RECT measure{0,0,(LONG)((area.right-area.left)*(spec->width?spec->width:80)/100)-2*padding,0};measure.right=(std::max)(1L,measure.right);
    DrawTextW(dc,text.c_str(),(int)text.size(),&measure,DT_CALCRECT|DT_WORDBREAK|DT_NOPREFIX);
    RECT box=wave3::place(area,measure.right+2*padding,measure.bottom+2*padding,*spec);
    HBRUSH bg=CreateSolidBrush(wave3::rgb(spec->background,g_customColors?toColorRef(g_defBg,false):g_th.client));FillRect(dc,&box,bg);DeleteObject(bg);
    HBRUSH border=CreateSolidBrush(g_th.border);FrameRect(dc,&box,border);DeleteObject(border);
    int saved=SaveDC(dc);IntersectClipRect(dc,box.left,box.top,box.right,box.bottom);InflateRect(&box,-padding,-padding);
    SetBkMode(dc,TRANSPARENT);SetTextColor(dc,wave3::rgb(spec->foreground,g_customColors?toColorRef(g_defFg,false):g_th.text));
    DrawTextW(dc,text.c_str(),(int)text.size(),&box,DT_WORDBREAK|DT_NOPREFIX);RestoreDC(dc,saved);SelectObject(dc,old);
}

static void repositionQuick(){
    if(!g_quickHwnd)return;POINT pointer{};GetCursorPos(&pointer);MONITORINFO mi{sizeof mi};
    if(!GetMonitorInfoW(MonitorFromPoint(pointer,MONITOR_DEFAULTTONEAREST),&mi))throw std::runtime_error("quick monitor unavailable");
    int width=(mi.rcWork.right-mi.rcWork.left)*(int)g_quickSize/100,height=(mi.rcWork.bottom-mi.rcWork.top)*(int)g_quickSize/100;
    int x=mi.rcWork.left+((mi.rcWork.right-mi.rcWork.left)-width)/2,y=mi.rcWork.top+((mi.rcWork.bottom-mi.rcWork.top)-height)/2;
    if(!SetWindowPos(g_quickHwnd,nullptr,x,y,width,height,SWP_NOZORDER|SWP_NOACTIVATE))throw std::runtime_error("quick geometry failed");
}
static void quickVisibility(const std::string& op,bool human){
    if(human&&waveBusy())return;
    if(g_picker&&g_picker->active()){if(human)return;throw std::invalid_argument("picker owns input");}
    const bool visible=g_quickHwnd&&IsWindowVisible(g_quickHwnd);
    const bool show=op=="on"||(op=="toggle"&&!visible);
    if(!show){
        g_quickPinned=false;if(g_quickHwnd)ShowWindow(g_quickHwnd,SW_HIDE);
        {LockG hold;if(g_focusOverride==g_quickSession)g_focusOverride=nullptr;}
        return;
    }
    if(!g_quickHwnd){
        ensurePopupClass();
        g_quickHwnd=CreateWindowExW(0,L"AgwintermLitePopup",L"agliteterm — quick",kPopupStyle,0,0,640,400,g_hwnd,nullptr,GetModuleHandleW(nullptr),nullptr);
        if(!g_quickHwnd)throw std::runtime_error("quick window creation failed");
        try{
            repositionQuick();RECT r{};GetClientRect(g_quickHwnd,&r);
            wchar_t* home=nullptr;if(FAILED(SHGetKnownFolderPath(FOLDERID_Profile,0,nullptr,&home)))throw std::runtime_error("home directory unavailable");
            const auto cwd=wave3::utf8(home);CoTaskMemFree(home);
            auto* session=newSession((std::max)(1,(int)r.right/g_cw),(std::max)(1,(int)r.bottom/g_ch),nullptr,nullptr,cwd.c_str(),true);
            if(!session)throw std::runtime_error("quick shell could not start");
            {LockG hold;g_quickSession=session;session->name=L"quick";}
        }catch(...){DestroyWindow(g_quickHwnd);g_quickHwnd=nullptr;throw;}
    }else repositionQuick();
    g_quickPinned=!human;darkTitleBar(g_quickHwnd,g_th.dark);ShowWindow(g_quickHwnd,SW_SHOWNOACTIVATE);
    if(human)SetForegroundWindow(g_quickHwnd);
    InvalidateRect(g_quickHwnd,nullptr,FALSE);
}

// A conservative observation, not a prompt-ready signal. Never query processes under g_lock.
struct WaveShellHint {DWORD pid=0;ULONGLONG born=0;std::string name;};
static std::map<std::string,WaveShellHint> waveShellHints(){
    std::map<std::string,WaveShellHint> hints;
    {LockG hold;for(auto* s:g_sessions)if(!s->exited&&s->childPid&&s->childCreated)hints[s->paneId]={s->childPid,s->childCreated,{}};}
    HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
    if(snapshot==INVALID_HANDLE_VALUE)return hints;
    std::set<DWORD> parents;PROCESSENTRY32W entry{sizeof entry};bool complete=false;
    if(Process32FirstW(snapshot,&entry)){do{parents.insert(entry.th32ParentProcessID);}while(Process32NextW(snapshot,&entry));complete=GetLastError()==ERROR_NO_MORE_FILES;}
    CloseHandle(snapshot);if(!complete)return hints;
    for(auto& item:hints){auto& hint=item.second;if(parents.count(hint.pid))continue;
        HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,hint.pid);if(!process)continue;
        FILETIME born{},exit{},kernel{},user{};wchar_t path[32768];DWORD length=32768;
        if(GetProcessTimes(process,&born,&exit,&kernel,&user)&&(((ULONGLONG)born.dwHighDateTime<<32)|born.dwLowDateTime)==hint.born&&
           QueryFullProcessImageNameW(process,0,path,&length)&&WaitForSingleObject(process,0)==WAIT_TIMEOUT){
            std::wstring name(path,length);auto slash=name.find_last_of(L"\\/");if(slash!=std::wstring::npos)name.erase(0,slash+1);
            if(name.size()>4&&_wcsicmp(name.c_str()+name.size()-4,L".exe")==0)name.resize(name.size()-4);
            for(auto* known:{L"cmd",L"powershell",L"pwsh",L"bash",L"sh",L"zsh",L"fish",L"nu"})if(_wcsicmp(name.c_str(),known)==0){hint.name=wave3::utf8(known);break;}
        }CloseHandle(process);
    }return hints;
}
static std::string waveShellValue(const Session* s,const std::map<std::string,WaveShellHint>& hints){ // lock held
    auto item=hints.find(s->paneId);
    return item!=hints.end()&&!s->exited&&s->childPid==item->second.pid&&s->childCreated==item->second.born?wave3::nullable(item->second.name):"null";
}
static bool setQuickHotkey(uint32_t value,bool persist,std::string& error){
    const bool reserve=value&&(value!=g_quickHotkey||!g_quickHotkeyId);
    const int next=g_quickHotkeyId==0x471?0x472:0x471;
    if(reserve&&!RegisterHotKey(g_hwnd,next,(value>>8)|MOD_NOREPEAT,value&255)){error="global hotkey unavailable; prior binding unchanged";return false;}
    if(persist){DWORD stored=value;auto saved=RegSetKeyValueW(HKEY_CURRENT_USER,kRegKey,L"QuickTerminalHotkey",REG_DWORD,&stored,sizeof stored);
        if(saved!=ERROR_SUCCESS){if(reserve)UnregisterHotKey(g_hwnd,next);error="hotkey could not be saved; prior binding unchanged";return false;}}
    if(reserve||!value){if(g_quickHotkeyId)UnregisterHotKey(g_hwnd,g_quickHotkeyId);g_quickHotkeyId=value?next:0;}
    {LockG hold;g_quickHotkey=value;}return true;
}
