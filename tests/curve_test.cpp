#include "curve.h"
#include "handles.h"
#include "view_state.h"
#include <cassert>
#include <iostream>
int main() {
 auto c=mpe::curve({{10,100},{60,76},{110,124}},10,110,100);
 assert(c.size()==3 && c[0].value==8192 && c[1].fraction==0.5);
 assert(c[1].value==8533 && c[2].value==7851);
 auto clipped=mpe::curve({{-10,10000},{200,-10000}},0,100,0);
 assert(clipped[0].fraction==0 && clipped[0].value==0);
 assert(clipped[1].fraction==1 && clipped[1].value==16383);
 assert(mpe::curve({},1,1,0).empty());
 auto reverse=mpe::curve({{20,0},{10,0},{30,0}},0,100,0);
 assert(reverse.size()==2);
 // Smooth mode is monotonic, starts/ends exactly at the drawn pitch, and
 // approaches both endpoints with near-zero slope rather than overshooting.
 auto smooth=mpe::gesture({{20,0},{40,900},{80,-48}},0,100,0,true);
 assert(smooth.front().fraction==0 && smooth.back().fraction==1);
 assert(smooth.front().value==8192 && smooth.back().value==8875);
 for(size_t i=1;i<smooth.size();++i) assert(smooth[i].value>=smooth[i-1].value);
 assert(smooth[2].value-smooth[1].value<3);
 auto free=mpe::gesture({{20,0},{40,24},{80,-48}},0,100,0,false);
 assert(free.size()==5 && free[2].value<8192);
 auto shortCurve=mpe::ticks({{0,8192},{0.1,8200},{0.9,8300},{1,8400}},0,2);
 assert(shortCurve.size()==2 && shortCurve[0].fraction==0 && shortCurve[1].fraction==1 && shortCurve[1].value==8400);
 assert(mpe::ticks({{0,0},{1,16383}},10,10).empty());
 // A gesture landing three note rows away must always produce exactly
 // +/-3 semitones at the synth's +/-48 range, independent of vertical zoom.
 for(double rowHeight:{6.0,12.0,24.0,32.0,48.0}) {
   for(int direction:{-1,1}) for(bool smoothTool:{false,true}) {
     auto joined=mpe::gesture({{0,200},{100,200-direction*3*rowHeight}},0,100,200,smoothTool,rowHeight);
     assert(joined.back().value==8192+direction*512);
     double drawnRows=(joined.back().value-8192)/8192.0*48;
     assert(drawnRows==direction*3);
   }
 }
 // Flat curves have an interior handle, allowing an arch without redrawing.
 auto nodes=mpe::handles({{0,8192},{0.25,8192},{0.5,8192},{1,8192}});
 assert(nodes.size()==2);
 nodes.insert(nodes.begin()+1,{0.5,8192});
 mpe::moveHandle(nodes,1,0.7,8704);
 for(bool smoothHandles:{false,true}) {
   auto arch=mpe::handleCurve(nodes,smoothHandles);
   assert(arch.front().value==8192 && arch.back().value==8192);
   bool foundPeak=false;
   for(auto b:arch) { assert(b.value>=8192 && b.value<=8704); if(b.fraction==0.7 && b.value==8704)foundPeak=true; }
   assert(foundPeak);
 }
 mpe::moveHandle(nodes,0,0.2,-100);assert(nodes.front().fraction==0 && nodes.front().value==0);
 mpe::moveHandle(nodes,2,0.4,20000);assert(nodes.back().fraction==1 && nodes.back().value==16383);
 mpe::moveHandle(nodes,1,2,8000);assert(nodes[1].fraction<1 && nodes[1].fraction>0);
 // Painting back over time replaces that section; vertical strokes and
 // continued vertical movement past note-off always use the newest value.
 auto back=mpe::gesture({{0,100},{50,90},{90,80},{40,64}},0,100,100,false,12);
 bool overwritten=false;for(auto b:back)if(b.fraction==0.4 && b.value==8704)overwritten=true;
 assert(overwritten);
 for(bool tool:{false,true}) {
   auto vertical=mpe::gesture({{30,100},{30,64}},0,100,100,tool,12);
   assert(vertical.front().value==8704 && vertical.back().value==8704);
   auto edge=mpe::gesture({{0,100},{110,80},{140,64}},0,100,100,tool,12);
   assert(edge.back().fraction==1 && edge.back().value==8704);
 }
 // A single eased segment needs just its two endpoints, not dozens of
 // polyline knots. Repeated complex edits have a fixed sampling budget.
 auto simple=mpe::gesture({{0,100},{100,64}},0,100,100,true,12);
 assert(mpe::handles(simple,20,true).size()==2);
 assert(mpe::handles({{0,8192},{0.25,8320},{0.5,8448},{1,8704}},20,true).size()==2);
 std::vector<mpe::Bend> complex;
 for(int i=0;i<=512;++i)complex.push_back({i/512.0,int(8192+1000*std::sin(i*0.4))});
 for(int i=0;i<30;++i) {
   auto controls=mpe::handles(complex,20,true);assert(controls.size()<=64);
   mpe::moveHandle(controls,controls.size()/2,0.5,9000);
   complex=mpe::handleCurve(controls,true);assert(complex.size()<=600);
 }
 // Independent MPE notes stay on their channel on repeat edits, including
 // adjacent notes sharing a member channel. Overlaps require a fresh channel.
 mpe::Note a{0,1,60,0,100,true,false}, b{1,1,64,50,150,false,false}, d{2,1,67,100,200,false,false};
 bool used[16]{}; used[1]=true;
 assert(mpe::allocate(a,{a,d},used)==1);
 assert(mpe::allocate(a,{a,b},used)==2);
 std::fill(used,used+16,true);
 assert(mpe::allocate(a,{a,b},used)==-1);
 mpe::Note ordinary{3,0,72,0,100,false,false}; used[7]=false;
 assert(mpe::allocate(ordinary,{ordinary},used)==7);
 // Blank notes render centred. Read existing bend data by channel, with
 // held/square and linear shapes and muted data excluded from playback.
 std::vector<mpe::PitchEvent> events{{0,1,8192,1,10,0,false},{1,1,9000,0,20,0,false},{2,2,10000,0,20,0,false},{3,1,0,0,30,0,true}};
 assert(mpe::valueAt({},1,50)==8192);
 assert(mpe::valueAt(events,1,0)==8192);
 assert(mpe::valueAt(events,1,15)==8596);
 assert(mpe::valueAt(events,1,25)==9000);
 assert(mpe::valueAt(events,1,40)==9000);
 assert(mpe::valueAt(events,1,40,true)==0);
 assert(mpe::valueAt(events,2,25)==10000);
 std::vector<mpe::PitchEvent> channel;
 for(auto e:events) if(e.channel==1 && !e.muted) channel.push_back(e);
 for(double t=-10;t<=60;t+=0.25) assert(mpe::channelValueAt(channel,t)==mpe::valueAt(events,1,t));
 assert(mpe::channelValueAt({},0)==8192);
 // Read only the active take's layout; ignore other takes' CC lane heights.
 const std::string chunk="<ITEM\nCFGEDITVIEW 10 0.5 60 12\nCFGEDIT 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0\nVELLANE 128 80 0\nTAKE SEL\nCFGEDITVIEW 20 2 50 16\nCFGEDIT 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 1\nVELLANE 1 90 0\n>\n";
 mpe::ViewState view;
 assert(mpe::parseView(chunk,0,view) && view.left==10 && view.topPitch==67 && view.lanesHeight==80 && view.beats());
 assert(mpe::parseView(chunk,1,view) && view.left==20 && view.rowHeight==16 && view.lanesHeight==90 && !view.beats());
 assert(!mpe::parseView("CFGEDITVIEW garbage",0,view));
 assert(!mpe::parseView(chunk,2,view));
 std::cout<<"Pitch mapping, curve tools, channel allocation, bend rendering and multi-take layout tests passed.\n";
}
