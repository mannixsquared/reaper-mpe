#import <Cocoa/Cocoa.h>
#include "keyboard_gate.h"
#include <cassert>
#include <iostream>
// This application handles shortcuts BEFORE normal Cocoa dispatch, like SWELL.
// Testing sendEvent entry itself catches what the previous accelerator mock did not.
static int nativeDispatches=0,handled=0;
static bool editing=true,textEntry=false,smooth=false;
static mpe::KeyboardCapture capture;
static bool action(unsigned int key,NSEventModifierFlags flags) {
 if(flags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption)) return false;
 if(key=='S') smooth=true;
 else if(key=='F') smooth=false;
 else if(key==27) editing=false;
 else if(key!='0' && key!='V') return false;
 ++handled; return true;
}
static bool filter(NSEvent* event) { return capture.consume(event,editing,textEntry,action); }
@interface TestApplication : NSObject
- (void)sendEvent:(NSEvent*)event;
@end
@implementation TestApplication
- (void)sendEvent:(NSEvent*)event { ++nativeDispatches; }
@end
static NSEvent* key(NSString* chars,unsigned short physical,NSEventModifierFlags flags=0,bool repeat=false,NSEventType type=NSEventTypeKeyDown) {
 return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:77 context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:repeat keyCode:physical];
}
int main() { @autoreleasepool {
 TestApplication* app=[TestApplication new];
 assert(mpe::applicationGate::install(app.class,filter));
 [app sendEvent:key(@"s",1)];assert(smooth && nativeDispatches==0 && handled==1);
 [app sendEvent:key(@"f",3)];assert(!smooth && nativeDispatches==0);
 [app sendEvent:key(@"S",1,NSEventModifierFlagShift)];assert(smooth && nativeDispatches==0);
 [app sendEvent:key(@"F",3,NSEventModifierFlagShift)];assert(!smooth && nativeDispatches==0);
 [app sendEvent:key(@"S",1,NSEventModifierFlagShift,true)];assert(nativeDispatches==0 && handled==4);
 [app sendEvent:key(@"s",1,NSEventModifierFlagCommand)];assert(nativeDispatches==1);
 textEntry=true;[app sendEvent:key(@"s",1)];assert(nativeDispatches==2);textEntry=false;
 [app sendEvent:key(@"x",7)];assert(nativeDispatches==3);
 // Escape never reaches the native window-close handler, including its repeat
 // and release after the edit view has already been removed.
 [app sendEvent:key(@"\x1b",53)];assert(!editing && nativeDispatches==3);
 [app sendEvent:key(@"\x1b",53,0,true)];assert(nativeDispatches==3);
 [app sendEvent:key(@"\x1b",53,0,false,NSEventTypeKeyUp)];assert(nativeDispatches==3);
 [app sendEvent:key(@"s",1)];assert(nativeDispatches==4);
 [app sendEvent:key(@"\x1b",53)];assert(nativeDispatches==5);
 mpe::applicationGate::uninstall();editing=true;
 [app sendEvent:key(@"s",1)];assert(nativeDispatches==6);
 [app release];
 std::cout<<"Native event gate: plain/Shift F/S, repeats, text fields, modified shortcuts, Escape and forwarding passed.\n";
} }
