#import "SFHitchMonitor.h"
#import "SFCore.h"

static const CFAbsoluteTime kHitch = 0.033;     // > 2 frames at 60 Hz: the micro-stutter the user sees
static const CFAbsoluteTime kKeyWindow = 1.0;   // a stall this soon after a key press is "after" it

void SFHitchMonitorStart(void (^lastKey)(NSString **, NSTimeInterval *)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void (^key)(NSString **, NSTimeInterval *) = [lastKey copy];
        __block CFAbsoluteTime busySince = 0, lastLog = 0;
        __block NSUInteger quiet = 0;   // stalls not logged since the last line (at most one line per second)
        CFRunLoopObserverRef o = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting, true, 0,
            ^(CFRunLoopObserverRef obs, CFRunLoopActivity act) {
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (act == kCFRunLoopAfterWaiting) { busySince = now; return; }
                if (!busySince) return;
                CFAbsoluteTime busy = now - busySince;
                busySince = 0;
                if (busy < kHitch) return;
                if (now - lastLog < 1) { quiet++; return; }
                NSString *name = nil; NSTimeInterval at = 0;
                if (key) key(&name, &at);
                NSTimeInterval ago = [NSDate timeIntervalSinceReferenceDate] - at;
                NSString *after = name && ago < busy + kKeyWindow ? [NSString stringWithFormat:@" after key %@", name] : @"";
                SFLog(@"hitch: main thread busy %.0f ms%@%@", busy * 1000, after,
                      quiet ? [NSString stringWithFormat:@" (+%lu shorter-spaced)", (unsigned long)quiet] : @"");
                lastLog = now; quiet = 0;
            });
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, kCFRunLoopCommonModes);
        CFRelease(o);
    });
}
