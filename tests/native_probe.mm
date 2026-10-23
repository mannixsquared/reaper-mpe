// Runs only in the isolated build/native-test resource. Uses the actual built
// plugin and REAPER APIs, never the caller's open project or resource directory.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include "reaper_plugin.h"
#define REAPERAPI_IMPLEMENT
#define REAPERAPI_MINIMAL
#define REAPERAPI_WANT_EnumProjects
#define REAPERAPI_WANT_GetResourcePath
#define REAPERAPI_WANT_InsertTrackAtIndex
#define REAPERAPI_WANT_GetTrack
#define REAPERAPI_WANT_CountTracks
#define REAPERAPI_WANT_CreateNewMIDIItemInProj
#define REAPERAPI_WANT_GetActiveTake
#define REAPERAPI_WANT_MIDI_InsertNote
#define REAPERAPI_WANT_MIDI_CountEvts
#define REAPERAPI_WANT_MIDI_GetNote
#define REAPERAPI_WANT_MIDI_SetNote
#define REAPERAPI_WANT_MIDI_SelectAll
#define REAPERAPI_WANT_MIDI_GetHash
#define REAPERAPI_WANT_SetItemStateChunk
#define REAPERAPI_WANT_SetMediaItemSelected
#define REAPERAPI_WANT_Main_OnCommand
#define REAPERAPI_WANT_NamedCommandLookup
#include "reaper_plugin_functions.h"
#undef min
#undef max
#include "curve.h"
#include "midi_batch.h"
#include <fstream>
#include <iterator>
#include <cstdio>
#include <tuple>
#include <dlfcn.h>
#include <chrono>
static reaper_plugin_info_t* host;
@interface NSView (NativeProbe)
- (bool)refresh;
- (std::vector<mpe::Bend>)drawnCurve:(const mpe::Note&)note;
- (void)commitCurve:(const std::vector<mpe::Bend>&)bends;
- (BOOL)handlePitchKey:(unsigned int)key modifiers:(NSEventModifierFlags)modifiers;
@end
static NSView* findOverlay(NSView* view) {
 if([view isKindOfClass:NSClassFromString(@"MPEPitchView")])return view;
 for(NSView* child in view.subviews)if(auto found=findOverlay(child))return found;
 return nil;
}
struct Note {bool selected,muted;double start,end;int channel,pitch,velocity;};
static std::vector<Note> readNotes(MediaItem_Take* take) {
 int count,cc,text;MIDI_CountEvts(take,&count,&cc,&text);std::vector<Note> result;
 for(int i=0;i<count;++i) {Note n{};if(MIDI_GetNote(take,i,&n.selected,&n.muted,&n.start,&n.end,&n.channel,&n.pitch,&n.velocity))result.push_back(n);}
 return result;
}
static FILE* probeLog=nullptr;
static bool (*originalGet)(MediaItem_Take*,char*,int*);
static bool (*originalSet)(MediaItem_Take*,const char*,int);
static void inspect(const char* data,int bytes) {
 size_t pos=0;int noteOns=0,records=0;
 while(pos<size_t(bytes)) {
   if(size_t(bytes)-pos<9){fprintf(probeLog,"trailing=%zu ",size_t(bytes)-pos);break;}
   int32_t length;memcpy(&length,data+pos+5,4);
   if(length<0 || size_t(length)>size_t(bytes)-pos-9){fprintf(probeLog,"invalid at %zu len=%d ",pos,length);break;}
   if(length>=3 && ((unsigned char)data[pos+9]&0xf0)==0x90 && (unsigned char)data[pos+11]>0)++noteOns;
   pos+=9+length;++records;
 }
 fprintf(probeLog,"records=%d noteOns=%d parsed=%zu\n",records,noteOns,pos);fflush(probeLog);
}
static bool probeGet(MediaItem_Take* take,char* output,int* size) {
 int capacity=*size;bool ok=originalGet(take,output,size);
 fprintf(probeLog,"GET capacity=%d return=%d size=%d ",capacity,ok,*size);
 if(ok && *size>=0 && *size<=capacity)inspect(output,*size);else {fprintf(probeLog,"\n");fflush(probeLog);}
 return ok;
}
static bool probeSet(MediaItem_Take* take,const char* input,int size) {
 fprintf(probeLog,"SET size=%d ",size);inspect(input,size);
 bool ok=originalSet(take,input,size);int count,cc,text;MIDI_CountEvts(take,&count,&cc,&text);
 fprintf(probeLog,"SET returned=%d notes=%d cc=%d\n",ok,count,cc);fflush(probeLog);return ok;
}

