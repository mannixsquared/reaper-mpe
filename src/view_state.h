#pragma once
#include <sstream>
#include <string>
#include <string_view>
#include <vector>
namespace mpe {
struct ViewState {
 double left=0, zoom=0, topPitch=0, rowHeight=0;
 int timebase=0, lanesHeight=0;
 bool beats() const { return timebase==0 || timebase==4; }
};
// CFGEDITVIEW is an undocumented REAPER item-chunk field, also used by
// js_Mouse editing scripts. Do not change it; parse the active take only.
// Search layout records directly instead of tokenising every MIDI event for
// each display frame. string_view also avoids copying the whole item chunk.
inline bool parseView(std::string_view chunk,int takeNumber,ViewState& view) {
 view=ViewState{};
 if(takeNumber<0) return false;
 auto nextTake=[&](size_t from) {
   size_t p=from;
   while((p=chunk.find("\nTAKE",p))!=std::string_view::npos) {
     size_t after=p+5;
     if(after==chunk.size() || chunk[after]==' ' || chunk[after]=='\n' || chunk[after]=='\r') return p;
     p=after;
   }
   return std::string_view::npos;
 };
 size_t start=0;
 for(int n=0;n<takeNumber;++n) { start=nextTake(start); if(start==std::string_view::npos) return false; ++start; }
 size_t end=nextTake(start);
 auto take=chunk.substr(start,end==std::string_view::npos ? chunk.size()-start : end-start);
 auto record=[&](std::string_view key,size_t from=0) {
   size_t pos=from;
   while((pos=take.find(key,pos))!=std::string_view::npos) {
     if(pos==0 || take[pos-1]=='\n') return pos;
     ++pos;
   }
   return std::string_view::npos;
 };
 auto line=[&](size_t pos) { size_t e=take.find('\n',pos); return std::string(take.substr(pos,e==std::string_view::npos ? take.size()-pos : e-pos)); };
 size_t v=record("CFGEDITVIEW "), e=record("CFGEDIT ");
 if(v==std::string_view::npos || e==std::string_view::npos) return false;
 std::string key; double top;
 std::istringstream geometry(line(v));
 if(!(geometry>>key>>view.left>>view.zoom>>top>>view.rowHeight)) return false;
 view.topPitch=127-top;
 std::istringstream edit(line(e)); edit>>key;
 double value;
 for(int i=1;i<=19;++i) { if(!(edit>>value)) return false; if(i==19) view.timebase=int(value); }
 size_t lane=record("VELLANE ");
 while(lane!=std::string_view::npos) {
   std::istringstream fields(line(lane)); int type,height;
   if(fields>>key>>type>>height) view.lanesHeight+=height;
   lane=record("VELLANE ",lane+1);
 }
 return view.zoom>0 && view.rowHeight>0;
}
}
