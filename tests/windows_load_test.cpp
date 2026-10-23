#include <windows.h>
#include <cassert>
#include <iostream>
int main(int argc,char** argv) {
 assert(argc==2);
 HMODULE module=LoadLibraryA(argv[1]);assert(module);
 auto entry=reinterpret_cast<int(*)(void*,void*)>(GetProcAddress(module,"ReaperPluginEntry"));
 assert(entry && entry(nullptr,nullptr)==0);
 assert(FreeLibrary(module));
 std::cout<<"Windows plugin loads, exports ReaperPluginEntry and unloads cleanly.\n";
}
