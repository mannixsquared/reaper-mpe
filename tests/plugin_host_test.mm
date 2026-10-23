// A small in-memory REAPER host loads the actual dylib and exercises its Cocoa
// overlay and MIDI commit path, without modifying a running REAPER project.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include "reaper_plugin.h"
#undef min
#undef max
#include "curve.h"
#include "midi_batch.h"
#include <dlfcn.h>
#include <cassert>
#include <cstring>
#include <string>
#include <iostream>
struct HostNote { bool selected,muted; double start,end; int channel,pitch,velocity; };
struct HostCC { bool selected,muted; double time; int type,channel,a,b; };
static std::vector<HostNote> notes;
static std::vector<HostCC> ccs,snapshotCCs;
static std::vector<HostNote> snapshotNotes;
static int revision=1,undoBegin=0,undoEnd=0,restoreCount=0,messages=0;
static bool failInsert=false,sortDisabled=false,fullBufferOnce=false;
static int silentFullBufferReads=0;
static int disableCalls=0,sortCalls=0,chunkCalls=0,hashCalls=0,enumCalls=0,bulkCalls=0,singleEventCalls=0;
static NSView* editor;
static MediaItem_Take* take=(MediaItem_Take*)2;
static ReaProject* project=(ReaProject*)3;
static bool (*hook)(KbdSectionInfo*,int,int,int,int,HWND);
static int (*toggle)(int);
static int registeredCommand=50000;
static accelerator_register_t* accelerator;
static double viewLeft=0,viewRowHeight=12;
static HWND getEditor() { return (HWND)editor; }
static MediaItem_Take* getTake(HWND) { return take; }
static int enumSel(MediaItem_Take*,int previous) { for(int i=previous+1;i<int(notes.size());++i) if(notes[i].selected) return i; return -1; }
static bool getNote(MediaItem_Take*,int i,bool* s,bool* m,double* a,double* b,int* c,int* p,int* v) { if(i<0 || i>=int(notes.size())) return false; auto n=notes[i]; *s=n.selected; *m=n.muted; *a=n.start; *b=n.end; *c=n.channel; *p=n.pitch; *v=n.velocity; return true; }
static bool count(MediaItem_Take*,int* n,int* c,int* t) {++enumCalls; *n=int(notes.size()); *c=int(ccs.size()); *t=0; return true; }
static bool getCC(MediaItem_Take*,int i,bool* s,bool* m,double* t,int* type,int* ch,int* a,int* b) { if(i<0 || i>=int(ccs.size())) return false; auto c=ccs[i]; *s=c.selected; *m=c.muted; *t=c.time; *type=c.type; *ch=c.channel; *a=c.a; *b=c.b; return true; }
static bool getHash(MediaItem_Take*,bool,char* out,int length) {++hashCalls; snprintf(out,length,"revision%d",revision); return true; }
static bool setNote(MediaItem_Take*,int i,const bool* s,const bool* m,const double* a,const double* b,const int* c,const int* p,const int* v,const bool*) { auto& n=notes.at(i); if(s)n.selected=*s;if(m)n.muted=*m;if(a)n.start=*a;if(b)n.end=*b;if(c)n.channel=*c;if(p)n.pitch=*p;if(v)n.velocity=*v;++revision;return true; }
static bool insertCC(MediaItem_Take*,bool s,bool m,double t,int type,int c,int a,int b) {++singleEventCalls; assert(sortDisabled); if(failInsert) return false; ccs.push_back({s,m,t,type,c,a,b}); ++revision; return true; }
static void disableSort(MediaItem_Take*) { assert(!sortDisabled);sortDisabled=true;++disableCalls; }
static void sort(MediaItem_Take*) { assert(sortDisabled);sortDisabled=false;++sortCalls; std::stable_sort(ccs.begin(),ccs.end(),[](auto a,auto b){return a.time<b.time;}); }
static void begin(ReaProject*) { ++undoBegin; }
static void end(ReaProject*,const char*,int flags) { assert(flags==UNDO_STATE_ITEMS);++undoEnd; }
static int showMessage(const char*,const char*,int) { ++messages; return 0; }
static bool validate(ReaProject*,void* p,const char*) { return p==take; }
static void update() {}
static int changes(ReaProject*) { return revision; }
static ReaProject* enumProjects(int,char*,int) { return project; }
static MediaItem* getItem(MediaItem_Take*) { return (MediaItem*)4; }
static double takeInfo(MediaItem_Take*,const char*) { return 0; }
static bool chunk(MediaItem*,char* out,int n,bool) {++chunkCalls;snapshotCCs=ccs;snapshotNotes=notes;
 const char* text="<ITEM\nCFGEDITVIEW 0 1 60 12\nCFGEDIT 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0\n>\n";
 std::string state=text;
 state.replace(state.find("CFGEDITVIEW 0"),13,"CFGEDITVIEW "+std::to_string(viewLeft));
 state.replace(state.find("60 12"),5,"60 "+std::to_string(viewRowHeight));
 snprintf(out,n,"%s",state.c_str()); return true;
}
static bool restoreItem(MediaItem*,const char*,bool) {notes=snapshotNotes;ccs=snapshotCCs;++restoreCount;++revision;return true;}
static MediaItem_Take* activeTake(MediaItem*) {return take;}
static double convert(MediaItem_Take*,double value) { return value; }
static bool deleteCC(MediaItem_Take*,int index) {++singleEventCalls; assert(sortDisabled); ccs.erase(ccs.begin()+index);++revision;return true; }
static bool restoreExpected=false;
static bool getAll(MediaItem_Take*,char* out,int* size) {
 if(fullBufferOnce) {fullBufferOnce=false;++silentFullBufferReads;memset(out,0,*size);return true;}
 std::vector<mpe::RawEvent> records;
 for(auto n:notes) {
   unsigned char flags=(n.selected ? 1 : 0)|(n.muted ? 2 : 0);
   records.push_back({int64_t(n.start),flags,{char(0x90|n.channel),char(n.pitch),char(n.velocity)}});
   records.push_back({int64_t(n.end),flags,{char(0x80|n.channel),char(n.pitch),char(0)}});
 }
 for(auto c:ccs)records.push_back({int64_t(c.time),static_cast<unsigned char>((c.selected ? 1 : 0)|(c.muted ? 2 : 0)),{char(c.type|c.channel),char(c.a),char(c.b)}});
 std::stable_sort(records.begin(),records.end(),[](auto a,auto b){return a.time<b.time;});
 std::vector<char> raw;int64_t previous=0;
 for(auto e:records) {
   int32_t delta=int32_t(e.time-previous),length=int32_t(e.message.size());size_t offset=raw.size();raw.resize(offset+9+length);
   memcpy(raw.data()+offset,&delta,4);raw[offset+4]=char(e.flags);memcpy(raw.data()+offset+5,&length,4);memcpy(raw.data()+offset+9,e.message.data(),length);previous=e.time;
 }
 if(*size<int(raw.size())) {*size=int(raw.size());return false;}
 memcpy(out,raw.data(),raw.size());*size=int(raw.size());return true;
}
static bool setAll(MediaItem_Take*,const char* data,int bytes) {++bulkCalls;assert(mpe::validRaw(std::vector<char>(data,data+bytes),int(notes.size())));
 if(failInsert) {failInsert=false;restoreExpected=true;return false;}
 if(restoreExpected) {++restoreCount;restoreExpected=false;}
 std::vector<HostNote> nextNotes;std::vector<HostCC> nextCCs;
 size_t pos=0;int64_t time=0;
 while(pos<size_t(bytes)) {
   if(size_t(bytes)-pos<9)return false;
   int32_t delta,length;memcpy(&delta,data+pos,4);unsigned char flags=data[pos+4];memcpy(&length,data+pos+5,4);pos+=9;
   if(length<0 || size_t(length)>size_t(bytes)-pos)return false;
   time+=delta;const auto* msg=(const unsigned char*)data+pos;pos+=length;
   if(length<3)continue;
   int channel=msg[0]&15,type=msg[0]&0xf0;
   if(type==0x90 && msg[2])nextNotes.push_back({bool(flags&1),bool(flags&2),double(time),-1,channel,msg[1],msg[2]});
   else if(type==0x80 || type==0x90) {
     for(auto& n:nextNotes)if(n.end<0 && n.channel==channel && n.pitch==msg[1]) {n.end=double(time);break;}
   } else nextCCs.push_back({bool(flags&1),bool(flags&2),double(time),type,channel,msg[1],msg[2]});
 }
 notes=std::move(nextNotes);ccs=std::move(nextCCs);++revision;return true;
}
static bool shape(MediaItem_Take*,int,int* s,double* t) { *s=0;*t=0;return true; }
static int undo(ReaProject*) { return 0; }
static void toolbar(int,int) {}
static HWND child(HWND,int id) { return id==1001 ? (HWND)editor : nullptr; }
static int registration(const char* name,void* value) {
 if(!strcmp(name,"accelerator"))accelerator=(accelerator_register_t*)value;
 if(!strcmp(name,"command_id"))return registeredCommand;
 if(!strcmp(name,"custom_action"))return registeredCommand+1;
 if(!strcmp(name,"hookcommand2"))hook=(decltype(hook))value;
 if(!strcmp(name,"toggleaction"))toggle=(decltype(toggle))value;
 return 1;
}
static void* function(const char* name) {
#define API(n,f) if(!strcmp(name,n))return (void*)f
 API("MIDIEditor_GetActive",getEditor); API("MIDIEditor_GetTake",getTake); API("MIDI_EnumSelNotes",enumSel);
 API("MIDI_GetNote",getNote);API("MIDI_CountEvts",count);API("MIDI_GetCC",getCC);API("MIDI_GetHash",getHash);
 API("MIDI_SetNote",setNote);API("MIDI_InsertCC",insertCC);API("MIDI_DisableSort",disableSort);API("MIDI_Sort",sort);API("Undo_BeginBlock2",begin);API("Undo_EndBlock2",end);
 API("ShowMessageBox",showMessage);API("ValidatePtr2",validate);API("UpdateArrange",update);API("GetProjectStateChangeCount",changes);API("EnumProjects",enumProjects);
 API("SetItemStateChunk",restoreItem);API("GetActiveTake",activeTake);API("GetItemStateChunk",chunk);API("GetMediaItemTake_Item",getItem);API("GetMediaItemTakeInfo_Value",takeInfo);API("MIDI_GetProjTimeFromPPQPos",convert);API("MIDI_GetPPQPosFromProjTime",convert);
 API("MIDI_DeleteCC",deleteCC);API("MIDI_GetAllEvts",getAll);API("MIDI_SetAllEvts",setAll);API("MIDI_GetCCShape",shape);API("Undo_DoUndo2",undo);API("Undo_DoRedo2",undo);API("RefreshToolbar2",toolbar);API("JS_Window_FindChildByID",child);
 std::cerr<<"Unexpected API: "<<name<<"\n"; return nullptr;
#undef API
}
@interface NSView (MPEHostTesting)
- (void)commitCurve:(const std::vector<mpe::Bend>&)curve;
- (bool)refresh;
- (bool)refreshLayout;
- (double)xFor:(double)ppq;
- (double)yFor:(int)pitch;
- (std::vector<mpe::Bend>)handlesFor:(const mpe::Note&)note;
- (std::vector<mpe::Bend>)drawnCurve:(const mpe::Note&)note;
- (BOOL)handlePitchKey:(unsigned int)key modifiers:(NSEventModifierFlags)modifiers;
@end
static void selectNote(NSView* view,int selected) {
 for(int i=0;i<int(notes.size());++i)notes[i].selected=i==selected;
 ++revision; assert([view refresh]);
 Ivar hash=class_getInstanceVariable(view.class,"dragHash");
 getHash(take,false,(char*)view+ivar_getOffset(hash),128);
}
int main(int argc,char** argv) { @autoreleasepool {
 assert(argc==2);
 void* library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if(!library) { std::cerr<<dlerror()<<"\n"; return 1; }
 auto entry=(int(*)(void*,reaper_plugin_info_t*))dlsym(library,"ReaperPluginEntry");assert(entry);
 editor=[[NSView alloc] initWithFrame:NSMakeRect(0,0,900,500)];
 notes={{true,false,100,300,0,60,100},{false,false,150,350,0,64,100}};
 // An unrelated controller must survive drawing and rollback unchanged.
 ccs={{false,false,175,0xB0,0,74,75}};
 reaper_plugin_info_t rec{};rec.caller_version=REAPER_PLUGIN_VERSION;rec.Register=registration;rec.GetFunc=function;
 assert(entry(nullptr,&rec)==1 && hook && toggle);
 assert(toggle(registeredCommand)==0);
 assert(hook(nullptr,registeredCommand,0,0,0,nullptr));
 assert(editor.subviews.count==1 && toggle(registeredCommand)==1);
 NSView* view=editor.subviews[0];
 assert(accelerator && accelerator->translateAccel && accelerator->isLocal);
 MSG key{}; key.hwnd=(HWND)editor; key.message=WM_KEYDOWN; key.wParam='S';
 assert(accelerator->translateAccel(&key,accelerator)==1);
 Ivar smooth=class_getInstanceVariable(view.class,"smooth");
 assert(*(bool*)((char*)view+ivar_getOffset(smooth)));
 // Repeat and release never reach REAPER's native Slice shortcut.
 key.lParam=LPARAM(1)<<30;assert(accelerator->translateAccel(&key,accelerator)==1);key.lParam=0;
 key.message=WM_KEYUP; assert(accelerator->translateAccel(&key,accelerator)==1);
 key.message=WM_KEYDOWN; key.wParam='F';assert(accelerator->translateAccel(&key,accelerator)==1);
 assert(!*(bool*)((char*)view+ivar_getOffset(smooth)));
 // Missing key-up must not stop a later fresh press from switching tools.
 key.wParam='S';assert(accelerator->translateAccel(&key,accelerator)==1);
 assert(*(bool*)((char*)view+ivar_getOffset(smooth)));
 key.wParam='F';assert(accelerator->translateAccel(&key,accelerator)==1);
 assert(!*(bool*)((char*)view+ivar_getOffset(smooth)));
 key.message=WM_KEYUP;assert(accelerator->translateAccel(&key,accelerator)==1);
 key.message=WM_KEYDOWN;key.wParam='A';assert(accelerator->translateAccel(&key,accelerator)==0);
 assert(![view handlePitchKey:'S' modifiers:NSEventModifierFlagCommand]);
 assert(![view handlePitchKey:'S' modifiers:NSEventModifierFlagOption]);
 // Layout updates immediately even when MIDI hash/revision has not changed.
 assert([view xFor:100]==100); viewLeft=25; assert([view refreshLayout]); assert([view xFor:100]==75);
 viewLeft=0;assert([view refreshLayout]);
 // Exercise the actual plugin's gesture mapping at a zoomed row height.
 viewRowHeight=32;assert([view refreshLayout]);
 Ivar pointsIvar=class_getInstanceVariable(view.class,"points");
 auto* drawn=(std::vector<mpe::Point>*)((char*)view+ivar_getOffset(pointsIvar));
 *drawn={{100,[view yFor:60]},{300,[view yFor:63]}};
 auto joined=[view drawnCurve:mpe::Note{0,0,60,100,300,true,false}];
 assert(joined.back().value==8704); // +3 semitones at +/-48
 drawn->clear();viewRowHeight=12;assert([view refreshLayout]);

 Ivar timerIvar=class_getInstanceVariable(view.class,"viewTimer");
 NSTimer* timer=object_getIvar(view,timerIvar);assert(timer && timer.timeInterval<0.017);

 // Exercise native event handling: click the second note, then the first.
 // Convert overlay-local points into the window coordinate system used by events.
 for(auto local:{NSMakePoint(200,104),NSMakePoint(120,152)}) {
   NSPoint location=[view convertPoint:local toView:nil];
   NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:location modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
   [view mouseDown:down];
   NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:location modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:0];
   [view mouseUp:up];
 }
 assert(notes[0].selected && !notes[1].selected);
 selectNote(view,0); [view commitCurve:std::vector<mpe::Bend>{{0,8192},{0.5,8600},{1,9000}}];
 assert(editor.subviews.count==1 && notes[0].channel==1 && ccs.size()==4);
 assert(ccs[0].time==100 && ccs.back().time==299);
 selectNote(view,0); [view commitCurve:std::vector<mpe::Bend>{{0,8192},{1,8192}}];
 assert(notes[0].channel==1 && ccs.size()==3); // replaces, never stacks
 selectNote(view,1); [view commitCurve:std::vector<mpe::Bend>{{0,8192},{1,7800}}];
 assert(notes[1].channel==2 && ccs.size()==5); // isolate overlapping notes
 bool preserved=false;for(auto c:ccs)if(c.type==0xB0&&c.a==74&&c.b==75)preserved=true;assert(preserved);
 int oldCount=int(ccs.size());selectNote(view,0);failInsert=true;
 [view commitCurve:std::vector<mpe::Bend>{{0,0},{1,16383}}]; failInsert=false;
 assert(restoreCount==1 && int(ccs.size())==oldCount && notes[0].channel==1);
 assert(undoBegin==4 && undoEnd==4 && messages==1);
 // A MIDI change between press and release invalidates the gesture.
 selectNote(view,0);++revision;[view commitCurve:std::vector<mpe::Bend>{{0,0},{1,16383}}];
 assert(undoBegin==4 && messages==2);
 // Drag the selected flat curve's middle handle: preserve both endpoints,
 // move timing and pitch, commit normal MIDI, and retain the overlay.
 selectNote(view,0);
 auto sendMouse=[&](NSEventType type,NSPoint local,int clicks=1,NSEventModifierFlags modifiers=0) {
   NSPoint location=[view convertPoint:local toView:nil];
   NSEvent* event=[NSEvent mouseEventWithType:type location:location modifierFlags:modifiers timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:clicks pressure:1];
   if(type==NSEventTypeLeftMouseDown)[view mouseDown:event];
   else if(type==NSEventTypeLeftMouseDragged)[view mouseDragged:event];
   else [view mouseUp:event];
 };
 int beforeChunks=chunkCalls,beforeHashes=hashCalls,beforeEnums=enumCalls,beforeBulk=bulkCalls;
 sendMouse(NSEventTypeLeftMouseDown,NSMakePoint([view xFor:200],[view yFor:60]),2);
 assert(chunkCalls==beforeChunks && hashCalls==beforeHashes && enumCalls==beforeEnums);
 fullBufferOnce=true;
 sendMouse(NSEventTypeLeftMouseDragged,NSMakePoint([view xFor:240],[view yFor:63]));
 sendMouse(NSEventTypeLeftMouseUp,NSMakePoint([view xFor:240],[view yFor:63]));
 assert(undoBegin==5 && undoEnd==5 && editor.subviews.count==1);
 assert(chunkCalls==beforeChunks && enumCalls==beforeEnums+1 && bulkCalls==beforeBulk+1 && singleEventCalls==0 && silentFullBufferReads==1);
 bool moved=false,startFlat=false,endFlat=false;
 for(auto c:ccs)if(c.type==0xE0 && c.channel==1) {
   int value=c.a+(c.b<<7);
   if(c.time==240 && value==8704)moved=true;
   if(c.time==100 && value==8192)startFlat=true;
   if(c.time==299 && value==8192)endFlat=true;
 }

 assert(moved && startFlat && endFlat);
 // A fresh freehand stroke tracks backwards and then vertical movement past
 // the note's right edge, without entering handle dragging.
 selectNote(view,0);
 sendMouse(NSEventTypeLeftMouseDown,NSMakePoint([view xFor:120],[view yFor:60]));
 sendMouse(NSEventTypeLeftMouseDragged,NSMakePoint([view xFor:250],[view yFor:62]));
 sendMouse(NSEventTypeLeftMouseDragged,NSMakePoint([view xFor:180],[view yFor:61]));
 sendMouse(NSEventTypeLeftMouseDragged,NSMakePoint([view xFor:340],[view yFor:62]));
 sendMouse(NSEventTypeLeftMouseDragged,NSMakePoint([view xFor:350],[view yFor:63]));
 sendMouse(NSEventTypeLeftMouseUp,NSMakePoint([view xFor:350],[view yFor:63]));
 bool edgeTracks=false;for(auto c:ccs)if(c.type==0xE0 && c.channel==1 && c.time==299 && c.a+(c.b<<7)==8704)edgeTracks=true;
 assert(edgeTracks && undoBegin==6);
 assert(disableCalls==6 && sortCalls==6 && !sortDisabled);
 // Adding without dragging commits on mouse-up; Alt-click deletion is an
 // immediate undoable curve edit. Boundary anchors cannot be removed.
 mpe::Note editable{0,1,60,100,300,true,false};
 auto beforeAdd=[view handlesFor:editable];int undoBeforeAdd=undoBegin;
 NSPoint addPoint=NSMakePoint([view xFor:210],[view yFor:58]);
 sendMouse(NSEventTypeLeftMouseDown,addPoint,2);
 sendMouse(NSEventTypeLeftMouseUp,addPoint,2);
 auto afterAdd=[view handlesFor:editable];
 assert(afterAdd.size()==beforeAdd.size()+1 && undoBegin==undoBeforeAdd+1);
 sendMouse(NSEventTypeLeftMouseDown,addPoint,1,NSEventModifierFlagOption);
 sendMouse(NSEventTypeLeftMouseUp,addPoint,1,NSEventModifierFlagOption);
 assert([view handlesFor:editable].size()==beforeAdd.size() && undoBegin==undoBeforeAdd+2);
 auto remaining=[view handlesFor:editable];
 NSPoint endpoint=NSMakePoint([view xFor:100],[view yFor:60]-(remaining.front().value-8192)/8192.0*48*12);
 sendMouse(NSEventTypeLeftMouseDown,endpoint,1,NSEventModifierFlagOption);
 sendMouse(NSEventTypeLeftMouseUp,endpoint,1,NSEventModifierFlagOption);
 assert(undoBegin==undoBeforeAdd+2 && [view handlesFor:editable].size()==remaining.size());


 // The replacement toolbar tool applies a deterministic natural vibrato to
 // the selected note in one undo step, preserving every note and its endpoints.
 assert(![view handlePitchKey:'C' modifiers:0]);
 assert([view handlePitchKey:'V' modifiers:0]);
 int beforeVibrato=undoBegin;
 sendMouse(NSEventTypeLeftMouseDown,NSMakePoint([view xFor:150],[view yFor:60]));
 sendMouse(NSEventTypeLeftMouseUp,NSMakePoint([view xFor:150],[view yFor:60]));
 assert(undoBegin==beforeVibrato+1 && notes.size()==2 && notes[0].pitch==60);
 assert([view handlePitchKey:'F' modifiers:0]);
 // Escape is consumed before native editor shortcuts. Even auto-repeat after
 // removing the overlay stays swallowed until key-up; then native keys resume.
 [timer retain];
 key.message=WM_KEYDOWN;key.wParam=27;
 assert(accelerator->translateAccel(&key,accelerator)==1);
 assert(editor.subviews.count==0 && toggle(registeredCommand)==0 && !timer.valid);
 key.lParam=LPARAM(1)<<30;assert(accelerator->translateAccel(&key,accelerator)==1);key.lParam=0;
 key.message=WM_KEYUP;assert(accelerator->translateAccel(&key,accelerator)==1);
 key.message=WM_KEYDOWN;assert(accelerator->translateAccel(&key,accelerator)==0);
 [timer release];
 assert(entry(nullptr,nullptr)==0);[editor release];
 // Objective-C classes stay registered for process lifetime; do not dlclose.
 std::cout<<"Plugin host: persistent overlay, multi-note edits, redraw replacement, channel isolation, rollback, stale-stroke rejection, toggle, shortcut capture, Escape lifecycle and immediate viewport sync passed.\n";
} }
