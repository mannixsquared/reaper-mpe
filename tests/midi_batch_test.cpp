#include "midi_batch.h"
#include <cassert>
#include <iostream>
static std::vector<char> encode(std::vector<mpe::RawEvent> events) {
 std::vector<char> raw;int64_t time=0;
 for(auto e:events) {
   int32_t d=int32_t(e.time-time),n=int32_t(e.message.size());size_t p=raw.size();raw.resize(p+9+n);
   memcpy(raw.data()+p,&d,4);raw[p+4]=e.flags;memcpy(raw.data()+p+5,&n,4);memcpy(raw.data()+p+9,e.message.data(),n);time=e.time;
 }
 return raw;
}
static std::vector<mpe::RawEvent> decode(const std::vector<char>& raw) {
 std::vector<mpe::RawEvent> events;size_t p=0;int64_t time=0;
 while(p<raw.size()) {int32_t d,n;memcpy(&d,raw.data()+p,4);memcpy(&n,raw.data()+p+5,4);time+=d;events.push_back({time,(unsigned char)raw[p+4],std::string(raw.data()+p+9,n)});p+=9+n;}return events;
}
int main() {
 std::vector<mpe::RawEvent> originals{{0,1,{char(0x91),60,100}},{20,0x51,{char(0xe1),1,65}},{20,0,std::string("\xff\x0f" "CCBZ abcde",12)},{30,2,{char(0xb1),74,90}},{40,1,{char(0xe2),2,66}},{100,1,{char(0x81),60,0}},{100,0,""}};
 auto source=encode(originals);std::vector<char> result;
 assert(mpe::validRaw(source,1));
 assert(!mpe::validRaw(std::vector<char>(262144,0),1));
 assert(!mpe::validRaw(source,2));
 assert(mpe::replacePitch(source,1,0,100,false,{{0,8192},{1,8704}},result));
 auto events=decode(result);int bends=0;bool controller=false,otherPitch=false,off=false,terminator=false;
 for(auto e:events) {
   if(e.message.size()==3 && (unsigned char)e.message[0]==0xe1) {++bends;assert(e.flags==0);assert(e.time==0 || e.time==99);}
   if(e.message==originals[3].message) {controller=true;assert(e.flags==2 && e.time==30);}
   if(e.message==originals[4].message) {otherPitch=true;assert(e.flags==1 && e.time==40);}
   if(e.message==originals[5].message) {off=true;assert(e.time==100 && e.flags==1);}
   if(e.message.empty()) {terminator=true;assert(e.time==100);}
   assert(e.message.find("CCBZ")==std::string::npos);
 }
 assert(bends==2 && controller && otherPitch && off && terminator);
 assert((unsigned char)events.front().message[0]==0xe1); // Initial bend precedes note-on.
 assert(!mpe::replacePitch({'x'},1,0,100,false,{{0,8192}},result));
 // Bulk transformation remains bounded for a dense existing take.
 std::vector<mpe::RawEvent> dense;
 for(int i=0;i<50000;++i)dense.push_back({i,0,{char(0xe1),char(i&127),char((i>>7)&127)}});
 source=encode(dense);assert(mpe::replacePitch(source,1,0,50000,false,{{0,8192},{1,8704}},result));assert(decode(result).size()==2);
 std::cout<<"Bulk MIDI replacement: unrelated data/flags, note ordering, Bezier cleanup, malformed data and 50,000-event take passed.\n";
}