static int probeMessage(const char* text,const char*,int) {fprintf(probeLog,"PLUGIN MESSAGE: %s\n",text);fflush(probeLog);return 0;}
static void probe() {
 host->Register("-timer",(void*)probe);
 const char* resource=GetResourcePath();
 if(!resource || !strstr(resource,"/build/native-test"))return;
 std::string root=resource;
 FILE* log=fopen((root+"/probe.log").c_str(),"w");if(!log)return;
 auto say=[&](const char* text){fprintf(log,"%s\n",text);fflush(log);};
 if(CountTracks(nullptr)!=0) {say("REFUSED: test project not empty");fclose(log);return;}
 InsertTrackAtIndex(0,false);auto track=GetTrack(nullptr,0);auto item=CreateNewMIDIItemInProj(track,0,4,nullptr);
 std::ifstream file(root+"/fixture.item");std::string fixture((std::istreambuf_iterator<char>(file)),{});
 if(!fixture.empty()) {
   if(!SetItemStateChunk(item,fixture.c_str(),false)) {say("FAIL: fixture load");fclose(log);return;}
 } else {
   auto take=GetActiveTake(item);
   for(int i=0;i<4;++i)MIDI_InsertNote(take,false,false,100+i*960,960+i*960,0,60+i,100,nullptr);
 }
 auto take=GetActiveTake(item);auto before=readNotes(take);
 fprintf(log,"notes before: %zu\n",before.size());fflush(log);
 if(before.empty()){say("FAIL: empty fixture");fclose(log);return;}
 MIDI_SelectAll(take,false);bool selected=true;MIDI_SetNote(take,0,&selected,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr);
 probeLog=log;
 void* plugin=dlopen((root+"/UserPlugins/reaper_mpe_editor.dylib").c_str(),RTLD_NOW);
 auto dialog=(void**)dlsym(plugin,"ShowMessageBox");if(dialog)*dialog=(void*)probeMessage;
 auto get=(void**)dlsym(plugin,"MIDI_GetAllEvts");if(get){originalGet=(decltype(originalGet))*get;*get=(void*)probeGet;}
 auto set=(void**)dlsym(plugin,"MIDI_SetAllEvts");if(set){originalSet=(decltype(originalSet))*set;*set=(void*)probeSet;}
 Class cls=NSClassFromString(@"MPEPitchView");
 if(!cls){say("FAIL: production class absent");fclose(log);return;}
 NSView* overlay=[[cls alloc] initWithFrame:NSMakeRect(0,0,900,500)];
 auto assign=[&](const char* name,const void* value,size_t size){Ivar field=class_getInstanceVariable(cls,name);memcpy((char*)overlay+ivar_getOffset(field),value,size);};
 auto project=EnumProjects(-1,nullptr,0);int minusOne=-1;
 assign("take",&take,sizeof(take));assign("project",&project,sizeof(project));assign("selected",&minusOne,sizeof(minusOne));assign("handleIndex",&minusOne,sizeof(minusOne));
 if(![overlay refresh]){say("FAIL: model refresh");fclose(log);return;}
 say("production overlay attached");
 double totalMs=0,maxMs=0;
 for(int iteration=0;iteration<30;++iteration) {
   Ivar hash=class_getInstanceVariable(overlay.class,"dragHash");MIDI_GetHash(take,false,(char*)overlay+ivar_getOffset(hash),128);
   std::vector<mpe::Point> points;
   for(int i=0;i<=512;++i)points.push_back({double(i),100-20*std::sin(i*(iteration%2 ? 0.04 : 0.4))});
   // Include backward and vertical painting paths.
   points.push_back({350,70});points.push_back({350,50});points.push_back({512,80});points.push_back({600,64});
   auto bends=mpe::gesture(points,0,512,100,iteration%2,12);
   if(iteration%3==2) {
     [overlay handlePitchKey:'V' modifiers:0];auto n=readNotes(take).front();
     bends=[overlay drawnCurve:mpe::Note{0,n.channel,n.pitch,n.start,n.end,true,n.muted}];
   } else [overlay handlePitchKey:iteration%2 ? 'S' : 'F' modifiers:0];
   fprintf(log,"edit %d starting, samples=%zu\n",iteration,bends.size());fflush(log);
   auto begin=std::chrono::steady_clock::now();
   [overlay commitCurve:bends];
   double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();totalMs+=ms;maxMs=std::max(maxMs,ms);
   fprintf(log,"commit %.3f ms\n",ms);
   auto after=readNotes(take);
   if(after.size()!=before.size()) {say("FAIL: note count changed");fclose(log);return;}
   for(size_t i=0;i<before.size();++i) {
     const auto& a=before[i];const auto& b=after[i];
     if(a.start!=b.start || a.end!=b.end || a.pitch!=b.pitch || a.velocity!=b.velocity || a.muted!=b.muted || (i>0 && a.channel!=b.channel)) {say("FAIL: note attributes changed");fclose(log);return;}
   }
   say("notes verified");
 }
 fprintf(log,"commit average=%.3f ms max=%.3f ms\n",totalMs/30,maxMs);
 [overlay release];say("PASS: 30 production freehand/smooth/vibrato commits; all original notes preserved");fclose(log);
}
extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE,reaper_plugin_info_t* rec) {
 if(!rec)return 0;if(REAPERAPI_LoadAPI(rec->GetFunc))return 0;host=rec;host->Register("timer",(void*)probe);return 1;
}
