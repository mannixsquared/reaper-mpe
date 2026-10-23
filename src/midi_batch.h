#pragma once
#include "curve.h"
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
namespace mpe {
struct RawEvent { int64_t time; unsigned char flags; std::string message; bool added=false; };
// Validate the complete native binary stream before it can be a write/rollback
// source. In particular a full untouched zero buffer is not a MIDI backup.
inline bool validRaw(const std::vector<char>& source,int expectedNotes=-1) {
 if(source.empty())return false;
 size_t pos=0;int noteOns=0;
 while(pos<source.size()) {
   if(source.size()-pos<9)return false;
   int32_t length;std::memcpy(&length,source.data()+pos+5,4);pos+=9;
   if(length<0 || size_t(length)>source.size()-pos)return false;
   if(length>=3 && ((unsigned char)source[pos]&0xf0)==0x90 && (unsigned char)source[pos+2]>0)++noteOns;
   pos+=size_t(length);
 }
 return expectedNotes<0 || noteOns==expectedNotes;
}
// One pass over the raw event stream replaces a curve. Preserve unrelated
// event bytes/flags and remove a Bezier attachment only with its deleted bend.
inline bool replacePitch(const std::vector<char>& source,int channel,double start,double end,bool muted,const std::vector<Bend>& bends,std::vector<char>& result) {
 std::vector<RawEvent> events;size_t pos=0;int64_t time=0;bool removed=false;
 while(pos<source.size()) {
   if(source.size()-pos<9)return false;
   int32_t delta,length;std::memcpy(&delta,source.data()+pos,4);unsigned char flags=source[pos+4];std::memcpy(&length,source.data()+pos+5,4);pos+=9;
   if(length<0 || size_t(length)>source.size()-pos)return false;
   time+=delta;std::string message(source.data()+pos,size_t(length));pos+=size_t(length);
   bool attachment=message.size()>=7 && (unsigned char)message[0]==0xff && (unsigned char)message[1]==0x0f && message.compare(2,5,"CCBZ ")==0;
   if(attachment && removed)continue;
   bool pitch=message.size()==3 && ((unsigned char)message[0]&0xf0)==0xe0 && ((unsigned char)message[0]&15)==channel;
   removed=pitch && time>=start && time<end;
   if(!removed)events.push_back({time,flags,std::move(message),false});
 }
 for(auto bend:ticks(bends,start,end)) {
   std::string msg{char(0xe0|channel),char(bend.value&127),char((bend.value>>7)&127)};
   events.push_back({int64_t(bend.fraction),static_cast<unsigned char>(muted ? 2 : 0),std::move(msg),true});
 }
 std::stable_sort(events.begin(),events.end(),[](const RawEvent& a,const RawEvent& b){return a.time!=b.time ? a.time<b.time : a.added && !b.added;});
 result.clear();result.reserve(source.size()+bends.size()*12);int64_t previous=0;
 for(const auto& e:events) {
   int64_t gap=e.time-previous;
   if(gap<std::numeric_limits<int32_t>::min() || gap>std::numeric_limits<int32_t>::max())return false;
   int32_t delta=int32_t(gap),length=int32_t(e.message.size());
   size_t offset=result.size();result.resize(offset+9+e.message.size());
   std::memcpy(result.data()+offset,&delta,4);result[offset+4]=char(e.flags);std::memcpy(result.data()+offset+5,&length,4);
   std::memcpy(result.data()+offset+9,e.message.data(),e.message.size());previous=e.time;
 }
 return true;
}
}
