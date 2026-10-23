// Windows overlay for the native REAPER piano roll. The parent is subclassed
// rather than replaced; REAPER still owns note editing, scrolling and painting.
#include "reaper_api.h"
#include <commctrl.h>
#include <windowsx.h>
#include "curve.h"
#include "handles.h"
#include "vibrato.h"
#include "view_state.h"
#include "midi_batch.h"
#include <array>
#include <string>
#include <vector>
#include <memory>
#include <cstdio>
#include <cmath>
#include <cstring>
static reaper_plugin_info_t* host;
static HHOOK keyboardHook;
static int command,midiCommand;
static gaccel_register_t action{};
static custom_action_register_t midiAction{32060,"MPE_DRAW_PITCH_TOGGLE_MIDI","MPE: Toggle per-note pitch editing",nullptr};
static constexpr UINT_PTR overlayId=0x4d5045;
static void closeEditor();
static void message(const char* text) {ShowMessageBox(text,"MPE pitch editor",0);}
struct Editor {
 HWND window=nullptr,piano=nullptr;
 MediaItem_Take* take=nullptr;ReaProject* project=nullptr;
 mpe::ViewState view;
 std::vector<mpe::Note> notes;
 std::vector<mpe::PitchEvent> events;
 std::array<std::vector<mpe::PitchEvent>,16> channels,allChannels;
 std::vector<char> chunk,rawBuffer;
 std::vector<mpe::Point> points;
 std::vector<mpe::Bend> nodes,cachedNodes;
 std::string nodeHash;
 char hash[128]{},dragHash[128]{};
 bool used[16]{},smooth=false,vibrato=false,dragging=false,pending=false;
 int selected=-1,handle=-1,cachedNote=-1,revision=-1;bool cachedSmooth=false;
 double depth=35,rate=5.5,pressDepth=35,pressRate=5.5;
 POINT press{};DWORD lastContent=0;
 double x(double ppq) const {return view.beats() ? (ppq-view.left)*view.zoom : (MIDI_GetProjTimeFromPPQPos(take,ppq)-MIDI_GetProjTimeFromPPQPos(take,view.left))*view.zoom;}
 double ppq(double x) const {return view.beats() ? view.left+x/view.zoom : MIDI_GetPPQPosFromProjTime(take,MIDI_GetProjTimeFromPPQPos(take,view.left)+x/view.zoom);}
 double y(int pitch) const {return 62+(view.topPitch-pitch+0.5)*view.rowHeight;}
 int bottom() const {RECT r{};GetClientRect(piano,&r);return std::max(62,int(r.bottom)-view.lanesHeight-16);}
 const std::vector<mpe::PitchEvent>& data(const mpe::Note& n)const {return n.muted ? allChannels[n.channel] : channels[n.channel];}
 mpe::Note* active() {for(auto& n:notes)if(n.index==selected)return &n;return nullptr;}
 void redraw() {InvalidateRect(piano,nullptr,FALSE);}
 void reindex() {
  for(auto& c:channels)c.clear();for(auto& c:allChannels)c.clear();
  for(auto e:events){allChannels[e.channel].push_back(e);if(!e.muted)channels[e.channel].push_back(e);}
 }
 bool layout() {
  if(!points.empty() || handle>=0)return true;
  if(!ValidatePtr2(project,take,"MediaItem_Take*"))return false;
  if(chunk.empty())chunk.resize(16*1024*1024);
  if(!GetItemStateChunk(GetMediaItemTake_Item(take),chunk.data(),int(chunk.size()),false))return false;
  mpe::ViewState next;
  if(!mpe::parseView(chunk.data(),int(GetMediaItemTakeInfo_Value(take,"IP_TAKENUMBER")),next))return false;
  bool changed=next.left!=view.left || next.zoom!=view.zoom || next.topPitch!=view.topPitch || next.rowHeight!=view.rowHeight || next.timebase!=view.timebase || next.lanesHeight!=view.lanesHeight;
  view=next;if(changed)redraw();return true;
 }
 bool refresh() {
  if(!points.empty() || handle>=0)return true;
  if(!ValidatePtr2(project,take,"MediaItem_Take*"))return false;
  int state=GetProjectStateChangeCount(project);
  if(!notes.empty() && state==revision)return true;
  if(!layout())return false;
  char current[128]{};if(!MIDI_GetHash(take,false,current,sizeof(current)))return false;
  if(strcmp(current,hash)) {
   notes.clear();events.clear();std::fill(used,used+16,false);selected=-1;
   int count=0,cc=0,text=0;MIDI_CountEvts(take,&count,&cc,&text);
   for(int i=0;i<count;++i) {
    mpe::Note n{};n.index=i;int velocity;
    if(MIDI_GetNote(take,i,&n.selected,&n.muted,&n.start,&n.end,&n.channel,&n.pitch,&velocity)) {notes.push_back(n);used[n.channel]=true;if(n.selected && selected<0)selected=i;}
   }
   for(int i=0;i<cc;++i) {
    bool s,m;double time;int type,ch,a,b;
    if(!MIDI_GetCC(take,i,&s,&m,&time,&type,&ch,&a,&b))continue;
    used[ch]=true;
    if(type==0xe0){int shape=0;double tension=0;MIDI_GetCCShape(take,i,&shape,&tension);events.push_back({i,ch,a+(b<<7),shape,time,tension,m});}
   }
   std::stable_sort(events.begin(),events.end(),[](auto a,auto b){return a.time<b.time;});reindex();
   strcpy_s(hash,current);redraw();
  }
  revision=state;return true;
 }
 std::vector<mpe::Bend> controls(const mpe::Note& n) {
  if(handle>=0 && !nodes.empty())return nodes;
  if(cachedNote==n.index && nodeHash==hash && cachedSmooth==smooth && !cachedNodes.empty())return cachedNodes;
  std::vector<mpe::Bend> samples;
  for(int i=0;i<=512;++i){double f=i/512.0,t=std::min(n.start+f*(n.end-n.start),std::max(n.start,n.end-1));samples.push_back({f,int(std::lround(mpe::channelValueAt(data(n),t)))});}
  cachedNodes=mpe::handles(samples,20,smooth);cachedNote=n.index;nodeHash=hash;cachedSmooth=smooth;return cachedNodes;
 }
 std::vector<mpe::Bend> drawn(const mpe::Note& n) {
  if(vibrato) {
   double begin=MIDI_GetProjTimeFromPPQPos(take,n.start),end=MIDI_GetProjTimeFromPPQPos(take,n.end);
   auto result=mpe::vibrato(end-begin,depth,rate);
   for(auto& b:result) {double t=MIDI_GetPPQPosFromProjTime(take,begin+b.fraction*(end-begin));double base=mpe::channelValueAt(data(n),std::min(t,std::max(n.start,n.end-1)));b.value=std::clamp(int(std::lround(base+b.value-8192)),0,16383);b.fraction=std::clamp((t-n.start)/(n.end-n.start),0.0,1.0);}
   return result;
  }
  std::vector<mpe::Point> timed;for(auto p:points)timed.push_back({ppq(p.x),p.y});
  return mpe::gesture(timed,n.start,n.end,y(n.pitch),smooth,view.rowHeight);
 }
 bool readRaw(std::vector<char>& output,int expected) {
  if(rawBuffer.empty())rawBuffer.resize(256*1024);
  for(int i=0;i<8;++i) {
   int capacity=int(rawBuffer.size()),bytes=capacity;bool ok=MIDI_GetAllEvts(take,rawBuffer.data(),&bytes);
   if(ok && bytes>0 && bytes<capacity){output.assign(rawBuffer.begin(),rawBuffer.begin()+bytes);return mpe::validRaw(output,expected);}
   size_t needed=bytes>capacity ? size_t(bytes)+1 : rawBuffer.size()*2;if(needed>32*1024*1024)return false;rawBuffer.resize(needed);
  }
  return false;
 }
 void commit(const std::vector<mpe::Bend>& bends) {
  char current[128]{};
  if(!ValidatePtr2(project,take,"MediaItem_Take*") || !MIDI_GetHash(take,false,current,sizeof(current)) || strcmp(current,dragHash)){message("MIDI changed during drawing; edit discarded.");cancel();refresh();return;}
  auto ptr=active();if(!ptr || bends.empty() || ptr->end<=ptr->start)return;auto n=*ptr;
  int target=mpe::allocate(n,notes,used);if(target<0){message("No unused MPE member channel is available.");return;}
  int expected=int(notes.size());std::vector<char> backup;
  if(!readRaw(backup,expected)){message("Could not obtain a complete MIDI snapshot; no edit made.");return;}
  auto finalNodes=handle>=0 ? nodes : mpe::handles(bends,20,smooth);
  Undo_BeginBlock2(project);MIDI_DisableSort(take);bool ok=true;std::vector<char> source=backup,output;
  if(target!=n.channel){bool noSort=true;ok=MIDI_SetNote(take,n.index,nullptr,nullptr,nullptr,nullptr,&target,nullptr,nullptr,&noSort);if(ok)ok=readRaw(source,expected);}
  if(ok)ok=mpe::replacePitch(source,target,n.start,n.end,n.muted,bends,output) && mpe::validRaw(output,expected);
  if(ok)ok=MIDI_SetAllEvts(take,output.data(),int(output.size()));MIDI_Sort(take);
  int count=0,cc=0,text=0;if(ok)ok=MIDI_CountEvts(take,&count,&cc,&text) && count==expected;
  bool restored=false;if(!ok){restored=MIDI_SetAllEvts(take,backup.data(),int(backup.size()));MIDI_CountEvts(take,&count,&cc,&text);restored=restored && count==expected;}
  Undo_EndBlock2(project,ok ? "MPE: edit note pitch curve" : "MPE: rejected edit",UNDO_STATE_ITEMS);
  if(ok) {
   for(auto& note:notes)if(note.index==n.index)note.channel=target;used[target]=true;
   events.erase(std::remove_if(events.begin(),events.end(),[&](auto e){return e.channel==target && e.time>=n.start && e.time<n.end;}),events.end());
   for(auto b:mpe::ticks(bends,n.start,n.end))events.push_back({-1,target,b.value,0,b.fraction,0,n.muted});
   std::stable_sort(events.begin(),events.end(),[](auto a,auto b){return a.time<b.time;});reindex();
   MIDI_GetHash(take,false,hash,sizeof(hash));cachedNodes=std::move(finalNodes);cachedNote=n.index;nodeHash=hash;cachedSmooth=smooth;
  }
  cancel();UpdateArrange();revision=GetProjectStateChangeCount(project);redraw();
  if(!ok){revision=-1;hash[0]=0;refresh();message(restored ? "Edit rejected; validated MIDI snapshot restored." : "Restoration could not be verified. Disable MPE editing and use Undo.");}
 }
 void cancel() {points.clear();nodes.clear();handle=-1;dragging=false;pending=false;}
 void paint(HDC dc) {
  int saved=SaveDC(dc);RECT area{};GetClientRect(piano,&area);IntersectClipRect(dc,0,62,area.right,bottom());
  HPEN pen=CreatePen(PS_SOLID,2,RGB(0,0,0));auto old=SelectObject(dc,pen);
  for(auto n:notes) {
   double left=x(n.start),right=x(n.end),base=y(n.pitch);
   if(right<0 || left>area.right || base<62 || base>bottom())continue;
   std::vector<mpe::Bend> preview;
   if(n.index==selected && dragging)preview=handle>=0 ? mpe::handleCurve(nodes,smooth) : drawn(n);
   bool first=true;
   auto vertex=[&](double xx,double value){int yy=int(std::lround(base-(value-8192)/8192.0*48*view.rowHeight));if(first){MoveToEx(dc,int(xx),yy,nullptr);first=false;}else LineTo(dc,int(xx),yy);};
   if(!preview.empty())for(auto b:preview)vertex(x(n.start+b.fraction*(n.end-n.start)),b.value);
   else {double lo=std::max(0.0,left),hi=std::min(double(area.right),right);int samples=std::clamp(int(hi-lo),2,1600);for(int i=0;i<=samples;++i){double xx=lo+(hi-lo)*i/samples;vertex(xx,mpe::channelValueAt(data(n),ppq(xx)));}}
   if(n.index==selected && !vibrato && (!dragging || handle>=0)) {
    auto brush=SelectObject(dc,GetStockObject(WHITE_BRUSH));
    for(auto b:controls(n)){int xx=int(x(n.start+b.fraction*(n.end-n.start))),yy=int(base-(b.value-8192)/8192.0*48*view.rowHeight);Ellipse(dc,xx-4,yy-4,xx+5,yy+5);}SelectObject(dc,brush);
   }
  }
  SelectObject(dc,old);DeleteObject(pen);RestoreDC(dc,saved);
  RECT toolbar{6,2,vibrato ? 620 : 440,29};HBRUSH bg=CreateSolidBrush(RGB(20,20,20));FillRect(dc,&toolbar,bg);DeleteObject(bg);SetBkMode(dc,TRANSPARENT);
  auto font=SelectObject(dc,GetStockObject(DEFAULT_GUI_FONT));
  auto label=[&](const char* text,int xx,bool active){SetTextColor(dc,active ? RGB(255,165,0) : RGB(255,255,255));TextOutA(dc,xx,7,text,int(strlen(text)));};
  label("Freehand [F]",14,!smooth && !vibrato);label("Smooth [S]",112,smooth && !vibrato);label("Flat [0]",208,false);label("Vibrato [V]",274,vibrato);label("Off [Esc]",365,false);
  if(vibrato){char text[80];snprintf(text,sizeof(text),"%.1f Hz / %.0f cents",rate,depth);label(text,445,false);}SelectObject(dc,font);
 }
 bool down(POINT p,bool alt,bool twice) {
  SetFocus(piano);
  if(p.y<30 && p.x>=6 && p.x<(vibrato ? 620 : 440)) {
   if(p.x<108){smooth=false;vibrato=false;}else if(p.x<204){smooth=true;vibrato=false;}
   else if(p.x<270){vibrato=false;flat();}else if(p.x<358)vibrato=true;else if(p.x<440){closeEditor();return true;}redraw();return true;
  }
  if(p.y<62 || p.y>=bottom())return false;
  if(GetProjectStateChangeCount(project)!=revision && !refresh())return true;
  cancel();auto n=active();
  if(n && !vibrato) {
   auto controlsNow=controls(*n);int nearby=-1;
   for(size_t i=0;i<controlsNow.size();++i){auto b=controlsNow[i];if(std::hypot(p.x-x(n->start+b.fraction*(n->end-n->start)),p.y-y(n->pitch)+(b.value-8192)/8192.0*48*view.rowHeight)<=7){nearby=int(i);break;}}
   if(alt) {
    if(nearby>0 && nearby+1<int(controlsNow.size())){controlsNow.erase(controlsNow.begin()+nearby);nodes=controlsNow;handle=0;strcpy_s(dragHash,hash);commit(mpe::handleCurve(nodes,smooth));}return true;
   }
   if(nearby>=0){nodes=controlsNow;handle=nearby;press=p;strcpy_s(dragHash,hash);SetCapture(piano);return true;}
   if(twice && controlsNow.size()<64 && p.x>x(n->start) && p.x<x(n->end)) {
    double f=(ppq(p.x)-n->start)/(n->end-n->start);auto at=std::lower_bound(controlsNow.begin(),controlsNow.end(),f,[](auto b,double t){return b.fraction<t;});
    if((at!=controlsNow.end() && std::abs(at->fraction-f)<0.0001) || (at!=controlsNow.begin() && std::abs((at-1)->fraction-f)<0.0001))return true;
    int i=int(at-controlsNow.begin()),value=std::clamp(int(std::lround(8192+(y(n->pitch)-p.y)/view.rowHeight/48*8192)),0,16383);controlsNow.insert(at,{f,value});nodes=controlsNow;handle=i;press=p;pending=true;strcpy_s(dragHash,hash);SetCapture(piano);redraw();return true;
   }
  }
  if(alt)return true;
  int hit=-1;double distance=1e9;
  if(n && p.x>=x(n->start) && p.x<=x(n->end)){double yy=y(n->pitch)-(mpe::channelValueAt(data(*n),ppq(p.x))-8192)/8192.0*48*view.rowHeight;if(std::abs(p.y-yy)<5)hit=n->index;}
  if(hit<0)for(auto note:notes){double d=std::abs(p.y-y(note.pitch));if(p.x>=x(note.start) && p.x<=x(note.end) && d<=std::max(4.0,view.rowHeight/2) && d<distance){hit=note.index;distance=d;}}
  if(hit<0)return true;
  selected=hit;for(auto& note:notes){bool sel=note.index==hit;if(note.selected!=sel)MIDI_SetNote(take,note.index,&sel,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr);note.selected=sel;}
  MIDI_GetHash(take,false,hash,sizeof(hash));revision=GetProjectStateChangeCount(project);strcpy_s(dragHash,hash);press=p;pressDepth=depth;pressRate=rate;points={{double(p.x),double(p.y)}};SetCapture(piano);redraw();return true;
 }
 void move(POINT p) {
  if(points.empty() && handle<0)return;
  if(!dragging && std::hypot(double(p.x-press.x),double(p.y-press.y))<3)return;
  dragging=true;auto n=active();if(!n)return;
  if(vibrato){depth=std::clamp(pressDepth+(press.y-p.y)/view.rowHeight*100,0.0,200.0);rate=std::clamp(pressRate+(p.x-press.x)/80.0,2.0,10.0);}
  else if(handle>=0){int value=int(std::lround(8192+(y(n->pitch)-p.y)/view.rowHeight/48*8192));mpe::moveHandle(nodes,handle,(ppq(p.x)-n->start)/(n->end-n->start),value);}
  else {double xx=std::clamp(double(p.x),x(n->start),x(n->end));if(!points.empty() && xx==points.back().x)points.back()={xx,double(p.y)};else points.push_back({xx,double(p.y)});if(points.size()>4096){std::vector<mpe::Point> compact;for(size_t i=0;i+1<points.size();i+=2)compact.push_back(points[i]);compact.push_back(points.back());points.swap(compact);}}
  redraw();
 }
 void up() {auto n=active();if(n && (dragging || pending || (vibrato && !points.empty()))){auto bends=handle>=0 ? mpe::handleCurve(nodes,smooth) : drawn(*n);commit(bends);}cancel();if(GetCapture()==piano)ReleaseCapture();redraw();}
 void flat(){if(active()){strcpy_s(dragHash,hash);commit({{0,8192},{1,8192}});}}
 bool key(UINT key) {
  if(GetKeyState(VK_MENU)<0)return false;
  if(GetKeyState(VK_CONTROL)<0){if(key!='Z')return false;cancel();if(GetKeyState(VK_SHIFT)<0)Undo_DoRedo2(project);else Undo_DoUndo2(project);refresh();return true;}
  if(key==VK_ESCAPE){closeEditor();return true;}
  if(key=='F'){smooth=false;vibrato=false;}else if(key=='S'){smooth=true;vibrato=false;}else if(key=='V')vibrato=true;else if(key=='0'){vibrato=false;flat();}else return false;redraw();return true;
 }
};
static std::unique_ptr<Editor> editor;
static std::array<bool,256> held{};
static LRESULT CALLBACK keyboard(int code,WPARAM removed,LPARAM param) {
 if(code>=0 && removed==PM_REMOVE) {
  auto msg=reinterpret_cast<MSG*>(param);UINT key=UINT(msg->wParam);
  if((msg->message==WM_KEYDOWN || msg->message==WM_KEYUP) && key<held.size()) {
   bool up=msg->message==WM_KEYUP,repeat=(msg->lParam&(LPARAM(1)<<30))!=0;
   if(held[key] && (up || repeat)){if(up)held[key]=false;msg->message=WM_NULL;}
   else if(!up && editor) {
    held[key]=false;HWND focus=GetFocus();char name[64]{};GetClassNameA(focus,name,sizeof(name));
    bool inEditor=focus==editor->window || IsChild(editor->window,focus);
    if(inEditor && _stricmp(name,"Edit")!=0 && editor->key(key)){held[key]=true;msg->message=WM_NULL;}
   }
  }
 }
 return CallNextHookEx(keyboardHook,code,removed,param);
}
static LRESULT CALLBACK pianoProc(HWND window,UINT msg,WPARAM w,LPARAM l,UINT_PTR,DWORD_PTR) {
 if(!editor)return DefSubclassProc(window,msg,w,l);
 switch(msg) {
  case WM_PAINT:{LRESULT result=DefSubclassProc(window,msg,w,l);if(editor){HDC dc=GetDC(window);editor->paint(dc);ReleaseDC(window,dc);}return result;}
  case WM_SETCURSOR:if(LOWORD(l)==HTCLIENT){POINT p{};GetCursorPos(&p);ScreenToClient(window,&p);if(p.y>=62 && p.y<editor->bottom()){SetCursor(LoadCursor(nullptr,IDC_CROSS));return TRUE;}}break;
  case WM_LBUTTONDOWN:case WM_LBUTTONDBLCLK:{POINT p{GET_X_LPARAM(l),GET_Y_LPARAM(l)};if(editor->down(p,GetKeyState(VK_MENU)<0,msg==WM_LBUTTONDBLCLK))return 0;break;}
  case WM_MOUSEMOVE:if(GetCapture()==window){editor->move({GET_X_LPARAM(l),GET_Y_LPARAM(l)});return 0;}break;
  case WM_LBUTTONUP:if(GetCapture()==window){editor->up();return 0;}break;
  case WM_CAPTURECHANGED:editor->cancel();editor->redraw();break;
  case WM_MOUSEWHEEL:case WM_MOUSEHWHEEL:case WM_HSCROLL:case WM_VSCROLL:{editor->cancel();LRESULT result=DefSubclassProc(window,msg,w,l);if(editor){editor->layout();editor->redraw();}return result;}
  case WM_TIMER:if(w==overlayId){if(MIDIEditor_GetActive()!=editor->window || EnumProjects(-1,nullptr,0)!=editor->project || !ValidatePtr2(editor->project,editor->take,"MediaItem_Take*") || MIDIEditor_GetTake(editor->window)!=editor->take){closeEditor();return 0;}editor->layout();if(GetTickCount()-editor->lastContent>100){editor->lastContent=GetTickCount();editor->refresh();}return 0;}break;
  case WM_NCDESTROY:closeEditor();break;
 }
 return DefSubclassProc(window,msg,w,l);
}
static void closeEditor() {
 if(!editor)return;HWND piano=editor->piano;KillTimer(piano,overlayId);RemoveWindowSubclass(piano,pianoProc,overlayId);
 if(GetCapture()==piano)ReleaseCapture();editor.reset();InvalidateRect(piano,nullptr,FALSE);
 RefreshToolbar2(0,command);RefreshToolbar2(32060,midiCommand);
}
static int toggleState(int id){return id==command || id==midiCommand ? (editor ? 1 : 0) : -1;}
static bool onAction(KbdSectionInfo*,int id,int,int,int,HWND) {
 if(id!=command && id!=midiCommand)return false;if(editor){closeEditor();return true;}
 HWND window=MIDIEditor_GetActive();auto take=window ? MIDIEditor_GetTake(window) : nullptr;HWND piano=window ? GetDlgItem(window,1001) : nullptr;
 if(!take || !piano){message("Open the built-in MIDI piano roll before enabling MPE editing.");return true;}
 auto next=std::make_unique<Editor>();next->window=window;next->piano=piano;next->take=take;next->project=EnumProjects(-1,nullptr,0);
 if(!next->refresh()){message("Could not read the MIDI editor layout. Use standard piano-roll mode.");return true;}
 if(!SetWindowSubclass(piano,pianoProc,overlayId,0)){message("Could not attach to the native piano roll.");return true;}
 editor=std::move(next);SetTimer(piano,overlayId,16,nullptr);editor->redraw();RefreshToolbar2(0,command);RefreshToolbar2(32060,midiCommand);return true;
}
extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE,reaper_plugin_info_t* rec) {
 if(!rec){closeEditor();if(keyboardHook)UnhookWindowsHookEx(keyboardHook);keyboardHook=nullptr;if(host){host->Register("-hookcommand2",reinterpret_cast<void*>(onAction));host->Register("-toggleaction",reinterpret_cast<void*>(toggleState));host->Register("-gaccel",&action);host->Register("-custom_action",&midiAction);}host=nullptr;return 0;}
 if(rec->caller_version!=REAPER_PLUGIN_VERSION || REAPERAPI_LoadAPI(rec->GetFunc))return 0;host=rec;
 keyboardHook=SetWindowsHookEx(WH_GETMESSAGE,keyboard,nullptr,GetCurrentThreadId());if(!keyboardHook)return 0;
 command=host->Register("command_id",const_cast<char*>("MPE_DRAW_ONE_NOTE"));action.accel.cmd=static_cast<WORD>(command);action.desc="MPE: Toggle per-note pitch editing";
 host->Register("gaccel",&action);midiCommand=host->Register("custom_action",&midiAction);host->Register("hookcommand2",reinterpret_cast<void*>(onAction));host->Register("toggleaction",reinterpret_cast<void*>(toggleState));return 1;
}
