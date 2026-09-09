// UI-thread-only owned native controls. The host retains the object until its HWND is gone.
#pragma once
#include <commctrl.h>
#include <functional>
#include "wave3.h"
class NativePicker {
    HWND owner_=nullptr,hwnd_=nullptr,edit_=nullptr,list_=nullptr,label_=nullptr,accept_=nullptr,cancel_=nullptr;
    HFONT font_=nullptr;UINT dpi_=96;bool ended_=false,disposing_=false,queryError_=false;
    std::function<void(const std::string&)> finish_;
    std::function<void(const std::string&)> diagnostic_;
    wave3::Selection selection_;
    int scale(int n)const{return (std::max)(1,MulDiv(n,(int)dpi_,96));}
    void fail(const char* message){
        try{diagnostic_(message);}catch(...){}
        try{finish("{\"result\":\"cancelled\"}");}catch(...){}
    }
    static LRESULT CALLBACK root(HWND h,UINT m,WPARAM w,LPARAM l){
        auto* p=reinterpret_cast<NativePicker*>(GetWindowLongPtrW(h,GWLP_USERDATA));
        if(m==WM_NCCREATE){p=static_cast<NativePicker*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);p->hwnd_=h;SetWindowLongPtrW(h,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(p));}
        if(!p)return DefWindowProcW(h,m,w,l);
        try{
            switch(m){
            case WM_CLOSE:p->finish("{\"result\":\"cancelled\"}");return 0;
            case WM_COMMAND:
                if(LOWORD(w)==101&&HIWORD(w)==EN_CHANGE)p->filter();
                else if((LOWORD(w)==1&&HIWORD(w)==BN_CLICKED)||(LOWORD(w)==102&&HIWORD(w)==LBN_DBLCLK))p->choose();
                else if(LOWORD(w)==2&&HIWORD(w)==BN_CLICKED)p->finish("{\"result\":\"cancelled\"}");
                return 0;
            case WM_SIZE:p->layout();break;
            case WM_SETFOCUS:p->focus();return 0;
            case WM_ACTIVATE:if(LOWORD(w)!=WA_INACTIVE)p->focus();break;
            case WM_DPICHANGED:{p->dpi_=LOWORD(w);auto r=*reinterpret_cast<RECT*>(l);SetWindowPos(h,nullptr,r.left,r.top,r.right-r.left,r.bottom-r.top,SWP_NOZORDER|SWP_NOACTIVATE);p->font();p->layout();break;}
            case WM_NCDESTROY:
                SetWindowLongPtrW(h,GWLP_USERDATA,0);p->hwnd_=nullptr;
                if(p->font_){DeleteObject(p->font_);p->font_=nullptr;}
                p->finish("{\"result\":\"cancelled\"}");break;
            }
        }catch(const std::exception& ex){p->fail(ex.what());return 0;}catch(...){p->fail("native picker callback failed");return 0;}
        return DefWindowProcW(h,m,w,l);
    }
    static LRESULT CALLBACK child(HWND h,UINT m,WPARAM w,LPARAM l,UINT_PTR id,DWORD_PTR data){
        auto* p=reinterpret_cast<NativePicker*>(data);
        try{
            if(m==WM_GETDLGCODE)return DefSubclassProc(h,m,w,l)|DLGC_WANTALLKEYS;
            if(m==WM_KEYDOWN){
                if(w==VK_ESCAPE){p->finish("{\"result\":\"cancelled\"}");return 0;}
                if(w==VK_RETURN){if(h==p->cancel_)p->finish("{\"result\":\"cancelled\"}");else p->choose();return 0;}
                if(w==VK_TAB){SetFocus(GetNextDlgTabItem(p->hwnd_,h,(GetKeyState(VK_SHIFT)&0x8000)!=0));return 0;}
                if(h==p->edit_&&w=='A'&&(GetKeyState(VK_CONTROL)&0x8000)){SendMessageW(h,EM_SETSEL,0,-1);return 0;}
                if((h==p->edit_||h==p->list_)&&(w==VK_UP||w==VK_DOWN)){
                    p->selection_.select((int)SendMessageW(p->list_,LB_GETCURSEL,0,0));p->selection_.move(w==VK_UP?-1:1);
                    SendMessageW(p->list_,LB_SETCURSEL,p->selection_.selected,0);return 0;
                }
            }
            if(m==WM_CHAR&&(w==VK_RETURN||w==VK_ESCAPE||w==VK_TAB))return 0;
            if(m==WM_NCDESTROY)RemoveWindowSubclass(h,child,id);
            return DefSubclassProc(h,m,w,l);
        }catch(const std::exception& ex){p->fail(ex.what());return 0;}catch(...){p->fail("picker control callback failed");return 0;}
    }
    HWND control(const wchar_t* cls,const wchar_t* title,DWORD style,int id){
        HWND h=CreateWindowExW(0,cls,title,WS_CHILD|WS_VISIBLE|style,0,0,1,1,hwnd_,reinterpret_cast<HMENU>((INT_PTR)id),GetModuleHandleW(nullptr),nullptr);
        if(!h)throw std::runtime_error("picker control creation failed");return h;
    }
    void font(){
        HFONT next=CreateFontW(-scale(14),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
        if(!next)throw std::runtime_error("picker font creation failed");
        for(auto h:{label_,edit_,list_,accept_,cancel_})if(h)SendMessageW(h,WM_SETFONT,(WPARAM)next,TRUE);
        if(font_)DeleteObject(font_);font_=next;
    }
    void layout(){
        if(!cancel_)return;RECT r{};GetClientRect(hwnd_,&r);int pad=scale(12),width=(std::max)(1,(int)r.right-2*pad),bottom=(std::max)(pad,(int)r.bottom-pad-scale(30));
        auto place=[](HWND h,int x,int y,int w,int ht){SetWindowPos(h,nullptr,x,y,w,ht,SWP_NOZORDER|SWP_NOACTIVATE);};
        place(label_,pad,pad,width,scale(24));place(edit_,pad,pad+scale(26),width,scale(28));
        place(list_,pad,pad+scale(62),width,(std::max)(1,bottom-pad-scale(70)));
        place(accept_,(std::max)(pad,(int)r.right-pad-scale(204)),bottom,scale(96),scale(30));
        place(cancel_,(std::max)(pad,(int)r.right-pad-scale(96)),bottom,scale(96),scale(30));
    }
    void filter(){
        if(!list_)return;wchar_t q[4097]{};GetWindowTextW(edit_,q,4097);
        try{selection_.set(q);queryError_=false;}catch(const std::invalid_argument& ex){
            queryError_=true;SendMessageW(list_,LB_RESETCONTENT,0,0);EnableWindow(accept_,FALSE);SetWindowTextW(label_,wave3::wide(ex.what()).c_str());return;
        }
        SetWindowTextW(label_,selection_.spec.promptSet?wave3::wide(selection_.spec.prompt).c_str():L"Select…");
        SendMessageW(list_,LB_RESETCONTENT,0,0);
        auto add=[&](const std::wstring& text){if(SendMessageW(list_,LB_ADDSTRING,0,(LPARAM)text.c_str())<0)throw std::runtime_error("picker list allocation failed");};
        for(int index:selection_.matches){const auto& i=selection_.spec.items[index];add(wave3::wide(i.label+(i.subtitle.empty()?"":" — "+i.subtitle)));}
        if(selection_.custom())add(L"Use \""+wave3::trim(selection_.query)+L"\"");
        SendMessageW(list_,LB_SETCURSEL,selection_.count()?0:-1,0);EnableWindow(accept_,selection_.count()>0);
    }
    void choose(){if(queryError_)return;selection_.select((int)SendMessageW(list_,LB_GETCURSEL,0,0));auto answer=selection_.choose();if(!answer.empty())finish(answer);}
public:
    std::string id;
    NativePicker(HWND owner,wave3::Pick spec,std::function<void(const std::string&)> finish,std::function<void(const std::string&)> diagnostic)
        :owner_(owner),finish_(std::move(finish)),diagnostic_(std::move(diagnostic)),selection_(std::move(spec)){}
    ~NativePicker(){dispose();}
    HWND hwnd()const{return hwnd_;}
    bool active()const{return hwnd_&&!ended_;}
    void show(){
        static bool registered=false;
        if(!registered){WNDCLASSW wc{};wc.lpfnWndProc=root;wc.hInstance=GetModuleHandleW(nullptr);wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);wc.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);wc.lpszClassName=L"AgwintermLitePicker";
            if(!RegisterClassW(&wc))throw std::runtime_error("picker class registration failed");registered=true;}
        dpi_=GetDpiForWindow(owner_);if(!dpi_)dpi_=96;
        RECT r{};GetWindowRect(owner_,&r);MONITORINFO mi{sizeof mi};if(!GetMonitorInfoW(MonitorFromWindow(owner_,MONITOR_DEFAULTTONEAREST),&mi))throw std::runtime_error("picker monitor unavailable");
        int width=(std::min)(scale(640),(int)(mi.rcWork.right-mi.rcWork.left)),height=(std::min)(scale(420),(int)(mi.rcWork.bottom-mi.rcWork.top));
        int x=(std::max)((int)mi.rcWork.left,(std::min)((int)mi.rcWork.right-width,(int)r.left+((int)(r.right-r.left)-width)/2));
        int y=(std::max)((int)mi.rcWork.top,(std::min)((int)mi.rcWork.bottom-height,(int)r.top+scale(60)));
        hwnd_=CreateWindowExW(WS_EX_CONTROLPARENT,L"AgwintermLitePicker",L"agliteterm picker",WS_CAPTION|WS_SYSMENU|WS_POPUP,x,y,width,height,owner_,nullptr,GetModuleHandleW(nullptr),this);
        if(!hwnd_)throw std::runtime_error("picker creation failed");
        label_=control(L"STATIC",L"",SS_NOPREFIX,100);edit_=control(L"EDIT",L"",WS_TABSTOP|WS_BORDER|ES_AUTOHSCROLL,101);
        list_=control(L"LISTBOX",L"",WS_TABSTOP|WS_BORDER|WS_VSCROLL|LBS_NOTIFY|LBS_NOINTEGRALHEIGHT,102);
        accept_=control(L"BUTTON",L"Select",WS_TABSTOP|BS_DEFPUSHBUTTON,1);cancel_=control(L"BUTTON",L"Cancel",WS_TABSTOP,2);
        for(auto h:{edit_,list_,accept_,cancel_})if(!SetWindowSubclass(h,child,1,(DWORD_PTR)this))throw std::runtime_error("picker subclass failed");
        SendMessageW(edit_,EM_SETLIMITTEXT,4096,0);font();layout();SetWindowTextW(edit_,wave3::wide(selection_.spec.query).c_str());filter();
        if(ended_||!hwnd_)throw std::runtime_error("picker closed during creation");
        ShowWindow(hwnd_,SW_SHOWNOACTIVATE);if(selection_.spec.follow)SetForegroundWindow(hwnd_);focus();
    }
    void focus(){if(!active()||!edit_)return;auto front=GetForegroundWindow();if(front==owner_||front==hwnd_)SetFocus(edit_);}
    bool route(UINT m,WPARAM w,LPARAM l){
        if(!active())return false;
        switch(m){
        case WM_KEYDOWN:case WM_KEYUP:case WM_CHAR:case WM_SYSKEYDOWN:case WM_SYSKEYUP:case WM_SYSCHAR:SendMessageW(edit_,m,w,l);return true;
        case WM_MOUSEMOVE:return true;
        case WM_DROPFILES:DragFinish((HDROP)w);return true;
        case WM_SETFOCUS:case WM_LBUTTONDOWN:case WM_LBUTTONUP:case WM_LBUTTONDBLCLK:case WM_RBUTTONDOWN:case WM_RBUTTONUP:case WM_MBUTTONDOWN:case WM_MBUTTONUP:case WM_MOUSEWHEEL:case WM_CONTEXTMENU:focus();return true;
        default:return false;
        }
    }
    void finish(const std::string& answer){if(ended_)return;ended_=true;try{finish_(answer);}catch(...){dispose();throw;}dispose();}
    void dispose(){
        if(disposing_)return;disposing_=true;ended_=true;
        const bool ours=hwnd_&&GetForegroundWindow()==hwnd_;
        if(hwnd_)DestroyWindow(hwnd_);hwnd_=nullptr;
        if(font_){DeleteObject(font_);font_=nullptr;}
        if(ours&&IsWindow(owner_)&&GetForegroundWindow()==owner_)SetFocus(owner_);
        disposing_=false;
    }
};
