#import <Cocoa/Cocoa.h>
#include "reaper_plugin.h"
#define REAPERAPI_IMPLEMENT
#define REAPERAPI_MINIMAL
#define REAPERAPI_WANT_MIDIEditor_GetActive
#define REAPERAPI_WANT_MIDIEditor_GetTake
#define REAPERAPI_WANT_MIDI_EnumSelNotes
#define REAPERAPI_WANT_MIDI_GetNote
#define REAPERAPI_WANT_MIDI_CountEvts
#define REAPERAPI_WANT_MIDI_GetCC
#define REAPERAPI_WANT_MIDI_GetHash
#define REAPERAPI_WANT_MIDI_SetNote
#define REAPERAPI_WANT_MIDI_InsertCC
#define REAPERAPI_WANT_MIDI_DisableSort
#define REAPERAPI_WANT_MIDI_Sort
#define REAPERAPI_WANT_Undo_BeginBlock2
#define REAPERAPI_WANT_Undo_EndBlock2
#define REAPERAPI_WANT_ShowMessageBox
#define REAPERAPI_WANT_ValidatePtr2
#define REAPERAPI_WANT_UpdateArrange
#define REAPERAPI_WANT_GetProjectStateChangeCount
#define REAPERAPI_WANT_EnumProjects
#define REAPERAPI_WANT_GetItemStateChunk
#define REAPERAPI_WANT_GetMediaItemTake_Item
#define REAPERAPI_WANT_GetMediaItemTakeInfo_Value
#define REAPERAPI_WANT_MIDI_GetProjTimeFromPPQPos
#define REAPERAPI_WANT_MIDI_GetPPQPosFromProjTime
#define REAPERAPI_WANT_MIDI_DeleteCC
#define REAPERAPI_WANT_MIDI_GetAllEvts
#define REAPERAPI_WANT_MIDI_SetAllEvts
#define REAPERAPI_WANT_MIDI_GetCCShape
#define REAPERAPI_WANT_Undo_DoUndo2
#define REAPERAPI_WANT_Undo_DoRedo2
#define REAPERAPI_WANT_RefreshToolbar2
#include "reaper_plugin_functions.h"
#undef min
#undef max
#include "curve.h"
#include "handles.h"
#include "vibrato.h"
#include "midi_batch.h"
#include "performance.h"
#include <cstdio>
#include "view_state.h"
#include "keyboard_gate.h"
#include <cstring>
#include <chrono>
#include <iomanip>
#include <array>
#include <dispatch/dispatch.h>
static reaper_plugin_info_t* host;
static int command, midiCommand;
static gaccel_register_t action{};
static custom_action_register_t midiAction{32060,"MPE_DRAW_PITCH_TOGGLE_MIDI","MPE: Toggle per-note pitch editing",nullptr};
static HWND (*findChild)(HWND,int);
static void closeOverlay();
static void requestViewSync();
static bool syncQueued=false;
static mpe::KeyboardCapture nativeKeys;
static bool filterApplicationEvent(NSEvent* event);
static accelerator_register_t keyboardHook{};
static std::array<bool,256> heldKeys{};
static HWND keyTarget=nullptr;
static NSWindow* pitchKeyWindow=nil;
static void message(const char* text) { ShowMessageBox(text,"MPE pitch editor",0); }
static bool readPitchHash(MediaItem_Take* take,char* output,int size) {return mpe::measure("midi.hash",[&]{return MIDI_GetHash(take,false,output,size);});}
@interface MPEPitchView : NSView {
@public
 HWND editor;
 MediaItem_Take* take;
 ReaProject* project;
 std::vector<mpe::Note> notes;
 std::vector<mpe::PitchEvent> events;
 std::array<std::vector<mpe::PitchEvent>,16> audibleEvents,allEvents;
 NSTrackingArea* pitchTracking;
 NSTimer* viewTimer;
 id scrollMonitor;
 std::vector<mpe::Point> points;
 mpe::ViewState view;
 std::string geometryKey;
 std::vector<char> chunkBuffer,midiReadBuffer;
 int loadedRevision;
 int selected, handleIndex;
 bool vibratoTool;
 double vibratoDepth,vibratoRate,pressDepth,pressRate;
 std::vector<mpe::Bend> handleNodes,cachedHandles;
 int cachedHandleNote;
 bool cachedHandleSmooth;
 std::string cachedHandleHash;
 bool smooth, dragging, pendingHandleInsert, used[16];
 NSPoint press;
 NSSize oldSize;
 char hash[128],dragHash[128];
}
- (std::vector<mpe::Bend>)handlesFor:(const mpe::Note&)note;
- (void)reindexEvents;
- (bool)readMidi:(std::vector<char>&)output expectedNotes:(int)expected;
- (bool)refresh;
- (bool)refreshLayout;
- (void)startInput;
- (void)stopInput;
- (BOOL)handlePitchKey:(unsigned int)key modifiers:(NSEventModifierFlags)modifiers;
- (double)xFor:(double)ppq;
- (double)yFor:(int)pitch;
- (std::vector<mpe::Bend>)drawnCurve:(const mpe::Note&)note;
- (void)commitCurve:(const std::vector<mpe::Bend>&)bends;
@end
static MPEPitchView* overlay;
static int toggleState(int cmd) { return cmd==command || cmd==midiCommand ? (overlay ? 1 : 0) : -1; }
static NSView* asView(HWND handle) {
 id object=(id)handle;
 if([object isKindOfClass:NSWindow.class]) return [(NSWindow*)object contentView];
 return [object isKindOfClass:NSView.class] ? (NSView*)object : nil;
}
@implementation MPEPitchView
- (instancetype)initWithFrame:(NSRect)frame {
 self=[super initWithFrame:frame];
 if(self) {selected=-1;handleIndex=-1;cachedHandleNote=-1;vibratoDepth=35;vibratoRate=5.5;}
 return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)resetCursorRects {
 [super resetCursorRects];
 [self addCursorRect:[self noteArea] cursor:NSCursor.crosshairCursor];
 [self addCursorRect:NSMakeRect(6,2,vibratoTool ? 620 : 440,27) cursor:NSCursor.arrowCursor];
}
- (void)updateTrackingAreas {
 if(pitchTracking) { [self removeTrackingArea:pitchTracking]; [pitchTracking release]; }
 pitchTracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingCursorUpdate|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
 [self addTrackingArea:pitchTracking]; [super updateTrackingAreas];
}
- (void)updatePitchCursor {
 NSPoint p=[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
 [(NSPointInRect(p,[self noteArea]) ? NSCursor.crosshairCursor : NSCursor.arrowCursor) set];
}
- (void)cursorUpdate:(NSEvent*)event { [self updatePitchCursor]; }
- (void)mouseMoved:(NSEvent*)event { [self updatePitchCursor]; }
- (void)mouseEntered:(NSEvent*)event { [self updatePitchCursor]; }
- (void)mouseExited:(NSEvent*)event { [self.window invalidateCursorRectsForView:self.superview]; }
- (void)startInput {
 // Common modes include scrollbar/mouse tracking, where REAPER's ordinary
 // extension timer can pause. No delay-based polling gate is applied here.
 viewTimer=[[NSTimer timerWithTimeInterval:1.0/60 target:self selector:@selector(syncViewport:) userInfo:nil repeats:YES] retain];
 [[NSRunLoop mainRunLoop] addTimer:viewTimer forMode:NSRunLoopCommonModes];
 scrollMonitor=[[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^NSEvent*(NSEvent* event) {
   if(overlay && event.window==overlay.window) requestViewSync();
   return event; // Observe only; native scroll delivery remains intact.
 }] retain];
 [self.window invalidateCursorRectsForView:self];
}
- (void)stopInput {
 [viewTimer invalidate]; [viewTimer release]; viewTimer=nil;
 if(scrollMonitor) { [NSEvent removeMonitor:scrollMonitor]; [scrollMonitor release]; scrollMonitor=nil; }
 if(pitchTracking) { [self removeTrackingArea:pitchTracking]; [pitchTracking release]; pitchTracking=nil; }
 [self discardCursorRects];
}
- (void)syncViewport:(NSTimer*)timer {
 if(overlay!=self || !self.window.isVisible) return;
 if(!ValidatePtr2(project,take,"MediaItem_Take*") || EnumProjects(-1,nullptr,0)!=project) return;
 [self refreshLayout]; [self displayIfNeeded];
}

- (NSRect)noteArea { return NSMakeRect(0,62,self.bounds.size.width,std::max(0.0,self.bounds.size.height-62-view.lanesHeight-16)); }
- (NSView*)hitTest:(NSPoint)point {
 NSPoint local=[self convertPoint:point fromView:self.superview];
 if(NSPointInRect(local,NSMakeRect(6,2,vibratoTool ? 620 : 440,27)) || NSPointInRect(local,[self noteArea])) return self;
 return nil;
}
- (double)xFor:(double)ppq {
 double x=view.beats() ? (ppq-view.left)*view.zoom : (MIDI_GetProjTimeFromPPQPos(take,ppq)-MIDI_GetProjTimeFromPPQPos(take,view.left))*view.zoom;
 return x;
}
- (double)yFor:(int)pitch { return 62+(view.topPitch-pitch+0.5)*view.rowHeight; }
- (std::vector<mpe::Bend>)drawnCurve:(const mpe::Note&)note {
 std::vector<mpe::Point> timed;
 for(auto p:points) {
   double ppq=view.beats() ? view.left+p.x/view.zoom : MIDI_GetPPQPosFromProjTime(take,MIDI_GetProjTimeFromPPQPos(take,view.left)+p.x/view.zoom);
   timed.push_back({ppq,p.y});
 }
 if(vibratoTool) {
   double begin=MIDI_GetProjTimeFromPPQPos(take,note.start),end=MIDI_GetProjTimeFromPPQPos(take,note.end);
   auto generated=mpe::vibrato(end-begin,vibratoDepth,vibratoRate);
   const auto& baseline=note.muted ? allEvents[note.channel] : audibleEvents[note.channel];
   for(auto& b:generated) {
     double ppq=MIDI_GetPPQPosFromProjTime(take,begin+b.fraction*(end-begin));
     double value=mpe::channelValueAt(baseline,std::min(ppq,std::max(note.start,note.end-1)));
     b.value=std::clamp(int(std::lround(value+b.value-8192)),0,16383);
     b.fraction=std::clamp((ppq-note.start)/(note.end-note.start),0.0,1.0);
   }
   return generated;
 }
 return mpe::gesture(timed,note.start,note.end,[self yFor:note.pitch],smooth,view.rowHeight);
}
- (std::vector<mpe::Bend>)handlesFor:(const mpe::Note&)note {
 mpe::PerformanceSpan timing("curve.handles");
 if(handleIndex>=0 && !handleNodes.empty()) return handleNodes;
 if(cachedHandleNote==note.index && cachedHandleHash==hash && cachedHandleSmooth==smooth && !cachedHandles.empty()) return cachedHandles;
 const auto& data=note.muted ? allEvents[note.channel] : audibleEvents[note.channel];
 if(note.end<=note.start) return {};
 // Bounded sampling keeps handle extraction independent of accumulated MIDI
 // density. Cache this result; never simplify MIDI on every drag/paint frame.
 std::vector<mpe::Bend> samples;
 for(int i=0;i<=512;++i) {
   double f=i/512.0,t=note.start+f*(note.end-note.start);
   samples.push_back({f,int(std::lround(mpe::channelValueAt(data,std::min(t,std::max(note.start,note.end-1)))))});
 }
 cachedHandles=mpe::handles(samples,20,smooth);
 cachedHandleNote=note.index;cachedHandleHash=hash;cachedHandleSmooth=smooth;
 return cachedHandles;
}
- (mpe::Note*)selectedNote { for(auto& n:notes) if(n.index==selected) return &n; return nullptr; }
- (bool)refreshLayout {
 mpe::PerformanceSpan timing("layout.read");
 if(!points.empty() || handleIndex>=0) return true;
 if(!ValidatePtr2(project,take,"MediaItem_Take*")) return false;
 // A bounded chunk buffer prevents truncated or unbounded reads on large items.
 if(chunkBuffer.empty()) chunkBuffer.resize(16*1024*1024,0);
 if(!GetItemStateChunk(GetMediaItemTake_Item(take),chunkBuffer.data(),int(chunkBuffer.size()),false)) return false;
 mpe::ViewState next;
 if(!mpe::parseView(chunkBuffer.data(),int(GetMediaItemTakeInfo_Value(take,"IP_TAKENUMBER")),next)) return false;
 std::ostringstream key; key<<std::setprecision(17)<<next.left<<' '<<next.zoom<<' '<<next.topPitch<<' '<<next.rowHeight<<' '<<next.timebase<<' '<<next.lanesHeight;
 if(geometryKey!=key.str() || !NSEqualSizes(oldSize,self.bounds.size)) {
   dragging=false; pendingHandleInsert=false; handleIndex=-1; handleNodes.clear(); points.clear();
   geometryKey=key.str(); view=next; oldSize=self.bounds.size; [self setNeedsDisplay:YES];
   [self.window invalidateCursorRectsForView:self];
 }
 return true;
}
- (bool)refresh {
 mpe::PerformanceSpan timing("model.refresh");
 if(!ValidatePtr2(project,take,"MediaItem_Take*"))return false;
 if(!points.empty() || handleIndex>=0)return true;
 int revision=GetProjectStateChangeCount(project);
 if(!notes.empty() && revision==loadedRevision)return true;
 if(![self refreshLayout]) return false;
 char current[128]{};
 if(!readPitchHash(take,current,sizeof(current))) return false;
 if(strcmp(current,hash)) {
   dragging=false; pendingHandleInsert=false; handleIndex=-1; handleNodes.clear(); points.clear();
   notes.clear(); events.clear(); std::fill(used,used+16,false);
   int count=0,ccCount=0,textCount=0;
   MIDI_CountEvts(take,&count,&ccCount,&textCount);
   int firstSelected=-1;
   for(int i=0;i<count;++i) {
     mpe::Note n{}; int velocity; n.index=i;
     if(MIDI_GetNote(take,i,&n.selected,&n.muted,&n.start,&n.end,&n.channel,&n.pitch,&velocity)) {
       notes.push_back(n); used[n.channel]=true;
       if(n.selected && firstSelected<0) firstSelected=i;
     }
   }
   selected=firstSelected;
   for(int i=0;i<ccCount;++i) {
     bool sel,muted; double time; int type,ch,a,b;
     if(!MIDI_GetCC(take,i,&sel,&muted,&time,&type,&ch,&a,&b)) continue;
     used[ch]=true;
     if(type==0xE0) {
       int shape=0; double tension=0; MIDI_GetCCShape(take,i,&shape,&tension);
       events.push_back({i,ch,a+(b<<7),shape,time,tension,muted});
     }
   }
   std::stable_sort(events.begin(),events.end(),[](const auto& a,const auto& b){ return a.time<b.time; });
   [self reindexEvents];
   std::strncpy(hash,current,sizeof(hash)-1); [self setNeedsDisplay:YES];
 }
 loadedRevision=revision;
 return true;
}
- (void)reindexEvents {
 for(auto& channel:audibleEvents)channel.clear();
 for(auto& channel:allEvents)channel.clear();
 for(auto event:events) {allEvents[event.channel].push_back(event);if(!event.muted)audibleEvents[event.channel].push_back(event);}
}
- (bool)readMidi:(std::vector<char>&)output expectedNotes:(int)expected {
 mpe::PerformanceSpan timing("midi.readRaw");
 if(midiReadBuffer.empty())midiReadBuffer.resize(256*1024);
 for(int attempt=0;attempt<8;++attempt) {
   int capacity=int(midiReadBuffer.size()),bytes=capacity;
   bool ok=MIDI_GetAllEvts(take,midiReadBuffer.data(),&bytes);
   // Native REAPER can return true with size UNCHANGED and no data when the
   // supplied buffer is too small. Equality means grow, never accept/restore.
   if(ok && bytes>0 && bytes<capacity) {
     output.assign(midiReadBuffer.begin(),midiReadBuffer.begin()+bytes);
     return mpe::validRaw(output,expected);
   }
   size_t needed=bytes>capacity ? size_t(bytes)+1 : midiReadBuffer.size()*2;
   if(needed>32*1024*1024)return false;
   midiReadBuffer.resize(needed);
 }
 return false;
}
- (void)drawRect:(NSRect)dirty {
 mpe::PerformanceSpan timing("view.paint");
 // Viewport timers/scroll callbacks maintain geometry. Painting and mouse
 // gestures use memory only: never serialize the take in this path.
 [NSGraphicsContext saveGraphicsState]; NSRectClip([self noteArea]);
 for(const auto& n:notes) {
   double left=[self xFor:n.start],right=[self xFor:n.end],base=[self yFor:n.pitch];
   if(right<0 || left>self.bounds.size.width || base<62 || base>NSMaxY([self noteArea])) continue;
   bool active=n.index==selected;
   [[NSColor colorWithCalibratedWhite:1 alpha:active ? 0.5 : 0.18] setStroke];
   NSBezierPath* zero=[NSBezierPath bezierPath]; [zero moveToPoint:NSMakePoint(left,base)]; [zero lineToPoint:NSMakePoint(right,base)]; [zero stroke];
   std::vector<mpe::Bend> preview;
   if(active && dragging) preview=handleIndex>=0 ? mpe::handleCurve(handleNodes,smooth) : [self drawnCurve:n];
   NSBezierPath* path=[NSBezierPath bezierPath];
   auto add=[&](double x,double value,bool first) {
     NSPoint p=NSMakePoint(x,base-(value-8192)/8192.0*48*view.rowHeight);
     if(first) [path moveToPoint:p]; else [path lineToPoint:p];
   };
   if(!preview.empty()) {
     bool first=true; for(auto b:preview) { double ppq=n.start+b.fraction*(n.end-n.start); add([self xFor:ppq],b.value,first); first=false; }
   } else {
     double visibleLeft=std::max(0.0,left), visibleRight=std::min(self.bounds.size.width,right);
     int samples=std::clamp(int(visibleRight-visibleLeft),2,1600);
     for(int i=0;i<=samples;++i) {
       double x=visibleLeft+(visibleRight-visibleLeft)*i/samples;
       double ppq=view.beats() ? view.left+x/view.zoom : MIDI_GetPPQPosFromProjTime(take,MIDI_GetProjTimeFromPPQPos(take,view.left)+x/view.zoom);
       add(x,mpe::channelValueAt(n.muted ? allEvents[n.channel] : audibleEvents[n.channel],ppq),i==0);
     }
   }
   [[NSColor colorWithCalibratedWhite:0 alpha:n.muted ? 0.3 : 1.0] setStroke];
   path.lineWidth=1.5; [path stroke];
   if(active && !vibratoTool && (!dragging || handleIndex>=0)) for(auto node:[self handlesFor:n]) {
     double x=[self xFor:n.start+node.fraction*(n.end-n.start)];
     double y=base-(node.value-8192)/8192.0*48*view.rowHeight;
     NSBezierPath* handle=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-4,y-4,8,8)];
     [NSColor.whiteColor setFill];[handle fill];[NSColor.blackColor setStroke];handle.lineWidth=1.5;[handle stroke];
   }
 }
 [NSGraphicsContext restoreGraphicsState];
 [[NSColor colorWithCalibratedWhite:0.08 alpha:0.95] setFill]; NSRectFillUsingOperation(NSMakeRect(6,2,vibratoTool ? 620 : 440,27),NSCompositingOperationSourceOver);
 auto label=[&](NSString* text,double x,BOOL active) { [text drawAtPoint:NSMakePoint(x,7) withAttributes:@{NSForegroundColorAttributeName:active ? NSColor.systemOrangeColor : NSColor.whiteColor,NSFontAttributeName:[NSFont systemFontOfSize:12]}]; };
 label(@"Freehand [F]",14,!smooth && !vibratoTool); label(@"Smooth [S]",112,smooth && !vibratoTool); label(@"Flat [0]",208,NO); label(@"Vibrato [V]",274,vibratoTool); label(@"Off [Esc]",365,NO);
 if(vibratoTool)label([NSString stringWithFormat:@"%.1f Hz · %.0f cents",vibratoRate,vibratoDepth],445,NO);

}
- (BOOL)handlePitchKey:(unsigned int)key modifiers:(NSEventModifierFlags)modifiers {
 bool command=modifiers & NSEventModifierFlagCommand;
 if(modifiers & (NSEventModifierFlagOption|NSEventModifierFlagControl)) return NO;
 if(command) {
   if(key!='Z') return NO;
   dragging=false; pendingHandleInsert=false; handleIndex=-1; handleNodes.clear(); points.clear();
   if(modifiers & NSEventModifierFlagShift) Undo_DoRedo2(project); else Undo_DoUndo2(project);
   [self refresh]; return YES;
 }
 if(key==27) { closeOverlay(); return YES; }
 if(key=='F') {smooth=false;vibratoTool=false;}
 else if(key=='S') {smooth=true;vibratoTool=false;}
 else if(key=='V') vibratoTool=true;
 else if(key=='0') {vibratoTool=false; if([self selectedNote]) { readPitchHash(take,dragHash,sizeof(dragHash)); [self commitCurve:std::vector<mpe::Bend>{{0,8192},{1,8192}}]; } }
 else return NO;
 [self setNeedsDisplay:YES]; return YES;
}
- (void)keyDown:(NSEvent*)event {
 NSString* key=event.charactersIgnoringModifiers.uppercaseString;
 unsigned int code=event.keyCode==53 ? 27 : (key.length==1 ? [key characterAtIndex:0] : 0);
 if(![self handlePitchKey:code modifiers:event.modifierFlags]) [self.superview keyDown:event];
}
- (void)scrollWheel:(NSEvent*)event {
 dragging=false; pendingHandleInsert=false; handleIndex=-1; handleNodes.clear(); points.clear();
 [self.superview scrollWheel:event];
 [self refreshLayout]; [self displayIfNeeded]; requestViewSync();
}
- (void)mouseDown:(NSEvent*)event {
 mpe::PerformanceSpan timing("input.mouseDown");
 [self.window makeFirstResponder:self];
 if(!ValidatePtr2(project,take,"MediaItem_Take*")) {closeOverlay();return;}
 if(GetProjectStateChangeCount(project)!=loadedRevision && ![self refresh]) {closeOverlay();return;}
 NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
 if(p.y<30) {
   if(p.x<108) {smooth=false;vibratoTool=false;}
   else if(p.x<204) {smooth=true;vibratoTool=false;}
   else if(p.x<270) {vibratoTool=false; if([self selectedNote]) { readPitchHash(take,dragHash,sizeof(dragHash)); [self commitCurve:std::vector<mpe::Bend>{{0,8192},{1,8192}}]; } }
   else if(p.x<358) vibratoTool=true;
   else if(p.x<440) { closeOverlay(); return; }
   [self setNeedsDisplay:YES]; return;
 }
 pendingHandleInsert=false;handleIndex=-1; handleNodes.clear();
 auto current=[self selectedNote];
 if(current && !vibratoTool) {
   auto nodes=[self handlesFor:*current];
   if(event.modifierFlags & NSEventModifierFlagOption) {
     for(size_t i=0;i<nodes.size();++i) {
       double x=[self xFor:current->start+nodes[i].fraction*(current->end-current->start)];
       double y=[self yFor:current->pitch]-(nodes[i].value-8192)/8192.0*48*view.rowHeight;
       if(std::hypot(p.x-x,p.y-y)>7)continue;
       // Keep the two note-boundary anchors; interior deletion is one undoable edit.
       if(i==0 || i+1==nodes.size())return;
       nodes.erase(nodes.begin()+i);handleNodes=nodes;handleIndex=0;
       std::strncpy(dragHash,hash,sizeof(dragHash)-1);
       auto curve=mpe::handleCurve(nodes,smooth);[self commitCurve:curve];return;
     }
     return;
   }
   bool nearHandle=false;
   for(auto node:nodes) {
     double x=[self xFor:current->start+node.fraction*(current->end-current->start)];
     double y=[self yFor:current->pitch]-(node.value-8192)/8192.0*48*view.rowHeight;
     if(std::hypot(p.x-x,p.y-y)<=7)nearHandle=true;
   }
   if(event.clickCount>=2 && !nearHandle && nodes.size()<64 && p.x>[self xFor:current->start] && p.x<[self xFor:current->end]) {
     double ppq=view.beats() ? view.left+p.x/view.zoom : MIDI_GetPPQPosFromProjTime(take,MIDI_GetProjTimeFromPPQPos(take,view.left)+p.x/view.zoom);
     double fraction=(ppq-current->start)/(current->end-current->start);
     auto at=std::lower_bound(nodes.begin(),nodes.end(),fraction,[](auto n,double f){return n.fraction<f;});
     if((at!=nodes.end() && std::abs(at->fraction-fraction)<0.0001) || (at!=nodes.begin() && std::abs((at-1)->fraction-fraction)<0.0001))return;
     size_t index=size_t(at-nodes.begin());
     int value=int(std::lround(8192+([self yFor:current->pitch]-p.y)/view.rowHeight/48*8192));
     nodes.insert(at,{fraction,std::clamp(value,0,16383)});
     handleNodes=nodes;handleIndex=int(index);press=p;dragging=false;pendingHandleInsert=true;points.clear();
     cachedHandles=nodes;cachedHandleHash=hash;cachedHandleNote=current->index;cachedHandleSmooth=smooth;
     std::strncpy(dragHash,hash,sizeof(dragHash)-1);[self setNeedsDisplay:YES];return;
   }
   for(size_t i=0;i<nodes.size();++i) {
     double x=[self xFor:current->start+nodes[i].fraction*(current->end-current->start)];
     double y=[self yFor:current->pitch]-(nodes[i].value-8192)/8192.0*48*view.rowHeight;
     if(std::hypot(p.x-x,p.y-y)<=7) {
       handleNodes=nodes;handleIndex=int(i);press=p;dragging=false;points.clear();
       std::strncpy(dragHash,hash,sizeof(dragHash)-1);return;
     }
   }
 }
 if(event.modifierFlags & NSEventModifierFlagOption)return;
 int hit=-1; double distance=1e9;
 // Prefer the selected note when its curve crosses another note row.
 auto active=[self selectedNote];
 if(active && p.x>=[self xFor:active->start] && p.x<=[self xFor:active->end]) {
   double ppq=view.beats() ? view.left+p.x/view.zoom : MIDI_GetPPQPosFromProjTime(take,MIDI_GetProjTimeFromPPQPos(take,view.left)+p.x/view.zoom);
   double y=[self yFor:active->pitch]-(mpe::channelValueAt(active->muted ? allEvents[active->channel] : audibleEvents[active->channel],ppq)-8192)/8192.0*48*view.rowHeight;
   if(std::abs(p.y-y)<5) hit=active->index;
 }
 if(hit<0) for(auto n:notes) {
   double d=std::abs(p.y-[self yFor:n.pitch]);
   if(p.x>=[self xFor:n.start] && p.x<=[self xFor:n.end] && d<=std::max(4.0,view.rowHeight/2) && d<distance) { hit=n.index; distance=d; }
 }
 if(hit<0) return;
 selected=hit;
 for(auto& n:notes) { bool sel=n.index==hit; if(n.selected!=sel) MIDI_SetNote(take,n.index,&sel,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr); n.selected=sel; }
 readPitchHash(take,hash,sizeof(hash)); loadedRevision=GetProjectStateChangeCount(project); std::strncpy(dragHash,hash,sizeof(dragHash)-1);
 press=p;pressDepth=vibratoDepth;pressRate=vibratoRate;points={{p.x,p.y}};dragging=false; [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent*)event {
 if(points.empty() && handleIndex<0) return;
 NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
 if(std::hypot(p.x-press.x,p.y-press.y)<3 && !dragging) return;
 dragging=true;
 if(vibratoTool) {
   vibratoDepth=std::clamp(pressDepth+(press.y-p.y)/view.rowHeight*100,0.0,200.0);
   vibratoRate=std::clamp(pressRate+(p.x-press.x)/80,2.0,10.0);
   [self setNeedsDisplay:YES];return;
 }
 if(handleIndex>=0) {
   auto n=[self selectedNote];if(!n)return;
   double ppq=view.beats() ? view.left+p.x/view.zoom : MIDI_GetPPQPosFromProjTime(take,MIDI_GetProjTimeFromPPQPos(take,view.left)+p.x/view.zoom);
   int value=int(std::lround(8192+([self yFor:n->pitch]-p.y)/view.rowHeight/48*8192));
   mpe::moveHandle(handleNodes,size_t(handleIndex),(ppq-n->start)/(n->end-n->start),value);
   [self setNeedsDisplay:YES];return;
 }
 // Keep vertical/backward movement and clamp x to the note boundary. Beyond
 // the right edge, the endpoint continues following the mouse's pitch.
 auto n=[self selectedNote];if(!n)return;
 double x=std::clamp(p.x,[self xFor:n->start],[self xFor:n->end]);
 if(!points.empty() && x==points.back().x) points.back()={x,p.y};
 else points.push_back({x,p.y});
 if(points.size()>4096) {
   std::vector<mpe::Point> compact;
   for(size_t i=0;i+1<points.size();i+=2)compact.push_back(points[i]);
   compact.push_back(points.back());points.swap(compact);
 }
 [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent*)event {
 mpe::PerformanceSpan timing("input.mouseUp");
 if(!dragging && !pendingHandleInsert && !(vibratoTool && !points.empty())) { points.clear(); handleIndex=-1; handleNodes.clear(); return; }
 auto n=[self selectedNote];
 if(n) { auto bends=handleIndex>=0 ? mpe::handleCurve(handleNodes,smooth) : [self drawnCurve:*n]; if(!bends.empty()) [self commitCurve:bends]; }
 dragging=false; pendingHandleInsert=false; handleIndex=-1; handleNodes.clear(); points.clear(); [self setNeedsDisplay:YES];
}
- (void)commitCurve:(const std::vector<mpe::Bend>&)bends {
 mpe::PerformanceSpan timing("midi.commit");
 char current[128]{};
 if(!ValidatePtr2(project,take,"MediaItem_Take*") || !readPitchHash(take,current,sizeof(current)) || strcmp(current,dragHash)) { message("MIDI changed during the stroke. The stroke was discarded."); [self refresh]; return; }
 auto ptr=[self selectedNote]; if(!ptr || ptr->end<=ptr->start) return;
 auto n=*ptr;
 int target=mpe::allocate(n,notes,used);
 if(target<0) { message("No unused MPE member channel is available for this overlapping note."); return; }
 int expectedNotes=int(notes.size());
 std::vector<char> backup;
 if(![self readMidi:backup expectedNotes:expectedNotes]) {message("Could not read a complete, valid MIDI snapshot; no edit made.");return;}
 std::vector<mpe::Bend> committedHandles=handleIndex>=0 ? handleNodes : mpe::handles(bends,20,smooth);
 mpe::measure("midi.undoBegin",[&]{Undo_BeginBlock2(project);});MIDI_DisableSort(take);
 bool ok=true;std::vector<char> source=backup,output;
 if(target!=n.channel) {
   bool noSort=true;
   ok=MIDI_SetNote(take,n.index,nullptr,nullptr,nullptr,nullptr,&target,nullptr,nullptr,&noSort);
   if(ok)ok=[self readMidi:source expectedNotes:expectedNotes];
 }
 if(ok)ok=mpe::replacePitch(source,target,n.start,n.end,n.muted,bends,output) && mpe::validRaw(output,expectedNotes);
 if(ok)ok=mpe::measure("midi.writeRaw",[&]{return MIDI_SetAllEvts(take,output.data(),int(output.size()));});
 mpe::measure("midi.sort",[&]{MIDI_Sort(take);});
 int count=0,cc=0,text=0;
 if(ok)ok=MIDI_CountEvts(take,&count,&cc,&text) && count==expectedNotes;
 bool restored=false;
 if(!ok) {
   // Only a fully parsed, note-count-validated buffer may ever be restored.
   restored=MIDI_SetAllEvts(take,backup.data(),int(backup.size()));
   MIDI_CountEvts(take,&count,&cc,&text);restored=restored && count==expectedNotes;
 }
 mpe::measure("midi.undoFinalize",[&]{Undo_EndBlock2(project,ok ? "MPE: edit note pitch curve" : "MPE: rejected edit",UNDO_STATE_ITEMS);});
 if(ok) {
   // Patch the in-memory model rather than enumerating the full take on release.
   for(auto& note:notes)if(note.index==n.index)note.channel=target;
   used[target]=true;
   events.erase(std::remove_if(events.begin(),events.end(),[&](const auto& e){return e.channel==target && e.time>=n.start && e.time<n.end;}),events.end());
   for(auto b:mpe::ticks(bends,n.start,n.end))events.push_back({-1,target,b.value,0,b.fraction,0,n.muted});
   std::stable_sort(events.begin(),events.end(),[](auto a,auto b){return a.time<b.time;});
   [self reindexEvents];
   readPitchHash(take,hash,sizeof(hash));loadedRevision=GetProjectStateChangeCount(project);
   cachedHandles=std::move(committedHandles);cachedHandleNote=n.index;
   cachedHandleHash=hash;cachedHandleSmooth=smooth;
   dragging=false;pendingHandleInsert=false;handleIndex=-1;handleNodes.clear();points.clear();
   [self setNeedsDisplay:YES];[self displayIfNeeded];
 } else {
   dragging=false;pendingHandleInsert=false;handleIndex=-1;points.clear();hash[0]=0;loadedRevision=-1;[self refresh];
 }
 mpe::measure("view.updateArrange",[&]{UpdateArrange();});loadedRevision=GetProjectStateChangeCount(project);
 if(!ok)message(restored ? "The edit was rejected. The validated MIDI snapshot was restored and the note count verified." : "The edit failed and restoration could not be verified. Disable MPE editing and use Undo.");
}
@end
static void closeOverlay() {
 if(overlay) {
   MPEPitchView* old=overlay; overlay=nil;
   NSWindow* window=old.window; NSView* parent=old.superview;
   [old stopInput]; [old removeFromSuperview]; [window makeFirstResponder:parent];
   [window invalidateCursorRectsForView:parent]; [old release];
 }
 if(host && RefreshToolbar2) { RefreshToolbar2(0,command); if(midiCommand) RefreshToolbar2(32060,midiCommand); }
}
static void tick() {
 if(!overlay) return;
 if(EnumProjects(-1,nullptr,0)!=overlay->project || MIDIEditor_GetActive()!=overlay->editor || !ValidatePtr2(overlay->project,overlay->take,"MediaItem_Take*") || MIDIEditor_GetTake(overlay->editor)!=overlay->take || !overlay.window.isVisible) { closeOverlay(); return; }
 static auto last=std::chrono::steady_clock::now(); auto now=std::chrono::steady_clock::now();
 if(now-last<std::chrono::milliseconds(100)) return; last=now;
 if(![overlay refresh]) closeOverlay();
}
static void requestViewSync() {
 if(syncQueued) return;
 syncQueued=true;
 dispatch_async(dispatch_get_main_queue(),^{
   syncQueued=false;
   if(overlay && overlay.window.isVisible) {
     // Runs after native scroll dispatch; coalesces trackpad bursts.
     [overlay refreshLayout]; [overlay displayIfNeeded];
   }
 });
}
static bool nativePitchAction(unsigned int key,NSEventModifierFlags modifiers) {
 return overlay && [overlay handlePitchKey:key modifiers:modifiers];
}
static bool filterApplicationEvent(NSEvent* event) {
 NSWindow* window=event.window ?: NSApp.keyWindow;
 bool editing=overlay && window && window==overlay.window && !NSApp.modalWindow && !window.attachedSheet;
 NSResponder* responder=window.firstResponder;
 bool text=[responder isKindOfClass:NSTextView.class] || [responder isKindOfClass:NSTextField.class];
 return nativeKeys.consume(event,editing,text,nativePitchAction);
}
static int translatePitchKey(MSG* msg,accelerator_register_t*) {
 if(!msg || (msg->message!=WM_KEYDOWN && msg->message!=WM_KEYUP)) return 0;
 unsigned int key=(unsigned int)msg->wParam;
 if(key>='a' && key<='z') key-=('a'-'A');
 if(key>=heldKeys.size()) return 0;
 NSView* target=asView(msg->hwnd);
 NSWindow* window=target.window;
 bool sameTarget=msg->hwnd==keyTarget || (window && window==pitchKeyWindow);
 // Keep consuming release and auto-repeat even after Escape removes the view.
 NSEvent* nativeEvent=NSApp.currentEvent;
 bool repeat=nativeEvent.type==NSEventTypeKeyDown ? nativeEvent.isARepeat : ((msg->lParam & (LPARAM(1)<<30))!=0);
 if(heldKeys[key] && sameTarget) {
   if(msg->message==WM_KEYUP) { heldKeys[key]=false; return 1; }
   if(repeat) return 1;
   // Some REAPER accelerator paths do not deliver key-up. A fresh press
   // must still work, or S/F/Escape would be swallowed on the next use.
   heldKeys[key]=false;
 }
 if(msg->message==WM_KEYUP || !overlay) return 0;
 bool editingWindow=msg->hwnd==overlay->editor || (window && window==overlay.window);
 if(!editingWindow) return 0;
 NSResponder* responder=overlay.window.firstResponder;
 if([responder isKindOfClass:NSTextView.class] || [responder isKindOfClass:NSTextField.class]) return 0;
 NSEventModifierFlags modifiers=NSApp.currentEvent.modifierFlags;
 // Save the target before the handler can remove the overlay on Escape.
 HWND before=msg->hwnd; NSWindow* beforeWindow=window;
 if(![overlay handlePitchKey:key modifiers:modifiers]) return 0;
 heldKeys[key]=true; keyTarget=before; pitchKeyWindow=beforeWindow;
 return 1; // Suppress native shortcut/action processing (including note slicing).
}
static bool onAction(KbdSectionInfo*,int cmd,int,int,int,HWND) {
 if(cmd!=command && cmd!=midiCommand) return false;
 if(overlay) { closeOverlay(); return true; }
 HWND editor=MIDIEditor_GetActive(); MediaItem_Take* take=editor ? MIDIEditor_GetTake(editor) : nullptr;
 if(!take) { message("Open the built-in MIDI editor, then enable MPE pitch editing."); return true; }
 if(NSApp && !mpe::applicationGate::install(object_getClass(NSApp),filterApplicationEvent)) {
   message("Could not install native keyboard capture. MPE editing was not enabled."); return true;
 }
 // Child 1001 is the piano-roll drawing surface, excluding editor toolbars.
 if(!findChild) findChild=(HWND(*)(HWND,int))host->GetFunc("JS_Window_FindChildByID");
 NSView* parent=findChild ? asView(findChild(editor,1001)) : nil;
 if(!parent) { message("This build needs js_ReaScriptAPI to find the native MIDI piano roll. Install/enable it and restart REAPER."); return true; }
 overlay=[[MPEPitchView alloc] initWithFrame:parent.bounds];
 overlay->editor=editor; overlay->take=take; overlay->project=EnumProjects(-1,nullptr,0); overlay->selected=-1; overlay->handleIndex=-1;overlay->vibratoDepth=35;overlay->vibratoRate=5.5;
 overlay.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
 if(![overlay refresh]) { closeOverlay(); message("Could not read this MIDI editor's layout. Standard piano-roll mode is required."); return true; }
 [parent addSubview:overlay positioned:NSWindowAbove relativeTo:nil]; [parent.window makeFirstResponder:overlay];
 [overlay startInput];
 RefreshToolbar2(0,command); if(midiCommand) RefreshToolbar2(32060,midiCommand);
 return true;
}
extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE,reaper_plugin_info_t* rec) {
 if(!rec) {
   closeOverlay(); mpe::applicationGate::uninstall(); if(host) { host->Register("-accelerator",&keyboardHook); heldKeys.fill(false); host->Register("-timer",(void*)tick); host->Register("-hookcommand2",(void*)onAction); host->Register("-toggleaction",(void*)toggleState); host->Register("-gaccel",&action); if(midiCommand) host->Register("-custom_action",&midiAction); } host=nullptr; return 0;
 }
 if(rec->caller_version!=REAPER_PLUGIN_VERSION || REAPERAPI_LoadAPI(rec->GetFunc)) return 0;
 host=rec;
 // Preserve the original action ID, so existing shortcuts continue to work.
 command=host->Register("command_id",(void*)"MPE_DRAW_ONE_NOTE"); if(!command) return 0;
 action.accel.cmd=command; action.desc="MPE: Toggle per-note pitch editing";
 host->Register("gaccel",&action); midiCommand=host->Register("custom_action",&midiAction);
 keyboardHook={translatePitchKey,true,nullptr}; host->Register("accelerator",&keyboardHook);
 host->Register("hookcommand2",(void*)onAction); host->Register("toggleaction",(void*)toggleState); host->Register("timer",(void*)tick);
 return 1;
}
