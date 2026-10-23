#pragma once
#include "curve.h"
namespace mpe {
// Depth is peak cents; rate is cycles/second, independent of tempo and zoom.
// Deterministic variations keep preview, commit and undo reproducible.
inline std::vector<Bend> vibrato(double duration,double depthCents=35,double rateHz=5.5) {
 if(duration<=0 || !std::isfinite(duration))return {};
 depthCents=std::clamp(depthCents,0.0,200.0);rateHz=std::clamp(rateHz,2.0,10.0);
 int samples=std::clamp(int(std::ceil(std::min(duration*rateHz*32,4096.0))),64,4096);
 std::vector<Bend> result;result.reserve(samples+1);
 const double pi=3.141592653589793;
 auto ease=[](double t){t=std::clamp(t,0.0,1.0);return t*t*(3-2*t);};
 double delay=std::min(0.12,duration*0.15),fade=std::min(0.25,duration*0.35),release=std::min(0.08,duration*0.15);
 for(int i=0;i<=samples;++i) {
   double fraction=double(i)/samples,t=fraction*duration;
   double age=std::max(0.0,t-delay);
   double envelope=ease(age/fade)*ease((duration-t)/release);
   // Frequency wanders a little; depth breathes independently. A subtle
   // second harmonic makes the motion less mechanically sinusoidal.
   double phase=2*pi*rateHz*age+0.11*std::sin(2*pi*0.9*age);
   double motion=(std::sin(phase)+0.08*std::sin(2*phase))/1.08;
   double breathing=0.93+0.07*std::sin(2*pi*0.7*age+0.8);
   int value=int(std::lround(8192+depthCents/100/48*8192*envelope*breathing*motion));
   result.push_back({fraction,std::clamp(value,0,16383)});
 }
 return result;
}
}
