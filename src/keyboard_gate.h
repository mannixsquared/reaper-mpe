#pragma once
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <array>
namespace mpe {
// Must run before SWELLApplication::sendEvent, which translates shortcuts and
// Escape before calling [super sendEvent:] (and hence before local monitors).
struct KeyboardCapture {
 std::array<bool,128> held{};
 std::array<NSInteger,128> windows{};
 bool consume(NSEvent* event,bool editingWindow,bool textEntry,bool (*action)(unsigned int,NSEventModifierFlags)) {
   if(event.type!=NSEventTypeKeyDown && event.type!=NSEventTypeKeyUp) return false;
   unsigned short physical=event.keyCode;
   if(physical>=held.size()) return false;
   if(held[physical] && windows[physical]==event.windowNumber) {
     if(event.type==NSEventTypeKeyUp) { held[physical]=false; return true; }
     if(event.isARepeat) return true;
     held[physical]=false;
   }
   if(event.type!=NSEventTypeKeyDown || !editingWindow || textEntry) return false;
   NSString* chars=event.charactersIgnoringModifiers.uppercaseString;
   unsigned int key=physical==53 ? 27 : (chars.length==1 ? [chars characterAtIndex:0] : 0);
   // Snapshot identity before Escape's action removes the overlay.
   NSInteger number=event.windowNumber;
   if(!action(key,event.modifierFlags)) return false;
   held[physical]=true; windows[physical]=number;
   return true;
 }
};
namespace applicationGate {
static Class targetClass=Nil;
static IMP previous=nullptr;
static bool (*filter)(NSEvent*)=nullptr;
static void sendEvent(id application,SEL selector,NSEvent* event) {
 if(filter && filter(event)) return;
 ((void(*)(id,SEL,NSEvent*))previous)(application,selector,event);
}
inline bool install(Class applicationClass,bool (*callback)(NSEvent*)) {
 if(targetClass) return true;
 Method method=class_getInstanceMethod(applicationClass,@selector(sendEvent:));
 if(!method) return false;
 IMP original=method_getImplementation(method);
 // Add an override if the method is inherited; never alter a superclass.
 class_addMethod(applicationClass,@selector(sendEvent:),original,method_getTypeEncoding(method));
 method=class_getInstanceMethod(applicationClass,@selector(sendEvent:));
 previous=method_setImplementation(method,(IMP)sendEvent);
 filter=callback; targetClass=applicationClass;
 return true;
}
inline void uninstall() {
 filter=nullptr;
 if(!targetClass) return;
 Method method=class_getInstanceMethod(targetClass,@selector(sendEvent:));
 if(method_getImplementation(method)==(IMP)sendEvent) {
   method_setImplementation(method,previous); targetClass=Nil; previous=nullptr;
 }
 // If another extension wraps us, retain the forwarding chain instead of
 // overwriting that extension's hook. REAPER unloads extensions at shutdown.
}
}
}
