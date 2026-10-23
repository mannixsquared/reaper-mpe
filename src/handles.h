#pragma once
#include "curve.h"
namespace mpe {
// Reduce MIDI samples to editable anchors, retaining extrema and endpoints.
inline std::vector<Bend> handles(const std::vector<Bend>& samples,double tolerance=20,bool smooth=false) {
 if(samples.size()<2) return samples;
 std::vector<bool> keep(samples.size(),false);keep.front()=keep.back()=true;
 std::vector<std::pair<size_t,size_t>> stack{{0,samples.size()-1}};
 while(!stack.empty()) {
   auto [a,b]=stack.back();stack.pop_back();
   double linearError=0,smoothError=0;size_t linearIndex=a,smoothIndex=a;
   for(size_t i=a+1;i<b;++i) {
     double width=samples[b].fraction-samples[a].fraction;
     if(width<=0) continue;
     double t=(samples[i].fraction-samples[a].fraction)/width;
     double delta=samples[b].value-samples[a].value;
     double l=std::abs(samples[i].value-(samples[a].value+delta*t));
     double c=std::abs(samples[i].value-(samples[a].value+delta*t*t*(3-2*t)));
     if(l>linearError) {linearError=l;linearIndex=i;}
     if(c>smoothError) {smoothError=c;smoothIndex=i;}
   }
   double error=linearError;size_t index=linearIndex;
   if(smooth && smoothError<linearError) {error=smoothError;index=smoothIndex;}
   if(error<=tolerance) index=a;
   if(index!=a) { keep[index]=true;stack.push_back({a,index});stack.push_back({index,b}); }
 }
 std::vector<Bend> out;for(size_t i=0;i<samples.size();++i)if(keep[i])out.push_back(samples[i]);
 // A fixed edit budget prevents repeated smooth edits multiplying MIDI
 // samples/handles. The dense MIDI stream is separate from its control polygon.
 if(out.size()>64) {
   std::vector<Bend> bounded;
   for(size_t i=0;i<64;++i) bounded.push_back(out[i*(out.size()-1)/63]);
   return bounded;
 }
 return out;
}
inline void moveHandle(std::vector<Bend>& nodes,size_t index,double fraction,int value) {
 if(index>=nodes.size()) return;
 // Endpoints remain anchored to the note boundaries. Interior handles cannot
 // cross neighbours; pitch stays within the MIDI 14-bit range.
 if(index>0 && index+1<nodes.size()) {
   double lo=nodes[index-1].fraction,hi=nodes[index+1].fraction;
   double gap=std::min(0.0001,(hi-lo)/4);
   nodes[index].fraction=std::clamp(fraction,lo+gap,hi-gap);
 }
 nodes[index].value=std::clamp(value,0,16383);
}
inline std::vector<Bend> handleCurve(const std::vector<Bend>& nodes,bool smooth) {
 if(nodes.size()<2) return nodes;
 std::vector<double> slopes(nodes.size(),0);
 for(size_t i=1;i+1<nodes.size();++i) {
   double h0=nodes[i].fraction-nodes[i-1].fraction,h1=nodes[i+1].fraction-nodes[i].fraction;
   if(h0<=0 || h1<=0) continue;
   double a=(nodes[i].value-nodes[i-1].value)/h0,b=(nodes[i+1].value-nodes[i].value)/h1;
   if(a*b>0) { double w1=2*h1+h0,w2=h1+2*h0;slopes[i]=(w1+w2)/(w1/a+w2/b); }
 }
 std::vector<Bend> out;
 for(size_t i=0;i+1<nodes.size();++i) {
   double h=nodes[i+1].fraction-nodes[i].fraction;
   if(h<=0) continue;
   int steps=std::max(2,int(std::ceil(h*512)));
   for(int j=0;j<steps;++j) {
     double t=double(j)/steps,t2=t*t,t3=t2*t;
     double value=smooth ? (2*t3-3*t2+1)*nodes[i].value+(t3-2*t2+t)*h*slopes[i]+(-2*t3+3*t2)*nodes[i+1].value+(t3-t2)*h*slopes[i+1] : nodes[i].value+(nodes[i+1].value-nodes[i].value)*t;
     out.push_back({nodes[i].fraction+h*t,std::clamp(int(std::lround(value)),0,16383)});
   }
 }
 out.push_back(nodes.back());return out;
}
}
