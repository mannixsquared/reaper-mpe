#pragma once
#include <algorithm>
#include <cmath>
#include <vector>
namespace mpe {
struct Point { double x, y; };
struct Bend { double fraction; int value; };
inline std::vector<Bend> curve(const std::vector<Point>& points, double left, double right, double baseline, double pixelsPerSemitone=12, double range=48) {
  std::vector<Bend> out;
  if (right <= left || pixelsPerSemitone <= 0 || range <= 0) return out;
  double previousFraction=0; bool havePrevious=false;
  for (auto p : points) {
    double f=std::clamp((p.x-left)/(right-left),0.0,1.0);
    int value=std::clamp(int(std::lround(8192+(baseline-p.y)/pixelsPerSemitone/range*8192)),0,16383);
    // Treat the stroke as an editable time/value function. Backtracking paints
    // over the traversed interval; vertical movement replaces the same time.
    if(havePrevious) {
      double lo=std::min(previousFraction,f),hi=std::max(previousFraction,f);
      auto first=std::upper_bound(out.begin(),out.end(),lo,[](double t,const Bend& a){return t<a.fraction;});
      auto last=std::lower_bound(out.begin(),out.end(),hi,[](const Bend& a,double t){return a.fraction<t;});
      if(first<last) out.erase(first,last);
    }
    previousFraction=f;havePrevious=true;
    auto at=std::lower_bound(out.begin(),out.end(),f,[](const Bend& a,double t){return a.fraction<t;});
    if(at!=out.end() && at->fraction==f) at->value=value;
    else out.insert(at,{f,value});
  }
  return out;
}
// A smooth gesture is an ease-in/ease-out cubic between the press and release.
// Both tools extend the first/last drawn value to the note boundaries.
inline std::vector<Bend> gesture(const std::vector<Point>& points, double left, double right, double baseline, bool smooth, double pixelsPerSemitone=12) {
  auto out=curve(points,left,right,baseline,pixelsPerSemitone);
  if(out.empty()) return {};
  if(out.size()==1) return {{0,out.front().value},{1,out.front().value}};
  if(smooth) {
    auto endpoints=curve({points.front(),points.back()},left,right,baseline,pixelsPerSemitone);
    if(endpoints.size()<2) return {{0,endpoints.front().value},{1,endpoints.front().value}};
    Bend a=endpoints.front(), b=endpoints.back(); out.clear();
    for(int i=0;i<=96;++i) {
      double t=i/96.0, ease=t*t*(3-2*t);
      out.push_back({a.fraction+(b.fraction-a.fraction)*t,int(std::lround(a.value+(b.value-a.value)*ease))});
    }
  }
  if(out.front().fraction>0) out.insert(out.begin(),{0,out.front().value});
  if(out.back().fraction<1) out.push_back({1,out.back().value});
  return out;
}
// Native MIDI timestamps are integral ticks. Coalesce samples landing on the
// same tick and keep the last event strictly before note-off, so redraws replace
// the complete old curve and never leave a bend at a neighbouring note boundary.
inline std::vector<Bend> ticks(const std::vector<Bend>& bends,double start,double end) {
 std::vector<Bend> out;
 if(end<=start) return out;
 double last=std::max(start,std::ceil(end)-1),bestDistance=0;
 for(auto b:bends) {
   double raw=start+b.fraction*(end-start);
   double time=std::clamp(std::round(raw),start,last);
   double distance=std::abs(raw-time);
   if(!out.empty() && out.back().fraction==time) {
     // Keep an exact control-point sample when oversampling shares its tick.
     // The note endpoint always wins on the final valid MIDI tick.
     if(b.fraction==1 || distance<=bestDistance) {out.back().value=b.value;bestDistance=distance;}
   } else {out.push_back({time,b.value});bestDistance=distance;}
 }
 return out;
}
struct Note { int index, channel, pitch; double start,end; bool selected,muted; };
struct PitchEvent { int index,channel,value,shape; double time,tension; bool muted; };
inline bool overlaps(const Note& a,const Note& b) { return a.start<b.end && b.start<a.end; }
inline bool independent(int channel,const Note& note,const std::vector<Note>& notes) {
  for(auto n:notes) if(n.index!=note.index && n.channel==channel && overlaps(n,note)) return false;
  return true;
}
// Reuse the note's existing member channel if independent. Otherwise prefer a
// completely unused member channel. Never steal a channel from another voice.
inline int allocate(const Note& note,const std::vector<Note>& notes,const bool used[16]) {
  if(note.channel>0 && independent(note.channel,note,notes)) return note.channel;
  for(int c=1;c<16;++c) if(!used[c]) return c;
  return -1;
}
inline double shaped(double t,int shape,double tension=0) {
  t=std::clamp(t,0.0,1.0);
  switch(shape) {
    case 0: return t>=1 ? 1 : 0;
    case 2: return (1-std::cos(t*3.141592653589793))/2;
    case 3: return 1-std::pow(1-t,3);
    case 4: return t*t*t;
    case 5: return std::clamp(t+tension*t*(1-t),0.0,1.0); // approximate external Bezier tension
    default: return t;
  }
}
inline double valueAt(const std::vector<PitchEvent>& events,int channel,double time,bool includeMuted=false) {
  const PitchEvent* previous=nullptr;
  for(const auto& e:events) {
    if(e.channel!=channel || (e.muted && !includeMuted)) continue;
    if(e.time>time) {
      if(!previous) return 8192;
      double f=(time-previous->time)/(e.time-previous->time);
      return previous->value+(e.value-previous->value)*shaped(f,previous->shape,previous->tension);
    }
    previous=&e;
  }
  return previous ? previous->value : 8192;
}
// The renderer pre-filters each channel once when MIDI changes. Each pixel
// lookup is logarithmic instead of scanning the complete take's event stream.
inline double channelValueAt(const std::vector<PitchEvent>& events,double time) {
 auto next=std::upper_bound(events.begin(),events.end(),time,[](double t,const PitchEvent& e){ return t<e.time; });
 if(next==events.begin()) return 8192;
 const auto& previous=*(next-1);
 if(next==events.end()) return previous.value;
 double f=(time-previous.time)/(next->time-previous.time);
 return previous.value+(next->value-previous.value)*shaped(f,previous.shape,previous.tension);
}

}
