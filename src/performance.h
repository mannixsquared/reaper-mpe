#pragma once
#include <chrono>
#include <cstdio>
namespace mpe {
// Only slow calls are logged; no MIDI/project contents are written.
struct PerformanceSpan {
 const char* label; std::chrono::steady_clock::time_point begin=std::chrono::steady_clock::now();
 explicit PerformanceSpan(const char* name):label(name){}
 ~PerformanceSpan() {
   double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
   if(ms<16)return;
   FILE* file=std::fopen("/tmp/reaper_mpe_performance.log","a");
   if(file) {std::fprintf(file,"%s %.2f ms\n",label,ms);std::fclose(file);}
 }
};
template<class F> decltype(auto) measure(const char* label,F&& operation) {PerformanceSpan span(label);return operation();}
}
