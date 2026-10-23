#include "vibrato.h"
#include <cassert>
#include <iostream>
int main() {
 auto v=mpe::vibrato(3,35,5.5);
 assert(v.size()>400 && v.size()<=4097);
 assert(v.front().value==8192 && v.back().value==8192);
 int crossings=0,last=0;double previous=-1;
 for(auto b:v) {
   assert(b.fraction>previous);previous=b.fraction;
   assert(std::abs(b.value-8192)<=60);
   int sign=b.value>8192 ? 1 : b.value<8192 ? -1 : 0;
   if(sign && last && sign!=last)++crossings;
   if(sign)last=sign;
 }
 assert(crossings>20 && crossings<40);
 for(auto b:mpe::vibrato(2,0,5))assert(b.value==8192);
 assert(mpe::vibrato(0).empty());assert(mpe::vibrato(-1).empty());
 assert(mpe::vibrato(1e6).size()==4097);
 auto same=mpe::vibrato(3,35,5.5);for(size_t i=0;i<v.size();++i)assert(same[i].value==v[i].value);
 std::cout<<"Vibrato: natural envelope, depth, rate, determinism and sample budget passed.\n";
}
